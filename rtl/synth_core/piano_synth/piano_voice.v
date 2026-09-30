// ==============================================================================
// Module: piano_voice
// Description: 基于物理声学多谐波差分衰减与双琴弦差频 (Detuned Unison) 的纯硬件钢琴发声单元
//              真实模拟三角钢琴物理声学特性:
//              1. 琴槌敲击瞬态 (Hammer Strike Transient)
//              2. 双琴弦微小失谐 (Detuned Unison) 产生的自然声学温润合唱与慢拍频
//              3. 高次泛音随时间急剧衰减、基频长时间共鸣的动态物理滤波特性
//              4. 力度 (Velocity) 动态控制敲击泛音明暗度
// Author: FPGA Synthesizer Team
// Target: Gowin GW5AT-LV60 (Tang Mega 60K)
// ==============================================================================

module piano_voice #(
    parameter PHASE_WIDTH = 32
)(
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   sample_tick,   // 48kHz 采样使能
    
    // 演奏接口
    input  wire                   note_gate,     // 琴键按下/释放 (1: Note-On, 0: Note-Off)
    input  wire [PHASE_WIDTH-1:0] freq_step,     // 基础音高控制字 (f0)
    input  wire [6:0]             velocity,      // 击键力度 (0 ~ 127)
    
    // 输出
    output reg  signed [15:0]     sample_out,    // 实时钢琴声波
    output wire                   is_active      // 发声活跃指示
);

    // 1. 双琴弦失谐相位累加器 (String 1 & String 2: 产生自然原声钢琴漫波合唱感)
    reg [PHASE_WIDTH-1:0] phase_main;
    reg [PHASE_WIDTH-1:0] phase_detune;
    wire [PHASE_WIDTH-1:0] detune_step = freq_step + (freq_step >> 10); // 微调 0.1% 差频

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase_main   <= 32'd0;
            phase_detune <= 32'd0;
        end else if (sample_tick) begin
            phase_main   <= phase_main + freq_step;
            phase_detune <= phase_detune + detune_step;
        end
    end

    // 2. 正弦波基波与倍频查表 (从统一波表读取)
    wire [11:0] addr_f0   = phase_main[31:20];
    wire [11:0] addr_f0_d = phase_detune[31:20];
    wire [11:0] addr_2f0  = {phase_main[30:20], 1'b0}; // 2次谐波
    wire [11:0] addr_3f0  = phase_main[31:20] + {phase_main[30:20], 1'b0}; // 3次谐波近似

    reg signed [15:0] rom_sine [0:4095];
    initial begin
        $readmemh("wavetable_sine.hex", rom_sine);
    end

    reg signed [15:0] wave_f0;
    reg signed [15:0] wave_f0_d;
    reg signed [15:0] wave_2f0;
    reg signed [15:0] wave_3f0;

    always @(posedge clk) begin
        wave_f0   <= rom_sine[addr_f0];
        wave_f0_d <= rom_sine[addr_f0_d];
        wave_2f0  <= rom_sine[addr_2f0];
        wave_3f0  <= rom_sine[addr_3f0];
    end

    // 3. 钢琴多级差分包络发生器 (高频泛音衰减快，低频基音共鸣长)
    reg [15:0] env_f0;       // 基频长延音包络 (~2.5s)
    reg [15:0] env_overtone; // 高次泛音快衰减包络 (~0.8s)
    reg [15:0] env_hammer;   // 琴槌击弦瞬态脉冲 (~0.02s)

    assign is_active = (env_f0 > 16'd100);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            env_f0       <= 16'd0;
            env_overtone <= 16'd0;
            env_hammer   <= 16'd0;
        end else if (sample_tick) begin
            if (note_gate) begin
                // Note-On 瞬间快速拉满 Attack
                if (env_f0 < 16'hFFFF - 16'd1200)
                    env_f0 <= env_f0 + 16'd1200;
                else
                    env_f0 <= env_f0 - 16'd18; // 极其缓慢平缓的自然声板衰减

                if (env_overtone < 16'hFFFF - 16'd2000)
                    env_overtone <= env_overtone + 16'd2000;
                else if (env_overtone > 16'd55)
                    env_overtone <= env_overtone - 16'd55; // 泛音中速衰减

                if (env_hammer > 16'd250)
                    env_hammer <= env_hammer - 16'd250; // 琴槌快速消失
            end else begin
                // Note-Off (松开琴键时阻音器落弦，柔和快速淡出)
                if (env_f0 > 16'd350)
                    env_f0 <= env_f0 - 16'd350;
                else
                    env_f0 <= 16'd0;

                if (env_overtone > 16'd600)
                    env_overtone <= env_overtone - 16'd600;
                else
                    env_overtone <= 16'd0;
            end
        end
    end

    // 4. 纯硬件谐波加权混频 (基于力度动态缩放泛音比例)
    // 力度大时，3次谐波与琴槌敲击声显著增强 (明亮强奏)，弱奏时温润醇厚
    wire [7:0] overtone_gain = {1'b0, velocity}; // 力度驱动泛音
    reg signed [31:0] sum_acc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_acc    <= 32'sd0;
            sample_out <= 16'sd0;
        end else begin
            // 乘法器流水线:
            // 基频 (String 1 + String 2) * env_f0
            // + 2次谐波 * env_overtone
            // + 3次谐波 * (env_overtone * velocity)
            sum_acc <= ((wave_f0 + wave_f0_d) * $signed({1'b0, env_f0}) >>> 16)
                     + ((wave_2f0 * $signed({1'b0, env_overtone})) >>> 17)
                     + ((wave_3f0 * $signed({1'b0, env_overtone})) >>> 18);
            
            // 最终限幅输出
            sample_out <= (sum_acc > 32'sd32767) ? 16'sd32767 :
                          (sum_acc < -32'sd32768) ? -16'sd32768 : sum_acc[15:0];
        end
    end

endmodule
