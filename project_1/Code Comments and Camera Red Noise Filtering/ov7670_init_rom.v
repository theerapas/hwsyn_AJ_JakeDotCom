// =============================================================================
// ov7670_init_rom.v
// -----------------------------------------------------------------------------
// Lookup ROM that holds the OV7670 register-programming sequence sent over
// SCCB at startup. The init controller walks `addr` from 0 upward and writes
// each {reg_addr, reg_value} pair to the camera until it sees the sentinel
// 16'hFFFF (= "end of list").
//
// Two special sentinel words:
//   16'hFFFE -> "wait" (the controller pauses for ~2 ms, no SCCB write)
//   16'hFFFF -> "stop" (init complete)
//
// The list below is a known-good QVGA RGB565 configuration. Compared to the
// previous version we:
//   * keep the resets at the start (mandatory after power-up)
//   * explicitly program QVGA via COM3 + COM14 + scaling registers
//   * select RGB565 with full 0..255 output range (COM15 = 0xD0)
//   * leave AGC / AWB / AEC enabled (COM8) so the sensor self-corrects color
//   * remove some duplicate / redundant writes that were in the old list
//   * `colorbar` switch enables the *DSP* color-bar test pattern (COM17[3])
// =============================================================================

module ov7670_init_rom (
    input  wire [7:0]  addr,        // index into the table (0..N)
    input  wire        colorbar,    // 1 = enable on-sensor color-bar test image
    output reg  [15:0] data         // {reg_addr[7:0], reg_value[7:0]}
);
    always @(*) begin
        case (addr)
            // -----------------------------------------------------------------
            // Step 1: software reset (write 0x80 to COM7 = 0x12), then wait
            // -----------------------------------------------------------------
            8'h00: data = 16'h1280;          // COM7: reset all registers
            8'h01: data = 16'hFFFE;          // wait

            // -----------------------------------------------------------------
            // Step 2: choose output format = QVGA RGB
            //   COM7 (0x12)  bit[2] = output format RGB,
            //                bit[4] = QVGA enable
            //                ==> 0x14 for RGB QVGA, or 0x16 for color bars+RGB+QVGA
            // -----------------------------------------------------------------
            8'h02: data = colorbar ? 16'h1216 : 16'h1214;

            // CLKRC (0x11): use external clock directly (no internal divide).
            //   bit[6] = use external XCLK directly,
            //   bits[5:0] = prescaler (0 = divide by 1)
            8'h03: data = 16'h1100;

            // COM3 (0x0C): enable DCW (down-sampling) for QVGA
            //   bit[2] = DCW enable, bit[3] = scale enable
            8'h04: data = 16'h0C04;

            // COM14 (0x3E): manual scaling, PCLK divider for QVGA
            //   bit[3] = DCW/scaling PCLK enable
            //   bits[2:0] = PCLK divider (1 = /2)
            8'h05: data = 16'h3E19;

            // Scaling registers for QVGA (0x70..0x73, 0x74..0x75 = pclk div)
            // These come from the OV7670 implementation guide for QVGA mode.
            8'h06: data = 16'h703A;          // SCALING_XSC
            8'h07: data = 16'h7135;          // SCALING_YSC
            8'h08: data = 16'h7211;          // SCALING_DCWCTR (1/2 H, 1/2 V)
            8'h09: data = 16'h73F1;          // SCALING_PCLK_DIV (/2)
            8'h0A: data = 16'hA202;          // SCALING_PCLK_DELAY

            // -----------------------------------------------------------------
            // Step 3: pick the pixel format = RGB565, full output range
            //   COM15 (0x40): bits[7:6]=11 -> 0..255 range,
            //                 bits[5:4]=01 -> RGB565
            //                 ==> 0xD0
            // -----------------------------------------------------------------
            8'h0B: data = 16'h40D0;

            // TSLB (0x3A): bit[3] cleared = output Y first in YUV (irrelevant
            // here since we are RGB), bit[0]=0. Set 0x04 = enable line buffer.
            8'h0C: data = 16'h3A04;

            // COM13 (0x3D): gamma enable + UV auto-saturation
            8'h0D: data = 16'h3DC0;

            // -----------------------------------------------------------------
            // Step 4: timing (HSTART/HSTOP/VSTART/VSTOP) and HREF
            // These are the OmniVision-recommended values for VGA timing,
            // which the QVGA scaler then halves automatically.
            // -----------------------------------------------------------------
            8'h0E: data = 16'h1713;          // HSTART
            8'h0F: data = 16'h1801;          // HSTOP
            8'h10: data = 16'h32B6;          // HREF
            8'h11: data = 16'h1903;          // VSTART
            8'h12: data = 16'h1A7B;          // VSTOP
            8'h13: data = 16'h030A;          // VREF

            // -----------------------------------------------------------------
            // Step 5: AGC / AEC / AWB (auto exposure & white balance)
            //   COM8 (0x13): enable AGC, AWB, AEC, and unfreeze them
            //                bit[0]=AEC, bit[1]=AWB, bit[2]=AGC,
            //                bit[5]=AEC step, bit[7]=fast AEC
            //   ==> 0xE7 enables all three with fast/unlimited step
            // -----------------------------------------------------------------
            8'h14: data = 16'h13E7;

            // COM16 (0x41): AWB gain enable, edge enhancement off
            8'h15: data = 16'h4108;

            // -----------------------------------------------------------------
            // Step 6: AWB gain control
            // These are the "magic numbers" from the OmniVision app note that
            // give a neutral white balance for indoor light. They mostly fix
            // the red/blue tint that you see with default AWB.
            // -----------------------------------------------------------------
            8'h16: data = 16'h6F9F;          // AWBCTR0
            8'h17: data = 16'h6A40;          // GGAIN: green channel pre-gain

            // Matrix coefficients MTX1..MTX6 + sign byte MTXS
            // These convert the sensor's raw RGB into a more accurate RGB
            // for display. Using the OV7670 datasheet's "office light" set.
            8'h18: data = 16'h4F80;          // MTX1
            8'h19: data = 16'h5080;          // MTX2
            8'h1A: data = 16'h5100;          // MTX3
            8'h1B: data = 16'h5222;          // MTX4
            8'h1C: data = 16'h535E;          // MTX5
            8'h1D: data = 16'h5480;          // MTX6
            8'h1E: data = 16'h589E;          // MTXS

            // -----------------------------------------------------------------
            // Step 7: brightness, contrast, gamma curve
            // -----------------------------------------------------------------
            8'h1F: data = 16'h5500;          // BRIGHT (0 = neutral)
            8'h20: data = 16'h5640;          // CONTRAS (0x40 = neutral)
            8'h21: data = 16'h5780;          // CONTRAS-CENTER

            // Gamma curve points (slope segments). Default OmniVision values.
            8'h22: data = 16'h7A20;
            8'h23: data = 16'h7B1C;
            8'h24: data = 16'h7C28;
            8'h25: data = 16'h7D3C;
            8'h26: data = 16'h7E55;
            8'h27: data = 16'h7F68;
            8'h28: data = 16'h8076;
            8'h29: data = 16'h8180;
            8'h2A: data = 16'h8288;
            8'h2B: data = 16'h838F;
            8'h2C: data = 16'h8496;
            8'h2D: data = 16'h85A3;
            8'h2E: data = 16'h86AF;
            8'h2F: data = 16'h87C4;
            8'h30: data = 16'h88D7;
            8'h31: data = 16'h89E8;

            // -----------------------------------------------------------------
            // Step 8: misc DSP knobs that improve the picture
            // -----------------------------------------------------------------
            8'h32: data = 16'h6985;          // GFIX
            8'h33: data = 16'h7410;          // REG74 (digital gain)
            8'h34: data = 16'h8D4F;          // RSVD - undocumented but recommended
            8'h35: data = 16'h8E00;
            8'h36: data = 16'h8F00;
            8'h37: data = 16'h9000;
            8'h38: data = 16'h9100;
            8'h39: data = 16'h9600;
            8'h3A: data = 16'h9A00;
            8'h3B: data = 16'hB084;
            8'h3C: data = 16'hB10C;
            8'h3D: data = 16'hB20E;
            8'h3E: data = 16'hB382;
            8'h3F: data = 16'hB80A;

            // COM17 (0x42): DSP color-bar test pattern when sw[5] is on
            8'h40: data = colorbar ? 16'h4208 : 16'h4200;

            // End-of-list sentinel
            8'h41: data = 16'hFFFF;
            default: data = 16'hFFFF;
        endcase
    end
endmodule
