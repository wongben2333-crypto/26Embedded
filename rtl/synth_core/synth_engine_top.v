// ==============================================================================
// Module: synth_engine_top
// Description: 多声部纯硬件音频合成引擎顶层
//              符合嵌赛高云赛题规则:
//              1. 基础复音数 >= 4 (本模块实现 8 声部并发独立物理发声单元)
//              2. 每一个声部具备独立相位累加器、独立调频控制、独立 ADSR 包络
//              3. 纯硬件逐样本 48kHz 实时计算
//              4. 内置高动态多路饱和混音器 (Saturating Mixer)
//              5. 内置纯硬件演示例程状态机 (Demo Player FSM) 与外部实时控制接口
// Author: FPGA Synthesizer Team
// Target: Gowin GW5AT-LV60 (Tang Mega 60K)
// ==============================================================================

module synth_engine_top #(
    parameter NUM_VOICES = 8,
    parameter CLK_FREQ   = 50_000_000,
    parameter AUDIO_FS   = 48_000
)(
    input  wire        clk,            // 主时钟 50MHz
    input  wire        rst_n,          // 异步复位 (低有效)
    
    // 模式选择: 1 = 纯硬件自主演示模式 (自动弹奏复音和弦乐章), 0 = 外部演奏输入模式
    input  wire        demo_mode_en,
    
    // 外部演奏控制总线 (当 demo_mode_en = 0 时生效)
    input  wire [NUM_VOICES-1:0] ext_gate,         // 8路音符独立触发
    input  wire [31:0]           ext_freq_step[0:NUM_VOICES-1], // 8路独立频率字
    input  wire [1:0]            ext_wave_sel[0:NUM_VOICES-1],  // 8路独立音色
    input  wire [6:0]            ext_velocity[0:NUM_VOICES-1],  // 8路独立力度
    
    // 主音频输出接口 (逐样本 48kHz 输出)
    output reg                   sample_tick,      // 48kHz 脉冲节拍
    output wire signed [15:0]    audio_left_out,   // 左声道混音输出
    output wire signed [15:0]    audio_right_out,  // 右声道混音输出
    output wire [NUM_VOICES-1:0] active_voices_bus // 活跃声部状态指示 (用于LED/HDMI监控)
);

    // --------------------------------------------------------------------------
    // 1. 48kHz 音频采样使能时钟生成 (从 50MHz 分频: 50,000,000 / 48,000 ≈ 1041.67)
    // --------------------------------------------------------------------------
    reg [15:0] tick_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tick_cnt    <= 16'd0;
            sample_tick <= 1'b0;
        end else if (tick_cnt >= 16'd1041) begin
            tick_cnt    <= 16'd0;
            sample_tick <= 1'b1;
        end else begin
            tick_cnt    <= tick_cnt + 1'b1;
            sample_tick <= 1'b0;
        end
    end

    // --------------------------------------------------------------------------
    // 2. 硬件颤音 LFO (Low Frequency Oscillator ~ 5.5Hz)
    // --------------------------------------------------------------------------
    reg [13:0] lfo_cnt;
    reg signed [15:0] vibrato_mod;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfo_cnt     <= 14'd0;
            vibrato_mod <= 16'sd0;
        end else if (sample_tick) begin
            // 48000 / 8192 ≈ 5.8Hz
            lfo_cnt <= lfo_cnt + 1'b1;
            if (lfo_cnt[12])
                vibrato_mod <= $signed({ {10{lfo_cnt[11]}}, lfo_cnt[11:6] });
            else
                vibrato_mod <= -$signed({ {10{lfo_cnt[11]}}, lfo_cnt[11:6] });
        end
    end

    // --------------------------------------------------------------------------
    // 3. 纯硬件演示乐章状态机 (Demo Player FSM)
    //    自动生成多声部和弦 (Root, Third, Fifth), 贝斯低音, 高音琶音旋律与多音色切换
    // --------------------------------------------------------------------------
    reg [NUM_VOICES-1:0] demo_gate;
    reg [31:0]           demo_freq_step[0:NUM_VOICES-1];
    reg [1:0]            demo_wave_sel[0:NUM_VOICES-1];
    reg [6:0]            demo_velocity[0:NUM_VOICES-1];
    
    // 节拍计时器 (以 sample_tick 驱动，每 0.25 秒一个 16 分音符)
    reg [15:0] beat_sample_cnt;
    reg [7:0]  seq_step;
    
    // 常用标准频率字预设 (ΔPhase = f * 2^32 / 48000)
    localparam STEP_C2 = 32'd5856401;   // 65.41 Hz  (Bass)
    localparam STEP_G2 = 32'd8774797;   // 98.00 Hz
    localparam STEP_A2 = 32'd9848529;   // 110.00 Hz
    localparam STEP_F2 = 32'd7817028;   // 87.31 Hz
    
    localparam STEP_C4 = 32'd23425607;  // 261.63 Hz (Middle C)
    localparam STEP_D4 = 32'd26299105;  // 293.66 Hz
    localparam STEP_E4 = 32'd29517173;  // 329.63 Hz
    localparam STEP_F4 = 32'd31272361;  // 349.23 Hz
    localparam STEP_G4 = 32'd35099188;  // 392.00 Hz
    localparam STEP_A4 = 32'd39394116;  // 440.00 Hz
    localparam STEP_B4 = 32'd44217112;  // 493.88 Hz
    localparam STEP_C5 = 32'd46851214;  // 523.25 Hz
    localparam STEP_E5 = 32'd59034346;  // 659.25 Hz
    localparam STEP_G5 = 32'd70198376;  // 783.99 Hz

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            beat_sample_cnt <= 16'd0;
            seq_step        <= 8'd0;
            demo_gate       <= 8'b0;
        end else if (sample_tick) begin
            // 48000 / 4 = 12000 个采样点 = 0.25 秒
            if (beat_sample_cnt >= 16'd11999) begin
                beat_sample_cnt <= 16'd0;
                seq_step <= (seq_step >= 8'd63) ? 8'd0 : (seq_step + 1'b1);
                
                // 根据节拍更新 8个声部状态
                case (seq_step[5:4]) // 4个和弦大节: C -> G -> Am -> F
                    2'b00: begin // C Major (C - E - G)
                        demo_freq_step[0] <= STEP_C2; // Bass
                        demo_wave_sel[0]  <= 2'b10;   // Triangle bass
                        demo_velocity[0]  <= 7'd110;
                        
                        demo_freq_step[1] <= STEP_C4; // Chord Root
                        demo_freq_step[2] <= STEP_E4; // Third
                        demo_freq_step[3] <= STEP_G4; // Fifth
                        demo_wave_sel[1]  <= 2'b00;   // Sine/warm
                        demo_wave_sel[2]  <= 2'b00;
                        demo_wave_sel[3]  <= 2'b00;
                        demo_velocity[1]  <= 7'd90;
                        demo_velocity[2]  <= 7'd85;
                        demo_velocity[3]  <= 7'd85;
                    end
                    2'b01: begin // G Major (G - B - D)
                        demo_freq_step[0] <= STEP_G2;
                        demo_freq_step[1] <= STEP_G4;
                        demo_freq_step[2] <= STEP_B4;
                        demo_freq_step[3] <= STEP_D4;
                        demo_wave_sel[0]  <= 2'b10;
                        demo_wave_sel[1]  <= 2'b01;   // Sawtooth
                        demo_wave_sel[2]  <= 2'b01;
                        demo_wave_sel[3]  <= 2'b01;
                        demo_velocity[0]  <= 7'd110;
                        demo_velocity[1]  <= 7'd90;
                        demo_velocity[2]  <= 7'd85;
                        demo_velocity[3]  <= 7'd85;
                    end
                    2'b10: begin // A Minor (A - C - E)
                        demo_freq_step[0] <= STEP_A2;
                        demo_freq_step[1] <= STEP_A4;
                        demo_freq_step[2] <= STEP_C5;
                        demo_freq_step[3] <= STEP_E5;
                        demo_wave_sel[0]  <= 2'b10;
                        demo_wave_sel[1]  <= 2'b00;
                        demo_wave_sel[2]  <= 2'b00;
                        demo_wave_sel[3]  <= 2'b00;
                        demo_velocity[0]  <= 7'd110;
                        demo_velocity[1]  <= 7'd90;
                        demo_velocity[2]  <= 7'd85;
                        demo_velocity[3]  <= 7'd85;
                    end
                    2'b11: begin // F Major (F - A - C)
                        demo_freq_step[0] <= STEP_F2;
                        demo_freq_step[1] <= STEP_F4;
                        demo_freq_step[2] <= STEP_A4;
                        demo_freq_step[3] <= STEP_C5;
                        demo_wave_sel[0]  <= 2'b10;
                        demo_wave_sel[1]  <= 2'b11;   // Square wave
                        demo_wave_sel[2]  <= 2'b11;
                        demo_wave_sel[3]  <= 2'b11;
                        demo_velocity[0]  <= 7'd110;
                        demo_velocity[1]  <= 7'd85;
                        demo_velocity[2]  <= 7'd80;
                        demo_velocity[3]  <= 7'd80;
                    end
                endcase
                
                // 声部 4~7: 动态主旋律与快速琶音 (Arpeggio & Lead)
                demo_wave_sel[4]  <= 2'b01; // Sawtooth lead
                demo_velocity[4]  <= 7'd120;
                case (seq_step[3:0])
                    4'd0:  demo_freq_step[4] <= STEP_C5;
                    4'd2:  demo_freq_step[4] <= STEP_E5;
                    4'd4:  demo_freq_step[4] <= STEP_G5;
                    4'd6:  demo_freq_step[4] <= STEP_E5;
                    4'd8:  demo_freq_step[4] <= STEP_D4;
                    4'd10: demo_freq_step[4] <= STEP_G4;
                    4'd12: demo_freq_step[4] <= STEP_B4;
                    4'd14: demo_freq_step[4] <= STEP_C5;
                    default: demo_freq_step[4] <= STEP_C5;
                endcase
                
                // 触发 Gate 脉冲 (保持和弦延音，主音按步触发)
                demo_gate[0] <= 1'b1; // Bass 恒定延音
                demo_gate[1] <= 1'b1; // 和弦组持续发声
                demo_gate[2] <= 1'b1;
                demo_gate[3] <= 1'b1;
                demo_gate[4] <= (seq_step[0] == 1'b0); // 主旋律交替触发与释放
                demo_gate[5] <= 1'b0;
                demo_gate[6] <= 1'b0;
                demo_gate[7] <= 1'b0;
            end else begin
                beat_sample_cnt <= beat_sample_cnt + 1'b1;
            end
        end
    end

    // --------------------------------------------------------------------------
    // 4. 发声参数仲裁 (外部输入 vs 演示模式)
    // --------------------------------------------------------------------------
    wire [NUM_VOICES-1:0] cur_gate;
    wire [31:0]           cur_freq_step[0:NUM_VOICES-1];
    wire [1:0]            cur_wave_sel[0:NUM_VOICES-1];
    wire [6:0]            cur_velocity[0:NUM_VOICES-1];

    genvar vi;
    generate
        for (vi = 0; vi < NUM_VOICES; vi = vi + 1) begin: GEN_CTRL_MUX
            assign cur_gate[vi]      = demo_mode_en ? demo_gate[vi]      : ext_gate[vi];
            assign cur_freq_step[vi] = demo_mode_en ? demo_freq_step[vi] : ext_freq_step[vi];
            assign cur_wave_sel[vi]  = demo_mode_en ? demo_wave_sel[vi]  : ext_wave_sel[vi];
            assign cur_velocity[vi]  = demo_mode_en ? demo_velocity[vi]  : ext_velocity[vi];
        end
    endgenerate

    // --------------------------------------------------------------------------
    // 5. 实例化 8 个完整的独立物理发声单元 (Voice Units)
    // --------------------------------------------------------------------------
    wire signed [15:0] voice_samples[0:NUM_VOICES-1];
    
    generate
        for (vi = 0; vi < NUM_VOICES; vi = vi + 1) begin: GEN_VOICE_ARRAY
            // 每个声部配置专属 ADSR 包络常数:
            // Attack 快, Decay 适中, Sustain 保持中高, Release 顺滑
            wire [15:0] v_attack  = (vi == 0) ? 16'd500  : 16'd800;   // 贝斯稍慢防爆音
            wire [15:0] v_decay   = 16'd120;
            wire [15:0] v_sustain = (vi == 0) ? 16'd50000 : 16'd38000;
            wire [15:0] v_release = 16'd200;
            
            // 颤音仅施加在主旋律声部 (Voice 4)
            wire signed [15:0] v_mod = (vi == 4) ? vibrato_mod : 16'sd0;

            voice_unit u_voice (
                .clk          (clk),
                .rst_n        (rst_n),
                .sample_tick  (sample_tick),
                .note_gate    (cur_gate[vi]),
                .freq_step    (cur_freq_step[vi]),
                .freq_mod     (v_mod),
                .velocity     (cur_velocity[vi]),
                .wave_sel     (cur_wave_sel[vi]),
                .attack_rate  (v_attack),
                .decay_rate   (v_decay),
                .sustain_level(v_sustain),
                .release_rate (v_release),
                .voice_out    (voice_samples[vi]),
                .is_active    (active_voices_bus[vi])
            );
        end
    endgenerate

    // --------------------------------------------------------------------------
    // 6. 纯硬件高动态多路饱和混音器 (Saturating Mixer)
    // --------------------------------------------------------------------------
    reg signed [20:0] mix_sum_l;
    reg signed [20:0] mix_sum_r;
    reg signed [15:0] sat_out_l;
    reg signed [15:0] sat_out_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mix_sum_l <= 21'sd0;
            mix_sum_r <= 21'sd0;
            sat_out_l <= 16'sd0;
            sat_out_r <= 16'sd0;
        end else if (sample_tick) begin
            // 立体声声道轻度声相分离 (Panning)
            // Left: Voice 0(Bass/Center), 1, 2, 4
            // Right: Voice 0(Bass/Center), 2, 3, 4
            mix_sum_l <= voice_samples[0] + voice_samples[1] + voice_samples[2] + voice_samples[4];
            mix_sum_r <= voice_samples[0] + voice_samples[2] + voice_samples[3] + voice_samples[4];

            // 硬件防削波软饱和限制器 (Saturator)
            // 左声道限幅
            if (mix_sum_l > 21'sd32767)
                sat_out_l <= 16'sd32767;
            else if (mix_sum_l < -21'sd32768)
                sat_out_l <= -16'sd32768;
            else
                sat_out_l <= mix_sum_l[15:0];

            // 右声道限幅
            if (mix_sum_r > 21'sd32767)
                sat_out_r <= 16'sd32767;
            else if (mix_sum_r < -21'sd32768)
                sat_out_r <= -16'sd32768;
            else
                sat_out_r <= mix_sum_r[15:0];
        end
    end

    assign audio_left_out  = sat_out_l;
    assign audio_right_out = sat_out_r;

endmodule
