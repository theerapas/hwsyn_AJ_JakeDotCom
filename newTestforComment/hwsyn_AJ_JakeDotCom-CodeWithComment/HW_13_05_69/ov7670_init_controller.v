// ============================================================================
// โมดูลควบคุมการตั้งค่ากล้อง OV7670 (Configuration Sequencer)
//
// หน้าที่หลัก: 
// 1. ส่งสัญญาณฮาร์ดแวร์รีเซ็ตไปที่กล้อง (ดึงสาย Reset ลงกราวด์) แล้วรอให้กล้องบูทเสร็จ
// 2. ไล่อ่านชุดคำสั่งจาก ov7670_init_rom แล้วทยอยส่งผ่านสาย SCCB (I2C) ทีละตัว
// 3. มีระบบดักจับการสับสวิตช์ (colorbar) เพื่อสั่งให้ระบบเริ่มกระบวนการตั้งค่าใหม่อีกรอบ
// ============================================================================
module ov7670_init_controller #(
    // ตั้งค่าเวลาหน่วง (Delay) เพื่อรอให้กล้องบูทเสร็จ (Hardware ต้องรอนานหน่อย)
    parameter integer SETTLE_CYCLES = 200000,
    parameter integer SCCB_DIV = 2000
) (
    input  wire clk,            // Clock หลักของระบบ
    input  wire reset,          // สัญญาณรีเซ็ตวงจร (จากภายนอก)
    input  wire colorbar,       // สวิตช์เปิด/ปิดโหมดแถบสี (SW[5])
    output reg  camera_reset = 1'b0, // สายไฟเสียบเข้าขา Reset ของกล้อง
    output wire sioc,           // สัญญาณนาฬิกา SCCB
    inout  wire siod,           // สัญญาณข้อมูล SCCB
    output reg  init_done = 1'b0     // Flag บอกว่า "ตั้งค่าครบหมดแล้วจ้า"
);

    // ========================================================================
    // ตัวแปรสำหรับคุมวงจรย่อย และนับเวลา
    // ========================================================================
    reg [19:0] wait_ctr = 20'd0;    // ตัวนับเวลา (ใช้ตอนสั่งรอ Delay)
    reg start_tx = 1'b0;            // สั่งให้ SCCB เริ่มส่งข้อมูล
    reg [7:0] tx_reg_addr = 8'h00;  // ที่อยู่ Register ที่จะเขียน
    reg [7:0] tx_reg_data = 8'h00;  // ข้อมูลที่จะเขียน
    wire tx_busy;                   // SCCB ตอบกลับมาว่า "กำลังยุ่งอยู่ (กำลังส่งไฟ)"
    wire tx_done;                   // SCCB ตอบกลับมาว่า "ส่งเสร็จแล้ว 1 ไบต์"

    reg [7:0] rom_addr = 8'd0;      // ตัวชี้บรรทัดคู่มือ (ROM)
    wire [15:0] rom_word;           // ข้อมูล 16 บิตที่อ่านได้จากคู่มือ (ROM)

    // ========================================================================
    // เทคนิคป้องกันปัญหา Metastability จากสวิตช์ (Synchronizer & Edge Detector)
    // ========================================================================
    // เนื่องจากสวิตช์คนกดมันอยู่นอกระบบ Clock (Asynchronous) เราต้องเอามาผ่าน 
    // Flip-flop 2 ชั้น (meta -> sync) เพื่อให้สัญญาณเนียนไปกับ Clock ก่อนใช้งาน
    reg colorbar_d = 1'b0;          // เก็บค่าสถานะสวิตช์ในอดีต (1 Clock ที่แล้ว)
    reg active_colorbar = 1'b0;
    reg colorbar_meta = 1'b0;       // ด่านแรกรับแรงกระแทกจากสวิตช์
    reg colorbar_sync = 1'b0;       // ด่านสอง สัญญาณนิ่งพร้อมใช้

    // เรียกใช้ ROM (หนังสือคู่มือ)
    ov7670_init_rom rom_u (
        .addr     (rom_addr),
        .colorbar (active_colorbar),
        .data     (rom_word)
    );

    // เรียกใช้โมดูลส่งข้อมูล SCCB (คนลงมือส่งไฟ)
    sccb_write_byte #(
        .DIV(SCCB_DIV)
    ) sccb_u (
        .clk         (clk),
        .reset       (reset),
        .start       (start_tx),
        .dev_addr    (8'h42),  // รหัสประจำตัวกล้อง OV7670 (Write Address = 0x42)
        .reg_addr    (tx_reg_addr),
        .reg_data    (tx_reg_data),
        .sioc        (sioc),
        .siod        (siod),
        .busy        (tx_busy),
        .done        (tx_done)
    );

    // ========================================================================
    // State Machine (FSM) ควบคุมลำดับการทำงานทั้งหมด
    // ========================================================================
    localparam S_RESET = 3'd0; // โหมด: กดปุ่มรีเซ็ตกล้องแช่ไว้
    localparam S_WAIT  = 3'd1; // โหมด: ปล่อยปุ่มรีเซ็ต แล้วรอให้กล้องสติกลับมา
    localparam S_LOAD  = 3'd2; // โหมด: อ่านคำสั่งจาก ROM
    localparam S_START = 3'd3; // โหมด: สั่ง SCCB ให้เริ่มส่ง
    localparam S_NEXT  = 3'd4; // โหมด: รอ SCCB ส่งเสร็จ เพื่อไปบรรทัดต่อไป
    localparam S_DONE  = 3'd5; // โหมด: ทำงานจบแล้ว พักผ่อนได้

    reg [2:0] state = S_RESET;

    always @(posedge clk) begin
        // อัปเดตสถานะสวิตช์ (Double-flop synchronizer)
        colorbar_meta <= colorbar;
        colorbar_sync <= colorbar_meta;

        if (reset) begin
            // ถ้ากดปุ่มรีเซ็ตบอร์ด ให้ล้างค่าทุกอย่างเริ่มใหม่หมด
            state <= S_RESET;
            wait_ctr <= 0;
            rom_addr <= 0;
            start_tx <= 0;
            init_done <= 0;
            camera_reset <= 1'b0;
            active_colorbar <= colorbar_sync;
            colorbar_d <= colorbar_sync;
        end else begin
            start_tx <= 0; // เคลียร์คำสั่งส่งข้อมูลเสมอ (มันเป็น Pulse แค่ 1 Clock)

            // Edge Detector: ตรวจจับว่ามีการ "สับสวิตช์" (สถานะอดีต != สถานะปัจจุบัน)
            // ถ้าระบบตั้งค่าเสร็จแล้ว (init_done) แต่จู่ๆ คนสับสวิตช์ ให้รีเซ็ตตัวเองไปเริ่มตั้งค่าใหม่หมด!
            if (init_done && (colorbar_sync != colorbar_d)) begin
                state <= S_RESET;
                wait_ctr <= 0;
                rom_addr <= 0;
                init_done <= 0;
                camera_reset <= 1'b0;
                active_colorbar <= colorbar_sync;
                colorbar_d <= colorbar_sync;
            end else case (state)
                
                // สเตตัสที่ 0: ดึงสาย Reset ลง 0 (Active-Low) ค้างไว้ให้วงจรในกล้องล้างค่า
                S_RESET: begin
                    camera_reset <= 1'b0;
                    if (wait_ctr < SETTLE_CYCLES) begin
                        wait_ctr <= wait_ctr + 1'd1; // นับถอยหลังรอ
                    end else begin
                        camera_reset <= 1'b1; // ปล่อยสาย Reset กลับเป็น 1
                        wait_ctr <= 0;
                        state <= S_WAIT;
                    end
                end

                // สเตตัสที่ 1: ปล่อยให้กล้องบูทตัวเองสักพัก (ไม่งั้นส่งคำสั่งไปมันก็ไม่ฟัง)
                // สเตตัสนี้ถูกใช้งานซ้ำด้วย ถ้ารหัส ROM สั่งให้รอ (FFFE)
                S_WAIT: begin
                    camera_reset <= 1'b1;
                    if (wait_ctr < SETTLE_CYCLES) begin
                        wait_ctr <= wait_ctr + 1'd1; // นับถอยหลังรอ
                    end else begin
                        state <= S_LOAD;
                    end
                end

                // สเตตัสที่ 2: ไปอ่านคู่มือ (ROM) มา 1 บรรทัด
                // มีรหัสลับ 2 ตัว: FFFE (ให้รอแป๊บนึง), FFFF (หมดเล่มแล้ว)
                S_LOAD: begin
                    if (rom_word == 16'hFFFF) begin
                        state <= S_DONE;             // เจอ FFFF แปลว่าจบงาน ไปพักได้
                    end else if (rom_word == 16'hFFFE) begin
                        wait_ctr <= 0;               
                        state <= S_WAIT;             // เจอ FFFE สั่งให้กระโดดไปนับเวลาถอยหลัง (S_WAIT)
                        rom_addr <= rom_addr + 1'd1; // แล้วเตรียมตัวอ่านบรรทัดต่อไป
                    end else begin
                        tx_reg_addr <= rom_word[15:8]; // หั่น 8 บิตบนไปเป็น Address
                        tx_reg_data <= rom_word[7:0];  // หั่น 8 บิตล่างไปเป็น Data
                        state <= S_START;
                    end
                end

                // สเตตัสที่ 3: กระทุ้งบอกโมดูล SCCB ว่า "พร้อมแล้ว ส่งเลยลูกพี่!"
                S_START: begin
                    if (!tx_busy) begin  // เช็คก่อนว่าสายว่างไหม
                        start_tx <= 1'b1;
                        state <= S_NEXT;
                    end
                end

                // สเตตัสที่ 4: ยืนรอจนกว่า SCCB จะส่งเสร็จ
                S_NEXT: begin
                    if (tx_done) begin               // พอส่งเสร็จแล้ว
                        rom_addr <= rom_addr + 1'd1; // ชี้ไปที่บรรทัดถัดไป
                        state <= S_LOAD;             // กลับไปอ่าน ROM บรรทัดใหม่
                    end
                end

                // สเตตัสที่ 5: งานจบแล้ว ชูธงบอกระบบว่าตั้งค่าเสร็จ
                S_DONE: begin
                    init_done <= 1'b1;
                end
            endcase
        end
    end
endmodule