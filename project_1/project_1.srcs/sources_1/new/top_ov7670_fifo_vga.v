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
        .colorbar  (sw[5]),
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
    localparam FRAME_PAIRS  = 38400;

    // One BRAM word stores two adjacent RGB332 pixels.
    (* ram_style = "block" *) reg [15:0] framebuffer [0:FRAME_PAIRS-1];

    reg [2:0] vsync_sr = 3'b111;
    always @(posedge cam_pclk_buf) vsync_sr <= {vsync_sr[1:0], cam_vsync};
    wire vsync_rise = (vsync_sr[2:1] == 2'b01);

    reg pclk_activity = 1'b0;
    reg pclk_seen     = 1'b0;
    reg href_seen     = 1'b0;
    reg vsync_seen    = 1'b0;
    reg frame_seen    = 1'b0;
    reg pixel_seen    = 1'b0;
    reg frame_ready   = 1'b0;

    reg href_d = 1'b0;
    reg [1:0] cap_phase = 2'd0;
    reg [7:0] pix0_hi = 8'h00;
    reg [7:0] pix0_lo = 8'h00;
    reg [7:0] pix1_hi = 8'h00;
    reg [8:0] cap_x = 9'd0;
    reg [7:0] cap_y = 8'd0;

    wire [15:0] wr_pair_addr =
        ({8'd0, cap_y} << 7) + ({8'd0, cap_y} << 5) + {8'd0, cap_x[8:1]};

    always @(posedge cam_pclk_buf) begin
        pclk_activity <= ~pclk_activity;
        pclk_seen <= 1'b1;
        href_d <= cam_href;
        if (cam_href)  href_seen <= 1'b1;
        if (cam_vsync) vsync_seen <= 1'b1;

        if (!cam_init_done) begin
            cap_phase <= 2'd0;
            cap_x <= 9'd0;
            cap_y <= 8'd0;
            frame_ready <= 1'b0;
            pixel_seen <= 1'b0;
        end else if (vsync_rise) begin
            cap_phase <= 2'd0;
            cap_x <= 9'd0;
            cap_y <= 8'd0;
            if (pixel_seen) begin
                frame_seen <= 1'b1;
                frame_ready <= 1'b1;
            end
            pixel_seen <= 1'b0;
        end else if (cam_href) begin
            case (cap_phase)
                2'd0: begin
                    pix0_hi <= cam_d;
                    cap_phase <= 2'd1;
                end

                2'd1: begin
                    pix0_lo <= cam_d;
                    cap_phase <= 2'd2;
                end

                2'd2: begin
                    pix1_hi <= cam_d;
                    cap_phase <= 2'd3;
                end

                default: begin
                    if ((cap_x < FRAME_WIDTH-1) && (cap_y < FRAME_HEIGHT)) begin
                        case (sw[7:6])
                            2'b00: framebuffer[wr_pair_addr] <= {
                                rgb565_to_rgb332(pix0_hi, pix0_lo, 1'b0), // RGB565 high-low
                                rgb565_to_rgb332(pix1_hi, cam_d,   1'b0)
                            };

                            2'b01: framebuffer[wr_pair_addr] <= {
                                rgb565_to_rgb332(pix0_lo, pix0_hi, 1'b0), // byte-swapped RGB565
                                rgb565_to_rgb332(cam_d,   pix1_hi, 1'b0)
                            };

                            2'b10: framebuffer[wr_pair_addr] <= {
                                rgb565_to_rgb332(pix0_hi, pix0_lo, 1'b1), // B/R swapped
                                rgb565_to_rgb332(pix1_hi, cam_d,   1'b1)
                            };

                            default: framebuffer[wr_pair_addr] <= {
                                rgb565_to_rgb332(pix0_lo, pix0_hi, 1'b1), // byte + B/R swap
                                rgb565_to_rgb332(cam_d,   pix1_hi, 1'b1)
                            };
                        endcase
                        if ((pix0_hi != 8'h00) || (pix0_lo != 8'h00) || (pix1_hi != 8'h00) || (cam_d != 8'h00))
                            pixel_seen <= 1'b1;
                    end
                    if (cap_x < FRAME_WIDTH-2)
                        cap_x <= cap_x + 9'd2;
                    cap_phase <= 2'd0;
                end
            endcase
        end else begin
            cap_phase <= 2'd0;
            cap_x <= 9'd0;
            if (href_d && !cam_href && (cap_y < FRAME_HEIGHT-1))
                cap_y <= cap_y + 8'd1;
        end
    end

    wire [8:0] src_x = sx[9:1];
    wire [7:0] src_y = sy[8:1];
    wire [15:0] rd_pair_addr =
        ({8'd0, src_y} << 7) + ({8'd0, src_y} << 5) + {8'd0, src_x[8:1]};

    reg [15:0] pixel_pair = 16'h0000;
    reg        src_x_lsb_d = 1'b0;
    reg [7:0]  frame_rgb332 = 8'h00;
    reg [11:0] camera_rgb = 12'h000;
    reg [11:0] filtered_rgb = 12'h000;
    reg [11:0] test_rgb = 12'h000;
    reg [11:0] live_rgb = 12'h000;

    function [7:0] rgb565_to_rgb332;
        input [7:0] hi;
        input [7:0] lo;
        input       swap_rb;
        reg [2:0] r3;
        reg [2:0] g3;
        reg [1:0] b2;
        begin
            r3 = hi[7:5];
            g3 = hi[2:0];
            b2 = lo[4:3];
            rgb565_to_rgb332 = swap_rb ? {lo[4:2], g3, hi[7:6]} : {r3, g3, b2};
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

    wire [7:0] selected_rgb332 = src_x_lsb_d ? pixel_pair[7:0] : pixel_pair[15:8];

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
            pixel_pair <= framebuffer[rd_pair_addr];
            src_x_lsb_d <= src_x[0];
            frame_rgb332 <= selected_rgb332;
            camera_rgb <= {
                selected_rgb332[7:5], selected_rgb332[7],
                selected_rgb332[4:2], selected_rgb332[4],
                selected_rgb332[1:0], selected_rgb332[1:0]
            };
            filtered_rgb <= apply_filter(camera_rgb, sw[4:2]);
        end else begin
            pixel_pair <= 16'h0000;
            src_x_lsb_d <= 1'b0;
            frame_rgb332 <= 8'h00;
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
