// =============================================================================
//  fx_chorus.v —— 合唱（短延迟 + LFO 调制延迟量）
//
//  原理一句话：把信号延迟约 10 ms，并让延迟量被一个低频振荡器（LFO）**缓慢
//  来回摆动**，然后与干声相加。摆动的延迟会让同一频率的相位不断变化，
//  合成出周期性的梳状滤波移动 —— 听感就是"好几个人/好几把琴同时奏同一个音"。
//
//  ===========================================================================
//  ★ 参数映射（param = 0..127 = 合唱深度）
//  ===========================================================================
//      LFO   : 三角波，固定 0.797 Hz
//              （相位增量 137 @ 2^24 累加器：137 × 97 656.25 / 2^24 = 0.797）
//      调制量: offset = (tri_signed × param) >> 6      ⇒ ±0 ~ ±254 采样点
//      延迟量: dly = 1024 + offset                     ⇒ 770 ~ 1278 采样点
//                                                       = 7.9 ~ 13.1 ms
//      干湿比: wet_q8 = param << 1                     ⇒ 0 ~ 0.99
//              ⇒ **param = 0 时湿声为 0，即完全旁通**，符合"深度=0 就没效果"的直觉
//      y[n]  = sat16( x[n] + (d[n]*wet) >> 8 )，写回延迟线的就是 x[n] 本身
//
//  ★ 为什么延迟量取 7.9~13.1 ms：
//      太短（<5 ms）会变成"镶边/Flanger"（梳状滤波太明显，音染重）；
//      太长（>30 ms）会听成两个音（变成回声/双音）。
//      7~13 ms 是合唱的经典区间，也是参考实现里"~9–17 ms 短延迟 + LFO 扫"的同一档。
//
//  ★ 读地址的 +1（同步读晚一拍）在本模块的推导 —— 与固定延迟不同，这里
//    dly 每个采样点都在变，所以结论要重算一遍：
//      rd_addr(T) = wr_ptr(T) - dly(T) + 1 = a[n-1] - dly_{n-1} + 1 = a[n] - dly_{n-1}
//      地址 a[k] 里存的是 x[k]（合唱写回的就是干声）⇒ rd_data = x[n - dly_{n-1}]
//      ⇒ **实际延迟恰好等于 dly_{n-1}**（上一个采样点的调制值）。
//    多出的那"一个采样点的调制滞后"完全听不出来（0.8 Hz 的 LFO 在 10 µs 内
//    几乎不动），但它让整个推导是精确的，而不是"差不多"。
//  ★ 约束 DLY ≥ 2：本模块最小延迟 770，天然满足（见 fx_comb.v 关于官方
//    "禁止同址同时读写 / 138K 不支持 read-before-write"的说明）。
// =============================================================================
`default_nettype none

module fx_chorus #(
    parameter integer AW      = 11,
    parameter integer DEPTH   = 2048,
    parameter integer BASE    = 1024,      // 中心延迟（采样点）≈ 10.5 ms
    parameter integer LFO_INC = 137        // 2^24 累加器步长 ⇒ 0.797 Hz
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

    reg  signed [15:0] mem [0:DEPTH-1];
    reg  [AW-1:0]      wr_ptr;
    reg  signed [15:0] d_rd;
    reg  [23:0]        lfo_ph;
    reg  [AW-1:0]      dly_r;
    reg                tick_d;

    // ------------------------------------------------------------ LFO 三角波 --
    // 取相位的高 9 位折成三角波：前半段上爬 0..255，后半段下爬 255..0
    wire [7:0] tri8  = lfo_ph[23] ? ~lfo_ph[22:15] : lfo_ph[22:15];
    wire signed [8:0] tri_s = {1'b0, tri8} - 9'sd128;          // -128 .. +127
    // ★ 乘法在全宽上形成再移位（tri_s 9 bit × param 7 bit = 16 bit，先算完）
    wire signed [16:0] mod_f = tri_s * $signed({1'b0, param});
    wire signed [16:0] mod_o = mod_f >>> 6;                    // ±254 以内
    // 中心延迟 + 调制偏移。mod_o ∈ ±254，BASE = 1024 ⇒ 实际延迟 770..1278 采样点
    // ⚠️ 用 sized localparam 承接 integer 参数（不做 `BASE[16:0]` 这种对 integer
    //    参数位选的写法 —— ModelSim 能过但依赖工具宽容度）
    localparam signed [16:0] BASE_C    = BASE;
    localparam        [23:0] LFO_INC_C = LFO_INC;
    wire signed [16:0] dly_f = BASE_C + mod_o;
    wire [AW-1:0]      dly_n = dly_f[AW-1:0];

    wire [AW-1:0] rd_addr = wr_ptr - (dly_r - 1'b1);

    // ---------------------------------------------------------- 组合计算 ----
    wire [7:0]         wet_q8 = {param, 1'b0};                 // param << 1
    wire signed [24:0] wet_f  = d_rd * $signed({1'b0, wet_q8});
    wire signed [16:0] wet_s  = wet_f >>> 8;
    wire signed [17:0] y_f    = {x[15], x} + {{1'b0, wet_s[16]}, wet_s};
    wire signed [15:0] y_n    = sat16(y_f);

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
            lfo_ph <= 24'd0;
            dly_r  <= BASE_C[AW-1:0];
            y      <= 16'sd0;
            tick_d <= 1'b0;
        end else begin
            tick_d <= sample_tick;

            if (clr_en) begin
                mem[clr_addr[AW-1:0]] <= 16'sd0;
            end else if (tick_d) begin
                mem[wr_ptr] <= x;                 // 合唱写回的是干声本身
            end

            if (sample_tick && !clr_en) begin
                wr_ptr <= wr_ptr + 1'b1;
                lfo_ph <= lfo_ph + LFO_INC_C;
                dly_r  <= dly_n;                  // 本采样点的调制值，下一点生效
            end

            d_rd <= mem[rd_addr];

            if (tick_d && !clr_en) y <= y_n;
        end
    end

endmodule

`default_nettype wire
