## ============================================================================
## ส่วนที่ 1: สัญญาณนาฬิกาหลักของระบบ (System Clock)
## ============================================================================
## รับสัญญาณนาฬิกา 100 MHz จากคริสตัลบนบอร์ด Basys 3 
## ในโปรเจกต์ Extra Credit สัญญาณนี้จะถูกส่งไปที่โมดูล MMCM (vga_clock_108) 
## เพื่อปั่นความถี่ขึ้นเป็น 108 MHz สำหรับขับเคลื่อนหน้าจอ 1280x960 ครับ
set_property -dict { PACKAGE_PIN W5 IOSTANDARD LVCMOS33 } [get_ports CLK100MHZ]
create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports CLK100MHZ]

## ============================================================================
## ส่วนที่ 2: สวิตช์สำหรับผู้ใช้งาน (User Input Switches)
## ============================================================================
## ใช้สำหรับควบคุมโหมดการแสดงผลต่างๆ แบบ Real-time
## sw[0] = สลับไปดูภาพ Color bars ที่ FPGA สร้างขึ้นเอง (เพื่อเช็คจอ VGA)
## sw[1] = สลับไปดูภาพสดจากกล้องดิบๆ (ยังไม่ผ่านฟิลเตอร์)
## sw[4:2] = เลือกฟิลเตอร์ภาพ (0=ปกติ, 1=ขาวดำ, 2=Invert สี, 3=แดง, 4=เขียว, 5=น้ำเงิน)
## sw[5] = สับเพื่อสั่งรีเซ็ตกล้อง และเปิดโหมด Color bars ที่สร้างจากเซนเซอร์กล้อง
set_property -dict { PACKAGE_PIN V17 IOSTANDARD LVCMOS33 } [get_ports {sw[0]}]
set_property -dict { PACKAGE_PIN V16 IOSTANDARD LVCMOS33 } [get_ports {sw[1]}]
set_property -dict { PACKAGE_PIN W16 IOSTANDARD LVCMOS33 } [get_ports {sw[2]}]
set_property -dict { PACKAGE_PIN W17 IOSTANDARD LVCMOS33 } [get_ports {sw[3]}]
set_property -dict { PACKAGE_PIN W15 IOSTANDARD LVCMOS33 } [get_ports {sw[4]}]
set_property -dict { PACKAGE_PIN V15 IOSTANDARD LVCMOS33 } [get_ports {sw[5]}]
set_property -dict { PACKAGE_PIN W14 IOSTANDARD LVCMOS33 } [get_ports {sw[6]}]
set_property -dict { PACKAGE_PIN W13 IOSTANDARD LVCMOS33 } [get_ports {sw[7]}]

## ============================================================================
## ส่วนที่ 3: หลอดไฟ LED แสดงสถานะ (Debug Indicators)
## ============================================================================
## ใช้ตรวจสอบสถานะการทำงานของฮาร์ดแวร์ เช่น 
## led[0] ติด = ตั้งค่ากล้องผ่าน SCCB สำเร็จแล้ว
## led[3] ติด = มีสัญญาณ Clock (PCLK) วิ่งมาจากกล้องแล้ว
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

## ============================================================================
## ส่วนที่ 4: พอร์ตเชื่อมต่อกับกล้อง OV7670 (Camera Interface)
## ============================================================================

## สายรับข้อมูลพิกเซลสี (Data Bus 8 บิต)
set_property -dict { PACKAGE_PIN P17 IOSTANDARD LVCMOS33 } [get_ports {cam_d[0]}]
set_property -dict { PACKAGE_PIN N17 IOSTANDARD LVCMOS33 } [get_ports {cam_d[1]}]
set_property -dict { PACKAGE_PIN M19 IOSTANDARD LVCMOS33 } [get_ports {cam_d[2]}]
set_property -dict { PACKAGE_PIN M18 IOSTANDARD LVCMOS33 } [get_ports {cam_d[3]}]
set_property -dict { PACKAGE_PIN L17 IOSTANDARD LVCMOS33 } [get_ports {cam_d[4]}]
set_property -dict { PACKAGE_PIN K17 IOSTANDARD LVCMOS33 } [get_ports {cam_d[5]}]
set_property -dict { PACKAGE_PIN C16 IOSTANDARD LVCMOS33 } [get_ports {cam_d[6]}]
set_property -dict { PACKAGE_PIN B16 IOSTANDARD LVCMOS33 } [get_ports {cam_d[7]}]

## สายสัญญาณซิงค์และควบคุมกล้อง
set_property -dict { PACKAGE_PIN A17 IOSTANDARD LVCMOS33 } [get_ports cam_href]   ;# บอกช่วงบรรทัดที่มีข้อมูลภาพ
set_property -dict { PACKAGE_PIN B15 IOSTANDARD LVCMOS33 } [get_ports cam_vsync]  ;# บอกจังหวะขึ้นเฟรมภาพใหม่
set_property -dict { PACKAGE_PIN R18 IOSTANDARD LVCMOS33 } [get_ports cam_pwdn]   ;# สาย Power down
set_property -dict { PACKAGE_PIN P18 IOSTANDARD LVCMOS33 } [get_ports cam_reset]  ;# สาย Hardware Reset
set_property -dict { PACKAGE_PIN C15 IOSTANDARD LVCMOS33 } [get_ports cam_xclk]   ;# ส่ง Clock 25 MHz ไปเลี้ยงกล้อง

## สายตั้งค่ากล้องผ่านโปรโตคอล SCCB (I2C)
set_property -dict { PACKAGE_PIN A14 IOSTANDARD LVCMOS33 } [get_ports cam_sioc]   ;# สาย Clock สำหรับ SCCB
set_property -dict { PACKAGE_PIN A15 IOSTANDARD LVCMOS33 } [get_ports cam_siod]   ;# สาย Data สำหรับ SCCB
set_property PULLUP true [get_ports cam_siod]                                     ;# เปิดตัวต้านทาน Pull-up ภายในชิป เพื่อรองรับการทำงานแบบ Open-drain

## สายรับ Clock จากกล้อง (PCLK)
set_property -dict { PACKAGE_PIN A16 IOSTANDARD LVCMOS33 } [get_ports cam_pclk_buf]

## [คำสั่งพิเศษ] อนุโลมให้พิน I/O ธรรมดา (A16) สามารถรับสัญญาณ Clock ได้
## ถ้าไม่ใส่คำสั่งนี้ Vivado จะ Compile ไม่ผ่านเพราะผิดกฎการเดินสาย Clock ของชิป
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -of_objects [get_ports cam_pclk_buf]]

## ============================================================================
## ส่วนที่ 5: พอร์ตส่งภาพออกจอคอมพิวเตอร์ (VGA Output)
## ============================================================================
## ต่อเข้ากับวงจรแปลงสัญญาณดิจิทัลเป็นอนาล็อก (DAC) บนบอร์ด
## รองรับสี 12 บิต (แดง 4 บิต, เขียว 4 บิต, น้ำเงิน 4 บิต = แสดงได้ 4,096 สี)

## กลุ่มสีแดง
set_property -dict { PACKAGE_PIN G19 IOSTANDARD LVCMOS33 } [get_ports {vgaRed[0]}]
set_property -dict { PACKAGE_PIN H19 IOSTANDARD LVCMOS33 } [get_ports {vgaRed[1]}]
set_property -dict { PACKAGE_PIN J19 IOSTANDARD LVCMOS33 } [get_ports {vgaRed[2]}]
set_property -dict { PACKAGE_PIN N19 IOSTANDARD LVCMOS33 } [get_ports {vgaRed[3]}]

## กลุ่มสีเขียว
set_property -dict { PACKAGE_PIN J17 IOSTANDARD LVCMOS33 } [get_ports {vgaGreen[0]}]
set_property -dict { PACKAGE_PIN H17 IOSTANDARD LVCMOS33 } [get_ports {vgaGreen[1]}]
set_property -dict { PACKAGE_PIN G17 IOSTANDARD LVCMOS33 } [get_ports {vgaGreen[2]}]
set_property -dict { PACKAGE_PIN D17 IOSTANDARD LVCMOS33 } [get_ports {vgaGreen[3]}]

## กลุ่มสีน้ำเงิน
set_property -dict { PACKAGE_PIN N18 IOSTANDARD LVCMOS33 } [get_ports {vgaBlue[0]}]
set_property -dict { PACKAGE_PIN L18 IOSTANDARD LVCMOS33 } [get_ports {vgaBlue[1]}]
set_property -dict { PACKAGE_PIN K18 IOSTANDARD LVCMOS33 } [get_ports {vgaBlue[2]}]
set_property -dict { PACKAGE_PIN J18 IOSTANDARD LVCMOS33 } [get_ports {vgaBlue[3]}]

## สัญญาณ Synchronization สั่งวาดจอภาพ
set_property -dict { PACKAGE_PIN P19 IOSTANDARD LVCMOS33 } [get_ports Hsync]  ;# ซิงค์แนวนอน
set_property -dict { PACKAGE_PIN R19 IOSTANDARD LVCMOS33 } [get_ports Vsync]  ;# ซิงค์แนวตั้ง