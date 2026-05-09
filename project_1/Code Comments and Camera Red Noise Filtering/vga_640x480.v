// =============================================================================
// vga_640x480.v
// -----------------------------------------------------------------------------
// Generates the standard VGA 640x480 @ 60 Hz timing from a 25 MHz pixel clock
// (industry standard is 25.175 MHz; 25 MHz is close enough that all monitors
//  will lock to it).
//
// Horizontal timing (in pixels, 800 total per line):
//   visible       0..639      (640 px)
//   front porch   640..655    ( 16 px)
//   sync pulse    656..751    ( 96 px, active low)
//   back porch    752..799    ( 48 px)
//
// Vertical timing (in lines, 525 total per frame):
//   visible       0..479      (480 lines)
//   front porch   480..489    ( 10 lines)
//   sync pulse    490..491    (  2 lines, active low)
//   back porch    492..524    ( 33 lines)
//
// Outputs:
//   sx, sy        - raw pixel/line counters (used by the framebuffer reader)
//   hsync, vsync  - sync pulses to the monitor (active low)
//   active_video  - 1 when the current pixel is inside the visible region
//   frame_start   - 1 for one cycle at sx=0,sy=0 (top-left corner)
// =============================================================================

module vga_640x480 (
    input  wire       clk25,         // 25 MHz pixel clock
    output reg [9:0]  sx = 0,        // 0..799 horizontal position
    output reg [9:0]  sy = 0,        // 0..524 vertical   position
    output wire       hsync,
    output wire       vsync,
    output wire       active_video,
    output wire       frame_start
);

    // -------- horizontal & vertical counters --------
    always @(posedge clk25) begin
        if (sx == 799) begin
            sx <= 0;
            if (sy == 524) sy <= 0;
            else           sy <= sy + 10'd1;
        end
        else begin
            sx <= sx + 10'd1;
        end
    end

    // sync pulses are active LOW (so we negate the comparison)
    assign hsync        = ~((sx >= 656) && (sx < 752));
    assign vsync        = ~((sy >= 490) && (sy < 492));
    assign active_video =  (sx <  640) && (sy <  480);
    assign frame_start  =  (sx == 0)   && (sy == 0);

endmodule
