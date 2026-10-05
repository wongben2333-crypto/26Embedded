// =============================================================================
//  tb_piano_engine.v —— 钢琴音色引擎仿真（ModelSim，纯 RTL，不用高云原语）
//
//  验证目标（对应任务书要求的 ① 单音频率 ② 复音 ③ note-off 后衰减）：
//    T1 单音 A4(69)：写出 16384 个采样点 → 外部 FFT 找基频与 6 个泛音
//    T2 note-off：松键后 RMS 必须在 0.12 s 内明显下落（阻音器）
//    T3 三音和弦 C4/E4/G4：FFT 必须能同时数出 3 个基频（复音）
//    T4 力度对比 vel=30 / vel=120：高次泛音占比必须随力度变大（"变亮"）
//    T5 按住不放（C6）：高次泛音先死 → 电平自然下落，没有 sustain 平台
//    T6 满复音 8 音：active 全 1、输出不削顶成方波
//    T7 note-on 靠得太近（<14 clk，装载期间）会被忽略 —— 记录真实行为
//    T8 控制→发声延迟：从 note-on 脉冲到首个非零输出采样点的拍数
//
//  用法（在任意工作目录下，先建好 out/ 子目录）：
//      vsim -c -do sim/piano/tb_piano_engine.do
//  本 tb 只写相对路径 out/piano_*.txt，因此不会碰工程里别人的 work/ 与 out/。
//
//  ⚠️ 两个 ModelSim 用法要点：
//     · 时钟 20 ns（50 MHz），sample_tick 每 512 clk 一拍（fs = 97656.25 Hz）
//     · 采样点必须在 mix_out 更新之后再读：本 tb 用 cap_sr[3] 打 4 拍，
//       再 #1 让非阻塞赋值结算完，避免读到上一拍的值
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_piano_engine;

    localparam integer CLK_HZ   = 50_000_000;
    localparam integer TICK_DIV = 512;          // fs = 50e6/512 = 97656.25 Hz
    localparam integer NS_A     = 16384;        // 单音记录长度（FFT 用）
    localparam integer NS_R     = 8000;         // 松键后记录长度
    localparam integer NS_CH    = 8192;         // 和弦记录长度
    localparam integer NS_VEL   = 8192;         // 力度对比
    localparam integer NS_HOLD  = 8192;         // 按住不放
    localparam integer NS_P8    = 4096;         // 8 音满复音

    // ------------------------------------------------------------ 时钟 ------
    reg clk = 1'b0;
    always #10 clk = ~clk;                       // 20 ns → 50 MHz

    reg rst_n = 1'b0;

    // ------------------------------------------------------- 采样节拍 -------
    reg [9:0] tick_cnt = 10'd0;
    reg       sample_tick = 1'b0;
    always @(posedge clk) begin
        if (!rst_n) begin
            tick_cnt    <= 10'd0;
            sample_tick <= 1'b0;
        end else if (tick_cnt == TICK_DIV - 1) begin
            tick_cnt    <= 10'd0;
            sample_tick <= 1'b1;
        end else begin
            tick_cnt    <= tick_cnt + 10'd1;
            sample_tick <= 1'b0;
        end
    end

    // 采样抓取标记：mix_out 在 tick 后第 3 拍更新，这里再等 1 拍（cap_sr[3]）
    reg [3:0] cap_sr = 4'd0;
    always @(posedge clk) cap_sr <= {cap_sr[2:0], sample_tick};
    wire cap = cap_sr[3];

    // ------------------------------------------------------------ DUT ------
    reg        on_valid  = 1'b0;
    reg [6:0]  on_note   = 7'd0;
    reg [6:0]  on_vel    = 7'd0;
    reg        off_valid = 1'b0;
    reg [6:0]  off_note  = 7'd0;

    // ---- 表情输入（T1~T7 全程保持 0 ⇒ 这一段就是"加表情前"的回归激励）----
    reg        glide_on   = 1'b0;
    reg [6:0]  glide_time = 7'd0;
    reg        vib_on     = 1'b0;
    reg [6:0]  vib_depth  = 7'd0;
    reg [6:0]  vib_rate   = 7'd0;
    reg        sustain    = 1'b0;

    wire signed [15:0] mix_out;
    wire [7:0]         active;

    piano_engine #(
        .N_VOICES  (8),
        .CLK_HZ    (CLK_HZ),
        .OUT_SHIFT (1)
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .sample_tick (sample_tick),
        .on_valid    (on_valid),
        .on_note     (on_note),
        .on_vel      (on_vel),
        .off_valid   (off_valid),
        .off_note    (off_note),
        .glide_on    (glide_on),
        .glide_time  (glide_time),
        .vib_on      (vib_on),
        .vib_depth   (vib_depth),
        .vib_rate    (vib_rate),
        .sustain     (sustain),
        .mix_out     (mix_out),
        .active      (active)
    );

    // ------------------------------------------------------- 文件句柄 ------
    integer fa, fr, fc, fv1, fv2, fh, fp;
    integer fvi, fnv, fgl, fsu;

    // ------------------------------------------------------------ 任务 ------
    // note-on 单拍脉冲
    task note_on;
        input [6:0] n;
        input [6:0] v;
        begin
            @(posedge clk);
            on_valid <= 1'b1;
            on_note  <= n;
            on_vel   <= v;
            @(posedge clk);
            on_valid <= 1'b0;
            on_vel   <= 7'd0;
        end
    endtask

    task note_off;
        input [6:0] n;
        begin
            @(posedge clk);
            off_valid <= 1'b1;
            off_note  <= n;
            @(posedge clk);
            off_valid <= 1'b0;
        end
    endtask

    // 连续记录 nsamp 个采样点到文件
    // ★ 同时统计 X 样本数：flow-verifier 的独立 TB 曾抓到"active 位图正常、
    //   波形全 X"（根因是越界位选读到 x）。这条自检确保同类问题不会再溜过去。
    integer xn;
    task rec;
        input integer fh;
        input integer nsamp;
        integer k;
        begin
            for (k = 0; k < nsamp; k = k + 1) begin
                @(posedge clk);
                #1;
                while (!cap) begin
                    @(posedge clk);
                    #1;
                end
                if (^mix_out === 1'bx) xn = xn + 1;
                $fwrite(fh, "%0d\n", mix_out);
            end
        end
    endtask

    // 平均绝对值（MAV）：比 RMS 简单、无开方，做"衰减了多少"的判据足够
    task meas_mav;
        input  integer nsamp;
        output integer mav;
        integer k;
        reg [63:0] acc;
        reg signed [15:0] s;
        integer a;
        begin
            acc = 64'd0;
            for (k = 0; k < nsamp; k = k + 1) begin
                @(posedge clk);
                #1;
                while (!cap) begin
                    @(posedge clk);
                    #1;
                end
                s = mix_out;
                a = (s < 0) ? (-s) : s;
                acc = acc + a;
            end
            mav = acc / nsamp;
        end
    endtask

    // 等指定个数的采样点
    task wait_ticks;
        input integer nt;
        integer g;
        begin
            g = 0;
            while (g < nt) begin
                @(posedge clk);
                #1;
                if (cap) g = g + 1;
            end
        end
    endtask

    // 等全部声部静音（用 tick 计数，判据与"阻音器时长"直接对应）
    task wait_silent;
        input integer max_tick;
        integer g;
        begin
            g = 0;
            while ((active !== 8'd0) && (g < max_tick)) begin
                @(posedge clk);
                #1;
                if (cap) g = g + 1;
            end
            if (active !== 8'd0)
                $display("[TB] 警告：等了 %0d 个采样点仍有声部发声 (active=%b)", g, active);
        end
    endtask

    // 峰值绝对值
    task meas_peak;
        input  integer nsamp;
        output integer pk;
        integer k;
        reg signed [15:0] s;
        integer a;
        begin
            pk = 0;
            for (k = 0; k < nsamp; k = k + 1) begin
                @(posedge clk);
                #1;
                while (!cap) begin
                    @(posedge clk);
                    #1;
                end
                s = mix_out;
                a = (s < 0) ? (-s) : s;
                if (a > pk) pk = a;
            end
        end
    endtask

    integer mav_early, mav_late, mav_hold1, mav_hold2, pk;
    integer lat_cyc;
    integer i;
    integer nfail;

    // 声部位图里 1 的个数（声部分配是轮转的，具体是哪几位不该写死）
    function integer pop8;
        input [7:0] v;
        integer k;
        begin
            pop8 = 0;
            for (k = 0; k < 8; k = k + 1)
                pop8 = pop8 + v[k];
        end
    endfunction

    // ------------------------------------------------------------ 主流程 ---
    initial begin
        nfail = 0;
        xn    = 0;
        fa  = $fopen("out/piano_a4.txt",      "w");
        fr  = $fopen("out/piano_a4_rel.txt",  "w");
        fc  = $fopen("out/piano_chord.txt",   "w");
        fv1 = $fopen("out/piano_vel030.txt",  "w");
        fv2 = $fopen("out/piano_vel120.txt",  "w");
        fh  = $fopen("out/piano_hold_c6.txt", "w");
        fp  = $fopen("out/piano_poly8.txt",   "w");
        fvi = $fopen("out/piano_vib.txt",     "w");
        fnv = $fopen("out/piano_novib.txt",   "w");
        fgl = $fopen("out/piano_glide.txt",   "w");
        fsu = $fopen("out/piano_sustain.txt", "w");
        if (fa == 0 || fc == 0 || fp == 0) begin
            $display("[TB] 无法打开 out/piano_*.txt —— 请先建好 out/ 子目录");
            $finish;
        end

        $display("================================================================");
        $display("[TB] tb_piano_engine 开始  fs = %0d Hz (sample_tick 每 %0d clk)",
                 CLK_HZ / TICK_DIV, TICK_DIV);
        $display("[TB] 期望：8 声部 x 6 泛音 = 48 个独立加法分量");
        $display("================================================================");

        // ---------------- 复位 ----------------
        rst_n = 1'b0;
        repeat (40) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);

        // ================= T1: 单音 A4(69) vel=100 =================
        $display("");
        $display("[T1] 单音 A4 (note 69, 440.00 Hz) vel=100 —— 记录 %0d 采样点", NS_A);
        lat_cyc = -1;
        fork
            note_on(7'd69, 7'd100);
            begin : lat_meas
                // 控制→发声延迟：从脉冲那拍到首个 |mix_out| > 8 的采样点
                integer c;
                c = 0;
                @(posedge clk);
                while (c < 200000) begin
                    @(posedge clk);
                    #1;
                    if (cap && ((mix_out > 16'sd8) || (mix_out < -16'sd8))) begin
                        lat_cyc = c;
                        c = 200000;
                    end
                    c = c + 1;
                end
            end
        join
        $display("[T1] active = %b （期望 0000_0001）", active);
        if (active !== 8'b0000_0001) begin
            $display("[T1] FAIL: 声部分配后 active 不是 8'b00000001");
            nfail = nfail + 1;
        end else begin
            $display("[T1] PASS: active = %b", active);
        end
        if (lat_cyc < 0) begin
            $display("[T1] FAIL: 没有任何输出");
            nfail = nfail + 1;
        end else begin
            $display("[T1] 控制->发声延迟 = %0d clk = %0d ns （判据 <=10 ms）",
                     lat_cyc, lat_cyc * 20);
            if (lat_cyc * 20 > 10_000_000) begin
                $display("[T1] FAIL: 延迟超过 10 ms");
                nfail = nfail + 1;
            end else begin
                $display("[T1] PASS: 延迟远小于 10 ms");
            end
        end
        meas_peak(256, pk);
        $display("[T1] 起音峰值 |mix_out| = %0d (满幅 32767)", pk);
        rec(fa, NS_A);

        // ================= T2: note-off 后衰减 =================
        $display("");
        $display("[T2] note-off 后阻音器衰减 —— 记录 %0d 采样点", NS_R);
        note_off(7'd69);
        meas_mav(2048, mav_early);          // 松键瞬间的平均电平
        rec(fr, NS_R);
        meas_mav(2048, mav_late);           // 松键约 0.1 s 后的平均电平
        $display("[T2] 松键瞬间平均电平 = %0d，约 0.1 s 后 = %0d", mav_early, mav_late);
        if (mav_late * 3 < mav_early) begin
            $display("[T2] PASS: 松键后明显衰减（>9.5 dB）");
        end else begin
            $display("[T2] FAIL: 松键后没有明显衰减");
            nfail = nfail + 1;
        end

        // 等所有声部彻底静音，避免影响后续测试（阻音器 ≈ 21 ms 时间常数，
        // 降到 active 阈值(-48 dB)约 116 ms ≈ 11300 个采样点）
        wait_silent(40000);
        $display("[T2] 全部声部已静音，active = %b", active);

        // ================= T3: 三音和弦 C4/E4/G4 =================
        $display("");
        $display("[T3] 三音和弦 C4(60) E4(64) G4(67) vel=100 —— 复音");
        // ⚠️ 三个 note-on 至少间隔 14 clk（装载 FSM 期间会忽略新 note-on）
        fork
            begin note_on(7'd60, 7'd100); repeat (20) @(posedge clk);
                  note_on(7'd64, 7'd100); repeat (20) @(posedge clk);
                  note_on(7'd67, 7'd100); end
        join
        repeat (200) @(posedge clk);
        // 注意：声部分配是轮转的（磨损均衡），所以只判"有几个声部在响"，
        // 不写死具体是哪几位 —— 上一版把期望写成 0000_0111，实际是 0000_1110，
        // 那是分配器的正常行为，不是 bug。
        $display("[T3] active = %b，发声声部数 = %0d （期望 3）", active, pop8(active));
        if (pop8(active) != 3) begin
            $display("[T3] FAIL: 和弦没有占用 3 个声部");
            nfail = nfail + 1;
        end else begin
            $display("[T3] PASS: 3 个声部同时发声（复音成立）");
        end
        rec(fc, NS_CH);
        note_off(7'd60); note_off(7'd64); note_off(7'd67);
        wait_silent(40000);

        // ================= T4: 力度 → 音色明暗 =================
        $display("");
        $display("[T4] 力度对比 A4 vel=30 vs vel=120（高次泛音应随力度增强）");
        note_on(7'd69, 7'd30);
        rec(fv1, NS_VEL);
        note_off(7'd69);
        wait_silent(40000);
        note_on(7'd69, 7'd120);
        rec(fv2, NS_VEL);
        note_off(7'd69);
        wait_silent(40000);
        $display("[T4] 样本已写入 out/piano_vel030.txt / out/piano_vel120.txt（FFT 分析见 Python）");

        // ================= T5: 按住不放也衰减（无 sustain 平台）=================
        // ⚠️ 判据必须看【足够长】的时间：钢琴基频时间常数是秒级，
        //    在前 100 ms 里电平本来就几乎不变（高次泛音虽然掉得快，但它们本来
        //    就比基频低 20~26 dB，对总电平贡献很小）。
        //    所以这里按住 1 s 再比：C6 基频 τ≈1.34 s ⇒ 1 s 后应掉 >3 dB。
        $display("");
        $display("[T5] 按住不放的 C6(84)：按住 1 s 后电平应明显下落（无 sustain 平台）");
        note_on(7'd84, 7'd110);
        meas_mav(2048, mav_hold1);
        rec(fh, NS_HOLD);
        wait_ticks(97656);                  // 正好 1.0 s（fs = 97656.25 Hz）
        meas_mav(2048, mav_hold2);
        note_off(7'd84);
        $display("[T5] 起音平均电平 = %0d，按住 1 s 后 = %0d（%.2f dB）",
                 mav_hold1, mav_hold2,
                 20.0 * $log10((mav_hold2 + 0.5) / (mav_hold1 + 0.5)));
        if (mav_hold2 * 10 < mav_hold1 * 7) begin
            $display("[T5] PASS: 按住不放时电平在持续下落（无 sustain 平台）");
        end else begin
            $display("[T5] FAIL: 按住 1 s 电平几乎不变 —— 像有 sustain 平台");
            nfail = nfail + 1;
        end
        wait_silent(40000);

        // ================= T6: 8 音满复音 =================
        $display("");
        $display("[T6] 8 音满复音（C4 E4 G4 B4 D5 F#5 A5 C6）");
        fork
            begin
                note_on(7'd60, 7'd100); repeat (20) @(posedge clk);
                note_on(7'd64, 7'd100); repeat (20) @(posedge clk);
                note_on(7'd67, 7'd100); repeat (20) @(posedge clk);
                note_on(7'd71, 7'd100); repeat (20) @(posedge clk);
                note_on(7'd74, 7'd100); repeat (20) @(posedge clk);
                note_on(7'd78, 7'd100); repeat (20) @(posedge clk);
                note_on(7'd81, 7'd100); repeat (20) @(posedge clk);
                note_on(7'd84, 7'd100);
            end
        join
        repeat (300) @(posedge clk);
        $display("[T6] active = %b （期望 1111_1111）", active);
        if (active !== 8'b1111_1111) begin
            $display("[T6] FAIL: 没有占满 8 个声部");
            nfail = nfail + 1;
        end else begin
            $display("[T6] PASS: 8 个声部全部发声");
        end
        meas_peak(2048, pk);
        $display("[T6] 8 音峰值 = %0d（满幅 32767；软膝限幅生效属正常）", pk);
        rec(fp, NS_P8);
        note_off(7'd60); note_off(7'd64); note_off(7'd67); note_off(7'd71);
        note_off(7'd74); note_off(7'd78); note_off(7'd81); note_off(7'd84);
        wait_silent(40000);
        $display("[T6] 全部 off 后 active = %b （期望 0000_0000 = 阻音器已把 8 个声部放掉）",
                 active);
        if (active !== 8'b0000_0000) begin
            $display("[T6] FAIL: 全部 off 后仍有声部没释放");
            nfail = nfail + 1;
        end else begin
            $display("[T6] PASS: 全部 off 后 8 个声部全部释放");
        end

        // ================= T7: 太近的 note-on 会被忽略 =================
        $display("");
        $display("[T7] 两个 note-on 相隔 5 clk（< 装载 14 拍）→ 记录真实行为");
        fork
            begin note_on(7'd72, 7'd100); end
            begin repeat (5) @(posedge clk); note_on(7'd76, 7'd100); end
        join
        repeat (300) @(posedge clk);
        $display("[T7] active = %b，发声声部数 = %0d （预期 1：第二个 note-on 被忽略）",
                 active, pop8(active));
        $display("[T7] 说明：现场演奏/MIDI 事件间隔 >> 280 ns，不影响实际使用");
        if (pop8(active) != 1) begin
            $display("[T7] 注意：发声声部数不是 1 —— 装载窗口行为与预期不同");
            nfail = nfail + 1;
        end else begin
            $display("[T7] PASS: 装载窗口内（<14 clk）的第二个 note-on 确实被忽略");
        end
        note_off(7'd72); note_off(7'd76);
        wait_silent(40000);

        // =====================================================================
        //  T1~T7 到此结束。以上全程 glide_on/vib_on/vib_depth/vib_rate/sustain 恒 0，
        //  落盘文件与"加表情之前"的 reference 必须逐样本一致（见 evidence/ref_before）。
        //  下面开始表情测试（拓展②）。
        // =====================================================================

        // ================= T8: 颤音 =================
        $display("");
        $display("[T8] 颤音：vib_depth=127（±49.6 cent） vib_rate=127（f_lfo=12.7 Hz）");
        vib_on = 1'b1; vib_depth = 7'd127; vib_rate = 7'd127;
        note_on(7'd69, 7'd100);
        rec(fvi, 32768);                    // 0.336 s，FFT 分辨率 2.98 Hz
        note_off(7'd69);
        vib_on = 1'b0; vib_depth = 7'd0; vib_rate = 7'd0;
        wait_silent(40000);
        $display("[T8] 已写 out/piano_vib.txt（颤音开）");
        // 同一音符、其余条件完全相同，只是关掉颤音 → 用来对照边带
        note_on(7'd69, 7'd100);
        rec(fnv, 32768);
        note_off(7'd69);
        wait_silent(40000);
        $display("[T8] 已写 out/piano_novib.txt（颤音关，对照）");

        // ================= T9: 滑音 =================
        $display("");
        $display("[T9] 滑音：glide_time=64（t=256 ms），A4(440Hz) → A5(880Hz)");
        glide_on = 1'b1; glide_time = 7'd64;
        note_on(7'd69, 7'd100);             // 先起 A4
        wait_ticks(9766);                   // 稳定 0.1 s
        $display("[T9] 起音位图 active=%b，准备发第二个 note-on（应滑向 A5）", active);
        fork
            rec(fgl, 32768);                // 0.336 s > 0.256 s 滑音时长
            begin
                repeat (30) @(posedge clk);
                note_on(7'd81, 7'd100);
            end
        join
        $display("[T9] 滑音后 active=%b（滑音模式下新音符复用同一路声部）", active);
        note_off(7'd69); note_off(7'd81);
        glide_on = 1'b0; glide_time = 7'd0;
        wait_silent(40000);

        // ================= T10: 延音踏板 =================
        $display("");
        $display("[T10] 延音踏板：sustain=1 时 note-off 不应释放声部");
        sustain = 1'b1;
        note_on(7'd69, 7'd100);
        wait_ticks(9766);
        note_off(7'd69);                    // 踏板踩着：只记账
        meas_mav(2048, mav_early);
        $display("[T10] 踏板踩下 note-off 后：active=%b，平均电平=%0d（应仍 >0 且 active≠0）",
                 active, mav_early);
        if ((active === 8'd0) || (mav_early < 100)) begin
            $display("[T10] FAIL: 踏板踩下时 note-off 把声部放掉了");
            nfail = nfail + 1;
        end else begin
            $display("[T10] PASS: 踏板踩下时 note-off 后仍在发声");
        end
        rec(fsu, 8192);                     // 落一段"还响着"的证据
        sustain = 1'b0;                     // 抬踏板 ⇒ 一次性释放
        wait_ticks(9766);                   // 等 0.1 s（阻音器 τ≈21 ms ⇒ 早已落净）
        meas_mav(2048, mav_late);
        $display("[T10] 抬踏板后平均电平=%0d（应显著下降）", mav_late);
        if (mav_late * 3 < mav_early) begin
            $display("[T10] PASS: 抬踏板后声部被释放（%.1f dB）",
                     20.0 * $log10((mav_late + 0.5) / (mav_early + 0.5)));
        end else begin
            $display("[T10] FAIL: 抬踏板后没有释放");
            nfail = nfail + 1;
        end
        wait_silent(40000);
        $display("[T10] 释放后 active=%b", active);

        // ---------------- 汇总 ----------------
        $display("");
        $display("================================================================");
        $display("[TB] X（未定义）样本总数 = %0d （必须为 0）", xn);
        if (xn != 0) begin
            $display("[TB] FAIL: 输出里出现 X —— 典型原因是某个寄存器漏复位，");
            $display("[TB]       或位选越界（越界位按 x 读入）后进了数据通路");
            nfail = nfail + 1;
        end else begin
            $display("[TB] PASS: 全部样本都是确定值，无 X");
        end
        if (nfail == 0)
            $display("[TB] 全部自检项 PASS（频谱判据见 Python 分析脚本）");
        else
            $display("[TB] 有 %0d 项 FAIL", nfail);
        $display("[TB] 说明：基频/泛音比例/复音谱峰由 Python 对 out/piano_*.txt 做 FFT 判定");
        $display("================================================================");

        $fclose(fa); $fclose(fr); $fclose(fc);
        $fclose(fv1); $fclose(fv2); $fclose(fh); $fclose(fp);
        $fclose(fvi); $fclose(fnv); $fclose(fgl); $fclose(fsu);
        $stop;                       // ⚠️ 用 $stop 不用 $finish：$finish 会杀掉整个 vsim
    end

    // 仿真超时保护（全部用例约 2.5 s 仿真时间；给到 6 s 余量）
    // ⚠️ 延时必须写成实数：3_000_000_000 会被当成 32 位有符号整数而溢出
    initial begin
        #(6.0e9);
        $display("[TB] TIMEOUT");
        $stop;
    end

endmodule

`default_nettype wire
