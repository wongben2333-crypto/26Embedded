// =============================================================================
//  tb_spectrum.v —— 端到端频谱取证
//
//  目的：验证赛题【必备交付物】"测试模式下 N 路不同频率 → 频谱可数出
//        N 个独立谱峰"。
//
//  ★ 这里例化的是【完整音源通路】：bench_gate → adsr → tone_bank
//    而不是只例化 tone_bank 给固定样本。理由：
//      · tone_bank 的每路增益由 ADSR 的 env_level 决定，若 env 全 0 则整段静音
//        （实测过：只例化 tone_bank 会 dump 出全零，check_peaks 报"输入全零"）
//      · 用真实通路才能同时验证"包络接入后频谱仍达标"
//    采样窗口跨多个 bench_gate 组轮换周期，因此 32 路都会出现并可被 FFT 分辨。
//
//  做法：在每个 sample_tick 把 mix 的【十进制有符号】值写进文件，一行一个，
//        然后用 tools/verify/check_peaks.py --format samples 做 FFT 判据。
//        （注意：是十进制，不是十六进制 —— `$fdisplay(fd, "%0d", mix)`。）
//
//  ⚠️ --fs 必须显式给出 48828.125，不能用脚本默认的 48000！
//     本设计的 fs 由 BCK_DIV 决定：2 -> 48828.125 Hz；1 -> 97656.25 Hz（当前默认 1）。
//     若漏掉 --fs，200 Hz 会被读成 196.29 Hz，32 个峰全部误判 FAIL
//     （实测：无 --fs → exit 1 命中 0/32；加 --fs → exit 0 命中 32/32）。
//
//    python tools/verify/check_peaks.py --file out/tone_samples.txt \
//        --format samples --fs 97656.25 --count 32 --start 200 --step 200
//
//  ⚠️ 本文件输出的是【活文件】——仿真运行期间会被持续改写，且可能被进程独占锁定。
//     若在仿真还在跑的时候读它，会拿到"写到一半"的内容，得出互相矛盾的结论
//     （实测过：先测出 6.83 dB，再测出 13/32 命中 + 19 杂散，都是同一份半成品）。
//     这类错误比没有测量更危险 —— 它看起来像数据。
//     ★ 纪律：先快照再分析，只对快照下结论：
//         Copy-Item out\tone_samples.txt out\tone_samples_snap.txt
//         python tools\verify\check_peaks.py --file out\tone_samples_snap.txt ...
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_spectrum;

    localparam real    TCLK    = 20.0;      // 50 MHz
    // ★ 采样率必须与 tone_bank.v 的频率字一致，否则 FFT 判据的 --fs 会错
    localparam integer BCK_DIV = 1;          // 2 -> 48828.125 Hz; 1 -> 97656.25 Hz
    localparam integer NV      = 32;
    // 收集 65536 个样本：fs/65536 ≈ 0.745 Hz 分辨率，足以分辨 200 Hz 间隔。
    // 窗口时长 ≈ 1.34 s，跨多个 bench_gate 组轮换周期 → 32 路都会出现。
    localparam integer NSAMP   = 65536;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;

    wire               sample_tick;
    wire signed [15:0] mix;

    // ---------------- 完整音源通路 ----------------
    wire [NV-1:0] gate;
    // ★ 变调验证入口：用 plusarg 控制 pitch_semi，复用本测试台【已验证】的
    //   驱动与判据链路（前两次自己另写测试台都失败了，根因就是重复造轮子）。
    //   用法：vsim -c -work work tb_spectrum +PITCH_SEMI=7
    reg signed [3:0] pitch_semi = 4'sd0;
    integer          semi_arg;
    initial begin
        if ($value$plusargs("PITCH_SEMI=%d", semi_arg)) pitch_semi = semi_arg[3:0];
    end

    wire [4:0]    env_voice;
    wire [16:0]   env_level;

    tone_bank u_bank (
        .clk        (clk),
        .rst_n      (rst_n),
        .sample_tick(sample_tick),
        .gate_in    (gate),
        .pitch_semi (pitch_semi),
        .timbre     (2'd0),   // 测试模式必须用表 0（纯正弦），否则每路多个谐波谱峰
        .env_voice  (env_voice),
        .env_level  (env_level),
        .mix_out    (mix)
    );

    // ★★ 本测试台【刻意】使用与 top.v 不同的 ADSR 参数，这不是笔误 ★★
//   实测教训（2026-10-03）：我曾"顺手对齐"成 top.v 的 EN_DIV=512，
//   结果 32 谱峰判据直接变成 FAIL —— 导出数据的 min=-20889 / max=3459，
//   出现严重直流偏置、std 从满幅掉到 3656。
//   根因：bench_gate 是【轮换门控】（每次只按住一组声部），
//   而 EN_DIV=512 时包络要 10.5 ms 才爬到满幅 —— 声部在被重新触发时
//   还没到满幅，于是整段信号既弱又不对称，FFT 被直流项淹没。
//   EN_DIV=8 时包络在约 0.2 ms 内就到 steady state，
//   每个声部在"被按住的那段窗口"里增益恒定，谱峰才干净。
//   ⇒ 这是**测量设置**（把被测对象的增益固定住），不是"与设计不一致的 bug"。
//   ⚠️ 但必须知道：本测试台测的是"增益恒定时 32 路频率是否可分辨"，
//      **不测 top.v 的包络时长**。包络时长由 tb_adsr 单独负责。
adsr #(.N_VOICES(NV), .EN_DIV(8), .ATK_SH(8), .DEC_SH(10), .REL_SH(12),
           .SUS_LEVEL(49152)) u_adsr (
        .clk(clk), .rst_n(rst_n), .gate(gate),
        .voice_rd(env_voice), .level_rd(env_level), .phase_rd()
    );

    bench_gate #(.N_VOICES(NV)) u_bench (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick), .gate(gate)
    );

    // 用真实的 PT8211 发送器产生 sample_tick → 保证 fs 与上板完全一致
    wire bck_o, ws_o, din_o;
    pt8211_tx #(.BCK_DIV(BCK_DIV)) u_dac (
        .clk(clk), .reset(~rst_n),
        .sample_l(mix), .sample_r(mix),
        .sample_tick(sample_tick),
        .bck(bck_o), .ws(ws_o), .din(din_o)
    );

    always #(TCLK/2.0) clk = ~clk;

    integer fd;
    integer n = 0;

    // ------------------------------------------------ 混音波形导出（真实仿真值）---
    integer wf_fd;
    initial wf_fd = $fopen("C:/Users/Danny/Desktop/FPGA competition/fpga_hank/out/wave_mix.csv", "w");
    always @(posedge sample_tick)
        if (wf_fd != 0 && $time < 20000000) $fwrite(wf_fd, "%0d,%0d\n", $time, mix);

    initial begin
        repeat (20) @(posedge clk);
        rst_n = 1'b1;

        fd = $fopen("tone_samples.txt", "w");
        if (fd == 0) begin
            $display("[TB] ERROR: cannot open tone_samples.txt");
            $stop;   // ★ 用 $stop 而非 $finish：run.do 要连续跑多个 tb，$finish 会终止整个 vsim
        end

        // 丢掉前 8192 个样本，让相位累加器与包络进入稳态
        repeat (8192) @(posedge sample_tick);

        while (n < NSAMP) begin
            @(posedge sample_tick);
            $fdisplay(fd, "%0d", mix);
            n = n + 1;
        end

        $fclose(fd);
        $display("[TB] wrote %0d samples to tone_samples.txt", n);
        // fs 由 BCK_DIV 决定：2 -> 48828.125 Hz；1 -> 97656.25 Hz
        $display("[TB] fs = %0.3f Hz, freq resolution = %f Hz",
                 (BCK_DIV == 1) ? 97656.25 : 48828.125, ((BCK_DIV == 1) ? 97656.25 : 48828.125)/NSAMP);
        $stop;   // ★ 用 $stop 而非 $finish：run.do 要连续跑多个 tb，$finish 会终止整个 vsim
    end

endmodule

`default_nettype wire
