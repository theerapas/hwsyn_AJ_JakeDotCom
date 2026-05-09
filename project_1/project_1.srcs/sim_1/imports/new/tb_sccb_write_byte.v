`timescale 1ns / 1ps

// Test one SCCB register-write transaction. The test checks that the write
// engine pulses done once, returns the bus to idle, and produces SIOC activity.
module tb_sccb_write_byte;
    reg clk = 1'b0;
    reg reset = 1'b1;
    reg start = 1'b0;
    wire sioc;
    tri1 siod;
    wire busy;
    wire done;

    integer done_count = 0;
    integer sioc_edges = 0;
    reg sioc_d = 1'b1;

    always #5 clk = ~clk; // 100 MHz

    sccb_write_byte #(
        .DIV(8)
    ) dut (
        .clk(clk),
        .reset(reset),
        .start(start),
        .dev_addr(8'h42),
        .reg_addr(8'h12),
        .reg_data(8'h04),
        .sioc(sioc),
        .siod(siod),
        .busy(busy),
        .done(done)
    );

    always @(posedge clk) begin
        sioc_d <= sioc;
        if (sioc_d != sioc) sioc_edges = sioc_edges + 1;
        if (done) done_count = done_count + 1;
    end

    initial begin
        $dumpfile("tb_sccb_write_byte.vcd");
        $dumpvars(0, tb_sccb_write_byte);

        repeat (5) @(posedge clk);
        reset <= 1'b0;
        repeat (5) @(posedge clk);

        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        wait (done == 1'b1);
        repeat (20) @(posedge clk);

        if (done_count != 1) begin
            $display("FAIL: done_count = %0d", done_count);
            $finish;
        end

        if (busy != 1'b0 || sioc != 1'b1 || siod != 1'b1) begin
            $display("FAIL: bus did not return to idle. busy=%b sioc=%b siod=%b", busy, sioc, siod);
            $finish;
        end

        if (sioc_edges < 50) begin
            $display("FAIL: too few SIOC transitions: %0d", sioc_edges);
            $finish;
        end

        $display("PASS: SCCB write produced one transaction and returned to idle.");
        $finish;
    end
endmodule
