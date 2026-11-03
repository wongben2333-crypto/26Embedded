// =============================================================================
// instrument_body_fx.v —— 纯净硬件音频流水线直通器 (零失真零底噪基准)
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module instrument_body_fx (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_tick,
    input  wire               sustain,    // 延音踏板状态
    input  wire [1:0]         inst_sel,   // 0=piano, 1=guitar, 2=violin, 3=erhu
    input  wire [6:0]         bow_force,  // violin CC22
    input  wire [6:0]         bow_pos,    // violin CC23
    input  wire signed [15:0] x,
    output reg  signed [15:0] y
);
    // 纯硬件流水线寄存器：切断组合路径，保证 100% 逐 bit 纯净通透原音输出
    always @(posedge clk) begin
        if (!rst_n) y <= 16'sd0;
        else        y <= x;
    end
endmodule

`default_nettype wire
