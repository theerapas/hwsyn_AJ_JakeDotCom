`timescale 1ns / 1ps

module top_ov7670_fifo_vga (
    input  wire CLK100MHZ,
    input  wire [1:0] sw,

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

    // ----------------------------------------------------------------
    // clocks from 100 MHz:
    //   25 MHz for VGA and camera XCLK
    //   50 MHz for FIFO read state machine
    // ----------------------------------------------------------------
    reg [1:0] div4 = 2'b00;
    always @(posedge CLK100MHZ) div4 <= div4 + 2'd1;

    wire clk25 = div4[1];
    wire clk50 = div4[0];

    assign cam_xclk = clk25;
    assign cam_reset = 1'b1;
    assign cam_pwdn  = 1'b0;

    // ----------------------------------------------------------------
    // Camera SCCB init
    // ----------------------------------------------------------------
    wire cam_init_done;

    ov7670_init_controller init_u (
        .clk        (CLK100MHZ),
        .reset      (1'b0),
        .sioc       (cam_sioc),
        .siod       (cam_siod),
        .init_done  (cam_init_done)
    );

    // ----------------------------------------------------------------
    // Camera activity/debug sampling
    // ----------------------------------------------------------------
    reg [2:0] vsync_sr = 3'b111;
    always @(posedge cam_pclk_buf) vsync_sr <= {vsync_sr[1:0], cam_vsync};

    wire vsync_rise = (vsync_sr[2:1] == 2'b01);

    // ----------------------------------------------------------------
    // VGA timing 640x480@60 style at 25 MHz
    // ----------------------------------------------------------------
    wire [9:0] sx, sy;
    wire       active_video;
    wire       frame_start;

    vga_640x480 vga_u (
        .clk25       (clk25),
        .sx          (sx),
        .sy          (sy),
        .hsync       (Hsync),
        .vsync       (Vsync),
        .active_video(active_video),
        .frame_start (frame_start)
    );

    // ----------------------------------------------------------------
    // Direct OV7670 capture into block RAM.
    //
    // The OV7670 is configured for QVGA RGB565:
    // 320 x 240 pixels, 2 bytes per pixel.
    // VGA reads the same frame buffer scaled 2x to 640 x 480.
    // ----------------------------------------------------------------
    localparam FRAME_PIXELS = 17'd76800;

    (* ram_style = "block" *) reg [15:0] framebuffer [0:76799];

    reg pclk_activity = 1'b0;
    reg pclk_seen = 1'b0;
    reg href_seen = 1'b0;
    reg vsync_seen = 1'b0;
    reg frame_seen = 1'b0;
    reg pixel_seen = 1'b0;
    reg byte_phase = 1'b0;
    reg [7:0] byte_hi = 8'h00;
    reg [16:0] wr_addr = 17'd0;

    always @(posedge cam_pclk_buf) begin
        pclk_activity <= ~pclk_activity;
        pclk_seen <= 1'b1;
        if (cam_href) href_seen <= 1'b1;
        if (cam_vsync) vsync_seen <= 1'b1;

        if (!cam_init_done || cam_vsync) begin
            wr_addr <= 17'd0;
            byte_phase <= 1'b0;
            if (cam_vsync)
                frame_seen <= 1'b1;
        end else if (cam_href) begin
            if (!byte_phase) begin
                byte_hi <= cam_d;
                byte_phase <= 1'b1;
            end else begin
                byte_phase <= 1'b0;
                if (wr_addr < FRAME_PIXELS) begin
                    framebuffer[wr_addr] <= {byte_hi, cam_d};
                    wr_addr <= wr_addr + 17'd1;
                    if ({byte_hi, cam_d} != 16'h0000)
                        pixel_seen <= 1'b1;
                end else begin
                    wr_addr <= wr_addr;
                end
            end
        end else begin
            byte_phase <= 1'b0;
        end
    end

    // ----------------------------------------------------------------
    // VGA pixel generation
    // SW0 bypasses the camera path and shows internal color bars.
    // SW1 shows live camera signals:
    //   red   = VSYNC high
    //   green = HREF high
    //   blue  = PCLK was seen
    //   color intensity also includes the current camera data bus
    // ----------------------------------------------------------------
    reg [15:0] rgb565 = 16'h0000;
    reg [11:0] test_rgb = 12'h000;
    reg [11:0] live_rgb = 12'h000;
    reg [8:0] disp_x = 9'd0;
    reg [7:0] disp_y = 8'd0;
    reg [16:0] rd_addr = 17'd0;

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

        if (active_video) begin
            disp_x <= sx[9:1]; // /2
            disp_y <= sy[8:1]; // /2
            rd_addr <= ({9'd0, sy[8:1]} << 8) + ({9'd0, sy[8:1]} << 6) + {8'd0, sx[9:1]};
            rgb565 <= framebuffer[rd_addr];
        end else begin
            rgb565 <= 16'h0000;
        end
    end

    assign vgaRed   = active_video ? (sw[0] ? test_rgb[11:8] : (sw[1] ? live_rgb[11:8] : rgb565[15:12])) : 4'h0;
    assign vgaGreen = active_video ? (sw[0] ? test_rgb[7:4]  : (sw[1] ? live_rgb[7:4]  : rgb565[10:7]))  : 4'h0;
    assign vgaBlue  = active_video ? (sw[0] ? test_rgb[3:0]  : (sw[1] ? live_rgb[3:0]  : rgb565[4:1]))   : 4'h0;

    // LEDs for debug
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
    assign led[15:13] = 3'd0;

endmodule
