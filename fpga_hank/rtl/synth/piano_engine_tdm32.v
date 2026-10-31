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
    wire [1:0] inst_ok_c = (inst_sel == 2'd1) ? 2'd1 :
                           ((inst_sel == 2'd2) || (inst_sel == 2'd3)) ? 2'd2 : 2'd0;
    reg  [1:0] inst_ok;
    always @(posedge clk) begin
        if (!rst_n) inst_ok <= 2'd0;
        else        inst_ok <= inst_ok_c;
    end

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
    piano_vib_lut u_vib_lut (
        .rate (vib_rate),
        .inc  (vib_inc_bus)
    );

    wire [15:0] glide_recip_bus;
    piano_glide_lut u_glide_lut (
        .t     (glide_time),
        .recip (glide_recip_bus)
    );

    // ---- 真实进入相位累加器的表情状态 -------------------------------
    reg [31:0] vib_phase;
    reg [6:0]  vib_depth_r;
    reg        vib_on_r;
    reg [31:0] vib_inc_r;
    reg [31:0] glide_cur_f0, glide_tgt_f0, last_f0_word;
    reg [15:0] glide_recip_r;
    reg        glide_active;

    wire signed [16:0] vib_tri = vib_phase[31]
        ? (17'sd32767 - ({9'd0, vib_phase[30:23]} <<< 8))
        : (-17'sd32768 + ({9'd0, vib_phase[30:23]} <<< 8));
    // vib_tri(Q15) × depth(0..127) -> Q15 fractional frequency offset.
    wire signed [24:0] vib_prod = vib_tri * $signed({1'b0, vib_depth_r});
    wire signed [24:0] vib_frac = vib_prod >>> 7;

    wire signed [32:0] glide_diff = $signed({1'b0, glide_tgt_f0})
                                   - $signed({1'b0, glide_cur_f0});
    wire signed [48:0] glide_step_full = glide_diff * $signed({1'b0, glide_recip_r});
    wire signed [32:0] glide_step = glide_step_full >>> 24;

    always @(posedge clk) begin
        if (!rst_n) begin
            vib_phase      <= 32'd0;
            vib_depth_r    <= 7'd0;
            vib_on_r       <= 1'b0;
            vib_inc_r      <= 32'd0;
            glide_cur_f0   <= 32'd0;
            glide_tgt_f0   <= 32'd0;
            last_f0_word   <= 32'd0;
            glide_recip_r  <= 16'd65535;
            glide_active   <= 1'b0;
        end else begin
            if (note_on && !ld_busy) begin
                last_f0_word <= f0_bus;
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
                vib_depth_r <= vib_depth;
                vib_on_r    <= vib_on;
                vib_inc_r   <= vib_inc_bus;
                if (vib_on) vib_phase <= vib_phase + vib_inc_bus;
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
    wire        note_on      = on_valid & ~vel_zero;

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
    reg             last_valid;

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
    (* ram_style = "block" *) reg [31:0] mem_ph  [0:255];
    (* ram_style = "block" *) reg [31:0] mem_env [0:255];
    (* ram_style = "block" *) reg [31:0] mem_inc [0:255];
    (* ram_style = "block" *) reg [11:0] mem_sr  [0:255]; // {2'b0, s_ring[4:0], s_damp[4:0]}

    integer init_k;
    initial begin
        for (init_k = 0; init_k < 256; init_k = init_k + 1) begin
            mem_ph[init_k]  = 32'd0;
            mem_env[init_k] = 32'd0;
            mem_inc[init_k] = 32'd0;
            mem_sr[init_k]  = {2'b0, 5'd13, 5'd9};
        end
    end

    // ------------------------------------------------ 5. 装载 FSM (Loader) ----
    localparam [1:0] L_IDLE = 2'd0, L_CALC = 2'd1, L_MUL = 2'd2, L_DONE = 2'd3;
    reg [1:0]       ld_st;
    reg [2:0]       ld_idx;
    reg             ld_busy;
    reg [SEL_W-1:0] ld_sel;
    reg [31:0]      ld_f0;
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
    reg [11:0]      ld_wr_sr;

    // 五段音区：低音的基波/低次谐波更重，高音逐步增加亮度和弦刚度。
    wire [2:0] band_ld = (on_note >= 7'd84) ? 3'd4 :
                         (on_note >= 7'd72) ? 3'd3 :
                         (on_note >= 7'd60) ? 3'd2 :
                         (on_note >= 7'd48) ? 3'd1 : 3'd0;
    reg [2:0] band_ld_eff;
    always @(posedge clk) begin
        if (!rst_n) band_ld_eff <= 3'd0;
        else        band_ld_eff <= band_ld;
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

    wire [33:0] ld_gmul   = pl_amp * ld_velgain;
    wire [16:0] ld_g      = ld_gmul[33:16];
    wire [21:0] kvel_prod = pl_k * {15'd0, ld_vel};
    wire [15:0] kvel_q12  = kvel_prod[21:7];
    wire [32:0] ld_bmul   = ld_gq * ld_kq;
    wire [18:0] ld_envsum = {2'b0, ld_gq} + ld_bmul[30:12];
    wire [16:0] ld_env_clamped = (ld_envsum > 19'd65536) ? 17'd65536 : ld_envsum[16:0];

    wire [2:0]  ld_n   = ld_idx + 3'd1;
    wire [32:0] ld_f0e = {1'b0, ld_f0};
    wire [32:0] ld_nf0 = (ld_n == 3'd1) ?  ld_f0e                    :
                         (ld_n == 3'd2) ? (ld_f0e << 1)              :
                         (ld_n == 3'd3) ? ((ld_f0e << 1) + ld_f0e)   :
                         (ld_n == 3'd4) ? (ld_f0e << 2)              :
                         (ld_n == 3'd5) ? ((ld_f0e << 2) + ld_f0e)   :
                                          ((ld_f0e << 2) + (ld_f0e << 1));
    wire [32:0] ld_inc_p1 = ld_nf0_r + (ld_f0e >> pl_st1_r) + (ld_f0e >> pl_st2_r);

    // ----------------------------------------- 6. TDM 4级流水扫描引擎 ---------
    // 每个 sample_tick (512拍) 扫描 32声部 × 6泛音 = 192 步 (占 196 拍，余 316 拍空闲)
    //   S0: 发出 BSRAM 同步读地址 `raddr = {s0_v, s0_j}`
    //   S1: 锁存 BSRAM 输出 (`s1_ph`, `s1_env`, `s1_inc`, `s1_sr`)，并发出 `piano_sin_rom` 地址
    //   S2: 计算 `ph_next` 与 `env_next`，锁存 `s2_sin`，送入共享 DSP18 计算 `sin * env`
    //   S3: 将 `ph_next`, `env_next` 写回 BSRAM (`waddr = {s3_v, s3_j}`，与 S0 读地址恒相差 3 步，
    //       彻底杜绝 Read-before-Write 风险)，累加声部波形与 32 声部总混音
    reg        tdm_run;
    reg [4:0]  s0_v;
    reg [2:0]  s0_j;
    wire [7:0] tdm_raddr = {s0_v, s0_j};

    reg [31:0] s1_ph, s1_env, s1_inc;
    reg [11:0] s1_sr_cfg;
    // 对齐同步正弦 ROM 的第二级数据寄存器；rom_* 与 rom_val 属于同一振荡器。
    reg [31:0] rom_ph, rom_env, rom_inc;
    reg [11:0] rom_sr_cfg;
    always @(posedge clk) begin
        if (!rst_n) begin
            s1_ph <= 32'd0; s1_env <= 32'd0; s1_inc <= 32'd0; s1_sr_cfg <= 12'd0;
            rom_ph <= 32'd0; rom_env <= 32'd0; rom_inc <= 32'd0; rom_sr_cfg <= 12'd0;
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
            // 默认中弱弓压，避免 64 档持续激励导致嗡声和削顶。
            drv_src_r <= (bow_speed != 7'd0) ? bow_speed : 7'd32;
            drv_on_r  <= (inst_ok == 2'd2);
        end
    end
    wire [31:0] drv_q  = {25'd0, drv_src_r} << 8;
    // 4×斜坡比原来的 16×更接近弓弦起音，避免快速进入饱和。
    wire [31:0] drv_r4 = drv_q << 2;

    wire [4:0] s1_s_ring = s1_sr_cfg[9:5];
    wire [4:0] s1_s_damp = s1_sr_cfg[4:0];
    wire       s1_gate   = v_gate[s1_v];

    wire [4:0] rom_s_ring = rom_sr_cfg[9:5];
    wire [4:0] rom_s_damp = rom_sr_cfg[4:0];
    wire       rom_gate   = v_gate[rom_v];

    reg [31:0] s1_env_next_c;
    always @(*) begin
        if (!s1_gate) begin
            if (s1_env <= (32'd1 << s1_s_damp)) s1_env_next_c = 32'd0;
            else                                s1_env_next_c = s1_env - (s1_env >> s1_s_damp);
        end else if (drv_on_r && ((s1_env >> s1_s_ring) < drv_q)) begin
            s1_env_next_c = s1_env + drv_r4;
        end else if (drv_on_r) begin
            s1_env_next_c = s1_env - (s1_env >> s1_s_ring) + drv_q;
        end else begin
            if (s1_env <= (32'd1 << s1_s_ring)) s1_env_next_c = 32'd0;
            else                                s1_env_next_c = s1_env - (s1_env >> s1_s_ring);
        end
    end

    reg [31:0] rom_env_next_c;
    always @(*) begin
        if (!rom_gate) begin
            if (rom_env <= (32'd1 << rom_s_damp)) rom_env_next_c = 32'd0;
            else                                  rom_env_next_c = rom_env - (rom_env >> rom_s_damp);
        end else if (drv_on_r && ((rom_env >> rom_s_ring) < drv_q)) begin
            rom_env_next_c = rom_env + drv_r4;
        end else if (drv_on_r) begin
            rom_env_next_c = rom_env - (rom_env >> rom_s_ring) + drv_q;
        end else begin
            if (rom_env <= (32'd1 << rom_s_ring)) rom_env_next_c = 32'd0;
            else                                  rom_env_next_c = rom_env - (rom_env >> rom_s_ring);
        end
    end

    reg signed [15:0] s2_sin;
    reg [17:0]        s2_env_q;
    reg [31:0]        s2_ph_next, s2_env_next;
    wire signed [34:0] s2_pf = $signed(s2_sin) * $signed({1'b0, s2_env_q});

    // 颤音与滑音在这里真正改变每个振荡器的相位增量。
    wire signed [48:0] vib_inc_prod = $signed({1'b0, rom_inc}) * vib_frac;
    wire signed [32:0] vib_inc_delta = vib_on_r ? (vib_inc_prod >>> 15) : 33'sd0;
    wire signed [33:0] glide_inc_delta = glide_active ? glide_diff : 34'sd0;
    wire signed [34:0] inc_mod_sum = $signed({1'b0, rom_inc})
                                    + {{2{vib_inc_delta[32]}}, vib_inc_delta}
                                    + {{1{glide_inc_delta[33]}}, glide_inc_delta};

    reg signed [18:0] s3_prod;
    reg [31:0]        s3_ph_wb, s3_env_wb;

    // BSRAM 写端口：Loader 仅在 `!s2_val` (即下一拍 `s3_val == 0`) 时置位 `ld_wr_en`，零写冲突
    wire        wb_we   = ld_wr_en | s3_val;
    wire [7:0]  wb_addr = ld_wr_en ? ld_wr_addr : {s3_v, s3_j};
    wire [31:0] wb_ph   = ld_wr_en ? 32'd0      : s3_ph_wb;
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
            ld_wr_sr    <= 12'd0;
            tdm_run     <= 1'b0;
            s0_v        <= 5'd0; s0_j <= 3'd0;
            s1_val      <= 1'b0; rom_val <= 1'b0; s2_val <= 1'b0; s3_val <= 1'b0;
            s1_v        <= 5'd0; rom_v   <= 5'd0; s2_v   <= 5'd0; s3_v   <= 5'd0;
            s1_j        <= 3'd0; rom_j   <= 3'd0; s2_j   <= 3'd0; s3_j   <= 3'd0;
            s2_sin      <= 16'sd0;
            s2_env_q    <= 18'd0;
            s2_ph_next  <= 32'd0;
            s2_env_next <= 32'd0;
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
                s2_sin      <= sin_rom_dout;
                s2_env_q    <= {2'b0, rom_env[31:16]};
                s2_ph_next  <= (v_gate[rom_v] || v_act_r[rom_v])
                             ? (rom_ph + inc_mod_sum[31:0]) : rom_ph;
                s2_env_next <= rom_env_next_c;
            end

            if (s2_val) begin
                s3_prod   <= $signed(s2_pf[34:16]);
                s3_ph_wb  <= s2_ph_next;
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
                    pl_sr_r  <= pl_sr;
                    pl_sd_r  <= pl_sd;
                    ld_st    <= L_MUL;
                end
                L_MUL: begin
                    if (!s2_val) begin // 确保下一拍 s3_val == 0，独享 BSRAM 写端口
                        ld_wr_en   <= 1'b1;
                        ld_wr_addr <= {ld_sel, ld_idx};
                        ld_wr_inc  <= ld_inc_p1[31:0];
                        ld_wr_env  <= {ld_env_clamped[15:0], 16'd0};
                        ld_wr_sr   <= {2'b0, pl_sr_r, pl_sd_r};
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

    // 动态右移：1..8声部保持原增益，9..16声部 >>>1，17..32声部 >>>2，彻底消除32复音饱和削波
    wire [1:0] poly_extra_sh = (act_cnt_q <= 6'd8)  ? 2'd0 :
                               (act_cnt_q <= 6'd16) ? 2'd1 : 2'd2;
    wire signed [27:0] norm_old = vsum_q >>> (OUT_SHIFT + poly_extra_sh);
    wire signed [27:0] norm_new = vsum_q >>> (OUT_SHIFT + 1 + poly_extra_sh);
    wire signed [27:0] norm_f   = (inst_ok != 2'd0) ? norm_new : norm_old;

    wire signed [27:0] mag      = norm_f[27] ? (-norm_f) : norm_f;
    wire signed [27:0] magl_old = (mag > KNEE) ? (KNEE + ((mag - KNEE) >>> 2)) : mag;
    wire signed [27:0] magl_new = (mag > KNEE) ? (KNEE + ((3 * (mag - KNEE)) >>> 3)) : mag;
    wire signed [27:0] magl     = (inst_ok != 2'd0) ? magl_new : magl_old;

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
