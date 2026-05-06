`timescale 1ns / 1ps

module image_processor (
    input wire clk,
    input wire [1:0] sw,           // Basys 3 Slide Switches for filter selection
    input wire [15:0] pixel_in,    // RGB565 pixel from BRAM
    output reg [15:0] pixel_out    // RGB565 pixel to VGA Output
);

    // Extract RGB565 color channels
    wire [4:0] r = pixel_in[15:11];
    wire [5:0] g = pixel_in[10:5];
    wire [4:0] b = pixel_in[4:0];

    // --------------------------------------------------------
    // Filter 1: Grayscale
    // --------------------------------------------------------
    // Hardware approximation: Average the RGB channels.
    // Aligning bits: multiply R and B by 2 to match G's 6-bit width before adding.
    wire [7:0] sum = {r, 1'b0} + g + {b, 1'b0};
    wire [5:0] gray_val = sum / 3;
    wire [15:0] filter_gray = {gray_val[5:1], gray_val, gray_val[5:1]};

    // --------------------------------------------------------
    // Filter 2: Color Inversion (Negative)
    // --------------------------------------------------------
    // Bitwise NOT operation on the incoming pixel.
    wire [15:0] filter_negative = ~pixel_in;

    // --------------------------------------------------------
    // Filter 3: Green-Only Isolation
    // --------------------------------------------------------
    // Zero out the Red and Blue channels.
    wire [15:0] filter_green_only = {5'b00000, g, 5'b00000};

    // --------------------------------------------------------
    // Multiplexer for Real-Time Switching[cite: 1]
    // --------------------------------------------------------
    always @(*) begin
        case(sw)
            2'b00: pixel_out = pixel_in;             // 00: Raw Video Feed
            2'b01: pixel_out = filter_gray;          // 01: Grayscale
            2'b10: pixel_out = filter_negative;      // 10: Negative Inversion
            2'b11: pixel_out = filter_green_only;    // 11: Green Channel Only
            default: pixel_out = pixel_in;
        endcase
    end

endmodule