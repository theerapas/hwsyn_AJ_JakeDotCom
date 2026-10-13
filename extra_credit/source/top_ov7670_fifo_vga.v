`timescale 1ns / 1ps

// Top-level video pipeline for Basys 3 + OV7670.
// โมดูลระดับบนสุด (Top-level) สำหรับจัดการไปป์ไลน์วิดีโอของบอร์ด Basys 3 และกล้อง OV7670
//
// Clock domains:
// โดเมนสัญญาณนาฬิกา (แบ่งการทำงานเป็น 3 จังหวะหลัก):
// - CLK100MHZ drives SCCB camera configuration and creates derived clocks.
//   (100 MHz ใช้ตั้งค่ากล้องผ่าน SCCB และสร้าง Clock ความถี่อื่นๆ)
// - cam_pclk_buf captures camera data in the OV7670 pixel clock domain.
//   (รับภาพเข้ามาตามจังหวะ PCLK ที่กล้องส่งมาให้)
// - clk108 drives 1280x960 VGA timing and bilinear framebuffer readout.
//   (108 MHz ใช้สร้างสัญญาณจอ VGA ขนาด 1280x960 และใช้อ่านข้อมูลภาพไปขยายขนาด)
//
// Video path:
// เส้นทางการไหลของข้อมูลวิดีโอ:
// OV7670 RGB565 stream -> 320x240 RGB444 framebuffer -> 4x bilinear scaler ->
// optional calibration, gentle desaturation, and image filter -> 1280x960 VGA.
// (รับภาพ RGB565 -> ย่อเก็บลง RAM 320x240 เป็น RGB444 -> ขยาย 4 เท่าด้วย Bilinear -> ปรับสมดุลสี/ใส่ฟิลเตอร์ -> ส่งออกจอ 1280x960)
module top_ov7670_fifo_vga (
    input  wire CLK100MHZ,      // สัญญาณนาฬิกาหลักจากบอร์ด 100 MHz
    input  wire [7:0] sw,       // สวิตช์บนบอร์ด 8 ตัว สำหรับเลือกโหมด

    // สัญญาณที่รับมาจากกล้อง OV7670
    input  wire [7:0] cam_d,        // ข้อมูลพิกเซลสี 8 บิต
    input  wire       cam_vsync,    // สัญญาณซิงค์แนวตั้ง (เริ่มเฟรมภาพใหม่)
    input  wire       cam_href,     // สัญญาณซิงค์แนวนอน (บอกช่วงที่มีข้อมูลสี)
    input  wire       cam_pclk_buf, // สัญญาณนาฬิกา Pixel Clock จากกล้อง

    // สัญญาณควบคุมที่ส่งไปให้กล้อง OV7670
    output wire       cam_xclk,     // สัญญาณนาฬิกา 25 MHz จ่ายให้กล้อง
    output wire       cam_reset,    // สัญญาณรีเซ็ตกล้อง
    output wire       cam_pwdn,     // สัญญาณโหมดประหยัดพลังงาน (ดึง 0 เพื่อให้ทำงาน)
    output wire       cam_sioc,     // สัญญาณนาฬิกา SCCB (I2C) สำหรับตั้งค่า
    inout  wire       cam_siod,     // สัญญาณข้อมูล SCCB (I2C) แบบ 2 ทิศทาง

    // สัญญาณส่งออกจอ VGA
    output wire [3:0] vgaRed,       // สีแดง 4 บิต
    output wire [3:0] vgaGreen,     // สีเขียว 4 บิต
    output wire [3:0] vgaBlue,      // สีน้ำเงิน 4 บิต
    output wire       Hsync,        // สัญญาณซิงค์แนวนอนของจอคอม
    output wire       Vsync,        // สัญญาณซิงค์แนวตั้งของจอคอม

    output wire [15:0] led        // หลอดไฟ LED บนบอร์ด สำหรับดูสถานะการทำงาน
);

    // Switch map:
    // การทำงานของสวิตช์แต่ละตัว:
    // sw[0] selects FPGA-generated VGA test bars. (สลับดูภาพแถบสีทดสอบที่บอร์ดสร้างเอง)
    // sw[1] selects a raw live camera-signal debug view. (สลับดูข้อมูลดิบๆ ที่มาจากกล้องเพื่อใช้ Debug)
    // sw[4:2] selects normal/grayscale/invert/R/G/B output filters. (เลือกฟิลเตอร์ภาพ ขาวดำ/สลับสี/แยกสี)
    // sw[5] enables the OV7670 internal color-bar test pattern. (สั่งให้กล้องส่งภาพแถบสีออกมา / สับเพื่อรีเซ็ตกล้อง)
    // sw[7:6] are currently unused, but mirrored on LEDs for visibility. (ยังไม่ได้ใช้งาน แต่โชว์ไฟ LED ไว้)

    // Divide the 100 MHz board clock by 4 for the OV7670 external clock.
    // วงจรหารความถี่นาฬิกา 100 MHz ให้เหลือ 25 MHz เพื่อจ่ายไปเลี้ยงตัวกล้อง
    reg [1:0] div4 = 2'b00;
    always @(posedge CLK100MHZ) div4 <= div4 + 2'd1;

    wire clk25 = div4[1]; // ดึงบิตที่ 1 มาใช้ จะได้ความถี่หาร 4 พอดี (25 MHz)
    
    // สายสัญญาณสำหรับ Clock 108 MHz
    wire clk108;
    wire clk108_locked;

    // เรียกใช้โมดูล MMCM ปั่นความถี่ 100 MHz ขึ้นเป็น 108 MHz สำหรับจอ HD
    vga_clock_108 clk108_u (
        .clk100 (CLK100MHZ),
        .clk108 (clk108),
        .locked (clk108_locked) // เป็น 1 เมื่อความถี่ 108 MHz นิ่งพร้อมใช้งานแล้ว
    );

    // OV7670 requires an external clock. 25 MHz works with the register
    // configuration used in ov7670_init_rom.v.
    // จ่ายไฟ 25 MHz ให้กล้อง และดึงพิน Power Down ลงกราวด์เพื่อให้กล้องทำงานตลอด
    assign cam_xclk  = clk25;
    assign cam_pwdn  = 1'b0;

    wire cam_init_done; // สัญญาณบอกว่าตั้งค่า Register กล้องเสร็จแล้ว

    // เรียกใช้โมดูลตั้งค่ากล้องผ่าน SCCB ตอนเปิดเครื่อง
    ov7670_init_controller init_u (
        .clk       (CLK100MHZ),
        .reset     (1'b0),
        .colorbar  (sw[5]),         // สวิตช์ 5 สั่งเปิดโหมดแถบสีของกล้อง
        .camera_reset (cam_reset),
        .sioc      (cam_sioc),
        .siod      (cam_siod),
        .init_done (cam_init_done)
    );

    wire [10:0] sx;             // พิกัด X ของจอภาพ
    wire [9:0]  sy;             // พิกัด Y ของจอภาพ
    wire       active_video;    // สัญญาณบอกว่ากำลังวาดอยู่ในพื้นที่แสดงผล (ไม่ใช่ขอบจอดำ)

    // เรียกใช้โมดูลสร้างจังหวะจอ VGA (แก้ไส้ในเป็น 1280x960 แล้ว แต่ยังคงชื่อเดิมไว้)
    vga_640x480 vga_u (
        .clk25        (clk108), // ป้อน Clock 108 MHz เข้าไปแทน
        .sx           (sx),
        .sy           (sy),
        .hsync        (Hsync),
        .vsync        (Vsync),
        .active_video (active_video),
        .frame_start  ()
    );

    localparam FRAME_WIDTH  = 320;
    localparam FRAME_HEIGHT = 240;
    localparam FRAME_PIXELS = 76800; // 320 * 240 พิกเซล

    // Store a 320x240 RGB444 frame. The camera is configured for a VGA-sized
    // stream, and the capture logic keeps every other source row/column.
    // ประกาศสร้าง Framebuffer (หน่วยความจำแรม) เก็บภาพขนาด 320x240 สี 12 บิต
    // คำสั่ง ram_style = "block" บังคับให้ Vivado ใช้ทรัพยากร BRAM ในชิป
    (* ram_style = "block" *) reg [11:0] framebuffer [0:FRAME_PIXELS-1];

    // กลุ่มตัวแปรสำหรับจับสถานะและตรวจสอบสัญญาณขาเข้าจากกล้อง
    reg pclk_activity = 1'b0;
    reg pclk_seen     = 1'b0;
    reg href_seen     = 1'b0;
    reg vsync_seen    = 1'b0;
    reg frame_seen    = 1'b0;
    reg pixel_seen    = 1'b0;
    reg frame_ready   = 1'b0; // 1 = เก็บภาพลง RAM ครบ 1 เฟรมแล้ว

    reg       byte_phase = 1'b0; // สถานะรับข้อมูล (0 = รับไบต์แรกครึ่งบน, 1 = รับไบต์สองครึ่งล่าง)
    reg       href_d = 1'b0;     // สถานะ HREF ในอดีต (เอาไว้เช็คขอบขาลง)
    reg [7:0] byte_hi = 8'h00;   // ตัวแปรพักข้อมูลครึ่งบนของ RGB565
    reg [9:0] cap_x = 10'd0;     // ตัวนับพิกัด X ขาเข้า (กล้องส่งมา 640)
    reg [8:0] cap_y = 9'd0;      // ตัวนับพิกัด Y ขาเข้า (กล้องส่งมา 480)

    // รีจิสเตอร์สำหรับแก้ปัญหาความไม่เสถียรของสัญญาณ (Metastability / Latch)
    reg       latched_vsync = 1'b0;
    reg       latched_href = 1'b0;
    reg [7:0] latched_d = 8'h00;

    // อ่านข้อมูลจากกล้องในจังหวะ "ขอบขาลง" (Falling Edge) ของ PCLK 
    // เพื่อให้ข้อมูลนิ่งที่สุดก่อนนำไปใช้ในจังหวะขอบขาขึ้น
    always @(negedge cam_pclk_buf) begin
        latched_vsync <= cam_vsync;
        latched_href <= cam_href;
        latched_d <= cam_d;
    end

    // เทคนิค Downsampling: เลื่อนบิตไปทางขวา 1 ที (หาร 2)
    // ย่อภาพจาก 640x480 ให้เหลือพิกัดเขียน 320x240 เพื่อประหยัดพื้นที่ RAM
    wire [8:0] cap_dst_x = cap_x[9:1];
    wire [7:0] cap_dst_y = cap_y[8:1];

    // คำนวณที่อยู่ (Address) ใน RAM 1 มิติ จากพิกัด 2 มิติ (Y*320 + X) โดยใช้วิธี Shift บิต
    wire [16:0] wr_addr =
        ({9'd0, cap_dst_y} << 8) + ({9'd0, cap_dst_y} << 6) + {8'd0, cap_dst_x};

    // Camera capture. Data is sampled on the falling PCLK edge and consumed on
    // the following rising edge, matching the timing style used by the reference
    // OV7670 capture design. Every other source column/row is stored to convert
    // the VGA-sized sensor stream into the required 320x240 frame.
    // ลอจิกบันทึกภาพลง RAM ทำงานจังหวะ PCLK ขอบขาขึ้น
    always @(posedge cam_pclk_buf) begin
        pclk_activity <= ~pclk_activity;
        pclk_seen <= 1'b1;
        href_d <= latched_href;
        if (latched_href)  href_seen <= 1'b1;
        if (latched_vsync) vsync_seen <= 1'b1;

        if (!cam_init_done) begin
            // ช่วงที่ยังตั้งค่ากล้องไม่เสร็จ ให้รีเซ็ตสถานะการรับภาพทั้งหมด
            byte_phase <= 1'b0;
            cap_x <= 10'd0;
            cap_y <= 9'd0;
            frame_ready <= 1'b0;
            pixel_seen <= 1'b0;
        end else if (latched_vsync) begin
            // เมื่อสัญญาณเริ่มเฟรมมา ให้ดึงหัวเขียนกลับไปที่พิกัด 0,0
            byte_phase <= 1'b0;
            cap_x <= 10'd0;
            cap_y <= 9'd0;
            if (pixel_seen) begin
                frame_seen <= 1'b1;
                frame_ready <= 1'b1; // รับภาพเสร็จสมบูรณ์ 1 เฟรม
            end
            pixel_seen <= 1'b0;
        end else if (latched_href) begin
            // ช่วงที่มีพิกเซลไหลเข้ามา
            if (!byte_phase) begin
                byte_hi <= latched_d;   // เก็บไบต์แรก (MSB) พักไว้ก่อน
                byte_phase <= 1'b1;     // เตรียมรับไบต์ที่สอง
            end else begin
                byte_phase <= 1'b0;     // รับไบต์ที่สองเสร็จแล้ว กลับไปรอไบต์แรกใหม่
                if ((cap_x < 10'd640) && (cap_y < 9'd480)) begin
                    // กรองเอาเฉพาะพิกเซลพิกัด "เลขคู่" (0, 2, 4, ...) เพื่อย่อภาพให้เล็กพอดี RAM
                    if (!cap_x[0] && !cap_y[0] && (cap_dst_x < FRAME_WIDTH) && (cap_dst_y < FRAME_HEIGHT)) begin
                        // แปลงสี RGB565 เป็น RGB444 แล้วเขียนลง Address ใน BRAM
                        framebuffer[wr_addr] <= rgb565_to_rgb444(byte_hi, latched_d);
                        if ((byte_hi != 8'h00) || (latched_d != 8'h00))
                            pixel_seen <= 1'b1;
                    end
                    cap_x <= cap_x + 10'd1; // ขยับพิกัด X ขาเข้า
                end
            end
        end else begin
            // หมดช่วงสัญญาณ HREF
            byte_phase <= 1'b0;
            cap_x <= 10'd0; // รีเซ็ตพิกัด X กลับต้นบรรทัด
            // ถ้าตรวจพบขอบขาลงของ HREF (href_d เป็น 1 แต่ latched_href เป็น 0) ให้ปัดแถว Y ขึ้น 1 บรรทัด
            if (href_d && !latched_href && (cap_y < 9'd479))
                cap_y <= cap_y + 9'd1;
        end
    end

    // ตัวแปรสำหรับสื่อสารระหว่าง RAM หลัก กับ โมดูลขยายภาพ Bilinear
    wire [16:0] scaler_fb_addr;
    reg  [11:0] scaler_fb_data = 12'h000;
    wire [11:0] scaled_rgb;
    wire        scaled_valid;

    // อ่านข้อมูลจาก BRAM ตาม Address ที่โมดูล Scaler ร้องขอมา (ทำงานเร็วระดับ 108 MHz)
    always @(posedge clk108) begin
        scaler_fb_data <= framebuffer[scaler_fb_addr];
    end

    // เรียกใช้โมดูลขยายภาพ 4 เท่าแบบ Bilinear Interpolation (320x240 -> 1280x960)
    bilinear_upscaler_4x scaler_u (
        .clk          (clk108),
        .frame_ready  (frame_ready),
        .sx           (sx),
        .sy           (sy),
        .active_video (active_video),
        .fb_addr      (scaler_fb_addr), // โมดูลส่ง Address มาขอพิกเซล
        .fb_data      (scaler_fb_data), // ส่งค่าสีกลับไปให้โมดูล
        .rgb          (scaled_rgb),     // ได้ค่าสีที่ผสมความเนียนเสร็จแล้วกลับมา
        .valid        (scaled_valid)
    );

    // รีจิสเตอร์จำค่าสีแต่ละขั้นตอน (Pipeline) สำหรับนำไปแสดงผล
    reg [11:0] camera_rgb = 12'h000;
    reg [11:0] balanced_rgb = 12'h000;
    reg [11:0] filtered_rgb = 12'h000;
    reg [11:0] test_rgb = 12'h000;
    reg [11:0] live_rgb = 12'h000;

    // Convert one OV7670 RGB565 pixel to the 12-bit RGB444 format used by the
    // framebuffer and VGA output.
    // ฟังก์ชันแปลงฟอร์แมตสีจากกล้อง (16 บิต) เป็นฟอร์แมตของบอร์ด (12 บิต) 
    // โดยตัดเศษบิตล่างสุดของแต่ละสีทิ้งไป
    function [11:0] rgb565_to_rgb444;
        input [7:0] hi;
        input [7:0] lo;
        reg [3:0] r4;
        reg [3:0] g4;
        reg [3:0] b4;
        begin
            r4 = hi[7:4];
            g4 = {hi[2:0], lo[7]};
            b4 = lo[4:1];
            rgb565_to_rgb444 = {r4, g4, b4};
        end
    endfunction

    // User-selectable filters. sw[4:2] selects normal, grayscale, inversion,
    // red-only, green-only, or blue-only video.
    // ฟังก์ชันสำหรับใส่ฟิลเตอร์ให้ภาพ (เลือกผ่านสวิตช์ SW4-SW2)
    function [11:0] apply_filter;
        input [11:0] rgb;
        input [2:0] mode;
        reg [3:0] gray;
        begin
            // คำนวณหาค่าเฉลี่ยสีเพื่อทำเป็นสีเทา (Grayscale)
            gray = ({2'b00, rgb[11:8]} + {2'b00, rgb[7:4], 1'b0} + {2'b00, rgb[3:0]}) >> 2;
            case (mode)
                3'b001: apply_filter = {gray, gray, gray};      // grayscale (ขาวดำ)
                3'b010: apply_filter = ~rgb;                    // color inversion (สลับสี/เนกาทีฟ)
                3'b011: apply_filter = {rgb[11:8], 8'h00};      // red channel (แสดงเฉพาะสีแดง)
                3'b100: apply_filter = {4'h0, rgb[7:4], 4'h0};  // green channel (แสดงเฉพาะสีเขียว)
                3'b101: apply_filter = {8'h00, rgb[3:0]};       // blue channel (แสดงเฉพาะสีน้ำเงิน)
                default: apply_filter = rgb;                    // normal color (ภาพปกติ)
            endcase
        end
    endfunction

    // Saturating subtract helper used by the camera color calibration.
    // ฟังก์ชันช่วยลบตัวเลขแบบมีลิมิต ป้องกันผลลบติดลบ (ม้วนหลับไปเป็นค่าสูงสุด)
    function [3:0] sub_sat4;
        input [3:0] value;
        input [3:0] amount;
        begin
            sub_sat4 = (value > amount) ? (value - amount) : 4'h0; // ถ้าลบแล้วต่ำกว่า 0 ให้ล็อคไว้ที่ 0
        end
    endfunction

    // Saturating add helper used by the camera color calibration.
    // ฟังก์ชันช่วยบวกตัวเลขแบบมีลิมิต ป้องกันผลบวกล้น (Overflow กลับไปเป็น 0)
    function [3:0] add_sat4;
        input [3:0] value;
        input [3:0] amount;
        reg [4:0] sum;
        begin
            sum = {1'b0, value} + {1'b0, amount};
            add_sat4 = sum[4] ? 4'hF : sum[3:0]; // ถ้าบวกแล้วเกินขีดจำกัด (บิตที่ 4 เด้ง) ให้ล็อคไว้ที่ค่าสูงสุด (F)
        end
    endfunction

    // Board-specific cleanup for the camera image before filters are applied.
    // The goal is intentionally modest: suppress low-light red speckles and
    // soften strong purple/red bias while preserving the live image.
    // ฟังก์ชันปรับสมดุลสีอัตโนมัติ (แก้ปัญหาสีเพี้ยนอมม่วง/แดง และจุดนอยส์แดงในที่มืด)
    function [11:0] color_balance;
        input [11:0] rgb;
        reg [3:0] r;
        reg [3:0] g;
        reg [3:0] b;
        reg [3:0] max_ch;
        reg [5:0] sum_ch;
        reg [4:0] r_ext;
        reg [4:0] g_ext;
        reg [4:0] b_ext;
        reg       red_dominant;
        reg       low_light;
        reg       purple_dominant;
        begin
            r = rgb[11:8];
            g = rgb[7:4];
            b = rgb[3:0];
            max_ch = (r > g) ? ((r > b) ? r : b) : ((g > b) ? g : b); // หาสีที่สว่างที่สุด
            sum_ch = {2'b00, r} + {2'b00, g} + {2'b00, b};            // ผลรวมความสว่าง
            r_ext = {1'b0, r};
            g_ext = {1'b0, g};
            b_ext = {1'b0, b};
            red_dominant = (r_ext > g_ext + 5'd1) && (r_ext > b_ext + 5'd1); // เช็คว่าสีแดงเด่นสุดไหม
            low_light = (max_ch < 4'hB); // เช็คว่าอยู่ในพื้นที่แสงน้อยหรือไม่
            purple_dominant = (r_ext > g_ext + 5'd1) && (b_ext > g_ext + 5'd1); // เช็คว่าสีอมม่วง (แดง+น้ำเงิน เด่งกว่าเขียว) หรือไม่

            // Board/camera calibration:
            // - clamp only the darkest pixels and red-only low-light speckles
            // - trim purple/red bias without crushing low-light detail
            // SW5 bypasses this path for raw sensor color-bar debugging.
            // ถ้ามืดจัด หรือเป็นนอยส์สีแดงในที่มืด ให้กดสีให้กลายเป็นดำสนิทไปเลย
            if ((max_ch < 4'h2) ||
                (sum_ch < 6'd5) ||
                (low_light && (g < 4'h3) && (b < 4'h3) && red_dominant)) begin
                color_balance = 12'h000; 
            end else if (purple_dominant) begin
                // ลดสีแดง/น้ำเงิน เพิ่มสีเขียว เพื่อแก้ความอมม่วง
                r = sub_sat4(r, 4'h1);
                b = sub_sat4(b, 4'h1);
                if (g < 4'hE)
                    g = add_sat4(g, 4'h1);
                color_balance = {r, g, b};
            end else if (red_dominant) begin
                // ลดความแดงลงนิดหน่อยเพื่อไม่ให้ภาพติดโทนร้อนเกินไป
                if (max_ch < 4'hC)
                    r = sub_sat4(r, 4'h2);
                else
                    r = sub_sat4(r, 4'h1);
                color_balance = {r, g, b};
            end else begin
                // สีปกติ ปล่อยผ่าน
                color_balance = {r, g, b};
            end
        end
    endfunction

    // Slightly reduce saturation by moving only strongly biased channels one
    // step toward luma. The deadband keeps normal colors from looking washed out.
    // ฟังก์ชันลดความสดของสี (Desaturate) ลงเล็กน้อย เพื่อให้ภาพดูเป็นธรรมชาติ ไม่แสบตาเกินไป
    function [11:0] soft_desaturate;
        input [11:0] rgb;
        reg [3:0] r;
        reg [3:0] g;
        reg [3:0] b;
        reg [3:0] gray;
        reg [4:0] r_ext;
        reg [4:0] g_ext;
        reg [4:0] b_ext;
        reg [4:0] gray_ext;
        begin
            r = rgb[11:8];
            g = rgb[7:4];
            b = rgb[3:0];
            gray = ({2'b00, r} + {2'b00, g, 1'b0} + {2'b00, b}) >> 2; // หาค่าเทา (ความสว่างเฉลี่ย)
            r_ext = {1'b0, r};
            g_ext = {1'b0, g};
            b_ext = {1'b0, b};
            gray_ext = {1'b0, gray};

            // ดึงค่าสีแต่ละสีให้วิ่งเข้าหาแกนสีเทาตรงกลางทีละนิด (ลบหรือบวก)
            if (r_ext > gray_ext + 5'd1)
                r = sub_sat4(r, 4'h1);
            else if (gray_ext > r_ext + 5'd1)
                r = add_sat4(r, 4'h1);

            if (g_ext > gray_ext + 5'd1)
                g = sub_sat4(g, 4'h1);
            else if (gray_ext > g_ext + 5'd1)
                g = add_sat4(g, 4'h1);

            if (b_ext > gray_ext + 5'd1)
                b = sub_sat4(b, 4'h1);
            else if (gray_ext > b_ext + 5'd1)
                b = add_sat4(b, 4'h1);

            soft_desaturate = {r, g, b};
        end
    endfunction

    // ขั้นตอนประมวลผลก่อนส่งภาพออกจอ (ทำงานด้วย Clock จอภาพ 108 MHz)
    always @(posedge clk108) begin
        // สร้างลวดลายแถบสี 8 สี (Color bars) สำหรับใช้ทดสอบจอ (โหมด SW0)
        if (sx < 160)       test_rgb <= 12'hF00;
        else if (sx < 320)  test_rgb <= 12'h0F0;
        else if (sx < 480)  test_rgb <= 12'h00F;
        else if (sx < 640)  test_rgb <= 12'hFF0;
        else if (sx < 800)  test_rgb <= 12'h0FF;
        else if (sx < 960)  test_rgb <= 12'hF0F;
        else if (sx < 1120) test_rgb <= 12'hFFF;
        else                test_rgb <= 12'h888;

        // ดึงภาพจากกล้องตรงๆ และแอบโชว์สัญญาณการซิงค์ภาพด้วย (โหมด SW1 เอาไว้ Debug จังหวะภาพ)
        live_rgb <= {
            cam_vsync ? 4'hF : cam_d[7:4],
            cam_href  ? 4'hF : cam_d[3:0],
            pclk_seen ? 4'hF : 4'h0
        };

        // ถ้าจอพร้อมวาด และ ภาพที่ผ่านตัวขยาย Bilinear มาเสร็จสมบูรณ์แล้ว
        if (active_video && scaled_valid && clk108_locked) begin
            camera_rgb <= scaled_rgb; // เอาสีจากวงจรขยาย (Scaler) มาตั้งต้น
            // The camera's own color bars bypass image cleanup so the test
            // pattern shows the raw configured sensor output.
            // นำภาพไปผ่านวงจรปรับสมดุลแสงสีและลดความจัดจ้าน (ยกเว้นตอนเปิดโหมด Color bar กล้องด้วย SW5)
            balanced_rgb <= sw[5] ? camera_rgb : soft_desaturate(color_balance(camera_rgb));
            // นำไปใส่ฟิลเตอร์ขั้นสุดท้าย (ตามสวิตช์ SW4-2)
            filtered_rgb <= apply_filter(balanced_rgb, sw[4:2]);
        end else begin
            // นอกพื้นที่หน้าจอ ให้ส่งค่าสีดำออกไป
            camera_rgb <= 12'h000;
            balanced_rgb <= 12'h000;
            filtered_rgb <= 12'h000;
        end
    end

    // ตัวเลือกแสดงผลสุดท้าย (Multiplexer): ดูจากสวิตช์ SW0 และ SW1 ว่าผู้ใช้ต้องการดูภาพแบบไหน 
    assign vgaRed   = (active_video && clk108_locked) ? (sw[0] ? test_rgb[11:8] : (sw[1] ? live_rgb[11:8] : filtered_rgb[11:8])) : 4'h0;
    assign vgaGreen = (active_video && clk108_locked) ? (sw[0] ? test_rgb[7:4]  : (sw[1] ? live_rgb[7:4]  : filtered_rgb[7:4]))  : 4'h0;
    assign vgaBlue  = (active_video && clk108_locked) ? (sw[0] ? test_rgb[3:0]  : (sw[1] ? live_rgb[3:0]  : filtered_rgb[3:0]))  : 4'h0;

    // LED debug map for bring-up: initialization, sync activity, pixel-clock
    // activity, frame detection, selected debug modes, and raw switch state.
    // นำสัญญาณต่างๆ มาต่อเข้าหลอด LED ให้สว่าง เพื่อมอนิเตอร์ฮาร์ดแวร์ด้วยสายตาเวลาบอร์ดทำงาน
    assign led[0]  = cam_init_done;
    assign led[1]  = vsync_seen;
    assign led[2]  = href_seen;
    assign led[3]  = pclk_activity;
    assign led[4]  = cam_vsync;
    assign led[5]  = cam_href;
    assign led[6]  = cam_d[7];
    assign led[7]  = sw[0];
    assign led[8]  = frame_seen;
    assign led[9]  = pixel_seen;
    assign led[10] = cam_href;
    assign led[11] = pclk_seen;
    assign led[12] = sw[1];
    assign led[14:13] = sw[7:6];
    assign led[15] = sw[5];

endmodule