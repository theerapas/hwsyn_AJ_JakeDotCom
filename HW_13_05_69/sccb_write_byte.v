`timescale 1ns / 1ps

// ============================================================================
// โมดูลส่งข้อมูล SCCB แบบ 1 คำสั่ง (Single-register SCCB write engine)
//
// การทำงาน 1 รอบ (Transaction) จะประกอบด้วยการส่งข้อมูล 3 ไบต์:
// 1. Device Address (รหัสประจำตัวกล้อง OV7670 โหมดเขียน)
// 2. Register Address (ตำแหน่งที่อยู่ที่ต้องการตั้งค่า)
// 3. Register Data (ข้อมูลที่จะตั้งค่า)
// *หมายเหตุ: หลังจบแต่ละไบต์ จะมีบิตที่ 9 (Don't care / ACK) คั่นเสมอ
// ============================================================================
module sccb_write_byte #(
    // ตัวหาร Clock (Divider) 
    // แปลง 100 MHz ให้กลายเป็นสัญญาณ Tick ที่ความเร็ว 50 kHz 
    // (ทำให้ความเร็ว SCL ออกมาที่ประมาณ 25 kHz เพราะ 1 ไซเคิลใช้ 2 Tick)
    parameter integer DIV = 2000
) (
    input  wire clk,            // นาฬิการะบบ 100 MHz
    input  wire reset,          // สัญญาณรีเซ็ต
    input  wire start,          // สัญญาณทริกเกอร์สั่งให้เริ่มส่งข้อมูล (Pulse 1 Clock)
    input  wire [7:0] dev_addr, // ไบต์ที่ 1: Device Address (ปกติคือ 0x42)
    input  wire [7:0] reg_addr, // ไบต์ที่ 2: Register Address
    input  wire [7:0] reg_data, // ไบต์ที่ 3: Data
    output wire sioc,           // สายสัญญาณนาฬิกา SCCB (SCL)
    inout  wire siod,           // สายสัญญาณข้อมูล SCCB (SDA) แบบ 2 ทิศทาง
    output reg  busy = 1'b0,    // 1 = กำลังส่งข้อมูลอยู่ ห้ามกวน
    output reg  done = 1'b0     // 1 = ส่งครบจบ 1 Transaction แล้ว
);

    // ========================================================================
    // ส่วนที่ 1: ตัวสร้างจังหวะ Tick (Clock Divider)
    // ========================================================================
    reg [15:0] divcnt = 0;
    reg scl = 1'b1;
    reg tick = 1'b0; // สัญญาณชีพจรที่จะเด้งเป็น 1 ทุกๆ 20 ไมโครวินาที (50 kHz)

    always @(posedge clk) begin
        if (reset) begin
            divcnt <= 0;
            tick <= 0;
        end else begin
            if (divcnt == DIV-1) begin
                divcnt <= 0;
                tick <= 1'b1; // ปล่อย Tick ออกมา 1 จังหวะ
            end else begin
                divcnt <= divcnt + 1'd1;
                tick <= 1'b0;
            end
        end
    end

    // ========================================================================
    // ส่วนที่ 2: การควบคุมสายข้อมูลแบบ Open-Drain
    // โปรโตคอล I2C/SCCB ไม่อนุญาตให้ FPGA ดันไฟ 3.3V (1) เข้าสายตรงๆ เพื่อป้องกันสายช็อต
    // FPGA ทำได้แค่ "ดึงสายลงกราวด์ (0)" หรือ "ปล่อยสายลอย (High-Z)" ให้ Pull-up ดึงขึ้นไปเป็น 1 เอง
    // ========================================================================
    reg sda_out = 1'b1; // ข้อมูลที่ต้องการส่ง (1=ปล่อยลอย, 0=ดึงลงกราวด์)
    reg sda_oe  = 1'b1; // Output Enable (1=เราเป็นคนขับสาย, 0=เปิดทางให้กล้องตอบกลับ)
    
    assign sioc = scl;  // สาย Clock ส่งออกทางเดียว
    assign siod = (sda_oe && !sda_out) ? 1'b0 : 1'bz; // ลอจิก Open-drain ของจริง

    // ========================================================================
    // ส่วนที่ 3: Shift Register สำหรับเรียงข้อมูลเตรียมส่ง
    // ข้อมูลทั้งหมด 27 บิต = {Dev_Addr(8), ACK(1), Reg_Addr(8), ACK(1), Data(8), ACK(1)}
    // ========================================================================
    reg [5:0] bitcnt = 0;
    reg [26:0] shreg = 27'h0;

    // ========================================================================
    // ส่วนที่ 4: State Machine (FSM) สำหรับควบคุมจังหวะ I2C/SCCB
    // ========================================================================
    localparam I_IDLE  = 3'd0; // โหมด: ว่างงาน รอคำสั่ง
    localparam I_START = 3'd1; // โหมด: สร้าง Start Condition
    localparam I_BITL  = 3'd2; // โหมด: สาย SCL เป็น 0 (ช่วงเปลี่ยนข้อมูล SDA)
    localparam I_BITH  = 3'd3; // โหมด: สาย SCL เป็น 1 (ช่วงล็อคข้อมูลให้อีกฝั่งอ่าน)
    localparam I_STOP0 = 3'd4; // โหมด: เตรียมสร้าง Stop Condition
    localparam I_STOP1 = 3'd5; // โหมด: สร้าง Stop Condition จังหวะ 1
    localparam I_STOP2 = 3'd6; // โหมด: สร้าง Stop Condition จังหวะ 2

    reg [2:0] state = I_IDLE;

    // FSM นี้จะขยับ State ก็ต่อเมื่อมีสัญญาณ `tick` มาเคาะเท่านั้น (ทำงานที่ 50 kHz)
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
            done <= 1'b0; // สัญญาณ done จะเป็น 1 แค่ Clock เดียวตอนจบงาน

            if ((state == I_IDLE) && start) begin
                // ได้รับคำสั่ง Start: เตรียมขบวนรถไฟข้อมูล 27 บิต
                scl <= 1'b1;
                sda_out <= 1'b1;
                sda_oe <= 1'b1;
                // ประกอบร่างบิต: สังเกตว่ามี 1'b1 คั่นเพื่อเป็นช่วงเวลา Don't Care (ACK) ให้กล้องดึงสาย
                shreg <= {dev_addr, 1'b1, reg_addr, 1'b1, reg_data, 1'b1};
                bitcnt <= 6'd26; // เริ่มนับจากบิตที่ 26 ลงไป 0
                busy <= 1'b1;    // ยกธงบอกระบบว่า "กำลังยุ่ง"
                state <= I_START;
                
            end else if (tick) begin
                // ขยับ State ตามจังหวะ Tick (50 kHz)
                case (state)
                    I_IDLE: begin
                        scl <= 1'b1;
                        sda_out <= 1'b1;
                        sda_oe <= 1'b1;
                        busy <= 1'b0;
                    end

                    // START Condition: กฎของ I2C คือต้องดึง SDA ลง 0 ในขณะที่ SCL ยังเป็น 1
                    I_START: begin
                        scl <= 1'b1;
                        sda_out <= 1'b0;
                        state <= I_BITL;
                    end

                    // BIT LOW (เตรียมข้อมูล): ดึง SCL เป็น 0 แล้วเปลี่ยนค่า SDA ตามข้อมูลที่จะส่ง
                    I_BITL: begin
                        scl <= 1'b0;
                        // ถ้าถึงจังหวะบิตที่ 9 (บิตที่ 18, 9, 0 ของ bitcnt) ให้เราปล่อยสาย (OE=0) เพื่อให้กล้องส่ง ACK
                        sda_oe <= !((bitcnt == 6'd18) || (bitcnt == 6'd9) || (bitcnt == 6'd0));
                        sda_out <= shreg[26]; // เอาบิตซ้ายสุด (MSB) ทยอยส่งออกไป
                        state <= I_BITH;
                    end

                    // BIT HIGH (ล็อคข้อมูล): ดึง SCL เป็น 1 เพื่อเคาะให้กล้องอ่านข้อมูลที่เราวางไว้บนสาย SDA
                    I_BITH: begin
                        scl <= 1'b1;
                        shreg <= {shreg[25:0], 1'b1}; // เลื่อนขบวนรถไฟ (Shift Left) ดันบิตถัดไปมารอซ้ายสุด
                        if (bitcnt == 0)
                            state <= I_STOP0; // ถ้าครบ 27 บิตแล้ว ไปสร้าง Stop Condition
                        else begin
                            bitcnt <= bitcnt - 1'd1;
                            state <= I_BITL;  // วนกลับไปส่งบิตต่อไป
                        end
                    end

                    // STOP Condition: กฎของ I2C คือต้องปล่อย SDA ขึ้นเป็น 1 ในขณะที่ SCL เป็น 1 อยู่แล้ว
                    I_STOP0: begin
                        sda_oe <= 1'b1;
                        scl <= 1'b0;    // ดึง SCL ลงก่อน
                        sda_out <= 1'b0; // ดึง SDA ลงรอมั่นๆ
                        state <= I_STOP1;
                    end

                    I_STOP1: begin
                        sda_oe <= 1'b1;
                        scl <= 1'b1;    // ปล่อย SCL ขึ้นเป็น 1
                        sda_out <= 1'b0; // SDA ยังคงเป็น 0 อยู่
                        state <= I_STOP2;
                    end

                    I_STOP2: begin
                        scl <= 1'b1;
                        sda_out <= 1'b1; // ปล่อย SDA ขึ้นเป็น 1 (ขณะที่ SCL เป็น 1) -> เกิดคลื่น STOP!
                        busy <= 1'b0;    // เลิกยุ่งแล้ว
                        done <= 1'b1;    // ชูธงบอก Controller ว่าส่งคำสั่งนี้สำเร็จ
                        state <= I_IDLE; // กลับไปรอคำสั่งถัดไป
                    end
                endcase
            end
        end
    end
endmodule