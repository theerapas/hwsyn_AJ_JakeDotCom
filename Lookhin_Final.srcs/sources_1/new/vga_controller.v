`timescale 1ns / 1ps

module vga_controller(
    input wire clk_25mhz,
    input wire [15:0] pixel_in,       // RGB565 from the filter/BRAM
    output wire hsync,
    output wire vsync,
    output reg [3:0] vga_r,
    output reg [3:0] vga_g,
    output reg [3:0] vga_b,
    output wire [16:0] frame_addr     // Address to read from BRAM
);

    // Standard VGA 640x480 @ 60Hz timing parameters
    parameter H_DISPLAY = 640;
    parameter H_FRONT   = 16;
    parameter H_SYNC    = 96;
    parameter H_BACK    = 48;
    parameter H_TOTAL   = 800;

    parameter V_DISPLAY = 480;
    parameter V_FRONT   = 10;
    parameter V_SYNC    = 2;
    parameter V_BACK    = 33;
    parameter V_TOTAL   = 525;

    reg [9:0] h_count = 0;
    reg [9:0] v_count = 0;

    // Generate Sync signals (active low for standard 640x480)
    assign hsync = (h_count >= (H_DISPLAY + H_FRONT) && h_count < (H_DISPLAY + H_FRONT + H_SYNC)) ? 1'b0 : 1'b1;
    assign vsync = (v_count >= (V_DISPLAY + V_FRONT) && v_count < (V_DISPLAY + V_FRONT + V_SYNC)) ? 1'b0 : 1'b1;

    // Active display area flag
    wire video_on = (h_count < H_DISPLAY) && (v_count < V_DISPLAY);

    // ------------------------------------------------------------------------
    // Pixel Doubling Logic for 320x240 resolution[cite: 1]
    // ------------------------------------------------------------------------
    // By dropping the LSB (bit 0) of the counters, we hold the same pixel
    // for two clock cycles horizontally, and read the same row twice vertically.
    wire [8:0] x_scaled = h_count[9:1]; // Ranges from 0 to 319
    wire [8:0] y_scaled = v_count[9:1]; // Ranges from 0 to 239
    
    // Calculate the 1D memory address for the BRAM
    assign frame_addr = (y_scaled * 320) + x_scaled;

    // Horizontal and Vertical Counters
    always @(posedge clk_25mhz) begin
        if (h_count == H_TOTAL - 1) begin
            h_count <= 0;
            if (v_count == V_TOTAL - 1)
                v_count <= 0;
            else
                v_count <= v_count + 1;
        end else begin
            h_count <= h_count + 1;
        end
    end

    // Output colors: Map 16-bit RGB565 down to the Basys 3's 12-bit VGA (4 bits per channel)
    always @(posedge clk_25mhz) begin
        if (video_on) begin
            vga_r <= pixel_in[15:12]; // Top 4 bits of Red
            vga_g <= pixel_in[10:7];  // Top 4 bits of Green
            vga_b <= pixel_in[4:1];   // Top 4 bits of Blue
        end else begin
            // Change these from 4'h0 to test VGA!
            vga_r <= 4'h0;
            vga_g <= 4'h0;
            vga_b <= 4'hF; // Output pure blue
        end
    end

endmodule