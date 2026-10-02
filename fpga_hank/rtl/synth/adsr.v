// =============================================================================
//  adsr.v —— N 路并行 ADSR 包络发生器（电平敏感 gate）
//
//  赛题要求"ADSR 包络调控"，且【振荡器统计规则】把"包络控制"列为构成一个
//  振荡器的三个必要条件之一（独立相位累加器 + 频率调控 + 包络控制）。
//  因此 32 路每一路都必须有自己的包络状态与电平。
//
//  ===========================================================================
//  ★★ 最关键的接口语义：gate 是【电平】不是脉冲 ★★
//
//  这是本模块第一版最大的设计错误：把 gate 当成单拍脉冲，于是"释放"只发生
//  一拍、电平只减一个步长就停住 —— 实测症状是 note_off 之后电平停在 49152
//  不动（释放需要几千个步进，而 gate 只高了一拍）。
//
//  正确语义（与真实乐器一致）：
//     gate[v] 高 = 该声部按键【按住】
//        · 上升沿（0→1）：起音，电平从 0 开始按 ATK 斜率爬升
//        · 保持高：爬到顶后按 DEC 斜率降到 SUS_LEVEL，然后保持
//     gate[v] 低 = 按键【松开】
//        · 从高变低那一刻起按 REL 斜率下降；降到 0 后回 IDLE（声部可被回收）
//
//  ===========================================================================
//  ★ 设计取向：为什么是"并行推进"而不是参考实现那样的"时分层叠"
//
//  参考实现 vdalex/tangmega-138k-fpga-projects 的 synth8.v 用时分走查（walk），
//  因为它在 150 MHz 下每个采样点只有 3072 拍、要服务 8 个声部，且共享昂贵的
//  乘法器与波表。本设计预算不同：50 MHz / 48828 Hz = 1024 拍/采样点，
//  32 路各做一次 17 bit 加减完全放得下，且并行推进没有"扫描索引对齐"问题 ——
//  本项目在 tone_bank 的 ROM 地址 MUX 上正是一次索引对齐错误导致某一路被
//  多读、增益偏 9.5 dB。所以包络这里刻意选并行。
//
//  ⚠️ 但仍遵守参考实现记录的硬约束：每声部数组只能有一个写语句。
//     从多处写同一数组会被推断成双口 block RAM，然后工具报一个关于 DPB
//     写模式的莫名其妙错误，而不是"这应该是触发器"。
//
//  电平格式：17 bit 无符号 Q16，0 = 静音，1<<16 = 满幅。
//           与波形相乘时 a = wave * env >> 16。
//           ⚠️ 乘积必须【全宽形成后再移位】，否则被截断成噪声
//           （参考实现踩过并记录：听起来就完全是噪声）。
//
//  ★ 时长必须【实算】：时长 = (1<<SH) 步 × EN_DIV 拍 ÷ clk
//    默认 EN_DIV=512、clk=50 MHz（每步 10.24 µs）：
//        ATK_SH=10 → 1024 步 ≈ 10.5 ms  （起音，听得见但跟手）
//        DEC_SH=10 →  256 步 ≈  2.6 ms  （衰减）
//        REL_SH=13 → 6144 步 ≈ 62.9 ms  （释放；从 sustain 49152 往下降）
//                   8192 步 ≈ 83.9 ms  （若从满幅 65536 起降，才是这个值）
//    ⚠️ 历史坑：注释曾写"ATK_SH=8 → 131 ms"，实际按当时 EN_DIV=8 只有
//       40.96 µs（2 个采样点），耳朵完全听不出包络。原因是 en_div_cnt
//       当时只有 8 位、EN_DIV 上限 255。现已把位宽参数化为 DIV_W。
//    ⚠️ 改 EN_DIV 后必须同时确认 DIV_W > $clog2(EN_DIV)。
// =============================================================================
`default_nettype none

module adsr #(
    parameter integer N_VOICES  = 32,
    parameter integer LEVEL_W   = 17,
    // ★ EN_DIV 的【可调范围】由 DIV_W 决定，不要照抄参考值就以为时间对：
    //   EN_DIV 只有 8 位时最大 255，包络最快只能到毫秒级，
    //   结果是"瞬起瞬落"、耳朵完全听不出 ADSR（本项目实测过：
    //   EN_DIV=8 + ATK_SH=8 → 起音仅 40.96 µs = 2 个采样点）。
    //   参数化位宽后可以取 EN_DIV=512 等值，让各段落在可听范围。
    //   各段实际时长 = (1<<SH) 步 × EN_DIV 拍 ÷ clk。
    parameter integer EN_DIV    = 512,          // 每个速率步进占用的 clk 数
    parameter integer DIV_W     = 16,           // en_div_cnt 位宽，须 > $clog2(EN_DIV)
    parameter integer ATK_SH    = 10,           // 起音：65536>>ATK_SH 步
    parameter integer DEC_SH    = 10,           // 衰减
    parameter integer REL_SH    = 13,           // 释放（与 top.v 生产配置对齐；默认 11 会与生产不符）
    parameter integer SUS_LEVEL = 49152         // Q16，0.75 满幅 ≈ -2.5 dB
)(
    input  wire               clk,
    input  wire               rst_n,

    // 电平敏感 gate：1 = 该声部按住，0 = 松开
    input  wire [N_VOICES-1:0] gate,

    // 遍历读端口（调用方扫 voice_rd 取电平）
    input  wire [4:0]         voice_rd,
    output wire [LEVEL_W-1:0] level_rd,
    output wire [1:0]         phase_rd
);

    localparam [1:0] P_IDLE = 2'd0, P_ATK = 2'd1, P_DEC = 2'd2, P_SUS = 2'd3;

    reg [LEVEL_W-1:0] en_level [0:N_VOICES-1];
    reg [1:0]         en_phase [0:N_VOICES-1];

    assign level_rd = en_level[voice_rd];
    assign phase_rd = en_phase[voice_rd];

    // ---------------------------------------------------------- 速率与步长 ----
    localparam integer ATK_INC = (1 << 16) >> ATK_SH;
    localparam integer DEC_INC = (1 << (LEVEL_W - 1)) >> DEC_SH;
    localparam integer REL_INC = (1 << (LEVEL_W - 1)) >> REL_SH;

    // ★ 位宽必须 >= $clog2(EN_DIV)+1，否则 EN_DIV 大于计数器满量程时
    //   en_step 永不成立 → 电平永远不动（与下面那个复位坑的后果一样）。
    reg [DIV_W-1:0] en_div_cnt;
    wire            en_step = (en_div_cnt == EN_DIV[DIV_W-1:0] - 1'b1);

    // ⚠️ 这个 always 必须带复位。曾经漏掉 rst_n 判断，
    //    结果 en_div_cnt 一直是 x → en_step 恒为 x → 电平永远不动。
    always @(posedge clk) begin
        if (!rst_n)       en_div_cnt <= {DIV_W{1'b0}};
        else if (en_step) en_div_cnt <= {DIV_W{1'b0}};
        else              en_div_cnt <= en_div_cnt + 1'b1;
    end

    // ------------------------------------------------------- 并行推进 --------
    genvar g;
    generate
    for (g = 0; g < N_VOICES; g = g + 1) begin : per_voice
        wire [LEVEL_W-1:0] cur = en_level[g];
        wire [1:0]         cph = en_phase[g];
        wire               g_on = gate[g];

        // 攻击增量（防止越过满幅）
        wire [LEVEL_W-1:0] atk_next =
            (cur + ATK_INC[LEVEL_W-1:0] >= 17'h1_0000)
            ? 17'h1_0000 : (cur + ATK_INC[LEVEL_W-1:0]);
        wire atk_done = (cur + ATK_INC[LEVEL_W-1:0] >= 17'h1_0000);

        // 衰减增量（降到 SUS 为止）
        wire [LEVEL_W-1:0] dec_next =
            (cur <= SUS_LEVEL[LEVEL_W-1:0] + DEC_INC[LEVEL_W-1:0])
            ? SUS_LEVEL[LEVEL_W-1:0] : (cur - DEC_INC[LEVEL_W-1:0]);
        wire dec_done = (cur <= SUS_LEVEL[LEVEL_W-1:0] + DEC_INC[LEVEL_W-1:0]);

        // 释放增量（降到 0 为止）
        wire [LEVEL_W-1:0] rel_next =
            (cur <= REL_INC[LEVEL_W-1:0]) ? 17'd0 : (cur - REL_INC[LEVEL_W-1:0]);
        wire rel_done = (cur <= REL_INC[LEVEL_W-1:0]);

        always @(posedge clk) begin
            if (!rst_n) begin
                en_level[g] <= {LEVEL_W{1'b0}};
                en_phase[g] <= P_IDLE;
            end else begin
                // ================= 相位机 =================
                // 优先级：gate 下降(release) > gate 上升(attack) > 阶段自推进
                if (!g_on && (cph != P_IDLE)) begin
                    // 松开：按 release 下降，降到 0 才回 IDLE
                    if (en_step && rel_done) en_phase[g] <= P_IDLE;
                end else if (g_on && (cph == P_IDLE)) begin
                    en_phase[g] <= P_ATK;                  // 上升沿：起音
                end else if (g_on) begin
                    if ((cph == P_ATK) && en_step && atk_done)      en_phase[g] <= P_DEC;
                    else if ((cph == P_DEC) && en_step && dec_done)  en_phase[g] <= P_SUS;
                end

                // ================= 电平 =================
                if (!g_on && (cph != P_IDLE)) begin
                    if (en_step) en_level[g] <= rel_next;
                end else if (g_on && (cph == P_IDLE)) begin
                    en_level[g] <= {LEVEL_W{1'b0}};        // 新音符从 0 起
                end else if (g_on && en_step) begin
                    case (cph)
                        P_ATK: en_level[g] <= atk_next;
                        P_DEC: en_level[g] <= dec_next;
                        P_SUS: en_level[g] <= SUS_LEVEL[LEVEL_W-1:0];
                        default: ;
                    endcase
                end
            end
        end
    end
    endgenerate

endmodule

`default_nettype wire
