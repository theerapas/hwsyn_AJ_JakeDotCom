`timescale 1ns / 1ps

// Test the top-level capture path with a short synthetic RGB565 camera line.
// The SCCB controller is bypassed so the test can focus on pixel packing,
// horizontal downsampling, framebuffer writes, and frame-ready detection.
module tb_top_capture_filters;
    reg CLK100MHZ = 1'b0;
    reg [7:0] sw = 8'h00;
    reg [7:0] cam_d = 8'h00;
    reg cam_vsync = 1'b0;
    reg cam_href = 1'b0;
    reg cam_pclk_buf = 1'b1;
    wire cam_xclk;
    wire cam_reset;
    wire cam_pwdn;
    wire cam_sioc;
    tri1 cam_siod;
    wire [3:0] vgaRed;
    wire [3:0] vgaGreen;
    wire [3:0] vgaBlue;
    wire Hsync;
    wire Vsync;
    wire [15:0] led;

    always #5 CLK100MHZ = ~CLK100MHZ;

    top_ov7670_fifo_vga dut (
        .CLK100MHZ(CLK100MHZ),
        .sw(sw),
        .cam_d(cam_d),
        .cam_vsync(cam_vsync),
        .cam_href(cam_href),
        .cam_pclk_buf(cam_pclk_buf),
        .cam_xclk(cam_xclk),
        .cam_reset(cam_reset),
        .cam_pwdn(cam_pwdn),
        .cam_sioc(cam_sioc),
        .cam_siod(cam_siod),
        .vgaRed(vgaRed),
        .vgaGreen(vgaGreen),
        .vgaBlue(vgaBlue),
        .Hsync(Hsync),
        .Vsync(Vsync),
        .led(led)
    );

    task send_cam_byte;
        input [7:0] value;
        begin
            cam_d = value;
            cam_href = 1'b1;
            cam_vsync = 1'b0;
            #10 cam_pclk_buf = 1'b0;
            #10 cam_pclk_buf = 1'b1;
            #10;
        end
    endtask

    task send_blank_pclk;
        input href_value;
        input vsync_value;
        begin
            cam_href = href_value;
            cam_vsync = vsync_value;
            #10 cam_pclk_buf = 1'b0;
            #10 cam_pclk_buf = 1'b1;
            #10;
        end
    endtask

    initial begin
        $dumpfile("tb_top_capture_filters.vcd");
        $dumpvars(0, tb_top_capture_filters.CLK100MHZ);
        $dumpvars(0, tb_top_capture_filters.sw);
        $dumpvars(0, tb_top_capture_filters.cam_d);
        $dumpvars(0, tb_top_capture_filters.cam_vsync);
        $dumpvars(0, tb_top_capture_filters.cam_href);
        $dumpvars(0, tb_top_capture_filters.cam_pclk_buf);
        $dumpvars(0, tb_top_capture_filters.vgaRed);
        $dumpvars(0, tb_top_capture_filters.vgaGreen);
        $dumpvars(0, tb_top_capture_filters.vgaBlue);
        $dumpvars(0, tb_top_capture_filters.led);
        $dumpvars(0, tb_top_capture_filters.dut.cap_x);
        $dumpvars(0, tb_top_capture_filters.dut.cap_y);
        $dumpvars(0, tb_top_capture_filters.dut.wr_addr);
        $dumpvars(0, tb_top_capture_filters.dut.camera_rgb);
        $dumpvars(0, tb_top_capture_filters.dut.balanced_rgb);
        $dumpvars(0, tb_top_capture_filters.dut.filtered_rgb);

        force dut.cam_init_done = 1'b1;

        repeat (4) send_blank_pclk(1'b0, 1'b0);

        // Four RGB565 source pixels. The capture logic stores source pixels
        // 0 and 2 because it downsamples horizontally by 2.
        send_cam_byte(8'hF8); send_cam_byte(8'h00); // red   -> framebuffer[0]
        send_cam_byte(8'h07); send_cam_byte(8'hE0); // green -> skipped
        send_cam_byte(8'h00); send_cam_byte(8'h1F); // blue  -> framebuffer[1]
        send_cam_byte(8'hFF); send_cam_byte(8'hFF); // white -> skipped

        send_blank_pclk(1'b0, 1'b0);
        send_blank_pclk(1'b0, 1'b1); // frame boundary: marks frame ready
        send_blank_pclk(1'b0, 1'b0);

        if (dut.framebuffer[0] != 12'hF00) begin
            $display("FAIL: framebuffer[0] = %h, expected F00", dut.framebuffer[0]);
            $finish;
        end

        if (dut.framebuffer[1] != 12'h00F) begin
            $display("FAIL: framebuffer[1] = %h, expected 00F", dut.framebuffer[1]);
            $finish;
        end

        if (dut.frame_ready != 1'b1) begin
            $display("FAIL: frame_ready was not set.");
            $finish;
        end

        $display("PASS: top-level capture wrote RGB565 pixels into the 320x240 framebuffer.");
        $finish;
    end
endmodule
