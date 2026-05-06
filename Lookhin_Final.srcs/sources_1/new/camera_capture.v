`timescale 1ns / 1ps

module camera_capture (
    input wire pclk,           // Camera Pixel Clock
    input wire vsync,          // Camera Vertical Sync
    input wire href,           // Camera Horizontal Reference (Valid Data)
    input wire [7:0] d,        // 8-bit Data from Camera
    output reg [16:0] addr,    // Write address for BRAM (up to 76,800 for 320x240)
    output reg [15:0] dout,    // 16-bit RGB565 Pixel Data out
    output reg wr_en           // Write Enable for BRAM
);

    reg write_state;           // 0 = receiving first byte, 1 = receiving second byte
    reg [15:0] latched_pixel;
    reg [16:0] pixel_count;

    initial begin
        addr = 0;
        dout = 0;
        wr_en = 0;
        write_state = 0;
        pixel_count = 0;
    end

    // The OV7670 outputs a frame bounded by VSYNC.
    // VSYNC high indicates a new frame (vertical blanking). We reset our memory address pointer here.
    always @(posedge pclk) begin
        if (vsync == 1'b1) begin
            addr <= 0;
            pixel_count <= 0;
            write_state <= 0;
            wr_en <= 0;
        end else begin
            // HREF high means the camera is transmitting a valid row of pixels
            if (href == 1'b1) begin
                if (write_state == 1'b0) begin
                    // State 0: Latch the first byte (Red [4:0] and Green [5:3])
                    latched_pixel[15:8] <= d;
                    write_state <= 1'b1;
                    wr_en <= 0;
                end else begin
                    // State 1: Combine with the second byte (Green [2:0] and Blue [4:0])
                    latched_pixel[7:0] <= d;
                    dout <= {d, latched_pixel[15:8]};
                    wr_en <= 1'b1;         // Trigger write to BRAM
                    write_state <= 1'b0;   // Reset state for the next pixel
                    
                    // Increment the address, ensuring we don't overflow a 320x240 buffer (76,800 pixels)
                    if (pixel_count < 76800) begin
                        addr <= pixel_count;
                        pixel_count <= pixel_count + 1;
                    end
                end
            end else begin
                // If HREF drops, we are between rows. Reset write enable and state.
                wr_en <= 0;
                write_state <= 0; 
            end
        end
    end

endmodule