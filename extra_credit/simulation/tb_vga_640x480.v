`timescale 1ns / 1ps

// Test one complete 1280x960 VGA frame. It counts active-video pixels and the
// positive HSYNC/VSYNC pulse widths against the expected timing constants.
module tb_vga_640x480;
    reg clk25 = 1'b0;
    wire [10:0] sx;
    wire [9:0] sy;
    wire hsync;
    wire vsync;
    wire active_video;
    wire frame_start;

    integer active_count = 0;
    integer hsync_low_count = 0;
    integer vsync_low_count = 0;
    integer cycle_count = 0;

    always #4.629 clk25 = ~clk25; // about 108 MHz

    vga_640x480 dut (
        .clk25(clk25),
        .sx(sx),
        .sy(sy),
        .hsync(hsync),
        .vsync(vsync),
        .active_video(active_video),
        .frame_start(frame_start)
    );

    initial begin
        $dumpfile("tb_vga_640x480.vcd");
        $dumpvars(0, tb_vga_640x480);

        repeat (1800 * 1000) begin
            @(posedge clk25);
            cycle_count = cycle_count + 1;
            if (active_video) active_count = active_count + 1;
            if (hsync) hsync_low_count = hsync_low_count + 1;
            if (vsync) vsync_low_count = vsync_low_count + 1;
        end

        if (active_count != 1280 * 960) begin
            $display("FAIL: active video count = %0d", active_count);
            $finish;
        end

        if (hsync_low_count != 112 * 1000) begin
            $display("FAIL: HSYNC high count = %0d", hsync_low_count);
            $finish;
        end

        if (vsync_low_count != 3 * 1800) begin
            $display("FAIL: VSYNC high count = %0d", vsync_low_count);
            $finish;
        end

        if (cycle_count != 1800 * 1000) begin
            $display("FAIL: total cycle count = %0d", cycle_count);
            $finish;
        end

        $display("PASS: VGA timing generated one 1280x960 frame correctly.");
        $finish;
    end
endmodule