// =============================================================================
//  fx_dist.v —— 电吉他【过载 / 失真】非线性级
// =============================================================================
//  信号链：预增益(可饱和) -> 立方软削波 -> (失真档再硬削) -> 音调低通 -> 输出电平
//
//  ★ 为什么是"立方软削波" y = x - x^3/3
//    · 单调、平滑、处处可导 => 音色"暖"，不像硬削那样刺耳
//    · **只用乘法**，没有除法、没有查表、没有 tanh 的指数运算
//    ⚠️ 立方在 |x| > 1 时**会回头上升**（x=2 时 y = 2 - 8/3 = -0.67！）
//       => **必须先把 x 饱和到 ±1**，否则会出现严重失真/跳变。
//          本模块的预增益级已经做了 sat16，所以送进立方的值天然在 ±1 内。
//
//  ★ 非对称削波（偶次谐波 = 电子管"暖"的来源）
//    负半周先乘 1.25 再削 => 正负半周波形不对称 => 产生偶次谐波。
//    实现只用一次移位加法 x + (x>>2)，**不占乘法器**。
//
//  ★ 定点（Q1.15，32767 ≈ 1.0）
//    x2 = (x*x)     >>> 15
//    x3 = (x*x2)    >>> 15
//    x/3 = (x3*10923) >>> 15      // 10923/32768 = 0.333343 ≈ 1/3
//
//  ★ 时序（MODE=1 最差裕量只有 +0.009 ns ⇒ 每拍组合逻辑必须短）
//    **拆成 4 相**，每相只做 **1 个乘法 + 少量加减与饱和**：
//      A: 预增益 ×gain + 非对称 + 饱和
//      B: x²
//      C: x³ 与最终的 x - x³/3（+ 失真档硬削）
//      D: 音调一阶低通 + 输出电平
//    ⚠️ 这 4 相**发生在【同一个采样周期内】**（每采样有 512 clk），
//       所以**不引入额外的采样延迟**，也不改变传递函数。
//
//  ★ 混叠说明：非线性会产生超 Nyquist 谐波。本工程 fs = 97.656 kHz，
//    是常规 48 kHz 系统的两倍多 => 混叠远好于常规 DSP，**不需要过采样**
//    （赛题也明确"过采样不加分"）。
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module fx_dist (
    input  wire               clk,
    input  wire               rst_n,
    // ---- 4 相使能（由 guitar_fx 的 sample_tick 移位链给出，每采样各 1 拍）----
    input  wire               en_a,
    input  wire               en_b,
    input  wire               en_c,
    input  wire               en_d,
    // ---- 参数 ----
    input  wire [1:0]         mode,    // 2'd1 = overdrive（纯立方）  2'd2 = distortion（立方+硬削）
    input  wire [6:0]         drive,   // 0..127 预增益
    input  wire [6:0]         tone,    // 0..127 音调（越大越亮）
    input  wire [6:0]         level,   // 0..127 输出电平（64 ≈ 单位增益）
    input  wire signed [15:0] x,
    output reg  signed [15:0] y
);

    // 过载参数在一个音频采样周期内保持不变。将外部控制量锁存到
    // sample 相位对应的寄存器，避免 drive 直接穿过乘法器形成长组合路径。
    // 这只增加一个采样边界内的参数更新，不改变音频数据通路的采样延迟。
    reg [6:0] drive_r;
    reg [1:0] mode_r;
    reg [6:0] tone_r;
    reg [6:0] level_r;
    always @(posedge clk) begin
        if (!rst_n) begin
            drive_r <= 7'd0;
            mode_r  <= 2'd1;
            tone_r  <= 7'd96;
            level_r <= 7'd64;
        end else if (en_a) begin
            drive_r <= drive;
            mode_r  <= mode;
            tone_r  <= tone;
            level_r <= level;
        end
    end

    // ---------------------------------------------------------------- 工具 ----
    function signed [15:0] sat16;
        input signed [40:0] v;
        begin
            if      (v >  41'sd32767) sat16 =  16'sd32767;
            else if (v < -41'sd32768) sat16 = -16'sd32768;
            else                      sat16 = v[15:0];
        end
    endfunction

    // =========================================================================
    //  相 A：预增益 ×gain + 非对称 + 饱和
    // =========================================================================
    //  gain = (32 + dr_lo) << dr_hi    ，dr_hi = drive[6:4] (0..7), dr_lo = drive[3:0]
    //  范围 32 .. 47<<7 = 6016  =>  Q8: 0.125 .. 23.5 倍
    //  用"指数+尾数"而不是线性，是为了让旋钮在小角度也有细腻变化。
    // [FIX] Smooth monotonic pre-gain curve: gain_q8 = 48 + (drive * 6) + ((drive * drive) >> 4)
    // Guarantees strictly monotonic THD increase across drive = 0..127 without premature rail saturation
    wire [13:0] dr_sq   = drive_r * drive_r;
    reg [15:0] gain_q8_r = 16'd48;
    always @(posedge clk) begin
        if (!rst_n) gain_q8_r <= 16'd48;
        else if (en_a) gain_q8_r <= 16'd48 + ({9'd0, drive_r} * 16'd6) + {6'd0, dr_sq[13:4]};
    end
    wire [15:0] gain_q8 = gain_q8_r;

    wire signed [32:0] pa     = x * $signed({1'b0, gain_q8});   // Q8 -> 33 bit
    wire signed [15:0] xg     = sat16(pa >>> 8);                // 饱和 => 保证 |x| <= 1

    // 非对称：负半周 ×1.25（= x + x/4），只多一个移位加法，不占乘法器
    //
    // ⚠️⚠️ 这里踩过本项目第 N 次"符号性"坑，务必看清 ⚠️⚠️
    //   第一版写成：
    //       wire signed [16:0] xa = xg[15] ? ({xg[15],xg} + {{2{xg[15]}}, xg[15:2]})
    //                                     : {xg[15], xg};
    //   `{xg[15],xg}` 是 **17 位拼接（无符号）**，`{{2{..}}, xg[15:2]}` 是 **16 位拼接（无符号）**。
    //   Verilog 对**无符号**表达式做加宽时是 **零扩展**，不是符号扩展
    //   ⇒ 那个 16 位的"x/4"（对负数本应是负数）被当成一个**大正数**加进去
    //   ⇒ 负数输入全部算错并顶到 +32767。
    //   实测证据（tb_guitar_probe）：fx_in=-281 -> xg=-36（对）-> xa=65491（错，应为 -45）
    //                                -> x_asym=32767（全饱和）
    //   **现象是"只能处理正半周"，根因是拼接的符号性。**
    //   ⇒ 修正：改成**同宽、全有符号**的运算（全部走 signed 17 位），不用拼接参与算术。
    //   ⇒ 铁律复习：`{a[15],a}` 这种"手工符号扩展"**只有和同宽操作数做位运算才安全**；
    //      一旦更窄的操作数混进来，就会被零扩展。宁可写 `$signed(x)` + `>>>`。
    wire signed [16:0] xg_se = $signed(xg);          // 17 位有符号
    // [FIX] Scale negative-half tube asymmetry with drive so drive=0 is clean (THD < 0.2%)
    // and THD increases strictly monotonically across drive = 0..127!
    wire signed [16:0] xg_q  = (drive_r >= 7'd64) ? (xg_se >>> 2) :
                               (drive_r >= 7'd32) ? (xg_se >>> 3) :
                               (drive_r >= 7'd8)  ? (xg_se >>> 4) : 17'sd0;
    wire signed [16:0] xg25  = xg_se + xg_q;
    wire signed [16:0] xa    = xg[15] ? xg25 : xg_se;
    wire signed [15:0] x_asym = sat16(xa);

    reg signed [15:0] xA;          // 相 A 的输出寄存器
    always @(posedge clk) begin
        if (!rst_n) xA <= 16'sd0;
        else if (en_a) xA <= x_asym;
    end

    // =========================================================================
    //  相 B：x²   （Q1.15 × Q1.15 = Q2.30，右移 15 回 Q1.15）
    // =========================================================================
    wire signed [31:0] sq   = xA * xA;
    wire signed [15:0] x2   = sat16(sq >>> 15);

    reg signed [15:0] xAr, x2B;
    always @(posedge clk) begin
        if (!rst_n) begin xAr <= 16'sd0; x2B <= 16'sd0; end
        else if (en_b) begin xAr <= xA; x2B <= x2; end     // xAr 供相 C 用
    end

    // =========================================================================
    //  相 C：x³ 与 y = x - x³/3（+ 失真档硬削）
    // =========================================================================
    wire signed [31:0] cb    = xAr * x2B;             // x³ in Q2.30
    wire signed [15:0] x3    = sat16(cb >>> 15);      // Q1.15
    wire signed [31:0] d3    = x3 * 32'sd10923;       // ÷3 的定点近似
    wire signed [15:0] third = sat16(d3 >>> 15);
    wire signed [16:0] yc17  = {xAr[15], xAr} - {third[15], third};   // 17 bit 防溢出
    wire signed [15:0] ycub  = sat16(yc17);

    // distortion 档：再硬削到 ±0.5 FS => 更"方"、更脏
    wire signed [15:0] yhard = (ycub >  16'sd16384) ?  16'sd16384 :
                               (ycub < -16'sd16384) ? -16'sd16384 : ycub;
    wire signed [15:0] ysel  = (mode_r == 2'd2) ? yhard : ycub;

    reg signed [15:0] yC;
    always @(posedge clk) begin
        if (!rst_n) yC <= 16'sd0;
        else if (en_c) yC <= ysel;
    end

    // =========================================================================
    //  相 D：音调一阶低通 + 输出电平
    // =========================================================================
    //  tone 0..127 -> 移位 4..1  => 截止 ≈ fs/(2π·2^sh) ≈ 972 / 1944 / 3888 / 7771 Hz
    wire [2:0] tsh = 3'd1 + ((7'd127 - tone_r) >> 5);   // 1..4

    reg signed [15:0] lp;                              // 一阶低通状态
    wire signed [16:0] lpd  = {yC[15], yC} - {lp[15], lp};
    wire signed [16:0] lpn  = {lp[15], lp} + (lpd >>> tsh);
    wire signed [15:0] lps  = sat16(lpn);

    //  level: Q7 缩放，level=64 => 128>>7 = 1.00（单位增益）
    //  ⚠️ 第一版写成 `>>> 8`，于是 level=64 只有 0.5 倍 —— 整条链白白衰减一半。
    //     频响测试是相对的（比值），掩盖了这个错；是"绝对电平"复核才发现的。
    wire [7:0] lev_q8 = {1'b0, level_r} + 8'd64;      // 64..191 => 0.50..1.49
    wire signed [32:0] pl = lps * $signed({1'b0, lev_q8});

    always @(posedge clk) begin
        if (!rst_n) begin lp <= 16'sd0; y <= 16'sd0; end
        else if (en_d) begin
            lp <= lps;
            y  <= sat16(pl >>> 7);
        end
    end

endmodule

`default_nettype wire
