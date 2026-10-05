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

    // ---- 音符命令总线（与 piano_engine / midi_rx 共用语义）----
    output reg         on_valid,      // note-on 脉冲（1 个 clk）
    output reg  [6:0]  on_note,       // MIDI 音符号 0..127
    output reg  [6:0]  on_vel,        // 力度 0..127
    output reg         off_valid,     // note-off 脉冲
    output reg  [6:0]  off_note,

    // ---- 状态输出（给 LED 与调试）----
    output wire        playing,       // 正在播放
    output wire [3:0]  song_index,    // 当前第几首（0 起）
    output wire [3:0]  song_count     // 共几首
);

    // ------------------------------------------------------------- 状态编码 ----
    localparam [2:0] S_IDLE   = 3'd0,   // 停止
                     S_LOAD   = 3'd1,   // 等同步 ROM 出数
                     S_LATCH  = 3'd2,   // 锁存音符 / 发 note-on
                     S_WAIT   = 3'd3,   // 数槽长
                     S_OFF    = 3'd4,   // 发逐音 off
                     S_ALLOFF = 3'd5;   // 发 all-notes-off 扫描（128 拍）

    // 休止符编码。⚠️ 注意：7'h7F 在 off 总线上【不再】代表"全部松开"——
    // 全关是用 128 拍扫描表达的（见文件头）。这里的 7'h7F 只是 song_rom 里
    // "这个地址是休止符、不发 note-on"的标记，两者语义无关。
    localparam [6:0] NOTE_REST = 7'h7F;

    // all-notes-off 扫描：off_note 依次 = 0..127，共 128 拍
    // （与 midi_rx.v 解析 CC123 的产出方式一致，下游只需一套语义）
    localparam [6:0] ALLOFF_LAST = 7'd127;

    // GAP_TICKS=0 时按 CLK_HZ 折算 2.62 ms：50e6/195312 = 256 tick
    // （tick = 512 clk ⇒ 256×512/50e6 = 2.62 ms）。用 CLK_HZ 而不是写死 256，
    // 这样换时钟频率时回退值跟着变 —— 参数不是摆设。
    localparam integer GAP_DEF = CLK_HZ / 195312;
    localparam integer GAP_RAW = (GAP_TICKS > 0) ? GAP_TICKS : GAP_DEF;
    // ⚠️ 用 sized localparam 承接，不写 `GAP_RAW[20:0]`：对 integer 参数做位选
    //    在 ModelSim 上能过，但属于依赖工具宽容度的写法；本模块要交给 Lead 综合，
    //    主动避开任何可能被综合器挑剔的构造。
    localparam [20:0]  GAP_RAW_C = GAP_RAW;
    localparam [20:0]  GAP_C     = (GAP_RAW < 1) ? 21'd1 : GAP_RAW_C;

    // --------------------------------------------------------------- 寄存器 ----
    reg [2:0]  state;
    reg        playing_r;
    reg [3:0]  song_index_r;
    reg [8:0]  note_idx;        // 当前/下一个音符的 ROM 序号
    reg [19:0] dur_cnt;         // 槽内已过的 sample_tick 数
    reg [19:0] cur_dur;         // 本音符槽长（sample_tick）
    reg [6:0]  active_note;     // 正在响的音（用于 off）
    reg        has_active;      // 1 = 有音正在响、还没发过 off
    reg        key_play_d, key_next_d;
    reg [6:0]  alloff_cnt;      // all-notes-off 扫描计数 0..127

    // ------------------------------------------------------------- 曲目 ROM ----
    wire [34:0] rom_dout;
    wire [3:0]  rom_n_songs;

    // ★ addr 用【组合】的 note_idx：与 wave_rom.v 的读法一致（同步 ROM 读）。
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
    // song_count 直接透传 ROM 的 n_songs ⇒ 生成器改了歌数，这里自动跟上，
    // 不存在"两处硬编码不同步"的可能。
    assign playing    = playing_r;
    assign song_index = song_index_r;
    assign song_count = rom_n_songs;

    // ------------------------------------------------------------- 按键边沿 ----
    // key_play / key_next 是【顶层已同步去抖后的电平】。本模块只取上升沿：
    // 机械按键会被按住很久，电平驱动会导致反复切换（见文件头决策 (1)）。
    always @(posedge clk) begin
        key_play_d <= key_play;
        key_next_d <= key_next;
    end
    wire play_press = key_play & ~key_play_d;
    wire next_press = key_next & ~key_next_d;

    // ------------------------------------------------------- 槽长组合比较 ----
    // cur_dur 至少按 1 处理：ROM 里 dur 恒 ≥1（生成器已断言），这里是防御性的。
    wire [19:0] cur_dur_s = (cur_dur == 20'd0) ? 20'd1 : cur_dur;
    // off 应在槽末【之前】GAP 发出；GAP 比槽还长时退化为"第 1 个 tick 就 off"
    wire [20:0] off_at = (cur_dur_s > GAP_C) ? ({1'b0, cur_dur_s} - GAP_C) : 21'd1;
    // 下一拍的计数值（用 21 bit 承接，避免 cur_dur 取满时回绕）
    wire [20:0] dn = {1'b0, dur_cnt} + 21'd1;

    // ------------------------------------------------------------------ FSM ----
    always @(posedge clk) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            playing_r    <= 1'b0;
            song_index_r <= 4'd0;
            note_idx     <= 9'd0;
            dur_cnt      <= 20'd0;
            cur_dur      <= 20'd0;
            active_note  <= 7'd0;
            has_active   <= 1'b0;
            alloff_cnt   <= 7'd0;
            on_valid     <= 1'b0;
            on_note      <= 7'd0;
            on_vel       <= 7'd0;
            off_valid    <= 1'b0;
            off_note     <= 7'd0;
        end else begin
            // 两个脉冲默认拉低，需要时在下面某一拍置 1 —— 保证严格 1 拍宽。
            on_valid  <= 1'b0;
            off_valid <= 1'b0;

            case (state)

            // ------------------------------------------------------- 停止 ----
            S_IDLE: begin
                if (play_press) begin
                    // 按键1 上升沿 = 从第 1 个音符开始播
                    playing_r  <= 1'b1;
                    note_idx   <= 9'd0;
                    dur_cnt    <= 20'd0;
                    has_active <= 1'b0;          // 停止时已经全 off 过
                    state      <= S_LOAD;
                end
                // key_next 在这里【故意】不响应：切歌只在播放时有效
            end

            // ------------------------------------------- 等 ROM（1 拍）----
            S_LOAD: begin
                state <= S_LATCH;
            end

            // ------------------------------------- 锁存音符 + 发 note-on ----
            S_LATCH: begin
                if (r_end) begin
                    // 曲末 → 单曲循环（理由见文件头决策 (3)）
                    // 到这里 has_active 必然是 0：每个音符的 off 都在 off_at
                    // （≥1 且 < 槽末）发过，槽末之前就已经松开了。
                    note_idx <= 9'd0;
                    state    <= S_LOAD;
                end else begin
                    note_idx <= note_idx + 9'd1;   // 预取下一个音符
                    dur_cnt  <= 20'd0;
                    cur_dur  <= r_dur;
                    if (r_note == NOTE_REST) begin
                        // 休止符：只占时值，不发任何命令
                        has_active <= 1'b0;
                        state      <= S_WAIT;
                    end else begin
                        on_valid    <= 1'b1;
                        on_note     <= r_note;
                        on_vel      <= r_vel;
                        active_note <= r_note;
                        has_active  <= 1'b1;
                        state       <= S_WAIT;
                    end
                end
            end

            // ------------------------------------------------- 数槽长 ----
            S_WAIT: begin
                // ★ 优先级：停止 > 切歌 > 正常计数
                //   两个键同拍按下时选"停止"——停止是更安全的结果（不会留下
                //   一个没人管的播放状态）。
                if (play_press) begin
                    playing_r <= 1'b0;                 // 立刻反映到 playing/LED
                    state     <= S_OFF;                // 逐音 off 后再走 128 拍全关扫描
                end else if (next_press) begin
                    // 按键2：切下一首（放完最后一首回到第一首）
                    song_index_r <= (song_index_r + 4'd1 >= rom_n_songs)
                                    ? 4'd0 : (song_index_r + 4'd1);
                    note_idx  <= 9'd0;                 // 新曲从第 1 个音符放
                    dur_cnt   <= 20'd0;
                    state     <= has_active ? S_OFF : S_LOAD;
                end else if (sample_tick) begin
                    dur_cnt <= dn[19:0];
                    // 槽末之前先静音，给下一个音符留出断句的缝
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
                alloff_cnt <= 7'd0;
                // 停止流程要继续发 all-notes-off 扫描；切歌流程直接去取新曲的音符
                state <= playing_r ? S_LOAD : S_ALLOFF;
            end

            // ------------------------- all-notes-off 扫描（128 拍 0..127）----
            // ★ 语义与 midi_rx.v 解析 CC123 时的产出**完全一致**：连续 128 拍
            //   off_valid，off_note 依次 0,1,…,127。下游 top.v 只实现一套即可。
            //   （本模块第一版曾用单拍 off_note=7'h7F 当广播码，已废弃 ——
            //     同一条总线上两种方言必然出事。）
            //   每拍一个音符，128 拍共 2.56 µs，相对顶层去抖窗口 2.621 ms 可忽略。
            S_ALLOFF: begin
                off_valid <= 1'b1;
                off_note  <= alloff_cnt;
                if (alloff_cnt == ALLOFF_LAST) begin
                    alloff_cnt <= 7'd0;
                    state      <= S_IDLE;
                end else begin
                    alloff_cnt <= alloff_cnt + 7'd1;
                end
            end

            default: state <= S_IDLE;
            endcase

            // ⚠️ 已知的"死窗口"：停止流程要经过 S_OFF（1 拍）+ S_ALLOFF（128 拍）
            //    才回 S_IDLE，这 129 个 clk（2.58 µs @50 MHz）内新按下的 key_play
            //    会被忽略。人手的按键间隔远大于 2.58 µs，且顶层去抖窗口本身就有
            //    2.621 ms（是它的 1000 倍），故不构成实际问题；这里写明是防止
            //    将来有人看到"连点两下只生效一次"却找不到原因。
            //    （若将来真要消除这个窗口，在 S_ALLOFF 里允许 play_press 抢占、
            //      把扫描剩余部分丢弃即可——但那样会在总线上留半套扫描，
            //      反而更危险，故不做。）
            //
            // ⚠️ 另一个更小的同类窗口（本模块自己查出来的，不是已知问题）：
            //    S_LOAD / S_LATCH 这 2 拍里**不检查 key_next** —— 只有 S_WAIT
            //    才响应切歌。取一个音符固定占 2 clk，而最短的音符槽长是
            //    12207 tick（致爱丽丝的十六分音符）⇒ 按键恰好落进这 2 拍的概率
            //    < 0.02%。落空的表现只是"这一下没切"，再按一次即可。
            //    刻意不修：为消除它要再加一套 latch，复杂度高于收益。
        end
    end

endmodule

`default_nettype wire
