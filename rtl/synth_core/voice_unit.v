// ==============================================================================
// Module: voice_unit
// Description: 单一独立发声单元 (Voice Unit)
//              严格契合赛题独立振荡器标准：
//              包含独立的相位累加器、独立的频率调控、独立的 ADSR 包络控制
// Author: FPGA Synthesizer Team
// Target: Gowin GW5AT-LV60 (Tang Mega 60K)
// ==============================================================================

module voice_unit (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_tick,    // 48kHz 采样使能
    
    // 演奏控制接口
    input  wire        note_gate,      // 音符触发 (1: Note-On, 0: Note-Off)
    input  wire [31:0] freq_step,      // 基础频率控制字 (由音高音符映射)
    input  wire signed [15:0] freq_mod,// 颤音/滑音偏置 (Hz/分音调制)
    input  wire [6:0]  velocity,       // 演奏力度 (0 ~ 127)
    input  wire [1:0]  wave_sel,       // 音色选择 (00-正弦, 01-锯齿, 10-三角, 11-方波)
    
    // ADSR 包络参数
    input  wire [15:0] attack_rate,
    input  wire [15:0] decay_rate,
    input  wire [15:0] sustain_level,
    input  wire [15:0] release_rate,
    
    // 发声输出与状态
    output wire signed [15:0] voice_out, // 该声部实时输出音频
    output wire               is_active  // 该声部是否处于活跃发声状态
);

    wire [15:0] env_gain;
    wire is_idle;

    assign is_active = !is_idle;

    // 1. 独立 ADSR 包络发生器
    adsr_envelope #(
        .ENV_WIDTH(16)
    ) u_adsr (
        .clk          (clk),
        .rst_n        (rst_n),
        .sample_tick  (sample_tick),
        .gate         (note_gate),
        .attack_rate  (attack_rate),
        .decay_rate   (decay_rate),
        .sustain_level(sustain_level),
        .release_rate (release_rate),
        .env_out      (env_gain),
        .is_idle      (is_idle)
    );

    // 2. 独立 DDS 振荡器与乘法包络调制
    dds_oscillator u_osc (
        .clk         (clk),
        .rst_n       (rst_n),
        .sample_tick (sample_tick),
        .freq_step   (freq_step),
        .freq_mod    (freq_mod),
        .wave_sel    (wave_sel),
        .env_in      (env_gain),
        .velocity    (velocity),
        .sample_out  (voice_out)
    );

endmodule
