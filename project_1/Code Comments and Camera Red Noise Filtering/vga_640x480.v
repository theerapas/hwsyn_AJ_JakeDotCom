module vga_640x480 (
    input  wire       clk25,
    output reg [9:0]  sx = 0,
    output reg [9:0]  sy = 0,
    output wire       hsync,
    output wire       vsync,
    output wire       active_video,
    output wire       frame_start
);
    // 640x480 @ 60 Hz nominal timing using 25 MHz pixel clock
    // visible: 640, front porch:16, sync:96, back porch:48 => 800
    // visible: 480, front porch:10, sync:2,  back porch:33 => 525

    always @(posedge clk25) begin
        if (sx == 799) begin
            sx <= 0;
            if (sy == 524) sy <= 0;
            else           sy <= sy + 1;
        end else begin
            sx <= sx + 1;
        end
    end

    assign hsync = ~((sx >= 656) && (sx < 752));
    assign vsync = ~((sy >= 490) && (sy < 492));
    assign active_video = (sx < 640) && (sy < 480);
    assign frame_start  = (sx == 0) && (sy == 0);

endmodule