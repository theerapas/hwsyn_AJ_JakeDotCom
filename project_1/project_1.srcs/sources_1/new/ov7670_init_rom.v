module ov7670_init_rom (
    input  wire [7:0] addr,
    output reg  [15:0] data
);
    always @(*) begin
        case (addr)
            8'd0:  data = 16'h1280; // COM7 reset
            8'd1:  data = 16'hFFFE; // delay

            8'd2:  data = 16'h1204; // COM7 RGB
            8'd3:  data = 16'h8C00; // RGB444 disable
            8'd4:  data = 16'h0400; // COM1
            8'd5:  data = 16'h40D0; // COM15 RGB565, full range
            8'd6:  data = 16'h3A04; // TSLB
            8'd7:  data = 16'h1418; // COM9 gain ceiling
            8'd8:  data = 16'h4F80; // matrix
            8'd9:  data = 16'h5030;
            8'd10: data = 16'h5100;
            8'd11: data = 16'h5232;
            8'd12: data = 16'h535E;
            8'd13: data = 16'h5480;
            8'd14: data = 16'h589E;
            8'd15: data = 16'h3DC0; // COM13
            8'd16: data = 16'h1101; // CLKRC
            8'd17: data = 16'h1716; // HSTART
            8'd18: data = 16'h1804; // HSTOP
            8'd19: data = 16'h32A4; // HREF
            8'd20: data = 16'h1902; // VSTART
            8'd21: data = 16'h1A7A; // VSTOP
            8'd22: data = 16'h030A; // VREF

            // QVGA scaling
            8'd23: data = 16'h0C04; // COM3 enable scaling
            8'd24: data = 16'h3E19; // COM14 divide + scaling
            8'd25: data = 16'h703A; // scaling xsc
            8'd26: data = 16'h7135; // scaling ysc
            8'd27: data = 16'h7211; // downsample DCW
            8'd28: data = 16'h73F1; // PCLK divider
            8'd29: data = 16'hA202; // scaling PCLK delay

            // AGC/AEC/AWB defaults commonly used
            8'd30: data = 16'h1500;
            8'd31: data = 16'h7A20;
            8'd32: data = 16'h7B10;
            8'd33: data = 16'h7C1E;
            8'd34: data = 16'h7D35;
            8'd35: data = 16'h7E5A;
            8'd36: data = 16'h7F69;
            8'd37: data = 16'h8076;
            8'd38: data = 16'h8180;
            8'd39: data = 16'h8288;
            8'd40: data = 16'h838F;
            8'd41: data = 16'h8496;
            8'd42: data = 16'h85A3;
            8'd43: data = 16'h86AF;
            8'd44: data = 16'h87C4;
            8'd45: data = 16'h88D7;
            8'd46: data = 16'h89E8;

            // Enable the OV7670 internal color bars for first hardware bring-up.
            // Once capture works, change this to 16'h4200 for normal camera image.
            8'd47: data = 16'h42F0; // COM17 color bar

            8'd48: data = 16'hFFFF;
            default: data = 16'hFFFF;
        endcase
    end
endmodule
