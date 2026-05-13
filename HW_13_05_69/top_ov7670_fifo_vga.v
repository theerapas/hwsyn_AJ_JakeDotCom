`timescale 1ns / 1ps

// ============================================================================
// โมดูลหลัก (Top-level): ไปป์ไลน์ประมวลผลวิดีโอสำหรับ Basys 3 + OV7670
// 
// สถาปัตยกรรม Clock Domains (แยก 3 โดเมนชัดเจน):
// 1. CLK100MHZ   : ใช้คุมวงจรตั้งค่ากล้อง (SCCB) และเป็นตัวต้นทางสร้าง Clock อื่นๆ
// 2. cam_pclk_buf: ใช้คุมวงจร "ฝั่งขาเข้า" (Capture) รับภาพตามจังหวะที่กล้องส่งมา
// 3. clk108      : ใช้คุมวงจร "ฝั่งขาออก" (VGA & Scaler) วาดจอ 1280x960 ที่ 60Hz
// ============================================================================
module top_ov7670_fifo_vga (
    // สัญญาณพื้นฐานจากบอร์ด
    input  wire CLK100MHZ,      // Clock หลักของบอร์ด 100 MHz
    input  wire [7:0] sw,       // สวิตช์ 8 ตัวสำหรับเลือกโหมดแสดงผล

    // กลุ่มสัญญาณรับจากกล้อง (ทำงานตามจังหวะ cam_pclk_buf)
    input  wire [7:0] cam_d,        // ข้อมูลสี 8 บิต
    input  wire       cam_vsync,    // สัญญาณเริ่มเฟรมใหม่
    input  wire       cam_href,     // สัญญาณบอกช่วงข้อมูลบรรทัดที่ Valid
    input  wire       cam_pclk_buf, // นาฬิกาที่กล้องสร้างให้ (ผ่าน Clock Buffer แล้ว)

    // กลุ่มสัญญาณควบคุมกล้อง
    output wire       cam_xclk,     // นาฬิกาป้อนให้กล้องทำงาน (25 MHz)
    output wire       cam_reset,    // รีเซ็ตฮาร์ดแวร์กล้อง
    output wire       cam_pwdn,     // โหมดประหยัดพลังงาน (ดึงลงกราวด์ = ทำงานตลอด)
    output wire       cam_sioc,     // สัญญาณนาฬิกา SCCB (I2C)
    inout  wire       cam_siod,     // ข้อมูล SCCB (I2C) สองทิศทาง

    // กลุ่มสัญญาณส่งออกจอ VGA
    output wire [3:0] vgaRed,
    output wire [3:0] vgaGreen,
    output wire [3:0] vgaBlue,
    output wire       Hsync,
    output wire       Vsync,

    // ไฟสถานะ LED
    output wire [15:0] led
);

    // ============================================================================
    // ส่วนที่ 1: การจัดการ Clock (Clock Generation)
    // ============================================================================
    
    // สร้าง 25 MHz สำหรับป้อนให้กล้องทำงาน (cam_xclk) 
    // ทำโดยการนำ 100 MHz มานับหาร 4 (ใช้บิตที่ 1 ของ div4)
    reg [1:0] div4 = 2'b00;
    always @(posedge CLK100MHZ) div4 <= div4 + 2'd1;
    wire clk25 = div4[1];

    // สร้าง 108 MHz สำหรับจอ VGA ระดับ HD (1280x960 @ 60Hz)
    // ใช้ MMCM ภายใน FPGA ในการปั่นความถี่ขึ้นมา
    wire clk108;
    wire clk108_locked;
    vga_clock_108 clk108_u (
        .clk100 (CLK100MHZ),
        .clk108 (clk108),
        .locked (clk108_locked) // สถานะบอกว่า MMCM ปั่น Clock นิ่งพร้อมใช้แล้ว
    );

    assign cam_xclk  = clk25; // จ่าย 25 MHz ให้กล้อง
    assign cam_pwdn  = 1'b0;  // ปลุกกล้องให้ตื่นตลอดเวลา

    // ============================================================================
    // ส่วนที่ 2: วงจรตั้งค่ากล้องตอนเปิดเครื่อง (SCCB Configurator)
    // ============================================================================
    wire cam_init_done;
    ov7670_init_controller init_u (
        .clk       (CLK100MHZ),
        .reset     (1'b0),
        .colorbar  (sw[5]),         // สับสวิตช์ 5 เพื่อสั่งรีเซ็ตและเปิดแถบสีทดสอบ
        .camera_reset (cam_reset),
        .sioc      (cam_sioc),
        .siod      (cam_siod),
        .init_done (cam_init_done)  // 1 = ตั้งค่ากล้อง 80 กว่าคำสั่งเสร็จแล้ว
    );

    // ============================================================================
    // ส่วนที่ 3: วงจรสร้างจังหวะหน้าจอ VGA (VGA Timing Generator)
    // ทำงานที่ 108 MHz เพื่อสร้างพิกัดของจอ 1280x960
    // ============================================================================
    wire [10:0] sx; // พิกัดแกน X (0-1799)
    wire [9:0]  sy; // พิกัดแกน Y (0-999)
    wire       active_video; // 1 = อยู่ในพื้นที่แสดงผลภาพ (ไม่ใช่ช่วงขอบจอดำ)

    vga_640x480 vga_u (
        .clk25        (clk108),     // **ชื่อพอร์ต clk25 แต่เรายัด 108 MHz เข้าไปแทน**
        .sx           (sx),
        .sy           (sy),
        .hsync        (Hsync),
        .vsync        (Vsync),
        .active_video (active_video),
        .frame_start  ()
    );

    // ============================================================================
    // ส่วนที่ 4: หน่วยความจำภาพ (Framebuffer)
    // จอง RAM ภายในชิป (Block RAM) เพื่อเก็บภาพขนาด 320x240 พิกเซล
    // แต่ละพิกเซลใช้สี 12 บิต (RGB444)
    // ============================================================================
    localparam FRAME_WIDTH  = 320;
    localparam FRAME_HEIGHT = 240;
    localparam FRAME_PIXELS = 76800;
    
    // คำสั่งบังคับให้ Vivado ใช้ทรัพยากร BRAM แทนที่จะใช้ Flip-flop ธรรมดา
    (* ram_style = "block" *) reg [11:0] framebuffer [0:FRAME_PIXELS-1];

    // ตัวแปรกลุ่มตรวจสอบสถานะสัญญาณกล้อง (ใช้ต่อกับ LED ไว้ Debug)
    reg pclk_activity = 1'b0;
    reg pclk_seen     = 1'b0;
    reg href_seen     = 1'b0;
    reg vsync_seen    = 1'b0;
    reg frame_seen    = 1'b0;
    reg pixel_seen    = 1'b0;
    reg frame_ready   = 1'b0;

    // ตัวแปรสำหรับวงจรรับภาพ
    reg       byte_phase = 1'b0; // โหมด RGB565 ต้องรับ 2 ไบต์ต่อ 1 พิกเซล (0=ไบต์แรก, 1=ไบต์สอง)
    reg       href_d = 1'b0;
    reg [7:0] byte_hi = 8'h00;   // เก็บข้อมูลไบต์บนรอไว้ผสมกับไบต์ล่าง
    reg [9:0] cap_x = 10'd0;     // ตัวนับพิกัด X ขาเข้า (0-639)
    reg [8:0] cap_y = 9'd0;      // ตัวนับพิกัด Y ขาเข้า (0-479)

    // รีจิสเตอร์สำหรับแก้ปัญหา Metastability (หน่วงสัญญาณ 1 จังหวะ)
    reg       latched_vsync = 1'b0;
    reg       latched_href = 1'b0;
    reg [7:0] latched_d = 8'h00;

    always @(negedge cam_pclk_buf) begin
        latched_vsync <= cam_vsync;
        latched_href <= cam_href;
        latched_d <= cam_d;
    end

    // **เทคนิค Downsampling (ย่อภาพก่อนเก็บลง RAM)**
    // กล้องส่งมา 640x480 แต่เราเลื่อนบิตไปทางขวา 1 ครั้ง (หาร 2) 
    // ทำให้เก็บข้อมูลลง RAM แค่พิกัด 320x240 (ทิ้งพิกเซลสลับกันไป)
    wire [8:0] cap_dst_x = cap_x[9:1]; 
    wire [7:0] cap_dst_y = cap_y[8:1]; 

    // สูตรคำนวณตำแหน่ง 1D Array จากพิกัด 2D (Address = y*320 + x)
    wire [16:0] wr_addr = ({9'd0, cap_dst_y} << 8) + ({9'd0, cap_dst_y} << 6) + {8'd0, cap_dst_x};

    // ============================================================================
    // ส่วนที่ 5: วงจรรับภาพจากกล้องเข้า BRAM (Camera Capture Domain)
    // ทำงานภายใต้ความเร็วของกล้อง (cam_pclk_buf)
    // ============================================================================
    always @(posedge cam_pclk_buf) begin
        pclk_activity <= ~pclk_activity;
        pclk_seen <= 1'b1;
        href_d <= latched_href;
        
        if (latched_href)  href_seen <= 1'b1;
        if (latched_vsync) vsync_seen <= 1'b1;

        if (!cam_init_done) begin
            // ถ้ากล้องยังตั้งค่าไม่เสร็จ ห้ามทำอะไรทั้งนั้น
            byte_phase <= 1'b0;
            cap_x <= 10'd0;
            cap_y <= 9'd0;
            frame_ready <= 1'b0;
            pixel_seen <= 1'b0;
        end else if (latched_vsync) begin
            // ขึ้นเฟรมใหม่ รีเซ็ตพิกัดหัวเขียนกลับไปที่ (0,0)
            byte_phase <= 1'b0;
            cap_x <= 10'd0;
            cap_y <= 9'd0;
            if (pixel_seen) begin
                frame_seen <= 1'b1;
                frame_ready <= 1'b1; // สัญญาณบอกว่าได้ภาพเต็มๆ มา 1 เฟรมแล้ว
            end
            pixel_seen <= 1'b0;
        end else if (latched_href) begin
            // ช่วงที่มีพิกเซลไหลเข้ามา
            if (!byte_phase) begin
                byte_hi <= latched_d; // เก็บไบต์แรก (MSB) ไว้ก่อน
                byte_phase <= 1'b1;
            end else begin
                byte_phase <= 1'b0;
                if ((cap_x < 10'd640) && (cap_y < 9'd480)) begin
                    // เงื่อนไขนี้คือการดักเก็บเฉพาะพิกเซลที่เป็นเลขคู่ (0, 2, 4...) 
                    // เพื่อย่อภาพให้เหลือ 320x240 ตามขนาด RAM ที่เรามี
                    if (!cap_x[0] && !cap_y[0] && (cap_dst_x < FRAME_WIDTH) && (cap_dst_y < FRAME_HEIGHT)) begin
                        framebuffer[wr_addr] <= rgb565_to_rgb444(byte_hi, latched_d); // แปลงสีแล้วยัดลง RAM
                        if ((byte_hi != 8'h00) || (latched_d != 8'h00))
                            pixel_seen <= 1'b1;
                    end
                    cap_x <= cap_x + 10'd1;
                end
            end
        end else begin
            byte_phase <= 1'b0;
            cap_x <= 10'd0;
            if (href_d && !latched_href && (cap_y < 9'd479))
                cap_y <= cap_y + 9'd1; // จบบรรทัด ปัด Y ลงมา 1 แถว
        end
    end

    // ============================================================================
    // ส่วนที่ 6: วงจรอ่านภาพและขยายขนาด (Bilinear Upscaler Domain)
    // ทำงานภายใต้ความเร็วหน้าจอ HD (clk108)
    // ============================================================================
    wire [16:0] scaler_fb_addr;
    reg  [11:0] scaler_fb_data = 12'h000;
    wire [11:0] scaled_rgb;
    wire        scaled_valid;

    // อ่านข้อมูลจาก RAM ตามตำแหน่งที่ Scaler ร้องขอ
    always @(posedge clk108) begin
        scaler_fb_data <= framebuffer[scaler_fb_addr];
    end

    // พระเอกของ Extra Credit: ขยายภาพ 320x240 ให้เต็มจอ 1280x960 แบบเนียนตา
    bilinear_upscaler_4x scaler_u (
        .clk          (clk108),
        .frame_ready  (frame_ready),
        .sx           (sx),
        .sy           (sy),
        .active_video (active_video),
        .fb_addr      (scaler_fb_addr), // Scaler ขอตำแหน่งอ่าน
        .fb_data      (scaler_fb_data), // ข้อมูลจาก RAM ส่งให้ Scaler
        .rgb          (scaled_rgb),     // สีพิกเซลที่คำนวณ Bilinear เสร็จแล้ว
        .valid        (scaled_valid)
    );

    // ============================================================================
    // ส่วนที่ 7: ระบบฟิลเตอร์และปรับสมดุลสี (Image Processing Pipeline)
    // ============================================================================
    reg [11:0] camera_rgb = 12'h000;
    reg [11:0] balanced_rgb = 12'h000;
    reg [11:0] filtered_rgb = 12'h000;
    reg [11:0] test_rgb = 12'h000;
    reg [11:0] live_rgb = 12'h000;

    // ฟังก์ชันแปลงฟอร์แมตสีจากกล้อง (RGB565) ให้เป็นของบอร์ด (RGB444)
    // โดยตัดบิตที่ความละเอียดต่ำสุดทิ้งไป
    function [11:0] rgb565_to_rgb444;
        input [7:0] hi;
        input [7:0] lo;
        reg [3:0] r4, g4, b4;
        begin
            r4 = hi[7:4];
            g4 = {hi[2:0], lo[7]};
            b4 = lo[4:1];
            rgb565_to_rgb444 = {r4, g4, b4};
        end
    endfunction

    // ฟังก์ชันใส่ฟิลเตอร์ตามสวิตช์ SW[4:2] (ขาวดำ, อินเวอร์ส, แยกสี RGB)
    function [11:0] apply_filter; ... endfunction

    // ฟังก์ชันตัวช่วยคำนวณคณิตศาสตร์แบบไม่ให้ค่าติดลบหรือล้น (Saturating Math)
    function [3:0] sub_sat4; ... endfunction
    function [3:0] add_sat4; ... endfunction

    // ฟังก์ชันปรับสมดุลแสง ลดนอยส์เม็ดสีแดงในที่มืด และลดความอมม่วงของกล้อง
    function [11:0] color_balance; ... endfunction

    // ฟังก์ชันลดความจัดจ้านของสี (Desaturate) เพื่อให้ภาพดูสมจริงขึ้น
    function [11:0] soft_desaturate; ... endfunction

    // ไปป์ไลน์ก่อนส่งออกจอ
    always @(posedge clk108) begin
        // สร้างลวดลายแถบสี Color Bar ภายในบอร์ดเอง (เอาไว้เช็คจอ)
        if (sx < 160)       test_rgb <= 12'hF00;
        else if (sx < 320)  test_rgb <= 12'h0F0;
        ... // (ตัดทอนโค้ดเพื่อความกระชับ)
        else               test_rgb <= 12'h888;

        // วงจรตรวจสอบสัญญาณภาพดิบๆ (Debug)
        live_rgb <= { ... };

        if (active_video && scaled_valid && clk108_locked) begin
            camera_rgb <= scaled_rgb; // เอาภาพที่ขยาย 4x มาเป็นตัวตั้งต้น
            // นำภาพไปผ่านการปรับสมดุล (ถ้าไม่ได้เปิดโหมด Color bar กล้อง)
            balanced_rgb <= sw[5] ? camera_rgb : soft_desaturate(color_balance(camera_rgb));
            // นำภาพที่สมดุลแล้วไปผ่านฟิลเตอร์เอฟเฟกต์
            filtered_rgb <= apply_filter(balanced_rgb, sw[4:2]);
        end else begin
            camera_rgb <= 12'h000;
            balanced_rgb <= 12'h000;
            filtered_rgb <= 12'h000;
        end
    end

    // ============================================================================
    // ส่วนที่ 8: พอร์ตส่งออก (Outputs)
    // ============================================================================
    
    // Mux เลือกว่าจะส่งภาพไหนออกพอร์ต VGA ตามสวิตช์ SW[0] และ SW[1]
    assign vgaRed   = (active_video && clk108_locked) ? (sw[0] ? test_rgb[11:8] : (sw[1] ? live_rgb[11:8] : filtered_rgb[11:8])) : 4'h0;
    assign vgaGreen = (active_video && clk108_locked) ? (sw[0] ? test_rgb[7:4]  : (sw[1] ? live_rgb[7:4]  : filtered_rgb[7:4]))  : 4'h0;
    assign vgaBlue  = (active_video && clk108_locked) ? (sw[0] ? test_rgb[3:0]  : (sw[1] ? live_rgb[3:0]  : filtered_rgb[3:0]))  : 4'h0;

    // เชื่อมต่อสัญญาณไฟ LED เพื่อใช้มอนิเตอร์ฮาร์ดแวร์ตอน Debug
    assign led[0]  = cam_init_done; // ถ้าไฟดวงนี้ติดแปลว่า SCCB ตั้งค่าเสร็จ
    assign led[1]  = vsync_seen;
    assign led[2]  = href_seen;
    assign led[3]  = pclk_activity;
    assign led[4]  = cam_vsync;
    ... // (ตัดทอนโค้ดเพื่อความกระชับ)
    assign led[15] = sw[5];

endmodule