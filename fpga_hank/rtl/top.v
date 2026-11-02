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
    // 3 = 硬件乐器（S5：13键+光电+ToF+EC11 直驱音符总线，见 io/hw_input_mgr.v）
    parameter integer MODE       = 3,
    // 采样率：BCK_DIV=1 -> fs=97656.25 Hz；BCK_DIV=2 -> 48828.125 Hz
    //   ⚠️ 改这个值必须同步重新生成 tone_bank.v / piano_rom.v（频率字按新采样率折算）
    parameter integer BCK_DIV    = 1,
    // MODE=0/1 下效果器的【上电默认档】：0=旁路 1=延迟 2=合唱 3=混响
    //   ⚠️ 默认旁路 —— 保证上电即具备极致清澈的干声基底，按按键或发送 CC 可随时开启效果器
    parameter integer FX_DEFAULT = 0,
    // ★ 138K 进阶总开关：1 = 启用 32复音×6泛音(192独立振荡器) TDM 引擎；0 = 8复音×6泛音并行引擎
    parameter integer USE_TDM32  = 1,
    // ★ 电吉他过载+箱体模拟级联开关：1 = 串联 guitar_fx (电吉他档自动开启过载+4x12箱体)
    parameter integer EN_GUITAR_FX = 1,
    // ★ 7寸 ATK-MD0700 (SSD1963 8080 J14) 仪器大屏 UI 与双缓冲 3.0s 实时示波器开关
    //   设置为 1（启用并具备智能空闲静音与断线检测保护，零音频串扰）：
    parameter integer EN_LCD_J14   = 1
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
    input  wire       key_pitch,  // AA19  MODE=2:变调（每按一下升 1 半音）；放歌:切歌

    // ------ 电脑控制链路新增（2026-10-05 上板确证）------
    // V14：官方引脚文件给 `rxp` 写的是 V14（Version 31004+）；已上板回环验证
    // ⚠️ 约束里 **不能给它 DRIVE=8**（本器件 P&R 报 ERROR CT1108）
    input  wire       uart_rx_pin, // V14  PC → FPGA 串口接收

    // ------ S5 硬件乐器输入（MODE=3；引脚全部实测过，见 INPUTS-WIRING.md）--
    input  wire [12:0] key_hw,     // J13 1..10,13,14,15  按下=0（内部上拉）
    input  wire [5:0]  photo_hw,   // J13 16..21          挡光=0（经 S9012）
    input  wire        ec1a,       // J13-22 D17  EC11 #1 正交 A
    input  wire        ec1b,       // J13-23 A19  EC11 #1 正交 B
    inout  wire        scl_tof,    // J13    A18  ToF#1 总线 A SCL（必须 inout）
    inout  wire        sda_tof,    // J13    D15  ToF#1 总线 A SDA
    output wire        dbg_tx,     // U15         UART TX（遥测 & 屏幕硬件截屏输出）

    // ------ J14 7寸 800x480 ATK-MD0700 (SSD1963 16-bit 8080) 仪器屏接口 ------
    output wire        lcd_cs,     // AB21 (J14-354)
    output wire        lcd_rs,     // R14  (J14-39)
    output wire        lcd_wr,     // AB20 (J14-357)
    output wire        lcd_rd,     // AB18 (J14-30)
    output wire        lcd_rst,    // Y18  (J14-32)
    inout  wire [15:0] lcd_db,     // 16-bit 8080 数据总线
    output wire        lcd_dpi_bl, // P20 -> GND (关闭底板 RGB 背光升压)
    output wire        ws_dout,    // J16 -> 板载 WS2812 RGB 状态灯

    // ------ 电容触摸屏接口 (FT5206 / FT5426 I2C on J14) ------
    inout  wire        tp_scl,     // U18 (J14-359)  I2C SCL
    inout  wire        tp_sda,     // Y19 (J14-31)  I2C SDA
    input  wire        tp_int,     // Y19 (J14-33)  触摸中断（低有效）
    output wire        tp_rst_n    // U18 (J14-35) 触摸复位（低有效，严禁使用 T20/J14-33 专用脚）
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
    wire signed [15:0] audio_mix_l, audio_mix_r;
    wire signed [15:0] audio_mix = audio_mix_l;

    pt8211_tx #(.BCK_DIV(BCK_DIV)) u_dac (
        .clk        (clk),
        .reset      (~rst_n),
        .sample_l   (audio_mix_l),
        .sample_r   (audio_mix_r),
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
    //  需求（用户）：key2 进曲目模式（自动播放）；再按一下 key2 回自由演奏；
    //               自由演奏下【同时响应】电脑串口 MIDI (COM9) 与 J13 物理乐器输入；
    //               曲目模式下：短按 key1 = 换乐器（钢琴→吉他→小提琴），长按 key1 (≥0.5s) = 切下一首歌。
    reg        k1_db_d;
    always @(posedge clk) k1_db_d <= key_db;
    wire k1_press = key_db & ~k1_db_d;          // key1 上升沿
    wire k1_rel   = ~key_db & k1_db_d;          // key1 下降沿（松开）

    // key1 长按检测（≥0.5s = 25,000,000 clk 触发切歌；短按松开触发换乐器）
    localparam [24:0] K1_LONG_MAX = 25'd25_000_000;
    reg [24:0] k1_hold_cnt = 25'd0;
    reg        k1_long_fired = 1'b0;
    always @(posedge clk) begin
        if (!rst_n || !key_db) begin
            k1_hold_cnt   <= 25'd0;
            k1_long_fired <= 1'b0;
        end else if (k1_hold_cnt < K1_LONG_MAX) begin
            k1_hold_cnt <= k1_hold_cnt + 25'd1;
        end else begin
            k1_long_fired <= 1'b1;
        end
    end
    wire k1_long_pulse  = run_song && key_db && (k1_hold_cnt == K1_LONG_MAX - 25'd1);
    wire k1_short_pulse = run_song && k1_rel && !k1_long_fired;

    // 运行期模式：1=自由演奏（上电默认，同时支持 PC MIDI + J13 物理按键），2=自动放歌
    reg [1:0] source_mode = 2'd1;
    always @(posedge clk) begin
        if (!rst_n) begin
            source_mode <= 2'd1;
        end else if (((MODE == 1) || (MODE == 3)) && k2_press) begin
            source_mode <= (source_mode == 2'd2) ? 2'd1 : 2'd2;
        end
    end
    wire run_song = (MODE == 0) || (((MODE == 1) || (MODE == 3)) && (source_mode == 2'd2));
    wire source_physical = (MODE == 3) && !run_song;

    // ★ 曲目模式下短按 key1 = 【换乐器播放】（钢琴→吉他→小提琴→钢琴）
    reg [1:0] inst_song = 2'd0;
    always @(posedge clk) begin
        if (!rst_n)                   inst_song <= 2'd0;
        else if (k1_short_pulse || (touch_timbre_pulse && run_song))
            inst_song <= (inst_song >= 2'd3) ? 2'd0 : (inst_song + 2'd1);
    end
    wire [1:0] inst_sel_eff = run_song ? inst_song : inst_sel;
    wire mode_chg = ((MODE == 1) || (MODE == 3)) & k2_press;

    // ---- 第 3 道清音：切换后静音窗 ~5 ms（避免阶跃"咔哒"）----
    //  ⚠️ v1 用静音窗（无乘法器/DSP）；线性淡入需要乘法器，留待后续
    localparam integer MUTE_LEN = 488;          // 5 ms × 97656.25 Hz
    reg [15:0] mute_cnt = 16'd0;
    always @(posedge clk) begin
        if (!rst_n)          mute_cnt <= 16'd0;
        else if (mode_chg)   mute_cnt <= MUTE_LEN[15:0];
        else if (mute_cnt != 16'd0) mute_cnt <= mute_cnt - 16'd1;
    end
    reg audio_muted_r = 1'b1;
    always @(posedge clk) begin
        if (!rst_n) audio_muted_r <= 1'b1;
        else        audio_muted_r <= (mute_cnt != 16'd0);
    end
    wire audio_muted = audio_muted_r;

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
        else if (k2_press && (MODE != 3)) timbre_user <= timbre_user + 2'd1;
    // 测试模式锁纯正弦表（否则每路多个谐波谱峰，判据会误判）
    wire [1:0] timbre_sel = (MODE == 2) ? 2'd0 : timbre_user;

    // ---------------------------------------------------- 音符命令总线 -----
    // 三个来源（song_player / midi_rx）共用同一套语义，按 MODE 选择
    wire        bus_on_valid, bus_off_valid, bus_cc_valid;
    wire [6:0]  bus_on_note, bus_on_vel, bus_off_note;
    wire        bus_glide_on, bus_vib_on, bus_sustain, bus_reset_all;
    wire [6:0]  bus_glide_time, bus_vib_depth, bus_vib_rate;

    // ---- 来源 A：song_player（MODE=0 / 曲目模式）----
    wire        s_on_valid, s_off_valid;
    wire [6:0]  s_on_note,  s_on_vel,  s_off_note;
    wire        s_playing,  s_paused;
    wire [3:0]  s_song_index, s_song_count;
    wire        s_sustain,  s_vib_on,  s_glide_on;
    wire [6:0]  s_vib_depth, s_vib_rate, s_glide_time;
    wire [7:0]  song_elapsed_sec, song_elapsed_min, song_total_sec, song_progress_pct;
    wire [8:0]  song_note_idx;
    wire [5:0]  song_sub_scroll;
    wire [6:0]  song_active_note;

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
    wire [6:0]  m_cc_num, m_cc_val;
    wire        m_cc_any_valid;

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

    // 放歌模式下允许通过：长按板载 key1 (≥0.5s) / 外接变调键 kp_press / MIDI CC27 / 串口 '>' 或 's' 切歌
    wire song_next_cmd  = k1_long_pulse ||
                          (m_cc_any_valid && (m_cc_num == 7'd27)) ||
                          (uart_valid && !uart_data[7] && (uart_data == ">" || uart_data == "s" || uart_data == "S")) ||
                          (run_song && kp_press);
    wire song_pause_cmd = (m_cc_any_valid && (m_cc_num == 7'd26) && (m_cc_val == 7'd64)) ||
                          (uart_valid && !uart_data[7] && (uart_data == "p" || uart_data == "P"));

    song_player #(.CLK_HZ(50_000_000)) u_song (
        .clk              (clk),
        .rst_n            (rst_n),
        .sample_tick      (sample_tick),
        .key_play         (1'b0),
        .key_next         (song_next_cmd),
        .key_pause        (song_pause_cmd),
        .run_en           (run_song),
        .on_valid         (s_on_valid),
        .on_note          (s_on_note),
        .on_vel           (s_on_vel),
        .off_valid        (s_off_valid),
        .off_note         (s_off_note),
        .playing          (s_playing),
        .paused           (s_paused),
        .song_index       (s_song_index),
        .song_count       (s_song_count),
        .song_sustain     (s_sustain),
        .song_vib_on      (s_vib_on),
        .song_vib_depth   (s_vib_depth),
        .song_vib_rate    (s_vib_rate),
        .song_glide_on    (s_glide_on),
        .song_glide_time  (s_glide_time),
        .song_elapsed_sec (song_elapsed_sec),
        .song_elapsed_min (song_elapsed_min),
        .song_total_sec   (song_total_sec),
        .song_progress_pct(song_progress_pct),
        .song_note_idx    (song_note_idx),
        .song_sub_scroll  (song_sub_scroll),
        .song_active_note (song_active_note)
    );

    // ================= 乐器/效果器 CC 译码（2026-10-06 新增）=================
    //  CC20 -> 乐器选择：0=钢琴 1=吉他 3=小提琴（协议值 3 映射到内部音色槽 2）
    //  CC21 -> 挂电量（吉他效果器强度）0..127
    //  ⚠️ midi_rx 只做传输层（原样透传 0..127），语义在这里定 —— 见 AGENTS.md §4.1
    reg  [1:0] inst_sel    = 2'd0;      // ★ 上电默认钢琴（防 X）
    reg  [6:0] drive_amt   = 7'd0;
    reg  [6:0] bow_force_amt = 7'd64;
    reg  [6:0] bow_pos_amt   = 7'd64;
    reg  [1:0] fx_sel_cc   = FX_DEFAULT[1:0];
    reg  [6:0] fx_param_cc = 7'd42;     // 默认 33% 适度音乐厅混响深度，自然透气不糊音
    reg  [1:0] cab_sel_cc  = 2'd1;      // 默认 4x12 密闭箱体
    always @(posedge clk) begin
        if (!rst_n) begin
            inst_sel    <= 2'd0;
            drive_amt   <= 7'd0;
            bow_force_amt <= 7'd64;
            bow_pos_amt   <= 7'd64;
            fx_sel_cc   <= FX_DEFAULT[1:0];
            fx_param_cc <= 7'd42;
            cab_sel_cc  <= 2'd1;
        end else begin
            if ((MODE != 2) && !run_song && kp_press)
                fx_sel_cc <= fx_sel_cc + 2'd1; // 板载/外接按键循环切换 旁路/延迟/合唱/混响
            if (touch_timbre_pulse && !run_song)
                inst_sel <= (inst_sel >= 2'd3) ? 2'd0 : (inst_sel + 2'd1);
            if (touch_fx_pulse)
                fx_sel_cc <= fx_sel_cc + 2'd1;
            if (m_cc_any_valid) begin
                case (m_cc_num)
                    7'd20: inst_sel    <= m_cc_val[1:0];
                    7'd21: drive_amt   <= m_cc_val;
                    7'd22: if ((inst_sel == 2'd2) || (inst_sel == 2'd3)) bow_force_amt <= m_cc_val;
                           else fx_sel_cc <= m_cc_val[1:0];
                    7'd23: if ((inst_sel == 2'd2) || (inst_sel == 2'd3)) bow_pos_amt <= m_cc_val;
                           else fx_param_cc <= m_cc_val;
                    7'd24: cab_sel_cc  <= m_cc_val[1:0];
                    7'd91: fx_sel_cc   <= (m_cc_val >= 7'd64) ? 2'd3 : 2'd0; // MIDI 标准混响 CC91
                    7'd93: fx_sel_cc   <= (m_cc_val >= 7'd64) ? 2'd2 : 2'd0; // MIDI 标准合唱 CC93
                    default: ;
                endcase
            end
        end
    end
    // ================= S5：硬件乐器输入管理（MODE=3 新增）=================
    //  13 键 + 光电#1 + ToF#1 + EC11#1 → 串行化音符事件（≥16 clk 间距，
    //  引擎装载 FSM 实测需 14 clk）+ EC11 音量。四类输入全部实测过
    //  （hw_bringup S1/SDRAMPROBE/TOFREAD/INPUTS 固件）。所有 MODE 下都
    //  例化（与 song_player/midi_rx 同例化风格）；MODE≠3 时事件被 mux 掉，
    //  综合只保留遥测链。详细语义见 io/hw_input_mgr.v 头注释。
    wire        h_on_valid, h_off_valid, h_glide_on;
    wire [6:0]  h_on_note,  h_on_vel,  h_off_note;
    wire [6:0]  h_glide_time, h_volume;
    wire [12:0] h_key_state;
    wire [5:0]  h_photo_state;
    wire [15:0] h_tof_dist;
    wire [7:0]  h_ovf;
    wire        h_dbg_tx;

    hw_input_mgr #(
        .CLK_HZ(50_000_000),
        .QUIET ((MODE == 3) ? 2 : 1)     // MODE=3: 保留按键/光电/EC11/ToF，冻结 U15 连续串口遥测防干扰 DAC
    ) u_hwin (
        .clk        (clk),
        .rst_n      (rst_n),
        .key_raw    (key_hw),
        .photo_raw  (photo_hw),
        .ec1a_raw   (ec1a),
        .ec1b_raw   (ec1b),
        .scl_a      (scl_tof),
        .sda_a      (sda_tof),
        .dbg_tx     (h_dbg_tx),
        .ev_on_valid(h_on_valid),
        .ev_on_note (h_on_note),
        .ev_on_vel  (h_on_vel),
        .ev_off_valid(h_off_valid),
        .ev_off_note (h_off_note),
        .ev_glide_on (h_glide_on),
        .ev_glide_time(h_glide_time),
        .volume     (h_volume),
        .key_state  (h_key_state),
        .photo_state(h_photo_state),
        .tof_dist   (h_tof_dist),
        .ovf_cnt    (h_ovf)
    );

    // ---- 按 MODE 选择来源 ----
    // MODE=0：song_player；MODE=1：midi_rx；MODE=2：测试模式不使用音符总线
    // MODE=3：自由演奏时【同时融合】PC MIDI (m_*) 与硬件外设 (h_*)；按 key2 进出曲目自动播放 (s_*)
    // ★ 注意：退出曲目模式时 song_player 会进入 S_OFF/S_ALLOFF 连发 128 拍 s_off_valid，
    //   因此 s_off_valid 必须始终透传到 bus_off_valid，确保切回自由演奏时 100% 释放残留声部！
    // 触摸屏按键发声通路与控制总线
    wire        touch_on_valid;
    wire [6:0]  touch_on_note;
    wire [6:0]  touch_on_vel;
    wire        touch_off_valid;
    wire [6:0]  touch_off_note;
    wire        touch_timbre_pulse;
    wire        touch_fx_pulse;
    wire [6:0]  touch_vol_val;
    wire        touch_vol_valid;

    wire free_on_valid_w  = m_on_valid  | (source_physical & h_on_valid) | touch_on_valid;
    wire [6:0] free_on_note_w = touch_on_valid ? touch_on_note : (m_on_valid ? m_on_note : h_on_note);
    wire [6:0] free_on_vel_w  = touch_on_valid ? touch_on_vel  : (m_on_valid ? m_on_vel  : h_on_vel);
    wire free_off_valid_w = m_off_valid | (source_physical & h_off_valid) | touch_off_valid;
    wire [6:0] free_off_note_w = touch_off_valid ? touch_off_note : (m_off_valid ? m_off_note : h_off_note);

    wire bus_on_valid_c  = (MODE == 2) ? 1'b0 : (run_song ? s_on_valid   : free_on_valid_w);
    wire [6:0] bus_on_note_c = (MODE == 2) ? 7'd0 : (run_song ? s_on_note    : free_on_note_w);
    wire [6:0] bus_on_vel_c  = (MODE == 2) ? 7'd0 : (run_song ? s_on_vel     : free_on_vel_w);
    wire bus_off_valid_c = (MODE == 2) ? 1'b0 : ((run_song | s_off_valid) ? s_off_valid : free_off_valid_w);
    wire [6:0] bus_off_note_c = (MODE == 2) ? 7'd0 : ((run_song | s_off_valid) ? s_off_note  : free_off_note_w);

    // ★ 时序优化流水线寄存器：切断跨芯片长组合路径，确保 50 MHz 建立时间裕量充足
    reg        bus_on_valid_r  = 1'b0;
    reg [6:0]  bus_on_note_r   = 7'd0;
    reg [6:0]  bus_on_vel_r    = 7'd0;
    reg        bus_off_valid_r = 1'b0;
    reg [6:0]  bus_off_note_r  = 7'd0;

    always @(posedge clk) begin
        if (!rst_n) begin
            bus_on_valid_r  <= 1'b0;
            bus_on_note_r   <= 7'd0;
            bus_on_vel_r    <= 7'd0;
            bus_off_valid_r <= 1'b0;
            bus_off_note_r  <= 7'd0;
        end else begin
            bus_on_valid_r  <= bus_on_valid_c;
            bus_on_note_r   <= bus_on_note_c;
            bus_on_vel_r    <= bus_on_vel_c;
            bus_off_valid_r <= bus_off_valid_c;
            bus_off_note_r  <= bus_off_note_c;
        end
    end

    wire bus_reset_all_w = (MODE == 2) ? 1'b0 : (m_reset_all | mode_chg);
    assign bus_on_valid   = bus_on_valid_r;
    assign bus_on_note    = bus_on_note_r;
    assign bus_on_vel     = bus_on_vel_r;
    assign bus_off_valid  = bus_off_valid_r;
    assign bus_off_note   = bus_off_note_r;
    assign bus_cc_valid   = (MODE == 2) ? 1'b0  : (run_song ? 1'b0         : m_cc_valid);
    assign bus_glide_on   = (MODE == 2) ? 1'b0  : (run_song ? s_glide_on   : m_glide_on);
    assign bus_glide_time = (MODE == 2) ? 7'd0  : (run_song ? s_glide_time : m_glide_time);
    // 放歌模式：长音揉弦给弦乐（小提琴与二胡）
    assign bus_vib_on     = (MODE == 2) ? 1'b0  : (run_song ? (s_vib_on && (inst_sel_eff_r >= 2'd2)) : m_vib_on);
    assign bus_vib_depth  = (MODE == 2) ? 7'd0  : (run_song ? s_vib_depth  : m_vib_depth);
    assign bus_vib_rate   = (MODE == 2) ? 7'd50 : (run_song ? s_vib_rate   : m_vib_rate);
    // 仅钢琴支持延音踏板（吉他/提琴/二胡有各自的物理运弓/衰减机理，不受延音踏板控制）：
    assign bus_sustain    = (MODE == 2) ? 1'b0  :
                            (inst_sel_eff_r != 2'd0) ? 1'b0 :
                            (run_song ? s_sustain : m_sustain);
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
    // ---------------------------------------------------- 多音色合成引擎 ----
    wire signed [15:0] mix_piano;
    wire [7:0]         piano_active;
    wire [31:0]        piano_active32;

    generate
    if (USE_TDM32 != 0) begin : g_tdm32_engine
        // ★ 138K 满血版：32复音 × 6泛音 = 192个同时活跃可闻独立振荡器 (TDM SDPB 架构)
        piano_engine_tdm32 #(
            .N_VOICES  (32),
            .CLK_HZ    (50_000_000),
            .OUT_SHIFT (1)
        ) u_piano_tdm32 (
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
            .inst_sel   (inst_sel_eff_r),
            .bow_speed  (bow_speed_eff_r),
            .mix_out    (mix_piano),
            .active     (piano_active32)
        );
        assign piano_active = piano_active32[7:0] | piano_active32[15:8] |
                              piano_active32[23:16] | piano_active32[31:24];
    end else begin : g_par8_engine
        piano_engine #(
            .N_VOICES  (8),
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
            .inst_sel   (inst_sel_eff_r),
            .bow_speed  (bow_speed_eff_r),
            .mix_out    (mix_piano),
            .active     (piano_active)
        );
        assign piano_active32 = {24'd0, piano_active};
    end
    endgenerate

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

    // ---------------------------------------------------- 乐器琴体 EQ -------
    // 先按音色做轻量琴体/拾音器频带整形，再进入可选吉他效果器和全局空间效果。
    // 该模块只做移位加法，逐样本纯 HDL，不影响 32 声部振荡器计数。
    wire signed [15:0] mix_body;
    instrument_body_fx u_body_fx (
        .clk       (clk),
        .rst_n     (rst_n),
        .sample_tick(sample_tick),
        .sustain   (bus_sustain),
        .inst_sel  (inst_sel_eff_r),
        .bow_force (bow_force_amt),
        .bow_pos   (bow_pos_amt),
        .x         (mix_piano),
        .y         (mix_body)
    );

    // ---------------------------------------------------- 硬件效果器 -------
    // ★ 位置：混音之后、pt8211_tx 之前（集成清单 §16）
    // ★ 只在 MODE=0/1 生效；MODE=2 下被 mux 掉、综合时会整体优化掉
    //   ⇒ 保证 32 谱峰取证路径与"未加效果器时"**逐样本一致**
    // ★ 电吉他专属效果器级联（4相过载/失真 + 6相 4x12/1x12 参数化 IIR 箱体模拟）
    //   当 inst_sel_eff_r == 2'd1 (电吉他) 时自动开启过载+箱体；钢琴/小提琴档逐 bit 旁路直通
    wire signed [15:0] mix_post_guitar;
    generate
    if (EN_GUITAR_FX != 0) begin : g_guitar_fx
        // 默认按木吉他参考音色走干声，避免上电就被过载/箱体模拟染成电子吉他。
        // CC21 调到 96 以上时仍可启用电吉他效果。
        wire [1:0] g_fx_sel  = (inst_sel_eff_r == 2'd1 && bow_speed_eff_r >= 7'd96) ? 2'd1 : 2'd0;
        wire [1:0] g_cab_sel = (inst_sel_eff_r == 2'd1 && bow_speed_eff_r >= 7'd96) ? cab_sel_cc : 2'd0;
        wire [6:0] g_drive   = (bow_speed_eff_r != 7'd0) ? bow_speed_eff_r : 7'd48;
        guitar_fx u_guitar_fx (
            .clk        (clk),
            .rst_n      (rst_n),
            .sample_tick(sample_tick),
            .fx_sel     (g_fx_sel),
            .cab_sel    (g_cab_sel),
            .drive      (g_drive),
            .tone       (7'd96),
            .level      (7'd64),
            .fx_in      (mix_body),
            .fx_out     (mix_post_guitar)
        );
    end else begin : g_no_guitar_fx
        assign mix_post_guitar = mix_body;
    end
    endgenerate

    wire [1:0] fx_sel = (MODE == 0) ? FX_DEFAULT[1:0] : fx_sel_cc;
    wire signed [15:0] fx_out_l, fx_out_r, fx_out;

    audio_fx #(
        .N_FX   (3)
    ) u_fx (
        .clk        (clk),
        .rst_n      (rst_n),
        .sample_tick(sample_tick),
        .fx_sel     (fx_sel),
        .param      (fx_param_cc),
        .fx_in      (mix_post_guitar),
        .fx_out_l   (fx_out_l),
        .fx_out_r   (fx_out_r),
        .fx_out     (fx_out)
    );

    // ---------------------------------------------------- 音频输出 mux ----
    // MODE=2：纯 tone_bank（32 路恒发声，供频谱取证）
    // MODE=0/1：钢琴引擎 → 效果器
    // MODE=3：钢琴引擎 → 效果器 → EC11 音量增益（S5 新增，唯一新增乘法器）
    //   ★ 2026-10-23 S5 修复：线性 (vol/127) 曲线在 100 附近每格只有 ±0.3 dB，
    //     实测"旋转没反应"。改为 dB 感知 LUT：vol 0..127 → 0..32767，
    //     全程 -42dB..0dB，每格（4 步）≈1.32 dB，vol=0 静音、127 直通。
    //   gain = (fx_out × vol_word) >> 15；|fx_out|≤32768、vol_word≤32767
    //   ⇒ |结果|≤32767，无需饱和。MODE≠3 时乘法器被常量折叠优化掉。
    //   操作数先寄存（帮 Gowin 映射进 DSP 并切断组合路径），输出再寄存一级。
    function [15:0] vol_lut;
        input [6:0] v;
        begin
            case (v)
            7'd0: vol_lut = 16'd0;
            7'd1: vol_lut = 16'd270;
            7'd2: vol_lut = 16'd281;
            7'd3: vol_lut = 16'd292;
            7'd4: vol_lut = 16'd303;
            7'd5: vol_lut = 16'd315;
            7'd6: vol_lut = 16'd327;
            7'd7: vol_lut = 16'd340;
            7'd8: vol_lut = 16'd353;
            7'd9: vol_lut = 16'd367;
            7'd10: vol_lut = 16'd381;
            7'd11: vol_lut = 16'd396;
            7'd12: vol_lut = 16'd411;
            7'd13: vol_lut = 16'd427;
            7'd14: vol_lut = 16'd444;
            7'd15: vol_lut = 16'd461;
            7'd16: vol_lut = 16'd479;
            7'd17: vol_lut = 16'd497;
            7'd18: vol_lut = 16'd517;
            7'd19: vol_lut = 16'd537;
            7'd20: vol_lut = 16'd557;
            7'd21: vol_lut = 16'd579;
            7'd22: vol_lut = 16'd601;
            7'd23: vol_lut = 16'd625;
            7'd24: vol_lut = 16'd649;
            7'd25: vol_lut = 16'd674;
            7'd26: vol_lut = 16'd700;
            7'd27: vol_lut = 16'd728;
            7'd28: vol_lut = 16'd756;
            7'd29: vol_lut = 16'd785;
            7'd30: vol_lut = 16'd816;
            7'd31: vol_lut = 16'd847;
            7'd32: vol_lut = 16'd880;
            7'd33: vol_lut = 16'd914;
            7'd34: vol_lut = 16'd950;
            7'd35: vol_lut = 16'd987;
            7'd36: vol_lut = 16'd1025;
            7'd37: vol_lut = 16'd1065;
            7'd38: vol_lut = 16'd1106;
            7'd39: vol_lut = 16'd1149;
            7'd40: vol_lut = 16'd1194;
            7'd41: vol_lut = 16'd1240;
            7'd42: vol_lut = 16'd1288;
            7'd43: vol_lut = 16'd1338;
            7'd44: vol_lut = 16'd1390;
            7'd45: vol_lut = 16'd1444;
            7'd46: vol_lut = 16'd1500;
            7'd47: vol_lut = 16'd1558;
            7'd48: vol_lut = 16'd1619;
            7'd49: vol_lut = 16'd1681;
            7'd50: vol_lut = 16'd1747;
            7'd51: vol_lut = 16'd1814;
            7'd52: vol_lut = 16'd1885;
            7'd53: vol_lut = 16'd1958;
            7'd54: vol_lut = 16'd2034;
            7'd55: vol_lut = 16'd2113;
            7'd56: vol_lut = 16'd2195;
            7'd57: vol_lut = 16'd2280;
            7'd58: vol_lut = 16'd2369;
            7'd59: vol_lut = 16'd2461;
            7'd60: vol_lut = 16'd2556;
            7'd61: vol_lut = 16'd2655;
            7'd62: vol_lut = 16'd2758;
            7'd63: vol_lut = 16'd2865;
            7'd64: vol_lut = 16'd2976;
            7'd65: vol_lut = 16'd3092;
            7'd66: vol_lut = 16'd3212;
            7'd67: vol_lut = 16'd3337;
            7'd68: vol_lut = 16'd3466;
            7'd69: vol_lut = 16'd3601;
            7'd70: vol_lut = 16'd3740;
            7'd71: vol_lut = 16'd3886;
            7'd72: vol_lut = 16'd4036;
            7'd73: vol_lut = 16'd4193;
            7'd74: vol_lut = 16'd4356;
            7'd75: vol_lut = 16'd4525;
            7'd76: vol_lut = 16'd4700;
            7'd77: vol_lut = 16'd4883;
            7'd78: vol_lut = 16'd5072;
            7'd79: vol_lut = 16'd5269;
            7'd80: vol_lut = 16'd5474;
            7'd81: vol_lut = 16'd5686;
            7'd82: vol_lut = 16'd5907;
            7'd83: vol_lut = 16'd6136;
            7'd84: vol_lut = 16'd6374;
            7'd85: vol_lut = 16'd6621;
            7'd86: vol_lut = 16'd6878;
            7'd87: vol_lut = 16'd7145;
            7'd88: vol_lut = 16'd7423;
            7'd89: vol_lut = 16'd7711;
            7'd90: vol_lut = 16'd8010;
            7'd91: vol_lut = 16'd8321;
            7'd92: vol_lut = 16'd8644;
            7'd93: vol_lut = 16'd8979;
            7'd94: vol_lut = 16'd9328;
            7'd95: vol_lut = 16'd9690;
            7'd96: vol_lut = 16'd10066;
            7'd97: vol_lut = 16'd10456;
            7'd98: vol_lut = 16'd10862;
            7'd99: vol_lut = 16'd11284;
            7'd100: vol_lut = 16'd11721;
            7'd101: vol_lut = 16'd12176;
            7'd102: vol_lut = 16'd12649;
            7'd103: vol_lut = 16'd13140;
            7'd104: vol_lut = 16'd13650;
            7'd105: vol_lut = 16'd14179;
            7'd106: vol_lut = 16'd14730;
            7'd107: vol_lut = 16'd15301;
            7'd108: vol_lut = 16'd15895;
            7'd109: vol_lut = 16'd16512;
            7'd110: vol_lut = 16'd17153;
            7'd111: vol_lut = 16'd17818;
            7'd112: vol_lut = 16'd18510;
            7'd113: vol_lut = 16'd19228;
            7'd114: vol_lut = 16'd19975;
            7'd115: vol_lut = 16'd20750;
            7'd116: vol_lut = 16'd21555;
            7'd117: vol_lut = 16'd22391;
            7'd118: vol_lut = 16'd23260;
            7'd119: vol_lut = 16'd24163;
            7'd120: vol_lut = 16'd25101;
            7'd121: vol_lut = 16'd26075;
            7'd122: vol_lut = 16'd27087;
            7'd123: vol_lut = 16'd28138;
            7'd124: vol_lut = 16'd29230;
            7'd125: vol_lut = 16'd30364;
            7'd126: vol_lut = 16'd31543;
            7'd127: vol_lut = 16'd32767;
            default: vol_lut = 16'd0;
            endcase
        end
    endfunction

    // ---------------------------------------------------- 音量控制增益级 (EC11 与 MODE=3) ----
    reg [6:0] vol_r = 7'd127;                  // 上电满音量 127（0 dB，确保音箱响亮清晰）
    always @(posedge clk)
        if (!rst_n) vol_r <= 7'd127;
        else        vol_r <= h_volume;
    wire [15:0] vol_word = vol_lut(vol_r);
    reg signed [15:0] gain_a_l, gain_a_r;
    reg signed [15:0] gain_b;
    always @(posedge clk) begin
        if (!rst_n) begin
            gain_a_l <= 16'sd0;
            gain_a_r <= 16'sd0;
            gain_b   <= 16'sd0;
        end else begin
            gain_a_l <= $signed(fx_out_l);
            gain_a_r <= $signed(fx_out_r);
            gain_b   <= $signed(vol_word);
        end
    end
    wire signed [31:0] gain_prod_l = gain_a_l * gain_b;
    wire signed [31:0] gain_prod_r = gain_a_r * gain_b;
    reg signed [15:0] gain_out_l, gain_out_r;
    always @(posedge clk) begin
        if (!rst_n) begin
            gain_out_l <= 16'sd0;
            gain_out_r <= 16'sd0;
        end else begin
            gain_out_l <= gain_prod_l[30:15];
            gain_out_r <= gain_prod_r[30:15];
        end
    end

    wire signed [15:0] audio_mix_raw_l = (MODE == 2) ? mix_bank   :
                                         (MODE == 3) ? gain_out_l : fx_out_l;
    wire signed [15:0] audio_mix_raw_r = (MODE == 2) ? mix_bank   :
                                         (MODE == 3) ? gain_out_r : fx_out_r;
    assign audio_mix_l = audio_muted ? 16'sd0 : audio_mix_raw_l;   // ★ 第 3 道清音 (左)
    assign audio_mix_r = audio_muted ? 16'sd0 : audio_mix_raw_r;   // ★ 第 3 道清音 (右)

    // ---------------------------------------------------- 功放使能 ---------
    assign PA_EN = 1'b0;               // 低有效 ⇒ 常开

    // ---------------------------------------------------- 7寸 J14 仪器大屏 UI
    wire [1:0] lcd_work_mode = (MODE == 2) ? 2'd2 :
                               run_song    ? 2'd1 : 2'd0;
    wire       lcd_uart_tx;
    wire       lcd_init_ok;

    generate
    if (EN_LCD_J14 != 0) begin : g_lcd_j14
        lcd_subsystem_j14 u_lcd_sub (
            .clk              (clk),
            .rst_n            (rst_n),
            .sample_tick      (sample_tick),
            .audio_mix        (audio_mix_l),
            .audio_mix_r      (audio_mix_r),
            .work_mode        (lcd_work_mode),
            .timbre_sel       (inst_sel_eff_r),
            .fx_sel           (fx_sel),
            .voice_active32   (piano_active32),
            .hw_key_state     (h_key_state),
            .master_vol       ((MODE == 3) ? vol_r : 7'd100),
            .bus_on_valid     (bus_on_valid),
            .bus_on_note      (bus_on_note),
            .bus_on_vel       (bus_on_vel),
            .bus_off_valid    (bus_off_valid),
            .bus_off_note     (bus_off_note),
            .bus_reset_all    (bus_reset_all),
            .cc_any_valid     (m_cc_any_valid),
            .cc_num           (m_cc_num),
            .cc_val           (m_cc_val),
            .uart_rx_valid    (uart_valid),
            .uart_rx_byte     (uart_data),
            .page_next_pulse  (1'b0),
            .song_index       (s_song_index[2:0]),
            .song_playing     (s_playing),
            .song_progress_pct(song_progress_pct),
            .song_elapsed_sec (song_elapsed_sec),
            .song_elapsed_min (song_elapsed_min),
            .song_total_sec   (song_total_sec),
            .song_note_idx    (song_note_idx),
            .song_sub_scroll  (song_sub_scroll),
            .song_active_note (song_active_note),
            .lcd_cs           (lcd_cs),
            .lcd_rs           (lcd_rs),
            .lcd_wr           (lcd_wr),
            .lcd_rd           (lcd_rd),
            .lcd_rst          (lcd_rst),
            .lcd_db           (lcd_db),
            .lcd_dpi_bl       (lcd_dpi_bl),
            .ws_dout          (ws_dout),
            .lcd_uart_tx      (lcd_uart_tx),
            .lcd_init_ok      (lcd_init_ok),
            .tp_scl           (tp_scl),
            .tp_sda           (tp_sda),
            .tp_int           (tp_int),
            .tp_rst_n         (tp_rst_n),
            .touch_on_valid   (touch_on_valid),
            .touch_on_note    (touch_on_note),
            .touch_on_vel     (touch_on_vel),
            .touch_off_valid  (touch_off_valid),
            .touch_off_note   (touch_off_note),
            .touch_timbre_pulse(touch_timbre_pulse),
            .touch_fx_pulse   (touch_fx_pulse),
            .touch_vol_val    (touch_vol_val),
            .touch_vol_valid  (touch_vol_valid)
        );
        assign dbg_tx = lcd_uart_tx;
    end else begin : g_no_lcd_j14
        assign lcd_cs      = 1'b1;
        assign lcd_rs      = 1'b1;
        assign lcd_wr      = 1'b1;
        assign lcd_rd      = 1'b1;
        assign lcd_rst     = 1'b1;
        assign lcd_db      = 16'hzzzz;
        assign lcd_dpi_bl  = 1'b0;
        assign ws_dout     = 1'b0;
        assign lcd_uart_tx = 1'b1;
        assign lcd_init_ok = 1'b0;
        assign tp_scl      = 1'bz;
        assign tp_sda      = 1'bz;
        assign tp_rst_n    = 1'b1;
        assign touch_on_valid     = 1'b0;
        assign touch_on_note      = 7'd0;
        assign touch_on_vel       = 7'd0;
        assign touch_off_valid    = 1'b0;
        assign touch_off_note     = 7'd0;
        assign touch_timbre_pulse = 1'b0;
        assign touch_fx_pulse     = 1'b0;
        assign touch_vol_val      = 7'd100;
        assign touch_vol_valid    = 1'b0;
        assign dbg_tx      = h_dbg_tx;
    end
    endgenerate

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

    // ---------------------------------------------------- 状态与曲目演奏指引 LED (赛题拓展③/④)
    // 低有效 (0=点亮, 1=熄灭)
    reg [6:0] cur_live_note = 7'd60;
    always @(posedge clk) begin
        if (!rst_n) cur_live_note <= 7'd60;
        else if (bus_on_valid) cur_live_note <= bus_on_note;
    end

    wire [6:0] eff_note = s_playing ? song_active_note : cur_live_note;
    wire note_sounding = s_playing ? (song_active_note != 7'd0) : (piano_active != 8'd0);

    // 节拍引导与音区指引 (低有效驱动，0=点亮)
    wire led0_out = s_playing ? ~(song_sub_scroll < 6'd15) : heart[24];
    wire led1_out = ~(note_sounding && (eff_note < 7'd60));
    wire led2_out = ~(note_sounding && (eff_note >= 7'd60 && eff_note < 7'd72));
    wire led3_out = ~(note_sounding && (eff_note >= 7'd72));

    assign led[0] = (MODE == 2) ? heart[24]  : led0_out;
    assign led[1] = (MODE == 2) ? ~samp_seen : led1_out;
    assign led[2] = (MODE == 2) ? ~(&gate)   : led2_out;
    assign led[3] = (MODE == 2) ? ~act_seen  : led3_out;

    // ---------------------------------------------------- 纯硬件超低延迟与确定性无抖动统计引擎 (赛题拓展③)
    wire [15:0] hw_lat_cur_cycles;
    wire [15:0] hw_lat_min_cycles;
    wire [15:0] hw_lat_max_cycles;
    wire [15:0] hw_lat_trig_cnt;

    hw_latency_profiler u_profiler (
        .clk               (clk),
        .rst_n             (rst_n),
        .trig              (bus_on_valid),
        .sample_tick       (sample_tick),
        .cur_latency_cycles(hw_lat_cur_cycles),
        .min_latency_cycles(hw_lat_min_cycles),
        .max_latency_cycles(hw_lat_max_cycles),
        .trig_count        (hw_lat_trig_cnt)
    );

endmodule

`default_nettype wire
