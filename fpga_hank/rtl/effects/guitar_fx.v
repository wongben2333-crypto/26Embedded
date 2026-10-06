// =============================================================================
//  guitar_fx.v —— 电吉他效果器顶层（过载/失真 + 箱体模拟）
// =============================================================================
//  ⛔ 不改已通过 MODE=1 时序的 `audio_fx.v`（Lead 裁决）—— 本模块是**新开**的独立模块。
//
//  ★★ 时序对策（MODE=1 最差裕量只有 +0.009 ns）★★
//  关键事实：**fs = 97 656.25 Hz，clk = 50 MHz ⇒ 每个采样点有 512 个时钟**。
//  ⇒ 不必把整条链塞进一拍。本模块用一个 **10 级相位移位链**（10 clk ≪ 512 clk），
//    让每个相位只承担"1 个乘法 + 少量加减与饱和"，组合路径都很短。
//
//  ⚠️ 而且这 10 个相位**全部发生在同一个采样周期之内** ⇒
//     * **不改变任何滤波器在采样率上的递归关系**（传递函数完全不变）
//     * **不增加采样延迟**：整链在 10 clk（200 ns）内算完，
//       输出仍早于下一个 sample_tick ⇒ **总延迟 = 1 个采样点 = 10.24 µs**
//       （比我原先告诉 Lead 的"+6 采样点"更好；那是我把相位延迟误当成采样延迟了 ——
//        见设计文档勘误）
//
//  信号链：
//     fx_in ──┬─ 旁路(fx_sel=0) ────────────────────────────────┐
//             └─ [失真级 4 相] ─┬─(clean 档取干声)─[箱体 6 相] ─┬─┴─> fx_out
//                                └────────────────────────────┘
//
//  fx_sel: 2'd0 = 旁路（逐 bit 直通）  2'd1 = 过载  2'd2 = 失真  2'd3 = 清音(仅箱体)
//  cab_sel: 2'd0 = 无箱体  2'd1 = 4x12 密闭  2'd2 = 1x12 开放
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module guitar_fx (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_tick,
    input  wire [1:0]         fx_sel,
    input  wire [1:0]         cab_sel,
    input  wire [6:0]         drive,
    input  wire [6:0]         tone,
    input  wire [6:0]         level,
    input  wire signed [15:0] fx_in,
    output reg  signed [15:0] fx_out
);

    // ------------------------------------------------------ 10 级相位移位链 ----
    localparam integer NPH = 10;
    reg [NPH-1:0] ph_sr;

    always @(posedge clk) begin
        if (!rst_n) ph_sr <= {NPH{1'b0}};
        else        ph_sr <= {ph_sr[NPH-2:0], sample_tick};
    end

    wire [3:0] dph = ph_sr[3:0];           // 失真级 4 相
    wire [5:0] cph = ph_sr[9:4];           // 箱体级 6 相

    // ==================================================== 失真级（4 相）=====
    wire signed [15:0] dist_out;
    wire [1:0] dist_mode = (fx_sel == 2'd2) ? 2'd2 : 2'd1;   // 过载 / 失真

    fx_dist u_dist (
        .clk(clk), .rst_n(rst_n),
        .en_a(dph[0]), .en_b(dph[1]), .en_c(dph[2]), .en_d(dph[3]),
        .mode(dist_mode), .drive(drive), .tone(tone), .level(level),
        .x(fx_in), .y(dist_out)
    );

    // ---------------------------------------------------------- 链内选择 ----
    // clean 档：不经失真，直接把干声送进箱体。
    // ⚠️ 代价：干声比 dist_out 早 4 clk（= 40 ns = 0.0004 个采样）——
    //    远小于一个采样点，听不出来；如实记在这里，不假装没有。
    wire signed [15:0] chain_in = (fx_sel == 2'd3) ? fx_in : dist_out;

    // ==================================================== 箱体级（6 相）=====
    wire signed [15:0] cab_out;
    wire [1:0] cab_use = (cab_sel == 2'd0) ? 2'd1 : cab_sel;  // 0 档也照算，输出由 mux 旁路

    cab_sim u_cab (
        .clk(clk), .rst_n(rst_n),
        .ph(cph), .cab_sel(cab_use),
        .x(chain_in), .y(cab_out)
    );

    // ============================================================ 输出选择 ====
    // 旁路档 **逐 bit 直通**（不经过任何乘法器/滤波器）—— 与 audio_fx 同一约定
    always @(posedge clk) begin
        if (!rst_n) begin
            fx_out <= 16'sd0;
        end else if (fx_sel == 2'd0) begin
            fx_out <= fx_in;                       // 旁路：逐 bit
        end else if (cab_sel != 2'd0) begin
            fx_out <= cab_out;                     // 失真(+箱体)
        end else begin
            fx_out <= chain_in;                    // 失真/清音，无箱体
        end
    end

endmodule

`default_nettype wire
