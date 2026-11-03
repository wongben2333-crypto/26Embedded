`default_nettype none

// Radix-2 DIT FFT: bit-reversed input, natural output, 1/2 scaling per stage.
module fft4096 (
    input wire clk, rst_n,
    input wire load,
    input wire [11:0] load_index,
    input wire signed [17:0] load_sample,
    input wire start,
    output wire busy,
    output reg done,
    input wire [11:0] rd_index,
    output wire signed [17:0] rd_re, rd_im
);
    localparam IDLE=0, READ_A=1, READ_B=2, MUL=3, ROTATE=4,
               SUM=5, WRITE_A=6, WRITE_B=7;
    reg [2:0] state;
    reg [11:0] half_span, addr_a, tw_step;
    reg [10:0] j, tw_index;
    wire [11:0] addr_b = addr_a + half_span;
    reg signed [17:0] ar, ai;
    reg signed [15:0] wr, wi;
    reg signed [33:0] rr, ii, ri, ir;
    reg signed [18:0] tr, ti;
    reg signed [19:0] plus_r, plus_i, minus_r, minus_i;
    wire signed [34:0] rot_r = {rr[33],rr} - {ii[33],ii};
    wire signed [34:0] rot_i = {ri[33],ri} + {ir[33],ir};
    reg [35:0] ram [0:4095];
    reg [35:0] ram_q;
    reg [11:0] ram_addr;
    reg ram_we;
    reg [35:0] ram_d;
    reg [31:0] twiddle [0:2047];
    initial $readmemh("rtl/visualizer/fft_twiddle.hex", twiddle);

    function [11:0] reverse12;
        input [11:0] n;
        integer k;
        begin
            for (k=0; k<12; k=k+1) reverse12[k] = n[11-k];
        end
    endfunction
    assign busy = (state != IDLE);
    assign rd_re = $signed(ram_q[35:18]);
    assign rd_im = $signed(ram_q[17:0]);

    always @* begin
        ram_addr = rd_index;
        ram_we = 1'b0;
        ram_d = 36'd0;
        case (state)
            IDLE: if (load) begin
                ram_addr = reverse12(load_index);
                ram_we = 1'b1;
                ram_d = {load_sample,18'd0};
            end
            READ_A: ram_addr = addr_a;
            READ_B: ram_addr = addr_b;
            WRITE_A: begin
                ram_addr = addr_a;
                ram_we = 1'b1;
                ram_d = {plus_r[18:1],plus_i[18:1]};
            end
            WRITE_B: begin
                ram_addr = addr_b;
                ram_we = 1'b1;
                ram_d = {minus_r[18:1],minus_i[18:1]};
            end
            default: ;
        endcase
    end
    // One synchronous memory port avoids large asynchronous read muxes.
    always @(posedge clk) begin
        if (ram_we) begin
            ram[ram_addr] <= ram_d;
            ram_q <= ram_d;
        end else ram_q <= ram[ram_addr];
        if (state == READ_A) begin
            wr <= $signed(twiddle[tw_index][31:16]);
            wi <= $signed(twiddle[tw_index][15:0]);
        end
    end
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            done <= 1'b0;
            half_span <= 12'd1;
            addr_a <= 12'd0;
            j <= 11'd0;
            tw_step <= 12'd2048;
            tw_index <= 11'd0;
        end else begin
            case (state)
                IDLE: begin
                    if (start) begin
                        done <= 1'b0;
                        half_span <= 12'd1;
                        addr_a <= 12'd0;
                        j <= 11'd0;
                        tw_step <= 12'd2048;
                        tw_index <= 11'd0;
                        state <= READ_A;
                    end
                end
                READ_A: state <= READ_B;
                READ_B: begin ar <= rd_re; ai <= rd_im; state <= MUL; end
                MUL: begin
                    rr <= rd_re * wr; ii <= rd_im * wi;
                    ri <= rd_re * wi; ir <= rd_im * wr;
                    state <= ROTATE;
                end
                ROTATE: begin tr <= rot_r[33:15]; ti <= rot_i[33:15]; state <= SUM; end
                SUM: begin
                    plus_r <= {{2{ar[17]}},ar} + {tr[18],tr};
                    plus_i <= {{2{ai[17]}},ai} + {ti[18],ti};
                    minus_r <= {{2{ar[17]}},ar} - {tr[18],tr};
                    minus_i <= {{2{ai[17]}},ai} - {ti[18],ti};
                    state <= WRITE_A;
                end
                WRITE_A: state <= WRITE_B;
                WRITE_B: begin
                    if ({1'b0,j} == half_span - 12'd1) begin
                        j <= 11'd0; tw_index <= 11'd0;
                        if (addr_b == 12'd4095) begin
                            if (half_span == 12'd2048) begin state <= IDLE; done <= 1'b1; end
                            else begin
                                half_span <= half_span << 1; tw_step <= tw_step >> 1;
                                addr_a <= 12'd0; state <= READ_A;
                            end
                        end else begin addr_a <= addr_b + 12'd1; state <= READ_A; end
                    end else begin
                        j <= j + 11'd1; tw_index <= tw_index + tw_step[10:0];
                        addr_a <= addr_a + 12'd1; state <= READ_A;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
