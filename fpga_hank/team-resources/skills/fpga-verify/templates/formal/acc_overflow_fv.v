// =============================================================================
//  templates/formal/acc_overflow_fv.v —— 形式验证模板：32 路累加器不溢出/不回绕
//
//  ⚠️【未验证】本机未安装 sby，模板未跑通。安装见 _research/fpga-tools/INSTALL-PLAN.md P0。
//
//  要证明的核心性质（对应 mix 通路最容易翻车的点）：
//    P1  有符号饱和后的输出不会"回绕"（正数相加不可能变负）
//    P2  只要每路幅度有界，32 路之和就不越过累加器位宽
//
//  用法：把下面 sat_add 换成 tone_bank.v 里真正的饱和累加逻辑（或直接对 DUT 做黑盒
//        形式验证：read_verilog 你的 RTL + 一个 driver/assert wrapper）。
// =============================================================================
`default_nettype none

module acc_overflow_fv #(
    parameter integer W = 16
)(
    input  wire              clk,
    (* anyseq *) input wire signed [W-1:0] a,
    (* anyseq *) input wire signed [W-1:0] b
);

    // 21 bit 中间量（与 tone_bank.v 的 sum 位宽一致），再饱和到 16 bit
    wire signed [20:0] wide = a + b;

    function signed [W-1:0] sat;
        input signed [20:0] v;
        begin
            if (v > 21'sd32767)       sat = 16'sd32767;
            else if (v < -21'sd32768) sat = -16'sd32768;
            else                      sat = v[W-1:0];
        end
    endfunction

    wire signed [W-1:0] y = sat(wide);

    always @(posedge clk) begin
        // P1：饱和输出不会回绕 —— 两个同号输入不可能得到反号输出
        if (a[W-1] == b[W-1])
            assert (y[W-1] == a[W-1]);
        // P2：未饱和时必须是精确和
        if (wide <= 21'sd32767 && wide >= -21'sd32768)
            assert (y == wide[W-1:0]);
    end

endmodule

`default_nettype wire
