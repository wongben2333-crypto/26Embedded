// =============================================================================
//  top.v —— fpga_hank 顶层（测试模式：32 路并行正弦 + ADSR 包络 → I2S → PT8211）
//
//  数据通路（这就是赛题要求的基础三项 + 拓展①）：
//
//     bench_gate ──gate[32]──► adsr ──level_rd──► tone_bank ──mix──► pt8211_tx ──► DAC
//          ▲                      ▲                   │
//          │                      └── env_voice ◄──────┘
//          └── 真实演奏模式下换成「按键/触摸 → 声部分配器」
//
//  · 32 路【独立相位累加器 + 独立频率字 + 独立包络】= 每个都是一个完整振荡器
//    （赛题【振荡器统计规则】：三要素缺一不可）
//  · ADSR 真正作用在通路上（不是摆设）—— 若 gate 未使用，综合器会把 32 路包络
//    整个优化掉。实测判据：接包络前构建资源 2013 LUT / 945 FF，接上后必须增加。
//  · 全 HDL、逐样本实时合成，无任何预录 PCM / ROM 音频样本（赛题红线）
//
//  引脚：见 constr/fpga_hank.cst（已双重核对并实际参与 P&R）
//
//  ★ 复位：用上电复位计数器，不依赖外部按键引脚
//  ★ 时钟：V22 = 50 MHz 板载有源晶振（同时是 EMCCLK，P&R 会报 PR1014）
// =============================================================================
`default_nettype none

// =============================================================================
//  ★ 为什么把 TEST_MODE / BCK_DIV 改成【模块参数】而不是文件级 localparam：
//    原来它们声明在 module 之外（文件级 localparam），**testbench 无法覆盖**
//    ⇒ 结果：演奏模式（TEST_MODE=0）的交互通路**没有任何仿真验证**，
//      "基础要求① 多维交互"只有"编译通过 + 引脚约束"作证据，
//      而不是功能验证。这对一项【基础要求】来说是不够的。
//    改成参数后，testbench 可以用
//        top #(.TEST_MODE(0)) dut (...)
//    真正测到"按键 → 去抖 → gate → 包络"这条通路。
//    默认值保持 1，因此**正式构建的行为完全不变**。
// =============================================================================

module top #(
    // 1 = 测试模式（32 谱峰取证）；0 = 演奏模式（按键驱动）
    parameter integer TEST_MODE = 1,
    // 采样率：BCK_DIV=2 -> fs=48828.125 Hz；BCK_DIV=1 -> fs=97656.25 Hz
    //   两者都远低于 PT8211 的 20 MHz 位时钟上限（分别占 7.8% 与 15.6%）。
    //   ⚠️ 改这个值之后必须同步重新生成 tone_bank.v（频率字要按新采样率折算）：
    //        python tools/gen/gen_tone_bank.py --write --bck-div <同一个值>
    //      否则音高会整体偏移（96k 沿用 48.8k 的频率字会低一个八度）。
    parameter integer BCK_DIV = 1
)(
    input  wire       clk,        // V22, 50 MHz
    output wire [3:0] led,        // T18 R18 R17 P16，低有效
    output wire       HP_BCK,     // Y17  PT8211 I2S 位时钟
    output wire       HP_WS,      // AB17 PT8211 I2S 字选
    output wire       HP_DIN,     // AA16 PT8211 I2S 数据
    output wire       PA_EN,      // AB16 功放使能，低有效

    // ---------------------------------------------------- 板载用户按键 ------
    // 赛题基础要求①：≥2 个【独立可控】维度，支持选音/和弦/触发/拨弦。
    // 板载 3+1 个按键，官方引脚文件 tang_mega_138K_pins.cst 的 "====== Keys ======" 段
    // 只给出两个球号（第三个键物理存在但官方无球号映射）：
    //     Key_in[0] = AB13   LVCMOS33 / PULL_MODE=UP / BANK_VCCIO=3.3
    //     Key_in[1] = Y12    LVCMOS33 / PULL_MODE=UP / BANK_VCCIO=3.3
    //   板上已内部上拉，**按下 = 0**（低有效）。
    //   ⚠️ 不要用 F4：F4 在 1.5V bank（LVCMOS15），混进本工程全 LVCMOS33 的约束里
    //      会多一处失败可能。
    input  wire       key,        // AB13  交互维度 1：演奏触发（按住 = 32 路齐发）
    input  wire       key2,       // Y12   交互维度 2：音色切换（每按一下换一种）

    // ---------------------------------------------------- 自研变调键 --------
    // 赛题基础要求③：「支持单音实时变调」。
    // 官方按键只有两个（官方引脚文件 Keys 段只给 AB13/Y12），所以第三个控制
    // 维度用 **PMOD 排针上的一个外接按键** —— 这正是赛题要求的"自研交互形态"
    // （不买现成键盘，自己接一个按钮即可）。
    //
    // 接法：P19（PMOD 排针）与 GND 之间接一个常开按键；内部开上拉，按下 = 0
    //       （与板载按键极性一致，便于统一处理）。
    // ⚠️ 未接按键时内部上拉为高 ⇒ pitch 恒为 0（原调），不影响其它功能。
    input  wire       key_pitch   // P19   交互维度 3：变调（每按一下升 1 个半音）
);

    // ---------------------------------------------------- 上电复位 ----------
    // 约 10 ms 后释放（2^19 / 50 MHz ≈ 10.5 ms），确保配置完成、时钟稳定
    reg [18:0] por = 19'd0;
    wire       rst_n = &por;

    // 去抖时长（两个板载按键 + 自研变调键共用）：2^17 clk = 2.621 ms
    // ⚠️ 这是【控制→发声延迟的主要贡献项】，改它必须同步更新文档的延迟预算。
    localparam [19:0] DB_MAX = 20'd131071;      // 2^17-1 → 131072 clk = 2.621 ms

    always @(posedge clk)
        if (!rst_n) por <= por + 19'd1;

    // ---------------------------------------------------- 采样节拍 ----------
    wire        sample_tick;
    wire signed [15:0] mix;

    // ---------------------------------------------------- 包络通路 ----------
    wire [31:0] gate;                       // 电平敏感：1 = 该路按住
    wire [4:0]  env_voice;                  // tone_bank 扫描到的路号
    wire [16:0] env_level;                  // adsr 送回该路的包络电平

    // =========================================================================
    //  交互维度 3：变调键（PMOD P19，自研外接按键）
    //  赛题基础要求③要求「支持单音实时变调」。官方按键只有两个，所以第三个
    //  控制维度用 PMOD 排针外接一个按键 —— 这正是赛题要求的"自研交互形态"。
    //  与另两个键完全相同的两级同步 + 去抖（同一个 DB_MAX）。
    //
    //  ★ 上电默认必须是【原调】：pitch_step 初值取 8，pitch_semi = 8-8 = 0。
    //    若初值取 0 则 pitch_semi = -8（低八度），用户一开机音高就是错的。
    // =========================================================================
    reg kp_meta, kp_sync, kp_db, kp_db_d;
    reg [19:0] db_cnt3;
    always @(posedge clk) begin
        kp_meta <= key_pitch;  kp_sync <= kp_meta;
        if (!rst_n) begin
            db_cnt3 <= 20'd0;  kp_db <= 1'b0;  kp_db_d <= 1'b0;
        end else begin
            if (~kp_sync != kp_db) begin
                if (db_cnt3 == DB_MAX) begin db_cnt3 <= 20'd0; kp_db <= ~kp_sync; end
                else                        db_cnt3 <= db_cnt3 + 20'd1;
            end else db_cnt3 <= 20'd0;
            kp_db_d <= kp_db;
        end
    end
    wire kp_press = kp_db & ~kp_db_d;

    reg [3:0] pitch_step = 4'd8;                       // 8 = 原调
    always @(posedge clk)
        if (!rst_n)        pitch_step <= 4'd8;
        else if (kp_press) pitch_step <= pitch_step + 4'd1;   // 0..15 循环

    wire signed [3:0] pitch_semi = pitch_step - 4'd8;  // -8..+7 半音

    // ---------------------------------------------------- 32 路音源 ---------
    // ---------------------------------------------------- 音色选择 ---------
    // ★ 两种工作模式（赛题要求"测试模式"提供取证状态）：
    //   测试模式(TEST_MODE=1)：gate 全按住，且音色【必须】锁在表 0（纯正弦）
    //     —— 否则每路会产生多个谐波谱峰，"N 路 → N 个谱峰"的判据会被误判。
    //   演奏模式(TEST_MODE=0)：gate 由交互逻辑驱动，音色可切换（拓展②）。
    //
    // 音色由【按键 key2】切换（见下方"交互维度 1/2"块）。

    // 测试模式锁纯正弦表（否则每路多个谐波谱峰，判据会误判）；
    // 演奏模式由【按键 key2】切换 —— 这就是交互维度 2。
    // ★ timbre_user 必须在使用【之前】声明（Verilog 对 net/reg 的声明顺序敏感）。
    reg [1:0] timbre_user = 2'd0;
    wire [1:0] timbre_sel  = TEST_MODE ? 2'd0 : timbre_user;

    // ★★ ROM_PARALLEL 必须显式传 1，不能依赖默认值！★★
    //   实测教训（00:03~00:26 构建全部卡死）：
    //     tone_bank.v 的参数默认值是 32，若顶层不覆盖就会例化 32 份 wave_rom，
    //     于是并行分支生效、串行实例不存在 → **rom_val 变成无驱动网络**
    //     （综合报 WARN EX1998: Net 'rom_val[15]' does not have a driver），
    //     进而卡死在 device independent optimization 阶段，产不出 .fs。
    //   经独立核实（fpga-tools 实测 + 赛题原文比对）：
    //     ROM_PARALLEL=1 **不影响"32 个独立振荡器"的认定** ——
    //     赛题"一个振荡器"的三要素是【独立相位累加器 + 频率调控 + 包络控制】，
    //     32 个谱峰来自 32 个独立相位累加器，与"波形 ROM 有几份"无关；
    //     时分复用一份 ROM 仍算 32 个振荡器，且省资源、构建只需 ~33 秒。
    //     赛题那句"单波表采样查表不计多谐波数量，仅计单个振荡器"的宾语是
    //     「多谐波数量」，是防止靠多谐波注水的条款，推不出"1 个波表=1 个振荡器"。
    //   ⇒ 保留这个参数是为了将来有余量时再评估并行度，但**默认必须显式传 1**。
    tone_bank #(
        .N_VOICES     (32),
        .ROM_PARALLEL (1)
    ) u_bank (
        .clk        (clk),
        .rst_n      (rst_n),
        .sample_tick(sample_tick),
        .gate_in    (gate),
        .timbre     (timbre_sel),
        .pitch_semi (pitch_semi),
        .env_voice  (env_voice),
        .env_level  (env_level),
        .mix_out    (mix)
    );

    // ---------------------------------------------------- ADSR 包络 ---------
    // ★ 包络时长必须【实算】，不要照抄估算值。公式：
    //       时长 = (1<<SH) 步 × EN_DIV 拍 ÷ 50e6
    //   实测教训：原来写 EN_DIV=8 / ATK_SH=8，实算只有 40.96 µs
    //   （= 2 个采样点，fs=96 kHz），耳朵完全听不出 ADSR，
    //   而注释里却写着"≈42 ms"——差 1000 倍，且这个错数一度进了技术文档。
    //   根因：en_div_cnt 当时只有 8 位，EN_DIV 上限 255。现已参数化 DIV_W。
    adsr #(
        .N_VOICES (32),
        .EN_DIV   (512),                    // 每步 512 拍 = 10.24 µs
        .DIV_W    (16),                     // 计数器位宽，须 > $clog2(EN_DIV)
        .ATK_SH   (10),                     // 1024 步 × 10.24 µs ≈ 10.5 ms
        .DEC_SH   (10),                     //  256 步 × 10.24 µs ≈  2.6 ms
        .REL_SH   (13),                     // 从 sustain 49152 起 6144 步 × 10.24 µs ≈ 62.9 ms
                                        //（从满幅 65536 起才是 8192 步 ≈ 83.9 ms）
        .SUS_LEVEL(49152)                   // 0.75 满幅 ≈ −2.5 dB
    ) u_adsr (
        .clk       (clk),
        .rst_n     (rst_n),
        .gate      (gate),
        .voice_rd  (env_voice),
        .level_rd  (env_level),
        .phase_rd  ()
    );

    // ---------------------------------------------------- 交互维度 1/2 -----
    // =========================================================================
    //  赛题基础要求①：≥2 个独立可控维度。本工程用两个板载按键实现：
    //    维度 1（key / AB13）：演奏触发 —— 按住时 32 路振荡器同时起音，
    //                          松开后按释放斜率归零。是"乐器发不发声"的控制。
    //    维度 2（key2 / Y12）：音色切换 —— 每按一下在 4 种波形表间循环。
    //                          是"发什么音色"的控制。
    //  两者【互相独立】：在按住 key 持续发声的过程中，可以反复按 key2 换音色，
    //  音高与包络不受影响。这正是"独立可控维度"的含义。
    //
    //  ⚠️ 为什么必须做两级同步 + 去抖：
    //     按键是**异步输入**。若直接送进比较器，亚稳态会让状态机随机跳变。
    //     先过两级 FF 消除亚稳态，再用"连续 N 拍稳定才认账"滤掉机械抖动
    //     （轻触开关典型抖动 <1 ms，极限约 5 ms）。
    //  去抖时长 2^17 / 50 MHz = 2.621 ms —— 这是【控制→发声延迟的主要贡献项】，
    //  改 DB_MAX 必须同步更新文档里的延迟预算。
    // =========================================================================


    reg key_meta, key_sync, key_db;
    reg k2_meta,  k2_sync,  k2_db;
    reg [19:0] db_cnt, db_cnt2;

    always @(posedge clk) begin
        // 两级同步
        key_meta <= key;      key_sync <= key_meta;
        k2_meta  <= key2;     k2_sync  <= k2_meta;

        if (!rst_n) begin
            db_cnt  <= 20'd0;  key_db  <= 1'b0;
            db_cnt2 <= 20'd0;  k2_db   <= 1'b0;
        end else begin
            // 维度 1 去抖
            if (~key_sync != key_db) begin
                if (db_cnt == DB_MAX) begin db_cnt <= 20'd0; key_db <= ~key_sync; end
                else                        db_cnt <= db_cnt + 20'd1;
            end else db_cnt <= 20'd0;
            // 维度 2 去抖
            if (~k2_sync != k2_db) begin
                if (db_cnt2 == DB_MAX) begin db_cnt2 <= 20'd0; k2_db <= ~k2_sync; end
                else                         db_cnt2 <= db_cnt2 + 20'd1;
            end else db_cnt2 <= 20'd0;
        end
    end

    // 维度 1：按下 = 1，电平敏感（按住持续发声）
    wire key_held = key_db;

    // 维度 2：取上升沿，按一下换一次音色
    reg  k2_db_d;
    always @(posedge clk) k2_db_d <= k2_db;
    wire k2_press = k2_db & ~k2_db_d;

    // （交互维度 3 的变调逻辑已上移到 tone_bank 例化之前，见上方）


    // timbre_user 已在上方声明；这里只做更新。
    always @(posedge clk)
        if (!rst_n)              timbre_user <= 2'd0;
        else if (k2_press)       timbre_user <= timbre_user + 2'd1;   // 0→1→2→3→0

    // ---------------------------------------------------- 测试演奏产生器 ----
    // ⚠️ 真实演奏模式下，把这里换成「电容触摸/光电/压力 → 按键扫描 → 声部分配器」，
    //    输出同样接到 gate 上即可，ADSR 与合成引擎都不用改。
    wire [31:0] gate_bench;
    bench_gate u_bench (
        .clk        (clk),
        .rst_n      (rst_n),
        .sample_tick(sample_tick),
        .gate       (gate_bench)
    );

    // ★ 测试模式 vs 演奏模式：
    //   测试模式(TEST_MODE=1)：gate 全部按住（由 bench_gate 提供），
    //     目的是得到**恒定增益**下的干净频谱，供"32 路 → 32 个独立谱峰"取证。
    //   演奏模式(TEST_MODE=0)：gate 由【按键】驱动 —— 这才是真实的乐器行为，
    //     也是基础要求①的"≥2 个独立可控维度"。
    assign gate = TEST_MODE ? gate_bench : {32{key_held}};

    // ---------------------------------------------------- I2S 发送 ---------
    pt8211_tx #(.BCK_DIV(BCK_DIV)) u_dac (
        .clk        (clk),
        .reset      (~rst_n),
        .sample_l   (mix),
        .sample_r   (mix),
        .sample_tick(sample_tick),
        .bck        (HP_BCK),
        .ws         (HP_WS),
        .din        (HP_DIN)
    );

    // ---------------------------------------------------- 功放使能 ---------
    assign PA_EN = 1'b0;                    // 低有效

    // ---------------------------------------------------- 状态 LED ---------
    // 低有效（驱动 0 点亮）。四个灯分别指示四项"活着的证据"：
    //   led[0] 心跳：分频计数高位 → 闪烁说明逻辑在跑
    //   led[1] 采样帧在流动
    //   led[2] 有音符在发声（任一 gate 高）
    //   led[3] 有包络在非静音阶段（说明 ADSR 真的在工作）
    reg [25:0] heart = 26'd0;
    always @(posedge clk)
        if (rst_n) heart <= heart + 26'd1;

    reg samp_seen = 1'b0;
    reg env_live  = 1'b0;
    always @(posedge clk) begin
        if (!rst_n) begin
            samp_seen <= 1'b0;
            env_live  <= 1'b0;
        end else begin
            if (sample_tick) samp_seen <= 1'b1;
            if (env_level != 17'd0) env_live <= 1'b1;
        end
    end

    assign led[0] = heart[24];              // 闪烁 = 在跑
    assign led[1] = ~samp_seen;             // 亮 = 采样帧在流动
    assign led[2] = ~(|gate);               // 亮 = 有音符按住
    assign led[3] = ~env_live;              // 亮 = 包络已工作过

endmodule

`default_nettype wire
