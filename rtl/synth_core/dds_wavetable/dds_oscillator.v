// ==============================================================================
// Module: dds_oscillator
// Description: 基于 32位相位累加器的可变音色 DDS 振荡器
//              严格契合赛题要求:
//              1. 独立相位累加器与频率调控
//              2. 4096点 16-bit 高保真波表 (正弦波/锯齿波/三角波/方波)
//              3. 支持频率微调与振动颤音 (Vibrato) 调制输入
//              4. 硬件乘法器级联 ADSR 包络与力度调控
// Author: FPGA Synthesizer Team
// Target: Gowin GW5AT-LV60 (Tang Mega 60K)
// ==============================================================================

module dds_oscillator #(
    parameter PHASE_WIDTH = 32,
    parameter TABLE_AW    = 12,  // 4096 点深度
    parameter DATA_WIDTH  = 16
)(
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   sample_tick,   // 48kHz 采样时钟使能脉冲
    input  wire [PHASE_WIDTH-1:0] freq_step,     // 基础频率控制字 (ΔPhase = f * 2^32 / 48000)
    input  wire signed [15:0]     freq_mod,      // 调频/颤音偏置输入 (可正可负)
    input  wire [1:0]             wave_sel,      // 波形选择: 00-正弦, 01-锯齿, 10-三角, 11-方波
    input  wire [15:0]            env_in,        // ADSR 包络输入 (0 ~ 65535)
    input  wire [6:0]             velocity,      // 力度输入 (0 ~ 127)
    output reg  signed [15:0]     sample_out     // 经过包络调控后的 16-bit 有符号音频样本
);

    // 1. 相位累加器
    reg [PHASE_WIDTH-1:0] phase_acc;
    wire [PHASE_WIDTH-1:0] effective_step;
    
    // 基础频率 + 调频调制
    assign effective_step = freq_step + {{16{freq_mod[15]}}, freq_mod};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase_acc <= {PHASE_WIDTH{1'b0}};
        end else if (sample_tick) begin
            phase_acc <= phase_acc + effective_step;
        end
    end

    // 2. 查表地址 (截取相位累加器高 12 位)
    wire [TABLE_AW-1:0] lut_addr = phase_acc[PHASE_WIDTH-1 : PHASE_WIDTH-TABLE_AW];

    // 3. 片上波表 ROM (4096 深度 x 16-bit 宽度)
    reg signed [DATA_WIDTH-1:0] rom_sine [0:(1<<TABLE_AW)-1];
    reg signed [DATA_WIDTH-1:0] rom_saw  [0:(1<<TABLE_AW)-1];
    reg signed [DATA_WIDTH-1:0] rom_tri  [0:(1<<TABLE_AW)-1];
    reg signed [DATA_WIDTH-1:0] rom_sqr  [0:(1<<TABLE_AW)-1];

    initial begin
        $readmemh("wavetable_sine.hex", rom_sine);
        $readmemh("wavetable_saw.hex",  rom_saw);
        $readmemh("wavetable_tri.hex",  rom_tri);
        $readmemh("wavetable_sqr.hex",  rom_sqr);
    end

    // 波表读取流水线
    reg signed [DATA_WIDTH-1:0] raw_wave;
    always @(posedge clk) begin
        case (wave_sel)
            2'b00: raw_wave <= rom_sine[lut_addr];
            2'b01: raw_wave <= rom_saw[lut_addr];
            2'b10: raw_wave <= rom_tri[lut_addr];
            2'b11: raw_wave <= rom_sqr[lut_addr];
            default: raw_wave <= 16'sh0000;
        endcase
    end

    // 4. 硬件乘法器包络调制与力度加权
    // Step 1: 包络调制 env_mult = raw_wave (16-bit signed) * env_in (16-bit unsigned) => 32-bit signed
    // Step 2: 力度调制 (0~127 映射为 64~127 基础增益，保证可听度)
    reg signed [31:0] env_scaled;
    wire [7:0] vel_gain = (velocity == 7'd0) ? 8'd0 : (8'd64 + {1'b0, velocity[6:1]}); // 动态范围控制

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            env_scaled <= 32'sd0;
            sample_out <= 16'sd0;
        end else begin
            // 流水线乘法 1: 乘以 ADSR 包络 (env_in: 0~65535, 右移 16位对齐)
            env_scaled <= (raw_wave * $signed({1'b0, env_in})) >>> 16;
            
            // 流水线乘法 2: 乘以 力度系数 (vel_gain: 0~128, 右移 7位对齐)
            sample_out <= (env_scaled * $signed({1'b0, vel_gain})) >>> 7;
        end
    end

endmodule
