`timescale 1ns / 1ps

module sccb_controller(
    input wire clk,         // 25MHz system clock
    output wire scl,        // SCCB Clock (SIO_C)
    inout wire sda          // SCCB Data (SIO_D)
);

    // OV7670 Write Device Address is 0x42[cite: 2]
    localparam CAMERA_WRITE_ADDR = 8'h42; 

    // SCCB operates at around 100kHz. 25MHz / 250 = 100kHz.
    reg [7:0] clk_divider = 0;
    reg sccb_clk = 0;
    
    always @(posedge clk) begin
        if (clk_divider == 124) begin
            sccb_clk <= ~sccb_clk;
            clk_divider <= 0;
        end else begin
            clk_divider <= clk_divider + 1;
        end
    end

    // Initialization ROM (Register Address, Data)
    // Expanded to include internal Digital Signal Processing (DSP) for better colors
    wire [15:0] init_rom [0:6];
    
    // Core Resolution and Format
    assign init_rom[0] = 16'h12_14; // COM7: QVGA, RGB[cite: 2]
    assign init_rom[1] = 16'h40_D0; // COM15: RGB565, Full Range[cite: 2]
    assign init_rom[2] = 16'h8C_00; // RGB444: Disable[cite: 2]
    
    // DSP and Color Correction (New Registers)
    assign init_rom[3] = 16'h13_8F; // COM8: Enable Fast AGC/AEC, AWB, AEC[cite: 2]
    assign init_rom[4] = 16'h3F_00; // EDGE: Edge enhancement adjustment[cite: 2]
    assign init_rom[5] = 16'h41_08; // COM16: Edge enhancement auto-adjustment enable[cite: 2]
    
    // End of transmission marker
    assign init_rom[6] = 16'hFF_FF;

    reg [7:0] reg_index = 0;
    reg [15:0] current_reg;
    reg [5:0] state = 0;
    reg [3:0] bit_counter = 0;
    reg [7:0] tx_data = 0;
    
    reg scl_reg = 1;
    reg sda_reg = 1;
    reg sda_dir = 1; // 1 = Output (FPGA drives SDA), 0 = Input (Camera drives SDA/Z)

    assign scl = scl_reg;
    // Tri-state buffer for inout SDA line to avoid bus contention during Don't-Care bits[cite: 3]
    assign sda = (sda_dir) ? sda_reg : 1'bz; 
// --- ADD THIS COUNTER HERE ---
    reg [19:0] delay_counter = 0; 
    // -----------------------------

    always @(posedge sccb_clk) begin
        case (state)
            0: begin // IDLE
                // --- REPLACE THE IDLE STATE WITH THIS DELAY LOGIC ---
                if (delay_counter < 20'hFFFFF) begin
                    delay_counter <= delay_counter + 1;
                end else begin
                    current_reg <= init_rom[reg_index];
                    if (init_rom[reg_index] != 16'hFFFF) begin
                        state <= 1;
                    end
                end
                // ----------------------------------------------------
            end
            
            1: begin // START Condition[cite: 3]
                sda_dir <= 1;
                sda_reg <= 0;
                scl_reg <= 1;
                state <= 2;
            end
            
            2: begin // Setup Phase 1: Device ID Address[cite: 3]
                scl_reg <= 0;
                tx_data <= CAMERA_WRITE_ADDR;
                bit_counter <= 7;
                state <= 3;
            end
            
            3: begin // TX Data Bits (used for Phase 1, 2, and 3)
                sda_dir <= 1;
                sda_reg <= tx_data[bit_counter];
                scl_reg <= 1;
                state <= 4;
            end
            
            4: begin // TX Data Clock Low
                scl_reg <= 0;
                if (bit_counter == 0) state <= 5;
                else begin
                    bit_counter <= bit_counter - 1;
                    state <= 3;
                end
            end
            
            5: begin // Wait for Don't-Care Bit (ACK)[cite: 3]
                sda_dir <= 0; // Release SDA line
                scl_reg <= 1;
                state <= 6;
            end
            
            6: begin // End Don't-Care Bit
                scl_reg <= 0;
                // Determine next phase based on current progress
                if (tx_data == CAMERA_WRITE_ADDR) begin
                    // Move to Phase 2: Sub-address (Register)[cite: 3]
                    tx_data <= current_reg[15:8];
                    bit_counter <= 7;
                    state <= 3;
                end else if (tx_data == current_reg[15:8]) begin
                    // Move to Phase 3: Write Data[cite: 3]
                    tx_data <= current_reg[7:0];
                    bit_counter <= 7;
                    state <= 3;
                end else begin
                    // Proceed to STOP condition
                    state <= 7;
                end
            end
            
            7: begin // STOP Condition Setup[cite: 3]
                sda_dir <= 1;
                sda_reg <= 0;
                scl_reg <= 1;
                state <= 8;
            end
            
            8: begin // STOP Condition Complete[cite: 3]
                sda_reg <= 1;
                reg_index <= reg_index + 1; // Move to next register in ROM
                state <= 0;
            end
        endcase
    end

endmodule