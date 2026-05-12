`timescale 1ns / 1ps

// 320x240 RGB444 to 1280x960 RGB444 bilinear scaler.
//
// The scaler reads one framebuffer pixel at a time into two-row buffers while
// the currently displayed row pair is produced from the opposite buffer. This
// keeps the large framebuffer at 320x240 and avoids needing four framebuffer
// reads per 108 MHz VGA pixel.
module bilinear_upscaler_4x (
    input  wire        clk,
    input  wire        frame_ready,
    input  wire [10:0] sx,
    input  wire [9:0]  sy,
    input  wire        active_video,
    output reg  [16:0] fb_addr = 17'd0,
    input  wire [11:0] fb_data,
    output wire [11:0] rgb,
    output wire        valid
);
    localparam FRAME_WIDTH  = 320;
    localparam FRAME_HEIGHT = 240;

    (* ram_style = "distributed" *) reg [11:0] row0_a [0:FRAME_WIDTH-1];
    (* ram_style = "distributed" *) reg [11:0] row1_a [0:FRAME_WIDTH-1];
    (* ram_style = "distributed" *) reg [11:0] row0_b [0:FRAME_WIDTH-1];
    (* ram_style = "distributed" *) reg [11:0] row1_b [0:FRAME_WIDTH-1];

    reg current_bank = 1'b0;
    reg current_valid = 1'b0;
    reg [7:0] current_y = 8'd0;

    reg bank_valid_a = 1'b0;
    reg bank_valid_b = 1'b0;
    reg [7:0] bank_y_a = 8'd0;
    reg [7:0] bank_y_b = 8'd0;

    reg prefetch_busy = 1'b0;
    reg prefetch_bank = 1'b0;
    reg [7:0] prefetch_y = 8'd0;
    reg [8:0] prefetch_x = 9'd0;
    reg       prefetch_row = 1'b0;
    reg       rd_pending = 1'b0;
    reg       pending_bank = 1'b0;
    reg       pending_row = 1'b0;
    reg [8:0] pending_x = 9'd0;

    wire [7:0] display_y = sy[9:2];
    wire [7:0] desired_prefetch_y =
        (!active_video && (sy >= 10'd960)) ? 8'd0 :
        (display_y == 8'd239) ? 8'd239 : (display_y + 8'd1);

    wire bank_a_matches_display = bank_valid_a && (bank_y_a == display_y);
    wire bank_b_matches_display = bank_valid_b && (bank_y_b == display_y);
    wire selected_bank = bank_a_matches_display ? 1'b0 :
                         bank_b_matches_display ? 1'b1 : current_bank;
    wire prefetch_target_bank = bank_a_matches_display ? 1'b1 :
                                bank_b_matches_display ? 1'b0 : ~current_bank;
    wire any_bank_has_desired =
        (bank_valid_a && (bank_y_a == desired_prefetch_y)) ||
        (bank_valid_b && (bank_y_b == desired_prefetch_y));

    function [16:0] make_addr;
        input [7:0] y;
        input [8:0] x;
        begin
            make_addr = ({9'd0, y} << 8) + ({9'd0, y} << 6) + {8'd0, x};
        end
    endfunction

    always @(posedge clk) begin
        if (rd_pending) begin
            if (!pending_bank) begin
                if (!pending_row) row0_a[pending_x] <= fb_data;
                else              row1_a[pending_x] <= fb_data;
            end else begin
                if (!pending_row) row0_b[pending_x] <= fb_data;
                else              row1_b[pending_x] <= fb_data;
            end

            rd_pending <= 1'b0;
            if (pending_row && (pending_x == FRAME_WIDTH-1)) begin
                prefetch_busy <= 1'b0;
                if (!pending_bank) begin
                    bank_valid_a <= 1'b1;
                    bank_y_a <= prefetch_y;
                end else begin
                    bank_valid_b <= 1'b1;
                    bank_y_b <= prefetch_y;
                end
            end else if (pending_x == FRAME_WIDTH-1) begin
                prefetch_row <= 1'b1;
                prefetch_x <= 9'd0;
            end else begin
                prefetch_x <= pending_x + 9'd1;
            end
        end else if (prefetch_busy) begin
            fb_addr <= make_addr(prefetch_row ? ((prefetch_y == 8'd239) ? 8'd239 : prefetch_y + 8'd1) : prefetch_y,
                                 prefetch_x);
            pending_bank <= prefetch_bank;
            pending_row <= prefetch_row;
            pending_x <= prefetch_x;
            rd_pending <= 1'b1;
        end else if (frame_ready && !any_bank_has_desired) begin
            prefetch_busy <= 1'b1;
            prefetch_bank <= prefetch_target_bank;
            prefetch_y <= desired_prefetch_y;
            prefetch_x <= 9'd0;
            prefetch_row <= 1'b0;
            if (!prefetch_target_bank) bank_valid_a <= 1'b0;
            else                       bank_valid_b <= 1'b0;
        end

        if (active_video && (sx == 11'd0) && (sy[1:0] == 2'b00)) begin
            if (!current_bank && bank_valid_a && (bank_y_a == display_y)) begin
                current_valid <= 1'b1;
                current_y <= display_y;
            end else if (current_bank && bank_valid_b && (bank_y_b == display_y)) begin
                current_valid <= 1'b1;
                current_y <= display_y;
            end else if (!current_bank && bank_valid_b && (bank_y_b == display_y)) begin
                current_bank <= 1'b1;
                current_valid <= 1'b1;
                current_y <= display_y;
            end else if (current_bank && bank_valid_a && (bank_y_a == display_y)) begin
                current_bank <= 1'b0;
                current_valid <= 1'b1;
                current_y <= display_y;
            end else begin
                current_valid <= 1'b0;
            end
        end
    end

    wire [8:0] src_x = sx[10:2];
    wire [8:0] src_x1 = (src_x == 9'd319) ? 9'd319 : (src_x + 9'd1);
    wire [1:0] frac_x = sx[1:0];
    wire [1:0] frac_y = sy[1:0];

    wire [11:0] p00 = !selected_bank ? row0_a[src_x]  : row0_b[src_x];
    wire [11:0] p10 = !selected_bank ? row0_a[src_x1] : row0_b[src_x1];
    wire [11:0] p01 = !selected_bank ? row1_a[src_x]  : row1_b[src_x];
    wire [11:0] p11 = !selected_bank ? row1_a[src_x1] : row1_b[src_x1];

    function [5:0] hmix4;
        input [3:0] a;
        input [3:0] b;
        input [1:0] frac;
        begin
            case (frac)
                2'd0: hmix4 = {a, 2'b00};
                2'd1: hmix4 = ({2'b00, a} << 1) + {2'b00, a} + {2'b00, b};
                2'd2: hmix4 = ({2'b00, a} << 1) + ({2'b00, b} << 1);
                default: hmix4 = {2'b00, a} + ({2'b00, b} << 1) + {2'b00, b};
            endcase
        end
    endfunction

    function [3:0] vmix4;
        input [5:0] top_scaled;
        input [5:0] bottom_scaled;
        input [1:0] frac;
        reg [7:0] scaled16;
        begin
            case (frac)
                2'd0: scaled16 = {top_scaled, 2'b00};
                2'd1: scaled16 = ({2'b00, top_scaled} << 1) + {2'b00, top_scaled} + {2'b00, bottom_scaled};
                2'd2: scaled16 = ({2'b00, top_scaled} << 1) + ({2'b00, bottom_scaled} << 1);
                default: scaled16 = {2'b00, top_scaled} + ({2'b00, bottom_scaled} << 1) + {2'b00, bottom_scaled};
            endcase
            vmix4 = scaled16[7:4];
        end
    endfunction

    wire [5:0] r_top = hmix4(p00[11:8], p10[11:8], frac_x);
    wire [5:0] r_bot = hmix4(p01[11:8], p11[11:8], frac_x);
    wire [5:0] g_top = hmix4(p00[7:4], p10[7:4], frac_x);
    wire [5:0] g_bot = hmix4(p01[7:4], p11[7:4], frac_x);
    wire [5:0] b_top = hmix4(p00[3:0], p10[3:0], frac_x);
    wire [5:0] b_bot = hmix4(p01[3:0], p11[3:0], frac_x);

    assign rgb = {
        vmix4(r_top, r_bot, frac_y),
        vmix4(g_top, g_bot, frac_y),
        vmix4(b_top, b_bot, frac_y)
    };
    assign valid = frame_ready && active_video &&
                   ((bank_a_matches_display && !selected_bank) ||
                    (bank_b_matches_display && selected_bank));
endmodule
