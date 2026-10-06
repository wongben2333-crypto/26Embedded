// =============================================================================
//  tb_touch_e2e.v —— 端到端仿真：**触摸 → 发声**
//
//   电极(RC) → touch_key.v → touch_notes.v → piano_engine.v → 音频样本
//
//  ★ 电极模型是**物理的**（不是"给一个延时"）：
//      V(t) = VCC·(1 − e^(−t/RC))，用**精确闭式步进** v ← VCC − (VCC−v)·e^(−dt/RC)；
//      "触摸" = **改变 C 值**（20 pF → 22/40 pF），不是改延时。
//      FPGA 输入门限 V_IH=2.0 V：v ≥ V_IH 时模型把 PAD 弱拉到 1，否则高阻。
//      ⇒ 计数由 R、C、V_IH 决定 ⇒ 能验证"计数 ↔ 电容"的单调关系（不是自证）。
//
//  验证内容：
//    E1 触摸 PAD0 ⇒ 发出 note=60(C4) 且音频基频 ≈ 261.63 Hz（频域在 Python 侧算）
//    E2 ★力度：强触摸(ΔC=20 pF) vs 轻触摸(ΔC=2 pF) ⇒ 上报 vel 更大、音频功率更大（给量化数字）
//    E3 多 PAD 同时 ⇒ 和弦（两个音都在响）
//    E4 松开 ⇒ 音符正确释放（active 回 0，无挂音）
//    E5 触摸扫描期间 sample_tick 不丢（计数与理论值一致）
//    E6 音频输出无 X/Z
//
//  音频样本被 dump 到 ../touch_e2e_*.txt（相对 _research/pc-link/_sim 运行），
//  再由 `_research/pc-link/analyze_touch_e2e.py` 做 RMS/FFT 定量。
//
//  运行： _research/pc-link/_sim/run_tb_touch_e2e.do   （编译需 -sv：用了 real 数组）
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_touch_e2e;

    localparam integer N       = 4;
    localparam integer CLK_HZ  = 50_000_000;
    localparam real    DT      = 1.0 / 50_000_000.0;   // 20 ns
    localparam real    VCC     = 3.3;
    localparam real    V_IH    = 2.0;                  // FPGA 输入门限（主假设，见 TOUCH-ELECTRICAL.md）
    localparam real    R_PULL  = 1.0e6;                // 1 MΩ 上拉
    localparam real    C_BASE  = 20.0e-12;             // 无触摸基础电容 20 pF

    reg clk = 1'b0;
    always #10 clk = ~clk;

    reg rst_n = 1'b0;
    integer j;

    // =========================================================================
    //  电极模型：真实 RC 指数充电 + 门限驱动（弱 1 / 高阻，从不驱动 0）
    //  ⚠️ `real` 数组是 SystemVerilog 语法 ⇒ 本文件必须用 vlog -sv 编译
    // =========================================================================
    wire [N-1:0] pad;
    reg  [N-1:0] model_pull = {N{1'b0}};
    assign (weak1, highz0) pad = model_pull;

    real v_pad   [0:N-1];       // PAD 上的电压
    real cap_pf  [0:N-1];       // PAD 电容（pF）—— **"触摸"就是改这个值**
    real k_step  [0:N-1];       // e^(−dt/RC)，每次 C 变化时重算
    real rc_cur  [0:N-1];
    real cap_last[0:N-1];

    initial begin
        for (j = 0; j < N; j = j + 1) begin
            v_pad[j]    = 0.0;
            cap_pf[j]   = C_BASE * 1e12;      // 20 pF
            cap_last[j] = -1.0;               // 强制首次重算
            k_step[j]   = 0.0;
            rc_cur[j]   = 0.0;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            model_pull <= {N{1'b0}};
            for (j = 0; j < N; j = j + 1) v_pad[j] = 0.0;
        end else begin
            for (j = 0; j < N; j = j + 1) begin
                // C 变了就重算步进系数（避免每拍都调 $exp，仿真更快）
                if (cap_pf[j] != cap_last[j]) begin
                    cap_last[j] = cap_pf[j];
                    rc_cur[j]   = R_PULL * cap_pf[j] * 1e-12;
                    k_step[j]   = $exp(-DT / rc_cur[j]);
                end
                if (pad[j] === 1'b0) begin
                    v_pad[j] = 0.0;                       // DUT 强驱低 ⇒ 放净
                end else if (v_pad[j] < VCC) begin
                    v_pad[j] = VCC - (VCC - v_pad[j]) * k_step[j];   // 精确指数步进
                end
                model_pull[j] <= (v_pad[j] >= V_IH) ? 1'b1 : 1'b0;
            end
        end
    end

    // =========================================================================
    //  DUT 链
    // =========================================================================
    wire [N-1:0]    pressed;
    wire [N*16-1:0] strength;
    wire [15:0]     dbg_count0;

    touch_key #(.N_PAD(N), .CLK_HZ(CLK_HZ)) u_touch (
        .clk(clk), .rst_n(rst_n), .pad(pad),
        .pressed(pressed), .strength(strength), .dbg_count0(dbg_count0)
    );

    wire        t_on_valid, t_off_valid;
    wire [6:0]  t_on_note, t_on_vel, t_off_note;
    wire [N-1:0] t_held;

    touch_notes #(.N_PAD(N), .BASE_NOTE(60), .NOTE_STRIDE(2), .VEL_SH(3)) u_notes (
        .clk(clk), .rst_n(rst_n),
        .pressed(pressed), .strength(strength),
        .on_valid(t_on_valid), .on_note(t_on_note), .on_vel(t_on_vel),
        .off_valid(t_off_valid), .off_note(t_off_note), .held(t_held)
    );

    // 音频采样节拍：50 MHz / 512 = 97 656.25 Hz（与工程一致）
    reg [8:0] stc = 9'd0;
    reg       sample_tick = 1'b0;
    always @(posedge clk) begin
        if (stc == 9'd511) begin stc <= 9'd0; sample_tick <= 1'b1; end
        else               begin stc <= stc + 9'd1; sample_tick <= 1'b0; end
    end

    wire signed [15:0] mix_out;
    wire [7:0]         active;

    piano_engine #(.N_VOICES(8), .CLK_HZ(CLK_HZ)) u_eng (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
        .on_valid(t_on_valid), .on_note(t_on_note), .on_vel(t_on_vel),
        .off_valid(t_off_valid), .off_note(t_off_note),
        .glide_on(1'b0), .glide_time(7'd0),
        .vib_on(1'b0), .vib_depth(7'd0), .vib_rate(7'd0),
        .sustain(1'b0),
        .mix_out(mix_out), .active(active)
    );

    // =========================================================================
    //  采集与统计
    // =========================================================================
    integer fd = 0;
    reg     cap_en = 0;
    integer cap_n = 0;
    reg signed [63:0] sum_sq = 0;
    reg signed [15:0] peak = 0;
    integer xz_cnt = 0;
    integer tick_seen = 0;

    always @(posedge clk) begin
        if (sample_tick) tick_seen <= tick_seen + 1;
        // ★ 必须用 sample_tick 门控：mix_out 每 512 个 clk 才更新一次，
        //   若按 clk 采集会得到 **512× 零阶保持**的假信号（FFT 频率全错）——实测踩过。
        if (cap_en && sample_tick) begin
            if ($isunknown(mix_out)) xz_cnt <= xz_cnt + 1;
            else begin
                sum_sq <= sum_sq + mix_out * mix_out;
                if (mix_out > peak)  peak <= mix_out;
                if (-mix_out > peak) peak <= -mix_out;
                cap_n  <= cap_n + 1;
                if (fd != 0) $fwrite(fd, "%0d\n", mix_out);
            end
        end
    end

    // ---- 统计/判定变量（**必须在 always 之前声明**，否则 vlog 报 Undefined variable）----
    integer errors = 0;
    reg signed [63:0] sq_weak = 0, sq_strong = 0, sq_chord = 0, sq_release = 0;  // 64bit：sum_sq~1e11 会溢出 32bit
    integer tick0, tick1;
    reg [6:0] vel_weak = 0, vel_strong = 0;
    reg [7:0] active_chord = 8'h00;
    integer   on_cnt_before_chord = 0;
    reg [6:0] hist0 = 7'd0, hist1 = 7'd0;          // 最近两个 NoteOn 音号（和弦判定）

    // 记录事件（音符/力度）
    reg [6:0] last_on_note = 7'd0, last_on_vel = 7'd0;
    integer   on_cnt = 0, off_cnt = 0;
    always @(posedge clk) begin
        if (t_on_valid) begin
            last_on_note <= t_on_note; last_on_vel <= t_on_vel; on_cnt <= on_cnt + 1;
            hist0 <= hist1; hist1 <= t_on_note;          // 留最近两个音号（和弦判定）
            $display("[EV]  NoteOn  note=%0d vel=%0d  (strength[%0d]=%0d, count0=%0d)",
                     t_on_note, t_on_vel, 0, strength[0*16 +: 16], dbg_count0);
        end
        if (t_off_valid) begin
            off_cnt <= off_cnt + 1;
            $display("[EV]  NoteOff note=%0d  (count0=%0d)", t_off_note, dbg_count0);
        end
    end

    // （统计变量已在上方统一声明）

    task chk;
        input         cond;
        input [511:0] name;
        begin
            if (cond) $display("[CHECK] PASS  %0s", name);
            else begin $display("[CHECK] FAIL  %0s", name); errors = errors + 1; end
        end
    endtask

    task wait_ticks;
        input integer n;
        begin repeat (n) @(posedge sample_tick); end
    endtask

    // 等某通道 pressed 变成期望值（最多等 5 ms）
    task wait_pressed;
        input integer ch;
        input         val;
        integer       guard;
        begin
            guard = 0;
            while ((pressed[ch] !== val) && (guard < 250000)) begin
                @(posedge clk); guard = guard + 1;
            end
        end
    endtask

    // 采集 n 个样本到文件
    task capture;
        input [1023:0] fname;      // 用字符串常量传入
        input integer  n;
        begin
            fd = $fopen(fname, "w");
            sum_sq = 0; peak = 0; cap_n = 0;
            cap_en = 1;
            wait_ticks(n);
            cap_en = 0;
            $fclose(fd); fd = 0;
            $display("[CAP]  %0s : %0d 样本, peak=%0d, sum_sq=%0d", fname, cap_n, peak, sum_sq);
        end
    endtask

    // =========================================================================
    //  主流程
    // =========================================================================
    initial begin
        $display("================================================================");
        $display(" tb_touch_e2e : 触摸 → 发声 端到端");
        $display("   电极模型：V(t)=VCC(1-e^-t/RC)，R=1 MΩ，V_IH=%.1f V（**物理模型**）", V_IH);
        $display("   触摸 = 改电容：基础 %.0f pF；轻触 +2 pF；强触 +20 pF", C_BASE*1e12);
        $display("   音频：97 656.25 Hz 采样；piano_engine N_VOICES=8");
        $display("================================================================");
        for (j = 0; j < N; j = j + 1) cap_pf[j] = C_BASE * 1e12;

        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        wait_ticks(400);                       // 让 touch_key 建立基线
        $display("[INFO] 基线建立后 count0=%0d（20 pF 理论值见 TOUCH-ELECTRICAL.md §1）", dbg_count0);

        // ---------------- S0 边界：低于阈值的触摸**必须不触发** ----------------
        //  ★ 这条是从一次"我的场景设计错误"里学来的，保留为正式用例：
        //    默认阈值 25% ⇒ 最小可检 ΔC ≈ 25% × 20 pF = **5 pF**；
        //    我原本把"轻触"设成 +2 pF（10%）⇒ 正确行为就是**不触发**（实测确认）。
        $display("\n---- 场景0：亚阈值触摸 PAD0（C=22 pF，ΔC=2 pF < 25%% 阈值）----");
        cap_pf[0] = 22.0;
        wait_ticks(800);
        $display("[INFO] 亚阈值：pressed=0x%0h strength[0]=%0d count0=%0d（基线 %0d）",
                 pressed, strength[0*16 +: 16], dbg_count0, 934);
        chk(pressed[0] == 1'b0, "S0  ΔC=2 pF（低于 25% 阈值）**不触发** —— 阈值语义正确");
        cap_pf[0] = C_BASE * 1e12;
        wait_ticks(400);

        // ---------------- E1/E2 轻触摸 PAD0（ΔC=6 pF，刚过阈值）----------------
        $display("\n---- 场景1：轻触摸 PAD0（C=26 pF，ΔC=6 pF）----");
        cap_pf[0] = 26.0;
        wait_pressed(0, 1'b1);
        $display("[INFO] 轻触：pressed=0x%0h strength[0]=%0d count0=%0d",
                 pressed, strength[0*16 +: 16], dbg_count0);
        wait_ticks(800);                       // 让包络进入相对稳态
        capture("../touch_e2e_weak.txt", 2048);
        sq_weak = sum_sq;
        vel_weak = last_on_vel;

        cap_pf[0] = C_BASE * 1e12;             // 松开
        wait_pressed(0, 1'b0);
        wait_ticks(600);

        // ---------------- E2 强触摸 PAD0（ΔC=20 pF）----------------
        $display("\n---- 场景2：强触摸 PAD0（C=40 pF，ΔC=20 pF）----");
        cap_pf[0] = 40.0;
        wait_pressed(0, 1'b1);
        $display("[INFO] 强触：pressed=0x%0h strength[0]=%0d count0=%0d",
                 pressed, strength[0*16 +: 16], dbg_count0);
        wait_ticks(800);
        capture("../touch_e2e_strong.txt", 2048);
        sq_strong = sum_sq;
        vel_strong = last_on_vel;

        cap_pf[0] = C_BASE * 1e12;
        wait_pressed(0, 1'b0);
        wait_ticks(600);

        // ---------------- E3 和弦：PAD0 + PAD2 同时 ----------------
        $display("\n---- 场景3：和弦 PAD0(C4) + PAD2(E4) 同时触摸 ----");
        on_cnt_before_chord = on_cnt;
        cap_pf[0] = 40.0;
        cap_pf[2] = 40.0;
        wait_pressed(0, 1'b1);
        wait_pressed(2, 1'b1);
        wait_ticks(800);
        active_chord = active;                 // ★ 在【和弦进行中】采样，而不是松开之后
        capture("../touch_e2e_chord.txt", 4096);
        sq_chord = sum_sq;
        $display("[INFO] 和弦期间 active=0x%02h，本场景新增 NoteOn %0d 个，最近两音=%0d,%0d",
                 active_chord, on_cnt - on_cnt_before_chord, hist0, hist1);

        // ---------------- E4 松开 ⇒ 释放 ----------------
        //  ⚠️ 教训：不能拿 `active==0` 当"无挂音"判据 —— 钢琴**释放尾音**期间 active 仍为 1
        //     （这是正确行为）。真正的"无挂音"判据是【每个 NoteOn 都有配对的 NoteOff】。
        $display("\n---- 场景4：松开所有 ----");
        cap_pf[0] = C_BASE * 1e12;
        cap_pf[2] = C_BASE * 1e12;
        wait_pressed(0, 1'b0);
        wait_pressed(2, 1'b0);
        wait_ticks(1200);                      // 等包络进入释放段
        $display("[INFO] 松开后 active=0x%02h（释放尾音仍可能为非 0）count0=%0d", active, dbg_count0);
        capture("../touch_e2e_release.txt", 2048);
        sq_release = sum_sq;
        $display("[INFO] 释放段 sum_sq=%0d（对比和弦期 %0d）", sq_release, sq_chord);

        // ---------------- E5 sample_tick 连续性 ----------------
        tick0 = tick_seen;
        repeat (512 * 200) @(posedge clk);     // 200 个音频周期
        tick1 = tick_seen;
        $display("\n[INFO] E5: 51200 clk 内 sample_tick 增加 %0d（期望 200）", tick1 - tick0);

        // ---------------- 汇总 ----------------
        $display("\n================================================================");
        $display(" 电量对比（sum_sq，越大越响）：");
        $display("   轻触(ΔC=2 pF)  vel=%0d  sum_sq=%0d", vel_weak, sq_weak);
        $display("   强触(ΔC=20 pF) vel=%0d  sum_sq=%0d", vel_strong, sq_strong);
        $display("   和弦(C4+E4)    sum_sq=%0d", sq_chord);
        $display("--------------------------------------------------------------");
        chk(on_cnt >= 1,                       "E1a 触摸产生了 NoteOn");
        chk((hist1 == 7'd60) || (hist0 == 7'd60), "E1b 音符号正确（PAD0 = 60 = C4）");
        chk(vel_strong > vel_weak,             "E2a 强触摸上报的力度更大");
        chk(sq_strong > sq_weak * 4,           "E2b 强触摸音频功率 > 4× 轻触摸（力度真的影响响度）");
        chk(sq_chord > 0,                      "E3a 和弦有音频输出");
        chk((on_cnt - on_cnt_before_chord) >= 2, "E3b 和弦发出了 ≥2 个 NoteOn");
        chk((hist0 == 7'd60 && hist1 == 7'd64) || (hist0 == 7'd64 && hist1 == 7'd60),
                                               "E3c 两个音是 C4(60) 与 E4(64)");
        chk(active_chord != 8'h00,             "E3d 和弦期间 active 非 0（确实在发声）");
        chk(on_cnt == off_cnt,                 "E4a 每个 NoteOn 都有配对 NoteOff（无挂音）");
        chk(sq_release < (sq_chord / 5),       "E4b 松手后音频功率显著衰减（释放生效）");
        chk((tick1 - tick0) == 200,            "E5  触摸扫描期间 sample_tick 不丢（200/200）");
        chk(xz_cnt == 0,                       "E6  音频输出全程无 X/Z");
        $display("================================================================");
        if (errors == 0) $display("[RESULT] PASS  (all checks passed)");
        else             $display("[RESULT] FAIL  (%0d checks failed)", errors);
        $display("================================================================");
        $finish;
    end

    initial begin
        #300_000_000;                          // 300 ms 兜底（4096 样本 ≈ 42 ms，留足余量）
        $display("[RESULT] TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire
