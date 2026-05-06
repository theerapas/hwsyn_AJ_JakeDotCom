module top_system(
    input wire clk_100mhz,        // Basys 3 primary clock
    input wire [1:0] sw,          // Filter switches
    // Camera Pins
    input wire [7:0] D,           // Camera Data
    input wire PCLK, VSYNC, HREF, // Camera Sync
    output wire XCLK,             // System clock to camera
    output wire PWDN, RST,        // Power and Reset
    output wire SCL,              // SCCB Clock (SIO_C)
    inout wire SDA,               // SCCB Data (SIO_D)
    // VGA Pins
    output wire [3:0] vga_r, vga_g, vga_b,
    output wire hsync, vsync
);

    // Divide 100MHz system clock by 4 to get 25MHz
    reg [1:0] clk_div = 0;
    always @(posedge clk_100mhz) begin
        clk_div <= clk_div + 1;
    end
    wire clk_25mhz = clk_div[1]; // Toggles at 25MHz
    
    wire [16:0] frame_addr_write, frame_addr_read;
    wire [15:0] pixel_data_in, pixel_data_raw, pixel_data_filtered;
    wire write_en;

    // Assign Camera defaults
    assign PWDN = 0; // Normal mode[cite: 2]
    assign RST = 1;  // Normal mode[cite: 2]
    
    // Generate 25MHz clock for VGA and Camera XCLK
    // (Requires a Clocking Wizard / MMCM IP here)
    assign XCLK = clk_25mhz; 

    // 1. Camera Capture Module
    // Reads PCLK, builds 16-bit pixels, outputs write address and data
    camera_capture capture_inst (
        .pclk(PCLK),
        .vsync(VSYNC),
        .href(HREF),
        .d(D),
        .addr(frame_addr_write),
        .dout(pixel_data_in),
        .wr_en(write_en)
    );

    // 2. Block RAM (Frame Buffer)
    // Needs to hold 320x240 = 76,800 pixels of 16-bit color
    blk_mem_gen_0 frame_buffer (
        .clka(PCLK),
        .wea(write_en),
        .addra(frame_addr_write),
        .dina(pixel_data_in),
        .clkb(clk_25mhz),
        .addrb(frame_addr_read),
        .doutb(pixel_data_raw)
    );

    // 3. Hardware Image Filter (Implemented above)
    image_processor filters (
        .clk(clk_25mhz),
        .sw(sw),
        .pixel_in(pixel_data_raw),
        .pixel_out(pixel_data_filtered)
    );

    // 4. VGA Controller
    // Outputs 640x480 sync, but drives frame_addr_read by pixel-doubling 320x240
    vga_controller vga_inst (
        .clk_25mhz(clk_25mhz),
        .pixel_in(pixel_data_filtered),
        .hsync(hsync),
        .vsync(vsync),
        .vga_r(vga_r),
        .vga_g(vga_g),
        .vga_b(vga_b),
        .frame_addr(frame_addr_read)
    );

    // 5. SCCB Controller
    // Initializes OV7670 registers for RGB565 and 320x240 resolution
    sccb_controller sccb_inst (
        .clk(clk_25mhz),
        .scl(SCL),
        .sda(SDA)
    );

endmodule