`timescale 1ns / 1ps

// 100 MHz Basys 3 clock to 108 MHz VGA pixel clock.
//
// Icarus simulation uses a pass-through clock so it does not need Xilinx
// primitive libraries. Vivado synthesis/simulation uses the MMCM path.
module vga_clock_108 (
    input  wire clk100,
    output wire clk108,
    output wire locked
);
`ifdef __ICARUS__
    assign clk108 = clk100;
    assign locked = 1'b1;
`else
    wire clkfb_unbuf;
    wire clkfb;
    wire clk108_unbuf;

    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKFBOUT_MULT_F(54.000),
        .CLKFBOUT_PHASE(0.000),
        .CLKIN1_PERIOD(10.000),
        .CLKOUT0_DIVIDE_F(10.000),
        .CLKOUT0_DUTY_CYCLE(0.500),
        .CLKOUT0_PHASE(0.000),
        .DIVCLK_DIVIDE(5),
        .REF_JITTER1(0.010),
        .STARTUP_WAIT("FALSE")
    ) mmcm_u (
        .CLKIN1(clk100),
        .CLKFBIN(clkfb),
        .CLKFBOUT(clkfb_unbuf),
        .CLKOUT0(clk108_unbuf),
        .CLKOUT1(),
        .CLKOUT2(),
        .CLKOUT3(),
        .CLKOUT4(),
        .CLKOUT5(),
        .CLKOUT6(),
        .LOCKED(locked),
        .PWRDWN(1'b0),
        .RST(1'b0)
    );

    BUFG clk108_bufg_u (
        .I(clk108_unbuf),
        .O(clk108)
    );

    BUFG clkfb_bufg_u (
        .I(clkfb_unbuf),
        .O(clkfb)
    );
`endif
endmodule
