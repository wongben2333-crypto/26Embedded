// =============================================================================
//  cab_biquad.v —— 箱体模拟用的二阶节（Direct Form I，两相流水）
// =============================================================================
//  ★ 为什么是 Direct Form I
//    直接实现 y[n] = b0·x[n] + b1·x[n-1] + b2·x[n-2] - a1·y[n-1] - a2·y[n-2]
//    * 状态全是 **Q1.15 的 16 bit**（x1,x2,y1,y2），不需要"状态是什么量纲"的心智负担
//    * 滤波器稳定 + 输入有界 ⇒ 状态天然有界（不需要额外饱和逻辑去救）
//
//  ★ 为什么拆两相（MODE=1 最差裕量只有 +0.009 ns）
//    一拍里做 5 个乘法 + 5 项加法树，组合路径太深。
//    拆成：
//      相 p（en_p）：寄存输入 xr 与 5 个乘积 p0..p4   —— 每拍只有 1 级乘法
//      相 q（en_q）：求和 + 四舍五入 + 饱和 + 推状态 —— 每拍只有加法树
//    ⚠️ 这两相**都发生在同一个采样周期内**（每采样 512 clk），
//       所以**不改变采样率上的递归关系** ⇒ **传递函数完全不变，也不增加采样延迟**。
//
//  ★ 定点（系数 Q2.18，数据 Q1.15）
//    b0 可能 >1（本设计的峰值均衡 b0 = 1.0385！）⇒ **绝不能用 Q1.15 存系数**
//      （Q1.15 最大 0.99997，1.0385 会被截断成负数 —— 本项目已因窄位宽翻过车）
//    a1 最大可到 ≈1.99 ⇒ 同理 Q2.18 范围 ±4 才够
//    乘积 ≤ 2^15 · 2^20 = 2^35，5 项和 ≤ 2^38 ⇒ 用 41 位累加器，安全
//
//  ★ F9（本项目铁律）：**右移必须四舍五入**
//    算术右移是向 −∞ 取整，会**系统性地放大幅值**，几十秒后炸掉。
//    这里用 "加半个 LSB 再移位"（+1<<17 后 >>>18）。
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module cab_biquad (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               en_p,        // 相 1：寄存输入与乘积
    input  wire               en_q,        // 相 2：求和/舍入/饱和/推状态
    input  wire signed [20:0] c_b0,
    input  wire signed [20:0] c_b1,
    input  wire signed [20:0] c_b2,
    input  wire signed [20:0] c_a1,
    input  wire signed [20:0] c_a2,
    input  wire signed [15:0] x,
    output reg  signed [15:0] y
);

    function signed [15:0] sat16;
        input signed [40:0] v;
        begin
            if      (v >  41'sd32767) sat16 =  16'sd32767;
            else if (v < -41'sd32768) sat16 = -16'sd32768;
            else                      sat16 = v[15:0];
        end
    endfunction

    reg signed [15:0] x1, x2, y1, y2, xr;
    reg signed [36:0] p0, p1, p2, p3, p4;      // 16bit × 21bit = 37 bit

    // 相 1
    always @(posedge clk) begin
        if (!rst_n) begin
            x1 <= 16'sd0; x2 <= 16'sd0; y1 <= 16'sd0; y2 <= 16'sd0; xr <= 16'sd0;
            p0 <= 37'sd0; p1 <= 37'sd0; p2 <= 37'sd0; p3 <= 37'sd0; p4 <= 37'sd0;
        end else if (en_p) begin
            xr <= x;
            p0 <= x  * c_b0;
            p1 <= x1 * c_b1;
            p2 <= x2 * c_b2;
            p3 <= y1 * c_a1;
            p4 <= y2 * c_a2;
        end
    end

    // 相 2：41 位加法树（显式符号扩展到 41 位，避免符号性陷阱）
    wire signed [40:0] acc =
          {{4{p0[36]}}, p0} + {{4{p1[36]}}, p1} + {{4{p2[36]}}, p2}
        - {{4{p3[36]}}, p3} - {{4{p4[36]}}, p4};

    // 四舍五入（F9）：+ 半个 LSB 再算术右移 18
    wire signed [40:0] acc_r = acc + 41'sd131072;      // 1<<17
    wire signed [15:0] yn    = sat16(acc_r >>> 18);

    always @(posedge clk) begin
        if (!rst_n) begin
            y <= 16'sd0;
        end else if (en_q) begin
            y  <= yn;
            y1 <= yn;        // 注意：y1 取**本拍算出的新值**（DF-I 的 y[n-1] 是上一采样）
            y2 <= y1;
            x1 <= xr;
            x2 <= x1;
        end
    end

endmodule

`default_nettype wire
