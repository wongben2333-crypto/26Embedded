// =============================================================================
//  tb_dut_perf.v —— 用【真实顶层 + 演奏模式】跑，检查会不会数字削顶
//
//  ★ 为什么要写这个：
//    真板录音出现了 60 个杂散（6600/6800/7000/7200/7400/7600 Hz），
//    而 tone_bank.v 里记着一段历史：**缩放不足导致 sat16 削顶时，
//    会正好产生这种"一串谐波杂散"**（当年实测 87 个）。
//
//    但此前所有仿真验证用的都是**测试模式**（bench_gate 轮换，同时只有约 2 路在响），
//    而真板演奏模式下 **32 路是同时开门的**（gate = {32{key_held}}）——
//    两者对 sum 的峰值压力完全不同。
//
//    ⇒ 本测试台直接例化 top #(TEST_MODE=0)，按住 key，
//      把内部 mix 采样导出来，交给 check_peaks.py 判。
//      如果仿真也出现杂散 ⇒ 是我们自己数字削顶的真实 bug；
//      如果仿真 0 杂散      ⇒ 失真来自扬声器/麦克风模拟段。
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_dut_perf;
    localparam integer NSAMP = 65536;

    reg clk = 1'b0;
    reg key = 1'b1;         // 板上按键：未按下 = 1
    reg key2 = 1'b1;
    reg key_pitch = 1'b1;

    wire [3:0] led;
    wire HP_BCK, HP_WS, HP_DIN, PA_EN;

    // ★ TEST_MODE = 0 → 演奏模式：gate = {32{key_held}}
    top #(.TEST_MODE(0), .BCK_DIV(1)) dut (
        .clk(clk), .led(led),
        .HP_BCK(HP_BCK), .HP_WS(HP_WS), .HP_DIN(HP_DIN), .PA_EN(PA_EN),
        .key(key), .key2(key2), .key_pitch(key_pitch)
    );

    always #10 clk = ~clk;   // 50 MHz

    integer fd, n, i;
    integer mn = 100000, mx = -100000, clip = 0;

    initial begin
        fd = $fopen("out/dut_perf_samples.txt", "w");
        if (fd == 0) begin $display("[TB] 无法打开输出文件"); $stop; end

        // 等上电复位与按键去抖（por ~10.5 ms + 去抖 2.62 ms）
        #20000000;          // 20 ms
        $display("[TB] t=20ms  key_db=%b  en_level[0]=%0d  mix=%0d",
                 dut.key_db, dut.u_adsr.en_level[0], dut.mix);
        key = 1'b0;         // 按住发声键
        #5000000;           // 再等 5 ms，让包络到达 sustain
        $display("[TB] t=25ms  key_db=%b  en_level[0]=%0d  mix=%0d",
                 dut.key_db, dut.u_adsr.en_level[0], dut.mix);
        #5000000;           // 再等 5 ms
        $display("[TB] t=30ms  key_db=%b  en_level[0]=%0d  mix=%0d",
                 dut.key_db, dut.u_adsr.en_level[0], dut.mix);
        #10000000;          // 再等 10 ms（共 20 ms 后）
        $display("[TB] t=40ms  key_db=%b  en_level[0]=%0d  mix=%0d",
                 dut.key_db, dut.u_adsr.en_level[0], dut.mix);

        $display("[TB] 开始采样 mix（演奏模式，32 路全开）…");
        for (i = 0; i < NSAMP; i = i + 1) begin
            @(posedge clk);
            n = dut.mix;
            if (n < mn) mn = n;
            if (n > mx) mx = n;
            if (n >= 32767 || n <= -32768) clip = clip + 1;
            $fwrite(fd, "%0d\n", n);
        end
        $fclose(fd);

        $display("[TB] ==============================================");
        $display("[TB] 样本数        : %0d", NSAMP);
        $display("[TB] min / max     : %0d / %0d", mn, mx);
        $display("[TB] 削顶样本数    : %0d   (%%0.4f)", clip, 100.0*clip/NSAMP);
        if (clip > 0)
            $display("[TB] ⚠️ 出现数字削顶 —— 这是真实 bug（sum 缩放不足）");
        else
            $display("[TB] ✅ 无数字削顶 —— 真板杂散来自扬声器/麦克风模拟段");
        $display("[TB] ==============================================");
        $stop;
    end

    // 防止 min/max 初始化判断写反：这里用简单比较
    initial begin
        // 修正上面写反的三元判断（保持可读）
    end
endmodule

`default_nettype wire
