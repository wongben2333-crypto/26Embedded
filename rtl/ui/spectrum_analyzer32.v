// =============================================================================
// spectrum_analyzer32.v —— 纯硬件 32 段多音与泛音实时音频频谱分析仪 (单写口轻量版)
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module spectrum_analyzer32 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_tick,
    input  wire [1:0]  work_mode,         // 2 = 32-Voice Benchmark
    input  wire [6:0]  live_note,         // 0..127
    input  wire [6:0]  live_vel,          // 0..127
    input  wire        audio_active,
    input  wire [7:0]  vu_level,          // 0..255
    input  wire [31:0] voice_active_mask, // 32 路声部激活掩码
    input  wire        scan_voice_act,    // TDM 实时扫描声部激活
    input  wire [6:0]  scan_voice_note,   // TDM 实时扫描声部音高
    input  wire [4:0]  scan_voice_idx,    // TDM 实时扫描声部编号
    input  wire [12:0] hw_key_state,      // 13 路物理琴键实时按压掩码
    input  wire signed [15:0] audio_sample, // 实时混合音频采样
    input  wire [9:0]  px,
    input  wire [8:0]  py,
    output wire [7:0]  cur_band_energy,   // 当前扫描列对应的频带能量
    output wire        bar_hit,           // 当前像素命中频谱柱 (Page 1)
    output wire [1:0]  bar_color_zone     // 0=绿色正常区, 1=黄色警示区, 2=红色峰值区
);

    localparam [9:0] SPEC_X_MIN = 10'd36;
    localparam [9:0] SPEC_X_MAX = 10'd764;
    localparam [8:0] BASE_Y     = 9'd432;

    // 32 个频带能量寄存器 (单写端口扫描更新，极低 LUT 占用)
    reg [7:0] band_energy [0:31];

    // 柱宽度 18 px，间距 5 px (总步进 23 px)
    wire in_spec_x = (px >= SPEC_X_MIN && px <= SPEC_X_MAX);
    wire [9:0] x_rel = in_spec_x ? (px - SPEC_X_MIN) : 10'd0;
    wire [4:0] cur_bar_idx = (x_rel * 24'd5700) >> 17; // x_rel / 23
    wire [9:0] cur_bar_rem = x_rel - (cur_bar_idx * 10'd23);
    wire is_bar_col = in_spec_x && (cur_bar_rem < 10'd18);

    // 1 半音 = 1 独立频带映射 (C4..F#5 -> Band 6..24)，确保多键同按绝不合并
    function [4:0] note_to_band(input [6:0] n);
        begin
            if (n < 7'd48)
                note_to_band = 5'd1 + n[5:4];
            else if (n < 7'd60)
                note_to_band = 5'd3 + ((n - 7'd48) >> 2);
            else if (n <= 7'd78)
                note_to_band = 5'd6 + (n - 7'd60);
            else if (n <= 7'd96)
                note_to_band = 5'd25 + ((n - 7'd79) >> 2);
            else
                note_to_band = 5'd30;
        end
    endfunction

    // 32-bit 实时基波激活掩码：汇聚 TDM-32 所有活跃声部 + 13 路物理琴键
    reg [31:0] voice_band_mask = 32'd0;
    reg [8:0]  mask_clr_cnt    = 9'd0;
    wire [4:0] v_band = note_to_band(scan_voice_note);

    always @(posedge clk) begin
        if (!rst_n) begin
            voice_band_mask <= 32'd0;
            mask_clr_cnt    <= 9'd0;
        end else begin
            if (sample_tick) begin
                if (mask_clr_cnt >= 9'd63) begin
                    mask_clr_cnt    <= 9'd0;
                    voice_band_mask <= 32'd0;
                end else begin
                    mask_clr_cnt <= mask_clr_cnt + 9'd1;
                end
            end
            if (scan_voice_act) begin
                voice_band_mask[v_band] <= 1'b1;
            end
        end
    end

    wire [31:0] key_band_mask = {13'd0, hw_key_state, 6'd0};
    wire [31:0] f0_mask       = voice_band_mask | key_band_mask;

    // 真实音频包络 + 伪随机高频抖动
    wire [15:0] sample_abs = audio_sample[15] ? (~audio_sample + 16'd1) : audio_sample;
    reg  [15:0] fast_env   = 16'd0;
    reg  [7:0]  lfsr       = 8'hA5;

    wire [15:0] env_boost = (fast_env >= 16'd8192) ? 16'd65535 : (fast_env << 3);
    wire [7:0]  env_lvl8  = env_boost[15:8];
    wire [7:0]  eff_vu    = (env_lvl8 > vu_level) ? env_lvl8 : vu_level;

    // 单端口轮询扫描器：每拍 sample_tick 扫描 1 个频带 (97.656 kHz / 32 = 3051 Hz 全频段刷新率)
    reg [4:0] scan_bi = 5'd0;
    wire      has_f0  = f0_mask[scan_bi];
    wire      has_h1  = (scan_bi >= 5'd5)  && f0_mask[scan_bi - 5'd5];
    wire      has_h2  = (scan_bi >= 5'd8)  && f0_mask[scan_bi - 5'd8];
    wire      has_h3  = (scan_bi >= 5'd11) && f0_mask[scan_bi - 5'd11];
    wire      has_h4  = (scan_bi >= 5'd13) && f0_mask[scan_bi - 5'd13];
    wire      has_h5  = (scan_bi >= 5'd15) && f0_mask[scan_bi - 5'd15];
    wire      has_sb  = ((scan_bi > 5'd0) && f0_mask[scan_bi - 5'd1]) ||
                        ((scan_bi < 5'd31) && f0_mask[scan_bi + 5'd1]);

    wire [7:0] raw_h0 = 8'd84 + (eff_vu >> 1) + {5'd0, lfsr[2:0]};
    wire [7:0] tgt_h0 = (raw_h0 > 8'd148) ? 8'd148 : raw_h0;
    wire [7:0] tgt_h1 = (tgt_h0 >> 1) + (tgt_h0 >> 2) + {5'd0, lfsr[2:0]};
    wire [7:0] tgt_h2 = (tgt_h0 >> 1) + {5'd0, lfsr[3:1]};
    wire [7:0] tgt_h3 = (tgt_h0 >> 2) + (tgt_h0 >> 3) + {5'd0, lfsr[4:2]};
    wire [7:0] tgt_h4 = (tgt_h0 >> 2) + {5'd0, lfsr[5:3]};
    wire [7:0] tgt_h5 = (tgt_h0 >> 3) + 8'd12 + {5'd0, lfsr[2:0]};
    wire [7:0] tgt_sb = (tgt_h0 >> 2) + (tgt_h0 >> 3) + {5'd0, lfsr[1:0]};

    wire [7:0] band_tgt = has_f0 ? tgt_h0 :
                          has_h1 ? tgt_h1 :
                          has_h2 ? tgt_h2 :
                          has_sb ? tgt_sb :
                          has_h3 ? tgt_h3 :
                          has_h4 ? tgt_h4 :
                          has_h5 ? tgt_h5 : 8'd0;

    wire [7:0] cur_e = band_energy[scan_bi];
    reg  [2:0] decay_div = 3'd0;

    integer bi;
    initial begin
        for (bi = 0; bi < 32; bi = bi + 1) band_energy[bi] = 8'd0;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            scan_bi   <= 5'd0;
            decay_div <= 3'd0;
            fast_env  <= 16'd0;
            lfsr      <= 8'hA5;
        end else if (sample_tick) begin
            scan_bi <= scan_bi + 5'd1;
            if (scan_bi == 5'd31) begin
                decay_div <= decay_div + 3'd1;
                lfsr      <= {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]} ^ sample_abs[7:0];
                fast_env  <= fast_env - (fast_env >> 4);
            end else if (sample_abs > fast_env) begin
                fast_env <= sample_abs;
            end

            // 单端口更新 band_energy[scan_bi]：瞬态拉升或每 ~2.6ms 阻尼回落
            if (band_tgt > cur_e) begin
                band_energy[scan_bi] <= band_tgt;
            end else if (decay_div == 3'd7) begin
                if (cur_e > 8'd4)
                    band_energy[scan_bi] <= cur_e - (cur_e >> 4) - 8'd2;
                else
                    band_energy[scan_bi] <= 8'd0;
            end
        end
    end

    // 当前列高度
    wire [7:0] active_h = band_energy[cur_bar_idx];
    assign cur_band_energy = active_h;

    wire [8:0] bar_top_y = (BASE_Y > {1'b0, active_h}) ? (BASE_Y - {1'b0, active_h}) : 9'd260;

    assign bar_hit = is_bar_col && (active_h > 8'd0) && (py >= bar_top_y && py <= BASE_Y);

    assign bar_color_zone = (py <= 9'd340) ? 2'd2 :
                            (py <= 9'd385) ? 2'd1 : 2'd0;

endmodule
`default_nettype wire
