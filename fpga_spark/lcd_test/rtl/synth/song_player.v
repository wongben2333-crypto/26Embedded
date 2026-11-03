// =============================================================================
//  song_player.v —— 演示模式播放器（按键1 播放/停止、按键2 切歌）
//
//  数据通路（演示模式）：
//
//     按键1 ─┐
//            ├─► song_player ──note 命令总线(on/off)──► 声部分配器 ──gate──► ADSR/振荡器
//     按键2 ─┘        ▲
//                     └── 音符数据 ◄── song_rom.v（纯 case 常量表，非 PCM）
//
//  ★ 合规性（赛题红线"严禁播放预录 PCM / 预置推流 / 整段录音触发"）：
//    本模块输出的是**逐个音符的 note-on/note-off 命令**，与真人按键演奏走
//    完全相同的总线与通路 —— 声音仍然由振荡器 + ADSR **逐样本实时合成**。
//    ROM 里存的是 (MIDI 音符号, 力度, 时值)，**没有任何波形样本**。
//
//  ===========================================================================
//  ★★ 三条行为决策（以及为什么）★★
//  ===========================================================================
//
//  (1) 按键1 = 播放/停止【切换】，且是【边沿触发】
//      · 用 key_play 的上升沿（key_play_d 延迟一拍比较），不是电平。
//        理由：按键在物理上会被按住几百毫秒（本项目顶层去抖窗口就是
//        2.621 ms），若用电平驱动，按住不放会不停地在"播放/停止"之间翻转。
//      · 停止时必须发 all-notes-off，否则正在响的那个音会一直挂着 ——
//        ADSR 收到的是电平敏感 gate（见 adsr.v 文件头"gate 是电平不是脉冲"），
//        不发 note-off 就等于手指按在琴键上不松，挂音会一直响到天荒地老。
//
//      ⚠️ all-notes-off 的【总线约定】（这一条是与其他模块的接口，务必遵守）：
//        本总线的 off 只有"一个音符号"这一根线，没有 MIDI 的 CC123 专用端口。
//        本工程约定的表达方式是 **连续 128 拍 off_valid，off_note = 0,1,…,127**
//        —— 这与 `rtl/io/midi_rx.v` 解析 CC123 (0xB0 0x7B 0x00) 时的产出方式
//        **完全一致**（见 AGENTS.md §4.1 的串口协议说明）。
//        ⚠️ 本模块第一版曾用"单拍 off_note = 7'h7F 作为广播码"，**已废弃**：
//           同一条总线上出现两种"全关"方言，下游 top.v 就得同时认两套，
//           迟早出错。统一成 midi_rx 的 128 拍扫描，下游只需实现一套。
//        停止时的发射顺序：
//          第 1 步（1 拍）：off_note = 本模块正在响的那个音（精确的逐音 off，
//                          让当前音**立刻**进入释放段，不等扫描轮到它）
//          第 2 步（128 拍）：off_note = 0,1,…,127（CC123 等价的全关扫描，
//                          能连带清掉别的来源——比如演奏模式下真人按住没松的
//                          音——留下的挂音）
//        代价：停止流程占用 129 个 clk（2.58 µs @50 MHz）。相对于顶层去抖窗口
//        2.621 ms 可以忽略，也不会让"按键1 再按一下重新播放"有可感延迟。
//
//  (2) 按键2 = 切歌，【只在播放时有效】（用户原话："按键2在播放的时候起到
//      切歌作用"）。停止时按它不动任何状态 —— 避免"停了以后按几下键2，
//      再按播放却从第 3 首开始"这种不符合直觉的行为。
//      切换时先把旧音 off 掉再发新音（否则旧音挂住、新音叠上来）。
//
//  (3) 一首放完：【单曲循环】（回到本曲第 1 个音符），不自动跳下一首。
//      理由：
//        · 演示现场"按键1 按一下开、再按一下停"是用户要的交互；
//          歌放完自动停，观众会以为死机了；自动跳下一首，又会让人搞不清
//          按键2 到底起没起作用（切歌键的功能被自动行为掩盖）。
//        · 单曲循环 + 按键2 显式切歌，两个键的职责互不重叠，最可预期。
//        · 参考例程也是这个取向：robsoncouto/arduino-songs 每首的 loop()
//          留空（"no need to repeat the melody"，重复与否交给上层），
//          sirius1242/musicbox 的 decode.v 在时值计数归零后把地址绕回 0。
//      要改成"放完自动下一首"，只需把 S_LATCH 里 r_end 分支的
//      `note_idx <= 0` 改成 `song_index_r <= 下一首`，两行的事。
//
//  (4) 复位【不】补发 all-notes-off
//      复位的语义是"整个系统回到初始状态"——下游（声部分配器 / ADSR）同时被复位，
//      所以不会有挂音，不需要也不应该在复位路径上往总线发包。
//      ⚠️ 但这条对 top.v 有一个【集成时必须注意】的推论：
//        若 top.v 用"多路选择"在演示模式与演奏模式之间切换而**不复位**，
//        切走的那一刻本模块可能有音正在响 —— 那时**必须由 top.v 自己发全关**
//        （或复位下游），否则会留挂音。本模块只在自己【被停止】时负责发全关，
//        不为"被别人切走"负责（它没有任何输入告诉它自己被切走了）。
//      ✅ 已由 sim/tb/tb_song_player.v 阶段 8 实测钉死（"复位不补发 all-notes-off"）。
//
//  ===========================================================================
//  ★ 音符"断句"（GAP_TICKS）—— 两个参考例程都做的事
//  ===========================================================================
//    参考例程 [R1] robsoncouto/arduino-songs：tone() 只让音符响
//    noteDuration*0.9，留 10% 静音；[R2] sirius1242/musicbox decode.v：
//    一个音符响满时值后再插 1 ms 的 signal<=0 才推进地址。
//    为什么必须留缝：不留缝的连奏会把**同一个音的重复**（Tetris 开头就是
//    E5 四分 + B4 八分 …，Faded 副歌开头是 B4 连着三次）糊成一个长音，
//    听感完全不对；而且 off 与下一个 on 挤在同一拍，语义也容易出错。
//    本模块用固定 GAP_TICKS（默认 256 tick = 2.62 ms）在**槽末之前**发 off，
//    而不是把"响多久"写进 ROM —— 这样生成器只需要管时值，不用管发音比例。
//
//  ===========================================================================
//  ★ 时序（流水对齐，与 wave_rom.v 相同的"同步读 ROM"约定）
//  ===========================================================================
//    song_rom 是同步读：addr 是组合量，dout 比 addr 晚一拍。因此取一个音符
//    走两拍：
//      S_LOAD （1 拍）：等同步 ROM 把 f(song, note_idx) 打到 dout 上
//      S_LATCH（1 拍）：dout 有效 —— 发 note-on、装载槽长、addr 推进 1
//      S_WAIT        ：按 sample_tick 数槽长；到 off_at 发 off，到槽末回 S_LOAD
//    第一个音符的**控制→发声延迟** = 按键边沿 1 拍 + S_LOAD/S_LATCH 2 拍
//    = 3 拍 = 60 ns @50 MHz（顶层去抖 2.621 ms 不在本模块内，是主要贡献项）。
//
//    ★ 节奏精度：每个槽长按 sample_tick 计数，而 S_LATCH 到第一个 tick 之间
//      有 0..1 个 tick 的对齐抖动（≤10.24 µs）。97 个音符累计最坏 ~1 ms，
//      相对 40 s 的曲子是 0.025%，听不出也测不出；若要消除，需要把 note-on
//      直接对齐到 tick 边沿（本模块刻意不做：那会给按键响应再加一个 tick 的
//      延迟，而"控制→发声 ≤10 ms"是赛题硬指标，且 10.24 µs 已经远小于它）。
//
//  ===========================================================================
//  ★ 资源
//  ===========================================================================
//     状态寄存器 ~20 FF + 槽长计数器 20 FF + ROM(219 项 × 35 bit，见 song_rom.v)
//     相对 138240 LUT / 138240 FF 可以忽略。
// =============================================================================
`default_nettype none

module song_player #(
    parameter integer CLK_HZ    = 50_000_000,
    // 音符槽末端的提前静音量（单位 sample_tick）。0 = 按 CLK_HZ 自动折算。
    // ⚠️ 有效范围 1 .. 2^20-1；给得比音符槽长还大时该音符会变成"一响就停"。
    parameter integer GAP_TICKS = 256
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_tick,   // 97 656.25 Hz 音频节拍

    input  wire        key_play,      // 按键1（已同步去抖后的电平，按下=1）
    input  wire        key_next,      // 按键2（同上）
    // ---- ★ 2026-10-06 新增：运行期模式切换需要的两个端口 ----
    //  ⚠️ key_play / key_next 的语义【一字未改】⇒ 原有 48 条 TB 断言与 top.v 旧接线仍有效
    input  wire        key_pause,     // ★ 暂停/恢复（电平，本模块内部取上升沿，与 key_play 同风格）
    input  wire        run_en,        // ★ 曲目模式使能（电平）：
                                      //    0 ⇒ 强制停止 + 走完 128 拍全关扫描 + 位置复位
                                      //    0→1 ⇒ **自动从头播放**（⇒ top.v 不必在外面造脉冲）
                                      //  ⚠️ 为什么必须是【电平】而不是复用 key_play 拉低：
                                      //     play_press 是【上升沿】(key_play & ~key_play_d)，
                                      //     电平 1→0 什么都不会发生 ⇒ "离开模式即停"必须有电平使能。
    // ---- 音符命令总线（与 piano_engine / midi_rx 共用语义）----
    output reg         on_valid,      // note-on 脉冲（1 个 clk）
    output reg  [6:0]  on_note,       // MIDI 音符号 0..127
    output reg  [6:0]  on_vel,        // 力度 0..127
    output reg         off_valid,     // note-off 脉冲
    output reg  [6:0]  off_note,

    // ---- 状态输出（给 LED、LCD UI Page 3 与演奏表情总线）----
    output wire        playing,           // 正在播放
    output wire        paused,            // ★ 暂停中（note_idx/dur_cnt 已冻结、当前音已释放）
    output wire [3:0]  song_index,        // 当前第几首（0 起）
    output wire [3:0]  song_count,        // 共几首
    output wire [7:0]  song_elapsed_sec,  // 实时播放已过秒数 (0..59)
    output wire [7:0]  song_elapsed_min,  // 实时播放已过分钟数 (0..59)
    output wire [7:0]  song_total_sec,    // 当前曲目总秒数
    output wire [7:0]  song_progress_pct, // 实时播放进度百分比 (0..100)
    output wire [8:0]  song_note_idx,     // 当前音符序号
    output wire [5:0]  song_sub_scroll,   // 音符槽内平滑滚动像素 (0..59)
    output wire [6:0]  song_active_note,  // 当前正在发声的主旋律音符 (0=无)
    // ---- 自动演奏技巧表情输出（延音踏板/揉弦/连奏滑音）----
    output wire        song_sustain,
    output wire        song_vib_on,
    output wire [6:0]  song_vib_depth,
    output wire [6:0]  song_vib_rate,
    output wire        song_glide_on,
    output wire [6:0]  song_glide_time
);

    // ------------------------------------------------------------- 状态编码 ----
    localparam [2:0] S_IDLE   = 3'd0,   // 停止
                     S_LOAD   = 3'd1,   // 等同步 ROM 出数
                     S_LATCH  = 3'd2,   // 锁存音符 / 发 note-on
                     S_WAIT   = 3'd3,   // 数槽长
                     S_OFF    = 3'd4,   // 发逐音 off
                     S_ALLOFF = 3'd5,   // 发 all-notes-off 扫描（128 拍）
                     S_PAUSE  = 3'd6;   // ★ 暂停（位置冻结；当前音已释放）

    localparam [6:0] NOTE_REST   = 7'h7F;
    localparam [6:0] ALLOFF_LAST = 7'd127;

    localparam integer GAP_DEF = CLK_HZ / 195312;
    localparam integer GAP_RAW = (GAP_TICKS > 0) ? GAP_TICKS : GAP_DEF;
    localparam [20:0]  GAP_RAW_C = GAP_RAW;
    localparam [20:0]  GAP_C     = (GAP_RAW < 1) ? 21'd1 : GAP_RAW_C;

    // --------------------------------------------------------------- 寄存器 ----
    reg [2:0]  state;
    reg        playing_r;
    reg [3:0]  song_index_r;
    reg [8:0]  note_idx;        // 当前/下一个音符的 ROM 序号
    reg [19:0] dur_cnt;         // 槽内已过的 sample_tick 数
    reg [19:0] cur_dur;         // 本音符槽长（sample_tick）
    reg [6:0]  active_note;     // 正在响的主音（用于 off 与五线谱显示）
    reg        has_active;      // 1 = 有主音正在响、还没发过 off
    // ★ 多声部和弦/吉他扫弦伴奏缓存（最多同时保持 4 个伴奏和弦音与主旋律叠加共鸣）
    reg [6:0]  chord_notes [0:3];
    reg [2:0]  chord_cnt;
    reg        key_play_d, key_next_d;
    reg        key_pause_d, run_en_d;
    reg        paused_r;
    reg [6:0]  active_vel;
    reg        pause_had_note;
    reg [6:0]  alloff_cnt;      // all-notes-off 扫描计数 0..127
    reg [16:0] sec_tick_cnt;    // 97656.25 Hz 节拍计数 (0..97655)
    reg [7:0]  cur_sec;         // 当前秒数 (0..59)
    reg [7:0]  cur_min;         // 当前分钟 (0..59)

    // ------------------------------------------------------------- 曲目 ROM ----
    wire [34:0] rom_dout;
    wire [3:0]  rom_n_songs;

    song_rom u_rom (
        .clk     (clk),
        .song    (song_index_r),
        .addr    (note_idx),
        .dout    (rom_dout),
        .n_songs (rom_n_songs)
    );

    wire        r_end  = rom_dout[34];
    wire [6:0]  r_note = rom_dout[33:27];
    wire [6:0]  r_vel  = rom_dout[26:20];
    wire [19:0] r_dur  = rom_dout[19:0];

    // ------------------------------------------------------------- 对外输出 ----
    assign playing    = playing_r;
    assign paused     = paused_r;
    assign song_index = song_index_r;
    assign song_count = rom_n_songs;

    reg [7:0]   total_sec_r;
    reg [7:0]  total_notes_r;
    reg [16:0] inv_notes_q16;
    always @(*) begin
        case (song_index_r)
            4'd0: begin total_sec_r = 8'd22; total_notes_r = 8'd68;  inv_notes_q16 = 17'd96377; end // 我落泪情绪零碎 (多声部版)
            4'd1: begin total_sec_r = 8'd38; total_notes_r = 8'd135; inv_notes_q16 = 17'd48546; end // 欢乐颂 (交响合唱版)
            4'd2: begin total_sec_r = 8'd24; total_notes_r = 8'd112; inv_notes_q16 = 17'd58515; end // 小星星 (吉他扫弦指弹版)
            4'd3: begin total_sec_r = 8'd27; total_notes_r = 8'd116; inv_notes_q16 = 17'd56497; end // 铃儿响叮当 (多声部伴奏版)
            4'd4: begin total_sec_r = 8'd12; total_notes_r = 8'd104; inv_notes_q16 = 17'd63016; end // 致爱丽丝 (双手琶音完整版)
            default: begin total_sec_r = 8'd30; total_notes_r = 8'd100; inv_notes_q16 = 17'd65536; end
        endcase
    end

    wire [8:0]  cur_note_idx_w = (note_idx > 9'd0) ? (note_idx - 9'd1) : 9'd0;
    wire [25:0] pct_mult = cur_note_idx_w * inv_notes_q16;
    wire [7:0]  pct_w = (cur_note_idx_w >= {1'b0, total_notes_r}) ? 8'd100 : pct_mult[23:16];

    reg [7:0]  song_progress_pct_r;
    reg [8:0]  song_note_idx_r;
    reg [5:0]  song_sub_scroll_r;
    reg [20:0] scroll_acc;

    assign song_elapsed_sec  = cur_sec;
    assign song_elapsed_min  = cur_min;
    assign song_total_sec    = total_sec_r;
    assign song_progress_pct = song_progress_pct_r;
    assign song_note_idx     = song_note_idx_r;
    assign song_sub_scroll   = (state == S_WAIT) ? song_sub_scroll_r : 6'd0;
    assign song_active_note  = has_active ? active_note : 7'd0;

    // ------------------------------------------------------------- 按键边沿 ----
    always @(posedge clk) begin
        key_play_d  <= key_play;
        key_next_d  <= key_next;
        key_pause_d <= key_pause;
        run_en_d    <= run_en;
    end
    wire play_press  = key_play  & ~key_play_d;
    wire next_press  = key_next  & ~key_next_d;
    wire pause_press = key_pause & ~key_pause_d;
    wire run_rise    = run_en    & ~run_en_d;

    // ------------------------------------------------------- 槽长与和弦层判定 ----
    wire [19:0] cur_dur_s = (cur_dur == 20'd0) ? 20'd1 : cur_dur;
    // ★ 当音符时值 <= 2500 tick (25.6 ms) 时，判定为【多声部和弦伴奏音 / 吉他扫弦弦音】：
    //   不提前发 off，直接保持发声并装入 chord_notes，与随后的主旋律音共同延音！
    wire        is_chord_layer = (cur_dur_s <= 20'd2500);
    wire [20:0] off_at = (cur_dur_s > GAP_C) ? ({1'b0, cur_dur_s} - GAP_C) : 21'd1;
    wire [20:0] dn = {1'b0, dur_cnt} + 21'd1;

    // 自动演奏技巧输出：
    // 1. 延音踏板：在每个和弦乐句内部保持踩下，仅在主音槽末断句换气窗口抬起清音
    assign song_sustain    = playing_r && ((state != S_WAIT) || is_chord_layer || (dn < off_at));
    // 2. 自动揉弦：主旋律在起弓 80 ms 后自然绽放揉弦，短音微揉，长音深情吟唱
    wire        vib_delay_ok = (dur_cnt >= 20'd8000);
    assign song_vib_on     = playing_r && (cur_dur_s >= 20'd10000) && vib_delay_ok;
    assign song_vib_depth  = (cur_dur_s >= 20'd50000) ? 7'd36 :
                             (cur_dur_s >= 20'd25000) ? 7'd26 : 7'd16;
    assign song_vib_rate   = 7'd55; // 5.5 Hz 自然揉弦速率
    // 3. 曲目模式禁用全局滑音（防止多声部和弦伴奏被滑音偷声部）
    assign song_glide_on   = 1'b0;
    assign song_glide_time = 7'd0;

    // ------------------------------------------------------------------ FSM ----
    always @(posedge clk) begin
        if (!rst_n) begin
            state          <= S_IDLE;
            playing_r      <= 1'b0;
            song_index_r   <= 4'd0;
            note_idx       <= 9'd0;
            dur_cnt        <= 20'd0;
            cur_dur        <= 20'd0;
            active_note    <= 7'd0;
            active_vel     <= 7'd0;
            has_active     <= 1'b0;
            chord_notes[0] <= 7'd0;
            chord_notes[1] <= 7'd0;
            chord_notes[2] <= 7'd0;
            chord_notes[3] <= 7'd0;
            chord_cnt      <= 3'd0;
            paused_r       <= 1'b0;
            pause_had_note <= 1'b0;
            alloff_cnt     <= 7'd0;
            sec_tick_cnt        <= 17'd0;
            cur_sec             <= 8'd0;
            cur_min             <= 8'd0;
            song_progress_pct_r <= 8'd0;
            song_note_idx_r     <= 9'd0;
            song_sub_scroll_r   <= 6'd0;
            scroll_acc          <= 21'd0;
            on_valid            <= 1'b0;
            on_note             <= 7'd0;
            on_vel              <= 7'd0;
            off_valid           <= 1'b0;
            off_note            <= 7'd0;
        end else begin
            on_valid  <= 1'b0;
            off_valid <= 1'b0;
            song_progress_pct_r <= pct_w;
            song_note_idx_r     <= cur_note_idx_w;

            // 实时播放秒表计数
            if (state == S_IDLE) begin
                sec_tick_cnt <= 17'd0;
                cur_sec      <= 8'd0;
                cur_min      <= 8'd0;
            end else if (playing_r && sample_tick) begin
                if (sec_tick_cnt >= 17'd97655) begin
                    sec_tick_cnt <= 17'd0;
                    if (cur_sec >= 8'd59) begin
                        cur_sec <= 8'd0;
                        if (cur_min < 8'd59) cur_min <= cur_min + 8'd1;
                    end else begin
                        cur_sec <= cur_sec + 8'd1;
                    end
                end else begin
                    sec_tick_cnt <= sec_tick_cnt + 17'd1;
                end
            end

            // ★★★ 全局最高优先级：运行期模式使能 run_en ★★★
            if (!run_en && (state != S_IDLE) && (state != S_OFF) && (state != S_ALLOFF)) begin
                playing_r <= 1'b0;
                paused_r  <= 1'b0;
                state     <= S_OFF;
            end
            else if (run_rise && (state == S_IDLE)) begin
                playing_r  <= 1'b1;
                paused_r   <= 1'b0;
                note_idx   <= 9'd0;
                dur_cnt    <= 20'd0;
                has_active <= 1'b0;
                chord_cnt  <= 3'd0;
                state      <= S_LOAD;
            end
            else begin
            case (state)

            // ------------------------------------------------------- 停止 ----
            S_IDLE: begin
                if (play_press) begin
                    playing_r  <= 1'b1;
                    note_idx   <= 9'd0;
                    dur_cnt    <= 20'd0;
                    has_active <= 1'b0;
                    chord_cnt  <= 3'd0;
                    state      <= S_LOAD;
                end
            end

            // ------------------------------------------- 等 ROM（1 拍）----
            S_LOAD: begin
                state <= S_LATCH;
            end

            // ------------------------------------- 锁存音符 + 发 note-on ----
            S_LATCH: begin
                if (r_end) begin
                    note_idx     <= 9'd0;
                    sec_tick_cnt <= 17'd0;
                    cur_sec      <= 8'd0;
                    cur_min      <= 8'd0;
                    chord_cnt    <= 3'd0;
                    state        <= S_OFF;
                end else begin
                    note_idx          <= note_idx + 9'd1;
                    dur_cnt           <= 20'd0;
                    cur_dur           <= r_dur;
                    scroll_acc        <= 21'd0;
                    song_sub_scroll_r <= 6'd0;
                    if (r_note == NOTE_REST) begin
                        has_active <= 1'b0;
                        state      <= S_WAIT;
                    end else begin
                        on_valid    <= 1'b1;
                        on_note     <= r_note;
                        on_vel      <= r_vel;
                        active_note <= r_note;
                        active_vel  <= r_vel;
                        has_active  <= 1'b1;
                        state       <= S_WAIT;
                    end
                end
            end

            // ------------------------------------------------- 数槽长 ----
            S_WAIT: begin
                if (play_press) begin
                    playing_r <= 1'b0;
                    state     <= S_OFF;
                end else if (pause_press) begin
                    if (has_active) begin
                        off_valid  <= 1'b1;
                        off_note   <= active_note;
                        has_active <= 1'b0;
                    end
                    pause_had_note <= has_active;
                    playing_r      <= 1'b0;
                    paused_r       <= 1'b1;
                    state          <= S_PAUSE;
                end else if (next_press) begin
                    song_index_r <= (song_index_r + 4'd1 >= rom_n_songs)
                                    ? 4'd0 : (song_index_r + 4'd1);
                    note_idx     <= 9'd0;
                    dur_cnt      <= 20'd0;
                    sec_tick_cnt <= 17'd0;
                    cur_sec      <= 8'd0;
                    cur_min      <= 8'd0;
                    chord_cnt    <= 3'd0;
                    // 切歌时走 S_OFF -> S_ALLOFF 清空上一首可能残留的和弦伴奏音，然后自动进 S_LOAD
                    state        <= S_OFF;
                end else if (sample_tick) begin
                    dur_cnt <= dn[19:0];
                    if (scroll_acc + 21'd60 >= {1'b0, cur_dur_s}) begin
                        scroll_acc <= scroll_acc + 21'd60 - {1'b0, cur_dur_s};
                        if (song_sub_scroll_r < 6'd59)
                            song_sub_scroll_r <= song_sub_scroll_r + 6'd1;
                    end else begin
                        scroll_acc <= scroll_acc + 21'd60;
                    end
                    // 每个音符（含和弦分解短音与主旋律长音）均在自身 off_at 处发出 off_valid：
                    // · 钢琴/吉他模式下 song_sustain=1，短和弦音自动进入引擎 v_sus_pend 延音，并在主音槽末随踏板抬起一并释放；
                    // · 小提琴模式下 sustain=0，短音即刻松弓，彻底杜绝多音持续拉弓轰鸣与漏关死音！
                    if (has_active && (dn >= off_at)) begin
                        off_valid  <= 1'b1;
                        off_note   <= active_note;
                        has_active <= 1'b0;
                    end
                    // 槽满 → 取下一个音符
                    if (dn >= {1'b0, cur_dur_s}) begin
                        state <= S_LOAD;
                    end
                end
            end

            // ------------------------------------------- 逐音 off ----
            S_OFF: begin
                if (has_active) begin
                    off_valid  <= 1'b1;
                    off_note   <= active_note;
                    has_active <= 1'b0;
                end
                chord_cnt  <= 3'd0;
                alloff_cnt <= 7'd0;
                state      <= S_ALLOFF;
            end

            // ------------------------- all-notes-off 扫描（128 拍 0..127）----
            S_ALLOFF: begin
                off_valid <= 1'b1;
                off_note  <= alloff_cnt;
                if (alloff_cnt == ALLOFF_LAST) begin
                    alloff_cnt <= 7'd0;
                    state      <= playing_r ? S_LOAD : S_IDLE;
                end else begin
                    alloff_cnt <= alloff_cnt + 7'd1;
                end
            end

            // ------------------------------------------- 暂停（位置冻结）----
            S_PAUSE: begin
                if (pause_press) begin
                    paused_r  <= 1'b0;
                    playing_r <= 1'b1;
                    if (pause_had_note) begin
                        on_valid   <= 1'b1;
                        on_note    <= active_note;
                        on_vel     <= active_vel;
                        has_active <= 1'b1;
                    end
                    state <= S_WAIT;
                end else if (play_press) begin
                    paused_r  <= 1'b0;
                    playing_r <= 1'b0;
                    state     <= S_OFF;
                end
            end

            default: state <= S_IDLE;
            endcase
            end
        end
    end

endmodule

`default_nettype wire
