// OV7670 configuration sequencer.
//
// The controller resets the camera, waits for it to settle, then writes the
// register table from ov7670_init_rom.v over SCCB. Toggling colorbar causes the
// sequence to run again, which is useful for showing the sensor's internal test
// pattern during debugging/demo.
module ov7670_init_controller #(
    // Keep reset/settle timing long in hardware, but allow fast simulation.
    parameter integer SETTLE_CYCLES = 200000,
    parameter integer SCCB_DIV = 2000
) (
    input  wire clk,
    input  wire reset,
    input  wire colorbar,
    output reg  camera_reset = 1'b0,
    output wire sioc,
    inout  wire siod,
    output reg  init_done = 1'b0
);
    reg [19:0] wait_ctr = 20'd0;
    reg start_tx = 1'b0;
    reg [7:0] tx_reg_addr = 8'h00;
    reg [7:0] tx_reg_data = 8'h00;
    wire tx_busy;
    wire tx_done;

    reg [7:0] rom_addr = 8'd0;
    wire [15:0] rom_word;
    reg colorbar_d = 1'b0;
    reg active_colorbar = 1'b0;
    reg colorbar_meta = 1'b0;
    reg colorbar_sync = 1'b0;

    ov7670_init_rom rom_u (
        .addr     (rom_addr),
        .colorbar (active_colorbar),
        .data     (rom_word)
    );

    sccb_write_byte #(
        .DIV(SCCB_DIV)
    ) sccb_u (
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

    localparam S_RESET = 3'd0;
    localparam S_WAIT  = 3'd1;
    localparam S_LOAD  = 3'd2;
    localparam S_START = 3'd3;
    localparam S_NEXT  = 3'd4;
    localparam S_DONE  = 3'd5;

    reg [2:0] state = S_RESET;

    always @(posedge clk) begin
        colorbar_meta <= colorbar;
        colorbar_sync <= colorbar_meta;

        if (reset) begin
            state <= S_RESET;
            wait_ctr <= 0;
            rom_addr <= 0;
            start_tx <= 0;
            init_done <= 0;
            camera_reset <= 1'b0;
            active_colorbar <= colorbar_sync;
            colorbar_d <= colorbar_sync;
        end else begin
            start_tx <= 0;

            if (init_done && (colorbar_sync != colorbar_d)) begin
                state <= S_RESET;
                wait_ctr <= 0;
                rom_addr <= 0;
                init_done <= 0;
                camera_reset <= 1'b0;
                active_colorbar <= colorbar_sync;
                colorbar_d <= colorbar_sync;
            end else case (state)
                // Hold OV7670 reset low long enough for a clean reconfiguration.
                S_RESET: begin
                    camera_reset <= 1'b0;
                    if (wait_ctr < SETTLE_CYCLES) begin
                        wait_ctr <= wait_ctr + 1'd1;
                    end else begin
                        camera_reset <= 1'b1;
                        wait_ctr <= 0;
                        state <= S_WAIT;
                    end
                end

                // Allow the sensor clock/reset state to settle before SCCB.
                S_WAIT: begin
                    camera_reset <= 1'b1;
                    if (wait_ctr < SETTLE_CYCLES) begin
                        wait_ctr <= wait_ctr + 1'd1; // initial settle
                    end else begin
                        state <= S_LOAD;
                    end
                end

                // Read the next ROM command. FFFE is a delay marker; FFFF ends.
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
