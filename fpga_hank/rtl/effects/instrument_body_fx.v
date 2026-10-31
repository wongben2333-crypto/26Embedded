// =============================================================================
// instrument_body_fx.v —— 三种乐器共用的轻量琴体共鸣 EQ
//
// 只使用逐采样的一阶状态和移位加法，不使用 PCM/IR。三个音色的差异来自
// 弦信号进入琴体后的频带平衡：
//   0 钢琴：低中频音板略增，高频柔化；
//   1 吉他：低频箱体和中频木质感略增，高频快速衰减；
//   2 小提琴：中高频桥/琴体共鸣略增，极高频保留少量弓毛亮度。
//
// lp_fast 截取约 2~4 kHz 以下能量，lp_slow 截取低频；两者之差作为琴体
// 中频带，x-lp_fast 作为高频带。所有状态在 sample_tick 更新，路径很短。
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module instrument_body_fx (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_tick,
    input  wire [1:0]         inst_sel,   // 0=piano, 1=guitar, 2/3=violin
    input  wire [6:0]         bow_force,  // violin CC22: bow pressure/brightness
    input  wire [6:0]         bow_pos,    // violin CC23: bridge↔fingerboard colour
    input  wire signed [15:0] x,
    output reg  signed [15:0] y
);
    reg signed [15:0] lp_fast;
    reg signed [15:0] lp_slow;

    function signed [15:0] sat16;
        input signed [19:0] v;
        begin
            if (v > 20'sd32767)       sat16 = 16'sd32767;
            else if (v < -20'sd32768) sat16 = -16'sd32768;
            else                     sat16 = v[15:0];
        end
    endfunction

    wire signed [16:0] fast_d = $signed(x) - $signed(lp_fast);
    wire signed [16:0] slow_d = $signed(x) - $signed(lp_slow);
    wire signed [15:0] fast_n = $signed(lp_fast) + (fast_d >>> 3);
    wire signed [15:0] slow_n = $signed(lp_slow) + (slow_d >>> 6);
    wire signed [16:0] mid    = $signed(fast_n) - $signed(slow_n);
    wire signed [16:0] high   = $signed(x) - $signed(fast_n);
    wire signed [17:0] mid_bow = (bow_force >= 7'd96) ? ($signed(mid) + ($signed(mid) >>> 1)) :
                                  (bow_force >= 7'd48) ? $signed(mid) : ($signed(mid) >>> 1);
    wire signed [16:0] high_bow = (bow_pos >= 7'd96) ? ($signed(high) >>> 2) :
                                   (bow_pos >= 7'd48) ? ($signed(high) >>> 3) : ($signed(high) >>> 4);

    reg signed [19:0] body_mix;
    always @(*) begin
        case (inst_sel)
            2'd1: // classical guitar: warm box, restrained piezo-like edge
                body_mix = $signed(x) + ($signed(slow_n) >>> 2)
                         + ($signed(mid) >>> 2) - ($signed(high) >>> 2);
            2'd2, 2'd3: // violin: bow force changes mid presence; bow position changes edge brightness
                body_mix = $signed(x) + mid_bow + high_bow - ($signed(slow_n) >>> 4);
            default: // piano: soundboard warmth, soften the synthetic top edge
                body_mix = $signed(x) + ($signed(slow_n) >>> 3)
                         + ($signed(mid) >>> 3) - ($signed(high) >>> 2);
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            lp_fast <= 16'sd0;
            lp_slow <= 16'sd0;
            y       <= 16'sd0;
        end else if (sample_tick) begin
            lp_fast <= fast_n;
            lp_slow <= slow_n;
            y       <= sat16(body_mix);
        end
    end
endmodule

`default_nettype wire
