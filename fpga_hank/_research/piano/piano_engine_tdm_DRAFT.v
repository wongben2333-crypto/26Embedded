// ############################################################################
// ⚠️⚠️ 这是【未完成的草稿】，不是可综合、可构建的 RTL —— 2026-10-06 piano-tone
//
//  它【不能编译】：vg_bus17 未声明、相位/包络数组的写回未实现、f0/vgain 未装载。
//  因此我已把它从 rtl/synth/ 【移出】到这里，避免被构建脚本的 rtl/synth/*.v
//  通配捡进去而弄坏构建（这类"半成品混进构建"正是本项目栽过的坑）。
//
//  保留它的价值：BSRAM 纪律(SDP/不同址同拍/读寄存)与 512 拍调度/带宽核算的
//  【设计意图】写在这里，阶段 2 实现时按它走；但**不要当它能用**。
// ############################################################################// =============================================================================
//  piano_engine_tdm.v —— 32 声部【时分复用】钢琴引擎（阶段 1：TDM 核对齐）
//
//  目标（Lead 已批准方案 B）：用「每采样点 512 个时钟」换乘法器，
//  把 32 声部 × 6 泛音的乘法【串行化】到共享 DSP 上，
//  使 DSP 占用与声部数【解耦】（8 声部引擎 ≈115.5 DSP；本方案目标 ≈4~8）。
//
//  ⚠️ 本文件是【阶段 1】，明确不含（也不假装含）以下内容：
//     · 琴槌激励、非谐性拉伸、齐奏失谐、颤音/滑音调制、软膝限幅
//     · 因此【还没有】与 8 声部引擎 bit 级一致（判据 4 属阶段 2/3）
//     阶段 1 要证明的是【架构可行】：调度排得下、带宽够、状态往返正确、
//     能真正发声（可 FFT 验频率）。架构风险是最大风险，所以先证它。
//
//  ============================ BSRAM 纪律（按 EFFECTS-IMPL.md）===============
//  ① 138K 【不支持 Read-before-Write】⇒ 读 addr k 与写回 addr k 必须隔 ≥1 拍
//     本模块：step 发出地址（t 拍）→ 读数据寄存（t+1）→ 写回（t+2）⇒ 不同址同拍 ✅
//  ② 真双口 DP 不支持 32 位；512×32 只有 SP/SDP/ROM ⇒ 用【SDP 模式】：
//     A 口只写、B 口只读（本模块写法即该模式：一读一写、不同址）
//  ③ 读路径必须寄存 ⇒ 本模块读数据显式过一级寄存器（`ph_rd_r`/`env_rd_r`）
//  ④ 一块 BSRAM = 18 Kbit；每数组 N_VOICES*N_PART=192 字 × 32 bit = 6 Kbit
//     ⇒ 每数组 1 块够；为给"读延迟 2 拍"留余量，实际可每数组放 2 块并行（综合时按需）
//
//  ============================ 时分复用调度 ==================================
//  一个采样点 = 512 clk。调度把 (声部, 泛音) 对编号 step = voice*N_PART + gn：
//    step 0..191  ：算 32 声部 × 6 泛音（相位/包络读改写 + 共享乘法）
//    step 192..511：空闲（⇒ 320 拍余量，用来吸收 note-on 装载的停顿）
//  带宽核算（每采样点）：
//    数组读 192 + 数组写 192 = 384 ≤ 512 ✅   DSP 乘 ≈192+32 = 224 ≤ 512 ✅
//  ⚠️ 装载用【停顿调度器】的方式实现：note-on 到来时占用 6 拍写 6 个泛音初值，
//     调度器顺延。因为空闲 320 拍 ≫ 一次装载 6 拍 ⇒ 一个采样点内可吸收 ~50 次装载，
//     远超 UART/MIDI 的实际音符速率 ⇒ 安全。**但这是阶段 1 的简化**：
//     阶段 2 应改成"尾部装载窗口"（step 384..511）以免极端情况挤占。
//
//  ⚠️ 刻意避免的东西（与 8 声部引擎同样的红线）：
//     · 不引入桶形移位器：`env >> s_ring[n]`、`f0 >> st1[n]` 都用
//       `case (n)` 选【常量移位后的值】再 mux ⇒ 移位是免费布线，只有 mux 成本
//     · 不在每拍新增宽乘法以外的组合深度
// =============================================================================
`default_nettype none
module piano_engine_tdm #(
    parameter integer N_VOICES = 32,
    parameter integer N_PART   = 6,
    parameter integer OUT_SHIFT = 23          // 累加 → 16 bit 输出（待与 8 声部引擎对齐）
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_tick,           // 每 512 clk 一拍
    input  wire        on_valid,
    input  wire [6:0]  on_note,
    input  wire [6:0]  on_vel,
    input  wire        off_valid,
    input  wire [6:0]  off_note,
    input  wire        glide_on,
    input  wire [6:0]  glide_time,
    input  wire        vib_on,
    input  wire [6:0]  vib_depth,
    input  wire [6:0]  vib_rate,
    input  wire        sustain,
    input  wire [1:0]  inst_sel,
    output reg  signed [15:0] mix_out,
    output wire [N_VOICES-1:0] active
);
    localparam integer NSTEP = N_VOICES * N_PART;      // 192
    localparam integer SW    = 9;                      // step 位宽（512）

    // ----------------------------------------------------------- 状态数组 ----
    // SDP 模式：一读一写、不同址、读数据寄存 ⇒ 综合成 BSRAM
    reg [31:0] ph_ram  [0:NSTEP-1];
    reg [31:0] env_ram [0:NSTEP-1];

    // 每声部元数据（寄存器，192 个 32 bit 数组太贵 ⇒ 只存 6 个初值/声部也可，
    // 阶段 1 直接存相位/包络在数组里，f0/门/力度按声部存寄存器）
    reg [31:0] f0    [0:N_VOICES-1];
    reg [17:0] vgain [0:N_VOICES-1];       // 力度增益 Q16（18 bit 便于对齐）
    reg        gate  [0:N_VOICES-1];

    reg [31:0] f0_bus;
    reg [17:0] vg_bus;
    piano_note_lut u_note_lut (.note(on_note), .f0_step(f0_bus), .beat_step());
    piano_vel_lut  u_vel_lut  (.vel(on_vel), .inst(inst_sel),
                               .gain_q16(vg_bus17), .lp_sh());

    // ------------------------------------------------------- 调度器 ----------
    reg [SW-1:0] step;
    reg          pass_done;
    reg [6:0]    load_cnt;                  // 装载剩余拍数
    reg [SW-1:0] load_addr;
    reg [31:0]   load_ph, load_env;
    reg          loading;

    wire [SW-1:0] step_nxt = step + 1'b1;
    wire          last_step = (step == NSTEP-1);

    // 当前 step 对应的声部/泛音
    wire [6:0] gn   = step % N_PART;                  // 0..5
    wire [6:0] vsel = step / N_PART;                  // 0..31
    wire [6:0] gn_d;
    wire [6:0] vsel_d;
    reg  [6:0] gn_r, vsel_r;

    // ------------------------------------------------- 读级（第 1 拍）--------
    reg [31:0] ph_rd_r, env_rd_r;
    always @(posedge clk) begin
        if (!rst_n) begin
            gn_r <= 7'd0; vsel_r <= 7'd0;
            ph_rd_r <= 32'd0; env_rd_r <= 32'd0;
        end else if (loading) begin
            // 装载期间不推进读级（调度器停顿）
        end else if (step < NSTEP) begin
            gn_r    <= gn;
            vsel_r  <= vsel;
            ph_rd_r <= ph_ram[step];      // ← SDP 读（地址寄存，数据下一拍可用）
            env_rd_r<= env_ram[step];
        end
    end

    // ------------------------------------------------- 常量移位 + mux -------
    // env' = env - (env >> s_ring[n])；s_ring 用与 8 声部引擎同一组常量
    // 用 case 选常量移位后的值 ⇒ 不产生桶形移位器
    reg [31:0] env_dec;
    always @(*) begin
        case (gn_r)
            7'd0: env_dec = env_rd_r >> 17;
            7'd1: env_dec = env_rd_r >> 16;
            7'd2: env_dec = env_rd_r >> 15;
            7'd3: env_dec = env_rd_r >> 14;
            7'd4: env_dec = env_rd_r >> 13;
            default: env_dec = env_rd_r >> 12;
        endcase
    end
    wire [31:0] env_nxt = env_rd_r - env_dec;

    // inc = n·f0 + (f0>>st1) + (f0>>st2)，n = gn_r+1（非谐性项阶段 1 省略，留 0）
    wire [31:0] f0_r  = f0[vsel_r];
    wire [33:0] nf0_r = (gn_r == 7'd0) ? {2'b0, f0_r}        :
                        (gn_r == 7'd1) ? {1'b0, f0_r, 1'b0} :
                        (gn_r == 7'd2) ? ({1'b0, f0_r, 1'b0} + {2'b0, f0_r}) :
                        (gn_r == 7'd3) ? {2'b0, f0_r, 2'b00} :
                        (gn_r == 7'd4) ? ({2'b0, f0_r, 2'b00} + {2'b0, f0_r}) :
                                         ({2'b0, f0_r, 2'b00} + {1'b0, f0_r, 1'b0});
    wire [31:0] ph_nxt = ph_rd_r + nf0_r[31:0];

    // ------------------------------------------------- 乘级（第 2 拍）--------
    wire signed [15:0] sin_d;
    piano_sin_rom u_sin (.clk(clk), .phase(ph_rd_r[31:24]), .data(sin_d));
    wire signed [32:0] prod = sin_d * $signed({1'b0, env_rd_r[31:16]});   // 16×16 → 33

    // 累加（跨整个 pass；每声部 6 项自然按 step 顺序求和）
    reg signed [41:0] acc;
    always @(posedge clk) begin
        if (!rst_n)                       acc <= 42'sd0;
        else if (sample_tick)             acc <= 42'sd0;
        else if (!loading && step < NSTEP) acc <= acc + prod;
    end

    // ------------------------------------------------- 写回（第 3 拍）--------
    always @(posedge clk) begin
        if (!rst_n) begin
            ph_ram[0] <= 32'd0;           // 数组初值由装载路径负责；这里只保证仿真不定态
        end
    end

    // ------------------------------------------------- 装载（note-on） -------
    // 简化实现：note-on 到来即占 6 拍，把 6 个泛音的相位清 0、包络置初值
    reg [6:0] alloc_rr;
    reg       load_pend;
    reg [6:0] pend_voice;
    always @(posedge clk) begin
        if (!rst_n) begin
            loading <= 1'b0; load_cnt <= 7'd0; load_addr <= {SW{1'b0}};
            alloc_rr <= 7'd0; load_pend <= 1'b0; pend_voice <= 7'd0;
            gate[0] <= 1'b0;
        end else begin
            if (on_valid && !loading && !load_pend) begin
                load_pend  <= 1'b1;
                pend_voice <= alloc_rr[6:0];
                alloc_rr   <= (alloc_rr == N_VOICES-1) ? 7'd0 : alloc_rr + 7'd1;
            end
            if (load_pend && !loading) begin
                loading   <= 1'b1;
                load_cnt  <= N_PART[6:0];
                load_addr <= {pend_voice, 3'd0} * N_PART;   // 该声部第一个泛音
                load_pend <= 1'b0;
            end
            if (loading) begin
                load_cnt <= load_cnt - 7'd1;
                load_addr<= load_addr + 1'b1;
                if (load_cnt == 7'd1) loading <= 1'b0;
            end
        end
    end

    // ------------------------------------------------- 输出 ------------------
    always @(posedge clk) begin
        if (!rst_n) mix_out <= 16'sd0;
        else if (sample_tick) mix_out <= acc[41 -: 16];
    end

    assign active = {N_VOICES{1'b1}};

endmodule
`default_nettype wire
