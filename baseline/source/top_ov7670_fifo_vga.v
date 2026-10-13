`timescale 1ns / 1ps


// ============================================================================
// Top-level video pipeline สำหรับบอร์ด Basys 3 + กล้อง OV7670
// ทำหน้าที่เป็นศูนย์กลางเชื่อมต่อ Clock Domains และประมวลผลท่อข้อมูลภาพ (Pipeline)
// ============================================================================
module top_ov7670_fifo_vga (
    // ------------------------------------------------------------------------
    // กลุ่มที่ 1: ขาพินเชื่อมต่อโลกภายนอก (I/O Ports)
    // ------------------------------------------------------------------------
    // สัญญาณนาฬิกาหลักของบอร์ด 100 MHz และสวิตช์สไลด์ 8 ตัว
    input  wire CLK100MHZ,
    input  wire [7:0] sw,


    // สัญญาณที่รับเข้ามาจากกล้อง (Data 8 บิต, สัญญาณเริ่มเฟรม, ข้อมูลบรรทัด, นาฬิกากล้อง)
    input  wire [7:0] cam_d,        // (Camera Data) สายส่งข้อมูลสีขนาน 8 เส้น (โหมด RGB565 ส่ง 1 พิกเซล/16 บิต โดยแบ่งส่ง 2 รอบ รอบละ 8 บิต)
    input  wire       cam_vsync,    // (Vertical Sync) สัญญาณบอก "เริ่มเฟรมภาพใหม่" (กระเด้งเป็น 1 เพื่อให้ FPGA ดึงหัวเขียนกลับมุมซ้ายบนสุด)
    input  wire       cam_href,     // (Horizontal Ref) สัญญาณบอก "ช่วงที่มีข้อมูลภาพ" (1 = ดึงสีไปเก็บได้, 0 = ช่วงขอบจอดำ/ปัดบรรทัด)
    input  wire       cam_pclk_buf, // (Pixel Clock) นาฬิกาที่กล้องสร้าง เคาะบอก FPGA ว่าข้อมูลสีนิ่งแล้ว (ดึงเข้า Clock Buffer เพื่อให้นิ่งขึ้น)


    // สัญญาณควบคุมที่ส่งกลับไปให้กล้อง (นาฬิกาอ้างอิง, รีเซ็ต, ดึงลงกราวด์ให้ทำงานตลอด)
    output wire       cam_xclk,     // (System Clock) นาฬิกาหลักความถี่ 25 MHz ที่ FPGA ต้องจ่ายไปเลี้ยงให้กล้องทำงาน
    output wire       cam_reset,    // (Hardware Reset) สายรีเซ็ตกล้อง (Active-Low: 0 = คืนค่าโรงงาน, 1 = ทำงานปกติ)
    output wire       cam_pwdn,     // (Power Down) สายสั่งโหมดประหยัดไฟ (Active-High: ในโปรเจกต์นี้ดึงเป็น 0 ถาวรเพื่อให้กล้องตื่นตลอดเวลา)
   
   
    // สาย I2C/SCCB สำหรับเขียน Register ตั้งค่ากล้อง
    output wire       cam_sioc,     // (Serial Clock) นาฬิกาจัดจังหวะส่งข้อมูลตั้งค่า (FPGA เป็นคนคุมจังหวะและส่งออกทางเดียว)
    inout  wire       cam_siod,     // (Serial Data) สายรับ-ส่งข้อมูล 2 ทิศทาง (FPGA ดึงสายเป็น 0 หรือปล่อยลอย High-Z เพื่อให้กล้องตอบ ACK)


    // สัญญาณส่งออกพอร์ต VGA (สีละ 4 บิต และสัญญาณกวาดหน้าจอ)
    output wire [3:0] vgaRed,       // สายส่งข้อมูลสีแดง 4 บิต (แสดงผลร่วมกัน 12 บิต = 4,096 สี)
    output wire [3:0] vgaGreen,     // สายส่งข้อมูลสีเขียว 4 บิต
    output wire [3:0] vgaBlue,      // สายส่งข้อมูลสีน้ำเงิน 4 บิต
    output wire       Hsync,        // (Horizontal Sync) สัญญาณเคาะจบแนวนอน (บอกจอคอมฯ ให้ปัดหัวอ่านกลับไปซ้ายสุดเพื่อเริ่มบรรทัดใหม่)
    output wire       Vsync,        // (Vertical Sync) สัญญาณเคาะจบแนวตั้ง (บอกจอคอมฯ ให้ดึงหัวอ่านกลับไปบนสุดเพื่อเริ่มเฟรมภาพใหม่)


    // หลอดไฟ LED 16 ดวงสำหรับ Debug ดูสถานะฮาร์ดแวร์
    output wire [15:0] led
);


    // ============================================================================
    // กลุ่มที่ 2: สร้างสัญญาณนาฬิกา 25 MHz (Clock Divider)
    // ============================================================================
    // ใช้ตัวนับ 2 บิต (นับ 0-3) เพื่อหารความถี่จาก 100 MHz ลง 4 เท่า
    reg [1:0] div4 = 2'b00;
    always @(posedge CLK100MHZ) div4 <= div4 + 2'd1;


    // ดึงบิตสูงสุดมาใช้งาน จะได้ Clock 25 MHz สำหรับจอ VGA และให้กล้องอ้างอิง
    wire clk25 = div4[1];


    // จ่าย Clock 25 MHz ให้กล้อง และดึงขา Power Down (pwdn) เป็น 0 เพื่อปลุกกล้อง
    assign cam_xclk  = clk25;
    assign cam_pwdn  = 1'b0;


    // ============================================================================
    // กลุ่มที่ 3: เรียกใช้โมดูลตั้งค่ากล้อง (SCCB Init Controller)
    // ============================================================================
    wire cam_init_done; // ตัวแปรเก็บสถานะว่าตั้งค่ากล้องเสร็จหรือยัง
   
    // ส่งคำสั่งจาก ROM ไปตังค่ากล้อง OV7670 ให้เป็นโหมด RGB565 ผ่าน SCCB
    ov7670_init_controller init_u (
        .clk       (CLK100MHZ),
        .reset     (1'b0),
        .colorbar  (sw[5]),       // สับสวิตช์ 5 เพื่อบังคับกล้องส่งแถบสีทดสอบ
        .camera_reset (cam_reset),
        .sioc      (cam_sioc),
        .siod      (cam_siod),
        .init_done (cam_init_done) // แจ้งกลับเมื่อตั้งค่าเสร็จ วงจรรับภาพถึงจะเริ่มทำงาน
    );








    // ============================================================================
    // กลุ่มที่ 4: เรียกใช้โมดูลสร้างพิกัดหน้าจอ VGA
    // ============================================================================
    wire [9:0] sx, sy;       // ตัวเก็บพิกัดแกน X และ Y ปัจจุบันของหัวอ่านจอภาพ
    wire       active_video; // สัญญาณบอกว่าหัวอ่านอยู่ในพื้นที่แสดงภาพ (ไม่ใช่ขอบดำ)
   
    // สร้างจังหวะกวาดจอ (Hsync/Vsync) สำหรับความละเอียด 640x480
    vga_640x480 vga_u (
        .clk25        (clk25),
        .sx           (sx),
        .sy           (sy),
        .hsync        (Hsync),
        .vsync        (Vsync),
        .active_video (active_video),
        .frame_start  ()
    );


    // ============================================================================
    // กลุ่มที่ 5: หน่วยความจำภาพ (Block RAM Framebuffer)
    // ============================================================================
    localparam FRAME_WIDTH  = 320;
    localparam FRAME_HEIGHT = 240;
    localparam FRAME_PIXELS = 76800; // จำนวนพิกเซลทั้งหมด (320 * 240)
   
    // สร้างอาร์เรย์เก็บข้อมูลสี 12 บิต จำนวน 76,800 ช่อง
    // คำสั่ง ram_style="block" บังคับให้ Vivado สังเคราะห์เป็น BRAM ภายในชิป
    (* ram_style = "block" *) reg [11:0] framebuffer [0:FRAME_PIXELS-1];


    // ============================================================================
    // กลุ่มที่ 6: ตัวแปรสำหรับวงจรดักจับภาพ (Capture Domain Registers)
    // ============================================================================
    // ตัวแปรกลุ่มนี้ใช้ตรวจสอบว่ามีสัญญาณนาฬิกาและข้อมูลส่งมาจากกล้องจริงๆ หรือไม่
    reg pclk_activity = 1'b0;
    reg pclk_seen     = 1'b0;
    reg href_seen     = 1'b0;
    reg vsync_seen    = 1'b0;
    reg frame_seen    = 1'b0;
    reg pixel_seen    = 1'b0;
    reg frame_ready   = 1'b0;


    // ตัวแปรสำหรับประกอบร่างพิกเซล
    reg       byte_phase = 1'b0; // ใช้บอกว่ากำลังรับข้อมูล 8 บิตชุดแรกหรือชุดหลัง (0 หรือ 1)
    reg       href_d = 1'b0;     // เก็บค่า href รอบที่แล้วเพื่อจับจังหวะขอบขาลง (จบบรรทัด)
    reg [7:0] byte_hi = 8'h00;   // เก็บข้อมูล 8 บิตชุดแรกทดไว้รอชุดที่สอง
    reg [9:0] cap_x = 10'd0;     // ตัวนับพิกัดแนวนอนของกล้อง (0-639)
    reg [8:0] cap_y = 9'd0;      // ตัวนับพิกัดแนวตั้งของกล้อง (0-479)




    // ============================================================================
    // ด่านที่ 6.1: ล็อกสัญญาณกันรบกวน (Latching on Negedge PCLK)
    // ============================================================================
    reg       latched_vsync = 1'b0;
    reg       latched_href = 1'b0;
    reg [7:0] latched_d = 8'h00;
   
    // ทำงานตอนขอบขาลงของนาฬิกากล้อง (ช่วงที่สัญญาณสายไฟนิ่งที่สุด)
    // ดึงค่ามาพักไว้ในตลับ Register เพื่อกันภาพล้มจากสัญญาณกวน (Noise)
    always @(negedge cam_pclk_buf) begin
        latched_vsync <= cam_vsync;
        latched_href <= cam_href;
        latched_d <= cam_d;
    end


    // ============================================================================
    // ด่านที่ 6.2: คำนวณที่อยู่เขียนหน่วยความจำ (Write Address)
    // ============================================================================
    // ตัดบิตล่างสุดทิ้ง ([9:1]) มีค่าเท่ากับหาร 2
    // เป็นการลดขนาดภาพ (Downsampling) จาก 640x480 เหลือ 320x240
    wire [8:0] cap_dst_x = cap_x[9:1];
    wire [7:0] cap_dst_y = cap_y[8:1];
   
    // คำนวณตำแหน่ง 1 มิติด้วยสูตร Address = (Y * 320) + X
    // ใช้เทคนิค Bit Shift แทนวงจรคูณ: (Y * 256) + (Y * 64) + X ประหยัด Logic Gate
    wire [16:0] wr_addr =
        ({9'd0, cap_dst_y} << 8) + ({9'd0, cap_dst_y} << 6) + {8'd0, cap_dst_x};


    // ============================================================================
    // ด่านที่ 6.3: วงจรเก็บเกี่ยวข้อมูลภาพ (Core Capture Logic on Posedge PCLK)
    // ============================================================================
    // ทำงานตอนขอบขาขึ้นของนาฬิกากล้อง
    always @(posedge cam_pclk_buf) begin
        pclk_activity <= ~pclk_activity; // กระพริบเพื่อเช็คว่า Clock ทำงาน
        pclk_seen <= 1'b1;
        href_d <= latched_href;          // อัปเดต href_d ของรอบที่แล้ว
       
        if (latched_href)  href_seen <= 1'b1;
        if (latched_vsync) vsync_seen <= 1'b1;


        // สถานะที่ 1: ถ้ากล้องยัง Init ไม่เสร็จ ให้รีเซ็ตระบบรับภาพรอไปก่อน
        if (!cam_init_done) begin
            byte_phase <= 1'b0;
            cap_x <= 10'd0;
            cap_y <= 9'd0;
            frame_ready <= 1'b0;
            pixel_seen <= 1'b0;
       
        // สถานะที่ 2: เจอ Vsync (เริ่มภาพใหม่) ให้ดึงหัวเขียนกลับไปมุมซ้ายบน
        end else if (latched_vsync) begin
            byte_phase <= 1'b0;
            cap_x <= 10'd0;
            cap_y <= 9'd0;
            // ถ้ารอบที่แล้วมีพิกเซลเข้ามาจริง แจ้งหน้าจอ VGA ว่ามีภาพพร้อมให้ดึงไปวาดแล้ว
            if (pixel_seen) begin
                frame_seen <= 1'b1;
                frame_ready <= 1'b1;
            end
            pixel_seen <= 1'b0;


        // สถานะที่ 3: กำลังรับข้อมูลสี (Href เป็น Logic 1)
        end else if (latched_href) begin
           
            // จังหวะรับไบต์แรก (ครึ่งบน)
            if (!byte_phase) begin
                byte_hi <= latched_d; // เก็บข้อมูลทดไว้ก่อน
                byte_phase <= 1'b1;   // สลับเฟสเพื่อรอรับครึ่งหลัง
               
            // จังหวะรับไบต์ที่สอง (ครึ่งล่าง) นำมาประกอบกัน
            end else begin
                byte_phase <= 1'b0; // สลับเฟสกลับ
               
                // ตรวจสอบว่าพิกัดไม่ออกนอกจอ
                if ((cap_x < 10'd640) && (cap_y < 9'd480)) begin
                   
                    // เงื่อนไข Downsampling: จะเขียนลง BRAM ก็ต่อเมื่อพิกัด X และ Y เป็น "เลขคู่"
                    // (!cap_x[0] หมายถึงบิตล่างสุดเป็น 0) ข้ามพิกเซลช่องคี่ทิ้งไปเลย
                    if (!cap_x[0] && !cap_y[0] && (cap_dst_x < FRAME_WIDTH) && (cap_dst_y < FRAME_HEIGHT)) begin
                        // นำ 2 ไบต์มาแปลงสีเหลือ 12 บิต แล้วยัดลงล็อกเกอร์ BRAM
                        framebuffer[wr_addr] <= rgb565_to_rgb444(byte_hi, latched_d);
                        if ((byte_hi != 8'h00) || (latched_d != 8'h00))
                            pixel_seen <= 1'b1; // ตรวจสอบว่าภาพไม่ใช่สีดำล้วน
                    end
                    cap_x <= cap_x + 10'd1; // ขยับหัวเขียนแนวนอนไปทางขวา 1 ช่อง
                end
            end
           
        // สถานะที่ 4: จบบรรทัด (Href ตกจาก 1 เป็น 0)
        end else begin
            byte_phase <= 1'b0;
            cap_x <= 10'd0; // ดึงหัวเขียนกลับไปซ้ายสุดของจอ
           
            // ใช้เทคนิคตรวจขอบขาลง (Falling edge detection) ของ Href
            // ถ้ารอบที่แล้วเป็น 1 รอบนี้เป็น 0 ให้ปัดหัวเขียนลงมาบรรทัดล่าง
            if (href_d && !latched_href && (cap_y < 9'd479))
                cap_y <= cap_y + 9'd1;
        end
    end


    // ============================================================================
    // กลุ่มที่ 7: คำนวณที่อยู่เพื่ออ่านข้อมูลไปแสดงจอ VGA (Read Address)
    // ============================================================================
    // นำพิกัดจอภาพ 640x480 มาหาร 2 (ตัดบิตล่างทิ้ง)
    // ทำให้เกิดเอฟเฟกต์ Pixel Doubling ขยายภาพ 320x240 ให้เต็มจออัตโนมัติ
    wire [8:0] src_x = sx[9:1];
    wire [7:0] src_y = sy[8:1];
   
    // คำนวณตำแหน่ง 1 มิติด้วยสูตร (Y * 320) + X สำหรับดึงข้อมูลออกจาก BRAM
    wire [16:0] rd_addr =
        ({9'd0, src_y} << 8) + ({9'd0, src_y} << 6) + {8'd0, src_x};


    // เตรียมตัวแปร Pipeline เป็นจุดพักข้อมูลก่อนส่งออกจอ
    reg [11:0] camera_rgb = 12'h000;   // รับภาพดิบจาก BRAM
    reg [11:0] balanced_rgb = 12'h000; // รับภาพที่แก้สีเพี้ยนแล้ว
    reg [11:0] filtered_rgb = 12'h000; // รับภาพที่ใส่ฟิลเตอร์ผู้ใช้แล้ว
    reg [11:0] test_rgb = 12'h000;     // เก็บภาพแถบสีจำลอง
    reg [11:0] live_rgb = 12'h000;     // เก็บภาพสดไม่ผ่าน BRAM (Debug)


    // ============================================================================
    // กลุ่มที่ 8: ฟังก์ชันย่อยคณิตศาสตร์และประมวลผลภาพ (Helper Functions)
    // ============================================================================
   
    // 8.1 ฟังก์ชันลดบิตสีจาก 16 บิต (RGB565) ให้เป็น 12 บิต (RGB444) เพื่อประหยัด BRAM
    function [11:0] rgb565_to_rgb444;
        input [7:0] hi;
        input [7:0] lo;
        reg [3:0] r4; reg [3:0] g4; reg [3:0] b4;
        begin
            r4 = hi[7:4];           // ดึงแดง 4 บิตบน
            g4 = {hi[2:0], lo[7]};  // ประกอบเขียว 4 บิตบน
            b4 = lo[4:1];           // ดึงน้ำเงิน 4 บิตบน
            rgb565_to_rgb444 = {r4, g4, b4};
        end
    endfunction


    // 8.2 ฟังก์ชันใส่ฟิลเตอร์วิดีโอ (เลือกได้จากสวิตช์ sw[4:2])
    function [11:0] apply_filter;
        input [11:0] rgb;
        input [2:0] mode;
        reg [3:0] gray;
        begin
            // สร้างสีเทาโดยนำ R+G+B แล้วหาร 4 (Shift right 2)
            gray = ({2'b00, rgb[11:8]} + {2'b00, rgb[7:4], 1'b0} + {2'b00, rgb[3:0]}) >> 2;
            case (mode)
                3'b001: apply_filter = {gray, gray, gray};      // โหมดขาวดำ
                3'b010: apply_filter = ~rgb;                    // โหมดสีตรงข้าม (Invert)
                3'b011: apply_filter = {rgb[11:8], 8'h00};      // ดึงมาแค่ช่องสีแดง
                3'b100: apply_filter = {4'h0, rgb[7:4], 4'h0};  // ดึงมาแค่ช่องสีเขียว
                3'b101: apply_filter = {8'h00, rgb[3:0]};       // ดึงมาแค่ช่องสีน้ำเงิน
                default: apply_filter = rgb;                    // ภาพปกติ
            endcase
        end
    endfunction


    // 8.3 ฟังก์ชันลบเลขแบบอิ่มตัว (Saturating Subtract) ป้องกันค่าติดลบแล้ววนกลับไปค่าสูงสุด
    function [3:0] sub_sat4;
        input [3:0] value;
        input [3:0] amount;
        begin
            sub_sat4 = (value > amount) ? (value - amount) : 4'h0;
        end
    endfunction


    // 8.4 ฟังก์ชันบวกเลขแบบอิ่มตัว (Saturating Add) ป้องกันค่าเกิน 15 (0xF)
    function [3:0] add_sat4;
        input [3:0] value;
        input [3:0] amount;
        reg [4:0] sum;
        begin
            sum = {1'b0, value} + {1'b0, amount};
            add_sat4 = sum[4] ? 4'hF : sum[3:0];
        end
    endfunction


    // 8.5 ฟังก์ชันปรับแก้สีเพี้ยน (แก้ปัญหาจุดแดงในที่มืดของเซนเซอร์ราคาถูก)
    function [11:0] color_balance;
        input [11:0] rgb;
        reg [3:0] r; reg [3:0] g; reg [3:0] b;
        reg [3:0] max_ch; reg [5:0] sum_ch;
        reg [4:0] r_ext; reg [4:0] g_ext; reg [4:0] b_ext;
        reg       red_dominant; reg       low_light; reg       purple_dominant;
        begin
            r = rgb[11:8]; g = rgb[7:4]; b = rgb[3:0];
            max_ch = (r > g) ? ((r > b) ? r : b) : ((g > b) ? g : b);
            sum_ch = {2'b00, r} + {2'b00, g} + {2'b00, b};
            r_ext = {1'b0, r}; g_ext = {1'b0, g}; b_ext = {1'b0, b};
           
            // เช็คว่าพิกเซลนี้มีสีไหนโดดเด่น หรือเป็นที่มืด
            red_dominant = (r_ext > g_ext + 5'd1) && (r_ext > b_ext + 5'd1);
            low_light = (max_ch < 4'hB);
            purple_dominant = (r_ext > g_ext + 5'd1) && (b_ext > g_ext + 5'd1);


            // ถ้ามืดมากและมีจุดแดงโผล่มา ให้กดสีให้ดำสนิทไปเลย
            if ((max_ch < 4'h2) || (sum_ch < 6'd5) || (low_light && (g < 4'h3) && (b < 4'h3) && red_dominant)) begin
                color_balance = 12'h000;
            // ถ้าภาพติดม่วง ให้ลดแดงกับน้ำเงิน เพิ่มเขียว
            end else if (purple_dominant) begin
                r = sub_sat4(r, 4'h1); b = sub_sat4(b, 4'h1);
                if (g < 4'hE) g = add_sat4(g, 4'h1);
                color_balance = {r, g, b};
            // ถ้าภาพติดแดง ให้ลดแดง
            end else if (red_dominant) begin
                if (max_ch < 4'hC) r = sub_sat4(r, 4'h2);
                else r = sub_sat4(r, 4'h1);
                color_balance = {r, g, b};
            end else begin
                color_balance = {r, g, b};
            end
        end
    endfunction


    // 8.6 ฟังก์ชันลดความอิ่มตัวของสี (ให้ภาพดูเป็นธรรมชาติขึ้น)
    function [11:0] soft_desaturate;
        input [11:0] rgb;
        reg [3:0] r; reg [3:0] g; reg [3:0] b; reg [3:0] gray;
        reg [4:0] r_ext; reg [4:0] g_ext; reg [4:0] b_ext; reg [4:0] gray_ext;
        begin
            r = rgb[11:8]; g = rgb[7:4]; b = rgb[3:0];
            gray = ({2'b00, r} + {2'b00, g, 1'b0} + {2'b00, b}) >> 2;
            r_ext = {1'b0, r}; g_ext = {1'b0, g}; b_ext = {1'b0, b}; gray_ext = {1'b0, gray};


            // ดึงสี R, G, B แต่ละช่องให้เข้าใกล้ค่าสีเทา (Gray) ของพิกเซลนั้นๆ เล็กน้อย
            if (r_ext > gray_ext + 5'd1) r = sub_sat4(r, 4'h1);
            else if (gray_ext > r_ext + 5'd1) r = add_sat4(r, 4'h1);


            if (g_ext > gray_ext + 5'd1) g = sub_sat4(g, 4'h1);
            else if (gray_ext > g_ext + 5'd1) g = add_sat4(g, 4'h1);


            if (b_ext > gray_ext + 5'd1) b = sub_sat4(b, 4'h1);
            else if (gray_ext > b_ext + 5'd1) b = add_sat4(b, 4'h1);


            soft_desaturate = {r, g, b};
        end
    endfunction


    // ============================================================================
    // กลุ่มที่ 9: ท่อประมวลผลก่อนส่งออกจอ (VGA Output Pipeline)
    // ============================================================================
    // ทำงานภายใต้ความเร็วจอภาพ (25 MHz)
    always @(posedge clk25) begin
       
        // 9.1 จำลองหน้าจอแถบสี (อิงพิกัดจากแกน X) เอาไว้เทสสาย VGA
        if (sx < 80)       test_rgb <= 12'hF00;
        else if (sx < 160) test_rgb <= 12'h0F0;
        else if (sx < 240) test_rgb <= 12'h00F;
        else if (sx < 320) test_rgb <= 12'hFF0;
        else if (sx < 400) test_rgb <= 12'h0FF;
        else if (sx < 480) test_rgb <= 12'hF0F;
        else if (sx < 560) test_rgb <= 12'hFFF;
        else               test_rgb <= 12'h888;


        // 9.2 ดึงสัญญาณสดจากสายไฟกล้องมาประกอบเป็นสี (Live Feed) ข้าม BRAM ไปเลย
        live_rgb <= {
            cam_vsync ? 4'hF : cam_d[7:4],
            cam_href  ? 4'hF : cam_d[3:0],
            pclk_seen ? 4'hF : 4'h0
        };


        // 9.3 ท่อประมวลผลหลัก (ทำงานเฉพาะตอนหัวอ่านอยู่ในหน้าจอแสดงผล)
        if (active_video && frame_ready) begin
            camera_rgb <= framebuffer[rd_addr]; // ขั้น 1: ดึงภาพจาก BRAM
           
            // ขั้น 2: ถ้าไม่ได้เทสแถบสีกล้อง (sw[5]) ให้รันผ่านฟังก์ชันแก้สี
            balanced_rgb <= sw[5] ? camera_rgb : soft_desaturate(color_balance(camera_rgb));
           
            // ขั้น 3: ใส่ฟิลเตอร์สีตามสวิตช์ผู้ใช้ (sw[4:2])
            filtered_rgb <= apply_filter(balanced_rgb, sw[4:2]);
        end else begin
            // ถ้าหัวอ่านอยู่นอกจอภาพ ให้ดับสีเป็นสีดำ (ป้องกันจอขึ้นเส้นประหลาด)
            camera_rgb <= 12'h000;
            balanced_rgb <= 12'h000;
            filtered_rgb <= 12'h000;
        end
    end


    // ============================================================================
    // กลุ่มที่ 10: วงจรเลือกสัญญาณออกจอภาพ (Output Multiplexers)
    // ============================================================================
    // ใช้คำสั่งเงื่อนไข ? : ซ้อนกันเพื่อทำหน้าที่เหมือนวงจร MUX แบบฮาร์ดแวร์
    // ลำดับความสำคัญ:
    // 1. ถ้าอยู่นอก active_video ส่งสี 0 (ดำ) ทันที
    // 2. ถ้า sw[0]=1 ส่งภาพแถบสีจำลอง test_rgb (ใช้ได้แม้ไม่ต่อกล้อง)
    // 3. ถ้า sw[1]=1 ส่งภาพดิบ live_rgb
    // 4. นอกเหนือจากนั้น ส่งภาพที่ผ่านฟิลเตอร์สมบูรณ์ filtered_rgb
    assign vgaRed   = active_video ? (sw[0] ? test_rgb[11:8] : (sw[1] ? live_rgb[11:8] : filtered_rgb[11:8])) : 4'h0;
    assign vgaGreen = active_video ? (sw[0] ? test_rgb[7:4]  : (sw[1] ? live_rgb[7:4]  : filtered_rgb[7:4]))  : 4'h0;
    assign vgaBlue  = active_video ? (sw[0] ? test_rgb[3:0]  : (sw[1] ? live_rgb[3:0]  : filtered_rgb[3:0]))  : 4'h0;


    // ============================================================================
    // กลุ่มที่ 11: แผนที่ดวงไฟ LED (Hardware Debug Map)
    // ============================================================================
    // เชื่อมต่อสถานะต่างๆ ลงไฟ LED บนบอร์ดเพื่อให้วิศวกรมองเห็นปัญหาได้ทันที
    assign led[0]  = cam_init_done; // สว่าง = กล้องคอนฟิกเสร็จแล้ว
    assign led[1]  = vsync_seen;    // สว่าง = รับรู้สัญญาณเฟรมใหม่
    assign led[2]  = href_seen;     // สว่าง = รับรู้สัญญาณข้อมูลบรรทัด
    assign led[3]  = pclk_activity; // กระพริบรัว = สัญญาณนาฬิกากล้องเดิน
    assign led[4]  = cam_vsync;     // ไฟติดดับตามจังหวะขึ้นเฟรมใหม่
    assign led[5]  = cam_href;      // ไฟติดดับตามจังหวะวาดบรรทัด
    assign led[6]  = cam_d[7];      // ดึงบิตสีบิตนึงมาเทสการขยับ
    assign led[7]  = sw[0];         // ดูสถานะสวิตช์โหมด
    assign led[8]  = frame_seen;    // สว่าง = เก็บภาพลง BRAM สำเร็จแล้ว
    assign led[9]  = pixel_seen;    // สว่าง = กล้องไม่ได้ส่งภาพมาแค่มืดๆ
    assign led[10] = cam_href;
    assign led[11] = pclk_seen;
    assign led[12] = sw[1];
    assign led[14:13] = sw[7:6];
    assign led[15] = sw[5];


endmodule
