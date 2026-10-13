`timescale 1ns / 1ps

// ============================================================================
// โมดูลขยายภาพแบบ Bilinear 4 เท่า (320x240 -> 1280x960)
//
// คอนเซปต์หลัก: แทนที่จะอ่าน RAM หลัก 4 ครั้งต่อ 1 พิกเซล (ซึ่ง Clock วิ่งไม่ทันแน่ๆ) 
// โมดูลนี้จะแอบไป "ดูดข้อมูลล่วงหน้า (Prefetch)" มาเก็บไว้ใน "ถังพักข้อมูล (Row Buffers)" ทีละ 2 บรรทัด
// โดยมีถังพัก 2 ชุดสลับกันทำงาน (Bank A และ Bank B) เพื่อให้สตรีมภาพออกจอได้ลื่นไหลไม่มีสะดุด
// ============================================================================
module bilinear_upscaler_4x (
    input  wire        clk,           // นาฬิกา 108 MHz สำหรับจอ HD
    input  wire        frame_ready,   // สัญญาณบอกว่ามีภาพเต็มเฟรมพร้อมให้ดึงแล้ว
    input  wire [10:0] sx,            // พิกัด X บนหน้าจอ VGA (0-1279)
    input  wire [9:0]  sy,            // พิกัด Y บนหน้าจอ VGA (0-959)
    input  wire        active_video,  // 1 = อยู่ในช่วงวาดภาพลงจอ
    output reg  [16:0] fb_addr = 17'd0, // ตำแหน่ง Address ที่ส่งไปขอข้อมูลจาก Framebuffer หลัก
    input  wire [11:0] fb_data,       // ข้อมูลสีพิกเซลที่ Framebuffer หลักตอบกลับมา
    output wire [11:0] rgb,           // สีที่ผ่านการผสม (Bilinear) เสร็จแล้ว ส่งออกไปรอขึ้นจอ
    output wire        valid          // 1 = ข้อมูลสี rgb พร้อมใช้งานแล้ว
);
    localparam FRAME_WIDTH  = 320;
    localparam FRAME_HEIGHT = 240;

    // ========================================================================
    // ส่วนที่ 1: หน่วยความจำชั่วคราว (Row Buffers - Double Buffering)
    // ใช้ Distributed RAM ใน FPGA สร้างที่เก็บข้อมูลทีละ 1 บรรทัด (320 พิกเซล)
    // แบ่งเป็น Bank A และ Bank B (แต่ละ Bank เก็บแถวบน row0 และแถวล่าง row1 เพื่อใช้ผสมสีแนวตั้ง)
    // ========================================================================
    (* ram_style = "distributed" *) reg [11:0] row0_a [0:FRAME_WIDTH-1];
    (* ram_style = "distributed" *) reg [11:0] row1_a [0:FRAME_WIDTH-1];
    (* ram_style = "distributed" *) reg [11:0] row0_b [0:FRAME_WIDTH-1];
    (* ram_style = "distributed" *) reg [11:0] row1_b [0:FRAME_WIDTH-1];

    // ตัวแปรควบคุมการสลับ Bank (ตัวไหนกำลังส่งออกจอ, ตัวไหนกำลังไปดูดข้อมูลใหม่)
    reg current_bank = 1'b0;
    reg current_valid = 1'b0;
    reg [7:0] current_y = 8'd0;

    reg bank_valid_a = 1'b0;
    reg bank_valid_b = 1'b0;
    reg [7:0] bank_y_a = 8'd0;
    reg [7:0] bank_y_b = 8'd0;

    // ========================================================================
    // ส่วนที่ 2: State Machine สำหรับดึงข้อมูลล่วงหน้า (Prefetch Logic)
    // ========================================================================
    reg prefetch_busy = 1'b0;
    reg prefetch_bank = 1'b0;
    reg [7:0] prefetch_y = 8'd0;
    reg [8:0] prefetch_x = 9'd0;
    reg       prefetch_row = 1'b0;
    reg       rd_pending = 1'b0;
    reg       pending_bank = 1'b0;
    reg       pending_row = 1'b0;
    reg [8:0] pending_x = 9'd0;

    // คำนวณว่าตอนนี้หน้าจอกำลังวาดอยู่ที่ Y ต้นฉบับบรรทัดไหน (เอา sy มาหาร 4 โดยการตัด 2 บิตล่างทิ้ง)
    wire [7:0] display_y = sy[9:2];
    
    // คำนวณหาบรรทัดถัดไปที่ต้องไปดูดข้อมูลมารอไว้ (ถ้ายังไม่สุดขอบล่าง ก็ดึงบรรทัดถัดไปมารอเลย)
    wire [7:0] desired_prefetch_y =
        (!active_video && (sy >= 10'd960)) ? 8'd0 :
        (display_y == 8'd239) ? 8'd239 : (display_y + 8'd1);

    // เช็คว่า Bank ไหนมีข้อมูลของบรรทัดที่หน้าจอกำลังวาดอยู่
    wire bank_a_matches_display = bank_valid_a && (bank_y_a == display_y);
    wire bank_b_matches_display = bank_valid_b && (bank_y_b == display_y);
    
    // เลือก Bank ที่จะเอามาใช้งานผสมสีส่งออกจอ
    wire selected_bank = bank_a_matches_display ? 1'b0 :
                         bank_b_matches_display ? 1'b1 : current_bank;
                         
    // กำหนด Bank ที่ว่างอยู่ ให้วิ่งไป Prefetch ข้อมูลมารอ
    wire prefetch_target_bank = bank_a_matches_display ? 1'b1 :
                                bank_b_matches_display ? 1'b0 : ~current_bank;
                                
    wire any_bank_has_desired =
        (bank_valid_a && (bank_y_a == desired_prefetch_y)) ||
        (bank_valid_b && (bank_y_b == desired_prefetch_y));

    // ฟังก์ชันช่วยคำนวณ Address 1D จากพิกัด 2D (สูตร Y*320 + X แบบใช้ Shift ประหยัดตัวคูณ)
    function [16:0] make_addr;
        input [7:0] y;
        input [8:0] x;
        begin
            make_addr = ({9'd0, y} << 8) + ({9'd0, y} << 6) + {8'd0, x}; // Y*256 + Y*64 + X
        end
    endfunction

    // บล็อกการทำงานหลัก: จัดการดึงข้อมูลจาก Framebuffer หลักมาใส่ Row Buffer ตัวที่ว่างอยู่
    always @(posedge clk) begin
        if (rd_pending) begin
            // เอาข้อมูลที่ตอบกลับมาจาก RAM ยัดลง Bank ที่เลือกไว้
            if (!pending_bank) begin
                if (!pending_row) row0_a[pending_x] <= fb_data;
                else              row1_a[pending_x] <= fb_data;
            end else begin
                if (!pending_row) row0_b[pending_x] <= fb_data;
                else              row1_b[pending_x] <= fb_data;
            end

            rd_pending <= 1'b0;
            // ดึงครบทั้งบรรทัด (319) แล้วหรือยัง?
            if (pending_row && (pending_x == FRAME_WIDTH-1)) begin
                prefetch_busy <= 1'b0; // ดึงครบ 2 แถว (row0, row1) แล้ว แจ้งว่า Bank นี้พร้อมใช้งาน
                if (!pending_bank) begin
                    bank_valid_a <= 1'b1;
                    bank_y_a <= prefetch_y;
                end else begin
                    bank_valid_b <= 1'b1;
                    bank_y_b <= prefetch_y;
                end
            end else if (pending_x == FRAME_WIDTH-1) begin
                prefetch_row <= 1'b1; // ดึงแถวแรกเสร็จแล้ว สลับไปดึงแถวที่สอง (row1) ต่อ
                prefetch_x <= 9'd0;
            end else begin
                prefetch_x <= pending_x + 9'd1; // ขยับไปพิกเซลต่อไปแนวนอน
            end
        end else if (prefetch_busy) begin
            // ส่ง Address ไปขอข้อมูลจาก RAM หลัก
            fb_addr <= make_addr(prefetch_row ? ((prefetch_y == 8'd239) ? 8'd239 : prefetch_y + 8'd1) : prefetch_y, prefetch_x);
            pending_bank <= prefetch_bank;
            pending_row <= prefetch_row;
            pending_x <= prefetch_x;
            rd_pending <= 1'b1; // รอ RAM ตอบกลับใน Clock ถัดไป
            
        end else if (frame_ready && !any_bank_has_desired) begin
            // เริ่มต้นกระบวนการ Prefetch สำหรับบรรทัดใหม่
            prefetch_busy <= 1'b1;
            prefetch_bank <= prefetch_target_bank;
            prefetch_y <= desired_prefetch_y;
            prefetch_x <= 9'd0;
            prefetch_row <= 1'b0;
            if (!prefetch_target_bank) bank_valid_a <= 1'b0;
            else                       bank_valid_b <= 1'b0;
        end

        // อัปเดตสถานะ Bank ปัจจุบันจังหวะที่หน้าจอเริ่มปัดหัวอ่านกลับมาต้นบรรทัด
        if (active_video && (sx == 11'd0) && (sy[1:0] == 2'b00)) begin
            if (!current_bank && bank_valid_a && (bank_y_a == display_y)) begin
                current_valid <= 1'b1;
                current_y <= display_y;
            end else if (current_bank && bank_valid_b && (bank_y_b == display_y)) begin
                current_valid <= 1'b1;
                current_y <= display_y;
            end else if (!current_bank && bank_valid_b && (bank_y_b == display_y)) begin
                current_bank <= 1'b1; // สลับ Bank!
                current_valid <= 1'b1;
                current_y <= display_y;
            end else if (current_bank && bank_valid_a && (bank_y_a == display_y)) begin
                current_bank <= 1'b0; // สลับ Bank!
                current_valid <= 1'b1;
                current_y <= display_y;
            end else begin
                current_valid <= 1'b0;
            end
        end
    end

    // ========================================================================
    // ส่วนที่ 3: คณิตศาสตร์ Bilinear Interpolation (ผสมสี 4 จุด)
    // ========================================================================
    wire [8:0] raw_src_x = sx[10:2]; // เอาพิกัด X จอใหญ่ มาหาร 4 เพื่อหาตำแหน่งพิกเซลต้นฉบับ
    
    // ป้องกัน Noise ตรงขอบจอด้านซ้าย (แก้ปัญหาขอบภาพสั่น)
    wire [8:0] src_x = (raw_src_x == 9'd0) ? 9'd1 : raw_src_x;
    
    // หาตำแหน่งพิกเซลถัดไปทางขวา (X+1) โดยต้องไม่เกินขอบขวาสุด (319)
    wire [8:0] src_x1 = (src_x == 9'd319) ? 9'd319 : (src_x + 9'd1);
    
    // เอาเศษจากการหาร 4 (คือ 2 บิตล่าง) มาเป็นค่าน้ำหนัก (Fraction: 0, 1, 2, 3) เพื่อดูว่าจุดผสมอยู่ใกล้พิกเซลไหนมากกว่ากัน
    wire [1:0] frac_x = sx[1:0]; 
    wire [1:0] frac_y = sy[1:0]; 

    // ดึงสีของจุด 4 มุม มาเตรียมไว้
    // p00 (ซ้ายบน), p10 (ขวาบน)
    // p01 (ซ้ายล่าง), p11 (ขวาล่าง)
    wire [11:0] p00 = !selected_bank ? row0_a[src_x]  : row0_b[src_x];
    wire [11:0] p10 = !selected_bank ? row0_a[src_x1] : row0_b[src_x1];
    wire [11:0] p01 = !selected_bank ? row1_a[src_x]  : row1_b[src_x];
    wire [11:0] p11 = !selected_bank ? row1_a[src_x1] : row1_b[src_x1];

    // ------------------------------------------------------------------------
    // ฟังก์ชันวิเศษ: ผสมสีแนวนอน 2 จุด (Horizontal Mix) แบบไม่ต้องใช้ Multiplier!
    // การ Shift ซ้าย 1 ที (<< 1) คือการคูณ 2 ในทางดิจิทัล
    // ------------------------------------------------------------------------
    function [5:0] hmix4;
        input [3:0] a;
        input [3:0] b;
        input [1:0] frac;
        begin
            case (frac)
                2'd0: hmix4 = {a, 2'b00};                                        // ตรงเป๊ะที่พิกเซลซ้าย: เอา A มา 100% (A * 4)
                2'd1: hmix4 = ({2'b00, a} << 1) + {2'b00, a} + {2'b00, b};       // ขยับมา 1/4: เอา A มา 3 ส่วน, B มา 1 ส่วน (2A + A + B = 3A+1B)
                2'd2: hmix4 = ({2'b00, a} << 1) + ({2'b00, b} << 1);             // อยู่ตรงกลางเป๊ะ 2/4: เอา A มา 2 ส่วน, B มา 2 ส่วน (2A + 2B)
                default: hmix4 = {2'b00, a} + ({2'b00, b} << 1) + {2'b00, b};    // ขยับมา 3/4 (ใกล้จุดขวา): เอา A มา 1 ส่วน, B มา 3 ส่วน (1A + 3B)
            endcase
        end
    endfunction

    // ------------------------------------------------------------------------
    // ฟังก์ชันผสมสีแนวตั้ง 2 จุด (Vertical Mix)
    // เอาผลลัพธ์แนวนอนบน-ล่างมาผสมกันอีกที เพื่อให้เสร็จสมบูรณ์
    // ------------------------------------------------------------------------
    function [3:0] vmix4;
        input [5:0] top_scaled;
        input [5:0] bottom_scaled;
        input [1:0] frac;
        reg [7:0] scaled16;
        begin
            case (frac)
                2'd0: scaled16 = {top_scaled, 2'b00};
                2'd1: scaled16 = ({2'b00, top_scaled} << 1) + {2'b00, top_scaled} + {2'b00, bottom_scaled};
                2'd2: scaled16 = ({2'b00, top_scaled} << 1) + ({2'b00, bottom_scaled} << 1);
                default: scaled16 = {2'b00, top_scaled} + ({2'b00, bottom_scaled} << 1) + {2'b00, bottom_scaled};
            endcase
            vmix4 = scaled16[7:4]; // หั่นบิตออก 4 บิต (เทียบเท่ากับการหาร 16 เพื่อคืนค่ากลับมาเป็นเลข 4 บิตเหมือนเดิม)
        end
    endfunction

    // ทำการผสมสีทีละชาแนล (แยก แดง, เขียว, น้ำเงิน ทำอิสระต่อกัน)
    // 1. ผสมแนวนอนแถวบน
    wire [5:0] r_top = hmix4(p00[11:8], p10[11:8], frac_x);
    // 2. ผสมแนวนอนแถวล่าง
    wire [5:0] r_bot = hmix4(p01[11:8], p11[11:8], frac_x);
    // (ทำแบบเดียวกันกับ Green และ Blue)
    wire [5:0] g_top = hmix4(p00[7:4], p10[7:4], frac_x);
    wire [5:0] g_bot = hmix4(p01[7:4], p11[7:4], frac_x);
    wire [5:0] b_top = hmix4(p00[3:0], p10[3:0], frac_x);
    wire [5:0] b_bot = hmix4(p01[3:0], p11[3:0], frac_x);

    // 3. เอาแถวบนกับแถวล่างมาผสมกันในแนวตั้ง ประกอบร่างกลับเป็น RGB 12 บิต!
    assign rgb = {
        vmix4(r_top, r_bot, frac_y),
        vmix4(g_top, g_bot, frac_y),
        vmix4(b_top, b_bot, frac_y)
    };
    
    // ตรวจสอบความถูกต้องว่าข้อมูลพร้อมส่งออกพอร์ต VGA 
    assign valid = frame_ready && active_video &&
                   ((bank_a_matches_display && !selected_bank) ||
                    (bank_b_matches_display && selected_bank));
endmodule