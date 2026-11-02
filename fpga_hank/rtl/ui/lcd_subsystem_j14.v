// ============================================================================
// Module Name: lcd_subsystem_j14
// Description: 7-inch 800x480 ATK-MD0700 (SSD1963 16-bit 8080 via J14) Display
//              Subsystem + 3.0s Dual-Buffer Peak-Envelope Oscilloscope +
//              4-Page Pure-RTL Instrument UI + Cold-Boot Watchdog + WS2812 RGB
// ============================================================================
`default_nettype none

module lcd_subsystem_j14 (
    input  wire        clk,               // 50 MHz system clock
    input  wire        rst_n,             // Active-low synchronous reset
    input  wire        sample_tick,       // 97,656.25 Hz audio sample tick
    input  wire signed [15:0] audio_mix,  // Final mixed 16-bit audio sample (Left)
    input  wire signed [15:0] audio_mix_r,// Final mixed 16-bit audio sample (Right / True Stereo)

    // Synthesizer & Mode Status
    input  wire [1:0]  work_mode,         // 0=Free Play, 1=Song Play, 2=32-Voice Benchmark
    input  wire [1:0]  timbre_sel,        // 0=Piano, 1=Guitar, 2/3=Violin
    input  wire [1:0]  fx_sel,            // 0=Bypass, 1=Delay, 2=Chorus, 3=Reverb
    input  wire [31:0] voice_active32,    // 32-bit active voice mask from piano_engine_tdm32
    input  wire [12:0] hw_key_state,      // 13 physical keys from J13 (1=pressed)
    input  wire [6:0]  master_vol,        // 0..127 master volume

    // Note & MIDI / UART Control Bus
    input  wire        bus_on_valid,
    input  wire [6:0]  bus_on_note,
    input  wire [6:0]  bus_on_vel,
    input  wire        bus_off_valid,
    input  wire [6:0]  bus_off_note,
    input  wire        bus_reset_all,
    input  wire        cc_any_valid,
    input  wire [6:0]  cc_num,
    input  wire [6:0]  cc_val,
    input  wire        uart_rx_valid,
    input  wire [7:0]  uart_rx_byte,
    input  wire        page_next_pulse,   // Optional button pulse to cycle UI page

    // Song Player Timeline & Score Scrolling Inputs
    input  wire [2:0]  song_index,
    input  wire        song_playing,
    input  wire [7:0]  song_progress_pct,
    input  wire [7:0]  song_elapsed_sec,
    input  wire [7:0]  song_elapsed_min,
    input  wire [7:0]  song_total_sec,
    input  wire [8:0]  song_note_idx,
    input  wire [5:0]  song_sub_scroll,
    input  wire [6:0]  song_active_note,

    // ATK-MD0700 LCD 8080 16-bit Bus (J14)
    output reg         lcd_cs,            // AB21
    output reg         lcd_rs,            // R14
    output reg         lcd_wr,            // AB20
    output reg         lcd_rd,            // AB18
    output reg         lcd_rst,           // Y18
    inout  wire [15:0] lcd_db,            // 16-bit bidirectional 8080 bus
    output wire        lcd_dpi_bl,        // P20 -> GND (disable onboard RGB boost)
    output wire        ws_dout,           // J16 -> WS2812 RGB status LED
    output wire        lcd_uart_tx,       // U15 -> Diagnostics & Hardware Screenshot TX
    output wire        lcd_init_ok,       // 1 when SSD1963 initialization completed

    // FT5206 / FT5426 Capacitive Touch Pins (J14)
    inout  wire        tp_scl,            // U18 (J14-359)
    inout  wire        tp_sda,            // Y19 (J14-31)
    input  wire        tp_int,            // Y19 (J14-33)
    output wire        tp_rst_n,          // U18 (J14-35)

    // Touch Event Outputs to Synthesizer / top.v
    output reg         touch_on_valid,
    output reg  [6:0]  touch_on_note,
    output reg  [6:0]  touch_on_vel,
    output reg         touch_off_valid,
    output reg  [6:0]  touch_off_note,
    output reg         touch_timbre_pulse,
    output reg         touch_fx_pulse,
    output reg  [6:0]  touch_vol_val,
    output reg         touch_vol_valid
);

    assign lcd_dpi_bl = 1'b0;

    // ------------------------------------------------------------------------
    // 1. Active Voice Population Counter (0..32) & 12-Key Octave Activity Mask
    // ------------------------------------------------------------------------
    integer vi;
    reg [5:0] voice_cnt_comb;
    always @(*) begin
        voice_cnt_comb = 6'd0;
        for (vi = 0; vi < 32; vi = vi + 1) begin
            voice_cnt_comb = voice_cnt_comb + {5'd0, voice_active32[vi]};
        end
    end
    reg [5:0] live_active_voices = 6'd0;
    always @(posedge clk) begin
        if (!rst_n)
            live_active_voices <= 6'd0;
        else if (work_mode == 2'd2)
            live_active_voices <= 6'd32;
        else
            live_active_voices <= voice_cnt_comb;
    end

    // Real-Time Note & Velocity Display Tracker
    reg [6:0]  live_note       = 7'd69;
    reg [6:0]  live_vel        = 7'd100;
    reg [23:0] note_hold_timer = 24'd0;
    reg        note_held       = 1'b0;

    always @(posedge clk) begin
        if (!rst_n || bus_reset_all) begin
            live_note       <= 7'd69;
            live_vel        <= 7'd100;
            note_held       <= 1'b0;
            note_hold_timer <= 24'd0;
        end else if (bus_on_valid) begin
            live_note       <= bus_on_note;
            live_vel        <= bus_on_vel;
            note_held       <= 1'b1;
            note_hold_timer <= 24'd25000000; // ~500ms minimum visual hold
        end else if (bus_off_valid && (bus_off_note == live_note)) begin
            note_held       <= 1'b0;
            if (note_hold_timer > 24'd8000000)
                note_hold_timer <= 24'd8000000; // ~160ms release tail
        end else if (note_hold_timer != 24'd0) begin
            note_hold_timer <= note_hold_timer - 1'b1;
        end
    end
    wire note_active = note_held || (note_hold_timer != 24'd0);

    function [3:0] get_semi_top;
        input [6:0] note;
        reg [6:0] n;
        begin
            if      (note >= 7'd120) n = note - 7'd120;
            else if (note >= 7'd108) n = note - 7'd108;
            else if (note >= 7'd96)  n = note - 7'd96;
            else if (note >= 7'd84)  n = note - 7'd84;
            else if (note >= 7'd72)  n = note - 7'd72;
            else if (note >= 7'd60)  n = note - 7'd60;
            else if (note >= 7'd48)  n = note - 7'd48;
            else if (note >= 7'd36)  n = note - 7'd36;
            else if (note >= 7'd24)  n = note - 7'd24;
            else if (note >= 7'd12)  n = note - 7'd12;
            else                     n = note;
            get_semi_top = n[3:0];
        end
    endfunction

    wire [11:0] live_note_mask = note_active ? (12'd1 << get_semi_top(live_note)) : 12'd0;
    wire [11:0] hw_key_mask    = hw_key_state[11:0] | {11'd0, hw_key_state[12]};
    wire [11:0] key_active_mask = (work_mode == 2'd2) ? 12'd0 : (hw_key_mask | live_note_mask);

    // ------------------------------------------------------------------------
    // 2. Real-Time VU Peak Meter & Audio Activity Detector
    // ------------------------------------------------------------------------
    wire [15:0] audio_abs = audio_mix[15] ? (-audio_mix) : audio_mix;
    reg  [15:0] vu_peak   = 16'd0;
    reg  [18:0] vu_decay  = 19'd0;

    always @(posedge clk) begin
        if (!rst_n) begin
            vu_peak  <= 16'd0;
            vu_decay <= 19'd0;
        end else if (sample_tick) begin
            if (audio_abs > vu_peak) begin
                vu_peak <= audio_abs;
            end else if (vu_decay == 19'd3000) begin
                vu_decay <= 19'd0;
                vu_peak  <= vu_peak - (vu_peak >> 5);
            end else begin
                vu_decay <= vu_decay + 1'b1;
            end
        end
    end
    wire [7:0] live_vu_level = vu_peak[15:8];
    wire       audio_active  = (vu_peak > 16'd160) || (|voice_active32) || (work_mode == 2'd2);

    // ------------------------------------------------------------------------
    // 3. Real-Time 3.0-Second Dual-Buffer Audio Oscilloscope Engine
    // ------------------------------------------------------------------------
    reg [9:0] smp_cnt_p0 = 10'd0;
    reg signed [15:0] cur_max_p0 = 16'sd0;
    reg signed [15:0] cur_min_p0 = 16'sd0;

    reg [9:0] smp_cnt_p1 = 10'd0;
    reg signed [15:0] cur_max_p1 = 16'sd0;
    reg signed [15:0] cur_min_p1 = 16'sd0;

    // Page 0 scaling (+/- 80 px headroom, center Y=300)
    wire signed [15:0] final_max_p0 = (audio_mix > cur_max_p0) ? audio_mix : cur_max_p0;
    wire signed [15:0] final_min_p0 = (audio_mix < cur_min_p0) ? audio_mix : cur_min_p0;

    wire [14:0] pos_abs_p0  = (final_max_p0 > 16'sd0) ? final_max_p0[14:0] : 15'd0;
    wire [17:0] prod_pos_p0 = {pos_abs_p0, 2'b00} + {2'b00, pos_abs_p0};
    wire [8:0]  off_top_p0  = prod_pos_p0[17:11];
    wire [8:0]  y_top_p0    = (off_top_p0 > 9'd80) ? 9'd220 : (9'd300 - off_top_p0);

    wire [15:0] neg_raw_p0  = (-final_min_p0);
    wire [14:0] neg_abs_p0  = (final_min_p0 < 16'sd0) ? neg_raw_p0[14:0] : 15'd0;
    wire [17:0] prod_neg_p0 = {neg_abs_p0, 2'b00} + {2'b00, neg_abs_p0};
    wire [8:0]  off_bot_p0  = prod_neg_p0[17:11];
    wire [8:0]  y_bot_p0    = (off_bot_p0 > 9'd80) ? 9'd380 : (9'd300 + off_bot_p0);

    // Page 1 scaling (+/- 48 px headroom, center Y=154)
    wire signed [15:0] final_max_p1 = (audio_mix > cur_max_p1) ? audio_mix : cur_max_p1;
    wire signed [15:0] final_min_p1 = (audio_mix < cur_min_p1) ? audio_mix : cur_min_p1;

    wire [14:0] pos_abs_p1  = (final_max_p1 > 16'sd0) ? final_max_p1[14:0] : 15'd0;
    wire [17:0] prod_pos_p1 = {pos_abs_p1, 1'b0} + {1'b0, pos_abs_p1};
    wire [8:0]  off_top_p1  = prod_pos_p1[16:11];
    wire [8:0]  y_top_p1    = (off_top_p1 > 9'd48) ? 9'd106 : (9'd154 - off_top_p1);

    wire [15:0] neg_raw_p1  = (-final_min_p1);
    wire [14:0] neg_abs_p1  = (final_min_p1 < 16'sd0) ? neg_raw_p1[14:0] : 15'd0;
    wire [17:0] prod_neg_p1 = {neg_abs_p1, 1'b0} + {1'b0, neg_abs_p1};
    wire [8:0]  off_bot_p1  = prod_neg_p1[16:11];
    wire [8:0]  y_bot_p1    = (off_bot_p1 > 9'd48) ? 9'd202 : (9'd154 + off_bot_p1);

    reg [17:0] scope_p0_ram  [0:511];
    reg [17:0] scope_p0_disp [0:511];
    reg [17:0] scope_p1_ram  [0:1023];
    reg [17:0] scope_p1_disp [0:1023];

    reg [9:0] scope_p0_wr      = 10'd0;
    reg [9:0] scope_p1_wr      = 10'd0;
    reg [9:0] scope_p0_wr_snap = 10'd0;
    reg [9:0] scope_p1_wr_snap = 10'd0;

    reg [9:0] copy_idx = 10'd0;
    reg       copying  = 1'b0;

    reg [9:0] px;
    reg [8:0] py;
    reg       frame_end_pulse = 1'b0;

    always @(posedge clk) begin
        if (!rst_n) begin
            scope_p0_wr      <= 10'd0;
            scope_p1_wr      <= 10'd0;
            scope_p0_wr_snap <= 10'd0;
            scope_p1_wr_snap <= 10'd0;
            smp_cnt_p0       <= 10'd0;
            smp_cnt_p1       <= 10'd0;
            cur_max_p0       <= 16'sd0;
            cur_min_p0       <= 16'sd0;
            cur_max_p1       <= 16'sd0;
            cur_min_p1       <= 16'sd0;
            copying          <= 1'b0;
            copy_idx         <= 10'd0;
        end else begin
            if (sample_tick) begin
                if (smp_cnt_p0 >= 10'd697) begin
                    smp_cnt_p0 <= 10'd0;
                    scope_p0_ram[scope_p0_wr] <= {y_top_p0, y_bot_p0};
                    if (scope_p0_wr >= 10'd419)
                        scope_p0_wr <= 10'd0;
                    else
                        scope_p0_wr <= scope_p0_wr + 1'b1;
                    cur_max_p0 <= audio_mix;
                    cur_min_p0 <= audio_mix;
                end else begin
                    smp_cnt_p0 <= smp_cnt_p0 + 1'b1;
                    if (audio_mix > cur_max_p0) cur_max_p0 <= audio_mix;
                    if (audio_mix < cur_min_p0) cur_min_p0 <= audio_mix;
                end

                if (smp_cnt_p1 >= 10'd385) begin
                    smp_cnt_p1 <= 10'd0;
                    scope_p1_ram[scope_p1_wr] <= {y_top_p1, y_bot_p1};
                    if (scope_p1_wr >= 10'd757)
                        scope_p1_wr <= 10'd0;
                    else
                        scope_p1_wr <= scope_p1_wr + 1'b1;
                    cur_max_p1 <= audio_mix;
                    cur_min_p1 <= audio_mix;
                end else begin
                    smp_cnt_p1 <= smp_cnt_p1 + 1'b1;
                    if (audio_mix > cur_max_p1) cur_max_p1 <= audio_mix;
                    if (audio_mix < cur_min_p1) cur_min_p1 <= audio_mix;
                end
            end

            if (frame_end_pulse) begin
                copying          <= 1'b1;
                copy_idx         <= 10'd0;
                scope_p0_wr_snap <= scope_p0_wr;
                scope_p1_wr_snap <= scope_p1_wr;
            end else if (copying) begin
                scope_p0_disp[copy_idx] <= scope_p0_ram[copy_idx];
                scope_p1_disp[copy_idx] <= scope_p1_ram[copy_idx];
                if (copy_idx >= 10'd757)
                    copying <= 1'b0;
                else
                    copy_idx <= copy_idx + 1'b1;
            end
        end
    end

    wire [9:0] p0_col = (px >= 10'd20 && px <= 10'd440) ? (px - 10'd20) : 10'd0;
    wire [9:0] p1_col = (px >= 10'd20 && px <= 10'd778) ? (px - 10'd20) : 10'd0;

    wire [9:0] p0_rd_addr = (scope_p0_wr_snap + p0_col >= 10'd420) ?
                            (scope_p0_wr_snap + p0_col - 10'd420) :
                            (scope_p0_wr_snap + p0_col);

    wire [9:0] p1_rd_addr = (scope_p1_wr_snap + p1_col >= 10'd758) ?
                            (scope_p1_wr_snap + p1_col - 10'd758) :
                            (scope_p1_wr_snap + p1_col);

    wire [17:0] p0_data = scope_p0_disp[p0_rd_addr];
    wire [17:0] p1_data = scope_p1_disp[p1_rd_addr];

    wire [8:0] p0_disp_top = (p0_data[17:9] == 9'd0) ? 9'd300 : p0_data[17:9];
    wire [8:0] p0_disp_bot = (p0_data[8:0]  == 9'd0) ? 9'd300 : p0_data[8:0];

    wire [8:0] p1_disp_top = (p1_data[17:9] == 9'd0) ? 9'd154 : p1_data[17:9];
    wire [8:0] p1_disp_bot = (p1_data[8:0]  == 9'd0) ? 9'd154 : p1_data[8:0];

    // ------------------------------------------------------------------------
    // 4. UI Page Controller (Auto Mode Tracking + MIDI CC / UART / Key Control)
    // ------------------------------------------------------------------------
    reg [1:0] ui_page         = 2'd0;
    reg [1:0] work_mode_d     = 2'd0;
    reg       reinit_req      = 1'b0;
    reg       reinit_clear_req;
    reg       snap_req        = 1'b0;
    reg       snap_clear_req;
    reg       snap_rle        = 1'b0;
    reg       diag_req        = 1'b0;
    reg       diag_clear_req;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ui_page     <= 2'd0;
            work_mode_d <= 2'd0;
            reinit_req  <= 1'b0;
            snap_req    <= 1'b0;
            snap_rle    <= 1'b0;
            diag_req    <= 1'b0;
        end else begin
            work_mode_d <= work_mode;
            if (reinit_clear_req) reinit_req <= 1'b0;
            if (snap_clear_req)   snap_req   <= 1'b0;
            if (diag_clear_req)   diag_req   <= 1'b0;

            // Automatically switch to the matching page when work_mode changes
            if (work_mode != work_mode_d) begin
                if      (work_mode == 2'd1) ui_page <= 2'd3; // Song Player Page
                else if (work_mode == 2'd2) ui_page <= 2'd2; // 32-Voice Benchmark Page
                else                        ui_page <= 2'd0; // Performance Dashboard
            end else if (touch_page_req) begin
                ui_page <= touch_page_val;
            end else if (page_next_pulse) begin
                ui_page <= ui_page + 2'd1;
            end else if (cc_any_valid) begin
                if (cc_num == 7'd25) begin snap_req <= 1'b1; snap_rle <= cc_val[0]; end
                if (cc_num == 7'd28) ui_page <= cc_val[1:0];
                if (cc_num == 7'd29 && cc_val == 7'd127) reinit_req <= 1'b1;
                if (cc_num == 7'd30) diag_req <= 1'b1;
            end else if (uart_rx_valid && (uart_rx_byte == "d" || uart_rx_byte == "D")) begin
                // 保留调试控制台直通查询命令 (限 'd'/'D' 遥测触发，绝不将音符/力度误当作换页快捷键)
                diag_req <= 1'b1;
            end
        end
    end

    wire [8:0] live_scope_wave_y = (ui_page == 2'd0) ? p0_disp_top : p1_disp_top;
    wire [8:0] live_scope_prev_y = (ui_page == 2'd0) ? p0_disp_bot : p1_disp_bot;

    // ------------------------------------------------------------------------
    // 5. LCD UI Module (4-Page Pure-RTL Renderer)
    // ------------------------------------------------------------------------
    wire [15:0] ui_color;
    reg  [7:0]  frame_cnt = 8'd0;

    // ★ 赛题拓展③：纯硬件 128x128 矢量双通道李萨如相位轨迹仪
    wire liss_box, liss_border, liss_reticle, liss_dot;
    lissajous_engine u_liss (
        .clk         (clk),
        .rst_n       (rst_n),
        .sample_tick (sample_tick),
        .frame_start (frame_end_pulse),
        .sample_l    (audio_mix),
        .sample_r    (audio_mix_r),
        .px          (px),
        .py          (py),
        .box_area    (liss_box),
        .border_line (liss_border),
        .reticle_line(liss_reticle),
        .trace_dot   (liss_dot)
    );

    // ★ 赛题拓展③：纯硬件 32 段专业实时音频频谱仪
    wire spec_bar_hit;
    wire [1:0] spec_bar_zone;
    spectrum_analyzer32 u_spec32 (
        .clk           (clk),
        .rst_n         (rst_n),
        .sample_tick   (sample_tick),
        .work_mode     (work_mode),
        .live_note     (live_note),
        .live_vel      (live_vel),
        .audio_active  (audio_active),
        .vu_level      (live_vu_level),
        .px            (px),
        .py            (py),
        .bar_hit       (spec_bar_hit),
        .bar_color_zone(spec_bar_zone)
    );

    // ★ 时序优化流水线寄存器：切断歌曲播放器长路径，确保 50 MHz 建立时间裕量充足
    reg [8:0] song_note_idx_r = 9'd0;
    reg [5:0] song_sub_scroll_r = 6'd0;
    reg [2:0] song_index_r = 3'd0;
    always @(posedge clk) begin
        if (!rst_n) begin
            song_note_idx_r   <= 9'd0;
            song_sub_scroll_r <= 6'd0;
            song_index_r      <= 3'd0;
        end else begin
            song_note_idx_r   <= song_note_idx;
            song_sub_scroll_r <= song_sub_scroll;
            song_index_r      <= song_index;
        end
    end

    
    // ========================================================================
    // 7寸电容触摸屏驱动 (FT5206 / FT5426 I2C 硬件引擎)
    // ========================================================================
    wire       touch_valid;
    wire       touch_down;
    wire [9:0] touch_x;
    wire [8:0] touch_y;
    wire [2:0] touch_cnt;

    wire [1:0] touch_chip_type;

    touch_ft5206_i2c #(
        .CLK_HZ  (50_000_000),
        .SCL_HZ  (100_000),
        .POLL_HZ (80)
    ) u_touch (
        .clk        (clk),
        .rst_n      (rst_n),
        .tp_scl     (tp_scl),
        .tp_sda     (tp_sda),
        .tp_int     (tp_int),
        .tp_rst_n   (tp_rst_n),
        .touch_valid(touch_valid),
        .touch_down (touch_down),
        .touch_x    (touch_x),
        .touch_y    (touch_y),
        .touch_cnt  (touch_cnt),
        .chip_type  (touch_chip_type),
        .dbg_ack_ok ()
    );

    // ------------------------------------------------------------------------
    // 触摸屏按键与乐器弹奏事件解码器 (Touch Sound & Navigation Decoder)
    // ------------------------------------------------------------------------
    reg        touch_page_req = 1'b0;
    reg [1:0]  touch_page_val = 2'd0;
    reg        touch_down_r = 1'b0;
    reg [6:0]  cur_touch_note = 7'd0;
    reg        touch_note_active = 1'b0;

    // 钢琴触键计算函数 (C4..B4)
    function [6:0] calc_piano_note;
        input [9:0] tx;
        input [8:0] ty;
        begin
            calc_piano_note = 7'd60; // 默认 C4
            if (ty <= 9'd402) begin
                if      (tx >= 10'd491 && tx <= 10'd517) calc_piano_note = 7'd61; // C#4
                else if (tx >= 10'd536 && tx <= 10'd562) calc_piano_note = 7'd63; // D#4
                else if (tx >= 10'd624 && tx <= 10'd650) calc_piano_note = 7'd66; // F#4
                else if (tx >= 10'd669 && tx <= 10'd695) calc_piano_note = 7'd68; // G#4
                else if (tx >= 10'd714 && tx <= 10'd740) calc_piano_note = 7'd70; // A#4
                else begin
                    if      (tx < 10'd505) calc_piano_note = 7'd60; // C4
                    else if (tx < 10'd550) calc_piano_note = 7'd62; // D4
                    else if (tx < 10'd595) calc_piano_note = 7'd64; // E4
                    else if (tx < 10'd640) calc_piano_note = 7'd65; // F4
                    else if (tx < 10'd685) calc_piano_note = 7'd67; // G4
                    else if (tx < 10'd730) calc_piano_note = 7'd69; // A4
                    else                   calc_piano_note = 7'd71; // B4
                end
            end else begin
                if      (tx < 10'd505) calc_piano_note = 7'd60; // C4
                else if (tx < 10'd550) calc_piano_note = 7'd62; // D4
                else if (tx < 10'd595) calc_piano_note = 7'd64; // E4
                else if (tx < 10'd640) calc_piano_note = 7'd65; // F4
                else if (tx < 10'd685) calc_piano_note = 7'd67; // G4
                else if (tx < 10'd730) calc_piano_note = 7'd69; // A4
                else                   calc_piano_note = 7'd71; // B4
            end
        end
    endfunction

    // 吉他触键计算函数 (6弦 x 5品)
    function [6:0] calc_guitar_note;
        input [9:0] tx;
        input [8:0] ty;
        reg [6:0] open_n;
        reg [3:0] fret;
        begin
            if      (ty < 9'd347) open_n = 7'd40; // 6弦 E2
            else if (ty < 9'd369) open_n = 7'd45; // 5弦 A2
            else if (ty < 9'd391) open_n = 7'd50; // 4弦 D3
            else if (ty < 9'd413) open_n = 7'd55; // 3弦 G3
            else if (ty < 9'd435) open_n = 7'd59; // 2弦 B3
            else                  open_n = 7'd64; // 1弦 E4

            if      (tx < 10'd525) fret = 4'd0; // 空弦
            else if (tx < 10'd585) fret = 4'd1; // 1品
            else if (tx < 10'd645) fret = 4'd2; // 2品
            else if (tx < 10'd705) fret = 4'd3; // 3品
            else if (tx < 10'd765) fret = 4'd4; // 4品
            else                   fret = 4'd5; // 5品

            calc_guitar_note = open_n + {3'd0, fret};
        end
    endfunction

    // 小提琴触键计算函数 (4弦 x 4把位)
    function [6:0] calc_violin_note;
        input [9:0] tx;
        input [8:0] ty;
        reg [6:0] open_n;
        reg [3:0] semi;
        begin
            if      (ty < 9'd362) open_n = 7'd55; // G3
            else if (ty < 9'd392) open_n = 7'd62; // D4
            else if (ty < 9'd422) open_n = 7'd69; // A4
            else                  open_n = 7'd76; // E5

            if      (tx < 10'd525) semi = 4'd0; // 空弦
            else if (tx < 10'd585) semi = 4'd2; // 一把位
            else if (tx < 10'd645) semi = 4'd4; // 二把位
            else if (tx < 10'd700) semi = 4'd5; // 三把位
            else                   semi = 4'd7; // 四把位

            calc_violin_note = open_n + {3'd0, semi};
        end
    endfunction

    // 二胡触键计算函数 (内弦D4 / 外弦A4 x 4把位)
    function [6:0] calc_erhu_note;
        input [9:0] tx;
        input [8:0] ty;
        reg [6:0] open_n;
        reg [3:0] semi;
        begin
            if (ty < 9'd390) open_n = 7'd62; // 内弦 D4
            else             open_n = 7'd69; // 外弦 A4

            if      (tx < 10'd525) semi = 4'd0; // 空弦
            else if (tx < 10'd585) semi = 4'd2; // 一把位
            else if (tx < 10'd645) semi = 4'd4; // 二把位
            else if (tx < 10'd700) semi = 4'd5; // 三把位
            else                   semi = 4'd7; // 四把位

            calc_erhu_note = open_n + {3'd0, semi};
        end
    endfunction

    reg [6:0] target_touch_note;
    always @(*) begin
        if (timbre_sel == 2'd1)
            target_touch_note = calc_guitar_note(touch_x, touch_y);
        else if (timbre_sel == 2'd2)
            target_touch_note = calc_violin_note(touch_x, touch_y);
        else if (timbre_sel == 2'd3)
            target_touch_note = calc_erhu_note(touch_x, touch_y);
        else
            target_touch_note = calc_piano_note(touch_x, touch_y);
    end

    // 触摸去抖与音符脉冲发射
    always @(posedge clk) begin
        if (!rst_n) begin
            touch_down_r       <= 1'b0;
            cur_touch_note     <= 7'd0;
            touch_note_active  <= 1'b0;
            touch_on_valid     <= 1'b0;
            touch_on_note      <= 7'd0;
            touch_on_vel       <= 7'd0;
            touch_off_valid    <= 1'b0;
            touch_off_note     <= 7'd0;
            touch_timbre_pulse <= 1'b0;
            touch_fx_pulse     <= 1'b0;
            touch_vol_valid    <= 1'b0;
            touch_vol_val      <= 7'd100;
        end else begin
            touch_on_valid     <= 1'b0;
            touch_off_valid    <= 1'b0;
            touch_timbre_pulse <= 1'b0;
            touch_fx_pulse     <= 1'b0;
            touch_vol_valid    <= 1'b0;
            touch_page_req     <= 1'b0;
            touch_down_r       <= touch_down;

            if (touch_valid) begin
                // 1. 触摸按下瞬间 (Rising edge of touch_down)
                if (touch_down && !touch_down_r) begin
                    // 点击导航栏 (py <= 40)：仅命中 4 个 Tab 键区时才切页，点击左上角标题区不误切
                    if (touch_y <= 9'd40) begin
                        if      (touch_x >= 10'd168 && touch_x <= 10'd300) begin touch_page_req <= 1'b1; touch_page_val <= 2'd0; end // 演奏
                        else if (touch_x >= 10'd318 && touch_x <= 10'd450) begin touch_page_req <= 1'b1; touch_page_val <= 2'd1; end // 示波
                        else if (touch_x >= 10'd468 && touch_x <= 10'd600) begin touch_page_req <= 1'b1; touch_page_val <= 2'd2; end // 谱峰
                        else if (touch_x >= 10'd618 && touch_x <= 10'd750) begin touch_page_req <= 1'b1; touch_page_val <= 2'd3; end // 曲目
                    end
                    // 点击主页状态卡片 (Page 0, py: 44..108)
                    else if (ui_page == 2'd0 && touch_y >= 9'd44 && touch_y <= 9'd108) begin
                        if (touch_x >= 10'd276 && touch_x <= 10'd522) begin
                            // 触摸音量条区域 (py >= 78, px: 345..515)，修复原先 7'd160 截断为 32 的溢出 bug
                            if (touch_y >= 9'd78 && touch_x >= 10'd345 && touch_x <= 10'd515) begin
                                if (touch_x <= 10'd350)      touch_vol_val <= 7'd0;
                                else if (touch_x >= 10'd510) touch_vol_val <= 7'd127;
                                else                         touch_vol_val <= (({8'd0, touch_x - 10'd350} * 18'd204) >> 8);
                                touch_vol_valid <= 1'b1;
                            end else if (touch_y < 9'd78) begin
                                touch_timbre_pulse <= 1'b1; // 切换乐器音色
                            end
                        end else if (touch_x >= 10'd532 && touch_x <= 10'd778) begin
                            touch_fx_pulse <= 1'b1; // 切换硬件音效
                        end
                    end
                    // 点击乐器演奏区 (Page 0, px >= 456, py >= 310)
                    else if (ui_page == 2'd0 && touch_x >= 10'd456 && touch_y >= 9'd310) begin
                        cur_touch_note    <= target_touch_note;
                        touch_note_active <= 1'b1;
                        touch_on_valid    <= 1'b1;
                        touch_on_note     <= target_touch_note;
                        touch_on_vel      <= 7'd110;
                    end
                end
                // 2. 持续按住移动 (Touch held / moving)：支持滑奏与平滑拖动音量条
                else if (touch_down && touch_down_r) begin
                    if (ui_page == 2'd0 && touch_y >= 9'd76 && touch_y <= 9'd108 && touch_x >= 10'd340 && touch_x <= 10'd520) begin
                        if (touch_x <= 10'd350)      touch_vol_val <= 7'd0;
                        else if (touch_x >= 10'd510) touch_vol_val <= 7'd127;
                        else                         touch_vol_val <= (({8'd0, touch_x - 10'd350} * 18'd204) >> 8);
                        touch_vol_valid <= 1'b1;
                    end else if (ui_page == 2'd0 && touch_x >= 10'd456 && touch_y >= 9'd310) begin
                        if (touch_note_active && (target_touch_note != cur_touch_note)) begin
                            touch_off_valid   <= 1'b1;
                            touch_off_note    <= cur_touch_note;
                            cur_touch_note    <= target_touch_note;
                            touch_on_valid    <= 1'b1;
                            touch_on_note     <= target_touch_note;
                            touch_on_vel      <= 7'd110;
                        end else if (!touch_note_active) begin
                            cur_touch_note    <= target_touch_note;
                            touch_note_active <= 1'b1;
                            touch_on_valid    <= 1'b1;
                            touch_on_note     <= target_touch_note;
                            touch_on_vel      <= 7'd110;
                        end
                    end else if (touch_note_active) begin
                        touch_off_valid   <= 1'b1;
                        touch_off_note    <= cur_touch_note;
                        touch_note_active <= 1'b0;
                    end
                end
                // 3. 手指离开松开 (Falling edge of touch_down)
                else if (!touch_down && touch_down_r) begin
                    if (touch_note_active) begin
                        touch_off_valid   <= 1'b1;
                        touch_off_note    <= cur_touch_note;
                        touch_note_active <= 1'b0;
                    end
                end
            end
        end
    end

lcd_ui u_lcd_ui (
        .clk             (clk),
        .rst_n           (rst_n),
        .px              (px),
        .py              (py),
        .page            (ui_page),
        .frame_cnt       (frame_cnt),
        .audio_active    (audio_active),
        .scope_wave_y    (live_scope_wave_y),
        .scope_prev_y    (live_scope_prev_y),
        .vu_level        (live_vu_level),
        .work_mode       (work_mode),
        .timbre_sel      (timbre_sel),
        .fx_sel          (fx_sel),
        .active_voices   (live_active_voices),
        .live_note       (live_note),
        .live_vel        (live_vel),
        .note_active     (note_active),
        .song_index      (song_index_r),
        .song_playing    (song_playing),
        .song_progress   (song_progress_pct),
        .master_vol      (master_vol),
        .key_active_mask (key_active_mask),
        .song_elapsed_sec(song_elapsed_sec),
        .song_elapsed_min(song_elapsed_min),
        .song_total_sec  (song_total_sec),
        .song_note_idx   (song_note_idx_r),
        .song_sub_scroll (song_sub_scroll_r),
        .song_active_note(song_active_note),
        .liss_box        (liss_box),
        .liss_border     (liss_border),
        .liss_reticle    (liss_reticle),
        .liss_dot        (liss_dot),
        .spec_bar_hit    (spec_bar_hit),
        .spec_bar_zone   (spec_bar_zone),
        .touch_down      (touch_down),
        .touch_x         (touch_x),
        .touch_y         (touch_y),
        .color           (ui_color)
    );

    // ------------------------------------------------------------------------
    // 6. SSD1963 8080 Driver with Cold-Boot Watchdog & Screenshot Engine
    // ------------------------------------------------------------------------
    reg  [15:0] db_out;
    reg         db_oe;
    assign lcd_db = db_oe ? db_out : 16'hzzzz;

    reg [15:0] db_in_s1, db_in_s2;
    always @(posedge clk) begin
        db_in_s1 <= lcd_db;
        db_in_s2 <= db_in_s1;
    end

    localparam K_WR = 2'b00, K_RD = 2'b01, K_DLY = 2'b10, K_END = 2'b11;
    `define LCD_C(x)   {K_WR , 1'b0, 1'b0, 4'd0, 24'h0 | (x)}
    `define LCD_D(x)   {K_WR , 1'b1, 1'b0, 4'd0, 24'h0 | (x)}
    `define LCD_R8     {K_RD , 1'b1, 1'b0, 4'd0, 24'h0}
    `define LCD_R16    {K_RD , 1'b1, 1'b1, 4'd0, 24'h0}
    `define LCD_DLY(x) {K_DLY, 1'b0, 1'b0, 4'd0, 24'h0 | (x)}
    `define LCD_ENDS   {K_END, 1'b0, 1'b0, 4'd0, 24'h0}

    localparam [7:0] SEG_INIT      = 8'd0;
    localparam [7:0] SEG_FRAME     = 8'd68;
    localparam [7:0] SEG_DIAG      = 8'd100;
    localparam [7:0] SEG_SNAP_PREP = 8'd160;

    reg  [7:0]  pc;
    reg  [31:0] rom_q;
    always @(*) begin
        case (pc)
        // ---------------- INIT (ALIENTEK atk_md0700_reg_init + 33.3MHz PCLK)
        8'd0 : rom_q = `LCD_C(8'hE2);
        8'd1 : rom_q = `LCD_D(8'h1D);       // M = 29
        8'd2 : rom_q = `LCD_D(8'h02);       // N = 2  -> PLL = 10MHz*30/3 = 100MHz
        8'd3 : rom_q = `LCD_D(8'h04);
        8'd4 : rom_q = `LCD_DLY(24'd50000); // 1ms
        8'd5 : rom_q = `LCD_C(8'hE0);
        8'd6 : rom_q = `LCD_D(8'h01);       // PLL enable
        8'd7 : rom_q = `LCD_DLY(24'd5000000);// 100ms
        8'd8 : rom_q = `LCD_C(8'hE0);
        8'd9 : rom_q = `LCD_D(8'h03);       // PLL lock
        8'd10: rom_q = `LCD_DLY(24'd2500000);// 50ms
        8'd11: rom_q = `LCD_C(8'h01);       // soft reset
        8'd12: rom_q = `LCD_DLY(24'd2500000);// 50ms
        8'd13: rom_q = `LCD_C(8'hE6);
        8'd14: rom_q = `LCD_D(8'h05);
        8'd15: rom_q = `LCD_D(8'h53);
        8'd16: rom_q = `LCD_D(8'hF6);       // 33.3MHz PCLK
        8'd17: rom_q = `LCD_C(8'hB0);
        8'd18: rom_q = `LCD_D(8'h20);
        8'd19: rom_q = `LCD_D(8'h00);
        8'd20: rom_q = `LCD_D(8'h03);
        8'd21: rom_q = `LCD_D(8'h1F);       // HDP = 799
        8'd22: rom_q = `LCD_D(8'h01);
        8'd23: rom_q = `LCD_D(8'hDF);       // VDP = 479
        8'd24: rom_q = `LCD_D(8'h00);
        8'd25: rom_q = `LCD_C(8'hB4);
        8'd26: rom_q = `LCD_D(8'h04);
        8'd27: rom_q = `LCD_D(8'h1F);       // HT = 1055
        8'd28: rom_q = `LCD_D(8'h00);
        8'd29: rom_q = `LCD_D(8'h2E);       // HPS = 46
        8'd30: rom_q = `LCD_D(8'h00);
        8'd31: rom_q = `LCD_D(8'h00);
        8'd32: rom_q = `LCD_D(8'h00);
        8'd33: rom_q = `LCD_D(8'h00);
        8'd34: rom_q = `LCD_C(8'hB6);
        8'd35: rom_q = `LCD_D(8'h02);
        8'd36: rom_q = `LCD_D(8'h0C);       // VT = 524
        8'd37: rom_q = `LCD_D(8'h00);
        8'd38: rom_q = `LCD_D(8'h17);       // VPS = 23
        8'd39: rom_q = `LCD_D(8'h16);
        8'd40: rom_q = `LCD_D(8'h00);
        8'd41: rom_q = `LCD_D(8'h00);
        8'd42: rom_q = `LCD_C(8'hF0);
        8'd43: rom_q = `LCD_D(8'h03);       // 16-bit 565
        8'd44: rom_q = `LCD_C(8'h29);       // display on
        8'd45: rom_q = `LCD_C(8'hD0);
        8'd46: rom_q = `LCD_D(8'h00);       // DBC off
        8'd47: rom_q = `LCD_C(8'hBE);       // PWM 100%
        8'd48: rom_q = `LCD_D(8'h05);
        8'd49: rom_q = `LCD_D(8'hFE);
        8'd50: rom_q = `LCD_D(8'h01);
        8'd51: rom_q = `LCD_D(8'h00);
        8'd52: rom_q = `LCD_D(8'h00);
        8'd53: rom_q = `LCD_D(8'h00);
        8'd54: rom_q = `LCD_C(8'hB8);
        8'd55: rom_q = `LCD_D(8'h03);
        8'd56: rom_q = `LCD_D(8'h01);
        8'd57: rom_q = `LCD_C(8'hBA);
        8'd58: rom_q = `LCD_D(8'h01);
        8'd59: rom_q = `LCD_C(8'h36);
        8'd60: rom_q = `LCD_D(8'h00);
        8'd61: rom_q = `LCD_DLY(24'd500000);
        8'd62: rom_q = `LCD_ENDS;

        // ---------------- FRAME header (refresh 2A/2B/2C)
        8'd68: rom_q = `LCD_C(8'hF0);
        8'd69: rom_q = `LCD_D(8'h03);
        8'd70: rom_q = `LCD_C(8'h29);
        8'd71: rom_q = `LCD_C(8'hD0);
        8'd72: rom_q = `LCD_D(8'h00);
        8'd73: rom_q = `LCD_C(8'hBE);
        8'd74: rom_q = `LCD_D(8'h05);
        8'd75: rom_q = `LCD_D(8'hFE);
        8'd76: rom_q = `LCD_D(8'h01);
        8'd77: rom_q = `LCD_D(8'h00);
        8'd78: rom_q = `LCD_D(8'h00);
        8'd79: rom_q = `LCD_D(8'h00);
        8'd80: rom_q = `LCD_C(8'hB8);
        8'd81: rom_q = `LCD_D(8'h03);
        8'd82: rom_q = `LCD_D(8'h01);
        8'd83: rom_q = `LCD_C(8'hBA);
        8'd84: rom_q = `LCD_D(8'h01);
        8'd85: rom_q = `LCD_C(8'h36);
        8'd86: rom_q = `LCD_D(8'h00);
        8'd87: rom_q = `LCD_C(8'h2A);
        8'd88: rom_q = `LCD_D(8'h00);
        8'd89: rom_q = `LCD_D(8'h00);
        8'd90: rom_q = `LCD_D(8'h03);
        8'd91: rom_q = `LCD_D(8'h1F);
        8'd92: rom_q = `LCD_C(8'h2B);
        8'd93: rom_q = `LCD_D(8'h00);
        8'd94: rom_q = `LCD_D(8'h00);
        8'd95: rom_q = `LCD_D(8'h01);
        8'd96: rom_q = `LCD_D(8'hDF);
        8'd97: rom_q = `LCD_C(8'h2C);
        8'd98: rom_q = `LCD_ENDS;

        // ---------------- DIAG readback (32 bytes)
        8'd100: rom_q = `LCD_C(8'hA1);
        8'd101: rom_q = `LCD_DLY(24'd2500);
        8'd102: rom_q = `LCD_R8; 8'd103: rom_q = `LCD_R8; 8'd104: rom_q = `LCD_R8; 8'd105: rom_q = `LCD_R8; 8'd106: rom_q = `LCD_R8;
        8'd107: rom_q = `LCD_C(8'h0A); 8'd108: rom_q = `LCD_DLY(24'd2500); 8'd109: rom_q = `LCD_R8;
        8'd110: rom_q = `LCD_C(8'hE4); 8'd111: rom_q = `LCD_DLY(24'd2500); 8'd112: rom_q = `LCD_R8;
        8'd113: rom_q = `LCD_C(8'hF1); 8'd114: rom_q = `LCD_DLY(24'd2500); 8'd115: rom_q = `LCD_R8;
        8'd116: rom_q = `LCD_C(8'h0B); 8'd117: rom_q = `LCD_DLY(24'd2500); 8'd118: rom_q = `LCD_R8;
        8'd119: rom_q = `LCD_C(8'hB1); 8'd120: rom_q = `LCD_DLY(24'd2500);
        8'd121: rom_q = `LCD_R8; 8'd122: rom_q = `LCD_R8; 8'd123: rom_q = `LCD_R8; 8'd124: rom_q = `LCD_R8; 8'd125: rom_q = `LCD_R8; 8'd126: rom_q = `LCD_R8; 8'd127: rom_q = `LCD_R8;
        8'd128: rom_q = `LCD_C(8'hE7); 8'd129: rom_q = `LCD_DLY(24'd2500);
        8'd130: rom_q = `LCD_R8; 8'd131: rom_q = `LCD_R8; 8'd132: rom_q = `LCD_R8;
        8'd133: rom_q = `LCD_C(8'hBF); 8'd134: rom_q = `LCD_DLY(24'd2500);
        8'd135: rom_q = `LCD_R8; 8'd136: rom_q = `LCD_R8; 8'd137: rom_q = `LCD_R8; 8'd138: rom_q = `LCD_R8; 8'd139: rom_q = `LCD_R8; 8'd140: rom_q = `LCD_R8; 8'd141: rom_q = `LCD_R8;
        8'd142: rom_q = `LCD_C(8'h2A); 8'd143: rom_q = `LCD_D(8'h00); 8'd144: rom_q = `LCD_D(8'h00); 8'd145: rom_q = `LCD_D(8'h03); 8'd146: rom_q = `LCD_D(8'h1F);
        8'd147: rom_q = `LCD_C(8'h2B); 8'd148: rom_q = `LCD_D(8'h00); 8'd149: rom_q = `LCD_D(8'h00); 8'd150: rom_q = `LCD_D(8'h01); 8'd151: rom_q = `LCD_D(8'hDF);
        8'd152: rom_q = `LCD_C(8'h2E); 8'd153: rom_q = `LCD_DLY(24'd2500);
        8'd154: rom_q = `LCD_R16; 8'd155: rom_q = `LCD_R16; 8'd156: rom_q = `LCD_R16;
        8'd157: rom_q = `LCD_C(8'h00);
        8'd158: rom_q = `LCD_ENDS;

        // ---------------- SCREENSHOT prep
        8'd160: rom_q = `LCD_C(8'h2A); 8'd161: rom_q = `LCD_D(8'h00); 8'd162: rom_q = `LCD_D(8'h00); 8'd163: rom_q = `LCD_D(8'h03); 8'd164: rom_q = `LCD_D(8'h1F);
        8'd165: rom_q = `LCD_C(8'h2B); 8'd166: rom_q = `LCD_D(8'h00); 8'd167: rom_q = `LCD_D(8'h00); 8'd168: rom_q = `LCD_D(8'h01); 8'd169: rom_q = `LCD_D(8'hDF);
        8'd170: rom_q = `LCD_C(8'h2E);
        8'd171: rom_q = `LCD_ENDS;

        default: rom_q = `LCD_ENDS;
        endcase
    end

    wire [1:0]  op_kind = rom_q[31:30];
    wire        op_rs   = rom_q[29];
    wire        op_w16  = rom_q[28];
    wire [23:0] op_data = rom_q[23:0];

    reg [7:0] dbuf [0:31];
    reg [4:0] dptr;

    localparam [3:0]
        M_RST_LO     = 4'd0,
        M_RST_HI     = 4'd1,
        M_SEQ        = 4'd2,
        M_DLY        = 4'd3,
        M_WR         = 4'd4,
        M_PIX        = 4'd5,
        M_RD         = 4'd6,
        M_PRINT      = 4'd7,
        M_PRINT_WAIT = 4'd8,
        M_SNAP_HDR   = 4'd9,
        M_SNAP_BURST = 4'd10,
        M_SNAP_TAIL  = 4'd11,
        M_OFFLINE    = 4'd12,
        M_INTERFRAME = 4'd13;

    reg [3:0]  ms, tx_ret_ms;
    reg [1:0]  seg;
    reg [6:0]  ph;
    reg [26:0] dly;
    reg        init_done;
    reg        print_req;
    reg [11:0] sframe;
    reg [2:0]  pll_fail_cnt = 3'd0;
    reg        snap_active  = 1'b0;

    assign lcd_init_ok = init_done;

    reg [15:0] cur_pix, rle_pix;
    reg [7:0]  rle_cnt;
    reg        last_pix_flag;
    reg        snap_dummy_done = 1'b0;
    reg [7:0]  tx_buf [0:7];
    reg [3:0]  tx_idx, tx_len;
    reg        snap_u_start;
    reg [7:0]  snap_u_byte;

    // UART Transmitter State Declarations
    reg  [8:0] u_div;
    reg  [3:0] u_bit;
    reg  [9:0] u_sh;
    reg        u_busy;
    wire       u_tick = (u_div == 9'd433);

    localparam [4:0]
        U_IDLE = 5'd0, U_HDR = 5'd1, U_TAG = 5'd2, U_BH = 5'd3, U_BL = 5'd4,
        U_SP = 5'd5, U_NL = 5'd6, U_CR = 5'd7, U_WAIT = 5'd8,
        U_TP1 = 5'd9, U_TP2 = 5'd10, U_TP3 = 5'd11, U_TP4 = 5'd12, U_TP5 = 5'd13,
        U_TP6 = 5'd14, U_TP7 = 5'd15, U_TP8 = 5'd16, U_TP9 = 5'd17, U_TP10 = 5'd18, U_TP11 = 5'd19;

    reg [4:0] us, us_ret;
    reg [4:0] ubi, ubi_end;
    reg [2:0] utag;
    reg       diag_u_start;
    reg [7:0] diag_u_byte;
    wire      print_busy = (us != U_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ms <= M_RST_LO; tx_ret_ms <= M_RST_LO; seg <= 0; pc <= SEG_INIT; ph <= 0; dly <= 27'd2500000;
            lcd_cs <= 1'b1; lcd_rs <= 1'b1; lcd_wr <= 1'b1; lcd_rd <= 1'b1; lcd_rst <= 1'b0;
            db_out <= 16'h0000; db_oe <= 1'b0;
            px <= 0; py <= 0; frame_cnt <= 0; init_done <= 1'b0; dptr <= 0;
            print_req <= 1'b0; sframe <= 0;
            snap_active <= 1'b0; snap_u_start <= 1'b0; snap_u_byte <= 8'h00;
            snap_clear_req <= 1'b0; reinit_clear_req <= 1'b0; frame_end_pulse <= 1'b0;
            tx_idx <= 0; tx_len <= 0; cur_pix <= 0; rle_pix <= 0; rle_cnt <= 0; last_pix_flag <= 1'b0; snap_dummy_done <= 1'b0;
        end else begin
            print_req        <= 1'b0;
            snap_u_start     <= 1'b0;
            snap_clear_req   <= 1'b0;
            diag_clear_req   <= 1'b0;
            reinit_clear_req <= 1'b0;
            frame_end_pulse  <= 1'b0;

            case (ms)
            M_RST_LO: begin
                lcd_rst <= 1'b0; lcd_cs <= 1'b1; lcd_rs <= 1'b1; lcd_wr <= 1'b1; lcd_rd <= 1'b1;
                db_out  <= 16'hFFFF; db_oe <= 1'b0;
                if (dly == 0) begin lcd_rst <= 1'b1; dly <= 27'd15000000; ms <= M_RST_HI; end
                else dly <= dly - 1'b1;
            end
            M_RST_HI: begin
                lcd_cs <= 1'b1; lcd_rs <= 1'b1; lcd_wr <= 1'b1; lcd_rd <= 1'b1;
                db_out <= 16'hFFFF; db_oe <= 1'b0;
                if (dly == 0) begin pc <= SEG_INIT; seg <= 0; ms <= M_SEQ; end
                else dly <= dly - 1'b1;
            end

            M_SEQ: begin
                ph <= 0;
                case (op_kind)
                K_WR : begin db_out <= op_data[15:0]; db_oe <= 1'b1; lcd_rs <= op_rs; ms <= M_WR; end
                K_RD : begin lcd_rs <= 1'b1; ms <= M_RD; end
                K_DLY: begin dly <= op_data; db_out <= 16'hFFFF; db_oe <= 1'b1; ms <= M_DLY; end
                K_END: begin
                    if (seg == 2'd0) begin
                        // Init commands sent. Immediately verify screen presence via SEG_DIAG
                        seg <= 2'd2; pc <= SEG_DIAG; dptr <= 0; ms <= M_SEQ;
                    end else if (seg == 2'd1) begin
                        px <= 0; py <= 0; ms <= M_PIX;
                        db_out <= 16'h0000; db_oe <= 1'b1; lcd_rs <= 1'b1;
                    end else if (seg == 2'd2) begin
                        ms <= M_PRINT;
                    end else begin
                        px <= 0; py <= 0; rle_cnt <= 8'd0; last_pix_flag <= 1'b0;
                        snap_dummy_done <= 1'b0;
                        ms <= M_SNAP_HDR;
                    end
                end
                endcase
            end

            M_DLY: begin
                lcd_cs <= 1'b1; lcd_wr <= 1'b1; lcd_rd <= 1'b1;
                db_out <= 16'hFFFF; db_oe <= 1'b0;
                if (dly == 0) begin pc <= pc + 1'b1; ms <= M_SEQ; end
                else dly <= dly - 1'b1;
            end

            M_WR: begin
                db_oe <= 1'b1;
                ph <= ph + 1'b1;
                case (ph)
                    7'd0  : begin lcd_cs <= 1'b0; lcd_wr <= 1'b1; lcd_rd <= 1'b1; end
                    7'd20 : lcd_wr <= 1'b0;
                    7'd52 : lcd_wr <= 1'b1;
                    7'd72 : begin lcd_cs <= 1'b1; db_out <= 16'hFFFF; end
                    7'd100: begin ph <= 7'd0; pc <= pc + 1'b1; ms <= M_SEQ; end
                    default: ;
                endcase
            end

            M_PIX: begin
                db_oe <= 1'b1;
                ph <= ph + 1'b1;
                case (ph)
                    7'd0 : begin lcd_cs <= 1'b0; lcd_wr <= 1'b1; lcd_rd <= 1'b1; end
                    7'd2 : db_out <= ui_color;
                    7'd4 : lcd_wr <= 1'b0;
                    7'd12: begin
                        lcd_wr <= 1'b1;
                        if (px == 10'd799) begin
                            px <= 10'd0;
                            if (py == 9'd479) py <= 9'd0;
                            else              py <= py + 1'b1;
                        end else begin
                            px <= px + 1'b1;
                        end
                    end
                    7'd19: begin
                        ph <= 7'd0;
                        if (px == 10'd0 && py == 9'd0) begin
                            lcd_cs <= 1'b1; db_oe <= 1'b0; db_out <= 16'hFFFF;
                            frame_end_pulse <= 1'b1;
                            if (snap_req) begin
                                snap_clear_req <= 1'b1; snap_active <= 1'b1;
                                seg <= 2'd3; pc <= SEG_SNAP_PREP; ms <= M_SEQ;
                            end else begin
                                seg <= 2'd2; pc <= SEG_DIAG; dptr <= 0; ms <= M_SEQ;
                            end
                        end
                    end
                    default: ;
                endcase
            end

            M_RD: begin
                ph <= ph + 1'b1;
                case (ph)
                    7'd0  : begin db_oe <= 1'b0; lcd_cs <= 1'b0; lcd_rd <= 1'b1; lcd_wr <= 1'b1; end
                    7'd10 : lcd_rd <= 1'b0;
                    7'd20 : begin
                        if (op_w16) begin
                            dbuf[dptr]      <= db_in_s2[15:8];
                            dbuf[dptr+1'b1] <= db_in_s2[7:0];
                            dptr <= dptr + 2'd2;
                        end else begin
                            dbuf[dptr] <= db_in_s2[7:0];
                            dptr <= dptr + 1'b1;
                        end
                        lcd_rd <= 1'b1;
                    end
                    7'd36 : lcd_cs <= 1'b1;
                    7'd52 : begin ph <= 7'd0; pc <= pc + 1'b1; db_oe <= 1'b0; db_out <= 16'hFFFF; ms <= M_SEQ; end
                    default: ;
                endcase
            end

            M_PRINT: begin
                lcd_cs <= 1'b1; db_oe <= 1'b0; db_out <= 16'hFFFF;
                if (!print_busy && us == U_IDLE) begin
                    sframe    <= frame_cnt;
                    print_req <= diag_req; // Only print telemetry when 'd' command requested
                    if (diag_req) diag_clear_req <= 1'b1;
                    ms        <= M_PRINT_WAIT;
                end
            end

            M_PRINT_WAIT: begin
                frame_cnt   <= frame_cnt + 1'b1;
                snap_active <= 1'b0;

                // Continuous Display Refresh Loop (Rock-solid, zero flickering, zero periodic reset)
                init_done <= 1'b1;

                if (reinit_req) begin
                    reinit_clear_req <= 1'b1;
                    pll_fail_cnt     <= 3'd0;
                    init_done        <= 1'b0;
                    dly              <= 27'd2500000;
                    ms               <= M_RST_LO;
                end else begin
                    // Inter-frame quiet sleep (20 ms = 1,000,000 clocks @ 50MHz)
                    // SSD1963 refreshes TFT glass from internal GRAM; FPGA bus rests quietly in High-Z!
                    dly <= 27'd1000000;
                    ms  <= M_INTERFRAME;
                end
            end

            M_INTERFRAME: begin
                lcd_cs <= 1'b1; lcd_wr <= 1'b1; lcd_rd <= 1'b1;
                db_oe  <= 1'b0; db_out <= 16'hFFFF;
                if (dly == 0) begin
                    seg <= 2'd1;
                    pc  <= SEG_FRAME;
                    ms  <= M_SEQ;
                end else begin
                    dly <= dly - 1'b1;
                end
            end

            M_OFFLINE: begin
                lcd_cs <= 1'b1; lcd_wr <= 1'b1; lcd_rd <= 1'b1;
                db_oe  <= 1'b0; db_out <= 16'hFFFF;
                if (dly == 0) begin
                    dly <= 27'd2500000;
                    ms  <= M_RST_LO; // Periodically re-probe to detect screen plug-in
                end else begin
                    dly <= dly - 1'b1;
                end
            end

            M_SNAP_HDR: begin
                if (!print_busy && us == U_IDLE && !u_busy) begin
                    tx_buf[0] <= "I"; tx_buf[1] <= "M"; tx_buf[2] <= "G";
                    tx_buf[3] <= snap_rle ? "C" : "Q";
                    tx_buf[4] <= snap_rle ? 8'h20 : 8'hC8;
                    tx_buf[5] <= snap_rle ? 8'h03 : 8'h00;
                    tx_buf[6] <= snap_rle ? 8'hE0 : 8'h78;
                    tx_buf[7] <= snap_rle ? 8'h01 : 8'h00;
                    tx_idx <= 0; tx_len <= 8;
                    tx_ret_ms <= M_SNAP_BURST;
                    ms <= M_SNAP_TAIL;
                end
            end

            M_SNAP_BURST: begin
                ph <= ph + 1'b1;
                case (ph)
                    7'd0 : begin db_oe <= 1'b0; lcd_cs <= 1'b0; lcd_rd <= 1'b1; lcd_wr <= 1'b1; end
                    7'd6 : lcd_rd <= 1'b0;
                    7'd26: begin cur_pix <= db_in_s2; lcd_rd <= 1'b1; end
                    7'd34: begin
                        if (!snap_dummy_done) begin
                        end else if (snap_rle) begin
                            if (px == 0 && py == 0) begin
                                rle_pix <= cur_pix; rle_cnt <= 8'd1;
                            end else if (cur_pix == rle_pix && rle_cnt < 8'd255) begin
                                rle_cnt <= rle_cnt + 1'b1;
                            end else begin
                                tx_buf[0] <= rle_cnt; tx_buf[1] <= rle_pix[15:8]; tx_buf[2] <= rle_pix[7:0];
                                tx_idx <= 0; tx_len <= 3;
                                rle_pix <= cur_pix; rle_cnt <= 8'd1;
                            end
                        end else begin
                            if ((px[1:0] == 2'd0) && (py[1:0] == 2'd0)) begin
                                tx_buf[0] <= cur_pix[15:8]; tx_buf[1] <= cur_pix[7:0];
                                tx_idx <= 0; tx_len <= 2;
                            end
                        end
                    end
                    7'd35: begin
                        if (!snap_dummy_done) begin
                            snap_dummy_done <= 1'b1;
                            ph <= 7'd0;
                        end else if (tx_len > 0) begin
                            tx_ret_ms <= M_SNAP_BURST;
                            ms <= M_SNAP_TAIL;
                        end else begin
                            ph <= 7'd0;
                            if (px == 10'd799) begin
                                px <= 0;
                                if (py == 9'd479) begin
                                    lcd_cs <= 1'b1;
                                    if (snap_rle) begin
                                        tx_buf[0] <= rle_cnt; tx_buf[1] <= rle_pix[15:8]; tx_buf[2] <= rle_pix[7:0];
                                        tx_idx <= 0; tx_len <= 3;
                                        last_pix_flag <= 1'b1; tx_ret_ms <= M_SNAP_BURST; ms <= M_SNAP_TAIL;
                                    end else begin
                                        tx_buf[0] <= "E"; tx_buf[1] <= "N"; tx_buf[2] <= "D"; tx_buf[3] <= "!";
                                        tx_idx <= 0; tx_len <= 4;
                                        tx_ret_ms <= M_PRINT_WAIT; ms <= M_SNAP_TAIL;
                                    end
                                end else py <= py + 1'b1;
                            end else px <= px + 1'b1;
                        end
                    end
                    default: ;
                endcase
            end

            M_SNAP_TAIL: begin
                if (!u_busy && !snap_u_start) begin
                    if (tx_idx < tx_len) begin
                        snap_u_byte  <= tx_buf[tx_idx];
                        snap_u_start <= 1'b1;
                        tx_idx       <= tx_idx + 1'b1;
                    end else begin
                        tx_len <= 0;
                        if (last_pix_flag) begin
                            last_pix_flag <= 1'b0;
                            tx_buf[0] <= "E"; tx_buf[1] <= "N"; tx_buf[2] <= "D"; tx_buf[3] <= "!";
                            tx_idx <= 0; tx_len <= 4;
                            tx_ret_ms <= M_PRINT_WAIT;
                        end else begin
                            ph <= 7'd0;
                            if (tx_ret_ms == M_SNAP_BURST) begin
                                if (px == 10'd799) begin
                                    px <= 0;
                                    if (py == 9'd479) begin
                                        tx_buf[0] <= "E"; tx_buf[1] <= "N"; tx_buf[2] <= "D"; tx_buf[3] <= "!";
                                        tx_idx <= 0; tx_len <= 4;
                                        tx_ret_ms <= M_PRINT_WAIT;
                                    end else py <= py + 1'b1;
                                end else px <= px + 1'b1;
                            end
                            ms <= tx_ret_ms;
                        end
                    end
                end
            end
            default: ms <= M_RST_LO;
            endcase
        end
    end

    // ------------------------------------------------------------------------
    // 7. UART Transmitter (Diagnostic Telemetry + Screenshot Transfer)
    // ------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            u_div <= 0; u_bit <= 0; u_sh <= 10'h3FF; u_busy <= 1'b0;
        end else begin
            if (u_busy) begin
                if (u_tick) begin
                    u_div <= 0;
                    u_sh  <= {1'b1, u_sh[9:1]};
                    if (u_bit == 4'd9) u_busy <= 1'b0;
                    else u_bit <= u_bit + 1'b1;
                end else u_div <= u_div + 1'b1;
            end else if (snap_u_start) begin
                u_sh   <= {1'b1, snap_u_byte, 1'b0};
                u_bit  <= 0; u_div <= 0; u_busy <= 1'b1;
            end else if (diag_u_start) begin
                u_sh   <= {1'b1, diag_u_byte, 1'b0};
                u_bit  <= 0; u_div <= 0; u_busy <= 1'b1;
            end
        end
    end
    assign lcd_uart_tx = u_sh[0];

    function [7:0] hexc;
        input [3:0] n;
        hexc = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h41 + {4'd0, n - 4'd10});
    endfunction

    reg [7:0] sbuf [0:31];
    reg [2:0] sp_hdr;
    integer k;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            us <= U_IDLE; us_ret <= U_IDLE; ubi <= 0; ubi_end <= 0; utag <= 0;
            diag_u_start <= 1'b0; diag_u_byte <= 8'h00; sp_hdr <= 0;
            for (k = 0; k < 32; k = k + 1) sbuf[k] <= 8'h00;
        end else begin
            diag_u_start <= 1'b0;
            if (print_req) for (k = 0; k < 32; k = k + 1) sbuf[k] <= dbuf[k];

            case (us)
            U_IDLE: if (print_req && !snap_active) begin sp_hdr <= 0; us <= U_HDR; end
            U_HDR: begin
                sp_hdr <= sp_hdr + 1'b1;
                case (sp_hdr)
                    3'd0: begin diag_u_byte <= "F"; diag_u_start <= 1'b1; us <= U_WAIT; us_ret <= U_HDR; end
                    3'd1: begin diag_u_byte <= hexc(sframe[11:8]); diag_u_start <= 1'b1; us <= U_WAIT; us_ret <= U_HDR; end
                    3'd2: begin diag_u_byte <= hexc(sframe[7:4]);  diag_u_start <= 1'b1; us <= U_WAIT; us_ret <= U_HDR; end
                    3'd3: begin diag_u_byte <= hexc(sframe[3:0]);  diag_u_start <= 1'b1; us <= U_WAIT; us_ret <= U_HDR; end
                    3'd4: begin diag_u_byte <= " "; diag_u_start <= 1'b1; utag <= 0; us <= U_WAIT; us_ret <= U_TAG; end
                    default: us <= U_IDLE;
                endcase
            end
            U_TAG: begin
                utag <= utag + 1'b1;
                case (utag)
                    3'd0: begin diag_u_byte <= "S"; diag_u_start <= 1'b1; ubi <= 0;  ubi_end <= 4;  us_ret <= U_BH; us <= U_WAIT; end
                    3'd1: begin diag_u_byte <= "P"; diag_u_start <= 1'b1; ubi <= 5;  ubi_end <= 5;  us_ret <= U_BH; us <= U_WAIT; end
                    3'd2: begin diag_u_byte <= "L"; diag_u_start <= 1'b1; ubi <= 6;  ubi_end <= 6;  us_ret <= U_BH; us <= U_WAIT; end
                    3'd3: begin diag_u_byte <= "C"; diag_u_start <= 1'b1; ubi <= 16; ubi_end <= 18; us_ret <= U_BH; us <= U_WAIT; end
                    3'd4: begin diag_u_byte <= "M"; diag_u_start <= 1'b1; ubi <= 9;  ubi_end <= 15; us_ret <= U_BH; us <= U_WAIT; end
                    3'd5: begin diag_u_byte <= "N"; diag_u_start <= 1'b1; us <= U_WAIT; us_ret <= U_CR; end
                    default: us <= U_CR;
                endcase
            end
            U_BH: begin diag_u_byte <= hexc(sbuf[ubi][7:4]); diag_u_start <= 1'b1; us_ret <= U_BL; us <= U_WAIT; end
            U_BL: begin
                diag_u_byte <= hexc(sbuf[ubi][3:0]); diag_u_start <= 1'b1;
                if (ubi == ubi_end) us_ret <= U_SP;
                else begin ubi <= ubi + 1'b1; us_ret <= U_BH; end
                us <= U_WAIT;
            end
            U_SP: begin diag_u_byte <= " "; diag_u_start <= 1'b1; us_ret <= U_TAG; us <= U_WAIT; end
            U_CR: begin diag_u_byte <= "0" + {6'd0, ui_page}; diag_u_start <= 1'b1; us_ret <= U_TP1; us <= U_WAIT; end
            U_TP1: begin diag_u_byte <= " "; diag_u_start <= 1'b1; us_ret <= U_TP2; us <= U_WAIT; end
            U_TP2: begin diag_u_byte <= "T"; diag_u_start <= 1'b1; us_ret <= U_TP3; us <= U_WAIT; end
            U_TP3: begin diag_u_byte <= (touch_chip_type == 2'd1) ? "F" : (touch_chip_type == 2'd2) ? "G" : (touch_chip_type == 2'd3) ? "g" : "-"; diag_u_start <= 1'b1; us_ret <= U_TP4; us <= U_WAIT; end
            U_TP4: begin diag_u_byte <= touch_down ? "1" : "0"; diag_u_start <= 1'b1; us_ret <= U_TP5; us <= U_WAIT; end
            U_TP5: begin diag_u_byte <= hexc({2'b00, touch_x[9:8]}); diag_u_start <= 1'b1; us_ret <= U_TP6; us <= U_WAIT; end
            U_TP6: begin diag_u_byte <= hexc(touch_x[7:4]); diag_u_start <= 1'b1; us_ret <= U_TP7; us <= U_WAIT; end
            U_TP7: begin diag_u_byte <= hexc(touch_x[3:0]); diag_u_start <= 1'b1; us_ret <= U_TP8; us <= U_WAIT; end
            U_TP8: begin diag_u_byte <= ","; diag_u_start <= 1'b1; us_ret <= U_TP9; us <= U_WAIT; end
            U_TP9: begin diag_u_byte <= hexc({3'b000, touch_y[8]}); diag_u_start <= 1'b1; us_ret <= U_TP10; us <= U_WAIT; end
            U_TP10: begin diag_u_byte <= hexc(touch_y[7:4]); diag_u_start <= 1'b1; us_ret <= U_TP11; us <= U_WAIT; end
            U_TP11: begin diag_u_byte <= hexc(touch_y[3:0]); diag_u_start <= 1'b1; us_ret <= U_NL; us <= U_WAIT; end
            U_NL: begin diag_u_byte <= 8'h0A; diag_u_start <= 1'b1; us_ret <= U_IDLE; us <= U_WAIT; end
            U_WAIT: if (!u_busy && !diag_u_start) us <= us_ret;
            default: us <= U_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------------
    // 8. WS2812 RGB Status LED
    // ------------------------------------------------------------------------
    reg [23:0] ws_color; // GRB format
    always @(*) begin
        if (!init_done)        ws_color = 24'h00_20_00; // Red: initializing
        else if (snap_active)  ws_color = 24'h20_20_40; // Purple: capturing screenshot
        else if (work_mode==2) ws_color = 24'h20_30_00; // Yellow: 32-test mode
        else if (work_mode==1) ws_color = 24'h00_00_30; // Blue: song mode
        else if (frame_cnt[3]) ws_color = 24'h30_00_00; // Green breath: free play
        else                   ws_color = 24'h10_00_00;
    end

    ws2812_drv u_ws2812 (
        .clk   (clk),
        .rst_n (rst_n),
        .color (ws_color),
        .dout  (ws_dout)
    );

    `undef LCD_C
    `undef LCD_D
    `undef LCD_R8
    `undef LCD_R16
    `undef LCD_DLY
    `undef LCD_ENDS

endmodule
`default_nettype wire
