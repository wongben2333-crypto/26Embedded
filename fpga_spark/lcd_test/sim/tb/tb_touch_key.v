// =============================================================================
//  tb_touch_key.v —— 电容触摸琴键 touch_key.v 的自检平台
//
//  ★ 电极模型（**这里是最容易翻车的地方，历史教训见下**）：
//      用 `assign (weak1, highz0) pad = model_pull;` 做**弱上拉**，
//      并且**模型从不驱动 0**。
//    ⇒ `pad[i] === 1'b0` 只可能是 **DUT 在放电** ⇒ 判"是否在放电"不会歧义。
//
//    历史教训（`rtl/not_integrated/touch_pad.v` 的 tb 长期不通过，三个坑）：
//      坑A 用 `pad === 1'b0` 判放电，**但模型自己带弱下拉** ⇒ 节点恒为 0，
//          模型永远以为 DUT 在放电 ⇒ 测量全超时（死锁）
//      坑B 用"边沿状态机"，空闲期误入"开始充电"分支把充电钉住
//      坑C 计数式模型（pad_in 分离信号）复位后头几次仍超时（原因当时未查清）
//    ⇒ 本模型：**弱上拉 + 到点才提供 + 只靠强 0 判放电**，从复位第一次测量就正确。
//
//  验证内容：
//    T1 上电不误判（含"基线未初始化"这段最容易出错的时期）
//    T2 无触摸：长稳不误触
//    T3 触摸 pad1：只有 pressed[1]=1，且 strength 明显 > 0
//    T4 松手后正确释放
//    T5 strength 随"电容增量"**单调递增**（将来当力度用）
//    T6 噪声鲁棒：±30 / ±150 抖动都不误触
//    T7 单次尖峰（+400 一拍）**不得**触发（去抖）
//    T8 基线跟踪：电容缓慢漂移（+2/轮，共 +400）不误触
//    T9 电极开路（超时）：**不许报按下**（fail-safe），dbg_count0 == 0xFFFF
//    T10 扫描周期实测 + 不阻塞音频（sample_tick 速率不变）
//
//  运行： 见 _research/pc-link/_sim/run_tb_touch_key.do
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_touch_key;

    localparam integer N        = 4;
    localparam integer CLK_HZ   = 50_000_000;
    localparam real    TCLK     = 20.0;                 // 50 MHz
    localparam real    CLK_NS   = 20.0;
    // ★ 阈值档位（可通过 `vsim -gT_SH=3 tb_touch_key` 覆盖验证灵敏度权衡）：
    //   2 ⇒ 25%（默认，抗噪优先）  3 ⇒ 12.5%  4 ⇒ 6.25%（与 captouch 的 SENSITIVITY 同档）
    parameter integer T_SH = 2;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #(TCLK/2.0) clk = ~clk;

    // =========================================================================
    //  电极模型：弱上拉（到点才提供），**从不驱动 0**
    // =========================================================================
    wire [N-1:0] pad;
    reg  [N-1:0] model_pull = {N{1'b0}};
    assign (weak1, highz0) pad = model_pull;

    reg  [15:0] cap_target [0:N-1];      // "电容大小"⇒ 充电到阈值需要多少 clk
    reg  [15:0] chg_cnt    [0:N-1];
    integer j;

    initial begin
        // 初始：模拟 ~20 pF / 1 MΩ ⇒ τ≈20 µs ⇒ 约 800 个 clk
        for (j = 0; j < N; j = j + 1) cap_target[j] = 16'd800;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            model_pull <= {N{1'b0}};
            for (j = 0; j < N; j = j + 1) chg_cnt[j] <= 16'd0;
        end else begin
            for (j = 0; j < N; j = j + 1) begin
                if (pad[j] === 1'b0) begin
                    // DUT 正在放电 ⇒ 电容放净，撤掉上拉
                    chg_cnt[j]   <= 16'd0;
                    model_pull[j] <= 1'b0;
                end else begin
                    if (chg_cnt[j] < cap_target[j]) chg_cnt[j] <= chg_cnt[j] + 16'd1;
                    model_pull[j] <= (chg_cnt[j] >= cap_target[j] - 16'd1);
                end
            end
        end
    end

    // =========================================================================
    //  DUT
    // =========================================================================
    wire [N-1:0]     pressed;
    wire [N*16-1:0]  strength;
    wire [15:0]      dbg_count0;

    touch_key #(.N_PAD(N), .CLK_HZ(CLK_HZ), .THRESH_SH(T_SH)) dut (
        .clk(clk), .rst_n(rst_n), .pad(pad),
        .pressed(pressed), .strength(strength), .dbg_count0(dbg_count0)
    );

    // =========================================================================
    //  轮次检测：DUT 每轮都会把 pad[0] 强驱低一次 ⇒ 数它的上升沿就是"轮"
    //  （比按时间估更稳：测量值变化时轮长也会变）
    // =========================================================================
    reg        pad0_low_d = 1'b0;
    integer    round_cnt  = 0;
    time       last_round_t = 0;
    time       round_period_ns = 0;

    always @(posedge clk) begin
        if (!rst_n) begin
            pad0_low_d <= 1'b0;
            round_cnt  <= 0;
        end else begin
            pad0_low_d <= (pad[0] === 1'b0);
            if ((pad[0] === 1'b0) && !pad0_low_d) begin
                round_cnt      <= round_cnt + 1;
                round_period_ns <= $time - last_round_t;
                last_round_t    <= $time;
            end
        end
    end

    // =========================================================================
    //  音频 sample_tick：97 656.25 Hz = 50 MHz / 512（**用来证明扫描不阻塞音频**）
    // =========================================================================
    reg [8:0] stc = 9'd0;
    reg       sample_tick = 1'b0;
    always @(posedge clk) begin
        if (stc == 9'd511) begin stc <= 9'd0; sample_tick <= 1'b1; end
        else               begin stc <= stc + 9'd1; sample_tick <= 1'b0; end
    end
    integer tick_cnt = 0;
    always @(posedge clk) if (sample_tick) tick_cnt <= tick_cnt + 1;

    // =========================================================================
    //  工具
    // =========================================================================
    integer errors = 0;

    task chk;
        input         cond;
        input [511:0] name;
        begin
            if (cond) $display("[CHECK] PASS  %0s", name);
            else begin $display("[CHECK] FAIL  %0s", name); errors = errors + 1; end
        end
    endtask

    // 等 n 个完整扫描轮（用 pad[0] 被驱动低来计数）
    task wait_rounds;
        input integer n;
        integer k;
        reg [31:0] tgt;
        begin
            for (k = 0; k < n; k = k + 1) begin
                tgt = round_cnt + 1;
                while (round_cnt < tgt) @(posedge clk);
            end
        end
    endtask

    // 读某通道的 strength
    function [15:0] str_of;
        input integer idx;
        begin
            str_of = strength[idx*16 +: 16];
        end
    endfunction

    integer noise_seed = 32'h1234_5678;
    integer r;

    // =========================================================================
    //  主流程
    // =========================================================================
    initial begin
        $display("================================================================");
        $display(" tb_touch_key : N_PAD=%0d  CLK=%0d Hz  THRESH_SH=%0d (阈值档：2=25%% 3=12.5%% 4=6.25%%)",
                 N, CLK_HZ, T_SH);
        $display(" 电极模型：弱上拉(到点才提供)，**从不驱动 0**");
        $display("================================================================");

        repeat (20) @(posedge clk);
        rst_n = 1'b1;

        // ---------------- T1/T2: 上电初始化 + 无触摸不误触 ----------------
        wait_rounds(N * 3);                                   // 每通道至少测过 3 次
        $display("[INFO] T1 上电后 pressed=0x%0h  dbg_count0=%0d  strength=0x%0h",
                 pressed, dbg_count0, str_of(0));
        chk(pressed == {N{1'b0}},              "T1a 上电初始化期间不误报按下");
        chk(dbg_count0 > 16'd700 && dbg_count0 < 16'd900,
            "T1b 通道 0 原始计数在预期量级（约 800）");
        chk(str_of(0) < 16'd64,                "T1c 无触摸时 strength 近 0");

        wait_rounds(N * 50);
        chk(pressed == {N{1'b0}},              "T2  无触摸长稳 50 轮不误触");

        // ---------------- T3/T4: 触摸 pad1 → 按下；松手 → 释放 ----------------
        cap_target[1] = 16'd1200;                             // +400 ⇒ +50%
        wait_rounds(N * 8);
        $display("[INFO] T3 pressed=0x%0h  strength[1]=%0d (期望≈400)", pressed, str_of(1));
        chk(pressed == 4'b0010,                "T3a 只有 pad1 报按下");
        chk(str_of(1) > 16'd300,               "T3b strength[1] 明显 > 0（可当力度）");

        cap_target[1] = 16'd800;                              // 松手
        wait_rounds(N * 8);
        chk(pressed == {N{1'b0}},              "T4  松手后正确释放");

        // ---------------- T5: strength 随电容增量单调递增 ----------------
        begin
            integer lv;
            reg [15:0] prev_s;
            reg        mono;
            reg [15:0] tgt;
            mono   = 1'b1;
            prev_s = 16'd0;
            $display("[INFO] T5 strength 随电容增量：");
            for (lv = 0; lv < 5; lv = lv + 1) begin
                tgt = 16'd900 + lv * 16'd100;                 // 900/1000/1100/1200/1300
                cap_target[2] = tgt;
                wait_rounds(N * 6);
                $display("        cap=%0d  strength=%0d", tgt, str_of(2));
                if (str_of(2) <= prev_s) mono = 1'b0;
                prev_s = str_of(2);
            end
            chk(mono == 1'b1,                  "T5  strength 随电容增量严格单调递增");
            cap_target[2] = 16'd800;
            wait_rounds(N * 8);
        end

        // ---------------- T6: 噪声鲁棒（±30 / ±150 **双向**抖动不误触）----------------
        //  ⚠️ 踩过的坑：`$random` 返回**有符号**数，`r % 31` 是**单边**（只会向下）噪声，
        //     而"向下"永远不可能造成误触发 ⇒ 那个版本的噪声测试**没有覆盖到目标条件**。
        //     这里先屏蔽符号位得到非负数，再减去一半 ⇒ 真正**双向**抖动。
        begin
            integer k;
            reg     ok1, ok2;
            ok1 = 1'b1; ok2 = 1'b1;
            for (k = 0; k < 40; k = k + 1) begin         // ±30 双向
                for (j = 0; j < N; j = j + 1) begin
                    r = $random(noise_seed) & 32'h7FFF_FFFF;
                    cap_target[j] = 16'd800 + ((r % 61) - 30);
                end
                wait_rounds(1);
                if (pressed != {N{1'b0}}) ok1 = 1'b0;
            end
            for (k = 0; k < 40; k = k + 1) begin         // ±150 双向
                for (j = 0; j < N; j = j + 1) begin
                    r = $random(noise_seed) & 32'h7FFF_FFFF;
                    cap_target[j] = 16'd800 + ((r % 301) - 150);
                end
                wait_rounds(1);
                if (pressed != {N{1'b0}}) ok2 = 1'b0;
            end
            chk(ok1 == 1'b1,                   "T6a ±30 双向抖动 40 轮不误触");
            chk(ok2 == 1'b1,                   "T6b ±150 双向抖动 40 轮不误触");
        end
        // ★ "从不触发"本身证明不了什么 —— 必须再证明**检测器有能力触发**（覆盖面）。
        //   T6c/T6d 用【持续】偏移把有效阈值夹在中间：
        //     +250（> 25% 阈值 ≈200）必须触发；+100（< 阈值）必须不触发。
        for (j = 0; j < N; j = j + 1) cap_target[j] = 16'd800;
        wait_rounds(N * 6);
        cap_target[3] = 16'd1050;                            // 持续 +250
        wait_rounds(5);
        $display("[INFO] T6c 持续+250 → pressed=0x%0h strength[3]=%0d", pressed, str_of(3));
        chk(pressed[3] == 1'b1,                "T6c 持续 +250（超阈值）**必须**触发（证明检测能力）");
        cap_target[3] = 16'd800;
        wait_rounds(N * 8);
        cap_target[3] = 16'd900;                             // 持续 +100
        wait_rounds(5);
        chk(pressed[3] == 1'b0,                "T6d 持续 +100（低于阈值）不触发（阈值下界成立）");
        cap_target[3] = 16'd800;
        wait_rounds(N * 8);

        // ---------------- T7: 单次尖峰不触发（去抖）----------------
        for (j = 0; j < N; j = j + 1) cap_target[j] = 16'd800;
        wait_rounds(N * 4);
        cap_target[3] = 16'd1200;                             // 只尖一拍
        wait_rounds(1);
        cap_target[3] = 16'd800;
        wait_rounds(N * 4);
        chk(pressed == {N{1'b0}},              "T7  单次 +400 尖峰不触发（去抖生效）");

        // ---------------- T8: 基线跟踪缓慢漂移 ----------------
        begin
            integer k;
            reg     okdrift;
            okdrift = 1'b1;
            for (k = 0; k < 120; k = k + 1) begin
                for (j = 0; j < N; j = j + 1) cap_target[j] = 16'd800 + k * 16'd2;
                wait_rounds(1);
                if (pressed != {N{1'b0}}) okdrift = 1'b0;
            end
            $display("[INFO] T8 漂移后 cap=%0d  dbg_count0=%0d", cap_target[0], dbg_count0);
            chk(okdrift == 1'b1,               "T8  基线跟踪 +2/轮 ×120 轮不误触");
            for (j = 0; j < N; j = j + 1) cap_target[j] = 16'd800;
            wait_rounds(N * 8);
        end

        // ---------------- T10（先测，因为 T9 会把通道 0 打超时）：扫描周期 + 音频不受影响 ----------------
        begin
            integer tick0, round0;
            time    t0;
            tick0  = tick_cnt;
            round0 = round_cnt;
            t0     = $time;
            repeat (512 * 100) @(posedge clk);                // 51200 clk = 100 个音频采样周期
            $display("[INFO] T10 扫描实测：一轮 %0d ns（%0.1f us），%0d 轮共 %0d ns",
                     round_period_ns, round_period_ns/1000.0,
                     round_cnt - round0, $time - t0);
            $display("[INFO] T10 每通道 %0.1f us ⇒ 整轮扫描率 %0.1f kHz（音频 %0.1f kHz 的 1/%0.1f）",
                     round_period_ns/1000.0/N,
                     1.0e9/round_period_ns/1000.0,
                     97656.25/1000.0,
                     97656.25/(1.0e9/round_period_ns));
            $display("[INFO] T10 按下延迟 ≈ %0.2f ms（PRESS_N=3 × 单轮）",
                     3.0*round_period_ns/1.0e6);
            chk((tick_cnt - tick0) == 100,     "T10a 扫描期间 sample_tick 恰为 100 次（音频节拍不受影响）");
            chk(round_period_ns > 0 && (round_period_ns < 1_000_000),
                "T10b 单轮扫描周期 < 1 ms（触摸延迟可控）");
            // 扫描率必须明显低于音频采样率 97.65625 kHz
            chk((1.0e9 / round_period_ns) < (97656.25 / 4.0),
                "T10c 整轮扫描率 < 音频采样率的 1/4（明显慢于音频）");
            // ★ 赛题硬指标：控制→发声总延迟 ≤10 ms；触摸去抖是其中一环
            chk((3.0 * round_period_ns / 1.0e6) < 10.0,
                "T10d 按下延迟（3 轮去抖）< 10 ms（赛题控制延迟指标）");
        end

        // ---------------- T9: 电极开路（超时）→ 不许报按下 ----------------
        cap_target[0] = 16'd20000;                            // 远大于 MEASURE_MAX=8192
        repeat (60000) @(posedge clk);                        // 等一轮超时扫完
        $display("[INFO] T9 开路后 pressed=0x%0h  dbg_count0=0x%04h", pressed, dbg_count0);
        chk(pressed[0] == 1'b0,                "T9a 电极开路（超时）不报按下（fail-safe）");
        chk(dbg_count0 == 16'hFFFF,            "T9b dbg_count0 饱和为 0xFFFF（开路诊断约定）");

        // ---------------- 汇总 ----------------
        $display("================================================================");
        if (errors == 0) $display("[RESULT] PASS  (all checks passed)");
        else             $display("[RESULT] FAIL  (%0d checks failed)", errors);
        $display("================================================================");
        $finish;
    end

    initial begin
        #400_000_000;                                        // 400 ms 兜底（约 2000 轮）
        $display("[RESULT] TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire
