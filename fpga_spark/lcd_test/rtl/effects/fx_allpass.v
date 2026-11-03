// =============================================================================
//  fx_allpass.v —— Schroeder 全通扩散器（Freeverb 变体）
//
//  用途：混响里 4 条并联梳状支路求和之后，串两个全通把"回声"打散成"扩散的尾巴"。
//        没有这两级全通，混响听起来像一串离散的回声而不是空间感。
//
//  ===========================================================================
//  ★ 结构与"它到底是不是数学上的全通"（要诚实）
//  ===========================================================================
//  本模块用的是 **Freeverb 的全通变体**（逐字对应其 C 参考实现）：
//      d[n]  = 延迟线在 (wr_ptr - DLY) 处的值
//      y[n]  = sat16( -x[n] + d[n] )
//      wr    = sat16( x[n] + (d[n]*fb) >> 8 )
//
//  ⚠️ 教科书上的 Schroeder 全通（v[n]=x+g·v[n-D]; y[n]=-g·v[n]+v[n-D]）是
//     **幅度严格平坦**的；Freeverb 这个变体的幅度响应并不严格平坦
//     （它把 g 只放在反馈支路）。选它的理由：
//       · Freeverb 是公有领域的经典实现，被无数工程验证过听感；
//       · 结构更省一次乘法；
//       · 混响的听感由"扩散"决定，微小的幅度不平坦在混响里完全听不出来。
//     本报告不会把它说成"严格全通"，就叫它 Schroeder/Freeverb 扩散器。
//
//  ★ 稳定性：fb < 256(Q8) 即可。本设计取 fb = 128（0.5，与 Freeverb 一致）。
//  ★ 读地址的 +1 推导与 fx_comb.v 完全一样（同步读晚一拍 + 写指针在 tick 边沿自增），
//    见 fx_comb.v 文件头的详细推导，这里不重复。约束同样是 **DLY ≥ 2**。
// =============================================================================
`default_nettype none

module fx_allpass #(
    parameter integer AW   = 11,
    parameter integer DEPTH = 2048,
    parameter integer DLY   = 1231
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_tick,
    input  wire               clr_en,
    input  wire [14:0]        clr_addr,
    input  wire signed [15:0] x,
    input  wire [7:0]         fb_q8,
    output reg  signed [15:0] y
);

    localparam integer DLY_C = (DLY < 2) ? 2 : ((DLY > DEPTH-1) ? DEPTH-1 : DLY);

    reg  signed [15:0] mem [0:DEPTH-1];
    reg  [AW-1:0]      wr_ptr;
    reg  signed [15:0] d_rd;
    reg                tick_d;

    wire [AW-1:0] rd_addr = wr_ptr - (DLY_C[AW-1:0] - 1'b1);

    // ---------------------------------------------------------- 组合计算 ----
    // 乘积全宽形成后再移位（本项目反复踩过"先截断再移位"的坑）
    wire signed [24:0] fb_f  = d_rd * $signed({1'b0, fb_q8});
    wire signed [16:0] fb_s  = fb_f >>> 8;
    wire signed [17:0] wr_f  = {x[15], x} + {{1'b0, fb_s[16]}, fb_s};
    wire signed [15:0] wr_n  = sat16(wr_f);

    // ★ 注意 -x 的溢出：x = -32768 时 -x = +32768 超出 16 bit 有符号范围，
    //   所以必须在 18 bit 上算完再饱和，不能写成 16 bit 的 -x。
    wire signed [17:0] neg_x = -$signed({x[15], x});
    wire signed [17:0] y_f   = neg_x + {{2{d_rd[15]}}, d_rd};
    wire signed [15:0] y_n   = sat16(y_f);

    function signed [15:0] sat16;
        input signed [17:0] v;
        begin
            if      (v > 18'sd32767)  sat16 = 16'sd32767;
            else if (v < -18'sd32768) sat16 = -16'sd32768;
            else                      sat16 = v[15:0];
        end
    endfunction

    // -------------------------------------------------------------- 时序 ----
    // ⚠️ 一个数组只有【一处】写语句（写成两处会被推断成双口 BSRAM 并报错）
    always @(posedge clk) begin
        if (!rst_n) begin
            wr_ptr <= {AW{1'b0}};
            d_rd   <= 16'sd0;
            y      <= 16'sd0;
            tick_d <= 1'b0;
        end else begin
            tick_d <= sample_tick;

            if (clr_en) begin
                mem[clr_addr[AW-1:0]] <= 16'sd0;
            end else if (tick_d) begin
                mem[wr_ptr] <= wr_n;
            end

            if (sample_tick && !clr_en) wr_ptr <= wr_ptr + 1'b1;

            d_rd <= mem[rd_addr];            // 同步读 ⇒ 1 拍延迟（与文件头推导一致）

            if (tick_d && !clr_en) y <= y_n;
        end
    end

endmodule

`default_nettype wire
