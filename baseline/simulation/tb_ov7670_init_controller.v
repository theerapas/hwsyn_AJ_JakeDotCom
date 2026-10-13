`timescale 1ns / 1ps

// Test the OV7670 initialization sequencer. The settle time and SCCB divider
// are reduced for simulation, but the state-machine behavior is the same as
// hardware: reset, wait, write the ROM table, and re-run on colorbar toggle.
module tb_ov7670_init_controller;
    reg clk = 1'b0;
    reg reset = 1'b1;
    reg colorbar = 1'b0;
    wire camera_reset;
    wire sioc;
    tri1 siod;
    wire init_done;

    integer cycles = 0;

    always #5 clk = ~clk; // 100 MHz

    ov7670_init_controller #(
        .SETTLE_CYCLES(8),
        .SCCB_DIV(4)
    ) dut (
        .clk(clk),
        .reset(reset),
        .colorbar(colorbar),
        .camera_reset(camera_reset),
        .sioc(sioc),
        .siod(siod),
        .init_done(init_done)
    );

    initial begin
        $dumpfile("tb_ov7670_init_controller.vcd");
        $dumpvars(0, tb_ov7670_init_controller);

        repeat (4) @(posedge clk);
        reset <= 1'b0;

        while (!init_done && cycles < 200000) begin
            @(posedge clk);
            cycles = cycles + 1;
        end

        if (!init_done) begin
            $display("FAIL: init_done was not asserted.");
            $finish;
        end

        if (camera_reset != 1'b1) begin
            $display("FAIL: camera_reset was not released.");
            $finish;
        end

        colorbar <= 1'b1;
        @(posedge clk);
        wait (init_done == 1'b0);
        wait (init_done == 1'b1);

        $display("PASS: OV7670 init sequence completed and re-ran after colorbar toggle.");
        $finish;
    end
endmodule
