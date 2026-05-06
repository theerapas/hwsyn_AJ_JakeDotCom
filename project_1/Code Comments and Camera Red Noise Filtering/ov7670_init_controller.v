// =============================================================================
// ov7670_init_controller.v
// -----------------------------------------------------------------------------
// Walks through the table in `ov7670_init_rom` and sends each entry to the
// OV7670 over SCCB (an I2C-like bus) using `sccb_write_byte`.
//
// State machine flow:
//
//   S_RESET  --200k cycles--> assert camera reset, then S_WAIT
//   S_WAIT   --200k cycles--> wait for the camera to settle, then S_LOAD
//   S_LOAD   --read rom_word-->
//                if 0xFFFF -> S_DONE (init finished)
//                if 0xFFFE -> S_WAIT (insert delay), advance rom address
//                else      -> latch addr/data, go to S_START
//   S_START  --tx not busy--> pulse start, go to S_NEXT
//   S_NEXT   --tx done    --> advance rom address, go back to S_LOAD
//   S_DONE   --             --> assert init_done forever (until colorbar toggle)
//
// If the user toggles the `colorbar` switch after init is done we restart the
// whole sequence so the new test-pattern setting takes effect.
// =============================================================================

module ov7670_init_controller (
    input  wire clk,                 // 100 MHz system clock
    input  wire reset,
    input  wire colorbar,            // user switch: enable on-sensor color bars
    output reg  camera_reset = 1'b0, // active-high here, inverted at top level if needed
    output wire sioc,                // SCCB clock (driven by sccb_write_byte)
    inout  wire siod,                // SCCB data  (open-drain)
    output reg  init_done = 1'b0
);
    // ---------- delay counter for camera reset / settle ----------------------
    reg [19:0] wait_ctr = 20'd0;

    // ---------- handshake to sccb_write_byte ---------------------------------
    reg        start_tx    = 1'b0;
    reg [7:0]  tx_reg_addr = 8'h00;
    reg [7:0]  tx_reg_data = 8'h00;
    wire       tx_busy;
    wire       tx_done;

    // ---------- ROM walker pointer -------------------------------------------
    reg  [7:0] rom_addr = 8'd0;
    wire [15:0] rom_word;

    // ---------- 2-FF synchroniser for the colorbar switch -------------------
    // The switch comes from a user button which is asynchronous to `clk`.
    reg colorbar_meta = 1'b0;
    reg colorbar_sync = 1'b0;
    reg colorbar_d    = 1'b0;       // last value we used to start an init pass
    reg active_colorbar = 1'b0;     // value held throughout one init pass

    // -------------------- ROM that holds register values --------------------
    ov7670_init_rom rom_u (
        .addr     (rom_addr),
        .colorbar (active_colorbar),
        .data     (rom_word)
    );

    // -------------------- SCCB byte transmitter -----------------------------
    sccb_write_byte sccb_u (
        .clk      (clk),
        .reset    (reset),
        .start    (start_tx),
        .dev_addr (8'h42),         // OV7670 SCCB write address (0x42)
        .reg_addr (tx_reg_addr),
        .reg_data (tx_reg_data),
        .sioc     (sioc),
        .siod     (siod),
        .busy     (tx_busy),
        .done     (tx_done)
    );

    // -------------------- main FSM -----------------------------------------
    localparam S_RESET = 3'd0;
    localparam S_WAIT  = 3'd1;
    localparam S_LOAD  = 3'd2;
    localparam S_START = 3'd3;
    localparam S_NEXT  = 3'd4;
    localparam S_DONE  = 3'd5;

    reg [2:0] state = S_RESET;

    always @(posedge clk) begin
        // Synchronise the colorbar switch into the clk domain (2 FFs).
        colorbar_meta <= colorbar;
        colorbar_sync <= colorbar_meta;

        if (reset) begin
            state           <= S_RESET;
            wait_ctr        <= 0;
            rom_addr        <= 0;
            start_tx        <= 0;
            init_done       <= 0;
            camera_reset    <= 1'b0;
            active_colorbar <= colorbar_sync;
            colorbar_d      <= colorbar_sync;
        end
        else begin
            start_tx <= 1'b0;     // default: don't start a new transmission

            // If the user toggled the colorbar switch after init completed,
            // re-run the whole init pass so the change takes effect.
            if (init_done && (colorbar_sync != colorbar_d)) begin
                state           <= S_RESET;
                wait_ctr        <= 0;
                rom_addr        <= 0;
                init_done       <= 0;
                camera_reset    <= 1'b0;
                active_colorbar <= colorbar_sync;
                colorbar_d      <= colorbar_sync;
            end
            else case (state)
                // ---------- 1) hold camera in reset for ~2 ms ----------
                S_RESET: begin
                    camera_reset <= 1'b0;
                    if (wait_ctr < 20'd200000) begin
                        wait_ctr <= wait_ctr + 1'd1;
                    end
                    else begin
                        camera_reset <= 1'b1;
                        wait_ctr     <= 0;
                        state        <= S_WAIT;
                    end
                end

                // ---------- 2) wait for camera to settle after reset --
                S_WAIT: begin
                    camera_reset <= 1'b1;
                    if (wait_ctr < 20'd200000) begin
                        wait_ctr <= wait_ctr + 1'd1;
                    end
                    else begin
                        state <= S_LOAD;
                    end
                end

                // ---------- 3) read next entry from ROM ---------------
                S_LOAD: begin
                    if (rom_word == 16'hFFFF) begin
                        // sentinel: end of init list
                        state <= S_DONE;
                    end
                    else if (rom_word == 16'hFFFE) begin
                        // sentinel: insert a delay and skip this entry
                        wait_ctr <= 0;
                        state    <= S_WAIT;
                        rom_addr <= rom_addr + 1'd1;
                    end
                    else begin
                        // real entry: split into reg-addr + reg-data
                        tx_reg_addr <= rom_word[15:8];
                        tx_reg_data <= rom_word[7:0];
                        state       <= S_START;
                    end
                end

                // ---------- 4) start a single SCCB transaction --------
                S_START: begin
                    if (!tx_busy) begin
                        start_tx <= 1'b1;
                        state    <= S_NEXT;
                    end
                end

                // ---------- 5) wait for the byte writer to finish -----
                S_NEXT: begin
                    if (tx_done) begin
                        rom_addr <= rom_addr + 1'd1;
                        state    <= S_LOAD;
                    end
                end

                // ---------- 6) latch init_done forever ----------------
                S_DONE: begin
                    init_done <= 1'b1;
                end
            endcase
        end
    end
endmodule
