# =============================================================================
# basys3_ov7670_fifo.xdc
# -----------------------------------------------------------------------------
# Pin and timing constraints for the OV7670 -> framebuffer -> VGA project on
# the Digilent Basys 3 (Artix-7 XC7A35T-1CPG236C).
#
# Switch mapping (sw[7:0]):
#   sw[0]   - VGA internal color-bar test pattern
#   sw[1]   - live raw camera-signal viewer
#   sw[4:2] - filter mode:  0 normal | 1 grayscale | 2 invert (negative)
#                           3 red    | 4 green     | 5 blue
#   sw[5]   - OV7670 internal color-bar test pattern
#             (toggling this causes camera config to re-run)
#   sw[7:6] - camera decode mode: 0 RGB565, 1 RGB565 swap, 2 YUYV, 3 UYVY
# =============================================================================

## ---------- 100 MHz board clock ----------
set_property -dict { PACKAGE_PIN W5  IOSTANDARD LVCMOS33 } [get_ports CLK100MHZ]
create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports CLK100MHZ]

## ---------- Slide switches ----------
set_property -dict { PACKAGE_PIN V17 IOSTANDARD LVCMOS33 } [get_ports {sw[0]}]
set_property -dict { PACKAGE_PIN V16 IOSTANDARD LVCMOS33 } [get_ports {sw[1]}]
set_property -dict { PACKAGE_PIN W16 IOSTANDARD LVCMOS33 } [get_ports {sw[2]}]
set_property -dict { PACKAGE_PIN W17 IOSTANDARD LVCMOS33 } [get_ports {sw[3]}]
set_property -dict { PACKAGE_PIN W15 IOSTANDARD LVCMOS33 } [get_ports {sw[4]}]
set_property -dict { PACKAGE_PIN V15 IOSTANDARD LVCMOS33 } [get_ports {sw[5]}]
set_property -dict { PACKAGE_PIN W14 IOSTANDARD LVCMOS33 } [get_ports {sw[6]}]
set_property -dict { PACKAGE_PIN W13 IOSTANDARD LVCMOS33 } [get_ports {sw[7]}]

## ---------- LEDs ----------
set_property -dict { PACKAGE_PIN U16 IOSTANDARD LVCMOS33 } [get_ports {led[0]}]
set_property -dict { PACKAGE_PIN E19 IOSTANDARD LVCMOS33 } [get_ports {led[1]}]
set_property -dict { PACKAGE_PIN U19 IOSTANDARD LVCMOS33 } [get_ports {led[2]}]
set_property -dict { PACKAGE_PIN V19 IOSTANDARD LVCMOS33 } [get_ports {led[3]}]
set_property -dict { PACKAGE_PIN W18 IOSTANDARD LVCMOS33 } [get_ports {led[4]}]
set_property -dict { PACKAGE_PIN U15 IOSTANDARD LVCMOS33 } [get_ports {led[5]}]
set_property -dict { PACKAGE_PIN U14 IOSTANDARD LVCMOS33 } [get_ports {led[6]}]
set_property -dict { PACKAGE_PIN V14 IOSTANDARD LVCMOS33 } [get_ports {led[7]}]
set_property -dict { PACKAGE_PIN V13 IOSTANDARD LVCMOS33 } [get_ports {led[8]}]
set_property -dict { PACKAGE_PIN V3  IOSTANDARD LVCMOS33 } [get_ports {led[9]}]
set_property -dict { PACKAGE_PIN W3  IOSTANDARD LVCMOS33 } [get_ports {led[10]}]
set_property -dict { PACKAGE_PIN U3  IOSTANDARD LVCMOS33 } [get_ports {led[11]}]
set_property -dict { PACKAGE_PIN P3  IOSTANDARD LVCMOS33 } [get_ports {led[12]}]
set_property -dict { PACKAGE_PIN N3  IOSTANDARD LVCMOS33 } [get_ports {led[13]}]
set_property -dict { PACKAGE_PIN P1  IOSTANDARD LVCMOS33 } [get_ports {led[14]}]
set_property -dict { PACKAGE_PIN L1  IOSTANDARD LVCMOS33 } [get_ports {led[15]}]

## ---------- OV7670 camera ----------
## Data bus D0..D7
set_property -dict { PACKAGE_PIN P17 IOSTANDARD LVCMOS33 } [get_ports {cam_d[0]}]
set_property -dict { PACKAGE_PIN N17 IOSTANDARD LVCMOS33 } [get_ports {cam_d[1]}]
set_property -dict { PACKAGE_PIN M19 IOSTANDARD LVCMOS33 } [get_ports {cam_d[2]}]
set_property -dict { PACKAGE_PIN M18 IOSTANDARD LVCMOS33 } [get_ports {cam_d[3]}]
set_property -dict { PACKAGE_PIN L17 IOSTANDARD LVCMOS33 } [get_ports {cam_d[4]}]
set_property -dict { PACKAGE_PIN K17 IOSTANDARD LVCMOS33 } [get_ports {cam_d[5]}]
set_property -dict { PACKAGE_PIN C16 IOSTANDARD LVCMOS33 } [get_ports {cam_d[6]}]
set_property -dict { PACKAGE_PIN B16 IOSTANDARD LVCMOS33 } [get_ports {cam_d[7]}]

## Sync / control signals
set_property -dict { PACKAGE_PIN A17 IOSTANDARD LVCMOS33 } [get_ports cam_href]
set_property -dict { PACKAGE_PIN A16 IOSTANDARD LVCMOS33 } [get_ports cam_pclk_buf]
set_property -dict { PACKAGE_PIN R18 IOSTANDARD LVCMOS33 } [get_ports cam_pwdn]
set_property -dict { PACKAGE_PIN P18 IOSTANDARD LVCMOS33 } [get_ports cam_reset]
set_property -dict { PACKAGE_PIN B15 IOSTANDARD LVCMOS33 } [get_ports cam_vsync]
set_property -dict { PACKAGE_PIN C15 IOSTANDARD LVCMOS33 } [get_ports cam_xclk]

## SCCB (I2C-like) bus.
## SIOD is open-drain; an internal pullup is enabled so the bus floats high
## when neither side is driving. Also enable a pullup on SIOC to be safe.
set_property -dict { PACKAGE_PIN A14 IOSTANDARD LVCMOS33 } [get_ports cam_sioc]
set_property -dict { PACKAGE_PIN A15 IOSTANDARD LVCMOS33 } [get_ports cam_siod]
set_property PULLUP true [get_ports cam_siod]
set_property PULLUP true [get_ports cam_sioc]

## ----- Camera PCLK input -----
## PCLK is wired to a non-clock-capable pin in the Basys 3 / OV7670 mapping.
## CLOCK_DEDICATED_ROUTE FALSE tells Vivado to route it to the BUFG anyway.
## (This is the standard work-around for this exact pinout.)
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -of_objects [get_ports cam_pclk_buf]]

## Tell the timer about the actual PCLK frequency. The OV7670 in QVGA RGB565
## mode runs PCLK at half the XCLK rate (we send 25 MHz XCLK, so PCLK ~12.5 MHz)
## but we let it run continuously, so we constrain at 24 MHz to be safe.
create_clock -name pclk -period 41.67 [get_ports cam_pclk_buf]

## The camera's PCLK and the system 25 MHz pixel clock are unrelated. The
## framebuffer is true dual-port BRAM and acts as the clock-domain crossing,
## so we mark the two clocks as asynchronous to one another to stop Vivado
## from reporting bogus cross-domain timing failures.
set_clock_groups -asynchronous \
  -group [get_clocks pclk] \
  -group [get_clocks sys_clk_pin]

## ---------- VGA DAC ----------
set_property -dict { PACKAGE_PIN G19 IOSTANDARD LVCMOS33 } [get_ports {vgaRed[0]}]
set_property -dict { PACKAGE_PIN H19 IOSTANDARD LVCMOS33 } [get_ports {vgaRed[1]}]
set_property -dict { PACKAGE_PIN J19 IOSTANDARD LVCMOS33 } [get_ports {vgaRed[2]}]
set_property -dict { PACKAGE_PIN N19 IOSTANDARD LVCMOS33 } [get_ports {vgaRed[3]}]

set_property -dict { PACKAGE_PIN J17 IOSTANDARD LVCMOS33 } [get_ports {vgaGreen[0]}]
set_property -dict { PACKAGE_PIN H17 IOSTANDARD LVCMOS33 } [get_ports {vgaGreen[1]}]
set_property -dict { PACKAGE_PIN G17 IOSTANDARD LVCMOS33 } [get_ports {vgaGreen[2]}]
set_property -dict { PACKAGE_PIN D17 IOSTANDARD LVCMOS33 } [get_ports {vgaGreen[3]}]

set_property -dict { PACKAGE_PIN N18 IOSTANDARD LVCMOS33 } [get_ports {vgaBlue[0]}]
set_property -dict { PACKAGE_PIN L18 IOSTANDARD LVCMOS33 } [get_ports {vgaBlue[1]}]
set_property -dict { PACKAGE_PIN K18 IOSTANDARD LVCMOS33 } [get_ports {vgaBlue[2]}]
set_property -dict { PACKAGE_PIN J18 IOSTANDARD LVCMOS33 } [get_ports {vgaBlue[3]}]

set_property -dict { PACKAGE_PIN P19 IOSTANDARD LVCMOS33 } [get_ports Hsync]
set_property -dict { PACKAGE_PIN R19 IOSTANDARD LVCMOS33 } [get_ports Vsync]
