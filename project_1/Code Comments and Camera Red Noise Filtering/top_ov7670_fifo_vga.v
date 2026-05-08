`timescale 1ns / 1ps

// Top-level video pipeline for Basys 3 + OV7670.
//
// Clock domains:
// - CLK100MHZ drives SCCB camera configuration and creates the 25 MHz clock.
// - cam_pclk_buf captures camera data in the OV7670 pixel clock domain.
// - clk25 drives VGA timing and framebuffer reads.
//
// Video path:
// OV7670 RGB565 stream -> 320x240 RGB444 framebuffer -> optional calibration
// and image filter -> 640x480 VGA output by 2x pixel/line repetition.
module top_ov7670_fifo_vga (
    input  wire CLK100MHZ,
    input  wire [7:0] sw,

    input  wire [7:0] cam_d,
    input  wire       cam_vsync,
    input  wire       cam_href,
    input  wire       cam_pclk_buf,

    output wire       cam_xclk,
    output wire       cam_reset,
    output wire       cam_pwdn,
    output wire       cam_sioc,
    inout  wire       cam_siod,

    output wire [3:0] vgaRed,
    output wire [3:0] vgaGreen,
    output wire [3:0] vgaBlue,
    output wire       Hsync,
    output wire       Vsync,

    output wire [15:0] led
);

    reg [1:0] div4 = 2'b00;
    always @(posedge CLK100MHZ) div4 <= div4 + 2'd1;

    wire clk25 = div4[1];

    // OV7670 requires an external clock. 25 MHz works with the register
    // configuration used in ov7670_init_rom.v.
    assign cam_xclk  = clk25;
    assign cam_pwdn  = 1'b0;

    wire cam_init_done;

    ov7670_init_controller init_u (
        .clk       (CLK100MHZ),
        .reset     (1'b0),
        .colorbar  (sw[5]),
        .camera_reset (cam_reset),
        .sioc      (cam_sioc),
        .siod      (cam_siod),
        .init_done (cam_init_done)
    );

    wire [9:0] sx, sy;
    wire       active_video;

    vga_640x480 vga_u (
        .clk25        (clk25),
        .sx           (sx),
        .sy           (sy),
        .hsync        (Hsync),
        .vsync        (Vsync),
        .active_video (active_video),
        .frame_start  ()
    );

    localparam FRAME_WIDTH  = 320;
    localparam FRAME_HEIGHT = 240;
    localparam FRAME_PIXELS = 76800;

    // Store a 320x240 RGB444 frame. The camera is configured for a VGA-sized
    // stream, and the capture logic keeps every other source row/column.
    (* ram_style = "block" *) reg [11:0] framebuffer [0:FRAME_PIXELS-1];

    reg pclk_activity = 1'b0;
    reg pclk_seen     = 1'b0;
    reg href_seen     = 1'b0;
    reg vsync_seen    = 1'b0;
    reg frame_seen    = 1'b0;
    reg pixel_seen    = 1'b0;
    reg frame_ready   = 1'b0;

    reg       byte_phase = 1'b0;
    reg       href_d = 1'b0;
    reg [7:0] byte_hi = 8'h00;
    reg [9:0] cap_x = 10'd0;
    reg [8:0] cap_y = 9'd0;

    reg       latched_vsync = 1'b0;
    reg       latched_href = 1'b0;
    reg [7:0] latched_d = 8'h00;

    always @(negedge cam_pclk_buf) begin
        latched_vsync <= cam_vsync;
        latched_href <= cam_href;
        latched_d <= cam_d;
    end

    wire [8:0] cap_dst_x = cap_x[9:1];
    wire [7:0] cap_dst_y = cap_y[8:1];

    wire [16:0] wr_addr =
        ({9'd0, cap_dst_y} << 8) + ({9'd0, cap_dst_y} << 6) + {8'd0, cap_dst_x};

    // Camera capture. Data is sampled on the falling PCLK edge and consumed on
    // the following rising edge, matching the timing style used by the reference
    // OV7670 capture design. Every other source column/row is stored to convert
    // the VGA-sized sensor stream into the required 320x240 frame.
    always @(posedge cam_pclk_buf) begin
        pclk_activity <= ~pclk_activity;
        pclk_seen <= 1'b1;
        href_d <= latched_href;
        if (latched_href)  href_seen <= 1'b1;
        if (latched_vsync) vsync_seen <= 1'b1;

        if (!cam_init_done) begin
            byte_phase <= 1'b0;
            cap_x <= 10'd0;
            cap_y <= 9'd0;
            frame_ready <= 1'b0;
            pixel_seen <= 1'b0;
        end else if (latched_vsync) begin
            byte_phase <= 1'b0;
            cap_x <= 10'd0;
            cap_y <= 9'd0;
            if (pixel_seen) begin
                frame_seen <= 1'b1;
                frame_ready <= 1'b1;
            end
            pixel_seen <= 1'b0;
        end else if (latched_href) begin
            if (!byte_phase) begin
                byte_hi <= latched_d;
                byte_phase <= 1'b1;
            end else begin
                byte_phase <= 1'b0;
                if ((cap_x < 10'd640) && (cap_y < 9'd480)) begin
                    if (!cap_x[0] && !cap_y[0] && (cap_dst_x < FRAME_WIDTH) && (cap_dst_y < FRAME_HEIGHT)) begin
                        framebuffer[wr_addr] <= rgb565_to_rgb444(byte_hi, latched_d);
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
                cap_y <= cap_y + 9'd1;
        end
    end

    wire [8:0] src_x = sx[9:1];
    wire [7:0] src_y = sy[8:1];
    wire [16:0] rd_addr =
        ({9'd0, src_y} << 8) + ({9'd0, src_y} << 6) + {8'd0, src_x};

    reg [11:0] camera_rgb = 12'h000;
    reg [11:0] balanced_rgb = 12'h000;
    reg [11:0] filtered_rgb = 12'h000;
    reg [11:0] test_rgb = 12'h000;
    reg [11:0] live_rgb = 12'h000;

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
    function [11:0] apply_filter;
        input [11:0] rgb;
        input [2:0] mode;
        reg [3:0] gray;
        begin
            gray = ({2'b00, rgb[11:8]} + {2'b00, rgb[7:4], 1'b0} + {2'b00, rgb[3:0]}) >> 2;
            case (mode)
                3'b001: apply_filter = {gray, gray, gray};      // grayscale
                3'b010: apply_filter = ~rgb;                    // color inversion
                3'b011: apply_filter = {rgb[11:8], 8'h00};      // red channel
                3'b100: apply_filter = {4'h0, rgb[7:4], 4'h0};  // green channel
                3'b101: apply_filter = {8'h00, rgb[3:0]};       // blue channel
                default: apply_filter = rgb;                    // normal color
            endcase
        end
    endfunction

    // Saturating subtract helper used by the camera color calibration.
    function [3:0] sub_sat4;
        input [3:0] value;
        input [3:0] amount;
        begin
            sub_sat4 = (value > amount) ? (value - amount) : 4'h0;
        end
    endfunction

    function [11:0] color_balance;
        input [11:0] rgb;
        reg [3:0] r;
        reg [3:0] g;
        reg [3:0] b;
        reg [3:0] max_ch;
        reg [5:0] sum_ch;
        reg       red_dominant;
        reg       low_light;
        begin
            r = rgb[11:8];
            g = rgb[7:4];
            b = rgb[3:0];
            max_ch = (r > g) ? ((r > b) ? r : b) : ((g > b) ? g : b);
            sum_ch = {2'b00, r} + {2'b00, g} + {2'b00, b};
            // "Red dominant" = R clearly above both G and B. Catches red noise
            // and red casts; doesn't fire on whites/grays/skin where R~=G~=B.
            red_dominant = (r > g + 4'h1) && (r > b + 4'h1);
            // Low-light region = the brightness band where AGC-amplified red
            // sensor noise lives. Anything below this is true shadow.
            low_light = (max_ch < 4'hB);

            // Board/camera calibration:
            // - Clamp dark pixels and red speckles in the low-light band.
            //   This is the dominant noise source: when the camera points at
            //   dark scenes the OV7670 cranks AGC and the red channel grains.
            //   The condition catches:
            //     * very dark pixels (max < 4)
            //     * very low total brightness (sum < 10)
            //     * any low-light pixel where red is the only channel that
            //       has any value to speak of (G,B both < 5 and R > G+1, B+1)
            // - Then trim residual warm cast on red-dominant pixels only,
            //   so whites/grays/greens/blues stay clean.
            // SW5 bypasses this path for raw sensor color-bar debugging.
            if ((max_ch < 4'h4) ||
                (sum_ch < 6'd10) ||
                (low_light && (g < 4'h5) && (b < 4'h5) && (r > g + 4'h1) && (r > b + 4'h1))) begin
                color_balance = 12'h000;
            end else if (red_dominant) begin
                // Red-dominant pixel - safe to trim red without desaturating
                // neutral or non-red regions. Brightness-aware drop:
                //   - dark/mid (max < C): -2  removes most residual cast
                //   - bright   (max >=C): -1  preserves real saturated reds
                if (max_ch < 4'hC)
                    r = sub_sat4(r, 4'h2);
                else
                    r = sub_sat4(r, 4'h1);
                color_balance = {r, g, b};
            end else begin
                // Not red-dominant - leave the pixel alone. Whites stay white,
                // greens/blues/skin stay clean.
                color_balance = {r, g, b};
            end
        end
    endfunction

    always @(posedge clk25) begin
        if (sx < 80)       test_rgb <= 12'hF00;
        else if (sx < 160) test_rgb <= 12'h0F0;
        else if (sx < 240) test_rgb <= 12'h00F;
        else if (sx < 320) test_rgb <= 12'hFF0;
        else if (sx < 400) test_rgb <= 12'h0FF;
        else if (sx < 480) test_rgb <= 12'hF0F;
        else if (sx < 560) test_rgb <= 12'hFFF;
        else               test_rgb <= 12'h888;

        live_rgb <= {
            cam_vsync ? 4'hF : cam_d[7:4],
            cam_href  ? 4'hF : cam_d[3:0],
            pclk_seen ? 4'hF : 4'h0
        };

        if (active_video && frame_ready) begin
            camera_rgb <= framebuffer[rd_addr];
            balanced_rgb <= sw[5] ? camera_rgb : color_balance(camera_rgb);
            filtered_rgb <= apply_filter(balanced_rgb, sw[4:2]);
        end else begin
            camera_rgb <= 12'h000;
            balanced_rgb <= 12'h000;
            filtered_rgb <= 12'h000;
        end
    end

    assign vgaRed   = active_video ? (sw[0] ? test_rgb[11:8] : (sw[1] ? live_rgb[11:8] : filtered_rgb[11:8])) : 4'h0;
    assign vgaGreen = active_video ? (sw[0] ? test_rgb[7:4]  : (sw[1] ? live_rgb[7:4]  : filtered_rgb[7:4]))  : 4'h0;
    assign vgaBlue  = active_video ? (sw[0] ? test_rgb[3:0]  : (sw[1] ? live_rgb[3:0]  : filtered_rgb[3:0]))  : 4'h0;

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
