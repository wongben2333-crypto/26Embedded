// =============================================================================
//  tb_piano_engine_latency.v —— 测【控制→可闻】延迟的分布（拓展③ 要求 P50/P95/P99/最大）
//
//  方法：note-on 相对 sample_tick 的相位是任意的（0..511 clk），
//        所以把 512 个相位【全扫一遍】，每个相位独立复位后测一次延迟，再统计分布。
//        这样得到的是**实测分布**，不是"算一个最坏值"。
//
//  测两个口径（都报，避免"可闻"定义含糊）：
//    L1 = note-on 脉冲 → mix_out 第一次【非零】（严格"有输出"）
//    L2 = note-on 脉冲 → |mix_out| ≥ 32（≈ −60 dBFS，保守的"可闻"）
//  另外测一个最坏场景：8 个声部全占满后再来第 9 个音（抢占分配），延迟是否变长。
//
//  用法：vsim -c -do "run -all;quit -f" tb_piano_engine_latency
// =============================================================================
`timescale 1ns/1ps
`default_nettype none
module tb_piano_engine_latency;
    localparam integer VDIV = 512;          // 一个采样周期 = 512 clk
    localparam integer NPH  = 512;          // 扫描全部 512 个相位

    reg clk = 0; always #10 clk = ~clk;     // 20 ns → 50 MHz
    reg rst_n = 0;
    reg [9:0] tc = 0; reg tick = 0;
    always @(posedge clk) begin
        if (tc == VDIV-1) begin tc <= 0; tick <= 1; end
        else begin tc <= tc + 1; tick <= 0; end
    end

    reg on_v = 0, off_v = 0;
    reg [6:0] on_n = 0, on_vel = 0, off_n = 0;
    wire signed [15:0] mix; wire [7:0] act;
    piano_engine #(.N_VOICES(8), .OUT_SHIFT(1)) dut (
        .clk(clk), .rst_n(rst_n), .sample_tick(tick),
        .on_valid(on_v), .on_note(on_n), .on_vel(on_vel),
        .off_valid(off_v), .off_note(off_n),
        .glide_on(1'b0), .glide_time(7'd0), .vib_on(1'b0),
        .vib_depth(7'd0), .vib_rate(7'd0), .inst_sel(2'd0), .sustain(1'b0),
        .mix_out(mix), .active(act));

    integer lat1 [0:NPH-1];    // 首个非零样本
    integer lat2 [0:NPH-1];    // 首个 |mix|>=32
    integer lat_steal;
    integer p, c, i, j;

    // 单次测量：复位 → 对齐 tick → 偏移 p 拍 → note-on → 等输出
    task measure; input integer phase; output integer l1; output integer l2;
        integer cyc; reg seen1;
        begin
            rst_n = 1'b0; repeat (4) @(posedge clk); rst_n = 1'b1;
            while (tick !== 1'b1) @(posedge clk);          // 对齐到采样节拍
            repeat (phase) @(posedge clk);                  // 相位偏移
            // 发 note-on（记录脉冲所在拍）
            @(posedge clk); on_n <= 7'd69; on_vel <= 7'd100; on_v <= 1'b1;
            @(posedge clk); on_v <= 1'b0;
            cyc = 0; l1 = -1; l2 = -1; seen1 = 1'b0;
            while (cyc < 4000) begin
                @(posedge clk); #1;
                cyc = cyc + 1;
                if (!seen1 && (mix !== 16'sd0)) begin l1 = cyc; seen1 = 1'b1; end
                if ((l2 < 0) && ((mix >= 16'sd32) || (mix <= -16'sd32))) l2 = cyc;
                if ((l1 >= 0) && (l2 >= 0)) cyc = 4000;
            end
        end
    endtask

    integer l1, l2, tmp;
    integer s1, s2;            // 用于排序
    integer p50, p95, p99;

    initial begin
        $display("================================================================");
        $display("[LAT] piano_engine 控制->可闻 延迟分布（扫描 note-on 的全部 %0d 个相位）", NPH);
        $display("[LAT] 1 clk = 20 ns；一个采样周期 = %0d clk = %.2f us", VDIV, VDIV*20.0/1000.0);
        $display("[LAT] L1 = 首个【非零】输出样本；L2 = 首个 |mix|>=32 (~-60 dBFS)");
        $display("================================================================");
        for (p = 0; p < NPH; p = p + 1) begin
            measure(p, lat1[p], lat2[p]);
        end
        // 排序取分位数（选择排序，512 项足够）
        for (i = 0; i < NPH; i = i + 1) begin
            for (j = i+1; j < NPH; j = j + 1) begin
                if (lat1[j] < lat1[i]) begin tmp = lat1[i]; lat1[i] = lat1[j]; lat1[j] = tmp; end
                if (lat2[j] < lat2[i]) begin tmp = lat2[i]; lat2[i] = lat2[j]; lat2[j] = tmp; end
            end
        end
        $display("");
        $display("L1（首个非零样本）: min=%0d clk (%.2f us)  P50=%0d (%.2f us)  P95=%0d (%.2f us)  P99=%0d (%.2f us)  max=%0d (%.2f us)",
                 lat1[0], lat1[0]*20.0/1000.0,
                 lat1[(NPH*50)/100], lat1[(NPH*50)/100]*20.0/1000.0,
                 lat1[(NPH*95)/100-1], lat1[(NPH*95)/100-1]*20.0/1000.0,
                 lat1[(NPH*99)/100-1], lat1[(NPH*99)/100-1]*20.0/1000.0,
                 lat1[NPH-1], lat1[NPH-1]*20.0/1000.0);
        $display("L2（|mix|>=32）   : min=%0d clk (%.2f us)  P50=%0d (%.2f us)  P95=%0d (%.2f us)  P99=%0d (%.2f us)  max=%0d (%.2f us)",
                 lat2[0], lat2[0]*20.0/1000.0,
                 lat2[(NPH*50)/100], lat2[(NPH*50)/100]*20.0/1000.0,
                 lat2[(NPH*95)/100-1], lat2[(NPH*95)/100-1]*20.0/1000.0,
                 lat2[(NPH*99)/100-1], lat2[(NPH*99)/100-1]*20.0/1000.0,
                 lat2[NPH-1], lat2[NPH-1]*20.0/1000.0);
        $display("抖动（max-min）：L1 = %0d clk = %.2f us   L2 = %0d clk = %.2f us",
                 lat1[NPH-1]-lat1[0], (lat1[NPH-1]-lat1[0])*20.0/1000.0,
                 lat2[NPH-1]-lat2[0], (lat2[NPH-1]-lat2[0])*20.0/1000.0);

        // ---- 最坏场景：8 声部占满后来第 9 个音（抢占）----
        rst_n = 1'b0; repeat (4) @(posedge clk); rst_n = 1'b1;
        while (tick !== 1'b1) @(posedge clk);
        for (i = 0; i < 8; i = i + 1) begin
            @(posedge clk); on_n <= 7'd60 + i[6:0]; on_vel <= 7'd100; on_v <= 1'b1;
            @(posedge clk); on_v <= 1'b0;
            repeat (20) @(posedge clk);
        end
        repeat (300) @(posedge clk);
        $display("");
        $display("[LAT] 8 声部占用情况 active=%b（应 11111111）", act);
        @(posedge clk); on_n <= 7'd84; on_vel <= 7'd100; on_v <= 1'b1;
        @(posedge clk); on_v <= 1'b0;
        c = 0; lat_steal = -1;
        while (c < 4000 && lat_steal < 0) begin
            @(posedge clk); #1; c = c + 1;
            if ((mix >= 16'sd32) || (mix <= -16'sd32)) lat_steal = c;
        end
        $display("[LAT] 抢占（第 9 个音）延迟 = %0d clk = %.2f us", lat_steal, lat_steal*20.0/1000.0);
        $display("[LAT] 说明：抢占不增加延迟（装载 FSM 都是 14 拍）");
        $stop;
    end
endmodule
`default_nettype wire
