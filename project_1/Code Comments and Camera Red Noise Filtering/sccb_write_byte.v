// =============================================================================
// sccb_write_byte.v
// -----------------------------------------------------------------------------
// Sends a single 3-byte SCCB transaction:
//
//        START | dev_addr (8 bits) | "ack" | reg_addr | "ack" | reg_data | "ack" | STOP
//
// SCCB is electrically I2C-like (open-drain SDA + SCL with external pull-ups).
// On the OV7670 the slave never acknowledges, so we three-state SDA during
// the ACK bit positions and the master simply continues.
//
// Timing: the bit clock is generated from a divide-by-DIV counter so that
// SCL runs at ~25 kHz from a 100 MHz core clock. That's well below the
// camera's max SCCB rate and very forgiving with weak pull-ups.
// =============================================================================

module sccb_write_byte (
    input  wire clk,                 // 100 MHz system clock
    input  wire reset,
    input  wire start,               // 1-cycle pulse: begin a transaction
    input  wire [7:0] dev_addr,      // OV7670 = 0x42 for write
    input  wire [7:0] reg_addr,      // register to program
    input  wire [7:0] reg_data,      // value to write
    output wire sioc,                // SCCB clock (push-pull from FPGA)
    inout  wire siod,                // SCCB data  (open-drain via tri-state)
    output reg  busy = 1'b0,         // 1 while a transaction is in progress
    output reg  done = 1'b0          // 1-cycle pulse when transaction completes
);
    // ---------- Clock divider: tick once every DIV cycles -------------------
    // 100e6 / 2000 = 50 kHz half-period -> 25 kHz SCL frequency.
    localparam DIV = 2000;

    reg [15:0] divcnt = 0;
    reg        scl    = 1'b1;
    reg        tick   = 1'b0;

    always @(posedge clk) begin
        if (reset) begin
            divcnt <= 0;
            tick   <= 0;
        end
        else begin
            if (divcnt == DIV-1) begin
                divcnt <= 0;
                tick   <= 1'b1;     // single-cycle "advance the SCCB FSM" pulse
            end
            else begin
                divcnt <= divcnt + 1'd1;
                tick   <= 1'b0;
            end
        end
    end

    // ---------- Open-drain SDA driver --------------------------------------
    // Drive 0 by pulling low; release ('z') for high so the external pull-up
    // can take the line up. Never drive the bus high directly.
    reg sda_out = 1'b1;
    reg sda_oe  = 1'b1;              // 1 when we are driving the bus

    assign sioc = scl;
    assign siod = (sda_oe && !sda_out) ? 1'b0 : 1'bz;

    // ---------- Bit-level state machine ------------------------------------
    // We cram all 27 bits we need to send into a shift register:
    //   { dev_addr[7:0], ack, reg_addr[7:0], ack, reg_data[7:0], ack }
    //                       ^slave-ack bits: we release SDA on these.
    reg [5:0]  bitcnt = 0;
    reg [26:0] shreg  = 27'h0;

    localparam I_IDLE  = 3'd0;
    localparam I_START = 3'd1;
    localparam I_BITL  = 3'd2;       // SCL low half-period: set up new SDA value
    localparam I_BITH  = 3'd3;       // SCL high half-period: hold SDA, advance
    localparam I_STOP0 = 3'd4;
    localparam I_STOP1 = 3'd5;
    localparam I_STOP2 = 3'd6;

    reg [2:0] state = I_IDLE;

    always @(posedge clk) begin
        if (reset) begin
            state   <= I_IDLE;
            busy    <= 1'b0;
            done    <= 1'b0;
            scl     <= 1'b1;
            sda_out <= 1'b1;
            sda_oe  <= 1'b1;
            bitcnt  <= 0;
        end
        else begin
            done <= 1'b0;            // default: not done

            // ---------- accept a new transaction request -------------------
            if ((state == I_IDLE) && start) begin
                scl     <= 1'b1;
                sda_out <= 1'b1;
                sda_oe  <= 1'b1;
                shreg   <= {dev_addr, 1'b1, reg_addr, 1'b1, reg_data, 1'b1};
                bitcnt  <= 6'd26;
                busy    <= 1'b1;
                state   <= I_START;
            end
            else if (tick) begin
                case (state)
                    // -------- bus idle: hold SDA and SCL high --------
                    I_IDLE: begin
                        scl     <= 1'b1;
                        sda_out <= 1'b1;
                        sda_oe  <= 1'b1;
                        busy    <= 1'b0;
                    end

                    // -------- START: SDA falls while SCL is high -----
                    I_START: begin
                        scl     <= 1'b1;
                        sda_out <= 1'b0;
                        state   <= I_BITL;
                    end

                    // -------- bit cell, low SCL phase -----------------
                    // Set up the new SDA bit. Release SDA (sda_oe=0) on
                    // the 9th, 18th, and 27th bits so the slave can ACK
                    // (we ignore what it actually drives).
                    I_BITL: begin
                        scl     <= 1'b0;
                        sda_oe  <= !((bitcnt == 6'd18) ||
                                     (bitcnt == 6'd9)  ||
                                     (bitcnt == 6'd0));
                        sda_out <= shreg[26];
                        state   <= I_BITH;
                    end

                    // -------- bit cell, high SCL phase ----------------
                    I_BITH: begin
                        scl   <= 1'b1;
                        shreg <= {shreg[25:0], 1'b1};
                        if (bitcnt == 0)
                            state <= I_STOP0;
                        else begin
                            bitcnt <= bitcnt - 1'd1;
                            state  <= I_BITL;
                        end
                    end

                    // -------- STOP sequence: SDA rises while SCL high
                    I_STOP0: begin
                        sda_oe  <= 1'b1;
                        scl     <= 1'b0;
                        sda_out <= 1'b0;
                        state   <= I_STOP1;
                    end

                    I_STOP1: begin
                        sda_oe  <= 1'b1;
                        scl     <= 1'b1;
                        sda_out <= 1'b0;
                        state   <= I_STOP2;
                    end

                    I_STOP2: begin
                        scl     <= 1'b1;
                        sda_out <= 1'b1;     // release: full STOP condition
                        busy    <= 1'b0;
                        done    <= 1'b1;     // 1-cycle "transaction complete"
                        state   <= I_IDLE;
                    end
                endcase
            end
        end
    end
endmodule
