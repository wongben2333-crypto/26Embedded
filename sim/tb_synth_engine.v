// ==============================================================================
// Testbench: tb_synth_engine
// Description: 多声部纯硬件音频合成引擎全功能测试激励
// Author: FPGA Synthesizer Team
// ==============================================================================

`timescale 1ns / 1ps

module tb_synth_engine;

    reg clk_50m;
    reg btn_rst_n;
    reg btn_demo_en;

    wire i2s_mclk;
    wire i2s_bclk;
    wire i2s_lrck;
    wire i2s_sdata;
    wire [5:0] led_voices;

    // 实例化顶层工程
    synth_top_tang_mega_60k u_top (
        .clk_50m    (clk_50m),
        .btn_rst_n  (btn_rst_n),
        .btn_demo_en(btn_demo_en),
        .i2s_mclk   (i2s_mclk),
        .i2s_bclk   (i2s_bclk),
        .i2s_lrck   (i2s_lrck),
        .i2s_sdata  (i2s_sdata),
        .led_voices (led_voices)
    );

    // 50MHz 主时钟产生 (周期 20ns)
    initial begin
        clk_50m = 0;
        forever #10 clk_50m = ~clk_50m;
    end

    // 测试流程
    initial begin
        $display("=================================================");
        $display("   FPGA Synthesizer RTL Simulation Starting...   ");
        $display("=================================================");
        
        btn_rst_n   = 0;
        btn_demo_en = 1; // 启动纯硬件自主演示模式

        #100;
        btn_rst_n   = 1; // 释放复位
        $display("[TB] Reset released at time %0t ns", $time);

        // 运行一段时间观察 I2S 信号与多声部发声行为
        #500_000;
        $display("[TB] Simulation completed successfully!");
        $finish;
    end

endmodule
