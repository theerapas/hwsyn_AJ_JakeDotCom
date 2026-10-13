// ============================================================================
// โมดูลส่งข้อมูลผ่านโปรโตคอล SCCB (คล้าย I2C) สำหรับตั้งค่ากล้อง OV7670
//
// หน้าที่หลัก: รับคำสั่ง 3 ไบต์ (Device Address, Register Address, Data)
// มาแปลงเป็นสัญญาณอนุกรม (Serial) ส่งออกไปทีละบิตตามมาตรฐาน SCCB
// ============================================================================
module sccb_write_byte #(
    // ตัวหารความถี่ (Clock Divider) เพื่อสร้างจังหวะการส่งข้อมูล
    // บอร์ดทำงานที่ 100 MHz หารด้วย 2000 จะได้จังหวะการทำงานประมาณ 50 kHz
    // (ความถี่จริงของ SIOC จะช้ากว่านี้เพราะใช้หลาย Tick ต่อ 1 บิต)
    parameter integer DIV = 2000
) (
    input  wire clk,            // สัญญาณนาฬิกาหลักของระบบ (100 MHz)
    input  wire reset,          // สัญญาณรีเซ็ตวงจร
    input  wire start,          // สัญญาณกระตุ้นให้เริ่มส่งข้อมูล (Pulse 1 clock)
    input  wire [7:0] dev_addr, // ที่อยู่ของตัวกล้อง (มักจะเป็น 8'h42 สำหรับเขียน)
    input  wire [7:0] reg_addr, // ตำแหน่ง Register ภายในกล้องที่ต้องการตั้งค่า
    input  wire [7:0] reg_data, // ข้อมูลที่ต้องการเขียนลงไปใน Register นั้น
    output wire sioc,           // สัญญาณนาฬิกา SCCB (Serial Clock) ส่งไปให้กล้อง
    inout  wire siod,           // สัญญาณข้อมูล SCCB (Serial Data) แบบ 2 ทิศทาง
    output reg  busy = 1'b0,    // สถานะบอกว่า "กำลังส่งข้อมูลอยู่ ห้ามกวน"
    output reg  done = 1'b0     // สถานะบอกว่า "ส่งข้อมูลเสร็จแล้ว 1 ชุด"
);


    // ============================================================================
    // ส่วนที่ 1: ตัวกำเนิดจังหวะ (Baud Rate / Tick Generator)
    // ============================================================================
    reg [15:0] divcnt = 0; // ตัวนับสำหรับหารความถี่
    reg scl = 1'b1;        // ตัวแปรจำลองสถานะของสาย SIOC
    reg tick = 1'b0;       // สัญญาณชีพจร (Pulse) ที่จะดังขึ้น 1 ครั้งเมื่อนับครบ


    // สร้างสัญญาณ tick เป็นจังหวะอ้างอิงให้ State Machine ทำงาน
    always @(posedge clk) begin
        if (reset) begin
            divcnt <= 0;
            tick <= 0;
        end else begin
            if (divcnt == DIV-1) begin
                divcnt <= 0;
                tick <= 1'b1; // ส่ง Tick ออกมา 1 จังหวะ
            end else begin
                divcnt <= divcnt + 1'd1;
                tick <= 1'b0;
            end
        end
    end


    // ============================================================================
    // ส่วนที่ 2: วงจรควบคุมสายส่งข้อมูลทางกายภาพ (Physical Layer / Open-Drain)
    // ============================================================================
    reg sda_out = 1'b1; // ข้อมูลที่เราต้องการส่งออกไป (0 หรือ 1)
    reg sda_oe  = 1'b1; // Output Enable (อนุญาตให้ FPGA ดึงสายไฟหรือไม่)
   
    // เชื่อม SCL เข้ากับสาย SIOC โดยตรง
    assign sioc = scl;
   
    // กฎของ Open-Drain (เช่นเดียวกับ I2C):
    // - ถ้าอยากส่ง '0' ให้ FPGA ดึงสายลงกราวด์ (1'b0)
    // - ถ้าอยากส่ง '1' ให้ FPGA ปล่อยสายว่าง (1'bz หรือ High-Impedance)
    //   แล้วตัวต้านทาน Pull-up บนบอร์ดจะดึงไฟขึ้นเป็น '1' เอง ป้องกันการลัดวงจร
    assign siod = (sda_oe && !sda_out) ? 1'b0 : 1'bz;


    // ============================================================================
    // ส่วนที่ 3: โครงสร้างข้อมูล (Shift Register & Bit Counter)
    // ============================================================================
    reg [5:0] bitcnt = 0;   // ตัวนับว่าตอนนี้ส่งไปแล้วกี่บิต
    reg [26:0] shreg = 27'h0; // ท่อพักข้อมูล (Shift Register) ขนาด 27 บิต


    // ประกาศชื่อสถานะ (State) ต่างๆ ของ FSM เพื่อให้อ่านโค้ดง่ายขึ้น
    localparam I_IDLE  = 3'd0; // รอคำสั่ง
    localparam I_START = 3'd1; // สร้างจังหวะเริ่ม (Start Condition)
    localparam I_BITL  = 3'd2; // จังหวะวางข้อมูล (Clock Low)
    localparam I_BITH  = 3'd3; // จังหวะให้กล้องอ่านข้อมูล (Clock High)
    localparam I_STOP0 = 3'd4; // เตรียมสร้างจังหวะจบ
    localparam I_STOP1 = 3'd5; // สร้างจังหวะจบ (Stop Condition) ขั้น 1
    localparam I_STOP2 = 3'd6; // สร้างจังหวะจบ ขั้น 2


    reg [2:0] state = I_IDLE;


    // ============================================================================
    // ส่วนที่ 4: เครื่องจักรสถานะ (Finite State Machine - FSM)
    // ============================================================================
    always @(posedge clk) begin
        if (reset) begin
            state <= I_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            scl <= 1'b1;
            sda_out <= 1'b1;
            sda_oe <= 1'b1;
            bitcnt <= 0;
        end else begin
            done <= 1'b0; // เคลียร์สัญญาณ Done เสมอ (ให้เป็นแค่ Pulse สั้นๆ)


            // ถ้าเครื่องว่างอยู่ และมีคนสั่ง start
            if ((state == I_IDLE) && start) begin
                scl <= 1'b1;
                sda_out <= 1'b1;
                sda_oe <= 1'b1;
               
                // จัดเรียงแพ็กเกจข้อมูล 27 บิต:
                // [Device Addr 8 บิต] + [Don't Care 1 บิต] +
                // [Reg Addr 8 บิต] + [Don't Care 1 บิต] +
                // [Data 8 บิต] + [Don't Care 1 บิต]
                // (บิต '1' ที่คั่นอยู่คือบิตเว้นว่างให้กล้องส่ง Ack กลับมา แต่เราไม่ได้อ่าน)
                shreg <= {dev_addr, 1'b1, reg_addr, 1'b1, reg_data, 1'b1};
               
                bitcnt <= 6'd26; // นับถอยหลัง 27 บิต (26 ถึง 0)
                busy <= 1'b1;    // ประกาศว่าเครื่องไม่ว่างแล้ว
                state <= I_START; // ขยับไปสถานะเริ่มต้น
               
            // State Machine จะขยับก็ต่อเมื่อมีสัญญาณ tick เข้ามาเท่านั้น
            end else if (tick) begin
                case (state)
                    I_IDLE: begin
                        // อยู่เฉยๆ รักษาให้สาย Clock และ Data เป็น High (สภาวะปกติ)
                        scl <= 1'b1;
                        sda_out <= 1'b1;
                        sda_oe <= 1'b1;
                        busy <= 1'b0;
                    end


                    I_START: begin
                        // เงื่อนไข Start Condition ของ SCCB:
                        // ขณะที่สาย Clock (scl) เป็น High ให้ดึงสาย Data (sda) ลงมาเป็น Low
                        scl <= 1'b1;
                        sda_out <= 1'b0;
                        state <= I_BITL;
                    end


                    I_BITL: begin
                        scl <= 1'b0; // ดึง Clock ลง Low เพื่อให้กล้องรู้ว่า "หยุดอ่านก่อน เรากำลังเปลี่ยนข้อมูล"
                       
                        // ปลดการเชื่อมต่อ (High-Z) ในบิตที่ 9 (Don't care/Ack bit)
                        // ตำแหน่งที่ 18, 9, 0 คือบิตคั่นระหว่างแต่ละไบต์ตามกฎ SCCB
                        sda_oe <= !((bitcnt == 6'd18) || (bitcnt == 6'd9) || (bitcnt == 6'd0));
                       
                        // หยิบบิตซ้ายสุดของ Shift Register มาวางบนสาย Data
                        sda_out <= shreg[26];
                        state <= I_BITH;
                    end


                    I_BITH: begin
                        scl <= 1'b1; // ดัน Clock ขึ้น High เพื่อสั่งกล้องว่า "อ่านข้อมูลบนสายได้เลย!"
                       
                        // เลื่อนบิตใน Shift Register ไปทางซ้าย 1 ตำแหน่ง เพื่อเตรียมข้อมูลบิตถัดไป
                        shreg <= {shreg[25:0],1'b1};
                       
                        if (bitcnt == 0)
                            state <= I_STOP0; // ถ้าส่งครบ 27 บิตแล้ว ให้ไปสร้าง Stop Condition
                        else begin
                            bitcnt <= bitcnt - 1'd1; // ลดจำนวนบิตที่เหลือลง
                            state <= I_BITL; // วนกลับไปสถานะ Clock Low เพื่อส่งบิตถัดไป
                        end
                    end


                    // ขั้นตอนการสร้าง Stop Condition: Data ต้องเปลี่ยนจาก Low เป็น High ในขณะที่ Clock เป็น High
                    I_STOP0: begin
                        sda_oe <= 1'b1;
                        scl <= 1'b0;      // ดึง Clock ลง Low ก่อน
                        sda_out <= 1'b0;  // ดึง Data ลง Low เตรียมไว้
                        state <= I_STOP1;
                    end


                    I_STOP1: begin
                        sda_oe <= 1'b1;
                        scl <= 1'b1;      // ดัน Clock ขึ้น High
                        sda_out <= 1'b0;  // Data ยังคงเป็น Low อยู่
                        state <= I_STOP2;
                    end


                    I_STOP2: begin
                        scl <= 1'b1;      // Clock ยังเป็น High
                        sda_out <= 1'b1;  // ปล่อย Data ให้ลอยขึ้น High (เสร็จสมบูรณ์ Stop Condition)
                        busy <= 1'b0;     // เครื่องว่างแล้ว
                        done <= 1'b1;     // ส่ง Pulse ว่า "จบงาน" ให้ Controller ตัวแม่รู้
                        state <= I_IDLE;  // กลับไปรอคำสั่งใหม่
                    end
                endcase
            end
        end
    end
endmodule
