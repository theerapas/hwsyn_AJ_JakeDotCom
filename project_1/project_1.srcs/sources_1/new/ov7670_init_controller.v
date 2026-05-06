module ov7670_init_controller (
    input  wire clk,
    input  wire reset,
    input  wire colorbar,
    output wire sioc,
    inout  wire siod,
    output reg  init_done = 1'b0
);
    localparam CLK_DIV = 500; // 100MHz / (2*500) = 100kHz-ish SCCB bit timing

    reg [15:0] wait_ctr = 16'd0;
    reg start_tx = 1'b0;
    reg [7:0] tx_reg_addr = 8'h00;
    reg [7:0] tx_reg_data = 8'h00;
    wire tx_busy;
    wire tx_done;

    reg [7:0] rom_addr = 8'd0;
    wire [15:0] rom_word;

    ov7670_init_rom rom_u (
        .addr     (rom_addr),
        .colorbar (colorbar),
        .data     (rom_word)
    );

    sccb_write_byte sccb_u (
        .clk         (clk),
        .reset       (reset),
        .start       (start_tx),
        .dev_addr    (8'h42),  // OV7670 write address
        .reg_addr    (tx_reg_addr),
        .reg_data    (tx_reg_data),
        .sioc        (sioc),
        .siod        (siod),
        .busy        (tx_busy),
        .done        (tx_done)
    );

    localparam S_WAIT  = 3'd0;
    localparam S_LOAD  = 3'd1;
    localparam S_START = 3'd2;
    localparam S_NEXT  = 3'd3;
    localparam S_DONE  = 3'd4;

    reg [2:0] state = S_WAIT;

    always @(posedge clk) begin
        if (reset) begin
            state <= S_WAIT;
            wait_ctr <= 0;
            rom_addr <= 0;
            start_tx <= 0;
            init_done <= 0;
        end else begin
            start_tx <= 0;

            case (state)
                S_WAIT: begin
                    if (wait_ctr < 16'd50000) begin
                        wait_ctr <= wait_ctr + 1'd1; // initial settle
                    end else begin
                        state <= S_LOAD;
                    end
                end

                S_LOAD: begin
                    if (rom_word == 16'hFFFF) begin
                        state <= S_DONE;
                    end else if (rom_word == 16'hFFFE) begin
                        wait_ctr <= 0;
                        state <= S_WAIT;
                        rom_addr <= rom_addr + 1'd1;
                    end else begin
                        tx_reg_addr <= rom_word[15:8];
                        tx_reg_data <= rom_word[7:0];
                        state <= S_START;
                    end
                end

                S_START: begin
                    if (!tx_busy) begin
                        start_tx <= 1'b1;
                        state <= S_NEXT;
                    end
                end

                S_NEXT: begin
                    if (tx_done) begin
                        rom_addr <= rom_addr + 1'd1;
                        state <= S_LOAD;
                    end
                end

                S_DONE: begin
                    init_done <= 1'b1;
                end
            endcase
        end
    end
endmodule
