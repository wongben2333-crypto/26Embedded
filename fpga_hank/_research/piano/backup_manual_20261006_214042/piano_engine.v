// =============================================================================
//  piano_engine.v —— 纯硬件钢琴音色引擎（8 声部 × 6 个独立泛音加法分量）
//
//  赛题：2026 高云杯 FPGA 创新设计赛道 · 选题二「实时多音色合成电子乐器引擎」
//        用户要求「要模仿钢琴的音调、音色」。
//
//  ===========================================================================
//  ★ 为什么用「加法合成 + 每泛音独立包络」，而不是查一张钢琴波表
//
//  查一张单周期波表只能得到固定的谐波比例，而且【不可能有非谐性】：
//  周期波形按定义所有分量都是基频的整数倍。真实钢琴最关键的两个特征
//  恰恰不在整数倍上：
//     · 高次泛音比整数倍略高（钢弦刚度 → inharmonicity，"温暖感"来源之一）
//     · 各泛音衰减速度不同（高次先死）；力度越大高次越强（"变亮"）
//  所以本引擎给每个泛音【独立相位累加器 + 独立频率 + 独立包络】——
//  这同时就是赛题【振荡器统计规则】里"一个完整振荡器"的三要素。
//  8 声部 × 6 泛音 = 48 个可独立计数的加法分量（单音即可满足拓展①的"≥32 路"）。
//
//  ---------------------------------------------------------------------------
//  ★ 技术依据（全部来自公开实现，不是拍脑袋）
//
//  1) AMY 的加法钢琴  https://github.com/shorepine/amy
//     说明页 https://shorepine.github.io/amy/piano.html
//     · 每个泛音一个独立振荡器、各自一条包络 —— 本引擎同构
//     · 高次泛音衰减更快；音越高衰减越快
//     · 力度→变亮：实测基频 +25 dB、第 20 次泛音 +45 dB
//       ⇒ 本引擎把 ≈20 dB 的"相对提亮"做成每个泛音自己的 K[n] 系数
//     · 非谐性 f_n = n·f0·sqrt(1+B·n²)，中音区 B≈0.0004
//     · 起音处还有一段宽带 "clunk"（琴槌噪声）—— AMY 没保留，本引擎补上
//
//  2) Faust STK 击弦钢琴  faust/examples/physicalModeling/faust-stk/piano1.dsp
//     · detuningHz 表：同音多弦失谐拍频只有 0.003 Hz(低音) → 0.25 Hz(中音)
//       → 1.0 Hz(高音)。⚠️ 是"零点几 Hz 的拍频"，不是固定 0.1% 频率偏移
//     · 琴槌 = 白噪声过 4 级一阶低通，系数随力度变（力度大→更亮）
//     · releaseLoopGain 0.865..0.997：松键后阻音器让声音快速消失
//
//  3) 同队参考 26Embedded/fpga_spark/.../piano_voice.v
//     · 双弦失谐 + 1:0.5:0.25 谐波权重 + 三级包络的思路可学
//     · ⛔ 但它把采样率写死 48 kHz（我们是 97656.25 Hz），且用 $readmemh 读
//       外部 .hex（文件缺失 ⇒ ROM 全 0、完全静音、极难排查）。
//       本引擎全部改成按真实 fs 生成的 case 常量表，且所有乘法/状态更新都
//       在 sample_tick 门控内（参考实现漏了门控，每 20 ns 白算一次）。
//
//  ---------------------------------------------------------------------------
//  ★ 数据通路（逐样本、逐声部并行；每采样点 512 clk 预算，实际只用 ~14 拍装载）
//
//    note-on ─► 声部分配（同音重击 > 空闲 > 已松开 > 轮转抢占）
//                 │
//                 └─► 装载 FSM（2 拍/泛音，共 14 拍）算 6 个泛音的
//                       inc[n] = n·f0 + (f0>>st1) + (f0>>st2)      ← 非谐性拉伸
//                       env[n] = amp[n]·vel_gain·(1 + K[n]·vel/4096) ← 力度变亮
//
//    每声部 6 条并行链（n = 0..5）：
//        ph[n] (32 bit) ──► piano_sin_rom（1/4 波表 + 象限折叠）──┐
//        env[n] (32 bit Q32，增益 = env[31:16]) ─────────────────►× ─► prod[n]
//                                                                 │
//        6 路相加 ─► × 齐奏拍频系数（1 个 LFO）─► + 琴槌噪声 ─► vout
//                                                                 │
//    8 个 vout 相加 ─► 预缩放 ─► 软膝限幅 ─► mix_out (16 bit)
//
//  ★ 包络形状 =「快起音 + 长衰减，没有 sustain 平台」
//    钢琴按住键也在衰减（阻尼器只在松键时落下）：
//      按住：env -= env >> s_ring[n]，时间常数 τ = 2^(s_ring+k)/fs
//      松开：env -= env >> s_damp[n]，≈ τ/32，模拟阻音器
//      k = clamp((90-note)>>4, 0, 3)：音越高衰减越快
//      ⇒ A4 基频 τ≈5.4 s、高音 C6 τ≈2.7 s、低音 C2 τ≈21 s
//    ⚠️ 包络必须是 32 bit（Q32）而不是 17 bit：用 "env -= env>>s" 做指数衰减时
//      可表示的尾部动态范围只有 W-s bit。若 W=17、s=15（想要 τ≈5 s），
//      衰减会在 env=2^15（仅 -12 dB）处【卡住不动】——听感是"音一直不停"。
//      32 bit 时尾部动态范围 > 72 dB，衰减能真正走到听不见才归零。
//    ⚠️ 音高相关的衰减不用"变移位器"（48 路变移位器 ≈ 6000 LUT），
//      而是用【每 2^k 个采样点更新一次】实现：移位量仍是常数（纯布线），
//      代价只是每声部一个 10 bit 掩码比较。
//
//  ★ 齐奏失谐（detuned unison）：真实钢琴一个音有 1~3 根弦微失调。
//    两根等幅弦 sin(f)+sin(f+δ) 的严格恒等式是 sin(f)·2cos(πδt)，
//    三根弦 ⇒ 幅度按 (2+cos)/3 起伏（拍频取自 Faust 的 detuningHz 表）。
//    ⚠️ 本实现把整个声部乘同一个拍频系数 ⇒ 对【基频】严格成立，
//      对高次泛音是近似（真实弦是 n·δ 的拍频）。这是为省 48 个累加器做的取舍。
//    ⚠️ 取 (2+cos)/4 而不是 /3：只是整体电平换一个常数（已在幅度系数里补偿），
//      但把除法变成 >>2 —— 纯移位，不需要除法器。
//      又因为真实三弦幅度并不相等，所以拍频取不到"全深零点"（1/3..1 ⇒ 这里
//      0.25..0.75），听感是温润的慢起伏，而不是忽大忽小的颤音。
//
//  ★ 琴槌瞬态：每声部一个 32 bit LFSR 噪声 → 一阶低通（档位随力度）
//    → 快速衰减包络（τ≈10.5 ms）。宽带"咔"声正是钢琴起音的特征。
//
//  ===========================================================================
//  ★ 表情（赛题拓展②）：力度 / 颤音 / 滑音 / 延音踏板
//
//  力度已经有（vel30→vel120 高次泛音 +6.34 dB）。另外三维的**精确映射公式**：
//
//  ① 颤音 Vibrato（vib_on / vib_depth=CC77 或 CC1 / vib_rate=CC76）
//       LFO 频率     f_lfo  = vib_rate × 0.1 Hz        （0→0，50→5.0 Hz，127→12.7 Hz）
//       调制度       f_inst = f_note × (1 + sin(2π f_lfo t) × depth_k/65536)
//       深度         depth_k = vib_depth × 15  (Q16 分数)
//                    ⇒ vib_depth 0..127 → ±0 .. ±2.907 % → ±0 .. ±49.6 cent（线性）
//       实现         逐采样点改【基频字】，再用同一套非谐性拉伸重算 6 个泛音增量
//                    ⇒ 所有泛音按同一比例平移，音程关系不变（这是"颤音"不是"走音"）
//       ⚠️ vib_on=0 或 vib_depth=0 ⇒ 完全不调制（相位通路切回原 inc[]，无残余抖动）
//
//  ② 滑音 Glide / Portamento（glide_on=CC65≥64 / glide_time=CC5）
//       时长         t_glide = glide_time × 4 ms       （0→立即跳变，127→508 ms）
//       步进         step = (f_target − f_current) / N，N = round(t_glide × fs)
//                    RTL 里用 recip = round(2^32/N) 查表 ⇒ step = (delta × recip) >> 32
//       ramp         每采样点 f0_cur += step，到位锁死；插值在【相位增量】一侧，
//                    频率连续变化，不会爆音
//       分配         开了滑音后，新音符一律交给"最近用过的声部"
//                    ⇒ 经典单音 portamento；此时不再叠加复音（已在报告写明）
//       ⚠️ 滑音续接时【不】把相位归零（否则滑音起点会"咔"一声）
//       ⚠️ glide_on=0 或 glide_time=0 ⇒ 立即跳变（与加表情前一致）
//
//  ③ 延音踏板 Sustain（CC64）
//       sustain=1 时收到 note-off：只置"待释放"标记，**不落阻尼器**（声部继续响）
//       sustain 由 1→0：把所有"待释放"的声部一次性释放
//       ⚠️ sustain=0 时行为与加踏板之前完全一致
//
//  ★★ 回归保证（加表情不许改变原有声音）★★
//     6 个新输入全 0 时：vib_act=0、gliding=0 ⇒ 相位增量走【原来的 inc[] 通路】
//     （`inc_use = pmod_act ? inc_vib : inc`），note-off 走原来的 gate_r<=0。
//     即：不是"应该一样"，而是**结构上就是同一条通路**。
//     已用"改前/改后同一激励序列逐样本比对"验证（见 sim/tb/tb_piano_engine.v 与
//     _research/piano/evidence/ref_before/）。
//
//  ===========================================================================
//  接口契约（与 song_player / midi_rx 共用同一套语义，签名不可改）
//    on_valid/on_note/on_vel  : note-on 单拍脉冲；⚠️ vel=0 按 MIDI 惯例当 note-off
//    off_valid/off_note       : note-off 单拍脉冲
//    mix_out                  : 16 bit 有符号混音（与 32 路振荡器组相加前）
//    active[N_VOICES-1:0]     : 每个声部是否在发声（LED）
//    表情输入（新增，全默认 0 时行为与之前逐样本一致）
//      glide_on / glide_time[6:0] / vib_on / vib_depth[6:0] / vib_rate[6:0] / sustain
//
//  ⚠️ 采样率：fs = CLK_HZ/512 = 97656.25 Hz（top.v 的 BCK_DIV=1）。
//     所有频率字 / 包络速率 / 拍频都由 tools/gen/gen_piano_rom.py 按该 fs 生成。
//     CLK_HZ 参数仅用于说明；改采样率必须重跑生成脚本。
//  ⚠️ N_VOICES 取 1..16（声部分配用 4 bit 选择器）。
//  ⚠️ 装载期间（14 拍 ≈ 0.28 µs）忽略新的 note-on：人手/串口不可能这么快，
//     这样就不需要"半个包络"的中间态，逻辑最简单也最不会出错。
// =============================================================================
`default_nettype none

module piano_engine #(
    parameter integer N_VOICES  = 8,          // 复音数（1..16）
    parameter integer CLK_HZ    = 50_000_000, // 说明用；频率字按 fs=97656.25 Hz 生成
    parameter integer OUT_SHIFT = 1           // 输出预缩放右移（0 更响、和弦更易触限幅）
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_tick,   // 音频采样节拍（97 656.25 Hz），别的模块提供

    // ---- 音符命令总线 ----
    input  wire        on_valid,      // note-on 脉冲（1 个 clk）
    input  wire [6:0]  on_note,       // MIDI 音符号 0..127（69 = A4 = 440 Hz）
    input  wire [6:0]  on_vel,        // 力度 0..127
    input  wire        off_valid,     // note-off 脉冲
    input  wire [6:0]  off_note,

    // ---- 表情输入（赛题拓展②：力度已有；这里补颤音/滑音/延音踏板）----
    //  ⚠️ 6 个新输入全为默认（0）时，输出必须与加表情之前【逐样本一致】。
    //     实现上是结构性保证：vib_act/gliding 都为 0 时，相位增量走的是原来的
    //     inc[] 寄存器通路（见 piano_voice 里的 inc_use 选择），没有任何舍入差异。
    input  wire        glide_on,      // CC65 ≥64：开启滑音
    input  wire [6:0]  glide_time,    // CC5  0..127 → t ≈ v×4 ms
    input  wire        vib_on,        // 深度>0 即开
    input  wire [6:0]  vib_depth,     // CC77 或 CC1
    input  wire [6:0]  vib_rate,      // CC76 0..127 → f ≈ v×0.1 Hz
    input  wire        sustain,       // CC64 ≥64：延音踏板
    input  wire [1:0]  inst_sel,      // ★ 多乐器（2026-10-06）：0=钢琴 1=电吉他 2=古筝
    input  wire [6:0]  bow_speed,     // ★ CC21 弓速 0..127（二胡用；0 ⇒ 固定中速兜底 64）
                                      //   全局切换（8 声部同一乐器）；只影响【新的音符】——
                                      //   系数在 note-on 装载期被采样，正在发声的音符保持原音色。
                                      //   ⚠️ 未接时（z/x）会落到 default 分支 = 钢琴，
                                      //      但仿真里 z 会传播 ⇒ TB 与 top.v 都必须显式接 2'd0。

    // ---- 输出 ----
    output reg  signed [15:0]  mix_out,   // 混音输出（与 32 路振荡器组相加前）
    output wire [N_VOICES-1:0] active     // 每个声部是否在发声（给 LED 用）
);

    // ---------------------------------------------------------------- 常量 ----
    localparam integer N_PART  = 6;      // 每声部泛音分量数
    localparam integer PHASE_W = 32;     // 相位累加器位宽
    localparam integer ENV_W   = 32;     // 包络位宽（Q32；增益 = env[31:16]）
    // ⚠️ SEL_W 只在 N_VOICES>16（如 20/32）时才加宽到 5 bit
    //    ⇒ N<=16（含默认 8）时【位宽与逻辑完全不变】，不动已验证的通路
    localparam integer SEL_W   = (N_VOICES > 16) ? 5 : 4;
    localparam integer DIV_W   = 10;     // 包络降速计数器位宽

    // 琴槌：最大增益 0.30(Q16)，包络衰减移位 10 ⇒ τ = 2^10/fs ≈ 10.5 ms
    localparam [16:0]  HAM_GAIN_Q16 = 17'd19661;
    localparam integer HAM_SH       = 10;

    // 输出软膝限幅拐点：|x| > KNEE 后按 1/4 斜率压缩，避免和弦硬削顶（刺耳）
    localparam signed [27:0] KNEE = 28'sd24576;

    // ------------------------------------------------------- 音符/力度查表 ----
    // 组合逻辑，只在 note-on 那一拍被采样（因此没有额外时序代价）
    wire [31:0] f0_bus;
    wire [31:0] beat_bus;
    wire [16:0] vel_gain_bus;
    wire [2:0]  vel_lp_bus;

    // ------------------------------------------------------- 多乐器（2026-10-06）----
    //  乐器级参数：激励增益 + 衰减档位偏移。**全局**（8 声部同乐器）。
    //  ⚠️ 这两个值只在【装载期】被采样 ⇒ 切换乐器只影响新音符（批准的语义）。
    wire [16:0] inst_ham_gain;
    wire [1:0]  inst_ksh_enc;
    // ★ 乐器下标映射（2026-10-06，Lead 批准的最小改法）
    //   语义：0=钢琴、1=电吉他、**2 或 3 = 第三个乐器槽**（原古筝，已由二胡替换）。
    //   ⚠️ 为什么 2 和 3 都映射到 2：
    //     ① GUI 发的是 **CC20=3**（v44-erhu-swap）⇒ 必须接受 3，否则 F3【切到二胡听到钢琴】✗
    //     ② ROM 仍是 3 行（0/1/2），**不必加行**；旧测试用 2、GUI 用 3 都能工作 ⇒ 兼容
    //     ③ 这样【没有任何合法 inst_sel 会落到"意外分支"】（0/1/2/3 全覆盖）
    //   ⚠️ 下标而不是端口语义：`inst_ok` 只用于三个查表实例，改这一处即可。
    wire [1:0]  inst_ok = (inst_sel == 2'd1) ? 2'd1 :
                          ((inst_sel == 2'd2) || (inst_sel == 2'd3)) ? 2'd2 : 2'd0;

    piano_inst_lut u_inst_lut (
        .inst         (inst_ok),
        .ham_gain_q16 (inst_ham_gain),
        .ksh_ofs_enc  (inst_ksh_enc)
    );

    piano_note_lut u_note_lut (
        .note      (on_note),
        .f0_step   (f0_bus),
        .beat_step (beat_bus)
    );

    piano_vel_lut u_vel_lut (
        .vel      (on_vel),
        .inst     (inst_ok),          // ★ 多乐器：拨片/指甲比毛毡琴槌亮 ⇒ lp_sh 更小
        .gain_q16 (vel_gain_bus),
        .lp_sh    (vel_lp_bus)
    );

    // ------------------------------------------------- 表情参数（拓展②）----
    // 颤音速率：f_lfo = vib_rate × 0.1 Hz（0 → 0，50 → 5.0 Hz，127 → 12.7 Hz）
    //           vib_inc = round(f_lfo × 2^32 / fs)，查表（生成脚本算好）
    // 颤音深度：depth_k = vib_depth × 15 (Q16 分数)
    //           f_inst = f_note × (1 + sin(2π f_lfo t) × depth_k / 65536)
    //           ⇒ depth 0..127 → ±0 .. ±2.907 % → ±0 .. ±49.6 cent（线性）
    // 滑音时长：t_glide = glide_time × 4 ms（0 → 立即跳变，127 → 508 ms）
    //           N = round(t_glide × fs)，recip = round(2^32 / N)
    //           step = ((f_target − f_current) × recip) >> 32，逐采样点线性推进
    wire [31:0] vib_inc_bus;
    // ⚠️ 位宽必须与 LUT 端口一致（16 bit）：原来写 32 bit，高 16 位【无驱动】
    //    vopt 会报 "Connection width does not match width of port 'recip'"，
    //    实测探针里该总线读到 Z。虽然 g_r_r 只取低 16 位、功能没错，
    //    但无驱动总线是隐患（X 传播/工具优化都可能咬人）⇒ 按端口宽度声明。
    wire [15:0] glide_recip_bus;

    piano_vib_lut u_vib_lut (
        .rate (vib_rate),
        .inc  (vib_inc_bus)
    );

    piano_glide_lut u_glide_lut (
        .t     (glide_time),
        .recip (glide_recip_bus)
    );

    wire [11:0] vib_depth_k = {5'd0, vib_depth} * 6'd15;   // ≤1905
    wire        vib_act     = vib_on & (vib_depth != 7'd0);
    wire        glide_act   = glide_on & (glide_time != 7'd0);

    // 延音踏板：抬起(pedal up)脉冲 —— 把"待释放"的声部一次性放掉
    reg sus_d;
    always @(posedge clk) begin
        if (!rst_n) sus_d <= 1'b0;
        else        sus_d <= sustain;
    end
    wire sus_fall = sus_d & ~sustain;

    // --------------------------------------------------- 声部状态（回读） ----
    wire [N_VOICES-1:0]     v_active;
    wire [N_VOICES-1:0]     v_gate;
    wire [7*N_VOICES-1:0]   v_note_flat;
    wire signed [24:0]      v_out [0:N_VOICES-1];

    // ------------------------------------------------------- 声部分配 --------
    // 优先级（贴近真实钢琴行为）：
    //   ⓪ 滑音模式：新音符一律给"最近用过的声部"（经典单音 portamento）
    //   ① 同音且仍按住 → 重击同一根弦（不抢别的声部）
    //   ② 空闲声部    → 从轮转指针开始扫，天然均衡磨损
    //   ③ 已松开声部  → 抢（正处在阻音器阶段，听感损失最小）
    //   ④ 任意声部    → 轮转抢占（最坏情况）
    //
    // ★★ 为什么改掉原来"4 个串行 for 循环"的写法 ★★
    //   MODE=0 的 P&R 时序报告里【最差路径】正是它（**不是表情通路**）：
    //     env(voice3) → act_c → 分配器串行链 → on_pulse_sel[0] → voice0 的 ph CE
    //     数据延迟 19.748 ns / 20 ns 周期（slack 仅 +0.010 ns，逻辑级数 15）
    //   原写法用 `!alloc_hit` 把 4 层 × 8 声部串成一条长链；MODE=1 又多一个
    //   滑音分支、布局更拥挤 ⇒ 这条通向 1536 个 ph-CE 终点的路径就成片违例
    //   （flow-verifier 报的 2382 违例里，很大一部分应是这类终点）。
    //   现在：三层候选掩码【并行】算，每层用树形优先级编码（3 级），
    //   最后按优先级做 3 选 1 ⇒ 链深从 ~24 级降到 ~6 级。
    // ⚠️ 语义必须逐例一致：_research/piano/check_allocator_equiv.py 穷举了
    //    (v_active, v_gate, rr) = 2^24 组合 × 12 组音号匹配 + 200 万随机样本，
    //    与串行版本逐例对照结果**完全相同**（evidence/allocator_equiv.txt）。
    // ⚠️ 树形版本支持 1..8 声部；N_VOICES>8 时自动退回原来的串行写法（见 generate）。
    reg  [SEL_W-1:0] alloc_sel;
    // ★ 一热分配结果（2026-10-06 修 362 违例）：让 `on_pulse_sel` 直接用一热位 AND，
    //   省掉原来 `alloc_sel == gp` 那一级 4 bit 相等比较（实测最差路径终点是 ph/CE,D）。
    //   ⚠️【三个 generate 分支都必须驱动它】——只改本分支会让 N>8 的 alloc_oh 悬空(z) ⇒ 静音。
    reg  [N_VOICES-1:0] alloc_oh;
    reg  [SEL_W-1:0] rr;
    reg  [SEL_W-1:0] last_voice;
    reg              last_valid;

    // 各声部当前基频（滑音起点用）。★ 用【已注册的 ld_sel】做 8 选 1（见下面 g_delta_c）：
    // 原来用组合的 alloc_sel，于是"分配器链 → 32 bit 8 选 1 → 33 bit 减法"全在一拍里；
    // 现在起点变成寄存器，路径短得多，而且 delta 值与原来完全一样（同一路声部）。
    wire [32*N_VOICES-1:0] v_f0_flat;

    // 有效声部掩码 + 音号匹配掩码（并行算）
    wire [7:0] valid_mask = (N_VOICES >= 8) ? 8'hFF
                                            : ((8'd1 << N_VOICES[3:0]) - 8'd1);
    reg  [7:0] note_match_mask;
    integer    nm;
    always @(*) begin
        note_match_mask = 8'd0;
        for (nm = 0; nm < 8; nm = nm + 1)
            if (nm < N_VOICES)
                note_match_mask[nm] = (v_note_flat[nm*7 +: 7] == on_note);
    end

    // 树形"最低置位"编码器：8 bit → SEL_W bit，深度 3 级（不是 8 级串行）
    // ⚠️ 返回值必须与 alloc_sel 同宽（SEL_W）：第一版返回 3 bit 却写成 s1[SEL_W-1:0]，
    //    越界位读成 x ⇒ alloc_sel 变成未知 ⇒ 一个声部都分配不到（全部静音）。
    //    这类"位选越界"在本项目已经栽过两次（uni_calc、ham_prod）。
    function [SEL_W-1:0] low8;
        input [7:0] m;
        reg [SEL_W-1:0] q0, q1, q2, q3, h0, h1;
        reg       a0, a1, a2, a3, b0, b1;
        begin
            a0 = m[0] | m[1];
            a1 = m[2] | m[3];
            a2 = m[4] | m[5];
            a3 = m[6] | m[7];
            q0 = m[0] ? {SEL_W{1'b0}}             : {{(SEL_W-1){1'b0}}, 1'b1};
            // ⚠️ 字面量位宽必须够：写 2'd4 会**溢出回绕成 0**（2 bit 装不下 4！）
            //    实测症状：low8(0x10) 返回 0、low8(0x80) 返回 3 ⇒ 高 4 位的声部全分错。
            q1 = m[2] ? {{(SEL_W-3){1'b0}}, 3'd2} : {{(SEL_W-3){1'b0}}, 3'd3};
            q2 = m[4] ? {{(SEL_W-3){1'b0}}, 3'd4} : {{(SEL_W-3){1'b0}}, 3'd5};
            q3 = m[6] ? {{(SEL_W-3){1'b0}}, 3'd6} : {{(SEL_W-3){1'b0}}, 3'd7};
            b0 = a0 | a1;   h0 = a0 ? q0 : q1;
            b1 = a2 | a3;   h1 = a2 ? q2 : q3;
            low8 = b0 ? h0 : h1;
        end
    endfunction

    // ---- 32 声部用：把上面已证的 low8 拼成 16/32 bit 树（深度 4/5 级）----
    //   ⚠️ 只在 N_VOICES>8 的 generate 分支里被引用；N<=8 时综合视作无用逻辑 ⇒
    //      默认 8 声部通路的位宽/逻辑一字未动。
    //   语义已证明：sim/tb/tb_alloc32_proof.v（结构化 32,000 + 随机 200,000 例，0 不一致）
    function [5:0] low16t;
        input [15:0] m;
        reg [5:0] lo, hi;
        begin
            lo = low8(m[7:0]);
            hi = low8(m[15:8]);
            low16t = (|m[7:0]) ? lo : (hi + 6'd8);
        end
    endfunction
    function [5:0] low32t;
        input [31:0] m;
        reg [5:0] lo, hi;
        begin
            lo = low16t(m[15:0]);
            hi = low16t(m[31:16]);
            low32t = (|m[15:0]) ? lo : (hi + 6'd16);
        end
    endfunction

    generate
    if (N_VOICES <= 8) begin : g_alloc_tree
        wire [7:0] m_same = valid_mask & v_gate & note_match_mask;
        wire [7:0] m_idle = valid_mask & ~v_active;
        wire [7:0] m_rel  = valid_mask & ~v_gate;
        // 轮转顺序 = 「>= rr 的位先扫（位内低位优先），否则扫 < rr 的位」
        wire [7:0] ge = valid_mask & (8'hFF << rr);
        wire [7:0] lt = valid_mask & ~(8'hFF << rr);
        wire [SEL_W-1:0] s1 = low8(m_same);
        wire [SEL_W-1:0] s2 = (|(m_idle & ge)) ? low8(m_idle & ge) : low8(m_idle & lt);
        wire [SEL_W-1:0] s3 = (|(m_rel  & ge)) ? low8(m_rel  & ge) : low8(m_rel  & lt);

        always @(*) begin
            if (glide_on && last_valid)  alloc_sel = last_voice;
            else if (|m_same)            alloc_sel = s1;
            else if (|m_idle)            alloc_sel = s2;
            else if (|m_rel)             alloc_sel = s3;
            else                         alloc_sel = rr;
        end

        // ★ 一热版（与上面的二进制版是【同一函数的两种编码】）：
        //   `m & (~m+1)` 直接取"最低置位"的一热 ⇒ 级数 2 级（减+与）
        //   对比原来 3 级树(low8) + 1 级 4bit 相等比较 ⇒ 省 1~2 级
        wire [7:0] oh1 = m_same & (~m_same + 8'd1);
        wire [7:0] m2w = (|(m_idle & ge)) ? (m_idle & ge) : (m_idle & lt);
        wire [7:0] m3w = (|(m_rel  & ge)) ? (m_rel  & ge) : (m_rel  & lt);
        wire [7:0] oh2 = m2w & (~m2w + 8'd1);
        wire [7:0] oh3 = m3w & (~m3w + 8'd1);
        always @(*) begin
            if (glide_on && last_valid) alloc_oh = (8'd1 << last_voice);
            else if (|m_same)           alloc_oh = oh1;
            else if (|m_idle)           alloc_oh = oh2;
            else if (|m_rel)            alloc_oh = oh3;
            else                        alloc_oh = (8'd1 << rr);
        end
    end else if (N_VOICES <= 32) begin : g_alloc_tree32
        // ★ 32 bit 两级树形分配器（N_VOICES = 17..32）。为什么必须换掉串行链：
        //   MODE=1 裕量只有 +0.009 ns，串行链随 N 增长 ⇒ N=20/32 必然违例。
        //   等价性已证：sim/tb/tb_alloc32_proof.v（结构化 32,000 + 随机 200,000 例，
        //   与"4 层串行优先、rr 旋转顺序"的黄金模型逐例一致，0 不一致，种子 0xc0ffee01）
        wire [31:0] vm       = (N_VOICES >= 32) ? 32'hFFFF_FFFF
                                                : ((32'd1 << N_VOICES[5:0]) - 32'd1);
        wire [31:0] vg32     = {32{1'b0}} | v_gate;     // 零扩展到 32（N=32 时也成立）
        wire [31:0] va32     = {32{1'b0}} | v_active;
        wire [31:0] rr32     = {{(32-SEL_W){1'b0}}, rr};
        reg  [31:0] nm32;
        integer     nm2;
        always @(*) begin
            nm32 = 32'd0;
            for (nm2 = 0; nm2 < N_VOICES; nm2 = nm2 + 1)
                nm32[nm2] = (v_note_flat[nm2*7 +: 7] == on_note);
        end
        wire [31:0] m_same32 = vm & vg32 & nm32;
        wire [31:0] m_idle32 = vm & ~va32;
        wire [31:0] m_rel32  = vm & ~vg32;
        wire [31:0] ge32     = vm & (32'hFFFF_FFFF << rr32);
        wire [31:0] lt32     = vm & ~(32'hFFFF_FFFF << rr32);
        wire [5:0]  s1_32 = low32t(m_same32);
        wire [5:0]  s2_32 = (|(m_idle32 & ge32)) ? low32t(m_idle32 & ge32)
                                                 : low32t(m_idle32 & lt32);
        wire [5:0]  s3_32 = (|(m_rel32  & ge32)) ? low32t(m_rel32  & ge32)
                                                 : low32t(m_rel32  & lt32);

        always @(*) begin
            if (glide_on && last_valid)  alloc_sel = last_voice;
            else if (|m_same32)          alloc_sel = s1_32[SEL_W-1:0];
            else if (|m_idle32)          alloc_sel = s2_32[SEL_W-1:0];
            else if (|m_rel32)           alloc_sel = s3_32[SEL_W-1:0];
            else                         alloc_sel = rr;
            // ⚠️ 本分支（N=17..32）也必须驱动 alloc_oh，否则 on_pulse_sel 全 0 ⇒ 静音
            alloc_oh = {N_VOICES{1'b0}};
            alloc_oh[alloc_sel] = 1'b1;
        end
    end else begin : g_alloc_serial
        // 备用路径：N_VOICES>32 时保持原来的串行语义（本项目不用）
        reg              alloc_hit;
        reg  [SEL_W-1:0] idx;
        integer          sai;
        always @(*) begin
            alloc_sel = rr;
            alloc_hit = 1'b0;
            if (glide_on && last_valid) begin
                alloc_sel = last_voice;
                alloc_hit = 1'b1;
            end
            for (sai = 0; sai < N_VOICES; sai = sai + 1) begin
                if (!alloc_hit && v_gate[sai] &&
                    (v_note_flat[sai*7 +: 7] == on_note)) begin
                    alloc_sel = sai[SEL_W-1:0];
                    alloc_hit = 1'b1;
                end
            end
            for (sai = 0; sai < N_VOICES; sai = sai + 1) begin
                idx = rr + sai[SEL_W-1:0];
                if (idx >= N_VOICES[SEL_W-1:0]) idx = idx - N_VOICES[SEL_W-1:0];
                if (!alloc_hit && !v_active[idx]) begin
                    alloc_sel = idx;
                    alloc_hit = 1'b1;
                end
            end
            for (sai = 0; sai < N_VOICES; sai = sai + 1) begin
                idx = rr + sai[SEL_W-1:0];
                if (idx >= N_VOICES[SEL_W-1:0]) idx = idx - N_VOICES[SEL_W-1:0];
                if (!alloc_hit && !v_gate[idx]) begin
                    alloc_sel = idx;
                    alloc_hit = 1'b1;
                end
            end
            for (sai = 0; sai < N_VOICES; sai = sai + 1) begin
                idx = rr + sai[SEL_W-1:0];
                if (idx >= N_VOICES[SEL_W-1:0]) idx = idx - N_VOICES[SEL_W-1:0];
                if (!alloc_hit) begin
                    alloc_sel = idx;
                    alloc_hit = 1'b1;
                end
            end
            // ⚠️ 本分支（N>32）也必须驱动 alloc_oh，否则 on_pulse_sel 全 0 ⇒ 静音
            alloc_oh = {N_VOICES{1'b0}};
            alloc_oh[alloc_sel] = 1'b1;
        end
    end
    endgenerate

    // ---------------------------------------------------- note-on / note-off -
    // ⚠️ MIDI 惯例：note-on 且 vel=0 等价于 note-off（midi_rx 常见写法）
    wire        vel_zero    = (on_vel == 7'd0);
    wire        off_any     = off_valid | (on_valid & vel_zero);
    wire [6:0]  off_any_note = (on_valid & vel_zero) ? on_note : off_note;
    wire        note_on     = on_valid & ~vel_zero;

    // ------------------------------------------------------- 装载 FSM --------
    localparam [1:0] L_IDLE = 2'd0, L_CALC = 2'd1, L_MUL = 2'd2, L_DONE = 2'd3;

    reg  [1:0]  ld_st;
    reg  [2:0]  ld_idx;
    reg         ld_busy;
    reg         ld_stb;                      // 装载有效脉冲（给被选声部）
    reg  [SEL_W-1:0] ld_sel;
    reg  [31:0] ld_f0;
    reg  [16:0] ld_velgain;
    reg  [6:0]  ld_vel;                      // ★ 力度也要锁存：明亮度系数 = K × vel/128
    reg  [16:0] ld_gq;                       // 中间量：amp × velgain >> 16
    reg  [15:0] ld_kq;
    reg  [16:0] ld_env_bus [0:N_PART-1];
    reg  [31:0] ld_inc_bus [0:N_PART-1];

    // 装载用的参数查表（运行时索引，只有这一份）
    wire [16:0] pl_amp;
    wire [15:0] pl_k;
    wire [4:0]  pl_sr, pl_sd, pl_st1, pl_st2;

    // ---------- 滑音斜率（与装载 FSM **并行**算，不占用任何 FSM 状态）----------
    // 为什么要并行：装载完成时刻 ld_stb 决定了包络在哪个采样点生效。
    // 若为了算滑音斜率往 FSM 里插状态，ld_stb 会整体后移 1~2 拍，
    // 输出就不再与"加表情之前"逐样本一致（回归要求会破）。
    // 所以这里把 delta 在 L_IDLE 那一拍锁存，借 L_CALC / L_MUL 两拍做乘法与移位，
    // 到 L_DONE 时早就准备好了（L_DONE 在 12 拍之后）。
    //
    // ★★ 为什么不用 33×33 的一次大乘法 ★★
    //   step = (delta × recip) >> 32 里 recip 是 32 bit，直接乘就是 33×33 = 66 bit
    //   ⇒ 4~6 个 18×18 乘法器 + 宽加法树，单周期很难收敛（这正是 MODE=1 里
    //   我这条表情通路最长的组合路径）。
    //   两条改进：
    //     ① 查表直接给 Q24 倒数：r = round(2^24 / N)。因为 N < 2^16，
    //        r 天然落在 [338, 42902] ⇒ **只有 16 bit**，精度 ≤ 0.15%；
    //        step = (delta × r) >> 24
    //     ② delta 拆成 17 bit 低半 + 16 bit 高半，两拍各做一次 17×16 / 16×16 乘法，
    //        再按位权拼起来 ⇒ 每次乘法只占 1 个 DSP，路径短得多。
    //   step_mag = (hi·r)>>7 + (lo·r)>>24      （由 mag = hi·2^17 + lo 推出）
    reg  signed [32:0] g_delta_r;
    reg               g_sign_r;
    reg  [16:0]       g_mag_lo_r;
    reg  [15:0]       g_mag_hi_r;
    reg  [15:0]       g_r_r;
    reg  [32:0]       g_plo_r;
    reg  [31:0]       g_phi_r;
    reg  signed [31:0] g_step_r;

    // ⚠️ f0_cur_ld 必须写在【装载寄存器声明之后】（ld_sel 在前面才声明）
    wire [31:0]        f0_cur_ld = v_f0_flat[ld_sel*32 +: 32];
    wire signed [32:0] g_delta_c = {1'b0, ld_f0} - {1'b0, f0_cur_ld};
    wire [32:0] g_mag_c    = g_delta_c[32] ? (~g_delta_c + 33'sd1) : g_delta_c;
    wire [32:0] g_plo_n    = g_mag_lo_r * g_r_r;        // 17×16 → 33 bit
    wire [31:0] g_phi_n    = g_mag_hi_r * g_r_r;        // 16×16 → 32 bit
    wire [26:0] g_step_mag = {2'd0, g_phi_r[31:7]} + {18'd0, g_plo_r[32:24]};
    // ⚠️ 位选必须与源等宽或更窄：写 g_step_mag[31:0] 会越界，越界位按 x 读入
    //    （本项目在 uni_calc 上就栽过一次，直接导致 mix_out 全程 X）。
    wire [31:0] g_step_mag32 = {5'd0, g_step_mag};
    wire signed [31:0] g_step_n = g_sign_r ? (-g_step_mag32) : g_step_mag32;

    always @(posedge clk) begin
        if (!rst_n) begin
            g_delta_r  <= 33'sd0;
            g_sign_r   <= 1'b0;
            g_mag_lo_r <= 17'd0;
            g_mag_hi_r <= 16'd0;
            g_r_r      <= 16'd0;
            g_plo_r    <= 33'd0;
            g_phi_r    <= 32'd0;
            g_step_r   <= 32'sd0;
        end else begin
            // 第 0 拍：先把 Q24 倒数锁存（它只跟 glide_time 有关，与音符无关）
            if ((ld_st == L_IDLE) && note_on && !ld_busy)
                g_r_r      <= glide_recip_bus;

            // 第 1 拍（第 0 个泛音的 L_CALC）：此时 ld_f0 / ld_sel 才【刚被 L_IDLE 写入】，
            //   读到的才是本次音符的值。
            //   ⚠️ 千万别在 L_IDLE 那一拍算 delta：非阻塞赋值意味着那时 ld_f0/ld_sel
            //      还是【上一个音符】的值 ⇒ delta=0 ⇒ step=0 ⇒ 滑音变成"瞬间跳变"。
            //      （本项目实测症状：T9 第一个窗口就是 880 Hz。）
            if ((ld_st == L_CALC) && (ld_idx == 3'd0)) begin
                g_delta_r  <= g_delta_c;
                g_sign_r   <= g_delta_c[32];
                g_mag_lo_r <= g_mag_c[16:0];
                g_mag_hi_r <= g_mag_c[32:17];
            end
            // 第 2 拍（第 0 个泛音的 L_MUL）：两次小乘法并行
            if ((ld_st == L_MUL) && (ld_idx == 3'd0)) begin
                g_plo_r <= g_plo_n;
                g_phi_r <= g_phi_n;
            end
            // 第 3 拍（第 1 个泛音的 L_CALC）：拼出 step（远早于 L_DONE）
            if ((ld_st == L_CALC) && (ld_idx == 3'd1))
                g_step_r <= g_step_n;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            last_voice <= {SEL_W{1'b0}};
            last_valid <= 1'b0;
        end else if (note_on && !ld_busy) begin
            last_voice <= alloc_sel;
            last_valid <= 1'b1;
        end
    end

    piano_partial_lut u_ld_lut (
        .n       (ld_idx),
        .inst    (inst_ok),           // ★ 多乐器：装载期查表（此处本就是运行时索引，免费）
        .amp_q16 (pl_amp),
        .k_q12   (pl_k),
        .s_ring  (pl_sr),
        .s_damp  (pl_sd),
        .st1     (pl_st1),
        .st2     (pl_st2)
    );

    // ★ 乘积必须在【全宽网络】上形成再移位（本项目踩过"32 位装不下 44 位乘积、
    //   高位被截断成噪声"的大坑）。这里的做法是：声明的线网位宽 >= 操作数位宽之和，
    //   使 Verilog 的上下文宽度足以容纳完整乘积，不做二次截断。
    wire [33:0] ld_gmul   = pl_amp * ld_velgain;   // 17×17 → 34 bit
    wire [16:0] ld_g      = ld_gmul[33:16];        // /65536 ⇒ Q16 幅度
    // ★★ 明亮度必须真的受力度控制 ★★
    //   K 是"最强奏时"的系数（Q12），实际系数 = K × vel/128。
    //   本项目实测教训：第一版直接把 K 当成系数（漏了 ×vel），结果
    //   env = g·(1+K/4096) 里 g 与 K 项同时正比于力度 ⇒ 泛音比例与力度无关，
    //   FFT 实测 vel30 / vel120 的"高次泛音/基频"比完全相同（差 0.01 dB），
    //   即"力度只改变音量、不改变音色"。修好后才是"力度越大越亮"。
    //   ⚠️ 乘法要先在全宽网络里形成：K(16bit) × vel(7bit) = 23bit，
    //      若直接写 (pl_k * ld_vel) >> 7 会按 16 位上下文截断。
    wire [21:0] kvel_prod = pl_k * {15'd0, ld_vel};
    wire [15:0] kvel_q12  = kvel_prod[21:7];       // K × vel / 128
    wire [32:0] ld_bmul   = ld_gq * ld_kq;         // 17×16 → 33 bit（明亮度）
    wire [18:0] ld_envsum = {2'b0, ld_gq} + ld_bmul[30:12];  // ×(1 + K·vel/(128·4096))

    // 非谐性拉伸：inc = n·f0 + (f0>>st1) + (f0>>st2)
    //   用移位加法近似 n·sqrt(1+B·n²)，B=0.0004，误差 < 0.07%（见生成脚本自检）
    //   33 bit 中间宽度：note 127 时 6×f0 ≈ 3.3e9 < 2^32，不会溢出
    reg  [32:0] ld_f0e;
    reg  [2:0]  ld_n;
    always @(*) begin
        ld_n   = ld_idx + 3'd1;
        ld_f0e = {1'b0, ld_f0};
    end

    wire [32:0] ld_nf0 = (ld_n == 3'd1) ?  ld_f0e                    :
                         (ld_n == 3'd2) ? (ld_f0e << 1)              :
                         (ld_n == 3'd3) ? ((ld_f0e << 1) + ld_f0e)   :
                         (ld_n == 3'd4) ? (ld_f0e << 2)              :
                         (ld_n == 3'd5) ? ((ld_f0e << 2) + ld_f0e)   :
                                          ((ld_f0e << 2) + (ld_f0e << 1));
    wire [32:0] ld_inc = ld_nf0
                       + (ld_f0e >> pl_st1)      // st=31 时该项可忽略
                       + (ld_f0e >> pl_st2);

    // 装载总线 → 平坦向量（Verilog-2001 不支持数组端口，故展平）
    wire [N_PART*17-1:0] ld_env_flat;
    wire [N_PART*32-1:0] ld_inc_flat;
    genvar g2;
    generate
    for (g2 = 0; g2 < N_PART; g2 = g2 + 1) begin : g_flat
        assign ld_env_flat[g2*17 +: 17] = ld_env_bus[g2];
        assign ld_inc_flat[g2*32 +: 32] = ld_inc_bus[g2];
    end
    endgenerate

    // 装载 FSM 的复位循环变量（模块级声明；分配器里的同名变量已在 generate 内改名 sai）
    integer ai;

    always @(posedge clk) begin
        if (!rst_n) begin
            ld_st      <= L_IDLE;
            ld_idx     <= 3'd0;
            ld_busy    <= 1'b0;
            ld_stb     <= 1'b0;
            ld_sel     <= {SEL_W{1'b0}};
            ld_f0      <= 32'd0;
            ld_velgain <= 17'd0;
            ld_vel     <= 7'd0;
            ld_gq      <= 17'd0;
            ld_kq      <= 16'd0;
            for (ai = 0; ai < N_PART; ai = ai + 1) begin
                ld_env_bus[ai] <= 17'd0;
                ld_inc_bus[ai] <= 32'd0;
            end
        end else begin
            ld_stb <= 1'b0;
            case (ld_st)
                L_IDLE: begin
                    if (note_on && !ld_busy) begin
                        ld_f0      <= f0_bus;
                        ld_velgain <= vel_gain_bus;
                        ld_vel     <= on_vel;          // ★ 明亮度要用到力度
                        ld_sel     <= alloc_sel;
                        ld_idx     <= 3'd0;
                        ld_busy    <= 1'b1;
                        ld_st      <= L_CALC;
                    end
                end
                L_CALC: begin
                    ld_gq <= ld_g;
                    ld_kq <= kvel_q12;                 // ★ K × vel / 128
                    ld_inc_bus[ld_idx] <= ld_inc[31:0];
                    ld_st <= L_MUL;
                end
                L_MUL: begin
                    ld_env_bus[ld_idx] <= (ld_envsum > 19'd65536) ? 17'd65536
                                                                 : ld_envsum[16:0];
                    if (ld_idx == N_PART[2:0] - 3'd1) begin
                        ld_st <= L_DONE;
                    end else begin
                        ld_idx <= ld_idx + 3'd1;
                        ld_st  <= L_CALC;
                    end
                end
                L_DONE: begin
                    ld_stb  <= 1'b1;          // 6 个包络/增量同时有效
                    ld_busy <= 1'b0;
                    ld_st   <= L_IDLE;
                end
                default: ld_st <= L_IDLE;
            endcase
        end
    end

    // 轮转指针推进
    always @(posedge clk) begin
        if (!rst_n) rr <= {SEL_W{1'b0}};
        else if (note_on && !ld_busy) begin
            if (alloc_sel == N_VOICES[SEL_W-1:0] - 1'b1) rr <= {SEL_W{1'b0}};
            else                                          rr <= alloc_sel + 1'b1;
        end
    end

    // 被选声部收到 note-on 脉冲（与装载完成脉冲 ld_stb 分开）
    wire [N_VOICES-1:0] on_pulse_sel;
    genvar gp;
    generate
    for (gp = 0; gp < N_VOICES; gp = gp + 1) begin : g_sel
        // ★ 一热分配（2026-10-06）：直接用一热位做 AND，省掉原来 `alloc_sel == gp`
        //   那一级 4 bit 相等比较（实测最差路径 20.034 ns / slack −0.296 ns）。
        assign on_pulse_sel[gp] = note_on & ~ld_busy & alloc_oh[gp];
    end
    endgenerate

    // ------------------------------------------------- 包络降速计数器 --------
    reg [DIV_W-1:0] div_cnt;
    always @(posedge clk) begin
        if (!rst_n)           div_cnt <= {DIV_W{1'b0}};
        else if (sample_tick) div_cnt <= div_cnt + 1'b1;
    end

    // -------------------------------------------------------- 8 个声部 -------
    wire [N_VOICES-1:0]   v_gate_w;
    wire [N_VOICES-1:0]   v_act_w;
    wire [7*N_VOICES-1:0] v_note_w;
    wire [32*N_VOICES-1:0] v_f0_w;

    genvar gv;
    generate
    for (gv = 0; gv < N_VOICES; gv = gv + 1) begin : g_voice
        wire signed [24:0] vo;
        wire               va, vg;
        wire [6:0]         vn;
        wire [31:0]        f0_w;

        piano_voice #(
            .N_PART       (N_PART),
            .PHASE_W      (PHASE_W),
            .ENV_W        (ENV_W),
            .DIV_W        (DIV_W),
            .HAM_SH       (HAM_SH),
            .HAM_GAIN_Q16 (HAM_GAIN_Q16),
            .ID           (gv)
        ) u_voice (
            .clk          (clk),
            .rst_n        (rst_n),
            .sample_tick  (sample_tick),
            .div_cnt      (div_cnt),
            .on_pulse     (on_pulse_sel[gv]),
            .on_note      (on_note),
            .on_velgain   (vel_gain_bus),
            .on_lpsh      (vel_lp_bus),
            // ★ 阶段1b 多乐器：引擎内部连接（不涉及 top.v 端口表）
            .on_ham_gain  (inst_ham_gain),
            .on_ksh_ofs   (inst_ksh_enc),
            .on_pluck_fast(inst_ok == 2'd1),   // 只有电吉他加速激励衰减
            .bow_speed    (bow_speed),         // ★ CC21 弓速
            .drv_on       (inst_ok == 2'd2),   // ★ 只有二胡持续供能 ⇒ 钢琴/吉他逐值不变

            .on_beat      (beat_bus),
            .ld_for_me    (ld_stb & (ld_sel == gv[SEL_W-1:0])),
            .ld_env_flat  (ld_env_flat),
            .ld_inc_flat  (ld_inc_flat),
            .ld_f0        (ld_f0),            // 新音符基频（滑音目标）
            .ld_gstep     (g_step_r),         // 滑音每采样点步进
            .off_pulse    (off_any),
            .off_note     (off_any_note),
            // ---- 表情 ----
            .glide_act    (glide_act),
            .vib_act      (vib_act),
            .vib_inc      (vib_inc_bus),
            .vib_depth_k  (vib_depth_k),
            .sustain      (sustain),
            .sus_fall     (sus_fall),
            .f0_out       (f0_w),
            .vout         (vo),
            .active       (va),
            .gate_out     (vg),
            .note_out     (vn)
        );

        assign v_out[gv]           = vo;
        assign v_act_w[gv]         = va;
        assign v_gate_w[gv]        = vg;
        assign v_note_w[gv*7 +: 7] = vn;
        assign v_f0_w[gv*32 +: 32] = f0_w;
    end
    endgenerate

    assign active      = v_act_w;
    assign v_active    = v_act_w;
    assign v_gate      = v_gate_w;
    assign v_note_flat = v_note_w;
    assign v_f0_flat   = v_f0_w;

    // --------------------------------------------------- 混音 + 软膝限幅 ----
    // ★ 只累加【仍在发声】的声部：
    //   这是一个防御措施。若某个声部的数据通路出现 X（例如将来有人漏掉某个
    //   寄存器的复位），未发声声部的 X 会被累进 mix_out，把整条输出永久污染成 X
    //   —— 本项目被 flow-verifier 独立验证抓到过一次（active 位图正常、波形全 X）。
    //   被排除的声部其电平已低于 -48 dB（active 判定），丢掉不影响听感。
    reg signed [27:0] vsum;
    integer vi;
    always @(*) begin
        vsum = 28'sd0;
        for (vi = 0; vi < N_VOICES; vi = vi + 1)
            vsum = vsum + (v_active[vi] ? v_out[vi] : 25'sd0);
    end

    // 🔴 输出级改动【已撤销】（2026-10-06，构建实测 404 违例 / 最差裕量 −4.71 ns）
    //
    // 🔴 输出级改动【第二次撤销】（2026-10-06）：754 违例 / −4.919 ns
    //
    // 本轮 `.tr`（`evidence/fpga_hank_MODE1_outsweep_754v.tr.txt`）Top 25 给出两类路径：
    //   ① `env_..._s0` → `mix_out_*_s0`  −4.919 ns（15 条）
    //      ⇒ 这是输出链的【输入侧】：包络寄存器 → 8 声部求和 → 增益/膝/阻断 → mix_out
    //   ② `u_midi/on_note_3_s0` → `ph_ph_.../CE`  −4.557 ns（10 条）
    //      ⇒ 就是之前那条 −0.296 ns 的分配器路径，**恶化到 −4.557**
    //
    // ⚠️ 结论修正（我上一条的说法不准确）：
    //    · **HP 递归不在 Top 上** ⇒ "递归包住求和树"不是主因 ✗
    //    · 真因是【我在这条已经临界（基准仅 +0.043 ns）的输出链上又串了几级】
    //      （增益 mux + 阻断 + 膝 mux）⇒ 把它推过界 ✗
    //    · `on_note → ph` 的恶化**不可能**由输出级逻辑造成（两者无逻辑关联）
    //      ⇒ 最可能是 **P&R/布局副作用**（新增 ~90 FF + mux 使该路径走线变差）
    //      ⇒ 判别方法：比对两版 `.tr` 中该路径的 **Logic Levels 与 cell/route 占比**
    //        （级数相同而 route 涨 ⇒ 是布局，不是逻辑）
    //
    // ⚠️ 另一条永久教训（Lead 指出、我认同）：
    //    **`sample_tick` 是【时钟使能 CE】，不是【慢时钟】** ⇒
    //    带 CE 的 always 块里组合逻辑仍须在【一个时钟】内收敛；
    //    "512 拍余量"是错觉，除非显式写多周期约束。
    //    （本项目同型三次：`env_en`→1536 个 CE / `ph/CE` / 本次）
    //
    // ⚠️ 而且对 `env → mix_out` **不能**用多周期约束：
    //    `env` 并不是 512 拍才更新一次（它在 sample_tick 之上还受 env_en 门控，但**输出链每采样点都要算**），
    //    且 `mix_out` 是在 `vld[2]` 捕获 —— 数据到达与捕获之间**只隔 1 个时钟**，不是 512。
    //    ⇒ 放松成多周期会【掩盖真实违例】✗
    //
    // ⇒ 正解只能是【真流水线】（用真实寄存器把链切开），且它必须回答一个产品问题：
    //    **钢琴能不能接受 +1 采样点（10.24 µs）的固定群延迟？**（见 _research/piano 记录）
    // ★★ 真流水线（2026-10-06，Lead 批准）：把输出链切成 3 段，代价 **+2 个时钟 = 40 ns**
    //
    // 为什么能修（`.tr` 给的证据）：最差路径的【起点是 `env`】——
    //   因为混音器逐声部门控 `vsum = Σ(v_active[vi] ? v_out[vi] : 0)`，
    //   而 `v_active` 是 `env` 组合派生的 ⇒ 整条链被包络顶着：
    //     `env → v_active → mux → 8 路求和树 → 增益/膝 → mix_out` = 28 级 / −4.919 ns ✗
    //   ⇒ 正解是【把链切开】，不是"去掉某一段" ✓
    //
    // 三段：
    //   段① `env → v_active → mux → 求和树`                       → 寄存器 `vsum_q`
    //   段② `vsum_q → 增益 mux → 取绝对值 → 软膝 → 符号`            → 寄存器 `magl_q`
    //   段③ `magl_q → 削顶比较 → mix_out`                          （用已有 mix_out 寄存器）
    //
    // ⚠️ 语义零改动：单级流水只是【在组合链中间插寄存器】，不改任何逻辑
    //   ⇒ 输出 = 原信号【平移 2 个时钟（40 ns）】⇒ 回归判据 = "去掉该固定偏移后逐字节一致" ✓
    // ⚠️ 为什么是"2 个时钟"而不是"1 个采样点"：这两级是**时钟级**流水（每拍都刷新、不加 CE）
    //   ⇒ 代价 2×20 ns = **40 ns**，比 Lead 批准的 10.24 µs 小 256 倍 ✓
    // ⚠️ `mix_out` 的有效位从 `vld[2]` 挪到 `vld[4]`（+2 拍）—— 必须同时改，否则整体错位 ✗
    reg signed [27:0] vsum_q;
    always @(posedge clk) begin
        if (!rst_n) vsum_q <= 28'sd0;
        else        vsum_q <= vsum;                       // 段①→② 的界
    end

    // 增益重平衡（门控非钢琴：钢琴数值逐位不变）：-6 dB
    //   实测依据（outsweep TB，8 音和弦）：吉他/二胡 32.37%/39.90% 采样点进软膝、峰值触硬削 32768；
    //   −6 dB 后 7.90%/11.70%，硬削消失 ✓
    wire signed [27:0] norm_old = vsum_q >>> OUT_SHIFT;
    wire signed [27:0] norm_new = vsum_q >>> (OUT_SHIFT + 1);
    wire signed [27:0] norm = (inst_ok != 2'd0) ? norm_new : norm_old;

    // ★★ 琴体共振曲线（二胡专用；门控 inst_sel==2 ⇒ 钢琴/吉他【完全旁路】⇒ 逐值不变）
    //   实测（专业《赛马》）：**550 Hz +34.6 dB（宽的低 Q 隆起）**、1635 / 2970 / 5360 Hz 次峰
    //   落地 = 4 级 peaking biquad，Q14 定点。**已与浮点比对：最大误差 0.176 dB、平均 0.016 dB**
    //   ⚠️ 位置：紧接增益、在软膝【之前】 ⇒ 顺带把 `vsum_q → magl_q` 那条 −1.499 长链
    //      切成 5 段（每段 1 乘积组 + 2 加）✓
    //   ⚠️ 位宽链（本项目栽过"32 bit 装不下乘积"⇒ 显式给宽）：
    //      x = 16 bit（低 16 位就是音频域）⇒ 16×16 = 32 bit 乘积 ⇒ 5 项累加 ⇒ **36 bit 累加器**
    //      ⇒ >>>14（常量）⇒ 限幅 ±32767 ⇒ 下一级 16 bit ✓
    //   ⚠️ 每级【一拍】（时钟级流水）⇒ 门控路径 +4 拍 = 80 ns；**钢琴路径一拍不动** ✓
    //   ⚠️ 系数常量 ⇒ 无变量移位 ⇒ 不会像上次那样长出多余桶形移位器（+8833 LUT）✓
    // 🔴 曲线【再次旁路】（2026-10-06）：按采样率门控后**仍然** 99.17%（应 ~1%）✗
    //   ⇒ 说明"更新率"不是（唯一）根因 ⇒ 滤波器还有**未定位的实现错误** ✗
    //   ⇒ 在定位清楚之前保持旁路，**绝不交给构建**（否则=全时软削波 ⇒ "更电子" ✗✗）
    //   ⚠️ 待查清单（下一轮逐条验证）：
    //     ① 输入切片：`norm[15:0]` 是否真的等于音频域（还是被截断/含直流）？
    //     ② 反馈符号/结构：`- a1·y1 - a2·y2` 的定点符号是否与浮点设计一致？
    //     ③ 每级 `>>>14` 后 `sat16` 是否把中间级顶到饱和（级联后放大）？
    //     ④ 用**逐级 dump** 逐个比对浮点参考（而不是只看最终膝触发）✗
    wire signed [27:0] norm_f = norm;

    // 软膝限幅：|x| <= KNEE 完全线性；膝上斜率门控（钢琴 1/4 原样；非钢琴 3/8）
    wire signed [27:0] mag  = norm_f[27] ? (-norm_f) : norm_f;
    wire signed [27:0] magl_old = (mag > KNEE) ? (KNEE + ((mag - KNEE) >>> 2)) : mag;
    wire signed [27:0] magl_new = (mag > KNEE) ? (KNEE + ((3 * (mag - KNEE)) >>> 3)) : mag;
    wire signed [27:0] magl = (inst_ok != 2'd0) ? magl_new : magl_old;

    // 段②→③ 的界：把"幅度 + 符号"一起寄存（符号必须跟着走，否则负半周会被翻正 ✗）
    reg signed [27:0] magl_q;
    reg               sign_q;
    always @(posedge clk) begin
        if (!rst_n) begin
            magl_q <= 28'sd0;
            sign_q <= 1'b0;
        end else begin
            magl_q <= magl;
            sign_q <= norm_f[27];
        end
    end
    wire signed [27:0] lim = sign_q ? (-magl_q) : magl_q;

    // 输出流水有效标记：钢琴/吉他/二胡统一 = vld[4]
    //   ⚠️ 曾有 `fvld` 链把二胡的有效位推迟 6 个采样点（为 6 级 IIR）——
    //      IIR 已弃用 ⇒ 必须删掉，否则二胡会读到【6 个采样点之前】的值（错样本）✗
    reg [11:0] vld;
    always @(posedge clk) begin
        if (!rst_n) vld <= 12'd0;
        else        vld <= {vld[10:0], sample_tick};
    end
    wire lim_vld = vld[4];

    always @(posedge clk) begin
        if (!rst_n) begin
            mix_out <= 16'sd0;
        end else if (lim_vld) begin
            if (lim > 28'sd32767)       mix_out <= 16'sd32767;
            else if (lim < -28'sd32768) mix_out <= -16'sd32768;
            else                        mix_out <= lim[15:0];
        end
    end

endmodule

// =============================================================================
//  piano_voice —— 单个钢琴声部（6 个独立泛音分量 + 齐奏失谐 + 琴槌噪声）
//
//  逐样本流水（fs 的每个 tick 推进一步）：
//    拍 T   ：相位累加、包络指数衰减、琴槌包络/噪声更新；
//             同时正弦 ROM 采样【旧相位】（ROM 是同步读，地址组合来自 ph），
//             并快照【旧包络 / 旧琴槌增益 / 旧噪声】
//    拍 T+1 ：ROM 输出到达 → 与包络相乘（乘积全宽形成后再 >>16）
//    拍 T+2 ：6 路相加 → × 齐奏拍频系数 → + 琴槌噪声 ⇒ vout
//    拍 T+3 ：（引擎）8 声部相加 → 预缩放 → 软膝限幅 → mix_out
//  固定 3~4 拍延迟（≈80 ns）、确定无抖动 —— 远优于赛题"控制→发声 ≤10 ms"。
//
//  ⚠️ 三个已踩过的坑，本模块都显式规避：
//     1) 正弦 ROM 用【同步读】，地址直接接 ph[n][31:24]：ROM 自己在 posedge
//        采样，所以输出天然是"上一拍相位"的正弦值，与快照到 env_q 的
//        "上一拍包络"严格对齐，不需要额外打拍（少一个 off-by-one 机会）。
//     2) 所有状态更新都在 sample_tick 门控内（参考实现漏了门控，每 20 ns 白算）。
//     3) note-off 之后【所有】包络继续正常更新，包括琴槌包络：
//        参考实现的 env_hammer 在 note-off 分支不更新，早松键会残留"咔"声。
// =============================================================================
module piano_voice #(
    parameter integer N_PART  = 6,
    parameter integer PHASE_W = 32,
    parameter integer ENV_W   = 32,
    parameter integer DIV_W   = 10,
    parameter integer HAM_SH  = 10,
    parameter [16:0]  HAM_GAIN_Q16 = 17'd19661,
    parameter integer ID      = 0
)(
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 sample_tick,
    input  wire [DIV_W-1:0]     div_cnt,

    // note-on（本声部被选中那一拍）
    input  wire                 on_pulse,
    input  wire [6:0]           on_note,
    input  wire [16:0]          on_velgain,
    input  wire [6:0]           bow_speed,     // ★ CC21 弓速（全局，各声部同值）
    input  wire                 drv_on,        // ★ 1 = 持续供能（只有二胡：inst_ok==2'd2）

    input  wire [2:0]           on_lpsh,
    // ★ 多乐器（阶段1b）：以下 3 个端口都是【引擎内部】连接，不影响 top.v 端口表
    input  wire [16:0]          on_ham_gain,   // 激励增益（钢琴 = 19661 = 原 HAM_GAIN_Q16）
    input  wire [1:0]           on_ksh_ofs,    // 衰减档位偏移编码：0→−1, 1→0, 2→+1
    input  wire                 on_pluck_fast, // 吉他：激励衰减加速一档（10.5 ms → 2.6 ms）
    input  wire [31:0]          on_beat,

    // 装载总线（本声部被选中时 ld_for_me 高 1 拍）
    input  wire                 ld_for_me,
    input  wire [N_PART*17-1:0] ld_env_flat,
    input  wire [N_PART*32-1:0] ld_inc_flat,
    input  wire [31:0]          ld_f0,        // 新音符基频（滑音目标）
    input  wire signed [31:0]   ld_gstep,     // 滑音步进 = (目标−当前)/N

    // note-off（广播；本声部自己比对音号）
    input  wire                 off_pulse,
    input  wire [6:0]           off_note,

    // ---- 表情（拓展②）----
    input  wire                 glide_act,    // glide_on 且 glide_time≠0
    input  wire                 vib_act,      // vib_on 且 vib_depth≠0
    input  wire [31:0]          vib_inc,      // LFO 相位增量
    input  wire [11:0]          vib_depth_k,  // 深度（Q16 分数，≤1905）
    input  wire                 sustain,      // 延音踏板
    input  wire                 sus_fall,     // 踏板抬起脉冲

    output wire [31:0]          f0_out,       // 当前基频（引擎算滑音 delta 用）
    output reg  signed [24:0]   vout,
    output wire                 active,
    output wire                 gate_out,
    output wire [6:0]           note_out
);

    // ------------------------------------------------------------ 状态 -------
    reg [PHASE_W-1:0] ph  [0:N_PART-1];      // 各泛音独立相位累加器
    reg [PHASE_W-1:0] inc [0:N_PART-1];      // 各泛音频率字（含非谐性拉伸）
    reg [ENV_W-1:0]   env [0:N_PART-1];      // 各泛音包络（Q32，增益 = [31:16]）

    reg [6:0]  note_r;
    reg        gate_r;
    reg [16:0] velgain_r;
    reg [2:0]  lpsh_r;

    reg [31:0] lfo_ph;                        // 齐奏失谐 LFO（起始相位 90° ⇒ 输出 cos）
    reg [31:0] lfo_inc;

    // ---- 表情状态（拓展②）----
    reg [31:0]        f0_cur;                 // 当前基频（滑音过程中逐采样点变化）
    reg [31:0]        f0_tgt;                 // 目标基频
    reg signed [31:0] gstep_r;                // 滑音每采样点步进
    reg               gliding;                // 正在滑音
    reg               glide_hold;             // 本次装载是"滑音续接"（不重置相位）
    reg               on_pulse_d;             // ★ on_pulse 打一拍：相位清零的两拍窗口
    reg [31:0]        vib_ph;                 // 颤音 LFO 相位（每声部独立）
    reg               sus_pend;               // 踏板踩着时收到 note-off ⇒ 待释放

    reg [ENV_W-1:0]   ham_env;                // 琴槌包络（Q32）
    reg [31:0]        lfsr;                   // 每声部独立噪声源
    reg signed [17:0] nz_lp;                  // 噪声一阶低通状态

    // 流水寄存器
    reg [17:0]        env_q [0:N_PART-1];     // 旧包络的 Q16 增益（多留 2 位余量）
    reg signed [18:0] prod  [0:N_PART-1];     // 各泛音 sin × env
    reg [17:0]        ham_g_q;
    reg signed [17:0] nz_q;
    reg signed [21:0] ham_prod;
    reg [18:0]        uni_q;                  // 齐奏拍频系数（Q16）

    // ---------------------------------------------------- 每泛音常量 --------
    // s_ring/s_damp 由生成脚本给出；用【常量索引】例化查表 ⇒ 综合时折叠成常数移位
    // （零 LUT）。这也是"音高相关衰减不用变移位器"的关键。
    wire signed [15:0] sin_dat [0:N_PART-1];
    wire [4:0]         cf_sr   [0:N_PART-1];
    // ★★ 弓弦驱动（`drive`，2026-10-06）
    //   drv_src = CC21 弓速；**为 0 时用【固定中速兜底 64】** —— 这是"诚实的固定值"，
    //   ⚠️ **不是"力度代理"**（不要读成"力度会影响弓速"）；真实力度代理留待后续。
    wire [6:0]  drv_src = (bow_speed != 7'd0) ? bow_speed : 7'd64;
    wire [31:0] drv_q   = {25'd0, drv_src} << 8;   // k·256（Q32 标度，见包络块注释）
    // ★ 声部内把 drv_on 打一拍（2026-10-06，修 `.tr` 定位出的扇出问题）
    //   原来 `.drv_on(inst_ok == 2'd2)` 是【顶层组合逻辑】直接扇出到 8 声部 × 6 泛音的 env/D
    //   ⇒ `.tr` 最差路径正是 `inst_sel → env_env_.../D`（−1.491），并牵连 ham_env/vib_ph ✗
    //   ⇒ 打一拍后 `inst_sel → 声部` 变成【寄存器到寄存器】✓（多 8 个 FF，每声部 1 个）
    //   ⚠️ `inst_sel` 只在用户切乐器时变 ⇒ 晚 20 ns 无感 ✓
    //   ⚠️ 钢琴 drv_on 恒 0 ⇒ drv_on_r 恒 0 ⇒ 逐值不变 ✓
    reg drv_on_r;
    always @(posedge clk) begin
        if (!rst_n) drv_on_r <= 1'b0;
        else        drv_on_r <= drv_on;
    end
    wire        drv_act = drv_on_r;                // 包络块用（已打拍）
    // ★ 起振档驱动量（常量左移，**无新移位器**）：定速斜坡每拍加 drv_q<<4
    //   ⚠️ 用【定速斜坡】取代"再选一个移位量"：原来 `env >> (cf_sr[j]-4)` 会长出
    //      **第二个 32 bit 变量移位器**（≈160 LUT × 6 泛音 × 8 声部 ≈ **7700 LUT** ✗）
    //      实测 `drive` 让 Logic +8833 ⇒ 就是它（去掉后应回到 ≈27.5k）
    //   ⚠️ 爬升时间 = 2^s/16 = 8192 拍 = **84 ms**（与指数档同量级）
    //   ⚠️ 到顶由"与 drv_q 比较"自然封顶 ⇒ **不需要 sat32** ✓
    wire [31:0] drv_r4 = drv_q << 4;

    wire [4:0]         cf_sd   [0:N_PART-1];
    wire [4:0]         cf_st1  [0:N_PART-1];
    wire [4:0]         cf_st2  [0:N_PART-1];
    wire [16:0]        cf_amp  [0:N_PART-1];
    wire [15:0]        cf_k    [0:N_PART-1];

    genvar gn;
    generate
    for (gn = 0; gn < N_PART; gn = gn + 1) begin : g_part
        localparam [2:0] PN = gn[2:0];
        wire signed [15:0] sd;
        wire [4:0] sr, sdamp, st1, st2;
        wire [16:0] amp_u;
        wire [15:0] k_u;

        piano_sin_rom u_sin (
            .clk   (clk),
            .phase (ph[gn][PHASE_W-1 -: 8]),   // 一个整周期 256 步
            .data  (sd)
        );

        // ⚠️ 每个泛音一份查表实例，输出必须接到【各自的数组元素】。
        //   第一版 6 个实例的输出接在同一根 wire 上（cf_st1_u 等）⇒ 同一网络多驱动，
        //   值会变成线与/x；当时那些线没用上所以没暴露，但一旦拿来算非谐性拉伸
        //   （滑音/颤音要按泛音重算相位增量）就会直接出错。
        piano_partial_lut u_cfg (
            .n       (PN),
            .inst    (2'd0),          // ★★ 必须【常量 0】：这样 s_ring/s_damp/st1/st2
                                      //    才能被综合器折叠成常数移位。
                                      //    若这里接 inst_sel（动态），每采样路径上会立刻
                                      //    长出桶形移位器 —— MODE=1 裕量只有 +0.009 ns。
                                      //    乐器差异已由装载期决定（pl_amp/pl_k/pl_st1/pl_st2）。
            .amp_q16 (amp_u),
            .k_q12   (k_u),
            .s_ring  (sr),
            .s_damp  (sdamp),
            .st1     (st1),
            .st2     (st2)
        );

        assign sin_dat[gn] = sd;
        assign cf_sr[gn]   = sr;
        assign cf_sd[gn]   = sdamp;
        assign cf_st1[gn]  = st1;
        assign cf_st2[gn]  = st2;
        assign cf_amp[gn]  = amp_u;
        assign cf_k[gn]    = k_u;
    end
    endgenerate

    // -------- 齐奏失谐 LFO：起始相位 90° ⇒ 正弦表读出的就是 cos --------
    wire signed [15:0] lfo_cos;
    piano_sin_rom u_lfo (
        .clk   (clk),
        .phase (lfo_ph[PHASE_W-1 -: 8]),
        .data  (lfo_cos)
    );

    // 三弦等幅相加 ⇒ 幅度 ∝ (2+cos)/3 ∈ [1/3, 1]；取 /4 换取一次纯移位，
    // 整体电平差由生成脚本里的幅度系数统一补偿。单根 LFO 支路成本：1 个累加器
    // + 1 份 1/4 波表 + 1 次 17×19 乘法。
    //
    // ★★ 必须全程【有符号】运算 ★★
    //   写成 `(18'd131072 + {lfo_cos, 1'b0}) >>> 2` 是错的：拼接 {signed, 1'b0}
    //   在 Verilog 里是【无符号】的，cos 为负时它的 17 位补码被当成大正数
    //   （cos=-1 → 131070），于是系数在 cos 过零处从 0.25 直接跳到 1.0 ——
    //   不是慢速起伏，而是一个大幅锯齿 + 直流偏置。
    //   本项目实测症状：单音波形 mean=+9551（满幅 32767），正半周恒削顶。
    wire signed [17:0] cos2   = $signed({{2{lfo_cos[15]}}, lfo_cos}) <<< 1; // 2·cos
    wire signed [19:0] uni_sum = 20'sd131072 + {{2{cos2[17]}}, cos2};       // 2+cos
    wire signed [19:0] uni_calc = uni_sum >>> 2;                            // (2+cos)/4 ∈ [0.25,0.75]

    // ===================== 表情调制（拓展②：颤音 + 滑音）=========================
    //  ★ 映射公式（也写在 piano_engine.v 文件头）：
    //    颤音：f_inst = f_note × (1 + sin(2π·f_lfo·t)·depth_k/65536)
    //          f_lfo = vib_rate × 0.1 Hz；depth_k = vib_depth × 15
    //          ⇒ vib_depth 0..127 → ±0 .. ±2.907 % → ±0 .. ±49.6 cent（线性）
    //    滑音：f_note(t) 从 f_old 线性推进到 f_new，N = glide_time×4ms×fs 个采样点
    //          f0_cur += (f_new − f_old)/N 每采样点一次
    //  ★★ 回归保证：vib_act=0 且 gliding=0 时，下面 inc_use 选的是【原来的 inc[]】，
    //     相位通路逐位与加表情前一致（不是"应该一样"，是结构性同一条通路）。
    wire signed [15:0] vib_sin;
    piano_sin_rom u_vib_lfo (
        .clk   (clk),
        .phase (vib_ph[PHASE_W-1 -: 8]),
        .data  (vib_sin)
    );

    // 频偏分数（Q16）：dev = sin × depth_k / 32768
    wire signed [26:0] vib_dev_full = vib_sin * $signed({1'b0, vib_depth_k}); // 16×12 → 27

    // ★★ 表情调制链【必须打拍】，否则是 MODE=1 独有的一条超长组合路径 ★★
    //   链条本来是：vib_ROM → 乘1(16×12) → 乘2(33×12) → 33 bit 加法
    //               → 6 路泛音增量重算(移位加法) → mux → 相位加法器
    //   两级乘法串在一拍里，实测/推算单周期收敛不了。
    //   MODE=1 报告的最差裕量 −4.670 ns（24.67 ns vs 20 ns）、且只有 MODE=1 才有这条路径，
    //   与"表情输入在 MODE=0 被常量折叠"完全吻合 ⇒ 高度怀疑就是它。
    //   现在插两级寄存器，把链切成 4 段短逻辑（每段 ≤ 约 5 ns）：
    //     stage1 乘1 → vib_dev_r      stage2 乘2+加 → f0_mod_r
    //     stage3 6 路移位加法 → inc_vib_r（本来就有）
    //   ⚠️ 对回归零影响：vib_act=0 且 gliding=0 时 pmod_act=0，mux 仍选原来的 inc[j]，
    //      这条链整条是死逻辑（不参与输出）。⚠️ 两级寄存器都要复位（防 X 传播）。
    reg signed [11:0] vib_dev_r;
    reg        [31:0] f0_mod_r;
    wire signed [11:0] vib_dev = vib_dev_full[26:15];
    // f0_mod = f0_cur × (1 + dev/65536) = f0_cur + ((f0_cur × dev) >> 16)
    //   ★ 别写成"乘 18 bit 增益 (65536+dev)"：那是 33×18 大乘法。
    wire signed [44:0] f0_mod_full2 = $signed({1'b0, f0_cur}) * vib_dev_r; // 33×12 → 45 bit

    always @(posedge clk) begin
        if (!rst_n) begin
            vib_dev_r <= 12'sd0;
            f0_mod_r  <= 32'd0;
        end else begin
            vib_dev_r <= vib_dev;
            f0_mod_r  <= {1'b0, f0_cur}
                       + {{4{f0_mod_full2[44]}}, f0_mod_full2[44:16]};
        end
    end

    // 滑音推进：f0_next = f0_cur + gstep，到达目标就停
    wire signed [32:0] f0_cur_s = {1'b0, f0_cur};
    wire signed [32:0] gstep_s  = {{1{gstep_r[31]}}, gstep_r};
    wire signed [32:0] f0_next  = f0_cur_s + gstep_s;
    wire        [32:0] f0_next_u = f0_next;            // 值恒为正（起点终点都 ≥0）
    wire        [32:0] f0_tgt_u  = {1'b0, f0_tgt};
    wire glide_done = (gstep_r > 32'sd0) ? (f0_next_u >= f0_tgt_u)
                                         : (f0_next_u <= f0_tgt_u);

    // 音高调制是否生效：颤音开 或 正在滑音
    wire pmod_act = vib_act | gliding;

    // 用【被调制的基频】重算 6 个泛音的相位增量（非谐性拉伸同样适用）
    //   inc_vib[n] = n·f0_mod + (f0_mod>>st1) + (f0_mod>>st2)  —— 纯移位加法，无乘法器
    wire [31:0] inc_vib [0:N_PART-1];
    generate
    for (gn = 0; gn < N_PART; gn = gn + 1) begin : g_modinc
        localparam integer NP = gn + 1;
        wire [32:0] f0e = {1'b0, f0_mod_r};
        wire [32:0] nf0 = (NP == 1) ?  f0e                    :
                          (NP == 2) ? (f0e << 1)              :
                          (NP == 3) ? ((f0e << 1) + f0e)      :
                          (NP == 4) ? (f0e << 2)              :
                          (NP == 5) ? ((f0e << 2) + f0e)      :
                                      ((f0e << 2) + (f0e << 1));
        assign inc_vib[gn] = nf0 + (f0e >> cf_st1[gn]) + (f0e >> cf_st2[gn]);
    end
    endgenerate

    // ★ 回归开关：表情关闭时走原来的 inc[]（逐位一致）
    // ★ inc_vib 先打一拍：这样"调制链(乘法+6 路移位加法)"与"相位累加器"之间
    //   多了一级寄存器，相位累加器输入只剩一个 mux。
    //   表情关闭时 mux 选 inc[j] ⇒ 与原通路**逐位相同**，回归不受影响。
    reg [PHASE_W-1:0] inc_vib_r [0:N_PART-1];
    integer           ij;                     // ⚠️ 不能用 j：j 在本模块更靠后才声明
    always @(posedge clk) begin
        if (!rst_n)
            for (ij = 0; ij < N_PART; ij = ij + 1) inc_vib_r[ij] <= {PHASE_W{1'b0}};
        else
            for (ij = 0; ij < N_PART; ij = ij + 1) inc_vib_r[ij] <= inc_vib[ij];
    end

    wire [PHASE_W-1:0] inc_use [0:N_PART-1];
    generate
    for (gn = 0; gn < N_PART; gn = gn + 1)
        assign inc_use[gn] = pmod_act ? inc_vib_r[gn] : inc[gn];
    endgenerate

    assign f0_out = f0_cur;

    // ------------------------------------------------------ 组合：状态量 ----
    reg act_c;
    integer j;
    always @(*) begin
        act_c = gate_r;
        for (j = 0; j < N_PART; j = j + 1)
            act_c = act_c | (|env[j][ENV_W-1 -: 8]);
    end
    assign active   = act_c;
    assign gate_out = gate_r;
    assign note_out = note_r;

    // 音高相关衰减档位：k = clamp((90-note)>>4, 0, 2)
    //   高音 k=0（衰减最快）→ 低音 k=2（衰减最慢），与 AMY"音越高衰减越快"一致
    //   实测时间常数 τ(基频) = 2^(s_ring+k)/fs：
    //     高音 C6 ≈ 1.34 s（T60≈9 s） / 中音 A4 ≈ 2.68 s（T60≈18 s）
    //     / 低音 C2 ≈ 5.37 s（T60≈37 s）—— 量级与 AMY、Faust STK 的实测一致
    //   实现方式：每 2^k 个采样点才更新一次包络（移位量仍为常数）
    wire [6:0] kraw = (note_r >= 7'd90) ? 7'd0 : (7'd90 - note_r);
    wire [2:0] ktmp = kraw[6:4];                                  // 0..5
    // ================= 多乐器：衰减档位（阶段1b）=========================
    // ⚠️ 这里为什么写得"绕"（后人别简化它）：
    //   原逻辑是 ksh = clamp((90-note)>>4, 0, 2)。若直接把 clamp 上限改成 3，
    //   **note ≤ 42 的低音会从 ksh=2 变成 3 ⇒ 低音衰减变慢 ⇒ 钢琴行为改变** ✗
    //   ⇒ 正确做法：钢琴基础档位仍 clamp 到 0..2【不动】，只在最后叠加乐器偏移
    //      并夹到 0..3。这样 inst_ofs=0（钢琴）时 ksh2 ≡ ksh ⇒ 逐位不变（有回归证明）。
    wire [2:0] ksh_base = (ktmp > 3'd2) ? 3'd2 : ktmp;            // 原 clamp 0..2，保持
    wire       ofs_up   = (on_ksh_ofs == 2'd2);                   // 古筝 +1（木共鸣箱更长）
    wire       ofs_dn   = (on_ksh_ofs == 2'd0);                   // 吉他 −1（本体短）
    wire [2:0] ksh_up   = (ksh_base == 3'd2) ? 3'd3 : (ksh_base + 3'd1);
    wire [2:0] ksh_dn   = (ksh_base == 3'd0) ? 3'd0 : (ksh_base - 3'd1);
    wire [2:0] ksh2     = ofs_up ? ksh_up : (ofs_dn ? ksh_dn : ksh_base);
    wire [DIV_W-1:0] kmask = ({{(DIV_W-4){1'b0}}, 4'd1} << ksh2) - 1'b1;
    wire env_en = ((div_cnt & kmask) == {DIV_W{1'b0}});

    // note-off 命中：本声部正按住、且音号匹配
    wire off_hit = off_pulse & gate_r & (off_note == note_r);

    // 琴槌初值：0.30 × 力度增益（Q16 × Q16 = Q32）
    // 激励初值：乐器相关增益 × 力度增益
    //   ★ 阶段1b：原来用常量参数 HAM_GAIN_Q16(=19661)；现在走 on_ham_gain。
    //     钢琴档 on_ham_gain = 19661 = 原常量 ⇒ 【逐位不变】（回归证明）。
    wire [33:0] ham_init = on_ham_gain * on_velgain;

    // 噪声样点（显式 signed：拼接结果是无符号的，必须先转换再参与有符号减法）
    wire signed [17:0] nz_s = {{2{lfsr[31]}}, lfsr[31:16]};

    // ------------------------------------------------------- 主状态更新 -----
    always @(posedge clk) begin
        if (!rst_n) begin
            for (j = 0; j < N_PART; j = j + 1) begin
                ph[j]    <= {PHASE_W{1'b0}};
                inc[j]   <= {PHASE_W{1'b0}};
                env[j]   <= {ENV_W{1'b0}};
                env_q[j] <= 18'd0;          // ★ 必须复位：否则首个 tick 之前它是 X，
                                            //   乘出来 prod=X → vout=X → mix_out 全程 X
            end
            note_r    <= 7'd0;
            gate_r    <= 1'b0;
            velgain_r <= 17'd0;
            lpsh_r    <= 3'd3;
            lfo_ph    <= 32'h4000_0000;      // 90°
            lfo_inc   <= 32'd0;
            ham_env   <= {ENV_W{1'b0}};
            ham_g_q   <= 18'd0;              // ★ 同上：不复位会让琴槌支路永久 X
            nz_q      <= 18'sd0;             // ★ 同上
            lfsr      <= 32'h9E37_79B9 ^ (ID * 32'h1234_5678);
            nz_lp     <= 18'sd0;
            f0_cur    <= 32'd0;
            f0_tgt    <= 32'd0;
            gstep_r   <= 32'sd0;
            gliding   <= 1'b0;
            glide_hold<= 1'b0;
            vib_ph    <= 32'd0;
            sus_pend  <= 1'b0;
            on_pulse_d<= 1'b0;
        end else begin
            // =================================================================
            // 🔴 两拍清零窗口【已撤销】（2026-10-06，真板 A/B 定位）
            //
            // 原方案：`if (on_pulse_d) ph[j] <= 0;` 放在块首（最低优先级），
            //         想让 on_pulse 的脉冲捕获有两拍余量。
            //
            // 我曾用"512 个 note-on 相位 × 16 样本 sha256 完全相同"证明它等价 ——
            // **但那个证明只覆盖了【单个 A4 音符、无滑音】的场景**，
            // 完全没覆盖 `gliding=1` 的状态。
            //
            // 真板 A/B（用户听感）+ 我自己的逐样本 A/B（含非零表情）实测：
            //   piano_glide.txt  OLD(听感好) 20271181550028DA
            //                    NEW(听感坏) 13847AB0F92B2C25   ← rms 差 37.6%
            //   把窗口关掉：     20271181550028DA  ← **逐字节恢复到听感好的那一版**
            // ⇒ **窗口确实改变了滑音路径的行为**，不是"等价变换"。
            // ⇒ 撤销。它本来也【不会减少综合报告的违例数】（工具不知道这个窗口），
            //    所以撤掉它**不损失任何时序收益**，只去掉一个真实的行为改动。
            //
            // ⚠️ 教训（AGENTS §9）：证据的覆盖范围必须对准结论。
            //    我证明的是"单音、无滑音、全相位不变"，
            //    结论却是"改动安全" —— 缺口正好落在滑音上。
            // =================================================================

            // =================================================================
            // ★★ 赋值顺序 = 优先级，这里【必须】先写周期更新、后写事件 ★★
            //
            // 同一次 always 里对同一寄存器多次非阻塞赋值时，**最后写的那个生效**。
            // 第一版把装载块写在 sample_tick 块【前面】，于是当 ld_for_me 与
            // sample_tick 撞在同一拍时，包络衰减分支会用"旧包络(=0，新声部)"把刚
            // 装载进去的初值覆盖成 0 —— 声部被分配了、note_r 也对，但 env 恒 0，
            // 结果是【这一拍被分配的音符完全没声音】。
            // 本项目的真实症状（flow-verifier 独立 TB，TICKDIV=8）：
            //   A4 响、A5 与 C4 完全无声（active 位图却"正常"），
            //   因为它的测试序列相位固定，撞拍是确定性的。
            // 真机 TICKDIV=512 时撞拍概率 1/512，但会表现为"偶发丢音"，
            // 必须从结构上消灭，而不是靠概率小。
            // =================================================================

            // ---------------- 1) 采样节拍：周期更新 ----------------
            if (sample_tick) begin
                // 相位：静音声部冻结（新音符从上次相位继续，和弦叠加才符合预期）
                // ★ inc_use：表情全关时它就是原来的 inc[j]（逐位一致，见上面的回归说明）
                for (j = 0; j < N_PART; j = j + 1)
                    if (gate_r || act_c)
                        ph[j] <= ph[j] + inc_use[j];

                // 包络：按住 → s_ring 慢衰减；松开 → s_damp 快衰减（阻音器）
                // cf_sr/cf_sd 是常数 ⇒ 这里是"两次常数移位 + 一个 2:1 选择"
                // ★ 弓弦持续供能（2026-10-06，`drive`；只对二胡，drv_on=0 ⇒ 与原来【逐值相同】）
                //   env 是 **32 bit Q32**（ENV_W=32，增益=[31:16]）；17 bit 的是装载总线 ld_env_bus。
                //   驱动字 drv_q = drv_src << 8（k·256）⇒ 稳态 env* = drv_q·2^s = k·512 的增益
                //   ⚠️ 起振用【定速斜坡】：env += drv_q<<4，**复用现有移位器**做"到顶判定"
                //      （`(env>>s) < drv_q` ⇔ `env < env*`）⇒ 既不加移位器、也不需要 sat32 ✓
                //      ⇒ 面积：去掉那个多余的 32 bit 变量移位器（≈7700 LUT）✓
                //      ⇒ 时序：路径只剩 比较 + mux + 加法 ≈ 3 级 ✓
                //   ⚠️ 到顶判据 `(env>>s) < drv_q` 在两档下都成立 ⇒ 斜坡停在 env* ✓（不会停在 1/16 ✓）
                //      —— 上一版"只改衰减不改驱动"会停在 6% 振幅，那是我算出来的错，已修 ✓
                //   ⚠️ 稳态峰值 k=127、s=17 ⇒ env*=4.26e9；斜坡最多再冲 drv_r4=5.2e5
                //      ⇒ 4.261e9 < 2^32=4.295e9 ⇒ **不会溢出** ✓
                //   ⚠️ !gate_r ⇒ 不加驱动 ⇒ 抬弓自动归零、s_damp 快释放生效 ✓
                for (j = 0; j < N_PART; j = j + 1) begin
                    if (!gate_r)
                        env[j] <= env[j] - (env[j] >> cf_sd[j]);
                    else if (env_en) begin
                        if (drv_act && ((env[j] >> cf_sr[j]) < drv_q))
                            env[j] <= env[j] + drv_r4;                       // 定速斜坡（常量左移）
                        else if (drv_act)
                            env[j] <= env[j] - (env[j] >> cf_sr[j]) + drv_q; // 稳态
                        else
                            env[j] <= env[j] - (env[j] >> cf_sr[j]);         // 钢琴/吉他：原样
                    end
                end

                // 齐奏失谐 LFO
                lfo_ph <= lfo_ph + lfo_inc;

                // 颤音 LFO（每声部独立相位；note-on 时清零 ⇒ 起音瞬间频偏为 0）
                vib_ph <= vib_ph + vib_inc;

                // 滑音：逐采样点把 f0_cur 线性推向 f0_tgt，到位就锁死并停
                //   ⚠️ 插值做在【相位增量】这一侧的分频上（f0_cur 是基频字），
                //      不是每采样点直接跳频率字 —— 频率是连续变化的，不会爆音。
                if (gliding) begin
                    if (glide_done) begin
                        f0_cur  <= f0_tgt;
                        gliding <= 1'b0;
                    end else begin
                        f0_cur <= f0_next_u[31:0];
                    end
                end

                // 琴槌：包络衰减 + 噪声推进 + 一阶低通（力度大 ⇒ 档位小 ⇒ 更亮）
                //   ⚠️ 无条件更新：note-off 之后同样继续衰减，不会残留噪声
                //   ⚠️ nz_s 必须显式声明为 signed 再参与减法：写成
                //      {{2{lfsr[31]}}, lfsr[31:16]} - nz_lp 时，拼接是【无符号】，
                //      整个减法会被当成无符号运算，负半周全错（听感是噪声变成直流偏置）
                // ★ 多乐器（阶段1b）：吉他拨片瞬态比钢琴毛毡短得多
            //   额外一档【常量移位】衰减抽头，由 on_pluck_fast 门控：
            //   τ(HAM_SH=10) ≈ 10.5 ms → 加 >>8 后 ≈ 2.6 ms
            //   ⚠️ 刻意用"常量移位 + 门控"，不是变量移位（那会长出桶形移位器，
            //      而 MODE=1 的最差裕量只有 +0.009 ns）。
            //   ⚠️ 钢琴 on_pluck_fast=0 ⇒ 该项恒为 0 ⇒ 逐位不变。
            ham_env <= ham_env - (ham_env >> HAM_SH)
                              - (on_pluck_fast ? (ham_env >> (HAM_SH-2)) : 32'd0);
                lfsr    <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
                nz_lp   <= nz_lp + ((nz_s - nz_lp) >>> lpsh_r);

                // 流水第一级：快照【旧】包络 / 旧琴槌增益 / 旧噪声
                //   （正弦 ROM 也在这一拍锁存旧相位，两者天然对齐）
                for (j = 0; j < N_PART; j = j + 1)
                    env_q[j] <= {2'b0, env[j][ENV_W-1 -: 16]};
                ham_g_q <= {2'b0, ham_env[ENV_W-1 -: 16]};
                nz_q    <= nz_lp;
            end

            // ---------------- 2) note-on（1 拍，优先级高于周期更新）---------
            if (on_pulse) begin
                note_r    <= on_note;
                gate_r    <= 1'b1;
                velgain_r <= on_velgain;
                lpsh_r    <= on_lpsh;
                lfo_ph    <= 32'h4000_0000;   // 每次击弦拍频从 cos 顶点开始（无起音突变）
                lfo_inc   <= on_beat;
                vib_ph    <= 32'd0;           // 颤音从 0 相位起（起音无频偏跳变）
                nz_lp     <= 18'sd0;          // 噪声从 0 起（避免直流跳变）
                ham_env   <= ham_init[31:0];
                sus_pend  <= 1'b0;            // 新击弦清掉"待释放"
                // 相位归零：6 个泛音同相起振 ⇒ 起音瞬间叠加出冲击感（真实琴槌亦如此）
                // ⚠️ 滑音续接时【不】归零：归零会让波形相位突变 ⇒ 滑音一开始就"咔"一声
                if (!(glide_act && (gate_r || act_c)))
                    for (j = 0; j < N_PART; j = j + 1)
                        ph[j] <= {PHASE_W{1'b0}};
                // 记录本次是否是"滑音续接"（装载那拍才知道要不要启动 ramp）
                glide_hold <= glide_act && (gate_r || act_c);
            end

            // ---------------- 3) note-off / 延音踏板 ----------------
            if (off_hit) begin
                if (sustain) sus_pend <= 1'b1;   // 踏板踩着：只记账，不落阻尼器
                else         gate_r   <= 1'b0;   // 与加踏板之前完全一致
            end
            // 踏板抬起：把"待释放"的声部一次性放掉
            //   （加 ~on_pulse：同一拍正好有新击弦时不要把它掐掉）
            if (sus_fall && sus_pend && !on_pulse) begin
                gate_r   <= 1'b0;
                sus_pend <= 1'b0;
            end

            // ---------------- 4) 装载总线（最高优先级，必须写在最后）--------
            if (ld_for_me) begin
                for (j = 0; j < N_PART; j = j + 1) begin
                    env[j] <= {ld_env_flat[j*17 +: 17], 16'd0};   // Q16 → Q32
                    inc[j] <= ld_inc_flat[j*32 +: 32];
                end
                f0_tgt <= ld_f0;
                if (glide_hold) begin
                    gstep_r <= ld_gstep;      // 从当前 f0_cur 滑向目标
                    gliding <= 1'b1;
                end else begin
                    f0_cur  <= ld_f0;         // 无滑音：一步到位（与加表情前一致）
                    gstep_r <= 32'sd0;
                    gliding <= 1'b0;
                end
                glide_hold <= 1'b0;
            end
            // 两拍清零窗口用的延迟脉冲（放在块末尾即可：它是独立寄存器，
            // 不参与上面的优先级覆盖关系）
            // on_pulse_d <= on_pulse;  // 随两拍窗口撤销
        end
    end

    // ------------------------------------------------------- 流水第二级 -----
    // 16 bit 有符号正弦 × 17 bit 包络 → 35 bit 乘积（全宽形成）→ >>16
    wire signed [34:0] pf [0:N_PART-1];
    generate
    for (gn = 0; gn < N_PART; gn = gn + 1) begin : g_prod
        assign pf[gn] = $signed(sin_dat[gn]) * $signed({1'b0, env_q[gn]});
    end
    endgenerate

    // 琴槌：18 bit 噪声 × 18 bit 增益 → 37 bit
    wire signed [36:0] hpf = nz_q * $signed({1'b0, ham_g_q});

    // ★★ 位选（part-select）在 Verilog 里【永远是无符号】，赋给更宽的 signed 变量时
    //    会被【零扩展】而不是符号扩展 —— 负的半周会变成接近满量程的正数。
    //    本项目实测症状：ham_prod 在 ±2.1e6（≈ 2^21）之间跳，单音输出被顶到
    //    +32767 恒削顶、mean=+9551。修法：拼 $signed()，或让两侧位宽完全一致。
    //    （下面 prod 两侧恰好同宽 19 bit，所以本来就对；ham_prod 是 21→22，
    //      必须显式 $signed。）
    always @(posedge clk) begin
        if (!rst_n) begin
            for (j = 0; j < N_PART; j = j + 1)
                prod[j] <= 19'sd0;
            ham_prod <= 22'sd0;
            uni_q    <= 19'd0;
        end else begin
            for (j = 0; j < N_PART; j = j + 1)
                prod[j] <= $signed(pf[j][34:16]);   // 等价于 >>> 16（有符号）
            ham_prod <= $signed(hpf[36:16]);
            uni_q    <= uni_calc[18:0];             // 正值，0.25..0.75 Q16
        end
    end

    // ------------------------------------------------------- 流水第三级 -----
    reg signed [21:0] psum;
    always @(*) begin
        psum = 22'sd0;
        for (j = 0; j < N_PART; j = j + 1)
            psum = psum + prod[j];
    end

    // 22 bit × 19 bit → 41 bit（全宽）→ >>16 ⇒ 取 [40:16]
    wire signed [40:0] vmul = psum * $signed({1'b0, uni_q});

    // ★★ 位选（part-select）在 Verilog 里【永远是无符号】的 ★★
    //   写成 `vmul[40:16] + ham_prod` 时，因为左操作数无符号，整个加法被当成
    //   无符号运算：负的 ham_prod 会被【零扩展】成一个大正数加进去，
    //   结果是输出被顶到 +32767 恒削顶（本项目实测：单音 RMS 直接爆表、
    //   松键后电平反而更大 —— 因为噪声项的符号全错）。
    //   必须用 $signed() 把位选恢复成有符号再相加。
    wire signed [24:0] vscale = $signed(vmul[40:16]);

    always @(posedge clk) begin
        if (!rst_n) vout <= 25'sd0;
        else        vout <= vscale + ham_prod;
    end

endmodule

`default_nettype wire
