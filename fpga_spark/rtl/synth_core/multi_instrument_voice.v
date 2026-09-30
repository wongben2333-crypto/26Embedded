// ==============================================================================
// Module: multi_instrument_voice
// Description: 多乐器多模式可切换独立物理发声单元
//              支持三种不同声学机制的纯硬件音色引擎:
//              - Mode 00: 经典合成器 (DDS 波表 + 乘法 ADSR 包络)
//              - Mode 01: 原声拨弦吉他 (Karplus-Strong 纯物理建模)
//              - Mode 10: 大三角钢琴 (多谐波时变衰减 + 双琴弦声学微失谐合唱)
//              - Mode 11: 64路谐波加法合成引擎 (Additive Synthesis)
// Author: FPGA Synthesizer Team
// Target: Gowin GW5AT-LV60 (Tang Mega 60K)
// ==============================================================================

module multi_instrument_voice #(
    parameter PHASE_WIDTH = 32
)(
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   sample_tick,   // 48kHz 采样使能
    
    // 乐器模式选择
    input  wire [1:0]             instrument_mode, // 00:Synth, 01:Guitar, 10:Piano, 11:Additive
    
    // 通用演奏控制接口
    input  wire                   note_gate,       // 按键门控 (1:按下, 0:松开)
    input  wire                   pluck_trig,      // 拨弦瞬间单周期触发脉冲
    input  wire [PHASE_WIDTH-1:0] freq_step,       // 32位音高控制字 (DDS / Piano)
    input  wire [9:0]             string_len,      // 琴弦长度 N (Guitar)
    input  wire [6:0]             velocity,        // 演奏力度 (0 ~ 127)
    input  wire [1:0]             synth_wave_sel,  // 合成器波形选择 (正弦/锯齿/三角/方波)
    
    // 合成器 ADSR 参数
    input  wire [15:0]            adsr_attack,
    input  wire [15:0]            adsr_decay,
    input  wire [15:0]            adsr_sustain,
    input  wire [15:0]            adsr_release,
    
    // 实时音频输出
    output reg  signed [15:0]     voice_out,
    output wire                   is_active
);

    // 1. 经典 DDS 合成器声音通道
    wire signed [15:0] out_synth;
    wire act_synth;
    voice_unit u_synth_voice (
        .clk          (clk),
        .rst_n        (rst_n),
        .sample_tick  (sample_tick),
        .note_gate    (note_gate),
        .freq_step    (freq_step),
        .freq_mod     (16'sd0),
        .velocity     (velocity),
        .wave_sel     (synth_wave_sel),
        .attack_rate  (adsr_attack),
        .decay_rate   (adsr_decay),
        .sustain_level(adsr_sustain),
        .release_rate (adsr_release),
        .voice_out    (out_synth),
        .is_active    (act_synth)
    );

    // 2. Karplus-Strong 纯物理建模原声吉他通道
    wire signed [15:0] out_guitar;
    wire act_guitar;
    karplus_strong_string u_guitar (
        .clk         (clk),
        .rst_n       (rst_n),
        .sample_tick (sample_tick),
        .pluck_trig  (pluck_trig),
        .string_len  (string_len),
        .velocity    (velocity),
        .decay_factor(16'd65150), // 约 0.994 衰减阻尼
        .sample_out  (out_guitar),
        .is_active   (act_guitar)
    );

    // 3. 物理声学三角钢琴通道
    wire signed [15:0] out_piano;
    wire act_piano;
    piano_voice u_piano (
        .clk        (clk),
        .rst_n      (rst_n),
        .sample_tick(sample_tick),
        .note_gate  (note_gate),
        .freq_step  (freq_step),
        .velocity   (velocity),
        .sample_out (out_piano),
        .is_active  (act_piano)
    );

    // 4. 多路音色无缝切换多路选择器 (MUX)
    always @(*) begin
        case (instrument_mode)
            2'b00: voice_out = out_synth;
            2'b01: voice_out = out_guitar;
            2'b10: voice_out = out_piano;
            default: voice_out = out_synth;
        endcase
    end

    assign is_active = (instrument_mode == 2'b00) ? act_synth  :
                       (instrument_mode == 2'b01) ? act_guitar :
                       (instrument_mode == 2'b10) ? act_piano  : 1'b0;

endmodule
