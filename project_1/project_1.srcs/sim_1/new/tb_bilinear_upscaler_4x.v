`timescale 1ns / 1ps

// Unit tests for the 4x RGB444 bilinear interpolation datapath. The row
// buffers are loaded directly so the expected fractional outputs are obvious.
module tb_bilinear_upscaler_4x;
    reg clk = 1'b0;
    reg frame_ready = 1'b1;
    reg [10:0] sx = 11'd0;
    reg [9:0] sy = 10'd0;
    reg active_video = 1'b1;
    wire [16:0] fb_addr;
    reg [11:0] fb_data = 12'h000;
    wire [11:0] rgb;
    wire valid;

    always #5 clk = ~clk;

    bilinear_upscaler_4x dut (
        .clk(clk),
        .frame_ready(frame_ready),
        .sx(sx),
        .sy(sy),
        .active_video(active_video),
        .fb_addr(fb_addr),
        .fb_data(fb_data),
        .rgb(rgb),
        .valid(valid)
    );

    task check_rgb;
        input [10:0] x_value;
        input [9:0] y_value;
        input [11:0] expected;
        begin
            sx = x_value;
            sy = y_value;
            #1;
            if (!valid || rgb != expected) begin
                $display("FAIL: sx=%0d sy=%0d rgb=%h valid=%b expected=%h",
                         x_value, y_value, rgb, valid, expected);
                $finish;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_bilinear_upscaler_4x.vcd");
        $dumpvars(0, tb_bilinear_upscaler_4x);

        dut.current_bank = 1'b0;
        dut.current_valid = 1'b1;
        dut.current_y = 8'd0;
        dut.bank_valid_a = 1'b1;
        dut.bank_y_a = 8'd0;
        dut.row0_a[0] = 12'h000;
        dut.row0_a[1] = 12'hF00;
        dut.row1_a[0] = 12'h0F0;
        dut.row1_a[1] = 12'h00F;

        check_rgb(11'd0, 10'd0, 12'h000);
        check_rgb(11'd1, 10'd0, 12'h300);
        check_rgb(11'd2, 10'd0, 12'h700);
        check_rgb(11'd3, 10'd0, 12'hB00);
        check_rgb(11'd0, 10'd1, 12'h030);
        check_rgb(11'd2, 10'd2, 12'h333);

        dut.current_y = 8'd239;
        dut.bank_y_a = 8'd239;
        dut.row0_a[319] = 12'hACE;
        dut.row1_a[319] = 12'hACE;
        check_rgb(11'd1279, 10'd956, 12'hACE);
        check_rgb(11'd1279, 10'd959, 12'hACE);

        // Regression for horizontal black bands: when bank B is the row being
        // displayed but current_bank still points at A for this clock edge,
        // prefetch must choose A and must not invalidate/display-clobber B.
        dut.current_bank = 1'b0;
        dut.bank_valid_a = 1'b1;
        dut.bank_y_a = 8'd0;
        dut.bank_valid_b = 1'b1;
        dut.bank_y_b = 8'd1;
        sx = 11'd0;
        sy = 10'd4;
        #1;
        if (dut.selected_bank != 1'b1 || dut.prefetch_target_bank != 1'b0) begin
            $display("FAIL: prefetch would overwrite displayed bank. selected=%b target=%b",
                     dut.selected_bank, dut.prefetch_target_bank);
            $finish;
        end

        $display("PASS: bilinear scaler interpolation and edge clamping are correct.");
        $finish;
    end
endmodule