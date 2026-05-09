// Register ROM for OV7670 RGB565 operation.
//
// Each entry is {register_address, register_value}. Special words:
// - 16'hFFFE: delay marker handled by ov7670_init_controller
// - 16'hFFFF: end of table
module ov7670_init_rom (
    input  wire [7:0] addr,
    input  wire       colorbar,
    output reg  [15:0] data
);
    always @(*) begin
        case (addr)
            8'h00: data = 16'h1280; // COM7 reset
            8'h01: data = 16'hFFFE; // settle after reset
            8'h02: data = 16'h1280; // reset again, matching the reference flow
            8'h03: data = 16'hFFFE;

            // RGB565 setup based on the local example project's
            // ov7670_registers.v. A few later values are board-specific color
            // and noise trims for this Basys 3 + OV7670 module.
            8'h04: data = colorbar ? 16'h1206 : 16'h1204;
            8'h05: data = 16'h1100;
            8'h06: data = 16'h0C00;
            8'h07: data = 16'h3E00;
            8'h08: data = 16'h8C00;
            8'h09: data = 16'h0400;
            8'h0A: data = 16'h40D0; // COM15: RGB565, full output range
            8'h0B: data = 16'h3A04;
            8'h0C: data = 16'h1438; // COM9: keep enough AGC for usable low-light brightness
            8'h0D: data = 16'h4F80; // MTX1: reduce red/yellow cast on this module
            8'h0E: data = 16'h5080; // MTX2: reduce red/yellow cast on this module
            8'h0F: data = 16'h5100;
            8'h10: data = 16'h523D;
            8'h11: data = 16'h53A7;
            8'h12: data = 16'h54E4;
            8'h13: data = 16'h589E;
            8'h14: data = 16'h3DC0;
            8'h15: data = 16'h1100;
            8'h16: data = 16'h1711;
            8'h17: data = 16'h1861;
            8'h18: data = 16'h32A4;
            8'h19: data = 16'h1903;
            8'h1A: data = 16'h1A7B;
            8'h1B: data = 16'h030A;
            8'h1C: data = 16'h0E61;
            8'h1D: data = 16'h0F4B;
            8'h1E: data = 16'h1602;
            8'h1F: data = 16'h1E37;
            8'h20: data = 16'h2102;
            8'h21: data = 16'h2291;
            8'h22: data = 16'h2907;
            8'h23: data = 16'h330B;
            8'h24: data = 16'h350B;
            8'h25: data = 16'h371D;
            8'h26: data = 16'h3871;
            8'h27: data = 16'h392A;
            8'h28: data = 16'h3C78;
            8'h29: data = 16'h4D40;
            8'h2A: data = 16'h4E20;
            8'h2B: data = 16'h6900;
            8'h2C: data = 16'h6B4A;
            8'h2D: data = 16'h7410;
            8'h2E: data = 16'h8D4F;
            8'h2F: data = 16'h8E00;
            8'h30: data = 16'h8F00;
            8'h31: data = 16'h9000;
            8'h32: data = 16'h9100;
            8'h33: data = 16'h9600;
            8'h34: data = 16'h9A00;
            8'h35: data = 16'hB084;
            8'h36: data = 16'hB18C; // ABLC1: enable auto black-level calibration
            8'h37: data = 16'hB20E;
            8'h38: data = 16'hB382;
            8'h39: data = 16'hB80A;
            8'h3A: data = colorbar ? 16'h4208 : 16'h4200; // COM17 DSP color bars
            8'h3B: data = 16'h13E5; // COM8: enable AGC/AEC; AWB off so fixed gains hold
            8'h3C: data = 16'h4108; // COM16: enable color gain stage
            8'h3D: data = 16'h6F9F; // AWB control
            8'h3E: data = 16'h6A50; // green/red channel balance helper

            // Manual sensor-side pre-gain trim. With AWB disabled above, these
            // fixed red/blue gains keep the image from drifting frame to frame.
            8'h3F: data = 16'h0180; // blue AWB gain, default is 0x80
            8'h40: data = 16'h0250; // red AWB gain, default is 0x80
            8'h41: data = 16'hFFFF;
            default: data = 16'hFFFF;
        endcase
    end
endmodule
