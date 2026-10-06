// =============================================================================
//  top.v —— fpga_hank 顶层（三模式：演示 / 电脑控制 / 32峰测试）
//
//  ★ 2026-10-05 三模式集成版。集成依据见 docs/INTEGRATION-CHECKLIST-top.md §1~§17。
//
//  模式（编译期参数 MODE，**不是运行期切换**）：
//
//    MODE=2  32峰测试（赛题必备交付物的取证场景）
//            gate 恒为全 1，音色锁纯正弦
//            bench_gate ──gate[32]──► adsr ──► tone_bank(32 路) ──► I2S
//            ⇒ 32 个独立振荡器【恒同时发声】，频谱可数出 32 根独立谱峰
//
//    MODE=0  演示模式（按键控制放歌）
//            key  = 按键1：按下播放 / 再按停止（边沿触发）
//            key2 = 按键2：播放中切歌（只在播放时有效）
//            song_player ──音符总线──► piano_engine(8 声部) ──► audio_fx ──► I2S
//
//    MODE=1  电脑控制（电脑当钢琴弹）
//            PC ──115200 8N1──► uart_rx ──► midi_rx ──音符/表情总线──►
//                 piano_engine(8 声部) ──► audio_fx ──► I2S
//            key2 = 循环切换效果器（旁路/延迟/合唱/混响）
//
//  ★ 为什么 MODE 是【参数】而不是运行期切换：
//    1. 每个模式一份位流，构建期就把不用的通路优化掉（MODE=2 时钢琴/效果器全被优化掉，
//       位流与取证场景完全一致）
//    2. **不存在运行期模式切换 ⇒ 不需要"切换时发全关"**（song_player 复位不补发
//       all-notes-off 是设计如此，见集成清单 §2.1；参数化后这个问题自动消失）
//
//  ★ 三个已上板确证的结论（集成清单 §7/§9）：
//    · FPGA UART = COM9（FT2232H 通道 B）；`rxp` 用 V14，**且不能带 DRIVE=8**（P&R 报 CT1108）
//    · 全关语义 = 连续 128 拍 off_valid（off_note 0..127）；下游必须【逐拍】消化
//    · 采样率 fs = 97656.25 Hz（BCK_DIV=1）
//
//  ★ 引脚：见 constr/fpga_hank.cst（新增 uart_rx_pin = V14）
// =============================================================================
`default_nettype none

module top #(
    // 0 = 演示模式（按键放歌）；1 = 电脑控制（串口钢琴）；2 = 32峰测试
    parameter integer MODE       = 1,
    // 采样率：BCK_DIV=1 -> fs=97656.25 Hz；BCK_DIV=2 -> 48828.125 Hz
    //   ⚠️ 改这个值必须同步重新生成 tone_bank.v / piano_rom.v（频率字按新采样率折算）
    parameter integer BCK_DIV    = 1,
    // MODE=0/1 下效果器的【上电默认档】：0=旁路 1=延迟 2=合唱 3=混响
    //   ⚠️ 默认旁路 —— 万一效果器有问题，最坏情况只是"没效果"，不会毁掉演示
    parameter integer FX_DEFAULT = 0
)(
    input  wire       clk,        // V22, 50 MHz 板载有源晶振
    output wire [3:0] led,        // T18 R18 R17 P16，低有效
    output wire       HP_BCK,     // Y17  PT8211 I2S 位时钟
    output wire       HP_WS,      // AB17 PT8211 I2S 字选
    output wire       HP_DIN,     // AA16 PT8211 I2S 数据
    output wire       PA_EN,      // AB16 功放使能，低有效

    // ------ 交互按键（赛题基础要求①：≥2 个独立可控维度）------
    input  wire       key,        // AB13  MODE=0:播放/停止；MODE=2:无（恒发声）
    input  wire       key2,       // Y12   MODE=0:切歌；MODE=1:切效果器；MODE=2:音色
    input  wire       key_pitch,  // Y22   MODE=2:变调（每按一下升 1 半音）

    // ------ 电脑控制链路新增（2026-10-05 上板确证）------
    // V14：官方引脚文件给 `rxp` 写的是 V14（Version 31004+）；已上板回环验证
    // ⚠️ 约束里 **不能给它 DRIVE=8**（本器件 P&R 报 ERROR CT1108）
    input  wire       uart_rx_pin // V14  PC → FPGA 串口接收
);

    // ---------------------------------------------------- 上电复位 ----------
    reg [18:0] por = 19'd0;
    wire       rst_n = &por;                 // 2^19/50MHz ≈ 10.5 ms

    always @(posedge clk)
        if (!rst_n) por <= por + 19'd1;

    // 去抖时长：2^17 clk = 2.621 ms（控制→发声延迟的主要贡献项）
    localparam [19:0] DB_MAX = 20'd65536;   // ★ 2026-10-06 2^17(2.621ms)→2^16(1.311ms)
    //   理由：拓展③要求延迟<=5ms且留裕度。2^17 时按键路径总延迟 2.98ms（裕度仅1.7x）；
    //   2^16 后约 1.67ms（裕度 3x）。1.311ms 的去抖对好触感按键（弹跳 <1ms）足够，
    //   但【必须在真板上验证不会双击】—— 按 50 次看有没有一次按下出两个音。
    //   若发现双击，改回 20'd131071 即可（一行）。

    // ---------------------------------------------------- I2S 发送 ---------
    // ★ 必须【先例化】pt8211_tx，因为 sample_tick 由它产生，下游全靠它当节拍
    wire               sample_tick;
    wire signed [15:0] audio_mix;

    pt8211_tx #(.BCK_DIV(BCK_DIV)) u_dac (
        .clk        (clk),
        .reset      (~rst_n),
        .sample_l   (audio_mix),
        .sample_r   (audio_mix),
        .sample_tick(sample_tick),
        .bck        (HP_BCK),
        .ws         (HP_WS),
        .din        (HP_DIN)
    );

    // ---------------------------------------------------- 按键同步 + 去抖 --
    reg key_meta, key_sync, key_db;
    reg k2_meta,  k2_sync,  k2_db;
    reg kp_meta,  kp_sync,  kp_db, kp_db_d;
    reg [19:0] db_cnt, db_cnt2, db_cnt3;

    always @(posedge clk) begin
        key_meta <= key;      key_sync <= key_meta;
        k2_meta  <= key2;     k2_sync  <= k2_meta;
        kp_meta  <= key_pitch; kp_sync <= kp_meta;

        if (!rst_n) begin
            db_cnt <= 20'd0;  key_db <= 1'b0;
            db_cnt2 <= 20'd0; k2_db  <= 1'b0;
            db_cnt3 <= 20'd0; kp_db  <= 1'b0; kp_db_d <= 1'b0;
        end else begin
            if (~key_sync != key_db) begin
                if (db_cnt == DB_MAX) begin db_cnt <= 20'd0; key_db <= ~key_sync; end
                else                       db_cnt <= db_cnt + 20'd1;
            end else db_cnt <= 20'd0;

            if (~k2_sync != k2_db) begin
                if (db_cnt2 == DB_MAX) begin db_cnt2 <= 20'd0; k2_db <= ~k2_sync; end
                else                        db_cnt2 <= db_cnt2 + 20'd1;
            end else db_cnt2 <= 20'd0;

            if (~kp_sync != kp_db) begin
                if (db_cnt3 == DB_MAX) begin db_cnt3 <= 20'd0; kp_db <= ~kp_sync; end
                else                        db_cnt3 <= db_cnt3 + 20'd1;
            end else db_cnt3 <= 20'd0;
            kp_db_d <= kp_db;
        end
    end

    wire key_held  = key_db;                  // 电平（MODE=0 的播放/停止由 song_player 取边沿）
    reg  k2_db_d;
    always @(posedge clk) k2_db_d <= k2_db;
    wire k2_press  = k2_db & ~k2_db_d;        // 上升沿
    wire kp_press  = kp_db & ~kp_db_d;

    // ================= 运行期模式：自由演奏 / 指定曲目（2026-10-06 新增）=================
    //  需求（用户）：key2 进曲目模式（自动播放）；key1 在曲目模式下 = 播放/暂停；
    //               上电默认【自由演奏】；key2 再按一下【回自由演奏】（否则回不去）。
    //  run_mode: 1 = 自由演奏（midi_rx 驱动）, 0 = 指定曲目（song_player 驱动）
    reg        k1_db_d;
    always @(posedge clk) k1_db_d <= key_db;
    wire k1_press = key_db & ~k1_db_d;          // key1 上升沿

    reg run_mode = 1'b1;                        // ★ 上电默认自由演奏（防 X）
    always @(posedge clk) begin
        if (!rst_n)               run_mode <= 1'b1;
        else if (MODE == 1) begin                // 只有 MODE=1（电脑控制位流）支持运行期切换
            if (k2_press) run_mode <= ~run_mode; // ★ key2 = 切换开关
        end else run_mode <= 1'b1;               // MODE=0/2 下不进曲目模式
    end
    wire run_song = (MODE == 1) ? ~run_mode : (MODE == 0);   // ★ 1 = 曲目模式

    // ★ 2026-10-06（用户要求）：曲目模式下 key1 = 【换乐器播放】（按一下切一个），
    //   不再做"暂停/播放"；暂停/播放由 key2 的进出模式承担。
    //   乐器选择走独立寄存器 inst_song，和自由演奏的 CC20 选择的 inst_sel 互不干扰。
    reg [1:0] inst_song = 2'd0;
    always @(posedge clk) begin
        if (!rst_n)                          inst_song <= 2'd0;
        else if (run_song & k1_press)        inst_song <= inst_song + 2'd1;   // 0→1→2→3→0
    end
    wire [1:0] inst_sel_eff = run_song ? inst_song : inst_sel;
    wire mode_chg = (MODE == 1) & k2_press;                  // 切换事件（一拍脉冲）

    // ---- 第 3 道清音：切换后静音窗 ~5 ms（避免阶跃"咔哒"）----
    //  ⚠️ v1 用静音窗（无乘法器/DSP）；线性淡入需要乘法器，留待后续
    localparam integer MUTE_LEN = 488;          // 5 ms × 97656.25 Hz
    reg [15:0] mute_cnt = 16'd0;
    always @(posedge clk) begin
        if (!rst_n)          mute_cnt <= 16'd0;
        else if (mode_chg)   mute_cnt <= MUTE_LEN[15:0];
        else if (mute_cnt != 16'd0) mute_cnt <= mute_cnt - 16'd1;
    end
    wire audio_muted = (mute_cnt != 16'd0);

    // 变调（MODE=2 用；上电必须是原调 ⇒ 初值 8 ⇒ pitch_semi=0）
    reg  [3:0] pitch_step = 4'd8;
    always @(posedge clk)
        if (!rst_n)        pitch_step <= 4'd8;
        else if (kp_press) pitch_step <= pitch_step + 4'd1;
    wire signed [3:0] pitch_semi = pitch_step - 4'd8;

    // MODE=2 音色切换（key2）
    reg [1:0] timbre_user = 2'd0;
    always @(posedge clk)
        if (!rst_n)        timbre_user <= 2'd0;
        else if (k2_press) timbre_user <= timbre_user + 2'd1;
    // 测试模式锁纯正弦表（否则每路多个谐波谱峰，判据会误判）
    wire [1:0] timbre_sel = (MODE == 2) ? 2'd0 : timbre_user;

    // ---------------------------------------------------- 音符命令总线 -----
    // 三个来源（song_player / midi_rx）共用同一套语义，按 MODE 选择
    wire        bus_on_valid, bus_off_valid, bus_cc_valid;
    wire [6:0]  bus_on_note, bus_on_vel, bus_off_note;
    wire        bus_glide_on, bus_vib_on, bus_sustain, bus_reset_all;
    wire [6:0]  bus_glide_time, bus_vib_depth, bus_vib_rate;

    // ---- 来源 A：song_player（MODE=0）----
    wire        s_on_valid, s_off_valid;
    wire [6:0]  s_on_note,  s_on_vel,  s_off_note;
    wire        s_playing;
    wire [3:0]  s_song_index, s_song_count;

    song_player #(.CLK_HZ(50_000_000)) u_song (
        .clk        (clk),
        .rst_n      (rst_n),
        .sample_tick(sample_tick),
        // ★ 2026-10-06 运行期模式：进入曲目模式由 run_en 上升沿自动播放 ⇒ key_play 不再需要
        .key_play   (1'b0),
        .key_next   (1'b0),          // 用户已定：不做切歌
        .key_pause  (1'b0),          // ★ 取消：曲目模式下 key1 改为【换乐器】（不在播放器里做暂停）
        .run_en     (run_song),      // ★ 电平使能：0 ⇒ 强制停止 + 走完 128 拍全关
        .on_valid   (s_on_valid),
        .on_note    (s_on_note),
        .on_vel     (s_on_vel),
        .off_valid  (s_off_valid),
        .off_note   (s_off_note),
        .playing    (s_playing),
        .song_index (s_song_index),
        .song_count (s_song_count)
    );

    // ---- 来源 B：uart_rx → midi_rx（MODE=1）----
    wire [7:0] uart_data;
    wire       uart_valid;

    uart_rx #(.CLK_HZ(50_000_000), .BAUD(115200)) u_uart (
        .clk   (clk),
        .rst_n (rst_n),
        .rx    (uart_rx_pin),
        .data  (uart_data),
        .valid (uart_valid)
    );

    wire        m_on_valid, m_off_valid, m_cc_valid;
    wire [6:0]  m_on_note,  m_on_vel,  m_off_note;
    wire        m_glide_on, m_vib_on, m_sustain, m_reset_all;
    wire [6:0]  m_glide_time, m_vib_depth, m_vib_rate;

    midi_rx u_midi (
        .clk        (clk),
        .rst_n      (rst_n),
        .byte_data  (uart_data),
        .byte_valid (uart_valid),
        .on_valid   (m_on_valid),
        .on_note    (m_on_note),
        .on_vel     (m_on_vel),
        .off_valid  (m_off_valid),
        .off_note   (m_off_note),
        .cc_valid   (m_cc_valid),
        .glide_on   (m_glide_on),
        .glide_time (m_glide_time),
        .vib_on     (m_vib_on),
        .vib_depth  (m_vib_depth),
        .vib_rate   (m_vib_rate),
        .sustain    (m_sustain),
        .reset_all  (m_reset_all),
        // ---- 通用 CC 直通（2026-10-06 新增）----
        .cc_num       (m_cc_num),
        .cc_val       (m_cc_val),
        .cc_any_valid (m_cc_any_valid)
    );

    // ================= 乐器/效果器 CC 译码（2026-10-06 新增）=================
    //  CC20 -> 乐器选择：0=钢琴 1=吉他 2=古筝
    //  CC21 -> 挂电量（吉他效果器强度）0..127
    //  ⚠️ midi_rx 只做传输层（原样透传 0..127），语义在这里定 —— 见 AGENTS.md §4.1
    wire [6:0] m_cc_num, m_cc_val;
    wire       m_cc_any_valid;
    reg  [1:0] inst_sel    = 2'd0;      // ★ 上电默认钢琴（防 X）
    reg  [6:0] drive_amt   = 7'd0;
    always @(posedge clk) begin
        if (!rst_n) begin
            inst_sel  <= 2'd0;
            drive_amt <= 7'd0;
        end else if (m_cc_any_valid) begin
            case (m_cc_num)
                7'd20: inst_sel  <= m_cc_val[1:0];
                7'd21: drive_amt <= m_cc_val;
                default: ;               // CC22~24 以后在这里补
            endcase
        end
    end
    // ---- 按 MODE 选择来源 ----
    // MODE=0：song_player；MODE=1：midi_rx；MODE=2：测试模式不使用音符总线
    //  ★ 2026-10-06：由【运行期】run_song 选择（MODE=0 恒曲目 / MODE=1 运行期 / MODE=2 不用）
    //  第 2 道清音：切换瞬间给 piano_engine 一个 reset_all 一拍脉冲（释放所有声部）
    wire bus_reset_all_w = (MODE == 2) ? 1'b0 : (run_song ? 1'b0 : (m_reset_all | mode_chg));
    assign bus_on_valid   = (MODE == 2) ? 1'b0        : (run_song ? s_on_valid  : m_on_valid);
    assign bus_on_note    = (MODE == 2) ? 7'd0        : (run_song ? s_on_note   : m_on_note);
    assign bus_on_vel     = (MODE == 2) ? 7'd0        : (run_song ? s_on_vel    : m_on_vel);
    assign bus_off_valid  = (MODE == 2) ? 1'b0        : (run_song ? s_off_valid : m_off_valid);
    assign bus_off_note   = (MODE == 2) ? 7'd0        : (run_song ? s_off_note  : m_off_note);
    assign bus_cc_valid   = (MODE == 2) ? 1'b0        : (run_song ? 1'b0        : m_cc_valid);
    assign bus_glide_on   = (MODE == 2) ? 1'b0        : (run_song ? 1'b0        : m_glide_on);
    assign bus_glide_time = (MODE == 2) ? 7'd0        : (run_song ? 7'd0        : m_glide_time);
    assign bus_vib_on     = (MODE == 2) ? 1'b0        : (run_song ? 1'b0        : m_vib_on);
    assign bus_vib_depth  = (MODE == 2) ? 7'd0        : (run_song ? 7'd0        : m_vib_depth);
    assign bus_vib_rate   = (MODE == 2) ? 7'd50       : (run_song ? 7'd50       : m_vib_rate);
    assign bus_sustain    = (MODE == 2) ? 1'b0        : (run_song ? 1'b0        : m_sustain);
    assign bus_reset_all  = bus_reset_all_w;

    // ★ 2026-10-06：把"曲目模式强制值"寄存一拍 —— 修上一版 −0.074 ns（mux 直连关键路径）
    reg [1:0] inst_sel_eff_r  = 2'd0;
    reg [6:0] bow_speed_eff_r = 7'd0;
    always @(posedge clk) begin
        if (!rst_n) begin
            inst_sel_eff_r  <= 2'd0;
            bow_speed_eff_r <= 7'd0;
        end else begin
            inst_sel_eff_r  <= inst_sel_eff;
            bow_speed_eff_r <= run_song ? 7'd0 : drive_amt;
        end
    end
    // ---------------------------------------------------- 钢琴引擎 ---------
    wire signed [15:0] mix_piano;
    wire [7:0]         piano_active;

    piano_engine #(
        .N_VOICES  (8),           // ★ 2026-10-06 曾试 20 ⇒ 时序失败(13203 违例/−6.774ns, BSRAM 219/340) 已回退；32 声部走 TDM 方案
        .CLK_HZ    (50_000_000),
        .OUT_SHIFT (1)
    ) u_piano (
        .clk        (clk),
        .rst_n      (rst_n),
        .sample_tick(sample_tick),
        .on_valid   (bus_on_valid),
        .on_note    (bus_on_note),
        .on_vel     (bus_on_vel),
        .off_valid  (bus_off_valid),
        .off_note   (bus_off_note),
        .glide_on   (bus_glide_on),
        .glide_time (bus_glide_time),
        .vib_on     (bus_vib_on),
        .vib_depth  (bus_vib_depth),
        .vib_rate   (bus_vib_rate),
        .sustain    (bus_sustain),
        // ★ 2026-10-06：曲目模式下【强制钢琴 + 弓速 0】
        //   （否则若用户上次选在二胡且 CC21>0，drive 会让每个音持续不衰减 ⇒ 整首歌变成一堵噪音 ✗）
        .inst_sel   (inst_sel_eff_r),          // ★ 曲目模式下由 key1 切换（已寄存，修时序）
        .bow_speed  (bow_speed_eff_r),         // ★ 曲目模式下强制 0（走内部中速兜底）
        .mix_out    (mix_piano),
        .active     (piano_active)
    );

    // ---------------------------------------------------- 32 路音源（MODE=2）
    wire [31:0]     gate;
    wire [4:0]      env_voice;
    wire [16:0]     env_level;
    wire signed [15:0] mix_bank;

    tone_bank #(
        .N_VOICES     (32),
        .ROM_PARALLEL (1)          // ★ 必须显式传 1：默认 32 会例化 32 份 wave_rom
    ) u_bank (                     //    ⇒ rom_val 无驱动 + 综合卡死（本项目实测）
        .clk        (clk),
        .rst_n      (rst_n),
        .sample_tick(sample_tick),
        .gate_in    (gate),
        .timbre     (timbre_sel),
        .pitch_semi (pitch_semi),
        .env_voice  (env_voice),
        .env_level  (env_level),
        .mix_out    (mix_bank)
    );

    adsr #(
        .N_VOICES (32),
        .EN_DIV   (512),
        .DIV_W    (16),
        .ATK_SH   (10),            // 1024 步 × 10.24 µs ≈ 10.5 ms
        .DEC_SH   (10),            //  256 步 × 10.24 µs ≈  2.6 ms
        .REL_SH   (13),            // 自 sustain 49152 起 6144 步 ≈ 62.9 ms
        .SUS_LEVEL(49152)
    ) u_adsr (
        .clk       (clk),
        .rst_n     (rst_n),
        .gate      (gate),
        .voice_rd  (env_voice),
        .level_rd  (env_level),
        .phase_rd  ()
    );

    // ★★ 关键：MODE=2 用【gate 恒全 1】★★
    //   依据集成清单 §7/§13：**真板 32/32 谱峰的取证配置是"32 路同时全开门"**
    //   （旧的 TEST_MODE=0 按下按键时就是这个状态）。
    //   用恒全 1 比"按住按键"更适合取证：**不需要人一直按着**，测量可重复。
    //   ⚠️ 不要用 bench_gate：它每 32768 采样点轮换、**任意时刻只有约 2 路在发声**
    //      ⇒ 瞬时频谱只有 2 根峰，不适合"N 路 → N 个谱峰"的判据。
    assign gate = (MODE == 2) ? 32'hFFFF_FFFF : 32'd0;

    // ---------------------------------------------------- 硬件效果器 -------
    // ★ 位置：混音之后、pt8211_tx 之前（集成清单 §16）
    // ★ 只在 MODE=0/1 生效；MODE=2 下被 mux 掉、综合时会整体优化掉
    //   ⇒ 保证 32 谱峰取证路径与"未加效果器时"**逐样本一致**
    reg  [1:0] fx_sel_user = FX_DEFAULT[1:0];
    always @(posedge clk)
        if (!rst_n)              fx_sel_user <= FX_DEFAULT[1:0];
        // ★ 2026-10-06：key2 在 MODE=1 下已经是【模式切换】⇒ 不再改效果器选择
        //   （原行为会让 fx_sel 越界到 3 > N_FX-1 ⇒ audio_fx 输出垃圾噪声 ✗）
    wire [1:0] fx_sel = (MODE == 0) ? FX_DEFAULT[1:0] : fx_sel_user;

    wire signed [15:0] fx_out;

    audio_fx #(
        .N_FX   (3)                    // ⚠️ 该模块【只有 N_FX】这一个参数
    ) u_fx (                           //    （作者注：内部不需要 CLK_HZ 做译码，
                                       //      仅保留契约参数 N_FX 为将来扩展预留）
        .clk        (clk),
        .rst_n      (rst_n),
        .sample_tick(sample_tick),
        .fx_sel     (fx_sel),
        .param      (7'd64),           // 0..127：深度/反馈量，取中值
        .fx_in      (mix_piano),
        .fx_out     (fx_out)
    );

    // ---------------------------------------------------- 音频输出 mux ----
    // MODE=2：纯 tone_bank（32 路恒发声，供频谱取证）
    // MODE=0/1：钢琴引擎 → 效果器
    wire signed [15:0] audio_mix_raw = (MODE == 2) ? mix_bank : fx_out;
    assign audio_mix = audio_muted ? 16'sd0 : audio_mix_raw;   // ★ 第 3 道清音

    // ---------------------------------------------------- 功放使能 ---------
    assign PA_EN = 1'b0;               // 低有效 ⇒ 常开

    // ---------------------------------------------------- 状态 LED ---------
    // 低有效（驱动 0 点亮）
    reg [25:0] heart = 26'd0;
    always @(posedge clk)
        if (rst_n) heart <= heart + 26'd1;

    reg samp_seen = 1'b0;
    reg act_seen  = 1'b0;
    always @(posedge clk) begin
        if (!rst_n) begin
            samp_seen <= 1'b0;
            act_seen  <= 1'b0;
        end else begin
            if (sample_tick) samp_seen <= 1'b1;
            // MODE=2：包络真的在非静音阶段；MODE=0/1：钢琴声部活跃
            if (MODE == 2) begin
                if (env_level != 17'd0) act_seen <= 1'b1;
            end else begin
                if (piano_active != 8'd0) act_seen <= 1'b1;
            end
        end
    end

    // led[0] 心跳；led[1] 采样帧在流动；led[2] 有音符；led[3] 包络/声部活跃
    //   MODE=0 追加：led[3] 同时指示"正在放歌"（s_playing）
    assign led[0] = heart[24];
    assign led[1] = ~samp_seen;
    assign led[2] = (MODE == 0) ? ~{s_playing} :
                    (MODE == 1) ? ~(|piano_active) :
                                  ~(&gate);
    assign led[3] = ~act_seen;

endmodule

`default_nettype wire
