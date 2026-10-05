// =============================================================================
//  tb_song_player.v —— song_player（演示模式播放器）功能验证
//
//  验证目标（逐条对应 task 的验收要求）：
//    1. 按按键1 开始播放，发出**按时间顺序正确**的 note-on 命令
//       —— 逐音比对 song 0 全部 29 个音符的 MIDI 号与力度
//       —— 并用"相邻 note-on 的 tick 间隔"反推每个音符槽长，
//          与 song_rom 里的 dur 对照（槽长必须严格等于 ROM 里的时值）
//    2. 曲末【单曲循环】回到第 1 个音符
//    3. 再按按键1 → 停止：playing 拉低 + 发 1 条逐音 off + 128 拍
//       all-notes-off 扫描（off_note = 0..127，与 midi_rx.v 的 CC123 语义一致），
//       且停止后**不再有任何 note-on**（不留挂音/不偷跑）
//    4. 再按按键1 → 从头重新播放（第 1 个音符）
//    5. 按键2 切歌：song_index 递增、新曲第 1 个音符正确、放完最后一首回到第一首
//    6. 停止状态下按键2 **无效**
//    7. 长按按键1 只切换一次 —— 证明是【边沿触发】不是电平触发
//
//  ===========================================================================
//  ★ 关于 sample_tick 周期（这是本 TB 唯一的"非生产"设置，必须说明白）
//  ===========================================================================
//  生产环境 sample_tick = 每 512 clk 一个（50 MHz / 512 = 97 656.25 Hz）。
//  本 TB 用 TICK_DIV = 2（每 2 clk 一个），因为它要跑完整首《欢乐颂》
//  （62 个音符 ≈ 3.6 M 个 tick）——按 512 clk/tick 就是 18 亿拍，仿真根本跑不完。
//
//  这**不会放过任何计数错误**，理由：
//    · sample_tick 的生成是 top.v / pt8211_tx 的职责，**不在 song_player 的契约内**；
//      song_player 只按"收到了几个 tick"计时。压缩 tick 周期只是等比压缩仿真时间。
//    · 本 TB 的所有时间断言都用 **tick 计数**（tick_cnt）而不是 clk 数，
//      槽长判据是"tick 间隔 == ROM 里的 dur"，与 tick 周期无关。
//    · 唯一受影响的量是"每音符固定 2 clk 的取数开销"折算成 tick 的比例：
//      生产是 2/512 tick（可忽略），本 TB 是 1 tick。因此 TB 断言的是
//      "间隔 - dur = 同一个常数"（证明槽长精确），而不是硬写某个绝对数。
//      实测该常数在汇总里打印出来（预期 1）。
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_song_player;

    // ------------------------------------------------------------------ 时钟 --
    reg clk = 1'b0;
    always #10 clk = ~clk;                    // 20 ns → 50 MHz

    localparam integer TICK_DIV = 2;          // 见文件头说明

    reg rst_n       = 1'b0;
    reg key_play    = 1'b0;
    reg key_next    = 1'b0;
    reg sample_tick = 1'b0;

    wire        on_valid;
    wire [6:0]  on_note, on_vel;
    wire        off_valid;
    wire [6:0]  off_note;
    wire        playing;
    wire [3:0]  song_index;
    wire [3:0]  song_count;

    // ------------------------------------------------------------- 被测设计 --
    song_player #(
        .CLK_HZ   (50_000_000),
        .GAP_TICKS(256)                       // 与生产默认值一致
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .sample_tick(sample_tick),
        .key_play   (key_play),
        .key_next   (key_next),
        .on_valid   (on_valid),
        .on_note    (on_note),
        .on_vel     (on_vel),
        .off_valid  (off_valid),
        .off_note   (off_note),
        .playing    (playing),
        .song_index (song_index),
        .song_count (song_count)
    );

    // ------------------------------------------------------- sample_tick 源 --
    integer tick_div_cnt = 0;
    integer tick_cnt     = 0;                 // TB 的时间单位：tick 个数
    always @(posedge clk) begin
        if (tick_div_cnt >= TICK_DIV - 1) begin
            tick_div_cnt <= 0;
            sample_tick  <= 1'b1;
            tick_cnt     <= tick_cnt + 1;
        end else begin
            tick_div_cnt <= tick_div_cnt + 1;
            sample_tick  <= 1'b0;
        end
    end

    // ------------------------------------------------------------ 期望值 -----
    // song 0 = 《Faded》(Alan Walker) **副歌第 1 次**，29 个音符。
    // ★ 数据来源：tools/gen/gen_song_rom.py --write 生成的 _research/songs/song_table.txt
    //   （即 song_rom.v 里 case 表的同一个真值来源；这里是**独立抄一份**当期望值，
    //     而不是反过来去读 DUT 用的 ROM —— 否则就是自己验证自己）
    // ★ 2026-10-05 更新：旋律整条换过 —— 旧数据误取了吉他分解和弦伴奏层
    //   （用户上板试听指出"Faded 旋律不对"，复核证实那一层 92% 都是和弦音）。
    //   音符数 47 → 29，首音 B4(71) → G5(79)，BPM 90 → 120。
    //
    // ⛔⚠️ 维护提醒（很容易漏）：本 TB 的期望值是**硬编码**的。若在
    //   `gen_song_rom.py` 的 SONGS 里**增删或调换曲目顺序**（例如按用户决定
    //   移除《Faded》），那么 song 0 就换人了，必须同步更新：
    //     ① 下面的 SONG_COUNT_EXP
    //     ② 整个 exp_midi / exp_dur 数组（29 → 新的音符数）
    //     ③ S1_FIRST..S4_FIRST 这几个"各曲首音"
    //     ④ 阶段 4 的切歌链（首数变了就要加减 press_next）
    //   否则 TB 会报一堆 FAIL —— 那是 TB 过期，不是 DUT 坏了。
    localparam [3:0] SONG_COUNT_EXP = 4'd5;   // 与 song_rom.v 的 n_songs 一致
    localparam integer S0_N = 29;
    reg [6:0]  exp_midi [0:S0_N-1];
    reg [19:0] exp_dur  [0:S0_N-1];

    // song 1..4 的第 1 个音符（切歌测试用）
    localparam [6:0] S1_FIRST = 7'd64;        // 欢乐颂：E4
    localparam [6:0] S2_FIRST = 7'd60;        // 小星星：C4
    localparam [6:0] S3_FIRST = 7'd64;        // 铃儿响叮当：E4
    localparam [6:0] S4_FIRST = 7'd76;        // 致爱丽丝：E5

    // ------------------------------------------------------------ 记分板 -----
    integer   err        = 0;
    integer   on_cnt     = 0;
    integer   off_cnt    = 0;
    integer   on_tick    [0:255];
    integer   on_time    [0:255];             // note-on 的绝对时刻（ns），算控制→发声延迟
    reg [6:0] on_seen    [0:255];
    integer   off_tick   [0:255];
    reg [6:0] off_seen   [0:255];

    integer   chk_notes  = 0;                 // 1 = 逐音比对 song 0 期望值
    integer   chk_delta  = 0;                 // 1 = 检查槽长 tick 间隔
    integer   delta_k    = -999;              // 实测常数：间隔 - ROM 时值
    integer   d, delta_cur;
    integer   press_time = 0;                 // 按键边沿的时刻（算控制→发声延迟）
    // all-notes-off 扫描的独立计数（声明必须在下面的 always 之前）
    integer   sweep_cnt  = 0;                 // 已完成的 0..127 扫描条数
    integer   sweep_next = 0;
    integer   in_sweep   = 0;

    always @(posedge clk) begin
        if (on_valid) begin
            if (on_cnt < 256) begin
                on_tick[on_cnt] = tick_cnt;
                on_time[on_cnt] = $time;
                on_seen[on_cnt] = on_note;
            end
            if (chk_notes && on_cnt < S0_N) begin
                if (on_note !== exp_midi[on_cnt]) begin
                    $display("[FAIL] t=%0t note#%0d 音符号错: got %0d want %0d",
                             $time, on_cnt, on_note, exp_midi[on_cnt]);
                    err = err + 1;
                end
                if (on_vel !== 7'd100) begin
                    $display("[FAIL] t=%0t note#%0d 力度错: got %0d want 100",
                             $time, on_cnt, on_vel);
                    err = err + 1;
                end
            end
            // 槽长检查：相邻 note-on 的 tick 间隔应 = 上一个音符的 ROM 时值 + 常数
            if (chk_delta && on_cnt >= 1 && on_cnt <= S0_N) begin
                d         = on_tick[on_cnt] - on_tick[on_cnt-1];
                delta_cur = d - exp_dur[on_cnt-1];
                if (delta_k == -999) delta_k = delta_cur;
                // ★ on_cnt == S0_N 是【曲末循环边界】，不是普通音符：
                //   此时 S_LATCH 看到 r_end，要先回 addr=0 再重新走一次
                //   S_LOAD→S_LATCH 取数，因此比普通音符多 2 clk = 1 个 tick。
                //   这是设计使然（每循环一遍只多约 10 µs），单独判定。
                if (on_cnt == S0_N) begin
                    if (delta_cur !== delta_k + 1) begin
                        $display("[FAIL] 曲末循环边界间隔异常: %0d (应=%0d)",
                                 delta_cur, delta_k + 1);
                        err = err + 1;
                    end else begin
                        $display("[info] 曲末循环边界额外开销 = 1 tick (2 clk)，符合预期");
                    end
                end else if (delta_cur !== delta_k) begin
                    $display("[FAIL] t=%0t 槽长%0d: 间隔=%0d ROM时值=%0d 偏差=%0d (常数应为%0d)",
                             $time, on_cnt-1, d, exp_dur[on_cnt-1], delta_cur, delta_k);
                    err = err + 1;
                end
                if (delta_cur < 0 || delta_cur > 4) begin
                    $display("[FAIL] t=%0t 槽长%0d: 偏差 %0d tick 过大（取数开销异常）",
                             $time, on_cnt-1, delta_cur);
                    err = err + 1;
                end
            end
            on_cnt = on_cnt + 1;
        end

        if (off_valid) begin
            if (off_cnt < 256) begin
                off_tick[off_cnt] = tick_cnt;
                off_seen[off_cnt] = off_note;
            end
            $display("[info] t=%0t tick=%0d OFF note=%0d", $time, tick_cnt, off_note);
            off_cnt = off_cnt + 1;

            // ★ all-notes-off 扫描的独立判定：数"完整的 off_note = 0,1,…,127 序列"
            //   有几条。这比只看 off 总数可靠 —— 总数会被音符断句 off 混进来。
            //   本曲库音域最低 62，断句 off 不可能是 0，所以 off_note==0 必然是扫描起点。
            if (in_sweep) begin
                if (off_note === sweep_next[6:0]) begin
                    if (off_note === 7'd127) begin
                        sweep_cnt  = sweep_cnt + 1;
                        in_sweep   = 0;
                        sweep_next = 0;
                    end else begin
                        sweep_next = sweep_next + 1;
                    end
                end else begin
                    $display("[FAIL] t=%0t all-notes-off 扫描不连续: 期望 %0d 实得 %0d",
                             $time, sweep_next, off_note);
                    err     = err + 1;
                    in_sweep = 0;
                end
            end else if (off_note === 7'd0) begin
                in_sweep   = 1;
                sweep_next = 1;
            end
        end
    end

    // --------------------------------------------------------------- 任务 ----
    task press_play; begin
        press_time = $time;                   // 记下按键时刻（算控制→发声延迟）
        key_play = 1'b1;
        @(posedge clk);                       // 该边沿被 DUT 采到（边沿检测生效）
        key_play = 1'b0;
        @(posedge clk);
    end endtask

    task press_next; begin
        key_next = 1'b1;
        @(posedge clk);
        key_next = 1'b0;
        @(posedge clk);
    end endtask

    task chk;
        input [8*200:1] name;                 // 放宽：中文消息按 UTF-8 是 3 字节/字
        input           cond;
        begin
            if (cond) $display("[PASS] %0s", name);
            else begin
                $display("[FAIL] %0s  (t=%0t)", name, $time);
                err = err + 1;
            end
        end
    endtask

    // ------------------------------------------------------------- 变量 ----
    integer i, j, k;
    integer lat_ns;
    reg     sweep_ok;

    // ------------------------------------------------------------- 主体 ----
    initial begin

        // ---- song 0 期望值（29 个音符：MIDI 号 / 槽长 tick）----
        // ⚠️ 由 gen_song_rom.py 的 song_table.txt 机械生成，不要手改
        exp_midi[ 0]=7'd 79; exp_dur[ 0]=20'd 48828; exp_midi[ 1]=7'd 83; exp_dur[ 1]=20'd 48828; exp_midi[ 2]=7'd 86; exp_dur[ 2]=20'd146484;
        exp_midi[ 3]=7'd 88; exp_dur[ 3]=20'd 48828; exp_midi[ 4]=7'd 86; exp_dur[ 4]=20'd 48828; exp_midi[ 5]=7'd 83; exp_dur[ 5]=20'd 48828;
        exp_midi[ 6]=7'd 81; exp_dur[ 6]=20'd 48828; exp_midi[ 7]=7'd 79; exp_dur[ 7]=20'd 48828; exp_midi[ 8]=7'd 76; exp_dur[ 8]=20'd 97656;
        exp_midi[ 9]=7'd 76; exp_dur[ 9]=20'd 48828; exp_midi[10]=7'd 78; exp_dur[10]=20'd 48828; exp_midi[11]=7'd 79; exp_dur[11]=20'd146484;
        exp_midi[12]=7'd 83; exp_dur[12]=20'd 48828; exp_midi[13]=7'd 86; exp_dur[13]=20'd146484; exp_midi[14]=7'd 88; exp_dur[14]=20'd 48828;
        exp_midi[15]=7'd 86; exp_dur[15]=20'd 48828; exp_midi[16]=7'd 83; exp_dur[16]=20'd 48828; exp_midi[17]=7'd 81; exp_dur[17]=20'd 48828;
        exp_midi[18]=7'd 79; exp_dur[18]=20'd 48828; exp_midi[19]=7'd 81; exp_dur[19]=20'd292969; exp_midi[20]=7'd 79; exp_dur[20]=20'd 48828;
        exp_midi[21]=7'd 83; exp_dur[21]=20'd 48828; exp_midi[22]=7'd 86; exp_dur[22]=20'd146484; exp_midi[23]=7'd 88; exp_dur[23]=20'd 48828;
        exp_midi[24]=7'd 86; exp_dur[24]=20'd 48828; exp_midi[25]=7'd 83; exp_dur[25]=20'd 48828; exp_midi[26]=7'd 81; exp_dur[26]=20'd 48828;
        exp_midi[27]=7'd 79; exp_dur[27]=20'd 48828; exp_midi[28]=7'd 76; exp_dur[28]=20'd 95011;

        $display("");
        $display("=========================================================");
        $display(" tb_song_player : song_player 演示模式播放器功能验证");
        $display(" 采样率 tick = 1/%0d clk (生产为 1/512)；时间断言以 tick 为单位", TICK_DIV);
        $display("=========================================================");

        key_play = 1'b0;  key_next = 1'b0;  rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);

        // ---------------------------------------------------- 阶段 0: 复位态 --
        chk("复位后 playing==0",        playing    === 1'b0);
        chk("复位后 song_index==0",     song_index === 4'd0);
        chk("复位后 song_count==5",     song_count === SONG_COUNT_EXP);
        chk("复位后没有 note-on",       on_cnt == 0);
        chk("复位后没有 off",           off_cnt == 0);

        // ========================= 阶段 1: 播放 + 逐音比对 =================
        $display("\n--- 阶段 1: 按键1 按下 → 从头播放，逐音比对 29 个音符 ---");
        chk_notes = 1;
        chk_delta = 1;
        press_play();
        chk("按 key_play 后 playing==1", playing === 1'b1);
        wait (on_cnt >= 1);
        chk("按 key_play 后第 1 个音符 = G5(79)（《Faded》副歌首音）",
            on_seen[0] === exp_midi[0]);
        // ★ 控制→发声延迟：本模块自身的贡献。
        //   ⚠️ 这不含顶层去抖窗口（2.621 ms，属 top.v）；本模块只负责
        //   "边沿 → note-on"，设计上是 3 拍。赛题要求总延迟 ≤10 ms，
        //   去抖 2.621 ms + 本模块 ~0.06 µs 远在预算内。
        lat_ns = on_time[0] - press_time;
        $display("[info] 控制→发声(本模块贡献) = %0d ns；设计值 3 clk = 60 ns", lat_ns);
        $display("       （实测值含 TB 记录按键时刻的相位偏移 0..20 ns，不是抖动）");
        chk("本模块控制→发声延迟 < 10 ms（赛题硬指标，含顶层去抖后仍满足）",
            lat_ns >= 0 && lat_ns < 10_000_000);

        // 等到 29 个音符全部走完，再多看 3 个（证明单曲循环）
        wait (on_cnt >= S0_N + 3);
        chk_notes = 0;
        chk_delta = 0;
        chk("song 0 的 29 个音符全部发出", on_cnt >= S0_N);
        chk("曲末循环回第 1 个音符 (G5=79)", on_seen[S0_N]     === exp_midi[0]);
        chk("曲末循环回第 2 个音符 (B5=83)", on_seen[S0_N + 1] === exp_midi[1]);
        chk("曲末循环回第 3 个音符 (D6=86)", on_seen[S0_N + 2] === exp_midi[2]);
        $display("[info] 槽长常数 K = 间隔 - ROM时值 = %0d tick (生产环境该常数为 2/512 tick)", delta_k);
        chk("槽长常数在合理范围 0..4", (delta_k >= 0) && (delta_k <= 4));

        // ================ 阶段 2: 再按按键1 → 停止 + all-notes-off =========
        $display("\n--- 阶段 2: 再按按键1 → 停止，必须发 all-notes-off 且不再偷跑 ---");
        i = on_cnt;
        j = off_cnt;
        repeat (10) @(posedge clk);           // 确保此刻处在音符槽内（has_active=1）
        press_play();
        chk("再按 key_play 后 playing==0", playing === 1'b0);
        repeat (300) @(posedge clk);          // 1 拍逐音 off + 128 拍扫描 + 余量
        chk("停止时发 1 条逐音 off + 128 拍 all-notes-off 扫描（共 129）",
            off_cnt == j + 129);
        if (off_cnt >= j + 129) begin
            chk("off#1 是逐音 off（合法音符号，不是休止符标记）", off_seen[j] <= 7'd127);
            // 扫描段必须严格是 0,1,…,127 —— 与 midi_rx.v 解析 CC123 的语义一致，
            // 下游 top.v 才能只实现一套"全关"逻辑。
            sweep_ok = 1'b1;
            for (k = 0; k < 128; k = k + 1)
                if (off_seen[j + 1 + k] !== k[6:0]) sweep_ok = 1'b0;
            chk("off#2..129 是 off_note = 0..127 的连续扫描", sweep_ok);
        end
        repeat (4000) @(posedge clk);         // 约 2000 tick：若仍在计数会立刻冒出新 note-on
        chk("停止后不再发 note-on（无偷跑）", on_cnt == i);

        // ================= 阶段 3: 再按按键1 → 从头重新播放 ================
        $display("\n--- 阶段 3: 再按按键1 → 从头重新播放 ---");
        i = on_cnt;
        press_play();
        chk("重新按 key_play 后 playing==1", playing === 1'b1);
        wait (on_cnt >= i + 1);
        chk("重新播放从第 1 个音符开始 (G5=79)", on_seen[i] === exp_midi[0]);

        // ==================== 阶段 4: 按键2 切歌（含循环） =================
        $display("\n--- 阶段 4: 按键2 切歌 0→1→2→3→4→0 ---");
        i = on_cnt;
        press_next();
        repeat (4) @(posedge clk);
        chk("切歌后 song_index==1", song_index === 4'd1);
        wait (on_cnt >= i + 1);
        chk("song1 第 1 个音符 = E4(64)", on_seen[i] === S1_FIRST);

        press_next();
        repeat (4) @(posedge clk);
        chk("切歌后 song_index==2", song_index === 4'd2);
        wait (on_cnt >= i + 2);
        chk("song2 第 1 个音符 = C4(60)", on_seen[i+1] === S2_FIRST);

        press_next();
        repeat (4) @(posedge clk);
        chk("切歌后 song_index==3", song_index === 4'd3);
        wait (on_cnt >= i + 3);
        chk("song3 第 1 个音符 = E4(64)", on_seen[i+2] === S3_FIRST);

        press_next();
        repeat (4) @(posedge clk);
        chk("切歌后 song_index==4", song_index === 4'd4);
        wait (on_cnt >= i + 4);
        chk("song4 第 1 个音符 = E5(76)", on_seen[i+3] === S4_FIRST);

        press_next();
        repeat (4) @(posedge clk);
        chk("放完最后一首回到第一首 song_index==0", song_index === 4'd0);
        wait (on_cnt >= i + 5);
        chk("回到 song0 第 1 个音符 = G5(79)", on_seen[i+4] === exp_midi[0]);

        // ============== 阶段 5: 停止状态下按键2 必须无效 ==================
        $display("\n--- 阶段 5: 停止状态下按键2 无效 ---");
        press_play();
        repeat (200) @(posedge clk);          // 等停止流程（1+128 拍）走完回到 S_IDLE
        chk("已停止 playing==0", playing === 1'b0);
        i = song_index;
        j = on_cnt;
        press_next();
        repeat (10) @(posedge clk);
        chk("停止时按 key_next 不改 song_index", song_index === i);
        chk("停止时按 key_next 不产生 note-on", on_cnt == j);

        // =========== 阶段 6: 长按按键1 只切换一次（边沿触发） ==============
        $display("\n--- 阶段 6: 长按按键1 只切换一次（证明是边沿触发）---");
        j = on_cnt;
        key_play = 1'b1;
        repeat (20000) @(posedge clk);        // 长按 400 us（生产去抖窗口 2.621 ms 的等效比例）
        chk("长按期间 playing 保持 1（没有被反复翻转）", playing === 1'b1);
        chk("长按只开始了一次（note-on 只多 1 个）", on_cnt == j + 1);
        key_play = 1'b0;
        repeat (20) @(posedge clk);
        press_play();
        repeat (10) @(posedge clk);
        chk("松开后再按一下 → 停止（边沿触发）", playing === 1'b0);
        repeat (300) @(posedge clk);          // ★ 等最后一条 all-notes-off 扫描跑完
        repeat (200) @(posedge clk);

        // ============== 阶段 7: all-notes-off 扫描计数 ====================
        // 全测试共 3 次停止（阶段 2 / 5 / 6），每次必须恰好一条完整的
        // off_note = 0..127 扫描。用独立计数器判定，而不是看 off 总数
        // （总数里混着音符断句 off，无法区分）。
        $display("\n--- 阶段 7: all-notes-off 扫描计数 ---");
        chk("3 次停止 → 恰好 3 条完整的 off_note=0..127 扫描", sweep_cnt == 3);
        $display("[info] 完整 all-notes-off 扫描 = %0d 条（每条 128 拍）", sweep_cnt);
        $display("[info] off 事件总数 = %0d（= %0d 条扫描×128 + %0d 条音符断句 off）",
                 off_cnt, sweep_cnt, off_cnt - sweep_cnt * 128);

        // ==================== 阶段 8: 播放中复位 ==========================
        // 目的：把"复位时会发生什么"也钉死，不留没验证的注释。
        // ★ 结论会是一条【集成时必须知道】的事实：复位**不**补发 all-notes-off
        //   （复位是全局的，下游引擎同时复位，所以是安全的）；
        //   但若 top.v 用"多路选择"在演示/演奏模式间切换而**不复位**，
        //   切走时就会留下挂音 —— 那时必须由 top.v 自己发全关。
        $display("\n--- 阶段 8: 播放中复位 → 状态清干净（且确认不补发 all-off）---");
        i = on_cnt;
        press_play();
        wait (on_cnt >= i + 1);
        repeat (200) @(posedge clk);          // 停在音符槽内（has_active=1）
        chk("复位前 playing==1", playing === 1'b1);
        j = off_cnt;
        rst_n = 1'b0;
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (20) @(posedge clk);
        chk("复位后 playing==0",  playing    === 1'b0);
        chk("复位后 song_index==0", song_index === 4'd0);
        chk("复位后没有新的 note-on", on_cnt == i + 1);
        chk("复位不补发 all-notes-off（设计如此，见上方说明）", off_cnt == j);
        // 复位后必须还能正常用
        press_play();
        wait (on_cnt >= i + 2);
        chk("复位后仍能播放（从第 1 个音符开始）", on_seen[i+1] === exp_midi[0]);
        press_play();
        repeat (400) @(posedge clk);          // 停止 + 扫描跑完

        // ========= 阶段 9: 停止后 129 clk 死窗口内再按被忽略 ==============
        // 这条把 song_player.v 末尾注释里声明的"死窗口"变成**验证过的事实**，
        // 而不是一句没人测过的断言。
        $display("\n--- 阶段 9: 停止后 129 clk 内再按 key_play 被忽略 ---");
        i = on_cnt;
        key_play = 1'b1; @(posedge clk); key_play = 1'b0; @(posedge clk);  // 开始
        wait (on_cnt >= i + 1);
        // 停止（按下 1 拍），随后 ~2 拍立刻再按一次 —— 落在 S_OFF/S_ALLOFF 内
        key_play = 1'b1; @(posedge clk); key_play = 1'b0; @(posedge clk);
        chk("停止已生效", playing === 1'b0);
        key_play = 1'b1; @(posedge clk); key_play = 1'b0;
        repeat (30) @(posedge clk);           // 仍在 129 clk 窗口内
        chk("窗口内再按 key_play 被忽略（playing 仍为 0）", playing === 1'b0);
        chk("窗口内再按不产生 note-on", on_cnt == i + 1);
        repeat (300) @(posedge clk);          // 等窗口结束
        press_play();
        wait (on_cnt >= i + 2);
        chk("窗口结束后再按 key_play 正常播放", on_seen[i+1] === exp_midi[0]);
        press_play();
        repeat (400) @(posedge clk);

        // 全测试累计的停止次数 = 阶段 2 / 5 / 6 / 8 / 9(两次) = 6 次，
        // 每次一条完整扫描 ⇒ 必须恰好 6 条。
        chk("累计 6 次停止 → 恰好 6 条完整的 off_note=0..127 扫描", sweep_cnt == 6);

        // ============================ 汇总 ===============================
        $display("");
        $display("=========================================================");
        if (err == 0) $display("=== tb_song_player: PASS (0 个错误) ===");
        else          $display("=== tb_song_player: FAIL (%0d 个错误) ===", err);
        $display("  note-on 事件 %0d 次；off 事件 %0d 次（含 %0d 条 all-notes-off 扫描）",
                 on_cnt, off_cnt, sweep_cnt);
        $display("  槽长常数 K = %0d tick", delta_k);
        $display("  控制→发声(本模块贡献) = %0d ns；顶层去抖另计 2.621 ms", lat_ns);
        $display("=========================================================");
        $stop;
    end

    // ------------------------------------------------------------ 看门狗 ----
    // 万一状态机卡死（wait 永不满足），不能让 run -all 无限跑下去。
    initial begin
        #800_000_000;                          // 800 ms 仿真时间上限
        $display("[FAIL] 仿真超时（看门狗 800 ms）—— 状态机可能卡死");
        $display("=== tb_song_player: FAIL (timeout) ===");
        $finish;
    end

endmodule

`default_nettype wire
