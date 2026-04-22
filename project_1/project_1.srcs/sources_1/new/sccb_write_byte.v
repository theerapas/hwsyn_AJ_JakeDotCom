module sccb_write_byte (
    input  wire clk,
    input  wire reset,
    input  wire start,
    input  wire [7:0] dev_addr,
    input  wire [7:0] reg_addr,
    input  wire [7:0] reg_data,
    output wire sioc,
    inout  wire siod,
    output reg  busy = 1'b0,
    output reg  done = 1'b0
);
    localparam DIV = 500; // ~100kHz from 100MHz

    reg [15:0] divcnt = 0;
    reg scl = 1'b1;
    reg tick = 1'b0;

    always @(posedge clk) begin
        if (reset) begin
            divcnt <= 0;
            tick <= 0;
        end else begin
            if (divcnt == DIV-1) begin
                divcnt <= 0;
                tick <= 1'b1;
            end else begin
                divcnt <= divcnt + 1'd1;
                tick <= 1'b0;
            end
        end
    end

    reg sda_out = 1'b1;
    reg sda_oe  = 1'b1;
    assign sioc = scl;
    assign siod = sda_oe ? sda_out : 1'bz;

    reg [5:0] bitcnt = 0;
    reg [26:0] shreg = 27'h0;

    localparam I_IDLE  = 3'd0;
    localparam I_START = 3'd1;
    localparam I_BITL  = 3'd2;
    localparam I_BITH  = 3'd3;
    localparam I_STOP1 = 3'd4;
    localparam I_STOP2 = 3'd5;

    reg [2:0] state = I_IDLE;

    always @(posedge clk) begin
        if (reset) begin
            state <= I_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            scl <= 1'b1;
            sda_out <= 1'b1;
            sda_oe <= 1'b1;
            bitcnt <= 0;
        end else begin
            done <= 1'b0;

            if ((state == I_IDLE) && start) begin
                scl <= 1'b1;
                sda_out <= 1'b1;
                sda_oe <= 1'b1;
                shreg <= {dev_addr, 1'b1, reg_addr, 1'b1, reg_data, 1'b1};
                bitcnt <= 6'd26;
                busy <= 1'b1;
                state <= I_START;
            end else if (tick) begin
                case (state)
                    I_IDLE: begin
                        scl <= 1'b1;
                        sda_out <= 1'b1;
                        sda_oe <= 1'b1;
                        busy <= 1'b0;
                    end

                    I_START: begin
                        scl <= 1'b1;
                        sda_out <= 1'b0;
                        state <= I_BITL;
                    end

                    I_BITL: begin
                        scl <= 1'b0;
                        sda_oe <= !((bitcnt == 6'd18) || (bitcnt == 6'd9) || (bitcnt == 6'd0));
                        sda_out <= shreg[26];
                        state <= I_BITH;
                    end

                    I_BITH: begin
                        scl <= 1'b1;
                        shreg <= {shreg[25:0],1'b1};
                        if (bitcnt == 0)
                            state <= I_STOP1;
                        else begin
                            bitcnt <= bitcnt - 1'd1;
                            state <= I_BITL;
                        end
                    end

                    I_STOP1: begin
                        sda_oe <= 1'b1;
                        scl <= 1'b0;
                        sda_out <= 1'b0;
                        state <= I_STOP2;
                    end

                    I_STOP2: begin
                        scl <= 1'b1;
                        sda_out <= 1'b1;
                        busy <= 1'b0;
                        done <= 1'b1;
                        state <= I_IDLE;
                    end
                endcase
            end
        end
    end
endmodule
