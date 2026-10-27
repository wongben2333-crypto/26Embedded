// ============================================================================
// Module Name: lcd_test_top (Unified Audio Instrument Synthesizer + 7-in LCD UI)
// Target     : Sipeed Tang Mega 138K NEO Dock (GW5AST-LV138PG484AC1/I0 = 138C)
//
// FUSED SUBSYSTEMS:
//   1. Hank Audio Engine:
//      - PT8211 16-bit I2S DAC @ 97.656 kHz (HP_BCK, HP_WS, HP_DIN, PA_EN)
//      - 3 Work Modes:
//          Mode 0: Free Play (PC MIDI / UART RX on V14 + onboard Key demo play)
//          Mode 1: Song Player (song_player + song_rom 5 songs)
//          Mode 2: 32-Voice Benchmark (tone_bank 32 independent DDS oscillators)
//      - piano_engine (8 voices x 6 additive harmonics = 48 components)
//      - audio_fx (Bypass, Delay, Chorus, Reverb)
//      - Status LEDs (led[3:0])
//
//   2. Spark 7-inch 800x480 LCD System:
//      - ATK-MD0700 (SSD1963 16-bit 8080 bus via J14)
//      - Cold-boot self-healing watchdog (auto recovery if PLL unlocks)
//      - Real-time Audio Scope (zero-crossing triggered 600-sample live buffer)
//      - Dynamic VU peak meters & real-time note/velocity tracking
//      - 4-page instrument UI: Dashboard / Spectrum / 32-Benchmark / Song Player
//      - Hardware screenshot engine (COM8/COM9 'c' command)
// ============================================================================
`default_nettype none

module lcd_test_top #(
    parameter integer DEFAULT_MODE = 0, // 0=Free Play, 1=Song Player, 2=32-Benchmark
    parameter integer BCK_DIV      = 1, // 97656.25 Hz
    parameter integer FX_DEFAULT   = 0  // 0=Bypass default
)(
    input  wire        sys_clk,    // 50MHz (V22)
    input  wire        sys_rst_n,  // AA13

    // Board user keys
    input  wire        key,        // AB13 (Mode 0: Demo Play, Mode 1: Next Song)
    input  wire        key2,       // Y12  (Cycle Mode 0 -> 1 -> 2 -> 0)

    // Board status LEDs (T18, R18, R17, P16, Active Low)
    output wire [3:0]  led,

    // PT8211 16-bit I2S Audio DAC
    output wire        HP_BCK,     // Y17
    output wire        HP_WS,      // AB17
    output wire        HP_DIN,     // AA16
    output wire        PA_EN,      // AB16 (Active Low = 0)

    // ATK-MD0700 LCD 8080 16-bit Bus (J14)
    output reg         lcd_cs,     // AB21
    output reg         lcd_rs,     // R14
    output reg         lcd_wr,     // AB20
    output reg         lcd_rd,     // AB18
    output reg         lcd_rst,    // Y18
    inout  wire [15:0] lcd_db,
    output wire        lcd_dpi_bl, // P20 -> GND
    output wire        ws_dout,    // J16 -> WS2812 RGB LED

    // UART Communication (FT2232H Channel B - COM8/COM9, 115200 8N1)
    output wire        uart_tx,    // U15 (Diagnostics & Screenshots)
    input  wire        uart_rx     // V14 (MIDI & Control Commands)
);

    // Disable dock onboard RGB LCD boost converter
    assign lcd_dpi_bl = 1'b0;
    assign PA_EN      = 1'b0;      // Audio amp enabled

    // ------------------------------------------------------------------------
    // Power-on reset (~10ms @ 50MHz)
    // ------------------------------------------------------------------------
    reg [19:0] por_cnt = 20'd0;
    wire rst_n = por_cnt[19];
    always @(posedge sys_clk) if (!por_cnt[19]) por_cnt <= por_cnt + 1'b1;

    // ------------------------------------------------------------------------
    // Button Synchronizers & Debounce (~2.6ms window)
    // ------------------------------------------------------------------------
    localparam [19:0] DB_MAX = 20'd131071;
    reg k1_m, k1_s, k1_db, k1_db_d;
    reg k2_m, k2_s, k2_db, k2_db_d;
    reg [19:0] db1_cnt, db2_cnt;

    always @(posedge sys_clk) begin
        k1_m <= key;  k1_s <= k1_m;
        k2_m <= key2; k2_s <= k2_m;

        if (!rst_n) begin
            db1_cnt <= 20'd0; k1_db <= 1'b0; k1_db_d <= 1'b0;
            db2_cnt <= 20'd0; k2_db <= 1'b0; k2_db_d <= 1'b0;
        end else begin
            if (~k1_s != k1_db) begin
                if (db1_cnt == DB_MAX) begin db1_cnt <= 20'd0; k1_db <= ~k1_s; end
                else db1_cnt <= db1_cnt + 1'b1;
            end else db1_cnt <= 20'd0;

            if (~k2_s != k2_db) begin
                if (db2_cnt == DB_MAX) begin db2_cnt <= 20'd0; k2_db <= ~k2_s; end
                else db2_cnt <= db2_cnt + 1'b1;
            end else db2_cnt <= 20'd0;

            k1_db_d <= k1_db;
            k2_db_d <= k2_db;
        end
    end

    wire k1_press = (k1_db & ~k1_db_d);
    wire k2_press = (k2_db & ~k2_db_d);

    // ------------------------------------------------------------------------
    // Runtime Mode & Page State
    // ------------------------------------------------------------------------
    reg [1:0] work_mode = DEFAULT_MODE[1:0];
    reg [1:0] ui_page   = 2'd0;

    // ------------------------------------------------------------------------
    // PT8211 Audio DAC & Timing Tick (97.656 kHz)
    // ------------------------------------------------------------------------
    wire               sample_tick;
    wire signed [15:0] audio_mix;

    pt8211_tx #(.BCK_DIV(BCK_DIV)) u_dac (
        .clk        (sys_clk),
        .reset      (~rst_n),
        .sample_l   (audio_mix),
        .sample_r   (audio_mix),
        .sample_tick(sample_tick),
        .bck        (HP_BCK),
        .ws         (HP_WS),
        .din        (HP_DIN)
    );

    // ------------------------------------------------------------------------
    // UART Receiver (115200 8N1 @ 50MHz)
    // ------------------------------------------------------------------------
    wire [7:0] rx_dat;
    wire       rx_vld;

    uart_rx #(.CLK_HZ(50_000_000), .BAUD(115200)) u_uart_rx (
        .clk   (sys_clk),
        .rst_n (rst_n),
        .rx    (uart_rx),
        .data  (rx_dat),
        .valid (rx_vld)
    );

    // ------------------------------------------------------------------------
    // MIDI Receiver
    // ------------------------------------------------------------------------
    wire        m_on_valid, m_off_valid, m_cc_valid;
    wire [6:0]  m_on_note,  m_on_vel,  m_off_note;
    wire        m_glide_on, m_vib_on, m_sustain, m_reset_all;
    wire [6:0]  m_glide_time, m_vib_depth, m_vib_rate;
    wire [6:0]  m_cc_num, m_cc_val;
    wire        m_cc_any_valid;

    midi_rx u_midi (
        .clk          (sys_clk),
        .rst_n        (rst_n),
        .byte_data    (rx_dat),
        .byte_valid   (rx_vld),
        .on_valid     (m_on_valid),
        .on_note      (m_on_note),
        .on_vel       (m_on_vel),
        .off_valid    (m_off_valid),
        .off_note     (m_off_note),
        .cc_valid     (m_cc_valid),
        .glide_on     (m_glide_on),
        .glide_time   (m_glide_time),
        .vib_on       (m_vib_on),
        .vib_depth    (m_vib_depth),
        .vib_rate     (m_vib_rate),
        .sustain      (m_sustain),
        .reset_all    (m_reset_all),
        .cc_num       (m_cc_num),
        .cc_val       (m_cc_val),
        .cc_any_valid (m_cc_any_valid)
    );

    // CC Controls: CC20 -> Timbre, CC21 -> Distortion/Drive
    reg [1:0] inst_sel  = 2'd0; // 0=Piano, 1=Guitar, 2=Guzheng
    reg [6:0] drive_amt = 7'd0;
    always @(posedge sys_clk) begin
        if (!rst_n) begin
            inst_sel  <= 2'd0;
            drive_amt <= 7'd0;
        end else if (m_cc_any_valid) begin
            if (m_cc_num == 7'd20) inst_sel  <= m_cc_val[1:0];
            if (m_cc_num == 7'd21) drive_amt <= m_cc_val;
        end
    end

    // ------------------------------------------------------------------------
    // Song Player (Mode 1)
    // ------------------------------------------------------------------------
    wire        s_on_valid, s_off_valid;
    wire [6:0]  s_on_note,  s_on_vel,  s_off_note;
    wire        s_playing,  s_paused;
    wire [3:0]  s_song_index, s_song_count;

    wire song_en = (work_mode == 2'd1);
    wire song_next_cmd = song_en && k1_press;

    song_player #(.CLK_HZ(50_000_000)) u_song (
        .clk        (sys_clk),
        .rst_n      (rst_n),
        .sample_tick(sample_tick),
        .key_play   (1'b0),
        .key_next   (song_next_cmd),
        .key_pause  (1'b0),
        .run_en     (song_en),
        .on_valid   (s_on_valid),
        .on_note    (s_on_note),
        .on_vel     (s_on_vel),
        .off_valid  (s_off_valid),
        .off_note   (s_off_note),
        .playing    (s_playing),
        .paused     (s_paused),
        .song_index (s_song_index),
        .song_count (s_song_count)
    );

    // ------------------------------------------------------------------------
    // Demo Key Play in Free Play Mode (Key1 press produces chord / note)
    // ------------------------------------------------------------------------
    reg k1_play_on  = 1'b0;
    reg k1_play_off = 1'b0;
    always @(posedge sys_clk) begin
        k1_play_on  <= (work_mode == 2'd0) && k1_press;
        k1_play_off <= (work_mode == 2'd0) && (~k1_db & k1_db_d);
    end

    // ------------------------------------------------------------------------
    // Unified Note Bus
    // ------------------------------------------------------------------------
    wire        bus_on_valid = (work_mode == 2'd1) ? s_on_valid : (m_on_valid | k1_play_on);
    wire [6:0]  bus_on_note  = (work_mode == 2'd1) ? s_on_note  : (k1_play_on ? 7'd69 : m_on_note);
    wire [6:0]  bus_on_vel   = (work_mode == 2'd1) ? s_on_vel   : (k1_play_on ? 7'd110 : m_on_vel);
    wire        bus_off_valid= (work_mode == 2'd1) ? s_off_valid: (m_off_valid | k1_play_off);
    wire [6:0]  bus_off_note = (work_mode == 2'd1) ? s_off_note : (k1_play_off ? 7'd69 : m_off_note);

    // ------------------------------------------------------------------------
    // Piano Synthesis Engine (8 Voices x 6 Additive Harmonics)
    // ------------------------------------------------------------------------
    wire signed [15:0] mix_piano;
    wire [7:0]         piano_active;

    piano_engine #(
        .N_VOICES  (8),
        .CLK_HZ    (50_000_000),
        .OUT_SHIFT (1)
    ) u_piano (
        .clk        (sys_clk),
        .rst_n      (rst_n),
        .sample_tick(sample_tick),
        .on_valid   (bus_on_valid),
        .on_note    (bus_on_note),
        .on_vel     (bus_on_vel),
        .off_valid  (bus_off_valid),
        .off_note   (bus_off_note),
        .glide_on   ((work_mode == 2'd0) ? m_glide_on : 1'b0),
        .glide_time ((work_mode == 2'd0) ? m_glide_time : 7'd0),
        .vib_on     ((work_mode == 2'd0) ? m_vib_on : 1'b0),
        .vib_depth  ((work_mode == 2'd0) ? m_vib_depth : 7'd0),
        .vib_rate   ((work_mode == 2'd0) ? m_vib_rate : 7'd50),
        .sustain    ((work_mode == 2'd0) ? m_sustain : 1'b0),
        .inst_sel   ((work_mode == 2'd1) ? 2'd0 : inst_sel),
        .bow_speed  ((work_mode == 2'd1) ? 7'd0 : drive_amt),
        .mix_out    (mix_piano),
        .active     (piano_active)
    );

    // ------------------------------------------------------------------------
    // Tone Bank & ADSR (Mode 2: 32-Voice Benchmark)
    // ------------------------------------------------------------------------
    wire [31:0]        gate = (work_mode == 2'd2) ? 32'hFFFF_FFFF : 32'd0;
    wire [4:0]         env_voice;
    wire [16:0]        env_level;
    wire signed [15:0] mix_bank;

    tone_bank #(
        .N_VOICES     (32),
        .ROM_PARALLEL (1)
    ) u_bank (
        .clk        (sys_clk),
        .rst_n      (rst_n),
        .sample_tick(sample_tick),
        .gate_in    (gate),
        .timbre     (2'd0), // pure sine
        .pitch_semi (4'd0),
        .env_voice  (env_voice),
        .env_level  (env_level),
        .mix_out    (mix_bank)
    );

    adsr #(
        .N_VOICES (32),
        .EN_DIV   (512),
        .DIV_W    (16),
        .ATK_SH   (10),
        .DEC_SH   (10),
        .REL_SH   (13),
        .SUS_LEVEL(49152)
    ) u_adsr (
        .clk       (sys_clk),
        .rst_n     (rst_n),
        .gate      (gate),
        .voice_rd  (env_voice),
        .level_rd  (env_level),
        .phase_rd  ()
    );



    // ------------------------------------------------------------------------
    // ------------------------------------------------------------------------
    // Real-Time Note Tracking & Voice Counter
    // ------------------------------------------------------------------------
    reg [6:0] live_note = 7'd69;
    reg [6:0] live_vel  = 7'd100;
    reg [23:0] note_hold_timer = 24'd0;

    always @(posedge sys_clk) begin
        if (!rst_n) begin
            live_note <= 7'd69;
            live_vel  <= 7'd100;
            note_hold_timer <= 24'd0;
        end else if (bus_on_valid) begin
            live_note <= bus_on_note;
            live_vel  <= bus_on_vel;
            note_hold_timer <= 24'd12000000; // ~240ms display hold
        end else if (bus_off_valid && bus_off_note == live_note) begin
            note_hold_timer <= 24'd0;
        end else if (note_hold_timer != 0) begin
            note_hold_timer <= note_hold_timer - 1'b1;
        end
    end
    wire note_active = (note_hold_timer != 0);

    wire [3:0] piano_voice_count = piano_active[0] + piano_active[1] + piano_active[2] + piano_active[3] +
                                   piano_active[4] + piano_active[5] + piano_active[6] + piano_active[7];
    wire [5:0] live_active_voices = (work_mode == 2'd2) ? 6'd32 : {2'd0, piano_voice_count};

    // ------------------------------------------------------------------------
    // Hardware Audio Effects (Bypass, Delay, Chorus, Reverb) & Noise Gate
    // ------------------------------------------------------------------------
    wire [1:0] fx_sel = (work_mode == 2'd2) ? 2'd0 : FX_DEFAULT[1:0];
    wire signed [15:0] fx_out;

    wire any_note_sounding = (|piano_active) || note_active || (work_mode == 2'd1 && s_playing);
    reg [17:0] tail_timer = 18'd0;

    always @(posedge sys_clk) begin
        if (!rst_n) begin
            tail_timer <= 18'd0;
        end else if (any_note_sounding || work_mode == 2'd2) begin
            tail_timer <= 18'd150000; // ~1.5s hold after note ends
        end else if (sample_tick && tail_timer != 18'd0) begin
            tail_timer <= tail_timer - 1'b1;
        end
    end

    wire is_audio_active = (work_mode == 2'd2) ? 1'b1 : (tail_timer != 18'd0);
    wire signed [15:0] fx_in_gated = (any_note_sounding || is_audio_active) ? mix_piano : 16'sd0;

    audio_fx #(.N_FX(3)) u_fx (
        .clk        (sys_clk),
        .rst_n      (rst_n),
        .sample_tick(sample_tick),
        .fx_sel     (fx_sel),
        .param      (7'd64),
        .fx_in      (fx_in_gated),
        .fx_out     (fx_out)
    );

    // Final Audio Output Mux with Hardware Silence Gate
    wire signed [15:0] audio_synth = (work_mode == 2'd2) ? mix_bank :
                                     is_audio_active     ? fx_out   : 16'sd0;
    assign audio_mix = audio_synth;

    // ------------------------------------------------------------------------
    // Real-Time VU Peak Meter & Audio Activity Detector
    // ------------------------------------------------------------------------
    wire [15:0] audio_abs = audio_mix[15] ? (-audio_mix) : audio_mix;
    reg  [15:0] vu_peak = 16'd0;
    reg  [18:0] vu_decay = 19'd0;

    always @(posedge sys_clk) begin
        if (sample_tick) begin
            if (audio_abs > vu_peak) vu_peak <= audio_abs;
            else if (vu_decay == 19'd3000) begin
                vu_decay <= 19'd0;
                vu_peak  <= vu_peak - (vu_peak >> 5);
            end else begin
                vu_decay <= vu_decay + 1'b1;
            end
        end
    end
    wire [7:0] live_vu_level = vu_peak[15:8];
    wire audio_active = is_audio_active && ((vu_peak > 16'd200) || (work_mode == 2'd2));

    // ------------------------------------------------------------------------
    // Real-Time Dual-Bank Scope Buffer with Zero-Crossing Lock
    // ------------------------------------------------------------------------
    reg signed [15:0] scope_bank_0 [0:799];
    reg signed [15:0] scope_bank_1 [0:799];
    reg wr_bank = 1'b0;
    reg rd_bank = 1'b1;
    reg [9:0]  scope_wr_idx = 10'd0;
    reg [2:0]  scope_div    = 3'd0;
    reg        scope_capturing = 1'b0;
    reg        capture_done    = 1'b0;
    reg signed [15:0] prev_sample = 16'd0;
    wire zero_cross = (prev_sample < -16'd200 && audio_mix >= 16'd0);

    reg [9:0] px;
    reg [8:0] py;

    always @(posedge sys_clk) begin
        if (sample_tick) begin
            prev_sample <= audio_mix;
            scope_div   <= scope_div + 1'b1;

            if (scope_div == 3'd0) begin // 97.656 kHz / 8 = ~12.2 kHz
                if (!scope_capturing && audio_active && zero_cross) begin
                    scope_wr_idx    <= 10'd0;
                    scope_capturing <= 1'b1;
                    capture_done    <= 1'b0;
                end else if (scope_capturing) begin
                    if (wr_bank == 1'b0) scope_bank_0[scope_wr_idx] <= audio_mix;
                    else                 scope_bank_1[scope_wr_idx] <= audio_mix;

                    if (scope_wr_idx == 10'd799) begin
                        scope_capturing <= 1'b0;
                        capture_done    <= 1'b1;
                    end else begin
                        scope_wr_idx <= scope_wr_idx + 1'b1;
                    end
                end
            end
        end

        // Frame-locked swap at start of display frame
        if (px == 10'd0 && py == 9'd0) begin
            if (capture_done) begin
                rd_bank <= wr_bank;
                wr_bank <= ~wr_bank;
                capture_done <= 1'b0;
            end
        end
    end



    // ------------------------------------------------------------------------
    // LCD Scope Waveform Reader (Column px -> scope_wave_y & scope_prev_y)
    // ------------------------------------------------------------------------
    wire [9:0] scope_addr = (ui_page == 2'd0) ?
        ((px >= 10'd20 && px <= 10'd440) ? ((px - 10'd20) << 1) : 10'd0) :
        ((px >= 10'd20 && px <= 10'd778) ? (px - 10'd20) : 10'd0);

    wire signed [15:0] live_scope_sample = audio_active ? ((rd_bank == 1'b0) ? scope_bank_0[scope_addr] : scope_bank_1[scope_addr]) : 16'sd0;
    reg  signed [15:0] sample_curr_r = 16'd0;
    reg  signed [15:0] sample_prev_r = 16'd0;
    reg  [9:0]        px_scope_prev = 10'd0;

    always @(posedge sys_clk) begin
        if (!rst_n) begin
            px_scope_prev <= 10'd0;
            sample_curr_r <= 16'd0;
            sample_prev_r <= 16'd0;
        end else begin
            if (px != px_scope_prev) begin
                px_scope_prev <= px;
                if (px <= 10'd20)
                    sample_prev_r <= live_scope_sample;
                else
                    sample_prev_r <= sample_curr_r;
            end
            sample_curr_r <= live_scope_sample;
        end
    end

    wire signed [9:0] wave_offset_p0 = $signed(sample_curr_r >>> 8);
    wire signed [9:0] wave_offset_p1 = $signed(sample_curr_r >>> 9);
    wire [8:0] live_scope_wave_y = (ui_page == 2'd0) ?
        (10'sd300 - wave_offset_p0) :
        (10'sd154 - wave_offset_p1);

    wire signed [9:0] prev_offset_p0 = $signed(sample_prev_r >>> 8);
    wire signed [9:0] prev_offset_p1 = $signed(sample_prev_r >>> 9);
    wire [8:0] live_scope_prev_y = (ui_page == 2'd0) ?
        (10'sd300 - prev_offset_p0) :
        (10'sd154 - prev_offset_p1);

    // ------------------------------------------------------------------------
    // LCD UI Module (Pure RTL Single-Cycle Multi-Page Engine)
    // ------------------------------------------------------------------------
    wire [15:0] ui_color;
    reg  [7:0]  frame_cnt = 8'd0;

    lcd_ui u_lcd_ui (
        .clk           (sys_clk),
        .rst_n         (rst_n),
        .px            (px),
        .py            (py),
        .page          (ui_page),
        .frame_cnt     (frame_cnt),
        .audio_active  (audio_active),
        .scope_wave_y  (live_scope_wave_y),
        .scope_prev_y  (live_scope_prev_y),
        .vu_level      (live_vu_level),
        .work_mode     (work_mode),
        .timbre_sel    (inst_sel),
        .fx_sel        (fx_sel),
        .active_voices (live_active_voices),
        .live_note     (live_note),
        .live_vel      (live_vel),
        .note_active   (note_active),
        .song_index    (s_song_index[2:0]),
        .song_playing  (s_playing),
        .song_progress (frame_cnt),
        .color         (ui_color)
    );

    // ------------------------------------------------------------------------
    // Interactive Command Decoder (UART & Keys)
    // ------------------------------------------------------------------------
    reg        reinit_req = 1'b0;
    reg        reinit_clear_req;
    reg        snap_req = 1'b0;
    reg        snap_clear_req;
    reg        snap_rle = 1'b0;
    reg [1:0]  snap_wait_frm = 2'd0;
    reg        frame_end_pulse = 1'b0;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            work_mode <= DEFAULT_MODE[1:0];
            ui_page   <= 2'd0;
            reinit_req<= 1'b0;
            snap_req  <= 1'b0;
            snap_rle  <= 1'b0;
            snap_wait_frm <= 2'd0;
        end else begin
            if (reinit_clear_req) reinit_req <= 1'b0;
            if (snap_clear_req)   snap_req   <= 1'b0;

            // Key2 switches mode
            if (k2_press) begin
                work_mode <= (work_mode == 2'd2) ? 2'd0 : (work_mode + 1'b1);
                // Also jump page to match mode
                if (work_mode == 2'd0) ui_page <= 2'd3;      // Go to song page
                else if (work_mode == 2'd1) ui_page <= 2'd2; // Go to test page
                else ui_page <= 2'd0;                        // Go to dashboard
            end

            // UART Commands
            if (rx_vld) begin
                case (rx_dat)
                    "0": begin work_mode <= 2'd0; ui_page <= 2'd0; end
                    "1": begin work_mode <= 2'd1; ui_page <= 2'd3; end
                    "2": begin work_mode <= 2'd2; ui_page <= 2'd2; end
                    "m", "M": begin ui_page <= 2'd0; end
                    "v", "V": begin ui_page <= 2'd1; end
                    "t", "T": begin ui_page <= 2'd2; end
                    "g", "G": begin ui_page <= 2'd3; end
                    "n", "N": begin ui_page <= ui_page + 1'b1; end
                    "b", "B": begin ui_page <= ui_page - 1'b1; end
                    "r", "R", "i", "I": begin reinit_req <= 1'b1; end
                    "q", "Q": begin snap_req <= 1'b1; snap_rle <= 1'b0; end
                    "c", "C": begin snap_req <= 1'b1; snap_rle <= 1'b1; end
                    default: ;
                endcase
            end else if (frame_end_pulse && snap_wait_frm != 2'd0) begin
                snap_wait_frm <= snap_wait_frm - 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------------
    // SSD1963 8080 Driver with Watchdog Auto-Recovery
    // ------------------------------------------------------------------------
    reg  [15:0] db_out;
    reg         db_oe;
    assign lcd_db = db_oe ? db_out : 16'hzzzz;

    reg [15:0] db_in_s1, db_in_s2;
    always @(posedge sys_clk) begin
        db_in_s1 <= lcd_db;
        db_in_s2 <= db_in_s1;
    end

    localparam K_WR = 2'b00, K_RD = 2'b01, K_DLY = 2'b10, K_END = 2'b11;
    `define C(x)   {K_WR , 1'b0, 1'b0, 4'd0, 24'h0 | (x)}
    `define D(x)   {K_WR , 1'b1, 1'b0, 4'd0, 24'h0 | (x)}
    `define R8     {K_RD , 1'b1, 1'b0, 4'd0, 24'h0}
    `define R16    {K_RD , 1'b1, 1'b1, 4'd0, 24'h0}
    `define DLY(x) {K_DLY, 1'b0, 1'b0, 4'd0, 24'h0 | (x)}
    `define ENDS   {K_END, 1'b0, 1'b0, 4'd0, 24'h0}

    localparam [7:0] SEG_INIT      = 8'd0;
    localparam [7:0] SEG_FRAME     = 8'd68;
    localparam [7:0] SEG_DIAG      = 8'd100;
    localparam [7:0] SEG_SNAP_PREP = 8'd160;

    reg  [7:0]  pc;
    reg  [31:0] rom_q;
    always @(*) begin
        case (pc)
        // ---------------- INIT (ALIENTEK atk_md0700_reg_init + 33.3MHz PCLK)
        8'd0 : rom_q = `C(8'hE2);
        8'd1 : rom_q = `D(8'h1D);       // M = 29
        8'd2 : rom_q = `D(8'h02);       // N = 2  -> PLL = 10MHz*30/3 = 100MHz
        8'd3 : rom_q = `D(8'h04);
        8'd4 : rom_q = `DLY(24'd50000); // 1ms
        8'd5 : rom_q = `C(8'hE0);
        8'd6 : rom_q = `D(8'h01);       // PLL enable
        8'd7 : rom_q = `DLY(24'd5000000);// 100ms (Datasheet: wait 100ms for PLL to lock)
        8'd8 : rom_q = `C(8'hE0);
        8'd9 : rom_q = `D(8'h03);       // PLL lock (switch sys clock to PLL)
        8'd10: rom_q = `DLY(24'd2500000);// 50ms (wait for clock switch)
        8'd11: rom_q = `C(8'h01);       // soft reset
        8'd12: rom_q = `DLY(24'd2500000);// 50ms (wait after soft reset)
        8'd13: rom_q = `C(8'hE6);
        8'd14: rom_q = `D(8'h05);
        8'd15: rom_q = `D(8'h53);
        8'd16: rom_q = `D(8'hF6);       // 33.3MHz PCLK
        8'd17: rom_q = `C(8'hB0);
        8'd18: rom_q = `D(8'h20);
        8'd19: rom_q = `D(8'h00);
        8'd20: rom_q = `D(8'h03);
        8'd21: rom_q = `D(8'h1F);       // HDP = 799
        8'd22: rom_q = `D(8'h01);
        8'd23: rom_q = `D(8'hDF);       // VDP = 479
        8'd24: rom_q = `D(8'h00);
        8'd25: rom_q = `C(8'hB4);
        8'd26: rom_q = `D(8'h04);
        8'd27: rom_q = `D(8'h1F);       // HT = 1055
        8'd28: rom_q = `D(8'h00);
        8'd29: rom_q = `D(8'h2E);       // HPS = 46
        8'd30: rom_q = `D(8'h00);
        8'd31: rom_q = `D(8'h00);
        8'd32: rom_q = `D(8'h00);
        8'd33: rom_q = `D(8'h00);
        8'd34: rom_q = `C(8'hB6);
        8'd35: rom_q = `D(8'h02);
        8'd36: rom_q = `D(8'h0C);       // VT = 524
        8'd37: rom_q = `D(8'h00);
        8'd38: rom_q = `D(8'h17);       // VPS = 23
        8'd39: rom_q = `D(8'h16);
        8'd40: rom_q = `D(8'h00);
        8'd41: rom_q = `D(8'h00);
        8'd42: rom_q = `C(8'hF0);
        8'd43: rom_q = `D(8'h03);       // 16-bit 565
        8'd44: rom_q = `C(8'h29);       // display on
        8'd45: rom_q = `C(8'hD0);
        8'd46: rom_q = `D(8'h00);       // DBC off
        8'd47: rom_q = `C(8'hBE);       // PWM config (100% full brightness)
        8'd48: rom_q = `D(8'h05);
        8'd49: rom_q = `D(8'hFE);
        8'd50: rom_q = `D(8'h01);
        8'd51: rom_q = `D(8'h00);
        8'd52: rom_q = `D(8'h00);
        8'd53: rom_q = `D(8'h00);
        8'd54: rom_q = `C(8'hB8);
        8'd55: rom_q = `D(8'h03);
        8'd56: rom_q = `D(8'h01);
        8'd57: rom_q = `C(8'hBA);
        8'd58: rom_q = `D(8'h01);
        8'd59: rom_q = `C(8'h36);
        8'd60: rom_q = `D(8'h00);
        8'd61: rom_q = `DLY(24'd500000);
        8'd62: rom_q = `ENDS;

        // ---------------- FRAME header (refresh 2A/2B/2C)
        8'd68: rom_q = `C(8'hF0);
        8'd69: rom_q = `D(8'h03);       // 16-bit 565
        8'd70: rom_q = `C(8'h29);       // display on
        8'd71: rom_q = `C(8'hD0);
        8'd72: rom_q = `D(8'h00);
        8'd73: rom_q = `C(8'hBE);       // PWM 100%
        8'd74: rom_q = `D(8'h05);
        8'd75: rom_q = `D(8'hFE);
        8'd76: rom_q = `D(8'h01);
        8'd77: rom_q = `D(8'h00);
        8'd78: rom_q = `D(8'h00);
        8'd79: rom_q = `D(8'h00);
        8'd80: rom_q = `C(8'hB8);
        8'd81: rom_q = `D(8'h03);
        8'd82: rom_q = `D(8'h01);
        8'd83: rom_q = `C(8'hBA);
        8'd84: rom_q = `D(8'h01);
        8'd85: rom_q = `C(8'h36);
        8'd86: rom_q = `D(8'h00);
        8'd87: rom_q = `C(8'h2A);
        8'd88: rom_q = `D(8'h00);
        8'd89: rom_q = `D(8'h00);
        8'd90: rom_q = `D(8'h03);
        8'd91: rom_q = `D(8'h1F);       // col 0..799
        8'd92: rom_q = `C(8'h2B);
        8'd93: rom_q = `D(8'h00);
        8'd94: rom_q = `D(8'h00);
        8'd95: rom_q = `D(8'h01);
        8'd96: rom_q = `D(8'hDF);       // page 0..479
        8'd97: rom_q = `C(8'h2C);       // write_memory_start
        8'd98: rom_q = `ENDS;

        // ---------------- DIAG readback (32 bytes)
        8'd100: rom_q = `C(8'hA1);
        8'd101: rom_q = `DLY(24'd2500);
        8'd102: rom_q = `R8; 8'd103: rom_q = `R8; 8'd104: rom_q = `R8; 8'd105: rom_q = `R8; 8'd106: rom_q = `R8;
        8'd107: rom_q = `C(8'h0A); 8'd108: rom_q = `DLY(24'd2500); 8'd109: rom_q = `R8;
        8'd110: rom_q = `C(8'hE4); 8'd111: rom_q = `DLY(24'd2500); 8'd112: rom_q = `R8;
        8'd113: rom_q = `C(8'hF1); 8'd114: rom_q = `DLY(24'd2500); 8'd115: rom_q = `R8;
        8'd116: rom_q = `C(8'h0B); 8'd117: rom_q = `DLY(24'd2500); 8'd118: rom_q = `R8;
        8'd119: rom_q = `C(8'hB1); 8'd120: rom_q = `DLY(24'd2500);
        8'd121: rom_q = `R8; 8'd122: rom_q = `R8; 8'd123: rom_q = `R8; 8'd124: rom_q = `R8; 8'd125: rom_q = `R8; 8'd126: rom_q = `R8; 8'd127: rom_q = `R8;
        8'd128: rom_q = `C(8'hE7); 8'd129: rom_q = `DLY(24'd2500);
        8'd130: rom_q = `R8; 8'd131: rom_q = `R8; 8'd132: rom_q = `R8;
        8'd133: rom_q = `C(8'hBF); 8'd134: rom_q = `DLY(24'd2500);
        8'd135: rom_q = `R8; 8'd136: rom_q = `R8; 8'd137: rom_q = `R8; 8'd138: rom_q = `R8; 8'd139: rom_q = `R8; 8'd140: rom_q = `R8; 8'd141: rom_q = `R8;
        8'd142: rom_q = `C(8'h2A); 8'd143: rom_q = `D(8'h00); 8'd144: rom_q = `D(8'h00); 8'd145: rom_q = `D(8'h03); 8'd146: rom_q = `D(8'h1F);
        8'd147: rom_q = `C(8'h2B); 8'd148: rom_q = `D(8'h00); 8'd149: rom_q = `D(8'h00); 8'd150: rom_q = `D(8'h01); 8'd151: rom_q = `D(8'hDF);
        8'd152: rom_q = `C(8'h2E); 8'd153: rom_q = `DLY(24'd2500);
        8'd154: rom_q = `R16; 8'd155: rom_q = `R16; 8'd156: rom_q = `R16;
        8'd157: rom_q = `C(8'h00);
        8'd158: rom_q = `ENDS;

        // ---------------- SCREENSHOT prep
        8'd160: rom_q = `C(8'h2A); 8'd161: rom_q = `D(8'h00); 8'd162: rom_q = `D(8'h00); 8'd163: rom_q = `D(8'h03); 8'd164: rom_q = `D(8'h1F);
        8'd165: rom_q = `C(8'h2B); 8'd166: rom_q = `D(8'h00); 8'd167: rom_q = `D(8'h00); 8'd168: rom_q = `D(8'h01); 8'd169: rom_q = `D(8'hDF);
        8'd170: rom_q = `C(8'h2E);
        8'd171: rom_q = `ENDS;

        default: rom_q = `ENDS;
        endcase
    end

    wire [1:0]  op_kind = rom_q[31:30];
    wire        op_rs   = rom_q[29];
    wire        op_w16  = rom_q[28];
    wire [23:0] op_data = rom_q[23:0];

    // Diag buffer (32 bytes)
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
        M_SNAP_TAIL  = 4'd11;

    reg [3:0]  ms, tx_ret_ms;
    reg [1:0]  seg;
    reg [6:0]  ph;
    reg [23:0] dly;
    reg        init_done;
    reg        print_req;
    reg [11:0] sframe;
    reg        snap_active = 1'b0;

    // Screenshot state
    reg [15:0] cur_pix, rle_pix;
    reg [7:0]  rle_cnt;
    reg        last_pix_flag;
    reg [7:0]  tx_buf [0:7];
    reg [3:0]  tx_idx, tx_len;
    reg        snap_u_start;
    reg [7:0]  snap_u_byte;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            ms <= M_RST_LO; tx_ret_ms <= M_RST_LO; seg <= 0; pc <= SEG_INIT; ph <= 0; dly <= 24'd2500000;
            lcd_cs <= 1'b1; lcd_rs <= 1'b1; lcd_wr <= 1'b1; lcd_rd <= 1'b1; lcd_rst <= 1'b0;
            db_out <= 16'h0000; db_oe <= 1'b1;
            px <= 0; py <= 0; frame_cnt <= 0; init_done <= 1'b0; dptr <= 0;
            print_req <= 1'b0; sframe <= 0;
            snap_active <= 1'b0; snap_u_start <= 1'b0; snap_u_byte <= 8'h00;
            snap_clear_req <= 1'b0; reinit_clear_req <= 1'b0; frame_end_pulse <= 1'b0;
            tx_idx <= 0; tx_len <= 0; cur_pix <= 0; rle_pix <= 0; rle_cnt <= 0; last_pix_flag <= 1'b0;
        end else begin
            print_req        <= 1'b0;
            snap_u_start     <= 1'b0;
            snap_clear_req   <= 1'b0;
            reinit_clear_req <= 1'b0;
            frame_end_pulse  <= 1'b0;

            case (ms)
            M_RST_LO: begin
                lcd_rst <= 1'b0; lcd_cs <= 1'b1; lcd_rs <= 1'b1; lcd_wr <= 1'b1; lcd_rd <= 1'b1;
                db_out  <= 16'hFFFF; db_oe <= 1'b1;
                if (dly == 0) begin lcd_rst <= 1'b1; dly <= 24'd15000000; ms <= M_RST_HI; end
                else dly <= dly - 1'b1;
            end
            M_RST_HI: begin
                lcd_cs <= 1'b1; lcd_rs <= 1'b1; lcd_wr <= 1'b1; lcd_rd <= 1'b1;
                db_out <= 16'hFFFF; db_oe <= 1'b1;
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
                        init_done <= 1'b1;
                        seg <= 2'd1; pc <= SEG_FRAME;
                    end else if (seg == 2'd1) begin
                        px <= 0; py <= 0; ms <= M_PIX;
                        db_out <= ui_color; db_oe <= 1'b1; lcd_rs <= 1'b1;
                    end else if (seg == 2'd2) begin
                        ms <= M_PRINT;
                    end else begin
                        px <= 0; py <= 0; rle_cnt <= 8'd0; last_pix_flag <= 1'b0;
                        ms <= M_SNAP_HDR;
                    end
                end
                endcase
            end

            M_DLY: begin
                lcd_cs <= 1'b1; lcd_wr <= 1'b1; lcd_rd <= 1'b1;
                db_out <= 16'hFFFF; db_oe <= 1'b1;
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
                    7'd0 : begin lcd_cs <= 1'b0; lcd_wr <= 1'b1; lcd_rd <= 1'b1; db_out <= ui_color; end
                    7'd4 : lcd_wr <= 1'b0;
                    7'd12: lcd_wr <= 1'b1;
                    7'd19: begin
                        ph <= 7'd0;
                        if (px == 10'd799) begin
                            px <= 0;
                            if (py == 9'd479) begin
                                lcd_cs <= 1'b1; db_out <= 16'hFFFF; py <= 0;
                                frame_end_pulse <= 1'b1;
                                if (snap_req && snap_wait_frm == 2'd0) begin
                                    snap_clear_req <= 1'b1; snap_active <= 1'b1;
                                    seg <= 2'd3; pc <= SEG_SNAP_PREP; ms <= M_SEQ;
                                end else begin
                                    seg <= 2'd2; pc <= SEG_DIAG; dptr <= 0; ms <= M_SEQ;
                                end
                            end else py <= py + 1'b1;
                        end else px <= px + 1'b1;
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
                    7'd52 : begin ph <= 7'd0; pc <= pc + 1'b1; db_oe <= 1'b1; db_out <= 16'hFFFF; ms <= M_SEQ; end
                    default: ;
                endcase
            end

            M_PRINT: begin
                lcd_cs <= 1'b1; db_oe <= 1'b1; db_out <= 16'hFFFF;
                if (!print_busy && us == U_IDLE) begin
                    sframe    <= frame_cnt;
                    print_req <= 1'b1;
                    ms        <= M_PRINT_WAIT;
                end
            end

            M_PRINT_WAIT: begin
                frame_cnt <= frame_cnt + 1'b1;
                // Auto Watchdog: If SSD1963 chip ID (0x5761) is valid but PLL is not locked,
                // trigger a full hardware reset & reinitialization sequence.
                if (reinit_req || (init_done && (dbuf[1] == 8'h57 && dbuf[2] == 8'h61 && dbuf[6] != 8'h04))) begin
                    reinit_clear_req <= 1'b1;
                    init_done        <= 1'b0;
                    dly              <= 24'd2500000; // 50ms RST low
                    ms               <= M_RST_LO;
                end else begin
                    seg              <= 2'd1;
                    pc               <= SEG_FRAME;
                    ms               <= M_SEQ;
                end
            end

            // Hardware Screenshot Engine
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
                    7'd10: lcd_rd <= 1'b0;
                    7'd20: begin cur_pix <= db_in_s2; lcd_rd <= 1'b1; end
                    7'd30: begin
                        lcd_cs <= 1'b1;
                        if (snap_rle) begin
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
                    7'd31: begin
                        if (tx_len > 0) begin tx_ret_ms <= M_SNAP_BURST; ms <= M_SNAP_TAIL; end
                        else begin
                            ph <= 7'd0;
                            if (px == 10'd799) begin
                                px <= 0;
                                if (py == 9'd479) begin
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
    // UART Transmitter (Diagnostic Telemetry + Screenshot Transfer)
    // ------------------------------------------------------------------------
    reg  [8:0]  u_div;
    reg  [3:0]  u_bit;
    reg  [9:0]  u_sh;
    reg         u_busy;
    wire        u_tick = (u_div == 9'd433);

    always @(posedge sys_clk or negedge rst_n) begin
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
    assign uart_tx = u_sh[0];

    // Diagnostic Line Formatter: "Fxx S:... P:... L:... C:... W:... N:x\n"
    localparam [4:0]
        U_IDLE = 5'd0, U_HDR = 5'd1, U_TAG = 5'd2, U_BH = 5'd3, U_BL = 5'd4,
        U_SP = 5'd5, U_NL = 5'd6, U_CR = 5'd7, U_WAIT = 5'd8;

    reg [4:0] us, us_ret;
    reg [4:0] ubi, ubi_end;
    reg [2:0] utag;
    reg       diag_u_start;
    reg [7:0] diag_u_byte;
    wire      print_busy = (us != U_IDLE);

    function [7:0] hexc;
        input [3:0] n;
        hexc = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h41 + {4'd0, n - 4'd10});
    endfunction

    reg [7:0] sbuf [0:31];
    reg [2:0] sp_hdr;
    integer k;

    always @(posedge sys_clk or negedge rst_n) begin
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
            U_CR: begin diag_u_byte <= "0" + {6'd0, ui_page}; diag_u_start <= 1'b1; us_ret <= U_NL; us <= U_WAIT; end
            U_NL: begin diag_u_byte <= 8'h0A; diag_u_start <= 1'b1; us_ret <= U_IDLE; us <= U_WAIT; end
            U_WAIT: if (!u_busy && !diag_u_start) us <= us_ret;
            default: us <= U_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------------
    // Board Status LEDs & WS2812 RGB
    // ------------------------------------------------------------------------
    reg [25:0] heart = 26'd0;
    always @(posedge sys_clk) heart <= heart + 1'b1;

    assign led[0] = heart[24];                       // Heartbeat blink
    assign led[1] = ~init_done;                      // LCD Init OK (low active)
    assign led[2] = ~(|piano_active | (|gate));      // Sound synthesis active
    assign led[3] = (work_mode == 2'd1) ? ~s_playing : ~note_active;

    reg [23:0] ws_color; // GRB format
    always @(*) begin
        if (!init_done)        ws_color = 24'h00_20_00;  // Red: initializing
        else if (snap_active)  ws_color = 24'h20_20_40;  // Purple: capturing screenshot
        else if (work_mode==2) ws_color = 24'h20_30_00;  // Yellow: 32-test mode
        else if (work_mode==1) ws_color = 24'h00_00_30;  // Blue: song mode
        else if (frame_cnt[3]) ws_color = 24'h30_00_00;  // Green breath: free play
        else                   ws_color = 24'h10_00_00;
    end

    ws2812_drv u_ws2812 (
        .clk   (sys_clk),
        .rst_n (rst_n),
        .color (ws_color),
        .dout  (ws_dout)
    );

endmodule
`default_nettype wire
