`timescale 1ns / 1ps

// 1280x960 @ 60 Hz VGA timing generator.
// The module produces pixel coordinates, active-video qualification, and
// positive HSYNC/VSYNC pulses for a 108 MHz pixel clock.
//
// The module name is kept as vga_640x480 so the existing Vivado project file
// does not need to be rebuilt from scratch.
module vga_640x480 (
    input  wire       clk25,
    output reg [10:0] sx = 0,
    output reg [9:0]  sy = 0,
    output wire       hsync,
    output wire       vsync,
    output wire       active_video,
    output wire       frame_start
);
    // 1280x960 @ 60 Hz VESA timing using 108 MHz pixel clock.
    // visible: 1280, front porch:96, sync:112, back porch:312 => 1800
    // visible: 960,  front porch:1,  sync:3,   back porch:36  => 1000

    always @(posedge clk25) begin
        if (sx == 1799) begin
            sx <= 0;
            if (sy == 999) sy <= 0;
            else           sy <= sy + 1;
        end else begin
            sx <= sx + 1;
        end
    end

    assign hsync = (sx >= 1376) && (sx < 1488);
    assign vsync = (sy >= 961) && (sy < 964);
    assign active_video = (sx < 1280) && (sy < 960);
    assign frame_start  = (sx == 0) && (sy == 0);

endmodule
