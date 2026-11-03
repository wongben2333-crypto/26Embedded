// =============================================================================
// piano_engine_tdm32.v — 32-Voice x 6-Partial (192 Independent Oscillators)
//                        Time-Division Multiplexed (TDM) Additive/Modal Engine
// Target: Gowin Arora V GW5AST-LV138PG484AC1/I0 (Tang Mega 138K Dock)
// Drop-in Replacement for `piano_engine` (100% Port- & LUT-Compatible with
// `top.v` and `piano_rom.v`: `piano_inst_lut`, `piano_note_lut`, `piano_vel_lut`,
// `piano_vib_lut`, `piano_glide_lut`, `piano_partial_lut`, `piano_sin_rom`).
//
// Competition Topic 2 Score Metric Alignment:
//   - N_VOICES = 32 x N_PART = 6 => 192 simultaneously active audible
//     independent oscillators @ Fs = 97,656.25 Hz (50 MHz / 512 clocks).
//   - Core metric: 192 * 97,656.25 = 1.875 x 10^7 osc*Hz.
//   - Each oscillator (idx = {v[4:0], j[2:0]} in 0..191) has:
//       1. Independent 32-bit Phase Accumulator (`mem_ph[0:255]`, SDPB BSRAM)
//       2. Independent 32-bit Frequency Increment (`mem_inc[0:255]`, SDPB BSRAM)
//       3. Independent 32-bit Exponential/Bowed Envelope (`mem_env[0:255]`, SDPB BSRAM)
//   - Strictly adheres to Gowin Arora V SDPB inference rules (`WRITE_MODE = 0` safe):
//       * Synchronous Read (Stage S0->S1) + Synchronous Write (Stage S3),
//         3-clock pipeline separation (`raddr != waddr`), zero async read.
// =============================================================================
`default_nettype none

module piano_engine_tdm32 #(
    parameter integer N_VOICES  = 32,         // 32复音 × 6泛音 = 192独立振荡器
    parameter integer CLK_HZ    = 50_000_000, // 50 MHz 主时钟
    parameter integer OUT_SHIFT = 1           // 基础输出预缩放右移
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_tick,   // 97,656.25 Hz (每 512 个 clk 1 拍)

    // ---- 音符命令总线 (与 top.v / piano_engine 完全一致) ----
    input  wire        on_valid,
    input  wire [6:0]  on_note,
    input  wire [6:0]  on_vel,
    input  wire        off_valid,
    input  wire [6:0]  off_note,

    // ---- 表情与多乐器输入 (与 top.v / piano_engine 完全一致) ----
    input  wire        glide_on,
    input  wire [6:0]  glide_time,
    input  wire        vib_on,
    input  wire [6:0]  vib_depth,
    input  wire [6:0]  vib_rate,
    input  wire        sustain,
    input  wire [1:0]  inst_sel,      // 0=钢琴, 1=吉他, 2/3=小提琴（同一音色槽）
    input  wire [6:0]  bow_speed,     // CC21 弓速

    // ---- 输出 ----
    output reg  signed [15:0]  mix_out,
    output wire [N_VOICES-1:0] active
);

    localparam integer N_PART = 6;
    localparam integer SEL_W  = 5;
    localparam signed [27:0] KNEE = 28'sd24576;

    // ------------------------------------------------------- 1. 查表实例 ----
    wire [1:0] inst_ok_c = inst_sel; // 0=钢琴, 1=吉他, 2=小提琴, 3=民族二胡
    reg  [1:0] inst_ok;
    always @(posedge clk) begin
        if (!rst_n) inst_ok <= 2'd0;
        else        inst_ok <= inst_ok_c;
    end
    wire is_bowed = (inst_ok == 2'd2) || (inst_ok == 2'd3);

    wire [16:0] inst_ham_gain;
    wire [1:0]  inst_ksh_enc;
    piano_inst_lut u_inst_lut (
        .inst         (inst_ok),
        .ham_gain_q16 (inst_ham_gain),
        .ksh_ofs_enc  (inst_ksh_enc)
    );

    wire [31:0] f0_bus;
    wire [31:0] beat_bus;
    piano_note_lut u_note_lut (
        .note      (on_note),
        .f0_step   (f0_bus),
        .beat_step (beat_bus)
    );

    wire [16:0] vel_gain_bus;
    wire [2:0]  vel_lp_bus;
    piano_vel_lut u_vel_lut (
        .vel      (on_vel),
        .inst     (inst_ok),
        .gain_q16 (vel_gain_bus),
        .lp_sh    (vel_lp_bus)
    );

    wire [31:0] vib_inc_bus;
    wire [6:0]  eff_vib_rate = (!vib_on && is_bowed) ? 7'd56 : vib_rate;
    piano_vib_lut u_vib_lut (
        .rate (eff_vib_rate),
        .inc  (vib_inc_bus)
    );

    wire [15:0] glide_recip_bus;
    piano_glide_lut u_glide_lut (
        .t     (glide_time),
        .recip (glide_recip_bus)
    );

    // ---- 前置声明（标准 Verilog 要求先声明后使用；ModelSim 不容忍前向引用）----
    wire       note_on;
    reg        last_valid;
    reg        ld_busy;

    // ---- 真实进入相位累加器的表情状态（含小提琴渐进揉弦 + 连奏自动滑音） ----
    reg [31:0] vib_phase;
    reg [6:0]  vib_depth_r;
    reg        vib_on_r;
    reg [31:0] vib_inc_r;
    reg [6:0]  vib_swell_cnt;
    reg [7:0]  vib_tick_div;
    reg [31:0] glide_cur_f0, glide_tgt_f0, last_f0_word;
    reg [15:0] glide_recip_r;
    reg        glide_active;

    wire signed [16:0] vib_tri = vib_phase[31]
        ? (17'sd32767 - ({9'd0, vib_phase[30:23]} <<< 8))
        : (-17'sd32768 + ({9'd0, vib_phase[30:23]} <<< 8));
    // vib_tri(Q15) × depth(0..127) -> Q15 fractional frequency offset.
    wire signed [24:0] vib_prod = vib_tri * $signed({1'b0, vib_depth_r});
    // ★ 2026-10-31 修正深度标定：原 >>>7 时 depth=18 → ±14% 频偏（≈±2.3 半音，严重跑调）。
    //   改为 >>>12：depth 0..127 → ±0..±3.1%（≈±0..±53 cent），depth=18 → ±0.44%（≈±7.6 cent），
    //   与 piano_engine.v 文件头"depth 127 ≈ ±49.6 cent"的协议约定一致。
    wire signed [24:0] vib_frac = vib_prod >>> 12;

    wire signed [32:0] glide_diff = $signed({1'b0, glide_tgt_f0})
                                   - $signed({1'b0, glide_cur_f0});
    wire signed [48:0] glide_step_full = glide_diff * $signed({1'b0, glide_recip_r});
    wire signed [32:0] glide_step = glide_step_full >>> 24;

    // 弦乐默认揉弦目标深度 18 (约 ±7 cent @ 5.6 Hz)，起音后渐入；外部 MIDI CC 可覆盖更大深度
    wire [6:0] tgt_vib_depth = vib_on ? vib_depth :
                               is_bowed ? 7'd18 : 7'd0;
    wire       eff_vib_on    = vib_on || is_bowed;

    always @(posedge clk) begin
        if (!rst_n) begin
            vib_phase      <= 32'd0;
            vib_depth_r    <= 7'd0;
            vib_on_r       <= 1'b0;
            vib_inc_r      <= 32'd0;
            vib_swell_cnt  <= 7'd0;
            vib_tick_div   <= 8'd0;
            glide_cur_f0   <= 32'd0;
            glide_tgt_f0   <= 32'd0;
            last_f0_word   <= 32'd0;
            glide_recip_r  <= 16'd65535;
            glide_active   <= 1'b0;
        end else begin
            if (note_on && !ld_busy) begin
                last_f0_word  <= f0_bus;
                // 新音起音瞬间揉弦归零（真实小提琴起弓先稳音再渐入揉弦）
                vib_swell_cnt <= 7'd0;
                vib_tick_div  <= 8'd0;
                if (glide_on && last_valid && glide_time != 7'd0) begin
                    glide_cur_f0  <= last_f0_word;
                    glide_tgt_f0  <= f0_bus;
                    glide_recip_r <= glide_recip_bus;
                    glide_active  <= 1'b1;
                end else begin
                    glide_cur_f0 <= f0_bus;
                    glide_tgt_f0 <= f0_bus;
                    glide_active <= 1'b0;
                end
            end
            if (sample_tick) begin
                vib_on_r  <= eff_vib_on;
                vib_inc_r <= vib_inc_bus;
                if (eff_vib_on) begin
                    vib_phase    <= vib_phase + vib_inc_bus;
                    vib_tick_div <= vib_tick_div + 8'd1;
                    if (vib_tick_div == 8'd255) begin
                        if (vib_swell_cnt < tgt_vib_depth)
                            vib_swell_cnt <= vib_swell_cnt + 7'd1;
                        else if (vib_swell_cnt > tgt_vib_depth)
                            vib_swell_cnt <= tgt_vib_depth;
                    end
                    vib_depth_r <= is_bowed ? vib_swell_cnt : tgt_vib_depth;
                end else begin
                    vib_depth_r <= 7'd0;
                end
                if (glide_active) begin
                    if ((glide_step == 0) ||
                        ((glide_diff[32] == 1'b0) && (glide_step >= glide_diff)) ||
                        ((glide_diff[32] == 1'b1) && (glide_step <= glide_diff))) begin
                        glide_cur_f0 <= glide_tgt_f0;
                        glide_active <= 1'b0;
                    end else begin
                        glide_cur_f0 <= glide_cur_f0 + glide_step;
                    end
                end
            end
        end
    end

    wire        vel_zero     = (on_vel == 7'd0);
    wire        off_any      = off_valid | (on_valid & vel_zero);
    wire [6:0]  off_any_note = (on_valid & vel_zero) ? on_note : off_note;
    assign      note_on      = on_valid & ~vel_zero;

    reg sus_d;
    always @(posedge clk) begin
        if (!rst_n) sus_d <= 1'b0;
        else        sus_d <= sustain;
    end
    wire sus_fall = sus_d & ~sustain;

    // ------------------------------------------------ 2. 32声部状态寄存器 ----
    reg [N_VOICES-1:0] v_gate;
    reg [N_VOICES-1:0] v_sus_pend;
    reg [N_VOICES-1:0] v_act_r;
    reg [6:0]          v_note [0:N_VOICES-1];
    reg [16:0]         v_velg [0:N_VOICES-1];
    assign active = v_act_r;

    // ------------------------------------------------ 3. 32声部树形分配器 ----
    reg [31:0] nm32;
    integer nm_i;
    always @(*) begin
        nm32 = 32'd0;
        for (nm_i = 0; nm_i < N_VOICES; nm_i = nm_i + 1)
            nm32[nm_i] = (v_note[nm_i] == on_note);
    end

    function [4:0] pri32;
        input [31:0] m;
        integer b;
        reg hit;
        begin
            pri32 = 5'd0;
            hit   = 1'b0;
            for (b = 0; b < 32; b = b + 1) begin
                if (!hit && m[b]) begin
                    pri32 = b[4:0];
                    hit   = 1'b1;
                end
            end
        end
    endfunction

    reg [SEL_W-1:0] rr;
    reg [SEL_W-1:0] last_voice;
    // last_valid 已在文件前部前置声明

    wire [31:0] m_same32 = v_gate & nm32;
    wire [31:0] m_idle32 = ~v_act_r;
    wire [31:0] m_rel32  = ~v_gate;
    wire [31:0] ge32     = (32'hFFFF_FFFF << rr);
    wire [31:0] lt32     = ~(32'hFFFF_FFFF << rr);

    wire [4:0] s1_32 = pri32(m_same32);
    wire [4:0] s2_32 = (|(m_idle32 & ge32)) ? pri32(m_idle32 & ge32) : pri32(m_idle32 & lt32);
    wire [4:0] s3_32 = (|(m_rel32  & ge32)) ? pri32(m_rel32  & ge32) : pri32(m_rel32  & lt32);

    wire [SEL_W-1:0] alloc_sel = (glide_on && last_valid) ? last_voice :
                                 (|m_same32)              ? s1_32      :
                                 (|m_idle32)              ? s2_32      :
                                 (|m_rel32)               ? s3_32      : rr;

    // ----------------------------------------- 4. Gowin SDPB BSRAM 状态阵列 ----
    // 256 x 32 bit: 高 5 位 = 声部号 (0..31)，低 3 位 = 泛音号 (0..5)
    // mem_sr 扩展为 28 bit (仍占同一块 18Kbit BSRAM):
    //   [27:12] = 该泛音分量的目标幅度 target_amp (用于小提琴逐泛音按真实频谱比例持续运弓)
    //   [11:10] = 2'b0
    //   [9:5]   = s_ring_eff (含音高衰减偏移 k(note))
    //   [4:0]   = s_damp_eff
    (* ram_style = "block" *) reg [31:0] mem_ph  [0:255];
    (* ram_style = "block" *) reg [31:0] mem_env [0:255];
    (* ram_style = "block" *) reg [31:0] mem_inc [0:255];
    (* ram_style = "block" *) reg [27:0] mem_sr  [0:255];

    integer init_k;
    initial begin
        for (init_k = 0; init_k < 256; init_k = init_k + 1) begin
            mem_ph[init_k]  = 32'd0;
            mem_env[init_k] = 32'd0;
            mem_inc[init_k] = 32'd0;
            mem_sr[init_k]  = {16'd0, 2'b0, 5'd13, 5'd9};
        end
    end

    // ------------------------------------------------ 5. 装载 FSM (Loader) ----
    localparam [1:0] L_IDLE = 2'd0, L_CALC = 2'd1, L_MUL = 2'd2, L_DONE = 2'd3;
    reg [1:0]       ld_st;
    reg [2:0]       ld_idx;
    // ld_busy 已在文件前部前置声明
    reg [SEL_W-1:0] ld_sel;
    reg [31:0]      ld_f0;
    reg [31:0]      ld_beat;
    reg [6:0]       ld_note;
    reg [16:0]      ld_velgain;
    reg [6:0]       ld_vel;
    reg [16:0]      ld_gq;
    reg [15:0]      ld_kq;
    reg [32:0]      ld_nf0_r;
    reg [4:0]       pl_st1_r, pl_st2_r, pl_sr_r, pl_sd_r;
    reg             ld_wr_en;
    reg [7:0]       ld_wr_addr;
    reg [31:0]      ld_wr_inc;
    reg [31:0]      ld_wr_env;
    reg [27:0]      ld_wr_sr;
    reg [31:0]      ld_wr_ph;

    // 五段音区：低音的基波/低次谐波更重，高音逐步增加亮度和弦刚度。
    wire [2:0] band_ld = (on_note >= 7'd84) ? 3'd4 :
                         (on_note >= 7'd72) ? 3'd3 :
                         (on_note >= 7'd60) ? 3'd2 :
                         (on_note >= 7'd48) ? 3'd1 : 3'd0;
    reg [2:0] band_ld_eff;
    always @(posedge clk) begin
        if (!rst_n) band_ld_eff <= 3'd0;
        else if (note_on && !ld_busy) band_ld_eff <= band_ld;
    end

    wire [16:0] pl_amp;
    wire [15:0] pl_k;
    wire [4:0]  pl_sr, pl_sd, pl_st1, pl_st2;
    piano_partial_lut u_ld_lut (
        .n       (ld_idx),
        .band    (band_ld_eff),
        .inst    (inst_ok),
        .amp_q16 (pl_amp),
        .k_q12   (pl_k),
        .s_ring  (pl_sr),
        .s_damp  (pl_sd),
        .st1     (pl_st1),
        .st2     (pl_st2)
    );

    // 音高相关衰减偏移：低音(<F#3)延音加长 +1 档，高音(>=F#5)衰减加快 -1 档
    wire [4:0] pl_sr_pitch = (ld_note < 7'd54 && pl_sr < 5'd18) ? (pl_sr + 5'd1) :
                             (ld_note >= 7'd78 && pl_sr > 5'd9) ? (pl_sr - 5'd1) : pl_sr;

    wire [33:0] ld_gmul   = pl_amp * ld_velgain;
    wire [16:0] ld_g      = ld_gmul[33:16];
    wire [21:0] kvel_prod = pl_k * {15'd0, ld_vel};
    wire [15:0] kvel_q12  = kvel_prod[21:7];
    wire [32:0] ld_bmul   = ld_gq * ld_kq;
    wire [18:0] ld_envsum = {2'b0, ld_gq} + ld_bmul[30:12];
    // 严格饱和至 16-bit Q16 最大值 65535 (16'hFFFF)，防止 65536 (17'h1_0000) 截断低 16 位归零
    wire [15:0] ld_env_clamped = (ld_envsum >= 19'd65535) ? 16'd65535 : ld_envsum[15:0];

    wire [2:0]  ld_n   = ld_idx + 3'd1;
    wire [32:0] ld_f0e = {1'b0, ld_f0};
    wire [32:0] ld_nf0 = (ld_n == 3'd1) ?  ld_f0e                    :
                         (ld_n == 3'd2) ? (ld_f0e << 1)              :
                         (ld_n == 3'd3) ? ((ld_f0e << 1) + ld_f0e)   :
                         (ld_n == 3'd4) ? (ld_f0e << 2)              :
                         (ld_n == 3'd5) ? ((ld_f0e << 2) + ld_f0e)   :
                                          ((ld_f0e << 2) + (ld_f0e << 1));
    // 加入同音多弦失谐拍频 (beat_bus)：奇次与偶次泛音微失谐，赋予三角钢琴/木吉他双弦自然合唱温暖感
    wire [32:0] ld_beat_ofs = (!is_bowed && ld_idx[0]) ? {1'b0, ld_beat} : 33'd0;
    wire [32:0] ld_inc_p1 = ld_nf0_r + (ld_f0e >> pl_st1_r) + (ld_f0e >> pl_st2_r) + ld_beat_ofs;

    // ----------------------------------------- 5b. 物理激励瞬态发生器 (琴槌/拨片/弓毛松香擦弦) ----
    // 16-bit Galois LFSR + 力度自适应双级低通/带通 + 快速指数衰减包络
    reg [15:0]        ham_lfsr;
    reg [15:0]        ham_env;
    reg [2:0]         ham_lp_sh;
    reg signed [15:0] ham_lp1, ham_lp2;

    wire ham_fb = ham_lfsr[15] ^ ham_lfsr[13] ^ ham_lfsr[12] ^ ham_lfsr[10];
    wire signed [15:0] ham_raw = $signed(ham_lfsr);
    wire signed [16:0] ham_d1  = ham_raw - ham_lp1;
    wire signed [16:0] ham_d2  = ham_lp1 - ham_lp2;
    wire signed [15:0] ham_lp1_n = ham_lp1 + (ham_d1 >>> ham_lp_sh);
    wire signed [15:0] ham_lp2_n = ham_lp2 + (ham_d2 >>> ham_lp_sh);
    // 钢琴取双级低通(毛毡锤击木质闷响)，吉他取带通(清脆拨片/指甲微瞬态)，小提琴取微带通(弓毛松香擦弦微触感)
    wire signed [15:0] ham_color = (inst_ok == 2'd1) ? (ham_lp1_n - ham_lp2_n) :
                                   is_bowed ? ((ham_lp1_n - ham_lp2_n) >>> 1) : ham_lp2_n;
    wire signed [32:0] ham_prod  = ham_color * $signed({1'b0, ham_env});
    reg  signed [15:0] ham_sig_r;
    always @(posedge clk) begin
        if (!rst_n) ham_sig_r <= 16'sd0;
        else        ham_sig_r <= ham_prod[31:16];
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            ham_lfsr  <= 16'hACE1;
            ham_env   <= 16'd0;
            ham_lp_sh <= 3'd2;
            ham_lp1   <= 16'sd0;
            ham_lp2   <= 16'sd0;
        end else begin
            if (note_on && !ld_busy) begin
                ham_lp_sh <= vel_lp_bus;
                // 钢琴柔和毛毡锤击、吉他清脆拨片瞬态、小提琴轻柔起弓擦弦
                ham_env   <= (inst_ok == 2'd1) ? (vel_gain_bus[16:2] + 16'd2048) :
                             is_bowed ? (vel_gain_bus[16:3]) :
                                                 (vel_gain_bus[16:2]);
            end else if (sample_tick) begin
                ham_lfsr <= {ham_lfsr[14:0], ham_fb};
                ham_lp1  <= ham_lp1_n;
                ham_lp2  <= ham_lp2_n;
                if (ham_env <= 16'd16) ham_env <= 16'd0;
                else if (inst_ok == 2'd1) ham_env <= ham_env - (ham_env >> 7); // ~1.3 ms 清脆拨片
                else if (is_bowed)        ham_env <= ham_env - (ham_env >> 9); // ~5.2 ms 起弓擦弦
                else                      ham_env <= ham_env - (ham_env >> 8); // ~2.6 ms 琴槌瞬态
            end
        end
    end

    // ----------------------------------------- 6. TDM 4级流水扫描引擎 ---------
    // 每个 sample_tick (512拍) 扫描 32声部 × 6泛音 = 192 步 (占 196 拍，余 316 拍空闲)
    reg        tdm_run;
    reg [4:0]  s0_v;
    reg [2:0]  s0_j;
    wire [7:0] tdm_raddr = {s0_v, s0_j};

    reg [31:0] s1_ph, s1_env, s1_inc;
    reg [27:0] s1_sr_cfg;
    // 对齐同步正弦 ROM 的第二级数据寄存器；rom_* 与 rom_val 属于同一振荡器。
    reg [31:0] rom_ph, rom_env, rom_inc;
    reg [27:0] rom_sr_cfg;
    always @(posedge clk) begin
        if (!rst_n) begin
            s1_ph <= 32'd0; s1_env <= 32'd0; s1_inc <= 32'd0; s1_sr_cfg <= 28'd0;
            rom_ph <= 32'd0; rom_env <= 32'd0; rom_inc <= 32'd0; rom_sr_cfg <= 28'd0;
        end else begin
            s1_ph     <= mem_ph[tdm_raddr];
            s1_env    <= mem_env[tdm_raddr];
            s1_inc    <= mem_inc[tdm_raddr];
            s1_sr_cfg <= mem_sr[tdm_raddr];
            rom_ph    <= s1_ph;
            rom_env   <= s1_env;
            rom_inc   <= s1_inc;
            rom_sr_cfg<= s1_sr_cfg;
        end
    end

    reg       s1_val, rom_val, s2_val, s3_val;
    reg [4:0] s1_v,   rom_v,   s2_v,   s3_v;
    reg [2:0] s1_j,   rom_j,   s2_j,   s3_j;

    wire signed [15:0] sin_rom_dout;
    piano_sin_rom u_shared_sin_rom (
        .clk   (clk),
        .phase (s1_ph[31:24]),
        .data  (sin_rom_dout)
    );

    reg [6:0] drv_src_r;
    reg       drv_on_r;
    always @(posedge clk) begin
        if (!rst_n) begin
            drv_src_r <= 7'd64;
            drv_on_r  <= 1'b0;
        end else begin
            drv_src_r <= (bow_speed != 7'd0) ? bow_speed : 7'd64;
            drv_on_r  <= is_bowed;
        end
    end

    wire [4:0]  rom_s_ring = rom_sr_cfg[9:5];
    wire [4:0]  rom_s_damp = rom_sr_cfg[4:0];
    wire        rom_gate   = v_gate[rom_v];
    // 小提琴逐泛音独立运弓目标包络：严格保持该音区/该泛音的真实声学谐波比例，彻底杜绝32位溢出与高次谐波失衡嗡声
    wire [31:0] rom_base_tgt = {rom_sr_cfg[27:12], 16'd0};
    wire [31:0] rom_bow_tgt  = (drv_src_r >= 7'd96) ? rom_base_tgt :
                               (drv_src_r >= 7'd48) ? (rom_base_tgt - (rom_base_tgt >> 2)) :
                                                      (rom_base_tgt >> 1);

    reg [31:0] rom_env_next_c;
    always @(*) begin
        if (!rom_gate) begin
            if (rom_env <= (32'd1 << rom_s_damp)) rom_env_next_c = 32'd0;
            else                                  rom_env_next_c = rom_env - (rom_env >> rom_s_damp);
        end else if (drv_on_r) begin
            // 指数起弓渐入 (τ ≈ 10.5 ms) 并稳定维持在各泛音的目标幅度
            if (rom_env < rom_bow_tgt)
                rom_env_next_c = rom_env + ((rom_bow_tgt - rom_env) >> 10) + 32'd64;
            else
                rom_env_next_c = rom_env - ((rom_env - rom_bow_tgt) >> 10);
        end else begin
            if (rom_env <= (32'd1 << rom_s_ring)) rom_env_next_c = 32'd0;
            else                                  rom_env_next_c = rom_env - (rom_env >> rom_s_ring);
        end
    end

    reg signed [15:0] s2_sin;
    reg [17:0]        s2_env_q;
    reg [31:0]        s2_inc_mod_q, s2_rom_ph_q, s2_env_next;
    wire signed [34:0] s2_pf = $signed(s2_sin) * $signed({1'b0, s2_env_q});

    // 颤音与滑音在这里真正改变每个振荡器的相位增量。
    // 滑音仅作用于 last_voice，且按泛音阶数 (rom_j+1) 比例缩放，并对 inc_mod_sum 下界钳位防无符号下溢！
    wire signed [48:0] vib_inc_prod = $signed({1'b0, rom_inc}) * vib_frac;
    wire signed [32:0] vib_inc_delta = vib_on_r ? (vib_inc_prod >>> 15) : 33'sd0;
    wire signed [33:0] glide_f0_ofs = $signed({1'b0, glide_cur_f0}) - $signed({1'b0, glide_tgt_f0});
    wire signed [35:0] glide_harm_ofs = (rom_j == 3'd0) ? {{2{glide_f0_ofs[33]}}, glide_f0_ofs} :
                                        (rom_j == 3'd1) ? ({{2{glide_f0_ofs[33]}}, glide_f0_ofs} <<< 1) :
                                        (rom_j == 3'd2) ? (({{2{glide_f0_ofs[33]}}, glide_f0_ofs} <<< 1) + {{2{glide_f0_ofs[33]}}, glide_f0_ofs}) :
                                        (rom_j == 3'd3) ? ({{2{glide_f0_ofs[33]}}, glide_f0_ofs} <<< 2) :
                                        (rom_j == 3'd4) ? (({{2{glide_f0_ofs[33]}}, glide_f0_ofs} <<< 2) + {{2{glide_f0_ofs[33]}}, glide_f0_ofs}) :
                                                          (({{2{glide_f0_ofs[33]}}, glide_f0_ofs} <<< 2) + ({{2{glide_f0_ofs[33]}}, glide_f0_ofs} <<< 1));
    wire signed [35:0] glide_inc_delta = (glide_active && (rom_v == last_voice)) ? glide_harm_ofs : 36'sd0;
    wire signed [35:0] inc_mod_raw = $signed({4'b0, rom_inc})
                                   + {{3{vib_inc_delta[32]}}, vib_inc_delta}
                                   + glide_inc_delta;
    wire [31:0] inc_mod_clamped = (inc_mod_raw <= 36'sd0) ? 32'd0 :
                                  (inc_mod_raw > 36'sd2147483647) ? 32'd2147483647 : inc_mod_raw[31:0];

    reg signed [18:0] s3_prod;
    reg [31:0]        s3_ph_wb, s3_env_wb;

    // BSRAM 写端口：Loader 仅在 `!s2_val` (即下一拍 `s3_val == 0`) 时置位 `ld_wr_en`，零写冲突
    wire        wb_we   = ld_wr_en | s3_val;
    wire [7:0]  wb_addr = ld_wr_en ? ld_wr_addr : {s3_v, s3_j};
    wire [31:0] wb_ph   = ld_wr_en ? ld_wr_ph   : s3_ph_wb;
    wire [31:0] wb_env  = ld_wr_en ? ld_wr_env  : s3_env_wb;

    always @(posedge clk) begin
        if (wb_we) begin
            mem_ph[wb_addr]  <= wb_ph;
            mem_env[wb_addr] <= wb_env;
        end
        if (ld_wr_en) begin
            mem_inc[ld_wr_addr] <= ld_wr_inc;
            mem_sr[ld_wr_addr]  <= ld_wr_sr;
        end
    end

    reg signed [21:0] voice_psum;
    reg               voice_act_acc;
    reg signed [27:0] vsum_acc;
    reg signed [27:0] vsum_q;

    wire signed [21:0] next_voice_psum = (s3_j == 3'd0) ? {{3{s3_prod[18]}}, s3_prod}
                                                        : (voice_psum + {{3{s3_prod[18]}}, s3_prod});

    integer vi;
    always @(posedge clk) begin
        if (!rst_n) begin
            rr          <= {SEL_W{1'b0}};
            last_voice  <= {SEL_W{1'b0}};
            last_valid  <= 1'b0;
            v_gate      <= {N_VOICES{1'b0}};
            v_sus_pend  <= {N_VOICES{1'b0}};
            v_act_r     <= {N_VOICES{1'b0}};
            for (vi = 0; vi < N_VOICES; vi = vi + 1) begin
                v_note[vi] <= 7'd0;
                v_velg[vi] <= 17'd0;
            end
            ld_st       <= L_IDLE;
            ld_idx      <= 3'd0;
            ld_busy     <= 1'b0;
            ld_sel      <= {SEL_W{1'b0}};
            ld_f0       <= 32'd0;
            ld_beat     <= 32'd0;
            ld_note     <= 7'd60;
            ld_velgain  <= 17'd0;
            ld_vel      <= 7'd0;
            ld_gq       <= 17'd0;
            ld_kq       <= 16'd0;
            ld_nf0_r    <= 33'd0;
            pl_st1_r    <= 5'd31;
            pl_st2_r    <= 5'd31;
            pl_sr_r     <= 5'd13;
            pl_sd_r     <= 5'd9;
            ld_wr_en    <= 1'b0;
            ld_wr_addr  <= 8'd0;
            ld_wr_inc   <= 32'd0;
            ld_wr_env   <= 32'd0;
            ld_wr_sr    <= 28'd0;
            ld_wr_ph    <= 32'd0;
            tdm_run     <= 1'b0;
            s0_v        <= 5'd0; s0_j <= 3'd0;
            s1_val      <= 1'b0; rom_val <= 1'b0; s2_val <= 1'b0; s3_val <= 1'b0;
            s1_v        <= 5'd0; rom_v   <= 5'd0; s2_v   <= 5'd0; s3_v   <= 5'd0;
            s1_j        <= 3'd0; rom_j   <= 3'd0; s2_j   <= 3'd0; s3_j   <= 3'd0;
            s2_sin        <= 16'sd0;
            s2_env_q      <= 18'd0;
            s2_inc_mod_q  <= 32'd0;
            s2_rom_ph_q   <= 32'd0;
            s2_env_next   <= 32'd0;
            s3_prod     <= 19'sd0;
            s3_ph_wb    <= 32'd0;
            s3_env_wb   <= 32'd0;
            voice_psum  <= 22'sd0;
            voice_act_acc <= 1'b0;
            vsum_acc    <= 28'sd0;
            vsum_q      <= 28'sd0;
        end else begin
            // 1. Note-On / Note-Off / Sustain Pedal 状态更新
            if (note_on && !ld_busy) begin
                v_note[alloc_sel]     <= on_note;
                v_velg[alloc_sel]     <= vel_gain_bus;
                v_gate[alloc_sel]     <= 1'b1;
                v_act_r[alloc_sel]    <= 1'b1;
                v_sus_pend[alloc_sel] <= 1'b0;
                last_voice            <= alloc_sel;
                last_valid            <= 1'b1;
                if (alloc_sel == N_VOICES[SEL_W-1:0] - 1'b1) rr <= {SEL_W{1'b0}};
                else                                         rr <= alloc_sel + 1'b1;
            end
            if (off_any) begin
                for (vi = 0; vi < N_VOICES; vi = vi + 1) begin
                    if (v_gate[vi] && (v_note[vi] == off_any_note)) begin
                        if (sustain) v_sus_pend[vi] <= 1'b1;
                        else         v_gate[vi]     <= 1'b0;
                    end
                end
            end
            if (sus_fall) begin
                for (vi = 0; vi < N_VOICES; vi = vi + 1) begin
                    if (v_sus_pend[vi]) begin
                        v_gate[vi]     <= 1'b0;
                        v_sus_pend[vi] <= 1'b0;
                    end
                end
            end

            // 2. TDM 192步扫描控制器
            if (sample_tick) begin
                tdm_run  <= 1'b1;
                s0_v     <= 5'd0;
                s0_j     <= 3'd0;
                vsum_acc <= 28'sd0;
            end else if (tdm_run) begin
                if (s0_j == N_PART[2:0] - 3'd1) begin
                    s0_j <= 3'd0;
                    if (s0_v == N_VOICES[4:0] - 5'd1) begin
                        tdm_run <= 1'b0;
                        s0_v    <= 5'd0;
                    end else begin
                        s0_v <= s0_v + 5'd1;
                    end
                end else begin
                    s0_j <= s0_j + 3'd1;
                end
            end

            s1_val <= tdm_run; s1_v <= s0_v; s1_j <= s0_j;
            // piano_sin_rom 是同步 ROM，输出比 s1_ph 晚一拍；valid/地址也延后一拍。
            rom_val <= s1_val; rom_v <= s1_v; rom_j <= s1_j;
            s2_val <= rom_val; s2_v <= rom_v; s2_j <= rom_j;
            s3_val <= s2_val;  s3_v <= s2_v; s3_j <= s2_j;

            if (rom_val) begin
                s2_sin       <= sin_rom_dout;
                s2_env_q     <= {2'b0, rom_env[31:16]};
                s2_inc_mod_q <= (v_gate[rom_v] || v_act_r[rom_v]) ? inc_mod_clamped : 32'd0;
                s2_rom_ph_q  <= rom_ph;
                s2_env_next  <= rom_env_next_c;
            end

            if (s2_val) begin
                s3_prod   <= $signed(s2_pf[34:16]);
                s3_ph_wb  <= s2_rom_ph_q + s2_inc_mod_q;
                s3_env_wb <= s2_env_next;
            end

            if (s3_val) begin
                voice_psum <= next_voice_psum;
                if (s3_j == 3'd0)
                    voice_act_acc <= v_gate[s3_v] | (|s3_env_wb[31:24]);
                else
                    voice_act_acc <= voice_act_acc | (|s3_env_wb[31:24]);

                if (s3_j == N_PART[2:0] - 3'd1) begin
                    v_act_r[s3_v] <= voice_act_acc | (|s3_env_wb[31:24]);
                    vsum_acc      <= vsum_acc + {{6{next_voice_psum[21]}}, next_voice_psum};
                    if (s3_v == N_VOICES[4:0] - 5'd1) begin
                        vsum_q <= vsum_acc + {{6{next_voice_psum[21]}}, next_voice_psum};
                    end
                end
            end

            // 3. Loader FSM (仅在 !s2_val 空闲窗口写入 BSRAM，避免与 S3 写回冲突)
            ld_wr_en <= 1'b0;
            case (ld_st)
                L_IDLE: begin
                    if (note_on && !ld_busy) begin
                        ld_f0      <= f0_bus;
                        ld_beat    <= beat_bus;
                        ld_note    <= on_note;
                        ld_velgain <= vel_gain_bus;
                        ld_vel     <= on_vel;
                        ld_sel     <= alloc_sel;
                        ld_idx     <= 3'd0;
                        ld_busy    <= 1'b1;
                        ld_st      <= L_CALC;
                    end
                end
                L_CALC: begin
                    ld_gq    <= ld_g;
                    ld_kq    <= kvel_q12;
                    ld_nf0_r <= ld_nf0;
                    pl_st1_r <= pl_st1;
                    pl_st2_r <= pl_st2;
                    pl_sr_r  <= pl_sr_pitch;
                    pl_sd_r  <= pl_sd;
                    ld_st    <= L_MUL;
                end
                L_MUL: begin
                    if (!s2_val) begin // 确保下一拍 s3_val == 0，独享 BSRAM 写端口
                        ld_wr_en   <= 1'b1;
                        ld_wr_addr <= {ld_sel, ld_idx};
                        ld_wr_inc  <= ld_inc_p1[31:0];
                        // 弦乐起弓初始幅度取 25% 柔和接触，随后由运弓包络平滑推升至目标值；钢琴/吉他直接冲击起音
                        ld_wr_env  <= is_bowed ? {2'b0, ld_env_clamped[15:2], 16'd0}
                                               : {ld_env_clamped, 16'd0};
                        ld_wr_sr   <= {ld_env_clamped, 2'b0, pl_sr_r, pl_sd_r};
                        // 泛音从零初相平滑起振，确保琴弦位移从 0 连续起步，彻底根除击弦/拨弦瞬态阶跃杂音与破音
                        ld_wr_ph   <= 32'd0;
                        if (ld_idx == N_PART[2:0] - 3'd1) begin
                            ld_st <= L_DONE;
                        end else begin
                            ld_idx <= ld_idx + 3'd1;
                            ld_st  <= L_CALC;
                        end
                    end
                end
                L_DONE: begin
                    ld_busy <= 1'b0;
                    ld_st   <= L_IDLE;
                end
                default: ld_st <= L_IDLE;
            endcase
        end
    end

    // ---------------------------- 7. 32复音动态余量 + 软膝防削顶混音器 ----
    integer ac_i;
    reg [5:0] act_cnt_c, act_cnt_q;
    always @(*) begin
        act_cnt_c = 6'd0;
        for (ac_i = 0; ac_i < N_VOICES; ac_i = ac_i + 1)
            act_cnt_c = act_cnt_c + {5'd0, v_act_r[ac_i]};
    end
    always @(posedge clk) begin
        if (!rst_n) act_cnt_q <= 6'd0;
        else        act_cnt_q <= act_cnt_c;
    end

    // 动态右移：1..2声部保持原增益，3..6声部 >>>1，7..14声部 >>>2，15..32声部 >>>3，彻底消除多音和弦削波
    wire [1:0] poly_extra_sh = (act_cnt_q <= 6'd2)  ? 2'd0 :
                               (act_cnt_q <= 6'd6)  ? 2'd1 :
                               (act_cnt_q <= 6'd14) ? 2'd2 : 2'd3;
    reg [1:0] poly_extra_sh_r;
    always @(posedge clk) begin
        if (!rst_n) poly_extra_sh_r <= 2'd0;
        else        poly_extra_sh_r <= poly_extra_sh;
    end
    wire signed [27:0] norm_old = vsum_q >>> (OUT_SHIFT + poly_extra_sh_r);
    wire signed [27:0] norm_new = vsum_q >>> (OUT_SHIFT + 1 + poly_extra_sh_r);
    // 钢琴统一采用高裕量衰减 (norm_new)，预留 6 dB 动态余量，杜绝高音/大动态和弦削波失真
    wire signed [27:0] norm_f   = norm_new;

    // ★ 注入起音物理激励瞬态：吉他清脆机械拨弦（1.3 ms），小提琴起弓松香摩擦（5.2 ms），无持续底噪
    wire signed [15:0] ham_subtle = (inst_ok == 2'd1) ? (ham_sig_r >>> 3) :
                                    is_bowed          ? (ham_sig_r >>> 4) : 16'sd0;
    wire signed [27:0] norm_sum   = norm_f + {{12{ham_subtle[15]}}, ham_subtle};

    wire signed [27:0] mag      = norm_sum[27] ? (-norm_sum) : norm_sum;
    wire signed [27:0] magl_old = (mag > KNEE) ? (KNEE + ((mag - KNEE) >>> 2)) : mag;
    wire signed [27:0] magl_new = (mag > KNEE) ? (KNEE + ((3 * (mag - KNEE)) >>> 3)) : mag;
    wire signed [27:0] magl     = magl_new;

    reg signed [27:0] magl_q;
    reg               sign_q;
    always @(posedge clk) begin
        if (!rst_n) begin
            magl_q <= 28'sd0;
            sign_q <= 1'b0;
        end else begin
            magl_q <= magl;
            sign_q <= norm_sum[27];
        end
    end
    wire signed [27:0] lim = sign_q ? (-magl_q) : magl_q;

    always @(posedge clk) begin
        if (!rst_n) begin
            mix_out <= 16'sd0;
        end else begin
            if (lim > 28'sd32767)       mix_out <= 16'sd32767;
            else if (lim < -28'sd32768) mix_out <= -16'sd32768;
            else                        mix_out <= lim[15:0];
        end
    end

endmodule

`default_nettype wire
