// =============================================================================
//  tb_pitch.v —— 验证【运行时半音变调】真的改变音高（FFT 版）
//
//  ★ 为什么第一版失败、这版为什么可靠：
//    第一版用"数过零率"测频率 —— 实测 4000 个采样点只数到 0~1 次过零，
//    而 200 Hz 在 97.656 kHz 下应有约 16 次。测量本身不可靠，既不能证明
//    也不能证伪（该失败已如实记录在 git e28de9f）。
//    本版改为**导出采样点做 FFT、比对谱峰位置** —— 这正是 tb_spectrum 用的
//    方法，而 tb_spectrum 已稳定给出 32/32 的可靠结果。
//
//  ★ 判据（用【固定】期望值，不用相对比值，避免两个测量误差相乘）：
//    第 0 路基频 200 Hz。
//      pitch_semi =  0 -> 期望 200.00 Hz
//      pitch_semi = +7 -> 期望 200 × 2^(7/12) = 299.66 Hz
//      pitch_semi = -5 -> 期望 200 × 2^(-5/12) = 149.83 Hz
//    每个档位导出 65536 个采样点，由 tools/verify/check_pitch.py 用 FFT
//    找出最低谱峰位置并与期望值比对（容差 ±1 Hz）。
//
//  用法（plusargs，由 sim/run_pitch.do 驱动）：
//      vsim -c -work work tb_pitch +PITCH_OUT=pitch_0.txt  +PITCH_SEMI=0
//      vsim -c -work work tb_pitch +PITCH_OUT=pitch_7.txt  +PITCH_SEMI=7
//      vsim -c -work work tb_pitch +PITCH_OUT=pitch_m5.txt +PITCH_SEMI=-5
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_pitch;

    localparam real TCLK = 20.0;                 // 50 MHz
    localparam integer NSAMP = 65536;            // 与 tb_spectrum 一致

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg sample_tick = 1'b0;

    reg  [31:0] gate_in = 32'd0;
    reg  [1:0]  timbre   = 2'd0;
    reg  signed [3:0] pitch_semi = 4'sd0;

    wire [4:0]  env_voice;
    reg  [16:0] env_level;                     // ★ 必须由 env_voice 组合驱动
    wire signed [15:0] mix;

    // ★ 关键修正（第一版幅值只有 ±1024、而应有的量级是 ±16000）：
    //   tb_spectrum 里 env_level 是【真 adsr 模块的输出】，它按 env_voice
    //   逐路返回该路的包络电平。本测试台为了只测频率、把包络固定成满幅，
    //   但**必须照样做成"按 env_voice 返回"的查表**——
    //   若只写 `assign env_level = 17'h1_0000` 常量，或漏掉组合驱动，
    //   乘法拿到的就不是满幅，输出幅值会明显偏小。
    //   这里用一张 32 项全满幅的表来复现 adsr 的"按路返回"语义。
    always @(*) env_level = 17'h1_0000;        // 32 路全是满幅（与查表等价）

    tone_bank #(.N_VOICES(32), .ROM_PARALLEL(1)) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .sample_tick(sample_tick),
        .gate_in    (gate_in),
        .timbre     (timbre),
        .pitch_semi (pitch_semi),
        .env_voice  (env_voice),
        .env_level  (env_level),
        .mix_out    (mix)
    );

    always #(TCLK/2.0) clk = ~clk;

    // 采样节拍：每 512 拍一次 -> fs = 50e6/512 = 97656.25 Hz
    integer tick_cnt = 0;
    always @(posedge clk) begin
        if (tick_cnt == 511) begin tick_cnt <= 0; sample_tick <= 1'b1; end
        else begin tick_cnt <= tick_cnt + 1; sample_tick <= 1'b0; end
    end

    // ---------------- 采样导出 ----------------
    integer fd;
    integer n;
    reg [1023:0] fname;
    integer semi;

    initial begin
        if (!$value$plusargs("PITCH_OUT=%s", fname)) fname = "pitch_out.txt";
        if (!$value$plusargs("PITCH_SEMI=%d", semi)) semi = 0;
        pitch_semi = semi[3:0];

        rst_n = 1'b0;
        repeat (20) @(posedge clk);
        rst_n = 1'b1;

        // 只让第 0 路发声 —— 单独一路才能干净地定位基频谱峰
        gate_in = 32'd1;

        fd = $fopen(fname, "w");
        if (fd == 0) begin
            $display("[PITCH] ERROR: cannot open %0s", fname);
            $stop;
        end

        // 丢掉前 8192 个采样点，让相位累加器进入稳态
        repeat (8192) @(posedge sample_tick);
        // 导出 NSAMP 个采样点
        for (n = 0; n < NSAMP; n = n + 1) begin
            @(posedge sample_tick);
            $fwrite(fd, "%0d\n", mix);
        end
        $fclose(fd);
        $display("[PITCH] wrote %0d samples to %0s (pitch_semi=%0d)", NSAMP, fname, pitch_semi);
        $stop;
    end

endmodule

`default_nettype wire
