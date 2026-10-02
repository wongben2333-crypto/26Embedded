// =============================================================================
//  templates/latency_tb.v —— 控制→发声延迟测量测试平台【模板，未验证】
//
//  目的：量出赛题要的 P50/P95/P99/max —— 从"控制事件被采样"到"音频样本开始变化"。
//
//  ⚠️ 这是模板，**必须按真实端口名改造后才能用**（本机未跑通，标为未验证）。
//     改造点：① 替换 u_engine 为你的引擎（键扫描/串口命令 + 振荡器组 + ADSR）
//             ② 把 TRIGGER 改成你的"控制事件"条件
//             ③ 把 AUDIO_CHANGED 改成"该声部包络离开 0 / 输出离开静音"
//
//  输出 lat.csv：每行一个延迟值（单位：clk）。分析：
//     python scripts/latency_stats.py --file lat.csv --unit cycles --clk-mhz 50 --markdown
//
//  注意：这里测的是**音频通路内的确定性延迟**（控制采样 → 出声样本）。
//        上板还要加上人机输入（按键消抖/串口帧）本身的延迟，报告里要写清边界。
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module latency_tb;

    localparam integer N_EVENTS  = 200;
    localparam integer GAP_CLK   = 1000;    // 两次控制事件之间的间隔

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;                  // 50 MHz

    // ---- 控制事件：按 GAP_CLK 周期性触发一次"按键/命令" --------------------
    reg  trigger = 1'b0;
    integer ev = 0;

    // ---- 被测引擎（改成你的顶层；端口名仅为示例） --------------------------
    wire signed [15:0] audio_l;
    wire signed [15:0] audio_r;
    wire               sample_tick;

    // 示例 DUT 占位（改造时替换）：
    // engine u_engine (.clk(clk), .rst_n(rst_n), .note_on(trigger), .audio_l(audio_l), ...);

    // ---- 延迟测量：trigger 被采样 → 音频离开静音 ---------------------------
    integer fd;
    integer t_trig = 0;
    integer waiting = 0;
    integer i;

    initial begin
        fd = $fopen("lat.csv", "w");
        if (fd == 0) begin $display("[lat] 无法写 lat.csv"); $finish; end
        $fdisplay(fd, "# 每个控制事件的延迟（单位 clk）");
        repeat (20) @(posedge clk);
        rst_n = 1'b1;

        for (i = 0; i < N_EVENTS; i = i + 1) begin
            repeat (GAP_CLK) @(posedge clk);
            @(negedge clk);
            t_trig  = $time;              // 控制事件被采样的时刻
            trigger = 1'b1;
            @(posedge clk);
            trigger = 1'b0;
            waiting = 1;
            // 等待音频离开静音（示例条件：audio_l != 0）
            while (waiting) begin
                @(posedge clk);
                if (audio_l !== 16'sd0) begin
                    $fdisplay(fd, "%0d", ($time - t_trig) / 20);  // clk 数
                    waiting = 0;
                end
                if (($time - t_trig) / 20 > 100000) begin
                    $fdisplay(fd, "-1");     // 超时：该次事件没出声
                    waiting = 0;
                end
            end
        end
        $fclose(fd);
        $display("[lat] wrote %0d events to lat.csv", N_EVENTS);
        $finish;
    end

    initial begin
        #100_000_000;
        $display("[lat] TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire
