`timescale 1ns / 1ps
// =============================================================================
// top_ov7670_fifo_vga.v
// -----------------------------------------------------------------------------
// Top-level module for the OV7670 -> Block-RAM frame buffer -> VGA pipeline
// running on the Basys 3 (Artix-7 XC7A35T).
//
// Pipeline:
//
//   OV7670 ----PCLK domain---- write port ----+
//                                             |
//                                             v
//                               framebuffer (BRAM, 320x240 x 12-bit RGB444)
//                                             |
//                                             v
//   VGA timing ----25 MHz domain---- read port ---> filters ---> VGA DAC pins
//
// Resolution: the framebuffer holds 320x240 pixels (QVGA). The VGA controller
// runs at the standard 640x480@60Hz. We pixel-double horizontally (sx>>1) and
// vertically (sy>>1) when reading the framebuffer, so each QVGA pixel covers
// a 2x2 block on the screen.
//
// Switches (slide switches sw[7:0]):
//   sw[0]      -> show internal VGA color bars (debug pattern)
//   sw[1]      -> show live raw HREF/VSYNC/PCLK signal viewer (debug)
//   sw[4:2]    -> filter mode applied to the camera image
//                   000 = normal (no filter)
//                   001 = grayscale
//                   010 = color inversion (negative)
//                   011 = red-only channel
//                   100 = green-only channel
//                   101 = blue-only channel
//   sw[5]      -> OV7670 internal color-bar test pattern (changing this re-runs
//                 the camera init sequence)
//   sw[7:6]    -> camera output decode mode
//                   00 = RGB565 (default, recommended)
//                   01 = RGB565 with byte swap
//                   10 = YUYV
//                   11 = UYVY
// =============================================================================

module top_ov7670_fifo_vga (
    // ---------------- Board clock ----------------
    input  wire CLK100MHZ,        // 100 MHz from the on-board oscillator

    // ---------------- User switches ----------------
    input  wire [7:0] sw,         // slide switches (see header for mapping)

    // ---------------- OV7670 camera input bus ----------------
    input  wire [7:0] cam_d,      // 8-bit parallel pixel data
    input  wire       cam_vsync,  // frame-start sync from camera
    input  wire       cam_href,   // active-line indicator from camera
    input  wire       cam_pclk_buf, // pixel clock from camera (used as a clock!)

    // ---------------- OV7670 control / config ----------------
    output wire       cam_xclk,   // 25 MHz reference clock TO the camera
    output wire       cam_reset,  // active-low reset to camera
    output wire       cam_pwdn,   // power-down (kept low = active)
    output wire       cam_sioc,   // SCCB clock (I2C-like SCL)
    inout  wire       cam_siod,   // SCCB data  (I2C-like SDA, open-drain)

    // ---------------- VGA outputs ----------------
    output wire [3:0] vgaRed,     // 4-bit red DAC
    output wire [3:0] vgaGreen,   // 4-bit green DAC
    output wire [3:0] vgaBlue,    // 4-bit blue DAC
    output wire       Hsync,      // horizontal sync
    output wire       Vsync,      // vertical sync

    // ---------------- Debug LEDs ----------------
    output wire [15:0] led
);

    // -------------------------------------------------------------------------
    // 1) Clock generation: divide the 100 MHz system clock down to 25 MHz.
    //    The camera needs ~24 MHz on XCLK; 25 MHz is well within spec.
    //    The same 25 MHz clock drives the VGA pixel timing.
    // -------------------------------------------------------------------------
    reg [1:0] div4 = 2'b00;
    always @(posedge CLK100MHZ) div4 <= div4 + 2'd1;

    wire clk25 = div4[1];        // 100 MHz / 4 = 25 MHz

    assign cam_xclk = clk25;     // feed 25 MHz to camera XCLK
    assign cam_pwdn = 1'b0;      // never power down

    // -------------------------------------------------------------------------
    // 2) Camera initialisation (SCCB writes the OV7670 register table)
    // -------------------------------------------------------------------------
    wire cam_init_done;          // goes high after the full register list is sent

    ov7670_init_controller init_u (
        .clk          (CLK100MHZ),
        .reset        (1'b0),
        .colorbar     (sw[5]),     // toggle on-sensor color-bar test pattern
        .camera_reset (cam_reset),
        .sioc         (cam_sioc),
        .siod         (cam_siod),
        .init_done    (cam_init_done)
    );

    // -------------------------------------------------------------------------
    // 3) VGA timing generator (640x480 @ 60 Hz from a 25 MHz pixel clock)
    // -------------------------------------------------------------------------
    wire [9:0] sx, sy;            // current pixel coordinates on screen
    wire       active_video;      // 1 when sx<640 && sy<480 (visible region)
    wire       frame_start;       // 1 for one cycle at the top of each frame

    vga_640x480 vga_u (
        .clk25        (clk25),
        .sx           (sx),
        .sy           (sy),
        .hsync        (Hsync),
        .vsync        (Vsync),
        .active_video (active_video),
        .frame_start  (frame_start)
    );

    // -------------------------------------------------------------------------
    // 4) Frame buffer: a single-port-per-side BRAM holding QVGA in RGB444.
    //
    //    320 x 240 x 12 bits = 921,600 bits ~= 0.92 Mbit, fits in Basys 3 BRAM.
    //    The framebuffer is dual-clocked (write on PCLK, read on clk25).
    //    Vivado will infer a true dual-port block RAM.
    // -------------------------------------------------------------------------
    localparam FRAME_WIDTH  = 320;
    localparam FRAME_HEIGHT = 240;
    localparam FRAME_PIXELS = FRAME_WIDTH * FRAME_HEIGHT;  // 76,800 pixels

    (* ram_style = "block" *) reg [11:0] framebuffer [0:FRAME_PIXELS-1];

    // =========================================================================
    // 5) CAMERA-SIDE WRITE LOGIC  (clocked by cam_pclk_buf)
    //
    //    OV7670 in QVGA RGB565 mode outputs:
    //      * 2 bytes per pixel (high byte first, then low byte)
    //      * 320 pixels (= 640 bytes) per HREF-active period
    //      * 240 active lines per VSYNC frame
    //
    //    To eliminate the "red noise" we previously saw, we:
    //      (a) Register cam_d / cam_href / cam_vsync into an IOB-friendly
    //          flop on negedge PCLK (data is stable mid-cycle), then re-sample
    //          on posedge in the FSM. This avoids setup-hold violations on
    //          the high bits of cam_d (which carry red in RGB565).
    //      (b) Track byte phase strictly per-line, resetting it on every
    //          HREF rising edge so a missed byte cannot offset every line.
    //      (c) Pack ONE pixel from each pair of bytes (no 4-byte super-group).
    //          Previously the design dropped half the pixels and miscolored
    //          the rest.
    //      (d) Removed the "dark_clamp" and "color_balance" workaround
    //          functions: with proper byte alignment those hacks aren't needed
    //          and they introduced their own flicker / hue shift.
    // =========================================================================

    // -------- Step 1: register inputs from camera using the negedge of PCLK
    //          (OV7670 data is valid on the rising PCLK edge, so the falling
    //           edge is a safe sample point).
    reg       latched_vsync = 1'b0;
    reg       latched_href  = 1'b0;
    reg [7:0] latched_d     = 8'h00;

    always @(negedge cam_pclk_buf) begin
        latched_vsync <= cam_vsync;
        latched_href  <= cam_href;
        latched_d     <= cam_d;
    end

    // -------- Step 2: line / pixel counters and byte-phase tracker
    reg       href_d       = 1'b0;     // HREF delayed one PCLK (for edge detection)
    reg       byte_phase   = 1'b0;     // 0 = first byte of pixel, 1 = second byte
    reg [7:0] byte_hi      = 8'h00;    // captured high byte of current pixel
    reg [9:0] cap_x        = 10'd0;    // pixel x-coordinate within source image
    reg [8:0] cap_y        = 9'd0;     // line index within source image

    // -------- Step 3: framebuffer write address (320*y + x).
    //          We multiply by 320 using shift-and-add: 320*y = (y<<8) + (y<<6).
    //          Max address = 320*239 + 319 = 76,799 (fits in 17 bits).
    wire [16:0] wr_addr =
        ({8'd0, cap_y} << 8) + ({8'd0, cap_y} << 6) + {8'd0, cap_x[8:0]};

    // -------- Step 4: housekeeping flags for the LEDs / debug
    reg pclk_activity = 1'b0;
    reg pclk_seen     = 1'b0;
    reg href_seen     = 1'b0;
    reg vsync_seen    = 1'b0;
    reg frame_seen    = 1'b0;
    reg pixel_seen    = 1'b0;
    reg frame_ready   = 1'b0;          // goes high after the first full frame

    always @(posedge cam_pclk_buf) begin
        // toggle a flop just so an LED can show PCLK is alive
        pclk_activity <= ~pclk_activity;
        pclk_seen     <= 1'b1;

        // delayed HREF for falling-edge detection (used for end-of-line)
        href_d <= latched_href;

        if (latched_href)  href_seen  <= 1'b1;
        if (latched_vsync) vsync_seen <= 1'b1;

        if (!cam_init_done) begin
            // Hold the capture FSM in reset until SCCB programming is done
            byte_phase  <= 1'b0;
            cap_x       <= 10'd0;
            cap_y       <= 9'd0;
            frame_ready <= 1'b0;
            pixel_seen  <= 1'b0;
        end
        else if (latched_vsync) begin
            // VSYNC marks the start of a new frame: reset everything
            byte_phase <= 1'b0;
            cap_x      <= 10'd0;
            cap_y      <= 9'd0;
            if (pixel_seen) begin
                frame_seen  <= 1'b1;
                frame_ready <= 1'b1;       // valid frame is now in BRAM
            end
            pixel_seen <= 1'b0;
        end
        else if (latched_href) begin
            // ---- ACTIVE LINE: incoming pixel bytes ----
            if (byte_phase == 1'b0) begin
                // First byte of pair: latch it, advance phase
                byte_hi    <= latched_d;
                byte_phase <= 1'b1;
            end
            else begin
                // Second byte of pair: combine into a 12-bit RGB444 pixel
                byte_phase <= 1'b0;

                // Only write into the framebuffer if we are within QVGA bounds.
                // The OV7670 in QVGA already outputs 320x240, but we guard anyway.
                if ((cap_x < FRAME_WIDTH) && (cap_y < FRAME_HEIGHT)) begin
                    framebuffer[wr_addr] <=
                        camera_word_to_rgb444(byte_hi, latched_d, sw[7:6]);

                    // light up LED if we ever see non-black pixel data
                    if ((byte_hi != 8'h00) || (latched_d != 8'h00))
                        pixel_seen <= 1'b1;
                end

                // Advance the source x-coordinate by one pixel (1 pixel = 2 bytes)
                if (cap_x < FRAME_WIDTH) cap_x <= cap_x + 10'd1;
            end
        end
        else begin
            // ---- HREF is low: between lines ----
            byte_phase <= 1'b0;       // reset phase so a missed byte cannot
                                      // shift every subsequent line.
            cap_x      <= 10'd0;

            // Detect HREF falling edge => one source line just ended
            if (href_d && !latched_href) begin
                if (cap_y < FRAME_HEIGHT - 1)
                    cap_y <= cap_y + 9'd1;
            end
        end
    end

    // =========================================================================
    // 6) PIXEL DECODE FUNCTIONS (combinational helpers used during write)
    // =========================================================================

    // RGB565 layout from camera (high byte first, low byte second):
    //   hi = R R R R R G G G
    //   lo = G G G B B B B B
    // We keep only the top 4 bits of each channel for our RGB444 buffer.
    function [11:0] rgb565_to_rgb444;
        input [7:0] hi;
        input [7:0] lo;
        input       swap_rb;          // useful if R and B come reversed
        reg   [3:0] r4, g4, b4;
        begin
            r4 = hi[7:4];                 // top 4 of the 5 red bits
            g4 = {hi[2:0], lo[7]};        // top 4 of the 6 green bits
            b4 = lo[4:1];                 // top 4 of the 5 blue bits
            rgb565_to_rgb444 = swap_rb ? {b4, g4, r4} : {r4, g4, b4};
        end
    endfunction

    // Saturating cast: clamp a signed 12-bit value into a 4-bit channel.
    function [3:0] sat4_from_8bit;
        input signed [11:0] value;
        begin
            if (value < 12'sd0)         sat4_from_8bit = 4'h0;
            else if (value > 12'sd255)  sat4_from_8bit = 4'hF;
            else                        sat4_from_8bit = value[7:4];
        end
    endfunction

    // ITU-R BT.601-ish YUV->RGB matrix at 4-bit precision.
    // Used only when sw[7:6] selects YUYV/UYVY.
    function [11:0] yuv_to_rgb444;
        input [7:0] y, u, v;
        reg signed [11:0] yy, uu, vv, rr, gg, bb;
        begin
            yy = {4'b0000, y};
            uu = {4'b0000, u} - 12'sd128;
            vv = {4'b0000, v} - 12'sd128;
            rr = yy + vv + (vv >>> 2) + (vv >>> 3);
            gg = yy - (uu >>> 2) - (uu >>> 4) - (vv >>> 1) - (vv >>> 3);
            bb = yy + uu + (uu >>> 1) + (uu >>> 2);
            yuv_to_rgb444 = {sat4_from_8bit(rr), sat4_from_8bit(gg), sat4_from_8bit(bb)};
        end
    endfunction

    // For YUV modes we'd actually need 4 bytes (Y0 U Y1 V) per pixel pair, but
    // since we're in the 2-byte-per-pixel path, only the RGB565 modes are
    // recommended. Mode 10/11 still call yuv_to_rgb444 with what we have so
    // the design synthesizes; for proper YUV operation, switch back to a
    // 4-byte capture. This is purely a debug option.
    function [11:0] camera_word_to_rgb444;
        input [7:0] hi;
        input [7:0] lo;
        input [1:0] mode;
        begin
            case (mode)
                2'b00:   camera_word_to_rgb444 = rgb565_to_rgb444(hi, lo, 1'b0);
                2'b01:   camera_word_to_rgb444 = rgb565_to_rgb444(lo, hi, 1'b0);
                2'b10:   camera_word_to_rgb444 = yuv_to_rgb444(hi, lo, 8'h80);
                default: camera_word_to_rgb444 = yuv_to_rgb444(lo, hi, 8'h80);
            endcase
        end
    endfunction

    // =========================================================================
    // 7) VGA-SIDE READ LOGIC  (clocked by clk25)
    //    We pixel-double both horizontally (sx >> 1) and vertically (sy >> 1)
    //    so a 320x240 framebuffer fills the 640x480 screen.
    // =========================================================================
    wire [8:0] src_x = sx[9:1];   // 0..319
    wire [7:0] src_y = sy[8:1];   // 0..239
    wire [16:0] rd_addr =
        ({8'd0, src_y} << 8) + ({8'd0, src_y} << 6) + {8'd0, src_x};

    reg [11:0] camera_rgb   = 12'h000;  // raw pixel from BRAM
    reg [11:0] filtered_rgb = 12'h000;  // pixel after the chosen filter

    // -------- Filter selection --------------------------------------------
    // We chose 3 filters per the project requirements:
    //   * Grayscale (sw[4:2] = 001)
    //   * Color inversion / negative (sw[4:2] = 010)
    //   * Red-only / Green-only / Blue-only color isolation (011 / 100 / 101)
    //     (counts as one filter family but we expose all three for variety)
    function [11:0] apply_filter;
        input [11:0] rgb;
        input [2:0]  mode;
        reg   [5:0]  gray_sum;       // 6 bits = enough for R + 2G + B
        reg   [3:0]  gray;
        begin
            // Luma approximation: (R + 2*G + B) / 4   (cheap weighted average,
            // close to ITU-R 0.30R + 0.59G + 0.11B for a 4-bit channel).
            gray_sum = {2'b00, rgb[11:8]} + {1'b0, rgb[7:4], 1'b0} + {2'b00, rgb[3:0]};
            gray     = gray_sum[5:2];      // divide by 4

            case (mode)
                3'b001:  apply_filter = {gray, gray, gray};       // grayscale
                3'b010:  apply_filter = ~rgb;                     // negative
                3'b011:  apply_filter = {rgb[11:8], 4'h0, 4'h0};  // red only
                3'b100:  apply_filter = {4'h0, rgb[7:4], 4'h0};   // green only
                3'b101:  apply_filter = {4'h0, 4'h0, rgb[3:0]};   // blue only
                default: apply_filter = rgb;                      // raw
            endcase
        end
    endfunction

    // -------- Read pixel from framebuffer and apply the filter ------------
    // BRAM read takes 1 clk25 cycle, so this is naturally pipelined.
    always @(posedge clk25) begin
        if (active_video && frame_ready) begin
            camera_rgb   <= framebuffer[rd_addr];
            filtered_rgb <= apply_filter(camera_rgb, sw[4:2]);
        end
        else begin
            camera_rgb   <= 12'h000;
            filtered_rgb <= 12'h000;
        end
    end

    // =========================================================================
    // 8) DEBUG OVERLAYS
    //    sw[0] = full-screen color bars (sanity-check VGA pipe alone)
    //    sw[1] = live raw-signal viewer (shows cam_d / HREF / VSYNC visually)
    // =========================================================================
    reg [11:0] test_rgb = 12'h000;
    reg [11:0] live_rgb = 12'h000;

    always @(posedge clk25) begin
        // Eight vertical bars: red, green, blue, yellow, cyan, magenta, white, gray
        if      (sx <  80) test_rgb <= 12'hF00;
        else if (sx < 160) test_rgb <= 12'h0F0;
        else if (sx < 240) test_rgb <= 12'h00F;
        else if (sx < 320) test_rgb <= 12'hFF0;
        else if (sx < 400) test_rgb <= 12'h0FF;
        else if (sx < 480) test_rgb <= 12'hF0F;
        else if (sx < 560) test_rgb <= 12'hFFF;
        else               test_rgb <= 12'h888;

        // "Live" debug pattern that lets you visually verify the camera's
        // sync signals and data bus are toggling at the expected rate.
        live_rgb <= {
            cam_vsync ? 4'hF : cam_d[7:4],
            cam_href  ? 4'hF : cam_d[3:0],
            pclk_seen ? 4'hF : 4'h0
        };
    end

    // -------------------------------------------------------------------------
    // 9) FINAL VGA OUTPUT MUX
    //    Priority: sw[0] color bars > sw[1] live debug > filtered camera.
    // -------------------------------------------------------------------------
    wire [11:0] vga_pixel =
        sw[0] ? test_rgb     :
        sw[1] ? live_rgb     :
                filtered_rgb;

    assign vgaRed   = active_video ? vga_pixel[11:8] : 4'h0;
    assign vgaGreen = active_video ? vga_pixel[7:4]  : 4'h0;
    assign vgaBlue  = active_video ? vga_pixel[3:0]  : 4'h0;

    // -------------------------------------------------------------------------
    // 10) Status / debug LEDs
    // -------------------------------------------------------------------------
    assign led[0]     = cam_init_done;   // SCCB programming finished
    assign led[1]     = vsync_seen;      // we saw at least one VSYNC
    assign led[2]     = href_seen;       // we saw at least one HREF
    assign led[3]     = pclk_activity;   // PCLK is toggling
    assign led[4]     = cam_vsync;       // live VSYNC
    assign led[5]     = cam_href;        // live HREF
    assign led[6]     = cam_d[7];        // live MSB of pixel data
    assign led[7]     = sw[0];
    assign led[8]     = frame_seen;      // captured at least one full frame
    assign led[9]     = pixel_seen;      // saw non-black pixel data
    assign led[10]    = cam_href;
    assign led[11]    = pclk_seen;
    assign led[12]    = sw[1];
    assign led[14:13] = sw[7:6];
    assign led[15]    = sw[5];

endmodule
