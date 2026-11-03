// =============================================================================
//  fx_echo.v —— 延迟 / 回声（单抽头 + 反馈，可产生多次重复回声）
//
//  结构：
//      d[n]  = 延迟线在 (wr_ptr - LEN) 处的值，即 x[n-LEN]（含历次反馈）
//      wr    = sat16( x[n] + (d[n]*fb) >> 8 )     ← 反馈 ⇒ 会重复响很多次
//      y[n]  = sat16( x[n] + (d[n]*wet) >> 8 )    ← 干声 + 湿声
//
//  ★ 延迟长度按【实际采样率 97 656.25 Hz】折算，不照抄 48 kHz 的例程：
//      LEN = 9766 + (param << 7)   采样点
//          = 100.0 ms + param × 1.31 ms   （param = 0..127 ⇒ 100 ~ 266 ms）
//    为什么用 "+(param<<7)" 而不是乘一个比例系数：移位就是乘法（×128），
//    **RTL 里一次真实乘法器都不用**，而且延迟与 param 的关系一眼就能算出来，
//    测试台可以精确预测回声出现在第几个采样点（见 tb_effects.v 的脉冲响应判据）。
//
//  ★ 反馈系数 fb 与"能响几次"：
//      fb_q8 = 96 + (param >> 1)  ⇒ 0.375 ~ 0.621
//      每次回声幅度乘 fb：0.621 时 5 次后剩 0.09（约 -21 dB），听得见一串尾巴；
//      0.375 时 3 次后就只剩 0.05，是"两下敲击"的感觉。
//      ⚠️ fb 必须严格 < 1.0（Q8 的 256）。本式最大 159，离发散边界很远 ——
//         这是刻意的：延迟线的写值是 sat16 饱和后的结果，饱和是非线性，
//         若 fb 贴近 1，饱和 + 反馈会形成自持极限环（参考实现 xls32 的
//         "railed 输出"就是这类问题）。留足余量比榨那 1 dB 重要。
//
//  ★ 与 fx_comb.v 相同的两件事：读地址 +1 的推导、DLY ≥ 2 的约束（官方文档
//    明确禁止对同一地址同时读写，且 138K 不支持 read-before-write）。
// =============================================================================
`default_nettype none

module fx_echo #(
    parameter integer AW    = 15,
    parameter integer DEPTH = 32768,
    // param = 0 时的基础延迟（采样点）。9766 @ 97 656.25 Hz ≈ 100.0 ms
    parameter integer LEN_MIN = 9766
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_tick,
    input  wire               clr_en,
    input  wire [14:0]        clr_addr,
    input  wire [6:0]         param,
    input  wire signed [15:0] x,
    output reg  signed [15:0] y
);

    // param[6:4] 在别处没用上；这里 LEN 用整个 param（100~266 ms 连续可调）
    // ⚠️ 用 sized localparam 承接 integer 参数，而不是直接写 `LEN_MIN[AW-1:0]`：
    //    对 integer 参数做位选在 ModelSim 里能过，但属于"依赖工具宽容度"的写法，
    //    换综合器有风险。本设计全程不跑综合（构建由 Lead 负责），所以**主动避开**
    //    任何读起来要看工具脸色的构造。
    localparam [AW-1:0] LEN_MIN_C = LEN_MIN;
    wire [AW-1:0] len = LEN_MIN_C + {5'd0, param, 7'd0};         // param << 7
    wire [7:0]    fb_q8  = 8'd96  + {1'b0, param[6:1]};          // param >> 1
    localparam [7:0] WET_Q8 = 8'd154;                            // 0.6

    reg  signed [15:0] mem [0:DEPTH-1];
    reg  [AW-1:0]      wr_ptr;
    reg  signed [15:0] d_rd;
    reg                tick_d;

    // ★ 读地址 = wr_ptr - LEN + 1（+1 的推导见 fx_comb.v 文件头；LEN 恒 ≥ 9766
    //   远大于 2，读写地址必然错开，满足官方"禁止同址同时读写"的约束）
    wire [AW-1:0] rd_addr = wr_ptr - (len - 1'b1);

    // ---------------------------------------------------------- 组合计算 ----
    wire signed [24:0] fb_f  = d_rd * $signed({1'b0, fb_q8});
    wire signed [24:0] wet_f = d_rd * $signed({1'b0, WET_Q8});
    wire signed [16:0] fb_s  = fb_f  >>> 8;
    wire signed [16:0] wet_s = wet_f >>> 8;
    wire signed [17:0] wr_f  = {{2{x[15]}}, x} + {fb_s[16],  fb_s};
    wire signed [17:0] y_f   = {{2{x[15]}}, x} + {wet_s[16], wet_s};
    wire signed [15:0] wr_n  = sat16(wr_f);
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

            d_rd <= mem[rd_addr];

            if (tick_d && !clr_en) y <= y_n;
        end
    end

endmodule

`default_nettype wire
