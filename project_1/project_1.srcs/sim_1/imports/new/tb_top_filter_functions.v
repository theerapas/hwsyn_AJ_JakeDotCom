`timescale 1ns / 1ps

// Test the required combinational image helper functions in top_ov7670_fifo_vga.
// This intentionally avoids VGA timing so the waveform stays short and the
// expected values are easy to inspect.
module tb_top_filter_functions;
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

    reg [11:0] rgb_in = 12'h000;
    reg [2:0] mode = 3'b000;
    reg [11:0] rgb565_out = 12'h000;
    reg [11:0] filter_out = 12'h000;

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

    task check_filter;
        input [11:0] value;
        input [2:0] filter_mode;
        input [11:0] expected;
        begin
            rgb_in = value;
            mode = filter_mode;
            filter_out = dut.apply_filter(value, filter_mode);
            #1;
            if (filter_out != expected) begin
                $display("FAIL: apply_filter(%h, %b) = %h, expected %h",
                         value, filter_mode, filter_out, expected);
                $finish;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_top_filter_functions.vcd");
        $dumpvars(0, tb_top_filter_functions.rgb_in);
        $dumpvars(0, tb_top_filter_functions.mode);
        $dumpvars(0, tb_top_filter_functions.rgb565_out);
        $dumpvars(0, tb_top_filter_functions.filter_out);

        rgb565_out = dut.rgb565_to_rgb444(8'hF8, 8'h00);
        #1;
        if (rgb565_out != 12'hF00) begin
            $display("FAIL: RGB565 red conversion = %h, expected F00", rgb565_out);
            $finish;
        end

        rgb565_out = dut.rgb565_to_rgb444(8'h07, 8'hE0);
        #1;
        if (rgb565_out != 12'h0F0) begin
            $display("FAIL: RGB565 green conversion = %h, expected 0F0", rgb565_out);
            $finish;
        end

        rgb565_out = dut.rgb565_to_rgb444(8'h00, 8'h1F);
        #1;
        if (rgb565_out != 12'h00F) begin
            $display("FAIL: RGB565 blue conversion = %h, expected 00F", rgb565_out);
            $finish;
        end

        check_filter(12'h369, 3'b000, 12'h369); // normal
        check_filter(12'h369, 3'b001, 12'h666); // grayscale
        check_filter(12'h369, 3'b010, 12'hC96); // invert
        check_filter(12'h369, 3'b011, 12'h300); // red only
        check_filter(12'h369, 3'b100, 12'h060); // green only
        check_filter(12'h369, 3'b101, 12'h009); // blue only

        $display("PASS: RGB565 conversion and image filter helpers produced expected values.");
        $finish;
    end
endmodule
