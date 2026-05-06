`timescale 1ns / 1ps

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

    assign cam_xclk  = clk25;
    assign cam_reset = 1'b1;
    assign cam_pwdn  = 1'b0;

    wire cam_init_done;

    ov7670_init_controller init_u (
        .clk       (CLK100MHZ),
        .reset     (1'b0),
        .colorbar  (1'b0),
        .sioc      (cam_sioc),
        .siod      (cam_siod),
        .init_done (cam_init_done)
    );

    wire [9:0] sx, sy;
    wire       active_video;
    wire       frame_start;

    vga_640x480 vga_u (
        .clk25        (clk25),
        .sx           (sx),
        .sy           (sy),
        .hsync        (Hsync),
        .vsync        (Vsync),
        .active_video (active_video),
        .frame_start  (frame_start)
    );

    localparam FRAME_WIDTH  = 320;
    localparam FRAME_HEIGHT = 240;
    localparam FRAME_PIXELS = 76800;

    // Store the same 12-bit RGB444 format used by the reference design.
    (* ram_style = "block" *) reg [11:0] framebuffer [0:FRAME_PIXELS-1];

    reg pclk_activity = 1'b0;
    reg pclk_seen     = 1'b0;
    reg href_seen     = 1'b0;
    reg vsync_seen    = 1'b0;
    reg frame_seen    = 1'b0;
    reg pixel_seen    = 1'b0;
    reg frame_ready   = 1'b0;

    reg [1:0] byte_phase = 2'd0;
    reg       href_d = 1'b0;
    reg [7:0] b0 = 8'h00;
    reg [7:0] b1 = 8'h00;
    reg [7:0] b2 = 8'h00;
    reg [9:0] cap_x = 10'd0;
    reg [8:0] cap_y = 9'd0;

    reg       latched_vsync = 1'b0;
    reg       latched_href = 1'b0;
    reg [7:0] latched_d = 8'h00;

    always @(negedge cam_pclk_buf) begin
        latched_vsync <= cam_vsync;
        latched_href <= cam_href;
        latched_d <= sw[5] ? reverse8(cam_d) : cam_d;
    end

    wire [8:0] cap_dst_x = cap_x[9:1];
    wire [7:0] cap_dst_y = cap_y[8:1];

    wire [16:0] wr_addr =
        ({9'd0, cap_dst_y} << 8) + ({9'd0, cap_dst_y} << 6) + {8'd0, cap_dst_x};

    always @(posedge cam_pclk_buf) begin
        pclk_activity <= ~pclk_activity;
        pclk_seen <= 1'b1;
        href_d <= latched_href;
        if (latched_href)  href_seen <= 1'b1;
        if (latched_vsync) vsync_seen <= 1'b1;

        if (!cam_init_done) begin
            byte_phase <= 2'd0;
            cap_x <= 10'd0;
            cap_y <= 9'd0;
            frame_ready <= 1'b0;
            pixel_seen <= 1'b0;
        end else if (latched_vsync) begin
            byte_phase <= 2'd0;
            cap_x <= 10'd0;
            cap_y <= 9'd0;
            if (pixel_seen) begin
                frame_seen <= 1'b1;
                frame_ready <= 1'b1;
            end
            pixel_seen <= 1'b0;
        end else if (latched_href) begin
            case (byte_phase)
                2'd0: begin
                    b0 <= latched_d;
                    byte_phase <= 2'd1;
                end

                2'd1: begin
                    b1 <= latched_d;
                    byte_phase <= 2'd2;
                end

                2'd2: begin
                    b2 <= latched_d;
                    byte_phase <= 2'd3;
                end

                default: begin
                    byte_phase <= 2'd0;
                    if ((cap_x < 10'd640) && (cap_y < 9'd480)) begin
                        if (!cap_y[0] && (cap_dst_x < FRAME_WIDTH) && (cap_dst_y < FRAME_HEIGHT)) begin
                            framebuffer[wr_addr] <= camera_word_to_rgb444(b0, b1, b2, latched_d, sw[7:6]);
                            if ((b0 != 8'h00) || (b1 != 8'h00) || (b2 != 8'h00) || (latched_d != 8'h00))
                                pixel_seen <= 1'b1;
                        end
                        cap_x <= cap_x + 10'd2;
                    end
                end
            endcase
        end else begin
            byte_phase <= 2'd0;
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
    reg [11:0] filtered_rgb = 12'h000;
    reg [11:0] test_rgb = 12'h000;
    reg [11:0] live_rgb = 12'h000;

    function [7:0] reverse8;
        input [7:0] value;
        begin
            reverse8 = {value[0], value[1], value[2], value[3], value[4], value[5], value[6], value[7]};
        end
    endfunction

    function [11:0] rgb565_to_rgb444;
        input [7:0] hi;
        input [7:0] lo;
        input       swap_rb;
        reg [3:0] r4;
        reg [3:0] g4;
        reg [3:0] b4;
        begin
            r4 = hi[7:4];
            g4 = {hi[2:0], lo[7]};
            b4 = lo[4:1];
            rgb565_to_rgb444 = swap_rb ? {b4, g4, r4} : {r4, g4, b4};
        end
    endfunction

    function [3:0] sat4_from_8bit;
        input signed [11:0] value;
        begin
            if (value < 12'sd0)
                sat4_from_8bit = 4'h0;
            else if (value > 12'sd255)
                sat4_from_8bit = 4'hF;
            else
                sat4_from_8bit = value[7:4];
        end
    endfunction

    function [11:0] yuv_to_rgb444;
        input [7:0] y;
        input [7:0] u;
        input [7:0] v;
        reg signed [11:0] yy;
        reg signed [11:0] uu;
        reg signed [11:0] vv;
        reg signed [11:0] rr;
        reg signed [11:0] gg;
        reg signed [11:0] bb;
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

    function [11:0] camera_word_to_rgb444;
        input [7:0] byte0;
        input [7:0] byte1;
        input [7:0] byte2;
        input [7:0] byte3;
        input [1:0] mode;
        begin
            case (mode)
                2'b00: camera_word_to_rgb444 = rgb565_to_rgb444(byte0, byte1, 1'b0); // RGB565
                2'b01: camera_word_to_rgb444 = rgb565_to_rgb444(byte1, byte0, 1'b0); // RGB565 byte swap
                2'b10: camera_word_to_rgb444 = yuv_to_rgb444(byte0, byte1, byte3);   // YUYV
                default: camera_word_to_rgb444 = yuv_to_rgb444(byte1, byte0, byte2);  // UYVY
            endcase
        end
    endfunction

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
            filtered_rgb <= apply_filter(camera_rgb, sw[4:2]);
        end else begin
            camera_rgb <= 12'h000;
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
