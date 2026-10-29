// =============================================================================
//  lcd_ui.v —— 800x480 ATK-MD0700 电子乐器多页面仪器界面 (Pure RTL)
//  Refined v2: Compact Right Piano, Large Left Scope, Rule 3 Fixed Headroom & Freq
// =============================================================================
`default_nettype none

module lcd_ui (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [9:0]  px,
    input  wire [8:0]  py,
    input  wire [1:0]  page,
    input  wire [7:0]  frame_cnt,

    // 实时音频示波器与电平输入
    input  wire        audio_active,   // 1 当有真实音频输出，0 当静音/无音频
    input  wire [8:0]  scope_wave_y,   // 示波器当前列真实音频 Y 坐标
    input  wire [8:0]  scope_prev_y,   // 示波器前一列真实音频 Y 坐标（用于线段补全）
    input  wire [7:0]  vu_level,       // 动态立体声峰值电平 0..255

    // 乐器与演奏状态输入
    input  wire [1:0]  work_mode,      // 0: Free Play, 1: Song Play, 2: 32-Test
    input  wire [1:0]  timbre_sel,     // 0: Piano 6H, 1: Guitar, 2: Guzheng, 3: Sine
    input  wire [1:0]  fx_sel,         // 0: Bypass, 1: Delay, 2: Chorus, 3: Reverb
    input  wire [5:0]  active_voices,  // 0..32
    input  wire [6:0]  live_note,      // 0..127
    input  wire [6:0]  live_vel,       // 0..127
    input  wire        note_active,    // 1 if note is active
    input  wire [2:0]  song_index,     // 0..4
    input  wire        song_playing,
    input  wire [7:0]  song_progress,  // 0..100%
    input  wire [6:0]  master_vol,     // 0..127 硬件主音量 (MIDI CC 7)
    input  wire [11:0] key_active_mask,// 12路琴键发声状态 (bit 0=C4..bit 11=B4)
    input  wire [7:0]  song_elapsed_sec, // 0..59
    input  wire [7:0]  song_elapsed_min, // 0..59
    input  wire [7:0]  song_total_sec,   // total seconds of song
    input  wire [8:0]  song_note_idx,    // current note index
    input  wire [5:0]  song_sub_scroll,  // 0..59 pixels
    input  wire [6:0]  song_active_note, // active MIDI note

    // 像素颜色输出 (RGB565)
    output reg  [15:0] color
);

    // -------------------------------------------------------------------------
    // 调色板 (Deep Blue Professional Commercial Instrument Theme)
    // -------------------------------------------------------------------------
    localparam [15:0] C_BG         = 16'h08A7; // Deep Midnight Navy Blue #081439
    localparam [15:0] C_NAV        = 16'h08A6; // Top Navigation Header #081430
    localparam [15:0] C_PANEL      = 16'h110C; // Deep Sapphire Slate Panel #102062
    localparam [15:0] C_BORDER     = 16'h1A7A; // Crisp Slate Blue Border #2038A4
    localparam [15:0] C_TEXT_PRI   = 16'hFFFF; // Pure White #FFFFFF
    localparam [15:0] C_TEXT_SEC   = 16'h7D99; // Crisp Ice Blue Text #7BB2CD
    localparam [15:0] C_CYAN       = 16'h07FF; // Electric Cyan #00FFFF
    localparam [15:0] C_GREEN      = 16'h07E0; // Emerald Green #00FF00
    localparam [15:0] C_AMBER      = 16'hFFE0; // Warm Amber Yellow #FFFF00
    localparam [15:0] C_RED        = 16'hF800; // Vivid Red #FF0000
    localparam [15:0] C_SCOPE_BG   = 16'h0023; // Dark Scope Background (Deep Obsidian Blue)
    localparam [15:0] C_GRID       = 16'h0927; // Scope Reticle Grid #082439
    localparam [15:0] C_ZERO_LINE  = 16'h11AE; // Scope Zero Center Line #103473
    localparam [15:0] C_KEY_WHITE  = 16'hFFFF; // Pure White Piano Key #FFFFFF
    localparam [15:0] C_KEY_BORDER = 16'h1A7A; // Key Border #2038A4
    localparam [15:0] C_KEY_BLACK  = 16'h0824; // Deep Charcoal Black Key #080820

    // Include song note table
    `include "gen_song_notes.vh"

    // Map MIDI note to treble/bass stave Y coordinate
    function [8:0] note_to_y;
        input [6:0] n;
        begin
            case (n)
                7'd77: note_to_y = 9'd280; // F5 (top stave line)
                7'd76: note_to_y = 9'd292; // E5
                7'd75, 7'd74: note_to_y = 9'd305; // D#5, D5 (4th line)
                7'd73, 7'd72: note_to_y = 9'd317; // C#5, C5
                7'd71: note_to_y = 9'd330; // B4 (3rd line)
                7'd70, 7'd69: note_to_y = 9'd342; // A#4, A4
                7'd68, 7'd67: note_to_y = 9'd355; // G#4, G4 (2nd line)
                7'd66, 7'd65: note_to_y = 9'd367; // F#4, F4
                7'd64: note_to_y = 9'd380; // E4 (bottom line)
                7'd63, 7'd62: note_to_y = 9'd392; // D#4, D4
                7'd61, 7'd60: note_to_y = 9'd405; // C#4, C4 (ledger line)
                7'd59: note_to_y = 9'd410; // B3
                7'd58, 7'd57: note_to_y = 9'd418; // A#3, A3
                7'd56, 7'd55: note_to_y = 9'd426; // G#3, G3
                7'd54, 7'd53: note_to_y = 9'd434; // F#3, F3
                7'd52, 7'd51: note_to_y = 9'd442; // E3, D#3
                7'd50, 7'd49: note_to_y = 9'd450; // D3, C#3
                7'd48:        note_to_y = 9'd458; // C3
                default: note_to_y = 9'd0; // Rest / unmapped
            endcase
        end
    endfunction

    // -------------------------------------------------------------------------
    // 字体 ROM 与字符渲染函数
    // -------------------------------------------------------------------------
    function font_dot;
        input [7:0] ascii;
        input [2:0] col;
        input [2:0] row;
        reg [4:0] row_bits;
        begin
            case (ascii)
                8'd32: case (row)
                    3'd0: row_bits = 5'b00000;
                    3'd1: row_bits = 5'b00000;
                    3'd2: row_bits = 5'b00000;
                    3'd3: row_bits = 5'b00000;
                    3'd4: row_bits = 5'b00000;
                    3'd5: row_bits = 5'b00000;
                    3'd6: row_bits = 5'b00000;
                    default: row_bits = 5'b00000;
                endcase
                8'd65: case (row)
                    3'd0: row_bits = 5'b01110;
                    3'd1: row_bits = 5'b10001;
                    3'd2: row_bits = 5'b10001;
                    3'd3: row_bits = 5'b11111;
                    3'd4: row_bits = 5'b10001;
                    3'd5: row_bits = 5'b10001;
                    3'd6: row_bits = 5'b10001;
                    default: row_bits = 5'b00000;
                endcase
                8'd66: case (row)
                    3'd0: row_bits = 5'b11110;
                    3'd1: row_bits = 5'b10001;
                    3'd2: row_bits = 5'b10001;
                    3'd3: row_bits = 5'b11110;
                    3'd4: row_bits = 5'b10001;
                    3'd5: row_bits = 5'b10001;
                    3'd6: row_bits = 5'b11110;
                    default: row_bits = 5'b00000;
                endcase
                8'd67: case (row)
                    3'd0: row_bits = 5'b01111;
                    3'd1: row_bits = 5'b10000;
                    3'd2: row_bits = 5'b10000;
                    3'd3: row_bits = 5'b10000;
                    3'd4: row_bits = 5'b10000;
                    3'd5: row_bits = 5'b10000;
                    3'd6: row_bits = 5'b01111;
                    default: row_bits = 5'b00000;
                endcase
                8'd68: case (row)
                    3'd0: row_bits = 5'b11110;
                    3'd1: row_bits = 5'b10001;
                    3'd2: row_bits = 5'b10001;
                    3'd3: row_bits = 5'b10001;
                    3'd4: row_bits = 5'b10001;
                    3'd5: row_bits = 5'b10001;
                    3'd6: row_bits = 5'b11110;
                    default: row_bits = 5'b00000;
                endcase
                8'd69: case (row)
                    3'd0: row_bits = 5'b11111;
                    3'd1: row_bits = 5'b10000;
                    3'd2: row_bits = 5'b10000;
                    3'd3: row_bits = 5'b11110;
                    3'd4: row_bits = 5'b10000;
                    3'd5: row_bits = 5'b10000;
                    3'd6: row_bits = 5'b11111;
                    default: row_bits = 5'b00000;
                endcase
                8'd70: case (row)
                    3'd0: row_bits = 5'b11111;
                    3'd1: row_bits = 5'b10000;
                    3'd2: row_bits = 5'b10000;
                    3'd3: row_bits = 5'b11110;
                    3'd4: row_bits = 5'b10000;
                    3'd5: row_bits = 5'b10000;
                    3'd6: row_bits = 5'b10000;
                    default: row_bits = 5'b00000;
                endcase
                8'd71: case (row)
                    3'd0: row_bits = 5'b01111;
                    3'd1: row_bits = 5'b10000;
                    3'd2: row_bits = 5'b10000;
                    3'd3: row_bits = 5'b10111;
                    3'd4: row_bits = 5'b10001;
                    3'd5: row_bits = 5'b10001;
                    3'd6: row_bits = 5'b01110;
                    default: row_bits = 5'b00000;
                endcase
                8'd72: case (row)
                    3'd0: row_bits = 5'b10001;
                    3'd1: row_bits = 5'b10001;
                    3'd2: row_bits = 5'b10001;
                    3'd3: row_bits = 5'b11111;
                    3'd4: row_bits = 5'b10001;
                    3'd5: row_bits = 5'b10001;
                    3'd6: row_bits = 5'b10001;
                    default: row_bits = 5'b00000;
                endcase
                8'd73: case (row)
                    3'd0: row_bits = 5'b11111;
                    3'd1: row_bits = 5'b00100;
                    3'd2: row_bits = 5'b00100;
                    3'd3: row_bits = 5'b00100;
                    3'd4: row_bits = 5'b00100;
                    3'd5: row_bits = 5'b00100;
                    3'd6: row_bits = 5'b11111;
                    default: row_bits = 5'b00000;
                endcase
                8'd74: case (row)
                    3'd0: row_bits = 5'b00001;
                    3'd1: row_bits = 5'b00001;
                    3'd2: row_bits = 5'b00001;
                    3'd3: row_bits = 5'b00001;
                    3'd4: row_bits = 5'b10001;
                    3'd5: row_bits = 5'b10001;
                    3'd6: row_bits = 5'b01110;
                    default: row_bits = 5'b00000;
                endcase
                8'd75: case (row)
                    3'd0: row_bits = 5'b10001;
                    3'd1: row_bits = 5'b10010;
                    3'd2: row_bits = 5'b10100;
                    3'd3: row_bits = 5'b11000;
                    3'd4: row_bits = 5'b10100;
                    3'd5: row_bits = 5'b10010;
                    3'd6: row_bits = 5'b10001;
                    default: row_bits = 5'b00000;
                endcase
                8'd76: case (row)
                    3'd0: row_bits = 5'b10000;
                    3'd1: row_bits = 5'b10000;
                    3'd2: row_bits = 5'b10000;
                    3'd3: row_bits = 5'b10000;
                    3'd4: row_bits = 5'b10000;
                    3'd5: row_bits = 5'b10000;
                    3'd6: row_bits = 5'b11111;
                    default: row_bits = 5'b00000;
                endcase
                8'd77: case (row)
                    3'd0: row_bits = 5'b10001;
                    3'd1: row_bits = 5'b11011;
                    3'd2: row_bits = 5'b10101;
                    3'd3: row_bits = 5'b10101;
                    3'd4: row_bits = 5'b10001;
                    3'd5: row_bits = 5'b10001;
                    3'd6: row_bits = 5'b10001;
                    default: row_bits = 5'b00000;
                endcase
                8'd78: case (row)
                    3'd0: row_bits = 5'b10001;
                    3'd1: row_bits = 5'b11001;
                    3'd2: row_bits = 5'b10101;
                    3'd3: row_bits = 5'b10011;
                    3'd4: row_bits = 5'b10001;
                    3'd5: row_bits = 5'b10001;
                    3'd6: row_bits = 5'b10001;
                    default: row_bits = 5'b00000;
                endcase
                8'd79: case (row)
                    3'd0: row_bits = 5'b01110;
                    3'd1: row_bits = 5'b10001;
                    3'd2: row_bits = 5'b10001;
                    3'd3: row_bits = 5'b10001;
                    3'd4: row_bits = 5'b10001;
                    3'd5: row_bits = 5'b10001;
                    3'd6: row_bits = 5'b01110;
                    default: row_bits = 5'b00000;
                endcase
                8'd80: case (row)
                    3'd0: row_bits = 5'b11110;
                    3'd1: row_bits = 5'b10001;
                    3'd2: row_bits = 5'b10001;
                    3'd3: row_bits = 5'b11110;
                    3'd4: row_bits = 5'b10000;
                    3'd5: row_bits = 5'b10000;
                    3'd6: row_bits = 5'b10000;
                    default: row_bits = 5'b00000;
                endcase
                8'd81: case (row)
                    3'd0: row_bits = 5'b01110;
                    3'd1: row_bits = 5'b10001;
                    3'd2: row_bits = 5'b10001;
                    3'd3: row_bits = 5'b10001;
                    3'd4: row_bits = 5'b10101;
                    3'd5: row_bits = 5'b10011;
                    3'd6: row_bits = 5'b01111;
                    default: row_bits = 5'b00000;
                endcase
                8'd82: case (row)
                    3'd0: row_bits = 5'b11110;
                    3'd1: row_bits = 5'b10001;
                    3'd2: row_bits = 5'b10001;
                    3'd3: row_bits = 5'b11110;
                    3'd4: row_bits = 5'b10100;
                    3'd5: row_bits = 5'b10010;
                    3'd6: row_bits = 5'b10001;
                    default: row_bits = 5'b00000;
                endcase
                8'd83: case (row)
                    3'd0: row_bits = 5'b01111;
                    3'd1: row_bits = 5'b10000;
                    3'd2: row_bits = 5'b10000;
                    3'd3: row_bits = 5'b01110;
                    3'd4: row_bits = 5'b00001;
                    3'd5: row_bits = 5'b00001;
                    3'd6: row_bits = 5'b11110;
                    default: row_bits = 5'b00000;
                endcase
                8'd84: case (row)
                    3'd0: row_bits = 5'b11111;
                    3'd1: row_bits = 5'b00100;
                    3'd2: row_bits = 5'b00100;
                    3'd3: row_bits = 5'b00100;
                    3'd4: row_bits = 5'b00100;
                    3'd5: row_bits = 5'b00100;
                    3'd6: row_bits = 5'b00100;
                    default: row_bits = 5'b00000;
                endcase
                8'd85: case (row)
                    3'd0: row_bits = 5'b10001;
                    3'd1: row_bits = 5'b10001;
                    3'd2: row_bits = 5'b10001;
                    3'd3: row_bits = 5'b10001;
                    3'd4: row_bits = 5'b10001;
                    3'd5: row_bits = 5'b10001;
                    3'd6: row_bits = 5'b01110;
                    default: row_bits = 5'b00000;
                endcase
                8'd86: case (row)
                    3'd0: row_bits = 5'b10001;
                    3'd1: row_bits = 5'b10001;
                    3'd2: row_bits = 5'b10001;
                    3'd3: row_bits = 5'b10001;
                    3'd4: row_bits = 5'b10001;
                    3'd5: row_bits = 5'b01010;
                    3'd6: row_bits = 5'b00100;
                    default: row_bits = 5'b00000;
                endcase
                8'd87: case (row)
                    3'd0: row_bits = 5'b10001;
                    3'd1: row_bits = 5'b10001;
                    3'd2: row_bits = 5'b10001;
                    3'd3: row_bits = 5'b10101;
                    3'd4: row_bits = 5'b10101;
                    3'd5: row_bits = 5'b11011;
                    3'd6: row_bits = 5'b10001;
                    default: row_bits = 5'b00000;
                endcase
                8'd88: case (row)
                    3'd0: row_bits = 5'b10001;
                    3'd1: row_bits = 5'b10001;
                    3'd2: row_bits = 5'b01010;
                    3'd3: row_bits = 5'b00100;
                    3'd4: row_bits = 5'b01010;
                    3'd5: row_bits = 5'b10001;
                    3'd6: row_bits = 5'b10001;
                    default: row_bits = 5'b00000;
                endcase
                8'd89: case (row)
                    3'd0: row_bits = 5'b10001;
                    3'd1: row_bits = 5'b10001;
                    3'd2: row_bits = 5'b01010;
                    3'd3: row_bits = 5'b00100;
                    3'd4: row_bits = 5'b00100;
                    3'd5: row_bits = 5'b00100;
                    3'd6: row_bits = 5'b00100;
                    default: row_bits = 5'b00000;
                endcase
                8'd90: case (row)
                    3'd0: row_bits = 5'b11111;
                    3'd1: row_bits = 5'b00001;
                    3'd2: row_bits = 5'b00010;
                    3'd3: row_bits = 5'b00100;
                    3'd4: row_bits = 5'b01000;
                    3'd5: row_bits = 5'b10000;
                    3'd6: row_bits = 5'b11111;
                    default: row_bits = 5'b00000;
                endcase
                8'd48: case (row)
                    3'd0: row_bits = 5'b01110;
                    3'd1: row_bits = 5'b10001;
                    3'd2: row_bits = 5'b10011;
                    3'd3: row_bits = 5'b10101;
                    3'd4: row_bits = 5'b11001;
                    3'd5: row_bits = 5'b10001;
                    3'd6: row_bits = 5'b01110;
                    default: row_bits = 5'b00000;
                endcase
                8'd49: case (row)
                    3'd0: row_bits = 5'b00100;
                    3'd1: row_bits = 5'b01100;
                    3'd2: row_bits = 5'b00100;
                    3'd3: row_bits = 5'b00100;
                    3'd4: row_bits = 5'b00100;
                    3'd5: row_bits = 5'b00100;
                    3'd6: row_bits = 5'b01110;
                    default: row_bits = 5'b00000;
                endcase
                8'd50: case (row)
                    3'd0: row_bits = 5'b01110;
                    3'd1: row_bits = 5'b10001;
                    3'd2: row_bits = 5'b00001;
                    3'd3: row_bits = 5'b00110;
                    3'd4: row_bits = 5'b01000;
                    3'd5: row_bits = 5'b10000;
                    3'd6: row_bits = 5'b11111;
                    default: row_bits = 5'b00000;
                endcase
                8'd51: case (row)
                    3'd0: row_bits = 5'b11110;
                    3'd1: row_bits = 5'b00001;
                    3'd2: row_bits = 5'b00001;
                    3'd3: row_bits = 5'b01110;
                    3'd4: row_bits = 5'b00001;
                    3'd5: row_bits = 5'b00001;
                    3'd6: row_bits = 5'b11110;
                    default: row_bits = 5'b00000;
                endcase
                8'd52: case (row)
                    3'd0: row_bits = 5'b00010;
                    3'd1: row_bits = 5'b00110;
                    3'd2: row_bits = 5'b01010;
                    3'd3: row_bits = 5'b10010;
                    3'd4: row_bits = 5'b11111;
                    3'd5: row_bits = 5'b00010;
                    3'd6: row_bits = 5'b00010;
                    default: row_bits = 5'b00000;
                endcase
                8'd53: case (row)
                    3'd0: row_bits = 5'b11111;
                    3'd1: row_bits = 5'b10000;
                    3'd2: row_bits = 5'b10000;
                    3'd3: row_bits = 5'b11110;
                    3'd4: row_bits = 5'b00001;
                    3'd5: row_bits = 5'b00001;
                    3'd6: row_bits = 5'b11110;
                    default: row_bits = 5'b00000;
                endcase
                8'd54: case (row)
                    3'd0: row_bits = 5'b00110;
                    3'd1: row_bits = 5'b01000;
                    3'd2: row_bits = 5'b10000;
                    3'd3: row_bits = 5'b11110;
                    3'd4: row_bits = 5'b10001;
                    3'd5: row_bits = 5'b10001;
                    3'd6: row_bits = 5'b01110;
                    default: row_bits = 5'b00000;
                endcase
                8'd55: case (row)
                    3'd0: row_bits = 5'b11111;
                    3'd1: row_bits = 5'b00001;
                    3'd2: row_bits = 5'b00001;
                    3'd3: row_bits = 5'b00010;
                    3'd4: row_bits = 5'b00100;
                    3'd5: row_bits = 5'b01000;
                    3'd6: row_bits = 5'b01000;
                    default: row_bits = 5'b00000;
                endcase
                8'd56: case (row)
                    3'd0: row_bits = 5'b01110;
                    3'd1: row_bits = 5'b10001;
                    3'd2: row_bits = 5'b10001;
                    3'd3: row_bits = 5'b01110;
                    3'd4: row_bits = 5'b10001;
                    3'd5: row_bits = 5'b10001;
                    3'd6: row_bits = 5'b01110;
                    default: row_bits = 5'b00000;
                endcase
                8'd57: case (row)
                    3'd0: row_bits = 5'b01110;
                    3'd1: row_bits = 5'b10001;
                    3'd2: row_bits = 5'b10001;
                    3'd3: row_bits = 5'b01111;
                    3'd4: row_bits = 5'b00001;
                    3'd5: row_bits = 5'b00010;
                    3'd6: row_bits = 5'b01100;
                    default: row_bits = 5'b00000;
                endcase
                8'd45: case (row)
                    3'd0: row_bits = 5'b00000;
                    3'd1: row_bits = 5'b00000;
                    3'd2: row_bits = 5'b00000;
                    3'd3: row_bits = 5'b11111;
                    3'd4: row_bits = 5'b00000;
                    3'd5: row_bits = 5'b00000;
                    3'd6: row_bits = 5'b00000;
                    default: row_bits = 5'b00000;
                endcase
                8'd43: case (row)
                    3'd0: row_bits = 5'b00000;
                    3'd1: row_bits = 5'b00100;
                    3'd2: row_bits = 5'b00100;
                    3'd3: row_bits = 5'b11111;
                    3'd4: row_bits = 5'b00100;
                    3'd5: row_bits = 5'b00100;
                    3'd6: row_bits = 5'b00000;
                    default: row_bits = 5'b00000;
                endcase
                8'd46: case (row)
                    3'd0: row_bits = 5'b00000;
                    3'd1: row_bits = 5'b00000;
                    3'd2: row_bits = 5'b00000;
                    3'd3: row_bits = 5'b00000;
                    3'd4: row_bits = 5'b00000;
                    3'd5: row_bits = 5'b00000;
                    3'd6: row_bits = 5'b00100;
                    default: row_bits = 5'b00000;
                endcase
                8'd58: case (row)
                    3'd0: row_bits = 5'b00000;
                    3'd1: row_bits = 5'b00100;
                    3'd2: row_bits = 5'b00000;
                    3'd3: row_bits = 5'b00000;
                    3'd4: row_bits = 5'b00100;
                    3'd5: row_bits = 5'b00000;
                    3'd6: row_bits = 5'b00000;
                    default: row_bits = 5'b00000;
                endcase
                8'd47: case (row)
                    3'd0: row_bits = 5'b00001;
                    3'd1: row_bits = 5'b00010;
                    3'd2: row_bits = 5'b00010;
                    3'd3: row_bits = 5'b00100;
                    3'd4: row_bits = 5'b01000;
                    3'd5: row_bits = 5'b01000;
                    3'd6: row_bits = 5'b10000;
                    default: row_bits = 5'b00000;
                endcase
                8'd124: case (row)
                    3'd0: row_bits = 5'b00100;
                    3'd1: row_bits = 5'b00100;
                    3'd2: row_bits = 5'b00100;
                    3'd3: row_bits = 5'b00100;
                    3'd4: row_bits = 5'b00100;
                    3'd5: row_bits = 5'b00100;
                    3'd6: row_bits = 5'b00100;
                    default: row_bits = 5'b00000;
                endcase
                8'd38: case (row)
                    3'd0: row_bits = 5'b01100;
                    3'd1: row_bits = 5'b10010;
                    3'd2: row_bits = 5'b10100;
                    3'd3: row_bits = 5'b01000;
                    3'd4: row_bits = 5'b10101;
                    3'd5: row_bits = 5'b10010;
                    3'd6: row_bits = 5'b01101;
                    default: row_bits = 5'b00000;
                endcase
                8'd91: case (row)
                    3'd0: row_bits = 5'b01110;
                    3'd1: row_bits = 5'b01000;
                    3'd2: row_bits = 5'b01000;
                    3'd3: row_bits = 5'b01000;
                    3'd4: row_bits = 5'b01000;
                    3'd5: row_bits = 5'b01000;
                    3'd6: row_bits = 5'b01110;
                    default: row_bits = 5'b00000;
                endcase
                8'd93: case (row)
                    3'd0: row_bits = 5'b01110;
                    3'd1: row_bits = 5'b00010;
                    3'd2: row_bits = 5'b00010;
                    3'd3: row_bits = 5'b00010;
                    3'd4: row_bits = 5'b00010;
                    3'd5: row_bits = 5'b00010;
                    3'd6: row_bits = 5'b01110;
                    default: row_bits = 5'b00000;
                endcase
                8'd40: case (row)
                    3'd0: row_bits = 5'b00010;
                    3'd1: row_bits = 5'b00100;
                    3'd2: row_bits = 5'b01000;
                    3'd3: row_bits = 5'b01000;
                    3'd4: row_bits = 5'b01000;
                    3'd5: row_bits = 5'b00100;
                    3'd6: row_bits = 5'b00010;
                    default: row_bits = 5'b00000;
                endcase
                8'd41: case (row)
                    3'd0: row_bits = 5'b01000;
                    3'd1: row_bits = 5'b00100;
                    3'd2: row_bits = 5'b00010;
                    3'd3: row_bits = 5'b00010;
                    3'd4: row_bits = 5'b00010;
                    3'd5: row_bits = 5'b00100;
                    3'd6: row_bits = 5'b01000;
                    default: row_bits = 5'b00000;
                endcase
                8'd37: case (row)
                    3'd0: row_bits = 5'b11001;
                    3'd1: row_bits = 5'b11010;
                    3'd2: row_bits = 5'b00100;
                    3'd3: row_bits = 5'b01000;
                    3'd4: row_bits = 5'b01011;
                    3'd5: row_bits = 5'b10011;
                    3'd6: row_bits = 5'b00000;
                    default: row_bits = 5'b00000;
                endcase
                8'd35: case (row)
                    3'd0: row_bits = 5'b01010;
                    3'd1: row_bits = 5'b01010;
                    3'd2: row_bits = 5'b11111;
                    3'd3: row_bits = 5'b01010;
                    3'd4: row_bits = 5'b11111;
                    3'd5: row_bits = 5'b01010;
                    3'd6: row_bits = 5'b01010;
                    default: row_bits = 5'b00000;
                endcase
                default: row_bits = 5'b00000;
            endcase
            font_dot = row_bits[3'd4 - col];
        end
    endfunction

    function [5:0] get_str_len;
        input [6:0] str_id;
        begin
            case (str_id)
                7'd0: get_str_len = 6'd16;
                7'd1: get_str_len = 6'd14;
                7'd2: get_str_len = 6'd13;
                7'd3: get_str_len = 6'd15;
                7'd4: get_str_len = 6'd14;
                7'd5: get_str_len = 6'd5;
                7'd6: get_str_len = 6'd13;
                7'd7: get_str_len = 6'd22;
                7'd8: get_str_len = 6'd20;
                7'd9: get_str_len = 6'd15;
                7'd10: get_str_len = 6'd12;
                7'd11: get_str_len = 6'd18;
                7'd12: get_str_len = 6'd19;
                7'd13: get_str_len = 6'd22;
                7'd14: get_str_len = 6'd23;
                7'd15: get_str_len = 6'd42;
                7'd16: get_str_len = 6'd10;
                7'd17: get_str_len = 6'd20;
                7'd18: get_str_len = 6'd26;
                7'd19: get_str_len = 6'd1;
                7'd20: get_str_len = 6'd1;
                7'd21: get_str_len = 6'd43;
                7'd22: get_str_len = 6'd41;
                7'd23: get_str_len = 6'd41;
                7'd24: get_str_len = 6'd42;
                7'd25: get_str_len = 6'd2;
                7'd26: get_str_len = 6'd2;
                7'd27: get_str_len = 6'd2;
                7'd28: get_str_len = 6'd2;
                7'd29: get_str_len = 6'd2;
                7'd30: get_str_len = 6'd2;
                7'd31: get_str_len = 6'd2;
                7'd32: get_str_len = 6'd2;
                7'd33: get_str_len = 6'd2;
                7'd34: get_str_len = 6'd2;
                7'd35: get_str_len = 6'd2;
                7'd36: get_str_len = 6'd2;
                7'd37: get_str_len = 6'd23;
                7'd38: get_str_len = 6'd28;
                7'd39: get_str_len = 6'd41;
                7'd40: get_str_len = 6'd19;
                7'd41: get_str_len = 6'd4;
                7'd42: get_str_len = 6'd5;
                7'd43: get_str_len = 6'd5;
                7'd44: get_str_len = 6'd5;
                7'd45: get_str_len = 6'd4;
                7'd46: get_str_len = 6'd4;
                7'd47: get_str_len = 6'd4;
                7'd48: get_str_len = 6'd4;
                7'd49: get_str_len = 6'd5;
                7'd50: get_str_len = 6'd16;
                7'd51: get_str_len = 6'd16;
                7'd52: get_str_len = 6'd18;
                7'd53: get_str_len = 6'd17;
                7'd54: get_str_len = 6'd20;
                7'd55: get_str_len = 6'd17;
                7'd56: get_str_len = 6'd15;
                7'd57: get_str_len = 6'd19;
                7'd58: get_str_len = 6'd20;
                7'd59: get_str_len = 6'd54;
                7'd60: get_str_len = 6'd46;
                7'd61: get_str_len = 6'd21;
                7'd62: get_str_len = 6'd4;
                7'd63: get_str_len = 6'd3;
                7'd64: get_str_len = 6'd3;
                7'd65: get_str_len = 6'd3;
                7'd66: get_str_len = 6'd4;
                7'd67: get_str_len = 6'd4;
                7'd68: get_str_len = 6'd4;
                7'd69: get_str_len = 6'd4;
                7'd70: get_str_len = 6'd3;
                7'd71: get_str_len = 6'd26;
                7'd72: get_str_len = 6'd27;
                7'd73: get_str_len = 6'd61;
                7'd74: get_str_len = 6'd39;
                7'd75: get_str_len = 6'd24;
                7'd76: get_str_len = 6'd53;
                7'd77: get_str_len = 6'd35;
                7'd78: get_str_len = 6'd30;
                7'd79: get_str_len = 6'd8;
                7'd80: get_str_len = 6'd4;
                default: get_str_len = 6'd0;
            endcase
        end
    endfunction

    // -------------------------------------------------------------------------
    // 32-Voice Benchmark Oscillator Label Function (Pure Combinational)
    // -------------------------------------------------------------------------
    function [7:0] get_osc_char;
        input [4:0] v_idx; // 0..31
        input [3:0] c_pos; // 0..9
        reg   [5:0] v_num;
        reg   [6:0] val_2x;
        reg   [3:0] v_mod;
        reg   [2:0] val_div;
        reg   [3:0] val_mod;
        begin
            v_num = v_idx + 1'b1; // 1..32
            val_2x = v_num << 1;  // 2..64
            v_mod = v_num - ((v_num >= 6'd30) ? 6'd30 : (v_num >= 6'd20) ? 6'd20 : (v_num >= 6'd10) ? 6'd10 : 6'd0);
            val_div = (val_2x >= 7'd60) ? 3'd6 :
                      (val_2x >= 7'd50) ? 3'd5 :
                      (val_2x >= 7'd40) ? 3'd4 :
                      (val_2x >= 7'd30) ? 3'd3 :
                      (val_2x >= 7'd20) ? 3'd2 : 3'd1;
            val_mod = val_2x - ({4'd0, val_div} * 7'd10);

            case (c_pos)
                4'd0: get_osc_char = 8'd35; // '#'
                4'd1: get_osc_char = (v_num >= 6'd30) ? 8'd51 : // '3'
                                     (v_num >= 6'd20) ? 8'd50 : // '2'
                                     (v_num >= 6'd10) ? 8'd49 : // '1'
                                                        8'd48;  // '0'
                4'd2: get_osc_char = 8'd48 + {4'd0, v_mod};
                4'd3: get_osc_char = 8'd32; // ' '
                4'd4: begin
                    if (v_num < 6'd5)
                        get_osc_char = 8'd48 + {1'd0, val_2x}; // '2', '4', '6', '8'
                    else
                        get_osc_char = 8'd48 + {5'd0, val_div}; // '1'..'6'
                end
                4'd5: begin
                    if (v_num < 6'd5)
                        get_osc_char = 8'd48; // '0'
                    else
                        get_osc_char = 8'd46; // '.'
                end
                4'd6: begin
                    if (v_num < 6'd5)
                        get_osc_char = 8'd48; // '0'
                    else
                        get_osc_char = 8'd48 + {4'd0, val_mod}; // '0', '2', '4', '6', '8'
                end
                4'd7: begin
                    if (v_num < 6'd5)
                        get_osc_char = 8'd72; // 'H'
                    else
                        get_osc_char = 8'd75; // 'K'
                end
                4'd8: begin
                    if (v_num < 6'd5)
                        get_osc_char = 8'd90; // 'Z'
                    else
                        get_osc_char = 8'd72; // 'H'
                end
                4'd9: begin
                    if (v_num < 6'd5)
                        get_osc_char = 8'd32; // ' '
                    else
                        get_osc_char = 8'd90; // 'Z'
                end
                default: get_osc_char = 8'd32;
            endcase
        end
    endfunction

    function text_pixel;
        input [6:0] str_id;
        input [9:0] curr_x, curr_y;
        input [9:0] start_x, start_y;
        input [1:0] scale; // 1: 5x7, 2: 10x14
        reg [9:0] rx, ry;
        reg [9:0] char_idx;
        reg [5:0] s_len;
        reg [7:0] ch;
        reg [2:0] c_col, c_row;
        begin
            text_pixel = 1'b0;
            s_len = get_str_len(str_id);
            if (curr_x >= start_x && curr_y >= start_y) begin
                rx = (curr_x - start_x) / scale;
                ry = (curr_y - start_y) / scale;
                if (ry < 10'd7 && rx < ({4'd0, s_len} * 10'd6)) begin
                    char_idx = rx / 10'd6;
                    c_col = rx % 10'd6;
                    c_row = ry[2:0];
                    if (c_col < 3'd5) begin
                        ch = get_char(str_id, char_idx[5:0]);
                        if (ch != 8'd0) begin
                            text_pixel = font_dot(ch, c_col, c_row);
                        end
                    end
                end
            end
        end
    endfunction

    function [7:0] get_char;
        input [6:0] str_id;
        input [5:0] idx;
        begin
            case (str_id)
                7'd0: case (idx)
                    6'd0: get_char = 8'd83;
                    6'd1: get_char = 8'd89;
                    6'd2: get_char = 8'd78;
                    6'd3: get_char = 8'd84;
                    6'd4: get_char = 8'd72;
                    6'd5: get_char = 8'd69;
                    6'd6: get_char = 8'd83;
                    6'd7: get_char = 8'd73;
                    6'd8: get_char = 8'd90;
                    6'd9: get_char = 8'd69;
                    6'd10: get_char = 8'd82;
                    6'd11: get_char = 8'd32;
                    6'd12: get_char = 8'd49;
                    6'd13: get_char = 8'd51;
                    6'd14: get_char = 8'd56;
                    6'd15: get_char = 8'd75;
                    default: get_char = 8'd0;
                endcase
                7'd1: case (idx)
                    6'd0: get_char = 8'd49;
                    6'd1: get_char = 8'd58;
                    6'd2: get_char = 8'd32;
                    6'd3: get_char = 8'd80;
                    6'd4: get_char = 8'd69;
                    6'd5: get_char = 8'd82;
                    6'd6: get_char = 8'd70;
                    6'd7: get_char = 8'd79;
                    6'd8: get_char = 8'd82;
                    6'd9: get_char = 8'd77;
                    6'd10: get_char = 8'd65;
                    6'd11: get_char = 8'd78;
                    6'd12: get_char = 8'd67;
                    6'd13: get_char = 8'd69;
                    default: get_char = 8'd0;
                endcase
                7'd2: case (idx)
                    6'd0: get_char = 8'd50;
                    6'd1: get_char = 8'd58;
                    6'd2: get_char = 8'd32;
                    6'd3: get_char = 8'd87;
                    6'd4: get_char = 8'd65;
                    6'd5: get_char = 8'd86;
                    6'd6: get_char = 8'd69;
                    6'd7: get_char = 8'd32;
                    6'd8: get_char = 8'd38;
                    6'd9: get_char = 8'd32;
                    6'd10: get_char = 8'd70;
                    6'd11: get_char = 8'd70;
                    6'd12: get_char = 8'd84;
                    default: get_char = 8'd0;
                endcase
                7'd3: case (idx)
                    6'd0: get_char = 8'd51;
                    6'd1: get_char = 8'd58;
                    6'd2: get_char = 8'd32;
                    6'd3: get_char = 8'd51;
                    6'd4: get_char = 8'd50;
                    6'd5: get_char = 8'd45;
                    6'd6: get_char = 8'd66;
                    6'd7: get_char = 8'd69;
                    6'd8: get_char = 8'd78;
                    6'd9: get_char = 8'd67;
                    6'd10: get_char = 8'd72;
                    6'd11: get_char = 8'd77;
                    6'd12: get_char = 8'd65;
                    6'd13: get_char = 8'd82;
                    6'd14: get_char = 8'd75;
                    default: get_char = 8'd0;
                endcase
                7'd4: case (idx)
                    6'd0: get_char = 8'd52;
                    6'd1: get_char = 8'd58;
                    6'd2: get_char = 8'd32;
                    6'd3: get_char = 8'd83;
                    6'd4: get_char = 8'd79;
                    6'd5: get_char = 8'd78;
                    6'd6: get_char = 8'd71;
                    6'd7: get_char = 8'd32;
                    6'd8: get_char = 8'd80;
                    6'd9: get_char = 8'd76;
                    6'd10: get_char = 8'd65;
                    6'd11: get_char = 8'd89;
                    6'd12: get_char = 8'd69;
                    6'd13: get_char = 8'd82;
                    default: get_char = 8'd0;
                endcase
                7'd5: case (idx)
                    6'd0: get_char = 8'd57;
                    6'd1: get_char = 8'd55;
                    6'd2: get_char = 8'd46;
                    6'd3: get_char = 8'd54;
                    6'd4: get_char = 8'd75;
                    default: get_char = 8'd0;
                endcase
                7'd6: case (idx)
                    6'd0: get_char = 8'd77;
                    6'd1: get_char = 8'd79;
                    6'd2: get_char = 8'd68;
                    6'd3: get_char = 8'd69;
                    6'd4: get_char = 8'd32;
                    6'd5: get_char = 8'd38;
                    6'd6: get_char = 8'd32;
                    6'd7: get_char = 8'd84;
                    6'd8: get_char = 8'd73;
                    6'd9: get_char = 8'd77;
                    6'd10: get_char = 8'd66;
                    6'd11: get_char = 8'd82;
                    6'd12: get_char = 8'd69;
                    default: get_char = 8'd0;
                endcase
                7'd7: case (idx)
                    6'd0: get_char = 8'd70;
                    6'd1: get_char = 8'd82;
                    6'd2: get_char = 8'd69;
                    6'd3: get_char = 8'd69;
                    6'd4: get_char = 8'd32;
                    6'd5: get_char = 8'd80;
                    6'd6: get_char = 8'd76;
                    6'd7: get_char = 8'd65;
                    6'd8: get_char = 8'd89;
                    6'd9: get_char = 8'd32;
                    6'd10: get_char = 8'd40;
                    6'd11: get_char = 8'd77;
                    6'd12: get_char = 8'd73;
                    6'd13: get_char = 8'd68;
                    6'd14: get_char = 8'd73;
                    6'd15: get_char = 8'd47;
                    6'd16: get_char = 8'd84;
                    6'd17: get_char = 8'd79;
                    6'd18: get_char = 8'd85;
                    6'd19: get_char = 8'd67;
                    6'd20: get_char = 8'd72;
                    6'd21: get_char = 8'd41;
                    default: get_char = 8'd0;
                endcase
                7'd8: case (idx)
                    6'd0: get_char = 8'd84;
                    6'd1: get_char = 8'd73;
                    6'd2: get_char = 8'd77;
                    6'd3: get_char = 8'd66;
                    6'd4: get_char = 8'd82;
                    6'd5: get_char = 8'd69;
                    6'd6: get_char = 8'd58;
                    6'd7: get_char = 8'd32;
                    6'd8: get_char = 8'd80;
                    6'd9: get_char = 8'd73;
                    6'd10: get_char = 8'd65;
                    6'd11: get_char = 8'd78;
                    6'd12: get_char = 8'd79;
                    6'd13: get_char = 8'd32;
                    6'd14: get_char = 8'd54;
                    6'd15: get_char = 8'd45;
                    6'd16: get_char = 8'd72;
                    6'd17: get_char = 8'd65;
                    6'd18: get_char = 8'd82;
                    6'd19: get_char = 8'd77;
                    default: get_char = 8'd0;
                endcase
                7'd9: case (idx)
                    6'd0: get_char = 8'd78;
                    6'd1: get_char = 8'd79;
                    6'd2: get_char = 8'd84;
                    6'd3: get_char = 8'd69;
                    6'd4: get_char = 8'd32;
                    6'd5: get_char = 8'd38;
                    6'd6: get_char = 8'd32;
                    6'd7: get_char = 8'd68;
                    6'd8: get_char = 8'd89;
                    6'd9: get_char = 8'd78;
                    6'd10: get_char = 8'd65;
                    6'd11: get_char = 8'd77;
                    6'd12: get_char = 8'd73;
                    6'd13: get_char = 8'd67;
                    6'd14: get_char = 8'd83;
                    default: get_char = 8'd0;
                endcase
                7'd10: case (idx)
                    6'd0: get_char = 8'd65;
                    6'd1: get_char = 8'd52;
                    6'd2: get_char = 8'd32;
                    6'd3: get_char = 8'd32;
                    6'd4: get_char = 8'd52;
                    6'd5: get_char = 8'd52;
                    6'd6: get_char = 8'd48;
                    6'd7: get_char = 8'd46;
                    6'd8: get_char = 8'd48;
                    6'd9: get_char = 8'd32;
                    6'd10: get_char = 8'd72;
                    6'd11: get_char = 8'd90;
                    default: get_char = 8'd0;
                endcase
                7'd11: case (idx)
                    6'd0: get_char = 8'd45;
                    6'd1: get_char = 8'd45;
                    6'd2: get_char = 8'd32;
                    6'd3: get_char = 8'd32;
                    6'd4: get_char = 8'd73;
                    6'd5: get_char = 8'd68;
                    6'd6: get_char = 8'd76;
                    6'd7: get_char = 8'd69;
                    6'd8: get_char = 8'd32;
                    6'd9: get_char = 8'd40;
                    6'd10: get_char = 8'd83;
                    6'd11: get_char = 8'd84;
                    6'd12: get_char = 8'd65;
                    6'd13: get_char = 8'd78;
                    6'd14: get_char = 8'd68;
                    6'd15: get_char = 8'd66;
                    6'd16: get_char = 8'd89;
                    6'd17: get_char = 8'd41;
                    default: get_char = 8'd0;
                endcase
                7'd12: case (idx)
                    6'd0: get_char = 8'd80;
                    6'd1: get_char = 8'd79;
                    6'd2: get_char = 8'd76;
                    6'd3: get_char = 8'd89;
                    6'd4: get_char = 8'd80;
                    6'd5: get_char = 8'd72;
                    6'd6: get_char = 8'd79;
                    6'd7: get_char = 8'd78;
                    6'd8: get_char = 8'd89;
                    6'd9: get_char = 8'd32;
                    6'd10: get_char = 8'd38;
                    6'd11: get_char = 8'd32;
                    6'd12: get_char = 8'd69;
                    6'd13: get_char = 8'd70;
                    6'd14: get_char = 8'd70;
                    6'd15: get_char = 8'd69;
                    6'd16: get_char = 8'd67;
                    6'd17: get_char = 8'd84;
                    6'd18: get_char = 8'd83;
                    default: get_char = 8'd0;
                endcase
                7'd13: case (idx)
                    6'd0: get_char = 8'd86;
                    6'd1: get_char = 8'd79;
                    6'd2: get_char = 8'd73;
                    6'd3: get_char = 8'd67;
                    6'd4: get_char = 8'd69;
                    6'd5: get_char = 8'd83;
                    6'd6: get_char = 8'd58;
                    6'd7: get_char = 8'd32;
                    6'd8: get_char = 8'd48;
                    6'd9: get_char = 8'd56;
                    6'd10: get_char = 8'd32;
                    6'd11: get_char = 8'd47;
                    6'd12: get_char = 8'd32;
                    6'd13: get_char = 8'd51;
                    6'd14: get_char = 8'd50;
                    6'd15: get_char = 8'd32;
                    6'd16: get_char = 8'd65;
                    6'd17: get_char = 8'd67;
                    6'd18: get_char = 8'd84;
                    6'd19: get_char = 8'd73;
                    6'd20: get_char = 8'd86;
                    6'd21: get_char = 8'd69;
                    default: get_char = 8'd0;
                endcase
                7'd14: case (idx)
                    6'd0: get_char = 8'd70;
                    6'd1: get_char = 8'd88;
                    6'd2: get_char = 8'd58;
                    6'd3: get_char = 8'd32;
                    6'd4: get_char = 8'd66;
                    6'd5: get_char = 8'd89;
                    6'd6: get_char = 8'd80;
                    6'd7: get_char = 8'd65;
                    6'd8: get_char = 8'd83;
                    6'd9: get_char = 8'd83;
                    6'd10: get_char = 8'd32;
                    6'd11: get_char = 8'd40;
                    6'd12: get_char = 8'd68;
                    6'd13: get_char = 8'd82;
                    6'd14: get_char = 8'd89;
                    6'd15: get_char = 8'd32;
                    6'd16: get_char = 8'd68;
                    6'd17: get_char = 8'd73;
                    6'd18: get_char = 8'd82;
                    6'd19: get_char = 8'd69;
                    6'd20: get_char = 8'd67;
                    6'd21: get_char = 8'd84;
                    6'd22: get_char = 8'd41;
                    default: get_char = 8'd0;
                endcase
                7'd15: case (idx)
                    6'd0: get_char = 8'd82;
                    6'd1: get_char = 8'd69;
                    6'd2: get_char = 8'd65;
                    6'd3: get_char = 8'd76;
                    6'd4: get_char = 8'd45;
                    6'd5: get_char = 8'd84;
                    6'd6: get_char = 8'd73;
                    6'd7: get_char = 8'd77;
                    6'd8: get_char = 8'd69;
                    6'd9: get_char = 8'd32;
                    6'd10: get_char = 8'd65;
                    6'd11: get_char = 8'd85;
                    6'd12: get_char = 8'd68;
                    6'd13: get_char = 8'd73;
                    6'd14: get_char = 8'd79;
                    6'd15: get_char = 8'd32;
                    6'd16: get_char = 8'd79;
                    6'd17: get_char = 8'd83;
                    6'd18: get_char = 8'd67;
                    6'd19: get_char = 8'd73;
                    6'd20: get_char = 8'd76;
                    6'd21: get_char = 8'd76;
                    6'd22: get_char = 8'd79;
                    6'd23: get_char = 8'd83;
                    6'd24: get_char = 8'd67;
                    6'd25: get_char = 8'd79;
                    6'd26: get_char = 8'd80;
                    6'd27: get_char = 8'd69;
                    6'd28: get_char = 8'd32;
                    6'd29: get_char = 8'd40;
                    6'd30: get_char = 8'd84;
                    6'd31: get_char = 8'd73;
                    6'd32: get_char = 8'd77;
                    6'd33: get_char = 8'd69;
                    6'd34: get_char = 8'd32;
                    6'd35: get_char = 8'd68;
                    6'd36: get_char = 8'd79;
                    6'd37: get_char = 8'd77;
                    6'd38: get_char = 8'd65;
                    6'd39: get_char = 8'd73;
                    6'd40: get_char = 8'd78;
                    6'd41: get_char = 8'd41;
                    default: get_char = 8'd0;
                endcase
                7'd16: case (idx)
                    6'd0: get_char = 8'd51; // '3'
                    6'd1: get_char = 8'd46; // '.'
                    6'd2: get_char = 8'd48; // '0'
                    6'd3: get_char = 8'd83; // 'S'
                    6'd4: get_char = 8'd32; // ' '
                    6'd5: get_char = 8'd82; // 'R'
                    6'd6: get_char = 8'd79; // 'O'
                    6'd7: get_char = 8'd76; // 'L'
                    6'd8: get_char = 8'd76; // 'L'
                    6'd9: get_char = 8'd73; // 'I'
                    6'd10: get_char = 8'd78; // 'N'
                    6'd11: get_char = 8'd71; // 'G'
                    default: get_char = 8'd0;
                endcase
                7'd17: case (idx)
                    6'd0: get_char = 8'd91;
                    6'd1: get_char = 8'd32;
                    6'd2: get_char = 8'd83;
                    6'd3: get_char = 8'd84;
                    6'd4: get_char = 8'd65;
                    6'd5: get_char = 8'd78;
                    6'd6: get_char = 8'd68;
                    6'd7: get_char = 8'd66;
                    6'd8: get_char = 8'd89;
                    6'd9: get_char = 8'd32;
                    6'd10: get_char = 8'd47;
                    6'd11: get_char = 8'd32;
                    6'd12: get_char = 8'd83;
                    6'd13: get_char = 8'd73;
                    6'd14: get_char = 8'd76;
                    6'd15: get_char = 8'd69;
                    6'd16: get_char = 8'd78;
                    6'd17: get_char = 8'd84;
                    6'd18: get_char = 8'd32;
                    6'd19: get_char = 8'd93;
                    default: get_char = 8'd0;
                endcase
                7'd18: case (idx)
                    6'd0: get_char = 8'd83;
                    6'd1: get_char = 8'd84;
                    6'd2: get_char = 8'd69;
                    6'd3: get_char = 8'd82;
                    6'd4: get_char = 8'd69;
                    6'd5: get_char = 8'd79;
                    6'd6: get_char = 8'd32;
                    6'd7: get_char = 8'd68;
                    6'd8: get_char = 8'd89;
                    6'd9: get_char = 8'd78;
                    6'd10: get_char = 8'd65;
                    6'd11: get_char = 8'd77;
                    6'd12: get_char = 8'd73;
                    6'd13: get_char = 8'd67;
                    6'd14: get_char = 8'd83;
                    6'd15: get_char = 8'd32;
                    6'd16: get_char = 8'd38;
                    6'd17: get_char = 8'd32;
                    6'd18: get_char = 8'd69;
                    6'd19: get_char = 8'd78;
                    6'd20: get_char = 8'd86;
                    6'd21: get_char = 8'd69;
                    6'd22: get_char = 8'd76;
                    6'd23: get_char = 8'd79;
                    6'd24: get_char = 8'd80;
                    6'd25: get_char = 8'd69;
                    default: get_char = 8'd0;
                endcase
                7'd19: case (idx)
                    6'd0: get_char = 8'd76;
                    default: get_char = 8'd0;
                endcase
                7'd20: case (idx)
                    6'd0: get_char = 8'd82;
                    default: get_char = 8'd0;
                endcase
                7'd21: case (idx)
                    6'd0: get_char = 8'd45;
                    6'd1: get_char = 8'd52;
                    6'd2: get_char = 8'd56;
                    6'd3: get_char = 8'd68;
                    6'd4: get_char = 8'd66;
                    6'd5: get_char = 8'd32;
                    6'd6: get_char = 8'd32;
                    6'd7: get_char = 8'd32;
                    6'd8: get_char = 8'd32;
                    6'd9: get_char = 8'd32;
                    6'd10: get_char = 8'd45;
                    6'd11: get_char = 8'd50;
                    6'd12: get_char = 8'd52;
                    6'd13: get_char = 8'd68;
                    6'd14: get_char = 8'd66;
                    6'd15: get_char = 8'd32;
                    6'd16: get_char = 8'd32;
                    6'd17: get_char = 8'd32;
                    6'd18: get_char = 8'd32;
                    6'd19: get_char = 8'd32;
                    6'd20: get_char = 8'd45;
                    6'd21: get_char = 8'd49;
                    6'd22: get_char = 8'd50;
                    6'd23: get_char = 8'd68;
                    6'd24: get_char = 8'd66;
                    6'd25: get_char = 8'd32;
                    6'd26: get_char = 8'd32;
                    6'd27: get_char = 8'd32;
                    6'd28: get_char = 8'd32;
                    6'd29: get_char = 8'd32;
                    6'd30: get_char = 8'd45;
                    6'd31: get_char = 8'd54;
                    6'd32: get_char = 8'd68;
                    6'd33: get_char = 8'd66;
                    6'd34: get_char = 8'd32;
                    6'd35: get_char = 8'd32;
                    6'd36: get_char = 8'd32;
                    6'd37: get_char = 8'd32;
                    6'd38: get_char = 8'd32;
                    6'd39: get_char = 8'd32;
                    6'd40: get_char = 8'd48;
                    6'd41: get_char = 8'd68;
                    6'd42: get_char = 8'd66;
                    default: get_char = 8'd0;
                endcase
                7'd22: case (idx)
                    6'd0: get_char = 8'd65;
                    6'd1: get_char = 8'd68;
                    6'd2: get_char = 8'd83;
                    6'd3: get_char = 8'd82;
                    6'd4: get_char = 8'd58;
                    6'd5: get_char = 8'd32;
                    6'd6: get_char = 8'd65;
                    6'd7: get_char = 8'd84;
                    6'd8: get_char = 8'd75;
                    6'd9: get_char = 8'd58;
                    6'd10: get_char = 8'd53;
                    6'd11: get_char = 8'd77;
                    6'd12: get_char = 8'd83;
                    6'd13: get_char = 8'd32;
                    6'd14: get_char = 8'd68;
                    6'd15: get_char = 8'd69;
                    6'd16: get_char = 8'd67;
                    6'd17: get_char = 8'd58;
                    6'd18: get_char = 8'd49;
                    6'd19: get_char = 8'd50;
                    6'd20: get_char = 8'd48;
                    6'd21: get_char = 8'd77;
                    6'd22: get_char = 8'd83;
                    6'd23: get_char = 8'd32;
                    6'd24: get_char = 8'd83;
                    6'd25: get_char = 8'd85;
                    6'd26: get_char = 8'd83;
                    6'd27: get_char = 8'd58;
                    6'd28: get_char = 8'd55;
                    6'd29: get_char = 8'd48;
                    6'd30: get_char = 8'd37;
                    6'd31: get_char = 8'd32;
                    6'd32: get_char = 8'd82;
                    6'd33: get_char = 8'd69;
                    6'd34: get_char = 8'd76;
                    6'd35: get_char = 8'd58;
                    6'd36: get_char = 8'd49;
                    6'd37: get_char = 8'd56;
                    6'd38: get_char = 8'd48;
                    6'd39: get_char = 8'd77;
                    6'd40: get_char = 8'd83;
                    default: get_char = 8'd0;
                endcase
                7'd23: case (idx)
                    6'd0: get_char = 8'd84;
                    6'd1: get_char = 8'd79;
                    6'd2: get_char = 8'd85;
                    6'd3: get_char = 8'd67;
                    6'd4: get_char = 8'd72;
                    6'd5: get_char = 8'd32;
                    6'd6: get_char = 8'd80;
                    6'd7: get_char = 8'd73;
                    6'd8: get_char = 8'd65;
                    6'd9: get_char = 8'd78;
                    6'd10: get_char = 8'd79;
                    6'd11: get_char = 8'd32;
                    6'd12: get_char = 8'd40;
                    6'd13: get_char = 8'd49;
                    6'd14: get_char = 8'd32;
                    6'd15: get_char = 8'd79;
                    6'd16: get_char = 8'd67;
                    6'd17: get_char = 8'd84;
                    6'd18: get_char = 8'd65;
                    6'd19: get_char = 8'd86;
                    6'd20: get_char = 8'd69;
                    6'd21: get_char = 8'd58;
                    6'd22: get_char = 8'd32;
                    6'd23: get_char = 8'd67;
                    6'd24: get_char = 8'd52;
                    6'd25: get_char = 8'd32;
                    6'd26: get_char = 8'd45;
                    6'd27: get_char = 8'd32;
                    6'd28: get_char = 8'd66;
                    6'd29: get_char = 8'd52;
                    6'd30: get_char = 8'd41;
                    6'd31: get_char = 8'd32;
                    6'd32: get_char = 8'd32;
                    6'd33: get_char = 8'd91;
                    6'd34: get_char = 8'd65;
                    6'd35: get_char = 8'd67;
                    6'd36: get_char = 8'd84;
                    6'd37: get_char = 8'd73;
                    6'd38: get_char = 8'd86;
                    6'd39: get_char = 8'd69;
                    6'd40: get_char = 8'd93;
                    default: get_char = 8'd0;
                endcase
                7'd24: case (idx)
                    6'd0: get_char = 8'd84;
                    6'd1: get_char = 8'd79;
                    6'd2: get_char = 8'd85;
                    6'd3: get_char = 8'd67;
                    6'd4: get_char = 8'd72;
                    6'd5: get_char = 8'd32;
                    6'd6: get_char = 8'd80;
                    6'd7: get_char = 8'd73;
                    6'd8: get_char = 8'd65;
                    6'd9: get_char = 8'd78;
                    6'd10: get_char = 8'd79;
                    6'd11: get_char = 8'd32;
                    6'd12: get_char = 8'd40;
                    6'd13: get_char = 8'd49;
                    6'd14: get_char = 8'd32;
                    6'd15: get_char = 8'd79;
                    6'd16: get_char = 8'd67;
                    6'd17: get_char = 8'd84;
                    6'd18: get_char = 8'd65;
                    6'd19: get_char = 8'd86;
                    6'd20: get_char = 8'd69;
                    6'd21: get_char = 8'd58;
                    6'd22: get_char = 8'd32;
                    6'd23: get_char = 8'd67;
                    6'd24: get_char = 8'd52;
                    6'd25: get_char = 8'd32;
                    6'd26: get_char = 8'd45;
                    6'd27: get_char = 8'd32;
                    6'd28: get_char = 8'd66;
                    6'd29: get_char = 8'd52;
                    6'd30: get_char = 8'd41;
                    6'd31: get_char = 8'd32;
                    6'd32: get_char = 8'd32;
                    6'd33: get_char = 8'd91;
                    6'd34: get_char = 8'd83;
                    6'd35: get_char = 8'd84;
                    6'd36: get_char = 8'd65;
                    6'd37: get_char = 8'd78;
                    6'd38: get_char = 8'd68;
                    6'd39: get_char = 8'd66;
                    6'd40: get_char = 8'd89;
                    6'd41: get_char = 8'd93;
                    default: get_char = 8'd0;
                endcase
                7'd25: case (idx)
                    6'd0: get_char = 8'd67;
                    6'd1: get_char = 8'd52;
                    default: get_char = 8'd0;
                endcase
                7'd26: case (idx)
                    6'd0: get_char = 8'd68;
                    6'd1: get_char = 8'd52;
                    default: get_char = 8'd0;
                endcase
                7'd27: case (idx)
                    6'd0: get_char = 8'd69;
                    6'd1: get_char = 8'd52;
                    default: get_char = 8'd0;
                endcase
                7'd28: case (idx)
                    6'd0: get_char = 8'd70;
                    6'd1: get_char = 8'd52;
                    default: get_char = 8'd0;
                endcase
                7'd29: case (idx)
                    6'd0: get_char = 8'd71;
                    6'd1: get_char = 8'd52;
                    default: get_char = 8'd0;
                endcase
                7'd30: case (idx)
                    6'd0: get_char = 8'd65;
                    6'd1: get_char = 8'd52;
                    default: get_char = 8'd0;
                endcase
                7'd31: case (idx)
                    6'd0: get_char = 8'd66;
                    6'd1: get_char = 8'd52;
                    default: get_char = 8'd0;
                endcase
                7'd32: case (idx)
                    6'd0: get_char = 8'd67;
                    6'd1: get_char = 8'd35;
                    default: get_char = 8'd0;
                endcase
                7'd33: case (idx)
                    6'd0: get_char = 8'd68;
                    6'd1: get_char = 8'd35;
                    default: get_char = 8'd0;
                endcase
                7'd34: case (idx)
                    6'd0: get_char = 8'd70;
                    6'd1: get_char = 8'd35;
                    default: get_char = 8'd0;
                endcase
                7'd35: case (idx)
                    6'd0: get_char = 8'd71;
                    6'd1: get_char = 8'd35;
                    default: get_char = 8'd0;
                endcase
                7'd36: case (idx)
                    6'd0: get_char = 8'd65;
                    6'd1: get_char = 8'd35;
                    default: get_char = 8'd0;
                endcase
                7'd37: case (idx)
                    6'd0: get_char = 8'd57;
                    6'd1: get_char = 8'd55;
                    6'd2: get_char = 8'd46;
                    6'd3: get_char = 8'd54;
                    6'd4: get_char = 8'd53;
                    6'd5: get_char = 8'd54;
                    6'd6: get_char = 8'd32;
                    6'd7: get_char = 8'd75;
                    6'd8: get_char = 8'd83;
                    6'd9: get_char = 8'd80;
                    6'd10: get_char = 8'd83;
                    6'd11: get_char = 8'd32;
                    6'd12: get_char = 8'd124;
                    6'd13: get_char = 8'd32;
                    6'd14: get_char = 8'd53;
                    6'd15: get_char = 8'd48;
                    6'd16: get_char = 8'd32;
                    6'd17: get_char = 8'd77;
                    6'd18: get_char = 8'd83;
                    6'd19: get_char = 8'd47;
                    6'd20: get_char = 8'd68;
                    6'd21: get_char = 8'd73;
                    6'd22: get_char = 8'd86;
                    default: get_char = 8'd0;
                endcase
                7'd38: case (idx)
                    6'd0: get_char = 8'd91;
                    6'd1: get_char = 8'd32;
                    6'd2: get_char = 8'd83;
                    6'd3: get_char = 8'd84;
                    6'd4: get_char = 8'd65;
                    6'd5: get_char = 8'd78;
                    6'd6: get_char = 8'd68;
                    6'd7: get_char = 8'd66;
                    6'd8: get_char = 8'd89;
                    6'd9: get_char = 8'd32;
                    6'd10: get_char = 8'd47;
                    6'd11: get_char = 8'd32;
                    6'd12: get_char = 8'd87;
                    6'd13: get_char = 8'd65;
                    6'd14: get_char = 8'd73;
                    6'd15: get_char = 8'd84;
                    6'd16: get_char = 8'd73;
                    6'd17: get_char = 8'd78;
                    6'd18: get_char = 8'd71;
                    6'd19: get_char = 8'd32;
                    6'd20: get_char = 8'd83;
                    6'd21: get_char = 8'd73;
                    6'd22: get_char = 8'd71;
                    6'd23: get_char = 8'd78;
                    6'd24: get_char = 8'd65;
                    6'd25: get_char = 8'd76;
                    6'd26: get_char = 8'd32;
                    6'd27: get_char = 8'd93;
                    default: get_char = 8'd0;
                endcase
                7'd39: case (idx)
                    6'd0: get_char = 8'd51;
                    6'd1: get_char = 8'd50;
                    6'd2: get_char = 8'd45;
                    6'd3: get_char = 8'd66;
                    6'd4: get_char = 8'd65;
                    6'd5: get_char = 8'd78;
                    6'd6: get_char = 8'd68;
                    6'd7: get_char = 8'd32;
                    6'd8: get_char = 8'd70;
                    6'd9: get_char = 8'd70;
                    6'd10: get_char = 8'd84;
                    6'd11: get_char = 8'd32;
                    6'd12: get_char = 8'd83;
                    6'd13: get_char = 8'd80;
                    6'd14: get_char = 8'd69;
                    6'd15: get_char = 8'd67;
                    6'd16: get_char = 8'd84;
                    6'd17: get_char = 8'd82;
                    6'd18: get_char = 8'd85;
                    6'd19: get_char = 8'd77;
                    6'd20: get_char = 8'd32;
                    6'd21: get_char = 8'd65;
                    6'd22: get_char = 8'd78;
                    6'd23: get_char = 8'd65;
                    6'd24: get_char = 8'd76;
                    6'd25: get_char = 8'd89;
                    6'd26: get_char = 8'd90;
                    6'd27: get_char = 8'd69;
                    6'd28: get_char = 8'd82;
                    6'd29: get_char = 8'd32;
                    6'd30: get_char = 8'd40;
                    6'd31: get_char = 8'd76;
                    6'd32: get_char = 8'd79;
                    6'd33: get_char = 8'd71;
                    6'd34: get_char = 8'd32;
                    6'd35: get_char = 8'd83;
                    6'd36: get_char = 8'd67;
                    6'd37: get_char = 8'd65;
                    6'd38: get_char = 8'd76;
                    6'd39: get_char = 8'd69;
                    6'd40: get_char = 8'd41;
                    default: get_char = 8'd0;
                endcase
                7'd40: case (idx)
                    6'd0: get_char = 8'd82;
                    6'd1: get_char = 8'd65;
                    6'd2: get_char = 8'd78;
                    6'd3: get_char = 8'd71;
                    6'd4: get_char = 8'd69;
                    6'd5: get_char = 8'd58;
                    6'd6: get_char = 8'd32;
                    6'd7: get_char = 8'd53;
                    6'd8: get_char = 8'd48;
                    6'd9: get_char = 8'd72;
                    6'd10: get_char = 8'd90;
                    6'd11: get_char = 8'd32;
                    6'd12: get_char = 8'd45;
                    6'd13: get_char = 8'd32;
                    6'd14: get_char = 8'd49;
                    6'd15: get_char = 8'd54;
                    6'd16: get_char = 8'd75;
                    6'd17: get_char = 8'd72;
                    6'd18: get_char = 8'd90;
                    default: get_char = 8'd0;
                endcase
                7'd41: case (idx)
                    6'd0: get_char = 8'd53;
                    6'd1: get_char = 8'd48;
                    6'd2: get_char = 8'd72;
                    6'd3: get_char = 8'd90;
                    default: get_char = 8'd0;
                endcase
                7'd42: case (idx)
                    6'd0: get_char = 8'd49;
                    6'd1: get_char = 8'd50;
                    6'd2: get_char = 8'd53;
                    6'd3: get_char = 8'd72;
                    6'd4: get_char = 8'd90;
                    default: get_char = 8'd0;
                endcase
                7'd43: case (idx)
                    6'd0: get_char = 8'd50;
                    6'd1: get_char = 8'd53;
                    6'd2: get_char = 8'd48;
                    6'd3: get_char = 8'd72;
                    6'd4: get_char = 8'd90;
                    default: get_char = 8'd0;
                endcase
                7'd44: case (idx)
                    6'd0: get_char = 8'd53;
                    6'd1: get_char = 8'd48;
                    6'd2: get_char = 8'd48;
                    6'd3: get_char = 8'd72;
                    6'd4: get_char = 8'd90;
                    default: get_char = 8'd0;
                endcase
                7'd45: case (idx)
                    6'd0: get_char = 8'd49;
                    6'd1: get_char = 8'd75;
                    6'd2: get_char = 8'd72;
                    6'd3: get_char = 8'd90;
                    default: get_char = 8'd0;
                endcase
                7'd46: case (idx)
                    6'd0: get_char = 8'd50;
                    6'd1: get_char = 8'd75;
                    6'd2: get_char = 8'd72;
                    6'd3: get_char = 8'd90;
                    default: get_char = 8'd0;
                endcase
                7'd47: case (idx)
                    6'd0: get_char = 8'd52;
                    6'd1: get_char = 8'd75;
                    6'd2: get_char = 8'd72;
                    6'd3: get_char = 8'd90;
                    default: get_char = 8'd0;
                endcase
                7'd48: case (idx)
                    6'd0: get_char = 8'd56;
                    6'd1: get_char = 8'd75;
                    6'd2: get_char = 8'd72;
                    6'd3: get_char = 8'd90;
                    default: get_char = 8'd0;
                endcase
                7'd49: case (idx)
                    6'd0: get_char = 8'd49;
                    6'd1: get_char = 8'd54;
                    6'd2: get_char = 8'd75;
                    6'd3: get_char = 8'd72;
                    6'd4: get_char = 8'd90;
                    default: get_char = 8'd0;
                endcase
                7'd50: case (idx)
                    6'd0: get_char = 8'd66;
                    6'd1: get_char = 8'd69;
                    6'd2: get_char = 8'd78;
                    6'd3: get_char = 8'd67;
                    6'd4: get_char = 8'd72;
                    6'd5: get_char = 8'd77;
                    6'd6: get_char = 8'd65;
                    6'd7: get_char = 8'd82;
                    6'd8: get_char = 8'd75;
                    6'd9: get_char = 8'd32;
                    6'd10: get_char = 8'd83;
                    6'd11: get_char = 8'd84;
                    6'd12: get_char = 8'd65;
                    6'd13: get_char = 8'd84;
                    6'd14: get_char = 8'd85;
                    6'd15: get_char = 8'd83;
                    default: get_char = 8'd0;
                endcase
                7'd51: case (idx)
                    6'd0: get_char = 8'd51;
                    6'd1: get_char = 8'd50;
                    6'd2: get_char = 8'd32;
                    6'd3: get_char = 8'd86;
                    6'd4: get_char = 8'd79;
                    6'd5: get_char = 8'd73;
                    6'd6: get_char = 8'd67;
                    6'd7: get_char = 8'd69;
                    6'd8: get_char = 8'd83;
                    6'd9: get_char = 8'd32;
                    6'd10: get_char = 8'd65;
                    6'd11: get_char = 8'd67;
                    6'd12: get_char = 8'd84;
                    6'd13: get_char = 8'd73;
                    6'd14: get_char = 8'd86;
                    6'd15: get_char = 8'd69;
                    default: get_char = 8'd0;
                endcase
                7'd52: case (idx)
                    6'd0: get_char = 8'd80;
                    6'd1: get_char = 8'd85;
                    6'd2: get_char = 8'd82;
                    6'd3: get_char = 8'd69;
                    6'd4: get_char = 8'd32;
                    6'd5: get_char = 8'd72;
                    6'd6: get_char = 8'd68;
                    6'd7: get_char = 8'd76;
                    6'd8: get_char = 8'd32;
                    6'd9: get_char = 8'd83;
                    6'd10: get_char = 8'd89;
                    6'd11: get_char = 8'd78;
                    6'd12: get_char = 8'd84;
                    6'd13: get_char = 8'd72;
                    6'd14: get_char = 8'd69;
                    6'd15: get_char = 8'd83;
                    6'd16: get_char = 8'd73;
                    6'd17: get_char = 8'd83;
                    default: get_char = 8'd0;
                endcase
                7'd53: case (idx)
                    6'd0: get_char = 8'd83;
                    6'd1: get_char = 8'd65;
                    6'd2: get_char = 8'd77;
                    6'd3: get_char = 8'd80;
                    6'd4: get_char = 8'd76;
                    6'd5: get_char = 8'd69;
                    6'd6: get_char = 8'd32;
                    6'd7: get_char = 8'd82;
                    6'd8: get_char = 8'd65;
                    6'd9: get_char = 8'd84;
                    6'd10: get_char = 8'd69;
                    6'd11: get_char = 8'd32;
                    6'd12: get_char = 8'd38;
                    6'd13: get_char = 8'd32;
                    6'd14: get_char = 8'd68;
                    6'd15: get_char = 8'd65;
                    6'd16: get_char = 8'd67;
                    default: get_char = 8'd0;
                endcase
                7'd54: case (idx)
                    6'd0: get_char = 8'd57;
                    6'd1: get_char = 8'd55;
                    6'd2: get_char = 8'd46;
                    6'd3: get_char = 8'd54;
                    6'd4: get_char = 8'd53;
                    6'd5: get_char = 8'd54;
                    6'd6: get_char = 8'd32;
                    6'd7: get_char = 8'd75;
                    6'd8: get_char = 8'd83;
                    6'd9: get_char = 8'd80;
                    6'd10: get_char = 8'd83;
                    6'd11: get_char = 8'd32;
                    6'd12: get_char = 8'd124;
                    6'd13: get_char = 8'd32;
                    6'd14: get_char = 8'd49;
                    6'd15: get_char = 8'd54;
                    6'd16: get_char = 8'd45;
                    6'd17: get_char = 8'd66;
                    6'd18: get_char = 8'd73;
                    6'd19: get_char = 8'd84;
                    default: get_char = 8'd0;
                endcase
                7'd55: case (idx)
                    6'd0: get_char = 8'd80;
                    6'd1: get_char = 8'd84;
                    6'd2: get_char = 8'd56;
                    6'd3: get_char = 8'd50;
                    6'd4: get_char = 8'd49;
                    6'd5: get_char = 8'd49;
                    6'd6: get_char = 8'd32;
                    6'd7: get_char = 8'd67;
                    6'd8: get_char = 8'd79;
                    6'd9: get_char = 8'd78;
                    6'd10: get_char = 8'd84;
                    6'd11: get_char = 8'd73;
                    6'd12: get_char = 8'd78;
                    6'd13: get_char = 8'd85;
                    6'd14: get_char = 8'd79;
                    6'd15: get_char = 8'd85;
                    6'd16: get_char = 8'd83;
                    default: get_char = 8'd0;
                endcase
                7'd56: case (idx)
                    6'd0: get_char = 8'd83;
                    6'd1: get_char = 8'd80;
                    6'd2: get_char = 8'd69;
                    6'd3: get_char = 8'd67;
                    6'd4: get_char = 8'd84;
                    6'd5: get_char = 8'd82;
                    6'd6: get_char = 8'd65;
                    6'd7: get_char = 8'd76;
                    6'd8: get_char = 8'd32;
                    6'd9: get_char = 8'd80;
                    6'd10: get_char = 8'd85;
                    6'd11: get_char = 8'd82;
                    6'd12: get_char = 8'd73;
                    6'd13: get_char = 8'd84;
                    6'd14: get_char = 8'd89;
                    default: get_char = 8'd0;
                endcase
                7'd57: case (idx)
                    6'd0: get_char = 8'd51;
                    6'd1: get_char = 8'd50;
                    6'd2: get_char = 8'd32;
                    6'd3: get_char = 8'd47;
                    6'd4: get_char = 8'd32;
                    6'd5: get_char = 8'd51;
                    6'd6: get_char = 8'd50;
                    6'd7: get_char = 8'd32;
                    6'd8: get_char = 8'd73;
                    6'd9: get_char = 8'd78;
                    6'd10: get_char = 8'd68;
                    6'd11: get_char = 8'd69;
                    6'd12: get_char = 8'd80;
                    6'd13: get_char = 8'd69;
                    6'd14: get_char = 8'd78;
                    6'd15: get_char = 8'd68;
                    6'd16: get_char = 8'd69;
                    6'd17: get_char = 8'd78;
                    6'd18: get_char = 8'd84;
                    default: get_char = 8'd0;
                endcase
                7'd58: case (idx)
                    6'd0: get_char = 8'd82;
                    6'd1: get_char = 8'd85;
                    6'd2: get_char = 8'd76;
                    6'd3: get_char = 8'd69;
                    6'd4: get_char = 8'd32;
                    6'd5: get_char = 8'd51;
                    6'd6: get_char = 8'd32;
                    6'd7: get_char = 8'd86;
                    6'd8: get_char = 8'd69;
                    6'd9: get_char = 8'd82;
                    6'd10: get_char = 8'd73;
                    6'd11: get_char = 8'd70;
                    6'd12: get_char = 8'd73;
                    6'd13: get_char = 8'd69;
                    6'd14: get_char = 8'd68;
                    6'd15: get_char = 8'd32;
                    6'd16: get_char = 8'd80;
                    6'd17: get_char = 8'd65;
                    6'd18: get_char = 8'd83;
                    6'd19: get_char = 8'd83;
                    default: get_char = 8'd0;
                endcase
                7'd59: case (idx)
                    6'd0: get_char = 8'd51;
                    6'd1: get_char = 8'd50;
                    6'd2: get_char = 8'd32;
                    6'd3: get_char = 8'd73;
                    6'd4: get_char = 8'd78;
                    6'd5: get_char = 8'd68;
                    6'd6: get_char = 8'd69;
                    6'd7: get_char = 8'd80;
                    6'd8: get_char = 8'd69;
                    6'd9: get_char = 8'd78;
                    6'd10: get_char = 8'd68;
                    6'd11: get_char = 8'd69;
                    6'd12: get_char = 8'd78;
                    6'd13: get_char = 8'd84;
                    6'd14: get_char = 8'd32;
                    6'd15: get_char = 8'd72;
                    6'd16: get_char = 8'd65;
                    6'd17: get_char = 8'd82;
                    6'd18: get_char = 8'd68;
                    6'd19: get_char = 8'd87;
                    6'd20: get_char = 8'd65;
                    6'd21: get_char = 8'd82;
                    6'd22: get_char = 8'd69;
                    6'd23: get_char = 8'd32;
                    6'd24: get_char = 8'd68;
                    6'd25: get_char = 8'd68;
                    6'd26: get_char = 8'd83;
                    6'd27: get_char = 8'd32;
                    6'd28: get_char = 8'd79;
                    6'd29: get_char = 8'd83;
                    6'd30: get_char = 8'd67;
                    6'd31: get_char = 8'd73;
                    6'd32: get_char = 8'd76;
                    6'd33: get_char = 8'd76;
                    6'd34: get_char = 8'd65;
                    6'd35: get_char = 8'd84;
                    6'd36: get_char = 8'd79;
                    6'd37: get_char = 8'd82;
                    6'd38: get_char = 8'd83;
                    6'd39: get_char = 8'd32;
                    6'd40: get_char = 8'd40;
                    6'd41: get_char = 8'd66;
                    6'd42: get_char = 8'd65;
                    6'd43: get_char = 8'd78;
                    6'd44: get_char = 8'd75;
                    6'd45: get_char = 8'd32;
                    6'd46: get_char = 8'd48;
                    6'd47: get_char = 8'd49;
                    6'd48: get_char = 8'd32;
                    6'd49: get_char = 8'd45;
                    6'd50: get_char = 8'd32;
                    6'd51: get_char = 8'd51;
                    6'd52: get_char = 8'd50;
                    6'd53: get_char = 8'd41;
                    default: get_char = 8'd0;
                endcase
                7'd60: case (idx)
                    6'd0: get_char = 8'd51;
                    6'd1: get_char = 8'd50;
                    6'd2: get_char = 8'd32;
                    6'd3: get_char = 8'd68;
                    6'd4: get_char = 8'd73;
                    6'd5: get_char = 8'd83;
                    6'd6: get_char = 8'd67;
                    6'd7: get_char = 8'd82;
                    6'd8: get_char = 8'd69;
                    6'd9: get_char = 8'd84;
                    6'd10: get_char = 8'd69;
                    6'd11: get_char = 8'd32;
                    6'd12: get_char = 8'd83;
                    6'd13: get_char = 8'd80;
                    6'd14: get_char = 8'd69;
                    6'd15: get_char = 8'd67;
                    6'd16: get_char = 8'd84;
                    6'd17: get_char = 8'd82;
                    6'd18: get_char = 8'd65;
                    6'd19: get_char = 8'd76;
                    6'd20: get_char = 8'd32;
                    6'd21: get_char = 8'd80;
                    6'd22: get_char = 8'd69;
                    6'd23: get_char = 8'd65;
                    6'd24: get_char = 8'd75;
                    6'd25: get_char = 8'd83;
                    6'd26: get_char = 8'd32;
                    6'd27: get_char = 8'd45;
                    6'd28: get_char = 8'd32;
                    6'd29: get_char = 8'd69;
                    6'd30: get_char = 8'd86;
                    6'd31: get_char = 8'd73;
                    6'd32: get_char = 8'd68;
                    6'd33: get_char = 8'd69;
                    6'd34: get_char = 8'd78;
                    6'd35: get_char = 8'd67;
                    6'd36: get_char = 8'd69;
                    6'd37: get_char = 8'd32;
                    6'd38: get_char = 8'd40;
                    6'd39: get_char = 8'd82;
                    6'd40: get_char = 8'd85;
                    6'd41: get_char = 8'd76;
                    6'd42: get_char = 8'd69;
                    6'd43: get_char = 8'd32;
                    6'd44: get_char = 8'd51;
                    6'd45: get_char = 8'd41;
                    default: get_char = 8'd0;
                endcase
                7'd61: case (idx)
                    6'd0: get_char = 8'd65;
                    6'd1: get_char = 8'd76;
                    6'd2: get_char = 8'd76;
                    6'd3: get_char = 8'd32;
                    6'd4: get_char = 8'd51;
                    6'd5: get_char = 8'd50;
                    6'd6: get_char = 8'd32;
                    6'd7: get_char = 8'd80;
                    6'd8: get_char = 8'd69;
                    6'd9: get_char = 8'd65;
                    6'd10: get_char = 8'd75;
                    6'd11: get_char = 8'd83;
                    6'd12: get_char = 8'd32;
                    6'd13: get_char = 8'd68;
                    6'd14: get_char = 8'd69;
                    6'd15: get_char = 8'd84;
                    6'd16: get_char = 8'd69;
                    6'd17: get_char = 8'd67;
                    6'd18: get_char = 8'd84;
                    6'd19: get_char = 8'd69;
                    6'd20: get_char = 8'd68;
                    default: get_char = 8'd0;
                endcase
                7'd62: case (idx)
                    6'd0: get_char = 8'd54;
                    6'd1: get_char = 8'd53;
                    6'd2: get_char = 8'd72;
                    6'd3: get_char = 8'd90;
                    default: get_char = 8'd0;
                endcase
                7'd63: case (idx)
                    6'd0: get_char = 8'd49;
                    6'd1: get_char = 8'd51;
                    6'd2: get_char = 8'd48;
                    default: get_char = 8'd0;
                endcase
                7'd64: case (idx)
                    6'd0: get_char = 8'd50;
                    6'd1: get_char = 8'd54;
                    6'd2: get_char = 8'd48;
                    default: get_char = 8'd0;
                endcase
                7'd65: case (idx)
                    6'd0: get_char = 8'd53;
                    6'd1: get_char = 8'd50;
                    6'd2: get_char = 8'd48;
                    default: get_char = 8'd0;
                endcase
                7'd66: case (idx)
                    6'd0: get_char = 8'd49;
                    6'd1: get_char = 8'd75;
                    6'd2: get_char = 8'd72;
                    6'd3: get_char = 8'd90;
                    default: get_char = 8'd0;
                endcase
                7'd67: case (idx)
                    6'd0: get_char = 8'd50;
                    6'd1: get_char = 8'd75;
                    6'd2: get_char = 8'd72;
                    6'd3: get_char = 8'd90;
                    default: get_char = 8'd0;
                endcase
                7'd68: case (idx)
                    6'd0: get_char = 8'd52;
                    6'd1: get_char = 8'd75;
                    6'd2: get_char = 8'd72;
                    6'd3: get_char = 8'd90;
                    default: get_char = 8'd0;
                endcase
                7'd69: case (idx)
                    6'd0: get_char = 8'd56;
                    6'd1: get_char = 8'd75;
                    6'd2: get_char = 8'd72;
                    6'd3: get_char = 8'd90;
                    default: get_char = 8'd0;
                endcase
                7'd70: case (idx)
                    6'd0: get_char = 8'd49;
                    6'd1: get_char = 8'd50;
                    6'd2: get_char = 8'd75;
                    default: get_char = 8'd0;
                endcase
                7'd71: case (idx)
                    6'd0: get_char = 8'd78; // N
                    6'd1: get_char = 8'd79; // O
                    6'd2: get_char = 8'd87; // W
                    6'd3: get_char = 8'd32; // ' '
                    6'd4: get_char = 8'd80; // P
                    6'd5: get_char = 8'd76; // L
                    6'd6: get_char = 8'd65; // A
                    6'd7: get_char = 8'd89; // Y
                    6'd8: get_char = 8'd73; // I
                    6'd9: get_char = 8'd78; // N
                    6'd10: get_char = 8'd71; // G
                    6'd11: get_char = 8'd58; // :
                    6'd12: get_char = 8'd32; // ' '
                    6'd13: get_char = 8'd84; // T
                    6'd14: get_char = 8'd82; // R
                    6'd15: get_char = 8'd65; // A
                    6'd16: get_char = 8'd67; // C
                    6'd17: get_char = 8'd75; // K
                    6'd18: get_char = 8'd32; // ' '
                    6'd19: get_char = 8'd48; // 0
                    6'd20: get_char = 8'd49 + {5'd0, song_index}; // 1..5
                    6'd21: get_char = 8'd32; // ' '
                    6'd22: get_char = 8'd47; // /
                    6'd23: get_char = 8'd32; // ' '
                    6'd24: get_char = 8'd48; // 0
                    6'd25: get_char = 8'd53; // 5
                    default: get_char = 8'd0;
                endcase
                7'd72: begin
                    case (song_index)
                        3'd0: case (idx) // WO LUO LEI QING XU LING SUI
                            6'd0: get_char = 8'd87; 6'd1: get_char = 8'd79; 6'd2: get_char = 8'd32;
                            6'd3: get_char = 8'd76; 6'd4: get_char = 8'd85; 6'd5: get_char = 8'd79; 6'd6: get_char = 8'd32;
                            6'd7: get_char = 8'd76; 6'd8: get_char = 8'd69; 6'd9: get_char = 8'd73; 6'd10: get_char = 8'd32;
                            6'd11: get_char = 8'd81; 6'd12: get_char = 8'd73; 6'd13: get_char = 8'd78; 6'd14: get_char = 8'd71; 6'd15: get_char = 8'd32;
                            6'd16: get_char = 8'd88; 6'd17: get_char = 8'd85; 6'd18: get_char = 8'd32;
                            6'd19: get_char = 8'd76; 6'd20: get_char = 8'd73; 6'd21: get_char = 8'd78; 6'd22: get_char = 8'd71; 6'd23: get_char = 8'd32;
                            6'd24: get_char = 8'd83; 6'd25: get_char = 8'd85; 6'd26: get_char = 8'd73;
                            default: get_char = 8'd0;
                        endcase
                        3'd1: case (idx) // BEETHOVEN OP.125 ODE TO JOY
                            6'd0: get_char = 8'd66; 6'd1: get_char = 8'd69; 6'd2: get_char = 8'd69; 6'd3: get_char = 8'd84;
                            6'd4: get_char = 8'd72; 6'd5: get_char = 8'd79; 6'd6: get_char = 8'd86; 6'd7: get_char = 8'd69;
                            6'd8: get_char = 8'd78; 6'd9: get_char = 8'd32; 6'd10: get_char = 8'd79; 6'd11: get_char = 8'd80;
                            6'd12: get_char = 8'd46; 6'd13: get_char = 8'd49; 6'd14: get_char = 8'd50; 6'd15: get_char = 8'd53;
                            6'd16: get_char = 8'd32; 6'd17: get_char = 8'd79; 6'd18: get_char = 8'd68; 6'd19: get_char = 8'd69;
                            6'd20: get_char = 8'd32; 6'd21: get_char = 8'd84; 6'd22: get_char = 8'd79; 6'd23: get_char = 8'd32;
                            6'd24: get_char = 8'd74; 6'd25: get_char = 8'd79; 6'd26: get_char = 8'd89;
                            default: get_char = 8'd0;
                        endcase
                        3'd2: case (idx) // TWINKLE TWINKLE LITTLE STAR
                            6'd0: get_char = 8'd84; 6'd1: get_char = 8'd87; 6'd2: get_char = 8'd73; 6'd3: get_char = 8'd78;
                            6'd4: get_char = 8'd75; 6'd5: get_char = 8'd76; 6'd6: get_char = 8'd69; 6'd7: get_char = 8'd32;
                            6'd8: get_char = 8'd76; 6'd9: get_char = 8'd73; 6'd10: get_char = 8'd84; 6'd11: get_char = 8'd84;
                            6'd12: get_char = 8'd76; 6'd13: get_char = 8'd69; 6'd14: get_char = 8'd32; 6'd15: get_char = 8'd83;
                            6'd16: get_char = 8'd84; 6'd17: get_char = 8'd65; 6'd18: get_char = 8'd82; 6'd19: get_char = 8'd32;
                            6'd20: get_char = 8'd83; 6'd21: get_char = 8'd79; 6'd22: get_char = 8'd78; 6'd23: get_char = 8'd71;
                            6'd24: get_char = 8'd32; 6'd25: get_char = 8'd32; 6'd26: get_char = 8'd32;
                            default: get_char = 8'd0;
                        endcase
                        3'd3: case (idx) // JINGLE BELLS TRADITIONAL
                            6'd0: get_char = 8'd74; 6'd1: get_char = 8'd73; 6'd2: get_char = 8'd78; 6'd3: get_char = 8'd71;
                            6'd4: get_char = 8'd76; 6'd5: get_char = 8'd69; 6'd6: get_char = 8'd32; 6'd7: get_char = 8'd66;
                            6'd8: get_char = 8'd69; 6'd9: get_char = 8'd76; 6'd10: get_char = 8'd76; 6'd11: get_char = 8'd83;
                            6'd12: get_char = 8'd32; 6'd13: get_char = 8'd84; 6'd14: get_char = 8'd82; 6'd15: get_char = 8'd65;
                            6'd16: get_char = 8'd68; 6'd17: get_char = 8'd73; 6'd18: get_char = 8'd84; 6'd19: get_char = 8'd73;
                            6'd20: get_char = 8'd79; 6'd21: get_char = 8'd78; 6'd22: get_char = 8'd65; 6'd23: get_char = 8'd76;
                            6'd24: get_char = 8'd32; 6'd25: get_char = 8'd32; 6'd26: get_char = 8'd32;
                            default: get_char = 8'd0;
                        endcase
                        default: case (idx) // BEETHOVEN FUR ELISE
                            6'd0: get_char = 8'd66; 6'd1: get_char = 8'd69; 6'd2: get_char = 8'd69; 6'd3: get_char = 8'd84;
                            6'd4: get_char = 8'd72; 6'd5: get_char = 8'd79; 6'd6: get_char = 8'd86; 6'd7: get_char = 8'd69;
                            6'd8: get_char = 8'd78; 6'd9: get_char = 8'd32; 6'd10: get_char = 8'd70; 6'd11: get_char = 8'd85;
                            6'd12: get_char = 8'd82; 6'd13: get_char = 8'd32; 6'd14: get_char = 8'd69; 6'd15: get_char = 8'd76;
                            6'd16: get_char = 8'd73; 6'd17: get_char = 8'd83; 6'd18: get_char = 8'd69; 6'd19: get_char = 8'd32;
                            6'd20: get_char = 8'd80; 6'd21: get_char = 8'd73; 6'd22: get_char = 8'd65; 6'd23: get_char = 8'd78;
                            6'd24: get_char = 8'd79; 6'd25: get_char = 8'd32; 6'd26: get_char = 8'd32;
                            default: get_char = 8'd0;
                        endcase
                    endcase
                end
                7'd73: case (idx)
                    6'd0: get_char = 8'd84; 6'd1: get_char = 8'd73; 6'd2: get_char = 8'd77; 6'd3: get_char = 8'd66; 6'd4: get_char = 8'd82; 6'd5: get_char = 8'd69; 6'd6: get_char = 8'd58; 6'd7: get_char = 8'd32;
                    6'd8: get_char = 8'd71; 6'd9: get_char = 8'd82; 6'd10: get_char = 8'd65; 6'd11: get_char = 8'd78; 6'd12: get_char = 8'd68; 6'd13: get_char = 8'd32;
                    6'd14: get_char = 8'd80; 6'd15: get_char = 8'd73; 6'd16: get_char = 8'd65; 6'd17: get_char = 8'd78; 6'd18: get_char = 8'd79; 6'd19: get_char = 8'd32;
                    6'd20: get_char = 8'd54; 6'd21: get_char = 8'd45; 6'd22: get_char = 8'd72; 6'd23: get_char = 8'd65; 6'd24: get_char = 8'd82; 6'd25: get_char = 8'd77; 6'd26: get_char = 8'd32; 6'd27: get_char = 8'd124; 6'd28: get_char = 8'd32;
                    6'd29: get_char = 8'd84; 6'd30: get_char = 8'd69; 6'd31: get_char = 8'd77; 6'd32: get_char = 8'd80; 6'd33: get_char = 8'd79; 6'd34: get_char = 8'd58; 6'd35: get_char = 8'd32;
                    6'd36: get_char = 8'd49; 6'd37: get_char = 8'd50; 6'd38: get_char = 8'd48; 6'd39: get_char = 8'd32; 6'd40: get_char = 8'd66; 6'd41: get_char = 8'd80; 6'd42: get_char = 8'd77; 6'd43: get_char = 8'd32; 6'd44: get_char = 8'd124; 6'd45: get_char = 8'd32;
                    6'd46: get_char = 8'd83; 6'd47: get_char = 8'd84; 6'd48: get_char = 8'd65; 6'd49: get_char = 8'd84; 6'd50: get_char = 8'd85; 6'd51: get_char = 8'd83; 6'd52: get_char = 8'd58; 6'd53: get_char = 8'd32;
                    6'd54: get_char = 8'd80; // P
                    6'd55: get_char = song_playing ? 8'd76 : 8'd65; // L : A
                    6'd56: get_char = song_playing ? 8'd65 : 8'd85; // A : U
                    6'd57: get_char = song_playing ? 8'd89 : 8'd83; // Y : S
                    6'd58: get_char = song_playing ? 8'd73 : 8'd69; // I : E
                    6'd59: get_char = song_playing ? 8'd78 : 8'd68; // N : D
                    6'd60: get_char = song_playing ? 8'd71 : 8'd32; // G : ' '
                    default: get_char = 8'd0;
                endcase
                7'd74: case (idx)
                    6'd0: get_char = 8'd80; // P
                    6'd1: get_char = 8'd76; // L
                    6'd2: get_char = 8'd65; // A
                    6'd3: get_char = 8'd89; // Y
                    6'd4: get_char = 8'd66; // B
                    6'd5: get_char = 8'd65; // A
                    6'd6: get_char = 8'd67; // C
                    6'd7: get_char = 8'd75; // K
                    6'd8: get_char = 8'd32; // ' '
                    6'd9: get_char = 8'd80; // P
                    6'd10: get_char = 8'd82; // R
                    6'd11: get_char = 8'd79; // O
                    6'd12: get_char = 8'd71; // G
                    6'd13: get_char = 8'd82; // R
                    6'd14: get_char = 8'd69; // E
                    6'd15: get_char = 8'd83; // S
                    6'd16: get_char = 8'd83; // S
                    6'd17: get_char = 8'd58; // :
                    6'd18: get_char = 8'd32; // ' '
                    6'd19: get_char = 8'd48; // 0
                    6'd20: get_char = 8'd48 + {4'd0, song_elapsed_min[3:0]}; // m
                    6'd21: get_char = 8'd58; // :
                    6'd22: get_char = 8'd48 + cur_sec_d10; // s10
                    6'd23: get_char = 8'd48 + cur_sec_rem; // s1
                    6'd24: get_char = 8'd32; // ' '
                    6'd25: get_char = 8'd47; // /
                    6'd26: get_char = 8'd32; // ' '
                    6'd27: get_char = 8'd48; // 0
                    6'd28: get_char = 8'd48; // 0
                    6'd29: get_char = 8'd58; // :
                    6'd30: get_char = 8'd48 + tot_sec_d10; // S10
                    6'd31: get_char = 8'd48 + tot_sec_rem; // S1
                    6'd32: get_char = 8'd32; // ' '
                    6'd33: get_char = 8'd32; // ' '
                    6'd34: get_char = 8'd40; // (
                    6'd35: get_char = pct_d100 ? 8'd49 : (pct_d10 > 0 ? (8'd48 + pct_d10) : 8'd48);
                    6'd36: get_char = pct_d100 ? 8'd48 : (8'd48 + pct_rem10);
                    6'd37: get_char = 8'd37; // %
                    6'd38: get_char = 8'd41; // )
                    default: get_char = 8'd0;
                endcase
                7'd75: case (idx)
                    6'd0: get_char = 8'd75;
                    6'd1: get_char = 8'd69;
                    6'd2: get_char = 8'd89;
                    6'd3: get_char = 8'd49;
                    6'd4: get_char = 8'd58;
                    6'd5: get_char = 8'd32;
                    6'd6: get_char = 8'd80;
                    6'd7: get_char = 8'd65;
                    6'd8: get_char = 8'd85;
                    6'd9: get_char = 8'd83;
                    6'd10: get_char = 8'd69;
                    6'd11: get_char = 8'd32;
                    6'd12: get_char = 8'd124;
                    6'd13: get_char = 8'd32;
                    6'd14: get_char = 8'd75;
                    6'd15: get_char = 8'd69;
                    6'd16: get_char = 8'd89;
                    6'd17: get_char = 8'd50;
                    6'd18: get_char = 8'd58;
                    6'd19: get_char = 8'd32;
                    6'd20: get_char = 8'd78;
                    6'd21: get_char = 8'd69;
                    6'd22: get_char = 8'd88;
                    6'd23: get_char = 8'd84;
                    default: get_char = 8'd0;
                endcase
                7'd76: case (idx)
                    6'd0: get_char = 8'd76;
                    6'd1: get_char = 8'd79;
                    6'd2: get_char = 8'd79;
                    6'd3: get_char = 8'd80;
                    6'd4: get_char = 8'd58;
                    6'd5: get_char = 8'd32;
                    6'd6: get_char = 8'd79;
                    6'd7: get_char = 8'd78;
                    6'd8: get_char = 8'd32;
                    6'd9: get_char = 8'd124;
                    6'd10: get_char = 8'd32;
                    6'd11: get_char = 8'd80;
                    6'd12: get_char = 8'd85;
                    6'd13: get_char = 8'd82;
                    6'd14: get_char = 8'd69;
                    6'd15: get_char = 8'd32;
                    6'd16: get_char = 8'd72;
                    6'd17: get_char = 8'd68;
                    6'd18: get_char = 8'd76;
                    6'd19: get_char = 8'd32;
                    6'd20: get_char = 8'd82;
                    6'd21: get_char = 8'd79;
                    6'd22: get_char = 8'd77;
                    6'd23: get_char = 8'd32;
                    6'd24: get_char = 8'd83;
                    6'd25: get_char = 8'd69;
                    6'd26: get_char = 8'd81;
                    6'd27: get_char = 8'd85;
                    6'd28: get_char = 8'd69;
                    6'd29: get_char = 8'd78;
                    6'd30: get_char = 8'd67;
                    6'd31: get_char = 8'd69;
                    6'd32: get_char = 8'd82;
                    6'd33: get_char = 8'd32;
                    6'd34: get_char = 8'd124;
                    6'd35: get_char = 8'd32;
                    6'd36: get_char = 8'd90;
                    6'd37: get_char = 8'd69;
                    6'd38: get_char = 8'd82;
                    6'd39: get_char = 8'd79;
                    6'd40: get_char = 8'd32;
                    6'd41: get_char = 8'd67;
                    6'd42: get_char = 8'd80;
                    6'd43: get_char = 8'd85;
                    6'd44: get_char = 8'd32;
                    6'd45: get_char = 8'd83;
                    6'd46: get_char = 8'd79;
                    6'd47: get_char = 8'd70;
                    6'd48: get_char = 8'd84;
                    6'd49: get_char = 8'd67;
                    6'd50: get_char = 8'd79;
                    6'd51: get_char = 8'd82;
                    6'd52: get_char = 8'd69;
                    default: get_char = 8'd0;
                endcase
                7'd77: case (idx)
                    6'd0: get_char = 8'd82;
                    6'd1: get_char = 8'd69;
                    6'd2: get_char = 8'd65;
                    6'd3: get_char = 8'd76;
                    6'd4: get_char = 8'd45;
                    6'd5: get_char = 8'd84;
                    6'd6: get_char = 8'd73;
                    6'd7: get_char = 8'd77;
                    6'd8: get_char = 8'd69;
                    6'd9: get_char = 8'd32;
                    6'd10: get_char = 8'd83;
                    6'd11: get_char = 8'd67;
                    6'd12: get_char = 8'd79;
                    6'd13: get_char = 8'd82;
                    6'd14: get_char = 8'd69;
                    6'd15: get_char = 8'd32;
                    6'd16: get_char = 8'd38;
                    6'd17: get_char = 8'd32;
                    6'd18: get_char = 8'd77;
                    6'd19: get_char = 8'd85;
                    6'd20: get_char = 8'd76;
                    6'd21: get_char = 8'd84;
                    6'd22: get_char = 8'd73;
                    6'd23: get_char = 8'd45;
                    6'd24: get_char = 8'd86;
                    6'd25: get_char = 8'd79;
                    6'd26: get_char = 8'd73;
                    6'd27: get_char = 8'd67;
                    6'd28: get_char = 8'd69;
                    6'd29: get_char = 8'd32;
                    6'd30: get_char = 8'd83;
                    6'd31: get_char = 8'd84;
                    6'd32: get_char = 8'd65;
                    6'd33: get_char = 8'd86;
                    6'd34: get_char = 8'd69;
                    default: get_char = 8'd0;
                endcase
                7'd78: case (idx)
                    6'd0: get_char = 8'd77; // M
                    6'd1: get_char = 8'd69; // E
                    6'd2: get_char = 8'd76; // L
                    6'd3: get_char = 8'd79; // O
                    6'd4: get_char = 8'd68; // D
                    6'd5: get_char = 8'd89; // Y
                    6'd6: get_char = 8'd58; // :
                    6'd7: get_char = 8'd32; // ' '
                    6'd8: begin
                        case (song_active_note)
                            7'd60, 7'd72: get_char = 8'd67; // C
                            7'd62, 7'd74: get_char = 8'd68; // D
                            7'd64, 7'd76: get_char = 8'd69; // E
                            7'd65, 7'd77: get_char = 8'd70; // F
                            7'd67:        get_char = 8'd71; // G
                            7'd69:        get_char = 8'd65; // A
                            7'd71:        get_char = 8'd66; // B
                            7'd61, 7'd63, 7'd66, 7'd68, 7'd70: get_char = 8'd35; // #
                            default:      get_char = 8'd45; // -
                        endcase
                    end
                    6'd9: begin
                        case (song_active_note)
                            7'd60, 7'd62, 7'd64, 7'd65, 7'd67, 7'd69, 7'd71: get_char = 8'd52; // 4
                            7'd72, 7'd74, 7'd76, 7'd77:                     get_char = 8'd53; // 5
                            default: get_char = 8'd32;
                        endcase
                    end
                    6'd10: get_char = 8'd32;
                    6'd11: get_char = 8'd40; // (
                    6'd12: begin
                        case (song_active_note)
                            7'd60, 7'd72: get_char = 8'd68; // DO: D
                            7'd62, 7'd74: get_char = 8'd82; // RE: R
                            7'd64, 7'd76: get_char = 8'd77; // MI: M
                            7'd65, 7'd77: get_char = 8'd70; // FA: F
                            7'd67:        get_char = 8'd83; // SOL: S
                            7'd69:        get_char = 8'd76; // LA: L
                            7'd71:        get_char = 8'd84; // TI: T
                            default:      get_char = 8'd45; // -
                        endcase
                    end
                    6'd13: begin
                        case (song_active_note)
                            7'd60, 7'd72: get_char = 8'd79; // O
                            7'd62, 7'd74: get_char = 8'd69; // E
                            7'd64, 7'd76: get_char = 8'd73; // I
                            7'd65, 7'd77: get_char = 8'd65; // A
                            7'd67:        get_char = 8'd79; // O
                            7'd69:        get_char = 8'd65; // A
                            7'd71:        get_char = 8'd73; // I
                            default:      get_char = 8'd45;
                        endcase
                    end
                    6'd14: get_char = (song_active_note == 7'd67) ? 8'd76 : 8'd41; // L or )
                    6'd15: get_char = (song_active_note == 7'd67) ? 8'd41 : 8'd32; // ) or ' '
                    6'd16: get_char = 8'd32;
                    6'd17: get_char = 8'd124; // |
                    6'd18: get_char = 8'd32;
                    6'd19: get_char = 8'd67; // C
                    6'd20: get_char = 8'd72; // H
                    6'd21: get_char = 8'd79; // O
                    6'd22: get_char = 8'd82; // R
                    6'd23: get_char = 8'd68; // D
                    6'd24: get_char = 8'd58; // :
                    6'd25: get_char = 8'd32;
                    6'd26: get_char = 8'd67; // C
                    6'd27: get_char = 8'd32;
                    6'd28: get_char = 8'd77; // M
                    6'd29: get_char = 8'd65; // A
                    default: get_char = 8'd0;
                endcase
                7'd79: case (idx)
                    6'd0: get_char = 8'd80;
                    6'd1: get_char = 8'd76;
                    6'd2: get_char = 8'd65;
                    6'd3: get_char = 8'd89;
                    6'd4: get_char = 8'd72;
                    6'd5: get_char = 8'd69;
                    6'd6: get_char = 8'd65;
                    6'd7: get_char = 8'd68;
                    default: get_char = 8'd0;
                endcase
                7'd80: case (idx)
                    6'd0: get_char = 8'd86; // 'V'
                    6'd1: get_char = 8'd79; // 'O'
                    6'd2: get_char = 8'd76; // 'L'
                    6'd3: get_char = 8'd58; // ':'
                    default: get_char = 8'd0;
                endcase
                default: get_char = 8'd0;
            endcase
        end
    endfunction

    // -------------------------------------------------------------------------
    // 全局顶部导航栏 (y: 0..36)
    // -------------------------------------------------------------------------
    wire in_nav      = (py <= 9'd36);
    wire nav_border  = (py == 9'd36);

    // 4个 Tab 高亮横线 (y: 33..35)
    wire tab0_bar = (page == 2'd0) && (px >= 10'd176 && px <= 10'd292 && py >= 9'd33 && py <= 9'd35);
    wire tab1_bar = (page == 2'd1) && (px >= 10'd326 && px <= 10'd442 && py >= 9'd33 && py <= 9'd35);
    wire tab2_bar = (page == 2'd2) && (px >= 10'd476 && px <= 10'd592 && py >= 9'd33 && py <= 9'd35);
    wire tab3_bar = (page == 2'd3) && (px >= 10'd626 && px <= 10'd742 && py >= 9'd33 && py <= 9'd35);
    wire tab_active_bar = tab0_bar || tab1_bar || tab2_bar || tab3_bar;

    wire t_nav_title = text_pixel(0, px, py, 10'd16,  9'd12, 2'd1);
    wire t_nav_tab0  = text_pixel(1, px, py, 10'd180, 9'd12, 2'd1);
    wire t_nav_tab1  = text_pixel(2, px, py, 10'd330, 9'd12, 2'd1);
    wire t_nav_tab2  = text_pixel(3, px, py, 10'd480, 9'd12, 2'd1);
    wire t_nav_tab3  = text_pixel(4, px, py, 10'd630, 9'd12, 2'd1);
    wire t_nav_rate  = text_pixel(5, px, py, 10'd728, 9'd12, 2'd1);

    // -------------------------------------------------------------------------
    // PAGE 0: 演奏主界面 (PERFORMANCE DASHBOARD - REFINED v2)
    // -------------------------------------------------------------------------
    // 顶部 3 张 Metric Cards (y: 44..104, x: 20..266, 276..522, 532..778)
    wire p0_c1_box = (page == 2'd0) && (px >= 10'd20  && px <= 10'd266 && py >= 9'd44 && py <= 9'd104);
    wire p0_c2_box = (page == 2'd0) && (px >= 10'd276 && px <= 10'd522 && py >= 9'd44 && py <= 9'd104);
    wire p0_c3_box = (page == 2'd0) && (px >= 10'd532 && px <= 10'd778 && py >= 9'd44 && py <= 9'd104);

    wire p0_c1_border = (page == 2'd0) && (
        ((px == 10'd20 || px == 10'd266) && py >= 9'd44 && py <= 9'd104) ||
        ((py == 9'd44 || py == 9'd104) && px >= 10'd20 && px <= 10'd266)
    );
    wire p0_c2_border = (page == 2'd0) && (
        ((px == 10'd276 || px == 10'd522) && py >= 9'd44 && py <= 9'd104) ||
        ((py == 9'd44 || py == 9'd104) && px >= 10'd276 && px <= 10'd522)
    );
    wire p0_c3_border = (page == 2'd0) && (
        ((px == 10'd532 || px == 10'd778) && py >= 9'd44 && py <= 9'd104) ||
        ((py == 9'd44 || py == 9'd104) && px >= 10'd532 && px <= 10'd778)
    );

    wire p0_c1_strip = p0_c1_box && (py >= 9'd44 && py <= 9'd46);
    wire p0_c2_strip = p0_c2_box && (py >= 9'd44 && py <= 9'd46);
    wire p0_c3_strip = p0_c3_box && (py >= 9'd44 && py <= 9'd46);

    wire t_p0_c1_t  = (page == 2'd0) && text_pixel(6,  px, py, 10'd30,  9'd52, 2'd1);
    wire t_p0_c1_v1 = (page == 2'd0) && text_pixel(7,  px, py, 10'd30,  9'd68, 2'd1);
    wire t_p0_c1_v2 = (page == 2'd0) && text_pixel(8,  px, py, 10'd30,  9'd86, 2'd1);

    wire t_p0_c2_t  = (page == 2'd0) && text_pixel(9,  px, py, 10'd286, 9'd52, 2'd1);
    wire t_p0_c2_v1 = (page == 2'd0) && (audio_active ?
        text_pixel(10, px, py, 10'd286, 9'd68, 2'd1) :
        text_pixel(11, px, py, 10'd286, 9'd68, 2'd1));

    // Card 2 硬件音量指示条与标签 (x: 286..510, y: 84..94)
    wire t_p0_vol_lbl = (page == 2'd0) && text_pixel(7'd80, px, py, 10'd286, 9'd86, 2'd1);
    wire p0_vol_bar_box = (page == 2'd0) && (px >= 10'd316 && px <= 10'd510 && py >= 9'd85 && py <= 9'd93);
    wire p0_vol_bar_border = (page == 2'd0) && (
        ((px == 10'd316 || px == 10'd510) && py >= 9'd85 && py <= 9'd93) ||
        ((py == 9'd85 || py == 9'd93) && px >= 10'd316 && px <= 10'd510)
    );
    wire [7:0] p0_vol_fill_w = master_vol + (master_vol >> 1);
    wire p0_vol_bar_fill = (page == 2'd0) && (px >= 10'd318 && px <= (10'd318 + {2'b0, p0_vol_fill_w}) && py >= 9'd87 && py <= 9'd91) && (master_vol != 7'd0);

    wire t_p0_c3_t  = (page == 2'd0) && text_pixel(12, px, py, 10'd542, 9'd52, 2'd1);
    wire t_p0_c3_v1 = (page == 2'd0) && text_pixel(13, px, py, 10'd542, 9'd68, 2'd1);
    wire t_p0_c3_v2 = (page == 2'd0) && text_pixel(14, px, py, 10'd542, 9'd86, 2'd1);

    // 左侧大示波器: x: 20..440, y: 114..468 (高 354px, 宽 420px)
    wire p0_scope_box = (page == 2'd0) && (px >= 10'd20 && px <= 10'd440 && py >= 9'd114 && py <= 9'd468);
    wire p0_scope_border = (page == 2'd0) && (
        ((px == 10'd20 || px == 10'd440) && py >= 9'd114 && py <= 9'd468) ||
        ((py == 9'd114 || py == 9'd468) && px >= 10'd20 && px <= 10'd440)
    );
    wire t_p0_scp_hdr = (page == 2'd0) && text_pixel(15, px, py, 10'd32,  9'd122, 2'd1);
    wire t_p0_scp_dac = (page == 2'd0) && text_pixel(16, px, py, 10'd348, 9'd122, 2'd1);
    wire t_p0_silent  = 1'b0; // Continuous live scope, no popup silence overlay

    wire p0_scope_grid = p0_scope_box && (
        (((px - 10'd20) % 10'd42 == 0) && py >= 9'd140 && py <= 9'd460) ||
        (((py - 9'd140) % 9'd40 == 0) && px >= 10'd20 && px <= 10'd440)
    );
    wire p0_scope_zero = p0_scope_box && (py == 9'd300);

    wire [8:0] p0_y_lo = (scope_wave_y < scope_prev_y) ? scope_wave_y : scope_prev_y;
    wire [8:0] p0_y_hi = (scope_wave_y > scope_prev_y) ? scope_wave_y : scope_prev_y;
    wire p0_wave_hit   = (page == 2'd0) && p0_scope_box &&
                         (py >= p0_y_lo) && (py <= p0_y_hi) && (py >= 9'd140 && py <= 9'd460);
    wire p0_wave_edge  = (page == 2'd0) && p0_scope_box &&
                         ((py == p0_y_lo) || (py == p0_y_hi)) &&
                         (py >= 9'd140 && py <= 9'd460);

    // 右上区: 立体声 VU 表与 ADSR 包络 (x: 456..778, y: 114..280)
    wire p0_vu_panel  = (page == 2'd0) && (px >= 10'd456 && px <= 10'd778 && py >= 9'd114 && py <= 9'd280);
    wire p0_vu_border = (page == 2'd0) && (
        ((px == 10'd456 || px == 10'd778) && py >= 9'd114 && py <= 9'd280) ||
        ((py == 9'd114 || py == 9'd280) && px >= 10'd456 && px <= 10'd778)
    );
    wire t_p0_vu_hdr = (page == 2'd0) && text_pixel(18, px, py, 10'd468, 9'd122, 2'd1);
    wire t_p0_vu_l   = (page == 2'd0) && text_pixel(19, px, py, 10'd468, 9'd142, 2'd1);
    wire t_p0_vu_r   = (page == 2'd0) && text_pixel(20, px, py, 10'd468, 9'd160, 2'd1);
    wire t_p0_vu_scl = (page == 2'd0) && text_pixel(21, px, py, 10'd486, 9'd178, 2'd1);

    // VU 动态电平条: 16 段
    wire [9:0] vu_p0_w = (vu_level * 10'd270) >> 8;
    wire p0_vu_l_bar = (page == 2'd0) && (px >= 10'd486 && px <= 10'd758) && (py >= 9'd142 && py <= 9'd154) && ((px - 10'd486) % 10'd17 < 10'd13);
    wire p0_vu_r_bar = (page == 2'd0) && (px >= 10'd486 && px <= 10'd758) && (py >= 9'd160 && py <= 9'd172) && ((px - 10'd486) % 10'd17 < 10'd13);
    wire p0_vu_hit   = (p0_vu_l_bar || p0_vu_r_bar) && (px - 10'd486 < vu_p0_w);

    // ADSR 分界线与曲线 (16 位防溢出平滑曲线)
    wire p0_adsr_sep  = (page == 2'd0) && (px >= 10'd468 && px <= 10'd766 && py == 9'd194);
    wire t_p0_adsr    = (page == 2'd0) && text_pixel(22, px, py, 10'd468, 9'd198, 2'd1);

    wire [8:0] adsr_y_atk = 9'd268 - (({6'd0, px - 10'd486} * 16'd46) / 16'd34);
    wire [8:0] adsr_y_dec = 9'd222 + (({6'd0, px - 10'd520} * 16'd18) / 16'd60);
    wire [8:0] adsr_y_rel = 9'd240 + (({6'd0, px - 10'd690} * 16'd28) / 16'd60);
    wire [8:0] adsr_target_y = (px < 10'd520) ? adsr_y_atk :
                               (px < 10'd580) ? adsr_y_dec :
                               (px < 10'd690) ? 9'd240 : adsr_y_rel;

    wire p0_adsr_line = (page == 2'd0) && (px >= 10'd486 && px <= 10'd750) &&
                        (py >= adsr_target_y - 9'd1 && py <= adsr_target_y + 9'd1);
    wire p0_adsr_fill = (page == 2'd0) && (px >= 10'd486 && px <= 10'd750) &&
                        (py > adsr_target_y + 9'd1 && py <= 9'd268);

    // 右下区: 紧凑型 1-Octave 触摸钢琴 (x: 456..778, y: 294..468, 宽 322px)
    wire p0_piano_box = (page == 2'd0) && (px >= 10'd456 && px <= 10'd778 && py >= 9'd294 && py <= 9'd468);
    wire p0_piano_border = (page == 2'd0) && (
        ((px == 10'd456 || px == 10'd778) && py >= 9'd294 && py <= 9'd468) ||
        ((py == 9'd294 || py == 9'd468) && px >= 10'd456 && px <= 10'd778)
    );
    wire any_key_active = note_active || (|key_active_mask);
    wire t_p0_piano_hdr = (page == 2'd0) && (any_key_active ?
        text_pixel(23, px, py, 10'd468, 9'd302, 2'd1) :
        text_pixel(24, px, py, 10'd468, 9'd302, 2'd1));

    // 7 个白键: x = 460 + i * 45, 宽度 43px, 高度 y: 322..458
    wire [8:0] pkx = (px >= 10'd460 && px <= 10'd773) ? (px - 10'd460) : 9'd0;
    wire [2:0] p0_w_idx = pkx / 10'd45;
    wire in_white_area = (page == 2'd0) && (px >= 10'd460 && px <= 10'd773 && py >= 9'd322 && py <= 9'd458);

    wire white_border = in_white_area && (
        (pkx % 10'd45 <= 10'd1) || (pkx % 10'd45 >= 10'd42) ||
        (py <= 9'd323) || (py >= 9'd457)
    );

    // 5 个黑键: 宽度 24px, 高度 y: 322..402
    // 中心点: C-D(504), D-E(549), F-G(639), G-A(684), A-B(729)
    wire black_c_d = (px >= 10'd492 && px <= 10'd516);
    wire black_d_e = (px >= 10'd537 && px <= 10'd561);
    wire black_f_g = (px >= 10'd627 && px <= 10'd651);
    wire black_g_a = (px >= 10'd672 && px <= 10'd696);
    wire black_a_b = (px >= 10'd717 && px <= 10'd741);

    wire in_black_area = (page == 2'd0) && (py >= 9'd322 && py <= 9'd402) &&
                         (black_c_d || black_d_e || black_f_g || black_g_a || black_a_b);

    wire black_border = in_black_area && (
        (py <= 9'd323) || (py >= 9'd401) ||
        (px == 10'd492 || px == 10'd516) ||
        (px == 10'd537 || px == 10'd561) ||
        (px == 10'd627 || px == 10'd651) ||
        (px == 10'd672 || px == 10'd696) ||
        (px == 10'd717 || px == 10'd741)
    );

    // 实时按键点亮逻辑 (映射 C=0, C#=1, D=2, D#=3, E=4, F=5, F#=6, G=7, G#=8, A=9, A#=10, B=11)
    // 支持全声部真实发声追踪、延音踏板发声状态、及多音和弦同时点亮
    wire is_active_key = (page == 2'd0) && (
        (in_black_area && (
            (key_active_mask[1]  && black_c_d) ||
            (key_active_mask[3]  && black_d_e) ||
            (key_active_mask[6]  && black_f_g) ||
            (key_active_mask[8]  && black_g_a) ||
            (key_active_mask[10] && black_a_b)
        )) ||
        (!in_black_area && in_white_area && (
            (key_active_mask[0]  && p0_w_idx == 3'd0) ||
            (key_active_mask[2]  && p0_w_idx == 3'd1) ||
            (key_active_mask[4]  && p0_w_idx == 3'd2) ||
            (key_active_mask[5]  && p0_w_idx == 3'd3) ||
            (key_active_mask[7]  && p0_w_idx == 3'd4) ||
            (key_active_mask[9]  && p0_w_idx == 3'd5) ||
            (key_active_mask[11] && p0_w_idx == 3'd6)
        ))
    );

    // 琴键音符标签文字
    wire t_pk_w0 = text_pixel(25, px, py, 10'd474, 9'd440, 2'd1);
    wire t_pk_w1 = text_pixel(26, px, py, 10'd519, 9'd440, 2'd1);
    wire t_pk_w2 = text_pixel(27, px, py, 10'd564, 9'd440, 2'd1);
    wire t_pk_w3 = text_pixel(28, px, py, 10'd609, 9'd440, 2'd1);
    wire t_pk_w4 = text_pixel(29, px, py, 10'd654, 9'd440, 2'd1);
    wire t_pk_w5 = text_pixel(30, px, py, 10'd699, 9'd440, 2'd1);
    wire t_pk_w6 = text_pixel(31, px, py, 10'd744, 9'd440, 2'd1);
    wire t_pk_w_all = t_pk_w0 || t_pk_w1 || t_pk_w2 || t_pk_w3 || t_pk_w4 || t_pk_w5 || t_pk_w6;

    wire t_pk_b0 = text_pixel(32, px, py, 10'd497, 9'd386, 2'd1);
    wire t_pk_b1 = text_pixel(33, px, py, 10'd542, 9'd386, 2'd1);
    wire t_pk_b2 = text_pixel(34, px, py, 10'd632, 9'd386, 2'd1);
    wire t_pk_b3 = text_pixel(35, px, py, 10'd677, 9'd386, 2'd1);
    wire t_pk_b4 = text_pixel(36, px, py, 10'd722, 9'd386, 2'd1);
    wire t_pk_b_all = t_pk_b0 || t_pk_b1 || t_pk_b2 || t_pk_b3 || t_pk_b4;

    // -------------------------------------------------------------------------
    // PAGE 1: 实时波形与 FFT 频谱 (WAVE & FFT DASHBOARD)
    // -------------------------------------------------------------------------
    wire p1_scope_box = (page == 2'd1) && (px >= 10'd20 && px <= 10'd778 && py >= 9'd44 && py <= 9'd244);
    wire p1_scope_border = (page == 2'd1) && (
        ((px == 10'd20 || px == 10'd778) && py >= 9'd44 && py <= 9'd244) ||
        ((py == 9'd44 || py == 9'd244) && px >= 10'd20 && px <= 10'd778)
    );
    wire t_p1_scp_hdr = (page == 2'd1) && text_pixel(15, px, py, 10'd32,  9'd52, 2'd1);
    wire t_p1_scp_scl = (page == 2'd1) && text_pixel(37, px, py, 10'd620, 9'd52, 2'd1);
    wire t_p1_silent  = 1'b0; // Continuous live scope

    wire p1_scope_grid = p1_scope_box && (
        (((px - 10'd20) % 10'd76 == 0) && py >= 9'd68 && py <= 9'd240) ||
        (((py - 9'd68) % 9'd34 == 0) && px >= 10'd20 && px <= 10'd778)
    );
    wire p1_scope_zero = p1_scope_box && (py == 9'd154);

    wire [8:0] p1_y_lo = (scope_wave_y < scope_prev_y) ? scope_wave_y : scope_prev_y;
    wire [8:0] p1_y_hi = (scope_wave_y > scope_prev_y) ? scope_wave_y : scope_prev_y;
    wire p1_wave_hit   = (page == 2'd1) && p1_scope_box &&
                         (py >= p1_y_lo) && (py <= p1_y_hi) && (py >= 9'd68 && py <= 9'd240);
    wire p1_wave_edge  = (page == 2'd1) && p1_scope_box &&
                         ((py == p1_y_lo) || (py == p1_y_hi)) &&
                         (py >= 9'd68 && py <= 9'd240);

    // 下半区: 760px 全宽 32 段 FFT 频谱仪 (x: 20..778, y: 254..468)
    wire p1_spec_box = (page == 2'd1) && (px >= 10'd20 && px <= 10'd778 && py >= 9'd254 && py <= 9'd468);
    wire p1_spec_border = (page == 2'd1) && (
        ((px == 10'd20 || px == 10'd778) && py >= 9'd254 && py <= 9'd468) ||
        ((py == 9'd254 || py == 9'd468) && px >= 10'd20 && px <= 10'd778)
    );
    wire t_p1_spec_hdr = (page == 2'd1) && text_pixel(39, px, py, 10'd32,  9'd262, 2'd1);
    wire t_p1_spec_rng = (page == 2'd1) && text_pixel(40, px, py, 10'd640, 9'd262, 2'd1);

    wire [4:0] p1_bar_idx = (px >= 10'd36 && px <= 10'd764) ? ((px - 10'd36) / 10'd23) : 5'd0;
    wire [8:0] p1_bar_h = (!audio_active || vu_level <= 8'd2) ? 9'd0 :
        (9'd6 + (((vu_level * (32 - p1_bar_idx)) >> 6)) + ((p1_bar_idx == (live_note % 32)) ? 9'd85 : 9'd0));

    wire p1_bar_hit = (page == 2'd1) && p1_spec_box && (p1_bar_h > 9'd0) &&
                      (px >= 10'd36 && px <= 10'd764) &&
                      (((px - 10'd36) % 10'd23) < 10'd18) &&
                      (py >= 9'd432 - p1_bar_h) && (py <= 9'd432);

    wire p1_spec_base = (page == 2'd1) && (px >= 10'd36 && px <= 10'd764) && (py == 9'd432);
    wire p1_spec_ticks = (page == 2'd1) && (py >= 9'd432 && py <= 9'd437) && (
        px == 10'd45  || px == 10'd137 || px == 10'd229 || px == 10'd321 ||
        px == 10'd413 || px == 10'd505 || px == 10'd597 || px == 10'd689 || px == 10'd758
    );

    wire t_f0 = text_pixel(41, px, py, 10'd36,  9'd440, 2'd1); // 50HZ
    wire t_f1 = text_pixel(42, px, py, 10'd125, 9'd440, 2'd1); // 125HZ
    wire t_f2 = text_pixel(43, px, py, 10'd217, 9'd440, 2'd1); // 250HZ
    wire t_f3 = text_pixel(44, px, py, 10'd309, 9'd440, 2'd1); // 500HZ
    wire t_f4 = text_pixel(45, px, py, 10'd405, 9'd440, 2'd1); // 1KHZ
    wire t_f5 = text_pixel(46, px, py, 10'd497, 9'd440, 2'd1); // 2KHZ
    wire t_f6 = text_pixel(47, px, py, 10'd589, 9'd440, 2'd1); // 4KHZ
    wire t_f7 = text_pixel(48, px, py, 10'd681, 9'd440, 2'd1); // 8KHZ
    wire t_f8 = text_pixel(49, px, py, 10'd745, 9'd440, 2'd1); // 16KHZ
    wire t_p1_freqs = t_f0 || t_f1 || t_f2 || t_f3 || t_f4 || t_f5 || t_f6 || t_f7 || t_f8;

    // -------------------------------------------------------------------------
    // PAGE 2: 32 路振荡器测试界面 (32-VOICE BENCHMARK - REFINED v2)
    // -------------------------------------------------------------------------
    wire p2_c1_box = (page == 2'd2) && (px >= 10'd20  && px <= 10'd266 && py >= 9'd44 && py <= 9'd104);
    wire p2_c2_box = (page == 2'd2) && (px >= 10'd276 && px <= 10'd522 && py >= 9'd44 && py <= 9'd104);
    wire p2_c3_box = (page == 2'd2) && (px >= 10'd532 && px <= 10'd778 && py >= 9'd44 && py <= 9'd104);

    wire p2_c1_border = (page == 2'd2) && (
        ((px == 10'd20 || px == 10'd266) && py >= 9'd44 && py <= 9'd104) ||
        ((py == 9'd44 || py == 9'd104) && px >= 10'd20 && px <= 10'd266)
    );
    wire p2_c2_border = (page == 2'd2) && (
        ((px == 10'd276 || px == 10'd522) && py >= 9'd44 && py <= 9'd104) ||
        ((py == 9'd44 || py == 9'd104) && px >= 10'd276 && px <= 10'd522)
    );
    wire p2_c3_border = (page == 2'd2) && (
        ((px == 10'd532 || px == 10'd778) && py >= 9'd44 && py <= 9'd104) ||
        ((py == 9'd44 || py == 9'd104) && px >= 10'd532 && px <= 10'd778)
    );

    wire p2_c1_strip = p2_c1_box && (py >= 9'd44 && py <= 9'd46);
    wire p2_c2_strip = p2_c2_box && (py >= 9'd44 && py <= 9'd46);
    wire p2_c3_strip = p2_c3_box && (py >= 9'd44 && py <= 9'd46);

    wire t_p2_c1_t  = (page == 2'd2) && text_pixel(50, px, py, 10'd30,  9'd52, 2'd1);
    wire t_p2_c1_v1 = (page == 2'd2) && text_pixel(51, px, py, 10'd30,  9'd68, 2'd1);
    wire t_p2_c1_v2 = (page == 2'd2) && text_pixel(52, px, py, 10'd30,  9'd86, 2'd1);

    wire t_p2_c2_t  = (page == 2'd2) && text_pixel(53, px, py, 10'd286, 9'd52, 2'd1);
    wire t_p2_c2_v1 = (page == 2'd2) && text_pixel(54, px, py, 10'd286, 9'd68, 2'd1);
    wire t_p2_c2_v2 = (page == 2'd2) && text_pixel(55, px, py, 10'd286, 9'd86, 2'd1);

    wire t_p2_c3_t  = (page == 2'd2) && text_pixel(56, px, py, 10'd542, 9'd52, 2'd1);
    wire t_p2_c3_v1 = (page == 2'd2) && text_pixel(57, px, py, 10'd542, 9'd68, 2'd1);
    wire t_p2_c3_v2 = (page == 2'd2) && text_pixel(58, px, py, 10'd542, 9'd86, 2'd1);

    // 中部: 32 个振荡器阵列 (x: 20..778, y: 114..246)
    wire p2_osc_box = (page == 2'd2) && (px >= 10'd20 && px <= 10'd778 && py >= 9'd114 && py <= 9'd246);
    wire p2_osc_border = (page == 2'd2) && (
        ((px == 10'd20 || px == 10'd778) && py >= 9'd114 && py <= 9'd246) ||
        ((py == 9'd114 || py == 9'd246) && px >= 10'd20 && px <= 10'd778)
    );
    wire t_p2_osc_hdr = (page == 2'd2) && text_pixel(59, px, py, 10'd32, 9'd122, 2'd1);

    wire [9:0] p2_cx = (px - 10'd32) % 10'd92;
    wire [8:0] p2_cy = (py - 9'd140) % 9'd25;
    wire in_osc_cell = (page == 2'd2) && (px >= 10'd32 && px <= 10'd764 && py >= 9'd140 && py <= 9'd238) &&
                       (p2_cx < 10'd86) && (p2_cy < 9'd21);

    wire osc_cell_border = in_osc_cell && (p2_cx == 10'd0 || p2_cx == 10'd85 || p2_cy == 9'd0 || p2_cy == 9'd20);
    wire osc_green_led   = in_osc_cell && (p2_cx >= 10'd6 && p2_cx <= 10'd11 && p2_cy >= 9'd7 && p2_cy <= 9'd13);

    wire [1:0] p2_cell_r = (py < 9'd165) ? 2'd0 :
                           (py < 9'd190) ? 2'd1 :
                           (py < 9'd215) ? 2'd2 : 2'd3;
    wire [2:0] p2_cell_c = (px < 10'd124) ? 3'd0 :
                           (px < 10'd216) ? 3'd1 :
                           (px < 10'd308) ? 3'd2 :
                           (px < 10'd400) ? 3'd3 :
                           (px < 10'd492) ? 3'd4 :
                           (px < 10'd584) ? 3'd5 :
                           (px < 10'd676) ? 3'd6 : 3'd7;
    wire [4:0] p2_voice_idx = {p2_cell_r, p2_cell_c};
    wire [9:0] p2_tx = (p2_cx >= 10'd16) ? (p2_cx - 10'd16) : 10'd0;
    wire [8:0] p2_ty = (p2_cy >= 9'd7)  ? (p2_cy - 9'd7)   : 9'd0;
    wire [3:0] p2_char_pos = p2_tx / 10'd6;
    wire [2:0] p2_c_col    = p2_tx % 10'd6;
    wire [2:0] p2_c_row    = p2_ty[2:0];
    wire [7:0] p2_cell_ch  = get_osc_char(p2_voice_idx, p2_char_pos);
    wire osc_text_hit = in_osc_cell && (p2_cx >= 10'd16 && p2_cx <= 10'd75 && p2_cy >= 9'd7 && p2_cy <= 9'd13) &&
                        (p2_c_col < 3'd5) && font_dot(p2_cell_ch, p2_c_col, p2_c_row);

    // 下半部: 32 个独立谱峰取证区 (x: 20..778, y: 256..468)
    wire p2_peak_box = (page == 2'd2) && (px >= 10'd20 && px <= 10'd778 && py >= 9'd256 && py <= 9'd468);
    wire p2_peak_border = (page == 2'd2) && (
        ((px == 10'd20 || px == 10'd778) && py >= 9'd256 && py <= 9'd468) ||
        ((py == 9'd256 || py == 9'd468) && px >= 10'd20 && px <= 10'd778)
    );

    // 独立标题带 (y: 256..282) -> 彻底与下方的谱峰隔离！
    wire p2_hdr_band = (page == 2'd2) && (px >= 10'd20 && px <= 10'd778 && py >= 9'd256 && py <= 9'd282);
    wire p2_hdr_line = (page == 2'd2) && (px >= 10'd20 && px <= 10'd778 && py == 9'd282);
    wire t_p2_pk_hdr = (page == 2'd2) && text_pixel(60, px, py, 10'd32,  9'd264, 2'd1);
    wire t_p2_pk_det = (page == 2'd2) && text_pixel(61, px, py, 10'd640, 9'd264, 2'd1);

    // 32 根独立谱线针状柱 (基线 y = 434, 顶点不超过 315)
    wire p2_peak_base = (page == 2'd2) && (px >= 10'd36 && px <= 10'd764 && py == 9'd434);
    wire [4:0] p2_needle_idx = (px - 10'd36) / 10'd23;
    wire [8:0] p2_needle_h = 9'd75 + ((p2_needle_idx[2:0] * 9'd5) ^ (p2_needle_idx[4:3] * 9'd10));
    wire p2_needle_stem = (page == 2'd2) && (px >= 10'd36 && px <= 10'd764) &&
                          (((px - 10'd36) % 10'd23) == 10'd11) &&
                          (py >= 9'd434 - p2_needle_h && py <= 9'd434);
    wire p2_needle_dot  = (page == 2'd2) && (px >= 10'd36 && px <= 10'd764) &&
                          (((px - 10'd36) % 10'd23) >= 10'd9 && ((px - 10'd36) % 10'd23) <= 10'd13) &&
                          (py >= 9'd434 - p2_needle_h - 9'd3 && py <= 9'd434 - p2_needle_h + 9'd1);

    // 底部频率刻度与文本 (y: 434..462)
    wire p2_freq_ticks = (page == 2'd2) && (py >= 9'd434 && py <= 9'd439) && (
        px == 10'd47  || px == 10'd139 || px == 10'd231 || px == 10'd323 ||
        px == 10'd415 || px == 10'd507 || px == 10'd599 || px == 10'd691 || px == 10'd760
    );

    wire t_p2_f0 = text_pixel(62, px, py, 10'd36,  9'd444, 2'd1); // 65HZ
    wire t_p2_f1 = text_pixel(63, px, py, 10'd130, 9'd444, 2'd1); // 130
    wire t_p2_f2 = text_pixel(64, px, py, 10'd222, 9'd444, 2'd1); // 260
    wire t_p2_f3 = text_pixel(65, px, py, 10'd314, 9'd444, 2'd1); // 520
    wire t_p2_f4 = text_pixel(66, px, py, 10'd406, 9'd444, 2'd1); // 1KHZ
    wire t_p2_f5 = text_pixel(67, px, py, 10'd498, 9'd444, 2'd1); // 2KHZ
    wire t_p2_f6 = text_pixel(68, px, py, 10'd590, 9'd444, 2'd1); // 4KHZ
    wire t_p2_f7 = text_pixel(69, px, py, 10'd682, 9'd444, 2'd1); // 8KHZ
    wire t_p2_f8 = text_pixel(70, px, py, 10'd750, 9'd444, 2'd1); // 12K
    wire t_p2_freqs = t_p2_f0 || t_p2_f1 || t_p2_f2 || t_p2_f3 || t_p2_f4 || t_p2_f5 || t_p2_f6 || t_p2_f7 || t_p2_f8;

    // -------------------------------------------------------------------------
    // PAGE 3: 曲目播放界面 (SONG PLAYER DASHBOARD)
    // -------------------------------------------------------------------------
    wire p3_banner_box = (page == 2'd3) && (px >= 10'd20 && px <= 10'd778 && py >= 9'd44 && py <= 9'd120);
    wire p3_banner_border = (page == 2'd3) && (
        ((px == 10'd20 || px == 10'd778) && py >= 9'd44 && py <= 9'd120) ||
        ((py == 9'd44 || py == 9'd120) && px >= 10'd20 && px <= 10'd778)
    );
    wire p3_banner_strip = p3_banner_box && (py >= 9'd44 && py <= 9'd46);

    wire t_p3_tr_idx = (page == 2'd3) && text_pixel(71, px, py, 10'd32, 9'd54, 2'd1);
    wire t_p3_tr_nam = (page == 2'd3) && text_pixel(72, px, py, 10'd32, 9'd70, 2'd2); // 放大 2x
    wire t_p3_tr_inf = (page == 2'd3) && text_pixel(73, px, py, 10'd32, 9'd94, 2'd1);

    wire p3_prog_panel = (page == 2'd3) && (px >= 10'd20 && px <= 10'd778 && py >= 9'd130 && py <= 9'd220);
    wire p3_prog_border = (page == 2'd3) && (
        ((px == 10'd20 || px == 10'd778) && py >= 9'd130 && py <= 9'd220) ||
        ((py == 9'd130 || py == 9'd220) && px >= 10'd20 && px <= 10'd778)
    );
    wire t_p3_pr_txt = (page == 2'd3) && text_pixel(74, px, py, 10'd32,  9'd138, 2'd1);
    wire t_p3_pr_key = (page == 2'd3) && text_pixel(75, px, py, 10'd600, 9'd138, 2'd1);
    wire t_p3_pr_hdl = (page == 2'd3) && text_pixel(76, px, py, 10'd32,  9'd196, 2'd1);

    wire [7:0] cur_sec_d10 = (song_elapsed_sec >= 8'd50) ? 8'd5 :
                             (song_elapsed_sec >= 8'd40) ? 8'd4 :
                             (song_elapsed_sec >= 8'd30) ? 8'd3 :
                             (song_elapsed_sec >= 8'd20) ? 8'd2 :
                             (song_elapsed_sec >= 8'd10) ? 8'd1 : 8'd0;
    wire [7:0] cur_sec_rem = song_elapsed_sec - (cur_sec_d10 * 8'd10);

    wire [7:0] tot_sec_d10 = (song_total_sec >= 8'd50) ? 8'd5 :
                             (song_total_sec >= 8'd40) ? 8'd4 :
                             (song_total_sec >= 8'd30) ? 8'd3 :
                             (song_total_sec >= 8'd20) ? 8'd2 :
                             (song_total_sec >= 8'd10) ? 8'd1 : 8'd0;
    wire [7:0] tot_sec_rem = song_total_sec - (tot_sec_d10 * 8'd10);

    wire [7:0] pct_val = (song_progress > 8'd100) ? 8'd100 : song_progress;
    wire [7:0] pct_d100 = (pct_val >= 8'd100) ? 8'd1 : 8'd0;
    wire [7:0] pct_rem100 = pct_val - (pct_d100 ? 8'd100 : 8'd0);
    wire [7:0] pct_d10 = (pct_rem100 >= 8'd90) ? 8'd9 :
                         (pct_rem100 >= 8'd80) ? 8'd8 :
                         (pct_rem100 >= 8'd70) ? 8'd7 :
                         (pct_rem100 >= 8'd60) ? 8'd6 :
                         (pct_rem100 >= 8'd50) ? 8'd5 :
                         (pct_rem100 >= 8'd40) ? 8'd4 :
                         (pct_rem100 >= 8'd30) ? 8'd3 :
                         (pct_rem100 >= 8'd20) ? 8'd2 :
                         (pct_rem100 >= 8'd10) ? 8'd1 : 8'd0;
    wire [7:0] pct_rem10 = pct_rem100 - (pct_d10 * 8'd10);

    wire [17:0] fill_prod = {10'd0, song_progress} * 18'd732;
    wire [9:0] p3_fill_x = 10'd32 + (fill_prod / 18'd100);
    wire p3_bar_box = (page == 2'd3) && (px >= 10'd32 && px <= 10'd764 && py >= 9'd160 && py <= 9'd186);
    wire p3_bar_border = p3_bar_box && (px == 10'd32 || px == 10'd764 || py == 9'd160 || py == 9'd186);
    wire p3_bar_fill   = p3_bar_box && (px <= p3_fill_x) && (py >= 9'd162 && py <= 9'd184);
    wire p3_bar_head   = p3_bar_box && (px >= p3_fill_x - 10'd3 && px <= p3_fill_x + 10'd3);

    wire p3_score_box = (page == 2'd3) && (px >= 10'd20 && px <= 10'd778 && py >= 9'd230 && py <= 9'd468);
    wire p3_score_border = (page == 2'd3) && (
        ((px == 10'd20 || px == 10'd778) && py >= 9'd230 && py <= 9'd468) ||
        ((py == 9'd230 || py == 9'd468) && px >= 10'd20 && px <= 10'd778)
    );
    wire t_p3_sc_hdr = (page == 2'd3) && text_pixel(77, px, py, 10'd32,  9'd238, 2'd1);
    wire t_p3_sc_mel = (page == 2'd3) && text_pixel(78, px, py, 10'd560, 9'd238, 2'd1);
    wire t_p3_sc_ply = (page == 2'd3) && text_pixel(79, px, py, 10'd345, 9'd426, 2'd1);

    wire p3_stave = (page == 2'd3) && p3_score_box && (
        py == 9'd280 || py == 9'd305 || py == 9'd330 || py == 9'd355 || py == 9'd380
    ) && (px >= 10'd32 && px <= 10'd764);

    wire p3_playhead = (page == 2'd3) && (px == 10'd360) && (py >= 9'd260 && py <= 9'd420);

    // -------------------------------------------------------------------------
    // Real-Time Dynamic Scrolling Score Engine (8 Slots, Smooth Continuous Scroll)
    // -------------------------------------------------------------------------
    wire [8:0] s_idx_0 = (song_note_idx >= 9'd2) ? (song_note_idx - 9'd2) : 9'd511;
    wire [8:0] s_idx_1 = (song_note_idx >= 9'd1) ? (song_note_idx - 9'd1) : 9'd511;
    wire [8:0] s_idx_2 = song_note_idx;
    wire [8:0] s_idx_3 = song_note_idx + 9'd1;
    wire [8:0] s_idx_4 = song_note_idx + 9'd2;
    wire [8:0] s_idx_5 = song_note_idx + 9'd3;
    wire [8:0] s_idx_6 = song_note_idx + 9'd4;
    wire [8:0] s_idx_7 = song_note_idx + 9'd5;

    wire [6:0] s_note_0 = get_song_note(song_index, s_idx_0);
    wire [6:0] s_note_1 = get_song_note(song_index, s_idx_1);
    wire [6:0] s_note_2 = get_song_note(song_index, s_idx_2);
    wire [6:0] s_note_3 = get_song_note(song_index, s_idx_3);
    wire [6:0] s_note_4 = get_song_note(song_index, s_idx_4);
    wire [6:0] s_note_5 = get_song_note(song_index, s_idx_5);
    wire [6:0] s_note_6 = get_song_note(song_index, s_idx_6);
    wire [6:0] s_note_7 = get_song_note(song_index, s_idx_7);

    wire [8:0] s_y_0 = note_to_y(s_note_0);
    wire [8:0] s_y_1 = note_to_y(s_note_1);
    wire [8:0] s_y_2 = note_to_y(s_note_2);
    wire [8:0] s_y_3 = note_to_y(s_note_3);
    wire [8:0] s_y_4 = note_to_y(s_note_4);
    wire [8:0] s_y_5 = note_to_y(s_note_5);
    wire [8:0] s_y_6 = note_to_y(s_note_6);
    wire [8:0] s_y_7 = note_to_y(s_note_7);

    wire [8:0] s_yb_0 = note_to_y(s_note_0 >= 7'd60 ? (s_note_0 - 7'd12) : s_note_0);
    wire [8:0] s_yb_1 = note_to_y(s_note_1 >= 7'd60 ? (s_note_1 - 7'd12) : s_note_1);
    wire [8:0] s_yb_2 = note_to_y(s_note_2 >= 7'd60 ? (s_note_2 - 7'd12) : s_note_2);
    wire [8:0] s_yb_3 = note_to_y(s_note_3 >= 7'd60 ? (s_note_3 - 7'd12) : s_note_3);
    wire [8:0] s_yb_4 = note_to_y(s_note_4 >= 7'd60 ? (s_note_4 - 7'd12) : s_note_4);
    wire [8:0] s_yb_5 = note_to_y(s_note_5 >= 7'd60 ? (s_note_5 - 7'd12) : s_note_5);
    wire [8:0] s_yb_6 = note_to_y(s_note_6 >= 7'd60 ? (s_note_6 - 7'd12) : s_note_6);
    wire [8:0] s_yb_7 = note_to_y(s_note_7 >= 7'd60 ? (s_note_7 - 7'd12) : s_note_7);

    // Continuous X coordinates: 360 + (slot - 2)*60 - sub_scroll
    wire signed [11:0] s_x_0 = 12'sd240 - $signed({6'd0, song_sub_scroll});
    wire signed [11:0] s_x_1 = 12'sd300 - $signed({6'd0, song_sub_scroll});
    wire signed [11:0] s_x_2 = 12'sd360 - $signed({6'd0, song_sub_scroll});
    wire signed [11:0] s_x_3 = 12'sd420 - $signed({6'd0, song_sub_scroll});
    wire signed [11:0] s_x_4 = 12'sd480 - $signed({6'd0, song_sub_scroll});
    wire signed [11:0] s_x_5 = 12'sd540 - $signed({6'd0, song_sub_scroll});
    wire signed [11:0] s_x_6 = 12'sd600 - $signed({6'd0, song_sub_scroll});
    wire signed [11:0] s_x_7 = 12'sd660 - $signed({6'd0, song_sub_scroll});

    wire signed [11:0] px_s = $signed({2'b00, px});

    wire hit_m_0 = (page == 2'd3) && (s_y_0 != 9'd0) && (px_s >= s_x_0 - 12'sd18 && px_s <= s_x_0 + 12'sd18) && (py >= s_y_0 - 9'd7 && py <= s_y_0 + 9'd7) && (px >= 10'd32 && px <= 10'd764);
    wire hit_m_1 = (page == 2'd3) && (s_y_1 != 9'd0) && (px_s >= s_x_1 - 12'sd18 && px_s <= s_x_1 + 12'sd18) && (py >= s_y_1 - 9'd7 && py <= s_y_1 + 9'd7) && (px >= 10'd32 && px <= 10'd764);
    wire hit_m_2 = (page == 2'd3) && (s_y_2 != 9'd0) && (px_s >= s_x_2 - 12'sd18 && px_s <= s_x_2 + 12'sd18) && (py >= s_y_2 - 9'd7 && py <= s_y_2 + 9'd7) && (px >= 10'd32 && px <= 10'd764);
    wire hit_m_3 = (page == 2'd3) && (s_y_3 != 9'd0) && (px_s >= s_x_3 - 12'sd18 && px_s <= s_x_3 + 12'sd18) && (py >= s_y_3 - 9'd7 && py <= s_y_3 + 9'd7) && (px >= 10'd32 && px <= 10'd764);
    wire hit_m_4 = (page == 2'd3) && (s_y_4 != 9'd0) && (px_s >= s_x_4 - 12'sd18 && px_s <= s_x_4 + 12'sd18) && (py >= s_y_4 - 9'd7 && py <= s_y_4 + 9'd7) && (px >= 10'd32 && px <= 10'd764);
    wire hit_m_5 = (page == 2'd3) && (s_y_5 != 9'd0) && (px_s >= s_x_5 - 12'sd18 && px_s <= s_x_5 + 12'sd18) && (py >= s_y_5 - 9'd7 && py <= s_y_5 + 9'd7) && (px >= 10'd32 && px <= 10'd764);
    wire hit_m_6 = (page == 2'd3) && (s_y_6 != 9'd0) && (px_s >= s_x_6 - 12'sd18 && px_s <= s_x_6 + 12'sd18) && (py >= s_y_6 - 9'd7 && py <= s_y_6 + 9'd7) && (px >= 10'd32 && px <= 10'd764);
    wire hit_m_7 = (page == 2'd3) && (s_y_7 != 9'd0) && (px_s >= s_x_7 - 12'sd18 && px_s <= s_x_7 + 12'sd18) && (py >= s_y_7 - 9'd7 && py <= s_y_7 + 9'd7) && (px >= 10'd32 && px <= 10'd764);

    wire hit_b_0 = (page == 2'd3) && (s_yb_0 != 9'd0) && (px_s >= s_x_0 - 12'sd22 && px_s <= s_x_0 + 12'sd22) && (py >= s_yb_0 - 9'd6 && py <= s_yb_0 + 9'd6) && (px >= 10'd32 && px <= 10'd764);
    wire hit_b_1 = (page == 2'd3) && (s_yb_1 != 9'd0) && (px_s >= s_x_1 - 12'sd22 && px_s <= s_x_1 + 12'sd22) && (py >= s_yb_1 - 9'd6 && py <= s_yb_1 + 9'd6) && (px >= 10'd32 && px <= 10'd764);
    wire hit_b_2 = (page == 2'd3) && (s_yb_2 != 9'd0) && (px_s >= s_x_2 - 12'sd22 && px_s <= s_x_2 + 12'sd22) && (py >= s_yb_2 - 9'd6 && py <= s_yb_2 + 9'd6) && (px >= 10'd32 && px <= 10'd764);
    wire hit_b_3 = (page == 2'd3) && (s_yb_3 != 9'd0) && (px_s >= s_x_3 - 12'sd22 && px_s <= s_x_3 + 12'sd22) && (py >= s_yb_3 - 9'd6 && py <= s_yb_3 + 9'd6) && (px >= 10'd32 && px <= 10'd764);
    wire hit_b_4 = (page == 2'd3) && (s_yb_4 != 9'd0) && (px_s >= s_x_4 - 12'sd22 && px_s <= s_x_4 + 12'sd22) && (py >= s_yb_4 - 9'd6 && py <= s_yb_4 + 9'd6) && (px >= 10'd32 && px <= 10'd764);
    wire hit_b_5 = (page == 2'd3) && (s_yb_5 != 9'd0) && (px_s >= s_x_5 - 12'sd22 && px_s <= s_x_5 + 12'sd22) && (py >= s_yb_5 - 9'd6 && py <= s_yb_5 + 9'd6) && (px >= 10'd32 && px <= 10'd764);
    wire hit_b_6 = (page == 2'd3) && (s_yb_6 != 9'd0) && (px_s >= s_x_6 - 12'sd22 && px_s <= s_x_6 + 12'sd22) && (py >= s_yb_6 - 9'd6 && py <= s_yb_6 + 9'd6) && (px >= 10'd32 && px <= 10'd764);
    wire hit_b_7 = (page == 2'd3) && (s_yb_7 != 9'd0) && (px_s >= s_x_7 - 12'sd22 && px_s <= s_x_7 + 12'sd22) && (py >= s_yb_7 - 9'd6 && py <= s_yb_7 + 9'd6) && (px >= 10'd32 && px <= 10'd764);

    // -------------------------------------------------------------------------
    // 最终像素颜色仲裁器 (Clean Hierarchical Priority Multiplexer)
    // -------------------------------------------------------------------------
    always @(*) begin
        color = C_BG;

        // 1. 全局顶部导航栏
        if (in_nav) begin
            color = C_NAV;
            if (nav_border) color = C_BORDER;
            if (tab_active_bar) color = C_CYAN;

            if (t_nav_title) color = C_CYAN;
            if (t_nav_rate)  color = C_GREEN;

            if (t_nav_tab0) color = (page == 2'd0) ? C_TEXT_PRI : C_TEXT_SEC;
            if (t_nav_tab1) color = (page == 2'd1) ? C_TEXT_PRI : C_TEXT_SEC;
            if (t_nav_tab2) color = (page == 2'd2) ? C_TEXT_PRI : C_TEXT_SEC;
            if (t_nav_tab3) color = (page == 2'd3) ? C_TEXT_PRI : C_TEXT_SEC;
        end

        // 2. PAGE 0 (Performance)
        else if (page == 2'd0) begin
            if (p0_c1_box || p0_c2_box || p0_c3_box || p0_vu_panel || p0_piano_box) color = C_PANEL;
            if (p0_c1_border || p0_c2_border || p0_c3_border || p0_vu_border || p0_piano_border) color = C_BORDER;

            if (p0_c1_strip) color = C_CYAN;
            if (p0_c2_strip) color = C_GREEN;
            if (p0_c3_strip) color = C_AMBER;

            // VU & ADSR
            if (p0_vu_l_bar || p0_vu_r_bar) color = 16'h08A6;
            if (p0_vu_hit) begin
                if (px >= 10'd710) color = C_RED;
                else if (px >= 10'd640) color = C_AMBER;
                else color = C_GREEN;
            end
            if (p0_adsr_sep) color = C_BORDER;
            if (p0_adsr_fill) color = 16'h114E;
            if (p0_adsr_line) color = C_AMBER;

            // 示波器
            if (p0_scope_box) color = C_SCOPE_BG;
            if (p0_scope_border) color = C_BORDER;
            if (p0_scope_grid) color = C_GRID;
            if (p0_scope_zero) color = C_ZERO_LINE;
            if (p0_wave_hit)  color = 16'h0310; // Glowing Cyber-Blue Envelope Body
            if (p0_wave_edge) color = C_CYAN;   // Crisp Cyan Peak Contours & Center Baseline

            // 紧凑型钢琴键盘
            if (in_white_area) color = C_KEY_WHITE;
            if (white_border)  color = C_KEY_BORDER;
            if (in_black_area) color = C_KEY_BLACK;
            if (black_border)  color = C_BORDER;
            if (is_active_key) color = C_GREEN;

            // 文字层
            // 硬件音量指示条与标签
            if (p0_vol_bar_box) color = C_SCOPE_BG;
            if (p0_vol_bar_border) color = C_BORDER;
            if (p0_vol_bar_fill) color = (master_vol == 7'd0) ? C_RED : (master_vol > 7'd110) ? C_AMBER : C_CYAN;
            if (t_p0_vol_lbl) color = (master_vol == 7'd0) ? C_RED : C_TEXT_PRI;

            if (t_p0_c1_t || t_p0_c2_t || t_p0_c3_t) color = C_TEXT_SEC;
            if (t_p0_piano_hdr) color = any_key_active ? C_GREEN : C_TEXT_SEC;
            if (t_p0_c1_v1 || t_p0_vu_hdr || t_p0_scp_hdr) color = C_TEXT_PRI;
            if (t_p0_c1_v2 || t_p0_scp_dac) color = C_CYAN;
            if (t_p0_c2_v1) color = audio_active ? C_GREEN : C_TEXT_SEC;
            if (t_p0_c3_v1) color = C_TEXT_PRI;
            if (t_p0_c3_v2 || t_p0_adsr) color = C_AMBER;
            if (t_p0_vu_l || t_p0_vu_r || t_p0_vu_scl) color = C_TEXT_SEC;
            if (t_p0_silent) color = 16'h3A73;

            if (t_pk_w_all) color = is_active_key ? 16'h0000 : 16'h08A6;
            if (t_pk_b_all) color = is_active_key ? 16'h0000 : C_TEXT_SEC;
        end

        // 3. PAGE 1 (Wave & Spectrum)
        else if (page == 2'd1) begin
            if (p1_scope_box || p1_spec_box) color = C_SCOPE_BG;
            if (p1_scope_border || p1_spec_border) color = C_BORDER;

            if (p1_scope_grid) color = C_GRID;
            if (p1_scope_zero) color = C_ZERO_LINE;
            if (p1_wave_hit)   color = 16'h0310;
            if (p1_wave_edge)  color = C_CYAN;

            if (p1_bar_hit) begin
                if (py <= 9'd340) color = C_RED;
                else if (py <= 9'd380) color = C_AMBER;
                else color = C_GREEN;
            end
            if (p1_spec_base || p1_spec_ticks) color = C_CYAN;

            if (t_p1_scp_hdr || t_p1_spec_hdr) color = C_TEXT_PRI;
            if (t_p1_scp_scl) color = C_CYAN;
            if (t_p1_spec_rng) color = C_GREEN;
            if (t_p1_silent) color = 16'h3A73;
            if (t_p1_freqs)  color = C_TEXT_SEC;
        end

        // 4. PAGE 2 (32-Voice Benchmark)
        else if (page == 2'd2) begin
            if (p2_c1_box || p2_c2_box || p2_c3_box || p2_osc_box) color = C_PANEL;
            if (p2_c1_border || p2_c2_border || p2_c3_border || p2_osc_border || p2_peak_border) color = C_BORDER;

            if (p2_c1_strip) color = C_CYAN;
            if (p2_c2_strip) color = C_GREEN;
            if (p2_c3_strip) color = C_AMBER;

            if (in_osc_cell)      color = 16'h11CE;
            if (osc_cell_border)  color = C_BORDER;
            if (osc_green_led)    color = C_GREEN;
            if (osc_text_hit)     color = 16'hFFFF;

            if (p2_peak_box)   color = C_SCOPE_BG;
            if (p2_hdr_band)   color = C_PANEL;
            if (p2_hdr_line)   color = C_BORDER;
            if (p2_peak_base)  color = C_BORDER;
            if (p2_needle_stem) color = C_CYAN;
            if (p2_needle_dot)  color = C_AMBER;
            if (p2_freq_ticks)  color = C_CYAN;

            if (t_p2_c1_t || t_p2_c2_t || t_p2_c3_t) color = C_TEXT_SEC;
            if (t_p2_c1_v1 || t_p2_c2_v1 || t_p2_c3_v1 || t_p2_osc_hdr || t_p2_pk_hdr) color = C_TEXT_PRI;
            if (t_p2_c1_v2) color = C_CYAN;
            if (t_p2_c2_v2) color = C_GREEN;
            if (t_p2_c3_v2 || t_p2_pk_det) color = C_AMBER;
            if (t_p2_freqs) color = C_TEXT_SEC;
        end

        // 5. PAGE 3 (Song Player)
        else if (page == 2'd3) begin
            if (p3_banner_box || p3_prog_panel) color = C_PANEL;
            if (p3_banner_border || p3_prog_border || p3_score_border) color = C_BORDER;
            if (p3_banner_strip) color = C_CYAN;

            if (p3_bar_box)    color = 16'h08A6;
            if (p3_bar_border) color = C_BORDER;
            if (p3_bar_fill)   color = C_CYAN;
            if (p3_bar_head)   color = C_TEXT_PRI;

            if (p3_score_box) color = C_SCOPE_BG;
            if (p3_stave)     color = C_GRID;
            if (p3_playhead)  color = C_RED;

            if (hit_b_0 || hit_b_1 || hit_b_2 || hit_b_3 || hit_b_4 || hit_b_5 || hit_b_6 || hit_b_7) color = C_GREEN;
            if (hit_m_0 || hit_m_1) color = 16'h128C; // Dim past notes
            if (hit_m_3 || hit_m_4 || hit_m_5 || hit_m_6 || hit_m_7) color = C_CYAN; // Upcoming notes
            if (hit_m_2)            color = C_AMBER;  // Current note on playhead

            if (t_p3_tr_idx || t_p3_pr_key || t_p3_pr_hdl) color = C_TEXT_SEC;
            if (t_p3_tr_nam || t_p3_pr_txt || t_p3_sc_hdr) color = C_TEXT_PRI;
            if (t_p3_tr_inf) color = C_CYAN;
            if (t_p3_sc_mel) color = C_AMBER;
            if (t_p3_sc_ply) color = C_RED;
        end
    end

endmodule
