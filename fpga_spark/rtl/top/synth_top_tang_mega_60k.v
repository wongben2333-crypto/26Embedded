// ==============================================================================
// Module: synth_top_tang_mega_60k
// Description: Tang Mega 60K (GW5AT-LV60PG484A) 电子乐器引擎顶层工程
// Author: FPGA Synthesizer Team
// ==============================================================================

module synth_top_tang_mega_60k (
    input  wire        clk_50m,         // 板载 50MHz 有源晶振
    input  wire        btn_rst_n,       // 板载复位按键 (低有效)
    input  wire        btn_demo_en,     // 按键: 演示模式启闭
    
    // I2S 音频 DAC 接口 (连接 PCM5102A 模块)
    output wire        i2s_mclk,        // MCLK 主时钟
    output wire        i2s_bclk,        // BCLK 位时钟
    output wire        i2s_lrck,        // LRCK 声道选择
    output wire        i2s_sdata,       // SDATA 串行数据
    
    // 板载指示灯
    output wire [5:0]  led_voices       // 6颗LED指示当前活跃并发声部数量
);

    wire sample_tick;
    wire signed [15:0] audio_l;
    wire signed [15:0] audio_r;
    wire [7:0] active_voices;

    // 指示灯输出: 活跃发声单元越多，点亮的 LED 越多 (低有效点亮)
    assign led_voices[0] = ~(active_voices[0] | active_voices[1]);
    assign led_voices[1] = ~(active_voices[2] | active_voices[3]);
    assign led_voices[2] = ~(active_voices[4]);
    assign led_voices[3] = ~(active_voices[5]);
    assign led_voices[4] = ~(active_voices[6]);
    assign led_voices[5] = ~(active_voices[7]);

    // 1. 多声部硬件合成引擎核心
    synth_engine_top #(
        .NUM_VOICES(8),
        .CLK_FREQ(50_000_000),
        .AUDIO_FS(48_000)
    ) u_synth_core (
        .clk              (clk_50m),
        .rst_n            (btn_rst_n),
        .demo_mode_en     (btn_demo_en), // 默认拉高演示模式
        .ext_gate         (8'b0),
        .ext_freq_step    ('{default: 32'd0}),
        .ext_wave_sel     ('{default: 2'b00}),
        .ext_velocity     ('{default: 7'd0}),
        .sample_tick      (sample_tick),
        .audio_left_out   (audio_l),
        .audio_right_out  (audio_r),
        .active_voices_bus(active_voices)
    );

    // 2. I2S 物理接口控制器
    i2s_transmitter u_i2s (
        .clk          (clk_50m),
        .rst_n        (btn_rst_n),
        .sample_left  (audio_l),
        .sample_right (audio_r),
        .sample_tick  (sample_tick),
        .i2s_mclk     (i2s_mclk),
        .i2s_bclk     (i2s_bclk),
        .i2s_lrck     (i2s_lrck),
        .i2s_sdata    (i2s_sdata)
    );

endmodule
