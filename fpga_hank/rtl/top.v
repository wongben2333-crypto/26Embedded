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
    parameter integer MODE       = 2,
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
    localparam [19:0] DB_MAX = 20'd131071;

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
        .key_play   (key_held),      // 电平输入，边沿由 song_player 内部处理
        .key_next   (k2_db),         // 同上
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
        .reset_all  (m_reset_all)
    );

    // ---- 按 MODE 选择来源 ----
    // MODE=0：song_player；MODE=1：midi_rx；MODE=2：测试模式不使用音符总线
    assign bus_on_valid   = (MODE == 0) ? s_on_valid  : m_on_valid;
    assign bus_on_note    = (MODE == 0) ? s_on_note   : m_on_note;
    assign bus_on_vel     = (MODE == 0) ? s_on_vel    : m_on_vel;
    assign bus_off_valid  = (MODE == 0) ? s_off_valid : m_off_valid;
    assign bus_off_note   = (MODE == 0) ? s_off_note  : m_off_note;
    assign bus_cc_valid   = (MODE == 0) ? 1'b0        : m_cc_valid;
    assign bus_glide_on   = (MODE == 0) ? 1'b0        : m_glide_on;
    assign bus_glide_time = (MODE == 0) ? 7'd0        : m_glide_time;
    assign bus_vib_on     = (MODE == 0) ? 1'b0        : m_vib_on;
    assign bus_vib_depth  = (MODE == 0) ? 7'd0        : m_vib_depth;
    assign bus_vib_rate   = (MODE == 0) ? 7'd50       : m_vib_rate;
    assign bus_sustain    = (MODE == 0) ? 1'b0        : m_sustain;
    assign bus_reset_all  = (MODE == 0) ? 1'b0        : m_reset_all;

    // ---------------------------------------------------- 钢琴引擎 ---------
    wire signed [15:0] mix_piano;
    wire [7:0]         piano_active;

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
        else if (k2_press && MODE == 1) fx_sel_user <= fx_sel_user + 2'd1;
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
    assign audio_mix = (MODE == 2) ? mix_bank : fx_out;

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
