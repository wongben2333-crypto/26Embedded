// =============================================================================
//  smoke_top.v —— 「只用板子本身」的分级上板冒烟测试顶层（S0–S6）
//
//  目的：触摸/光电等交互外设尚未到货时，仅凭 Tang Mega 138K 板载资源
//        （4 个 LED + 用户按键 AB13 + 板载 PT8211 耳机口）逐级验证整条链路。
//        每一级都能被用户用【眼睛】或【耳朵】直接验收。
//
//  级号由参数 STAGE 决定（0..6）。本文件末尾为每一级各提供了一个薄封装模块
//  smoke_top_s0 … smoke_top_s6，构建脚本用 Gowin 的 -top_module 直接选级即可：
//  本文件【一字不改】地被综合，不需要 -D 宏。
//  （实测：本机 gw_sh.exe V1.9.12.04 的 set_option / add_file 都不支持
//    -define / -compile_macro / -verilog_macro 之类的宏开关，见 _smoke-test/REPORT.md）
//
//  ---+------------------------------+------------------------------------------
//  级 | 内容                          | 用户验收方式
//  ---+------------------------------+------------------------------------------
//  S0 | LED 二进制计数 + 打标脚方波     | 4 个灯在变 = 时钟活了；
//     |                              | 顺便用示波器/万用表【定位】三个打标脚
//  S1 | 按键 AB13/Y12（2.62 ms 去抖）| 按住 led[1] 亮；AB13 每按一下 led[3:2] +1；
//     |  → LED                        | 按 Y12 把计数清零（证明第 2 个键也通了）
//  S2 | 固定 440 Hz 正弦 → I2S        | 耳机里听到持续稳定的 A4（440 Hz）
//  S3 | 按键触发单音 + 【听得见】的 ADSR| 听到音"起来 → 保持 → 消失"
//  S4 | 按键循环切 4 种音色（wave_rom）| AB13 下一个音色、Y12 上一个音色，
//     |                              | led[3:2] 显示当前音色号 0..3
//  S5 | 32 复音测试模式（32 个独立谱峰）| 录音 + FFT，数出 32 根柱子
//  S6 | 延迟测量（演奏用快包络 + 打标脚）| 示波器/声卡测「按键→出声」Δt；
//     |                              | 无仪器时看 led[3]=<5 ms / led[2]=<10 ms
//
//  ===========================================================================
//  ★ 硬约束 1：单时钟域。所有逻辑都在 clk（V22, 50 MHz）上，BCK 由 pt8211_tx
//    内部的计数器派生。参考实现明确记录过：用"真位时钟"驱动逻辑会造成跨时钟域、
//    sample_tick 偶发漏采、所有相位累加器整体错位（听感是"音准飘移"而不是爆音，
//    极难排查）。本文件不引入任何第二个时钟域。
//
//  ★ 硬约束 2：采样率用整数分频。
//      fs = clk / (BCK_DIV × 16 × 32) = clk / (BCK_DIV × 512)
//      BCK_DIV = 1 → BCK = 3.125 MHz，fs = 97656.25 Hz
//    与 rtl/top.v 当前配置一致；rtl/synth/tone_bank.v 的频率字正是按
//    97656.25 Hz 折算的 —— 换 BCK_DIV 必须同步重新生成 tone_bank.v。
//
//  ★ 硬约束 3：负数 Verilog 字面量必须写 -16'sd10278，不能写 16'sd-10278。
//
//  ===========================================================================
//  ★ S3 为什么要换 ADSR 参数（实测发现，重要）
//
//    rtl/synth/adsr.v 的头部注释写「EN_DIV=8 时 ATK_SH=8 → 131 ms 爬满」，
//    rtl/top.v 的注释写「≈42 ms」。按代码实际推算【两个都不对】：
//        ATK_INC = (1<<16) >> ATK_SH = 65536>>8 = 256
//        从 0 爬到满幅需要 65536/256 = 256 个步进
//        每个步进 = EN_DIV = 8 clk
//        ⇒ 起音时间 = 256 × 8 / 50e6 = 40.96 µs  ← 不是 131 ms，也不是 42 ms
//    也就是说 top.v 当前这套参数下，包络是"瞬起瞬落"，耳朵【听不出】ADSR，
//    S3 的验收会失败。所以本文件给 S3/S4 用了慢包络（EN_DIV=64, SH=16）：
//        起音 = 65536 × 64 / 50e6 = 83.9 ms   ← 听得见"起来"
//        衰减 = 16384 × 64 / 50e6 = 21.0 ms
//        释放 = 49152 × 64 / 50e6 = 62.9 ms   ← 听得见"消失"
//    S6 反而要"正式演奏"的快包络（EN_DIV=8, SH=12）：
//        起音 655 µs / 衰减 164 µs / 释放 491 µs
//    ⚠️ adsr.v 的 ATK_SH/DEC_SH/REL_SH 必须 ≤ 16，取 ≥17 时
//       ATK_INC = (1<<16)>>17 = 0 → 电平永远爬不动（死锁）。本文件不越这条线。
//    ⚠️ 修改 adsr.v 不在本任务授权内 —— 这里只做参数选择，不改模块源码。
// =============================================================================
`default_nettype none

module smoke_top #(
    // 0..6，含义见文件头表格
    parameter integer STAGE = 0
)(
    input  wire       clk,        // V22  50 MHz 板载有源晶振
    input  wire       key,        // AB13 用户按键 Key_in[0]，板上内部上拉，按下 = 0
    input  wire       key2,       // Y12  用户按键 Key_in[1]，板上内部上拉，按下 = 0
    output wire [3:0] led,        // T18 R18 R17 P16，【低有效，驱动 0 点亮】
    output wire       HP_BCK,     // Y17  PT8211 I2S 位时钟
    output wire       HP_WS,      // AB17 PT8211 I2S 字选
    output wire       HP_DIN,     // AA16 PT8211 I2S 数据
    output wire       PA_EN,      // AB16 功放使能，【低有效】
    output wire       DBG_KEY,    // Y22  打标：按键原始电平（同步后、未去抖），按下 = 1
    output wire       DBG_GATE,   // AB21 打标：目前是否应当发声（S6 里等于去抖后 gate）
    output wire       DBG_AUDIO   // AB22 打标：音频通路已送出可闻样本（幅度过阈值）
);

    // =========================================================================
    // 0. 上电复位（约 10 ms，2^19 / 50 MHz）
    //    不依赖任何外部引脚 —— 板上的复位键引脚在 1.5V bank（F4），不碰。
    // =========================================================================
    reg [18:0] por = 19'd0;
    wire       rst_n = &por;

    always @(posedge clk)
        if (!rst_n) por <= por + 19'd1;

    // =========================================================================
    // 1. 按键输入：两级同步 + 去抖
    //
    //    同步器：key 是异步输入，先过两级 FF，避免亚稳态直接进比较器。
    //    去抖  ：key_raw（同步后、未去抖）!= key_db 时开始计数，
    //            连续 131072 clk = 2.621 ms 稳定才认账；中途抖动则计数清零。
    //            2.621 ms 足以滤掉轻触开关的机械抖动（典型 < 1 ms，极限 ~5 ms）。
    //
    //    ⚠️ 去抖时长是 S6 延迟指标的【主要贡献项】，改 DB_MAX 必须同步更新
    //       docs/上板验证指南.md 里的延迟预算表。
    // =========================================================================
    localparam [19:0] DB_MAX = 20'd131071;      // = 2^17 - 1 → 131072 clk = 2.621 ms

    reg key_meta, key_sync;
    always @(posedge clk) begin
        if (!rst_n) begin
            key_meta <= 1'b0;
            key_sync <= 1'b0;
        end else begin
            key_meta <= key;
            key_sync <= key_meta;
        end
    end
    wire key_raw = ~key_sync;                   // 按下 = 1（板上按键低有效）

    reg [19:0] db_cnt;
    reg        key_db;
    always @(posedge clk) begin
        if (!rst_n) begin
            db_cnt <= 20'd0;
            key_db <= 1'b0;
        end else if (key_raw != key_db) begin
            if (db_cnt == DB_MAX) begin
                db_cnt <= 20'd0;
                key_db <= key_raw;
            end else begin
                db_cnt <= db_cnt + 20'd1;
            end
        end else begin
            db_cnt <= 20'd0;
        end
    end

    // 去抖后的上升沿（"note-on 决定"那一拍）
    reg  key_db_d;
    always @(posedge clk) key_db_d <= key_db;
    wire key_press = key_db & ~key_db_d;

    // ---- 第 2 个用户按键 Y12（Key_in[1]）------------------------------------
    // 引脚出处：官方 Sipeed 引脚文件 tang_mega_138K_pins.cst 的 "====== Keys ======" 段：
    //     IO_LOC "Key_in[1]" Y12;   IO_PORT ... LVCMOS33 PULL_MODE=UP BANK_VCCIO=3.3
    // 与 AB13 完全同规格，同在 3.3V bank。
    // 用途：S1 里当"清零键"，S4 里当"音色回退键" ——
    //       这样只用板子就能演示【2 个独立可控维度】（赛题基础要求①）。
    reg key2_meta, key2_sync;
    always @(posedge clk) begin
        if (!rst_n) begin
            key2_meta <= 1'b0;
            key2_sync <= 1'b0;
        end else begin
            key2_meta <= key2;
            key2_sync <= key2_meta;
        end
    end
    wire key2_raw = ~key2_sync;

    reg [19:0] db2_cnt;
    reg        key2_db;
    always @(posedge clk) begin
        if (!rst_n) begin
            db2_cnt <= 20'd0;
            key2_db <= 1'b0;
        end else if (key2_raw != key2_db) begin
            if (db2_cnt == DB_MAX) begin
                db2_cnt <= 20'd0;
                key2_db <= key2_raw;
            end else begin
                db2_cnt <= db2_cnt + 20'd1;
            end
        end else begin
            db2_cnt <= 20'd0;
        end
    end

    reg  key2_db_d;
    always @(posedge clk) key2_db_d <= key2_db;
    wire key2_press = key2_db & ~key2_db_d;

    // 按键按下次数（S1 用它做"按一下灯变"；按 Y12 清零）
    reg [3:0] press_cnt;
    always @(posedge clk) begin
        if (!rst_n)           press_cnt <= 4'd0;
        else if (key_press)   press_cnt <= press_cnt + 4'd1;
        else if (key2_press)  press_cnt <= 4'd0;
    end

    // =========================================================================
    // 2. 采样节拍 + 音频数据（由各级 generate 分支驱动）
    //    pt8211_tx 只负责产生 sample_tick 与 I2S 波形，本身不含时钟域转换。
    // =========================================================================
    wire               sample_tick;
    wire signed [15:0] mix16;      // 送 DAC 的样本（各级分支驱动）
    wire [16:0]        env_mon;    // 包络电平监视（各级分支驱动）
    wire [1:0]         timbre_mon; // 当前音色号监视（各级分支驱动）

    // 慢速心跳计数器：heart[24] 每 0.335 s 翻转 → 0.671 s 周期 ≈ 1.49 Hz
    // ⚠️ 必须写初值。不写的话硬件上电是 0（配置时 FF 被置 0）没问题，
    //    但【仿真】里它会停在 x，x+1 恒为 x —— 于是心跳和下面三路定位方波
    //    在 ModelSim 里永远读不出来（本项目实测踩过：led[0] 一直是 x）。
    reg [25:0] heart = 26'd0;
    always @(posedge clk)
        if (rst_n) heart <= heart + 26'd1;

    // 打标脚定位用的三路方波（S0 用）：1.49 / 2.98 / 5.96 Hz
    reg [25:0] loc_cnt = 26'd0;
    always @(posedge clk)
        if (rst_n) loc_cnt <= loc_cnt + 26'd1;
    wire loc_slow = loc_cnt[24];   // 1.49 Hz
    wire loc_mid  = loc_cnt[23];   // 2.98 Hz
    wire loc_fast = loc_cnt[22];   // 5.96 Hz

    // =========================================================================
    // 3. 音频源（按级选择）
    // =========================================================================
    generate
    // ---------------------------------------------------------------------
    // S2 / S3 / S4 / S6：单音 440 Hz
    //   · 一个相位累加器 + wave_rom 表 0（纯正弦）
    //   · 包络恒在通路上（赛题"振荡器三要素"之一：独立相位累加器 +
    //     频率调控 + 包络控制）
    //   · S2 把 gate 恒置 1 → 包络爬到 sustain 后恒定，听感是持续音
    //   · S4 的 timbre 由按键循环切换（这就是 top.v 里 timbre_auto 没做到的事）
    // ---------------------------------------------------------------------
    if (STAGE == 2 || STAGE == 3 || STAGE == 4 || STAGE == 6) begin : g_mono
        // 440.0 Hz @ fs = 50e6/512 = 97656.25 Hz
        // 频率字 = round(440 × 2^32 / 97656.25) = 19351405  → 实际 440.0000080 Hz
        localparam [31:0] FREQ_440 = 32'd19351405;

        // 包络参数按级选择：都是 STAGE 的常量表达式，综合期折叠，不产生额外逻辑
        localparam integer ENV_EN_DIV = (STAGE == 6) ? 8  : 64;   // 每步进 clk 数
        localparam integer ENV_ATK_SH = (STAGE == 6) ? 12 : 16;   // ≤16，否则增量为 0
        localparam integer ENV_DEC_SH = (STAGE == 6) ? 12 : 16;
        localparam integer ENV_REL_SH = (STAGE == 6) ? 12 : 16;

        // S2：gate 恒 1（持续音）；其余：gate = 去抖后的按键
        wire mono_gate = (STAGE == 2) ? 1'b1 : key_db;

        // 静音时把相位冻结在 0：新音符从相位 0 起，
        //   → 起音无相位跳变（不炸响）
        //   → S6 的"gate 拉高 → 出声"延迟【每次完全一致】，可复现
        wire mono_idle = (STAGE == 2) ? 1'b0 : (env_mon == 17'd0);

        reg [31:0] ph_acc;
        always @(posedge clk) begin
            if (!rst_n) ph_acc <= 32'd0;
            else if (sample_tick) begin
                if (mono_idle) ph_acc <= 32'd0;
                else           ph_acc <= ph_acc + FREQ_440;
            end
        end

        // 音色：S4 按键循环（AB13 = 下一个，Y12 = 上一个）；其余级别锁在表 0（纯正弦）
        //   ★ 这就是 top.v 里 timbre_auto 没做到的事：top.v 是定时器自动轮换，
        //     不是用户可控。这里由真实按键驱动，且两个方向都能走。
        reg [1:0] timbre;
        always @(posedge clk) begin
            if (!rst_n)                          timbre <= 2'd0;
            else if ((STAGE == 4) && key_press)  timbre <= timbre + 2'd1;
            else if ((STAGE == 4) && key2_press) timbre <= timbre - 2'd1;
            else if (STAGE != 4)                 timbre <= 2'd0;
        end

        wire [9:0]         waddr = {timbre, ph_acc[31:24]};   // {表号, 相位[7:0]}
        wire signed [15:0] wave_val;
        wave_rom u_wave (
            .clk  (clk),
            .addr (waddr),
            .data (wave_val)
        );

        wire [16:0] env_level;
        adsr #(
            .N_VOICES  (1),
            .EN_DIV    (ENV_EN_DIV),
            .ATK_SH    (ENV_ATK_SH),
            .DEC_SH    (ENV_DEC_SH),
            .REL_SH    (ENV_REL_SH),
            .SUS_LEVEL (49152)                  // Q16 → 0.75 满幅
        ) u_env (
            .clk      (clk),
            .rst_n    (rst_n),
            .gate     (mono_gate),
            .voice_rd (5'd0),
            .level_rd (env_level),
            .phase_rd ()
        );

        // 包络增益：乘积必须【全宽形成后再移位】，否则被截断成噪声
        // （adsr.v / tone_bank.v 都记录了这条坑）
        wire signed [32:0] scaled_full = $signed(wave_val) * $signed({1'b0, env_level});
        wire signed [16:0] scaled      = scaled_full >>> 16;

        // 再算术右移 1 位 → 单音峰值约 0.375 满幅（≈ -8.5 dBFS），
        // 板载 3W 功放推到板上扬声器时不至于吵到人。
        // ⚠️ 必须写 >>> 1（算术右移），不能写 scaled[16:1] ——
        //    部分选择会丢掉符号扩展，负样本会变成正的大数（听起来是爆音）。
        assign mix16      = scaled >>> 1;
        assign env_mon    = env_level;
        assign timbre_mon = timbre;
    end
    // ---------------------------------------------------------------------
    // S5：32 路复音测试模式（等价于 rtl/top.v 的 TEST_MODE=1 通路）
    //   bench_gate(TEST_MODE=1) 把 32 路 gate 全部按住
    //   → adsr 32 路各自爬到 sustain 恒定 → 谱峰干净（不产生边带抹峰）
    //   → tone_bank 32 个独立相位累加器同时发声
    //   → 音色锁表 0（纯正弦），否则每路多个谐波会让"N 路→N 谱峰"判据误判
    // ---------------------------------------------------------------------
    else if (STAGE == 5) begin : g_test32
        wire [31:0] gate32;
        wire [4:0]  env_voice;
        wire [16:0] env_level32;

        bench_gate #(
            .N_VOICES  (32),
            .TEST_MODE (1)
        ) u_bench (
            .clk         (clk),
            .rst_n       (rst_n),
            .sample_tick (sample_tick),
            .gate        (gate32)
        );

        adsr #(
            .N_VOICES  (32),
            .EN_DIV    (8),
            .ATK_SH    (8),
            .DEC_SH    (10),
            .REL_SH    (12),
            .SUS_LEVEL (49152)
        ) u_adsr (
            .clk      (clk),
            .rst_n    (rst_n),
            .gate     (gate32),
            .voice_rd (env_voice),
            .level_rd (env_level32),
            .phase_rd ()
        );

        tone_bank #(
            // ★ 必须显式传 ROM_PARALLEL=1：
            //   tone_bank.v L52 的默认值是 32（= N_VOICES），含义是"每路例化一份
            //   独立 wave_rom"。对 138K 来说 32 份 ROM 会让【综合跑不出来】
            //   （实测：本机 S5 综合卡住数分钟不结束，而不用 tone_bank 的 S0–S4
            //     每级只要约 33 秒）。ROM_PARALLEL=1 走"时分复用一份 ROM"分支，
            //   也就是本项目原本验证过的架构。
            //   ⚠️ 这是与 tone_bank.v 的接口耦合：若上游把这个参数删掉，
            //      这里会报未知参数，需要同步改。
            .N_VOICES     (32),
            .ROM_PARALLEL (1)
        ) u_bank (
            .clk         (clk),
            .rst_n       (rst_n),
            .sample_tick (sample_tick),
            .gate_in     (gate32),
            .timbre      (2'd0),          // 测试模式必须纯正弦
            .env_voice   (env_voice),
            .env_level   (env_level32),
            .mix_out     (mix16)
        );
        assign env_mon    = env_level32;
        assign timbre_mon = 2'd0;
    end
    // ---------------------------------------------------------------------
    // S0 / S1 及任何越界级号：不出声（DAC 收全 0，静态）
    // ---------------------------------------------------------------------
    else begin : g_silent
        assign mix16      = 16'sd0;
        assign env_mon    = 17'd0;
        assign timbre_mon = 2'd0;
    end
    endgenerate

    // =========================================================================
    // 4. 是否应当发声（各级语义见注释）
    // =========================================================================
    wire sound_active = (STAGE == 0 || STAGE == 1) ? 1'b0
                      : (STAGE == 2 || STAGE == 5) ? 1'b1
                      : (key_db | (env_mon != 17'd0));

    // 音频"已可闻"检测：幅度过阈值就锁存，静音期清零。
    // 阈值 64 ≈ 满幅的 0.2%（-54 dBFS），压得很低是为了让 S6 测的是
    // "波形真的开始动"而不是"包络爬到某个高度"，把测量误差压到几个采样点。
    wire [15:0] mag = mix16[15] ? (~mix16 + 16'd1) : mix16;

    reg audio_live;
    always @(posedge clk) begin
        if (!rst_n)             audio_live <= 1'b0;
        else if (!sound_active) audio_live <= 1'b0;
        else if (mag > 16'd63)  audio_live <= 1'b1;
    end

    // =========================================================================
    // 4b. S6 零仪器自测：从【物理接触】到【DAC 收到非零样本】的 clk 数
    //
    //     为什么要有它：S6 的正规做法是示波器/声卡测两个沿的时间差，但用户
    //     可能既没有示波器也没有音频线。这里让 FPGA 自己数一遍，
    //     结果直接做成两个"合格灯"，用户按一下键就能用眼睛判读：
    //         led[3] 亮 = 本次「按键→出声」< 5 ms
    //         led[2] 亮 = 本次「按键→出声」< 10 ms（赛题基础要求②的硬指标）
    //         led[3]/led[2] 都不亮 = 超过 10 ms → 不达标，要查
    //     ⚠️ 这是【FPGA 自测】，不是独立测量：它测的是芯片内部从 key 引脚
    //        第一次出现低电平，到音频样本幅度越过阈值之间的 clk 数，
    //        包含去抖窗口，但不含 DAC 转换与扬声器/耳机的物理时间（< 1 ms）。
    //        独立测量（示波器/声卡）应当复现同一量级；两者不一致就说明
    //        测的方法有问题，而不是"FPGA 说合格就合格"。
    //
    //     计时起点选 key_raw（去抖【前】的第一次接触）而不是 key_db，
    //     这样"去抖造成的等待"也被算进延迟里 —— 那本来就是控制链路的一部分。
    // =========================================================================
    localparam [31:0] LAT_5MS  = 32'd250000;    // 5 ms  = 250000 clk @ 50 MHz
    localparam [31:0] LAT_10MS = 32'd500000;    // 10 ms = 500000 clk
    localparam [31:0] LAT_CAP  = 32'd1000000;   // 20 ms 封顶，防一次没测到就永远卡住

    reg key_raw_d;
    always @(posedge clk) key_raw_d <= key_raw;
    wire key_raw_rise = key_raw & ~key_raw_d;

    reg [31:0] lat_cnt;
    reg [31:0] lat_val;
    reg        lat_run;
    reg        lat_valid;

    always @(posedge clk) begin
        if (!rst_n) begin
            lat_cnt   <= 32'd0;
            lat_val   <= 32'd0;
            lat_run   <= 1'b0;
            lat_valid <= 1'b0;
        end else if (!lat_run) begin
            // 空闲：等下一次物理接触（只在第一次接触时重新起跑，
            // 抖动期间的后续上升沿不会把计时清零）
            if (key_raw_rise) begin
                lat_cnt <= 32'd0;
                lat_run <= 1'b1;
            end
        end else if (audio_live) begin
            lat_val   <= lat_cnt;               // 测到了
            lat_run   <= 1'b0;
            lat_valid <= 1'b1;
        end else if (lat_cnt >= LAT_CAP) begin
            lat_val   <= LAT_CAP;               // 超时（如极短轻触，gate 没建立）
            lat_run   <= 1'b0;
            lat_valid <= 1'b1;
        end else begin
            lat_cnt <= lat_cnt + 32'd1;
        end
    end

    wire lat_lt5  = lat_valid && (lat_val < LAT_5MS);
    wire lat_lt10 = lat_valid && (lat_val < LAT_10MS);

    // =========================================================================
    // 5. I2S 发送（BCK_DIV=1 → fs = 97656.25 Hz）
    //    ⚠️ 左右声道都送同一样本（单声道内容，双声道等价）。
    //    ⚠️ 这里【不是】第二个时钟域：sample_tick 只是同一时钟域下的一拍脉冲。
    // =========================================================================
    pt8211_tx #(.BCK_DIV(1)) u_dac (
        .clk         (clk),
        .reset       (~rst_n),
        .sample_l    (mix16),
        .sample_r    (mix16),
        .sample_tick (sample_tick),
        .bck         (HP_BCK),
        .ws          (HP_WS),
        .din         (HP_DIN)
    );

    // =========================================================================
    // 6. 功放使能：S0/S1 不发声 → 关掉功放，避免底噪让人误判"S2 没声音"
    // =========================================================================
    assign PA_EN = (STAGE == 0 || STAGE == 1) ? 1'b1 : 1'b0;

    // =========================================================================
    // 7. 状态 LED（低有效：led_n 的 1 表示"亮"）
    // =========================================================================
    reg [3:0] led_n;
    always @(*) begin
        if (STAGE == 0) begin
            led_n = heart[24:21];                                  // 4 位二进制计数 = 在跑
        end else if (STAGE == 1) begin
            led_n = {press_cnt[1:0], key_db, heart[24]};           // [3:2]次数 [1]按住 [0]心跳
        end else if (STAGE == 2) begin
            led_n = {1'b0, 1'b0, audio_live, heart[24]};           // [1]音频在跑 [0]心跳
        end else if (STAGE == 3) begin
            led_n = {1'b0, (env_mon != 17'd0), key_db, heart[24]}; // [2]包络非零 [1]按住
        end else if (STAGE == 4) begin
            led_n = {timbre_mon, key_db, heart[24]};               // [3:2]当前音色号
        end else if (STAGE == 5) begin
            led_n = {1'b1, 1'b1, 1'b1, heart[24]};                 // [3:1]常亮 = 32 路全开
        end else begin
            // S6：零仪器自测的合格灯（见 §4b）
            led_n = {lat_lt5, lat_lt10, key_db, heart[24]};
        end
    end
    assign led = ~led_n;

    // =========================================================================
    // 8. 打标脚（S6 用它上示波器测延迟）
    //    S0 特殊：三路脚输出 1.49 / 2.98 / 5.96 Hz 方波，
    //            让用户【不用看原理图】就能用示波器/万用表/一只 LED+电阻
    //            把这三个脚找出来，然后再跑 S6。
    // =========================================================================
    assign DBG_KEY   = (STAGE == 0) ? loc_slow : key_raw;
    assign DBG_GATE  = (STAGE == 0) ? loc_mid  : sound_active;
    assign DBG_AUDIO = (STAGE == 0) ? loc_fast : audio_live;

endmodule

`default_nettype wire


// =============================================================================
//  以下是每一级的薄封装顶层。
//  Gowin 的 -top_module 只能指定"模块名"、不能在命令行传参数，
//  而本机 gw_sh 不支持 -D 宏（已实测），所以用"每级一个封装模块"来做编译期选级。
//  本文件始终被【原样】综合，没有任何按级生成的副本。
// =============================================================================
`default_nettype none

module smoke_top_s0 (
    input  wire       clk,
    input  wire       key,
    input  wire       key2,
    output wire [3:0] led,
    output wire       HP_BCK,
    output wire       HP_WS,
    output wire       HP_DIN,
    output wire       PA_EN,
    output wire       DBG_KEY,
    output wire       DBG_GATE,
    output wire       DBG_AUDIO
);
    smoke_top #(.STAGE(0)) u (
        .clk(clk), .key(key), .key2(key2), .led(led),
        .HP_BCK(HP_BCK), .HP_WS(HP_WS), .HP_DIN(HP_DIN), .PA_EN(PA_EN),
        .DBG_KEY(DBG_KEY), .DBG_GATE(DBG_GATE), .DBG_AUDIO(DBG_AUDIO)
    );
endmodule

module smoke_top_s1 (
    input  wire       clk,
    input  wire       key,
    input  wire       key2,
    output wire [3:0] led,
    output wire       HP_BCK,
    output wire       HP_WS,
    output wire       HP_DIN,
    output wire       PA_EN,
    output wire       DBG_KEY,
    output wire       DBG_GATE,
    output wire       DBG_AUDIO
);
    smoke_top #(.STAGE(1)) u (
        .clk(clk), .key(key), .key2(key2), .led(led),
        .HP_BCK(HP_BCK), .HP_WS(HP_WS), .HP_DIN(HP_DIN), .PA_EN(PA_EN),
        .DBG_KEY(DBG_KEY), .DBG_GATE(DBG_GATE), .DBG_AUDIO(DBG_AUDIO)
    );
endmodule

module smoke_top_s2 (
    input  wire       clk,
    input  wire       key,
    input  wire       key2,
    output wire [3:0] led,
    output wire       HP_BCK,
    output wire       HP_WS,
    output wire       HP_DIN,
    output wire       PA_EN,
    output wire       DBG_KEY,
    output wire       DBG_GATE,
    output wire       DBG_AUDIO
);
    smoke_top #(.STAGE(2)) u (
        .clk(clk), .key(key), .key2(key2), .led(led),
        .HP_BCK(HP_BCK), .HP_WS(HP_WS), .HP_DIN(HP_DIN), .PA_EN(PA_EN),
        .DBG_KEY(DBG_KEY), .DBG_GATE(DBG_GATE), .DBG_AUDIO(DBG_AUDIO)
    );
endmodule

module smoke_top_s3 (
    input  wire       clk,
    input  wire       key,
    input  wire       key2,
    output wire [3:0] led,
    output wire       HP_BCK,
    output wire       HP_WS,
    output wire       HP_DIN,
    output wire       PA_EN,
    output wire       DBG_KEY,
    output wire       DBG_GATE,
    output wire       DBG_AUDIO
);
    smoke_top #(.STAGE(3)) u (
        .clk(clk), .key(key), .key2(key2), .led(led),
        .HP_BCK(HP_BCK), .HP_WS(HP_WS), .HP_DIN(HP_DIN), .PA_EN(PA_EN),
        .DBG_KEY(DBG_KEY), .DBG_GATE(DBG_GATE), .DBG_AUDIO(DBG_AUDIO)
    );
endmodule

module smoke_top_s4 (
    input  wire       clk,
    input  wire       key,
    input  wire       key2,
    output wire [3:0] led,
    output wire       HP_BCK,
    output wire       HP_WS,
    output wire       HP_DIN,
    output wire       PA_EN,
    output wire       DBG_KEY,
    output wire       DBG_GATE,
    output wire       DBG_AUDIO
);
    smoke_top #(.STAGE(4)) u (
        .clk(clk), .key(key), .key2(key2), .led(led),
        .HP_BCK(HP_BCK), .HP_WS(HP_WS), .HP_DIN(HP_DIN), .PA_EN(PA_EN),
        .DBG_KEY(DBG_KEY), .DBG_GATE(DBG_GATE), .DBG_AUDIO(DBG_AUDIO)
    );
endmodule

module smoke_top_s5 (
    input  wire       clk,
    input  wire       key,
    input  wire       key2,
    output wire [3:0] led,
    output wire       HP_BCK,
    output wire       HP_WS,
    output wire       HP_DIN,
    output wire       PA_EN,
    output wire       DBG_KEY,
    output wire       DBG_GATE,
    output wire       DBG_AUDIO
);
    smoke_top #(.STAGE(5)) u (
        .clk(clk), .key(key), .key2(key2), .led(led),
        .HP_BCK(HP_BCK), .HP_WS(HP_WS), .HP_DIN(HP_DIN), .PA_EN(PA_EN),
        .DBG_KEY(DBG_KEY), .DBG_GATE(DBG_GATE), .DBG_AUDIO(DBG_AUDIO)
    );
endmodule

module smoke_top_s6 (
    input  wire       clk,
    input  wire       key,
    input  wire       key2,
    output wire [3:0] led,
    output wire       HP_BCK,
    output wire       HP_WS,
    output wire       HP_DIN,
    output wire       PA_EN,
    output wire       DBG_KEY,
    output wire       DBG_GATE,
    output wire       DBG_AUDIO
);
    smoke_top #(.STAGE(6)) u (
        .clk(clk), .key(key), .key2(key2), .led(led),
        .HP_BCK(HP_BCK), .HP_WS(HP_WS), .HP_DIN(HP_DIN), .PA_EN(PA_EN),
        .DBG_KEY(DBG_KEY), .DBG_GATE(DBG_GATE), .DBG_AUDIO(DBG_AUDIO)
    );
endmodule

`default_nettype wire
