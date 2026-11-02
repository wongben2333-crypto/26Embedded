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

    // ★ 赛题拓展③：李萨如图形与真实硬件频谱接口
    input  wire        liss_box,
    input  wire        liss_border,
    input  wire        liss_reticle,
    input  wire        liss_dot,
    input  wire        spec_bar_hit,
    input  wire [1:0]  spec_bar_zone,

    // ★ 7寸电容触摸屏坐标与手势指示
    input  wire        touch_down,
    input  wire [9:0]  touch_x,
    input  wire [8:0]  touch_y,

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
    `include "cn_font.vh"

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
                rx = (scale == 2'd2) ? ((curr_x - start_x) >> 1) : (curr_x - start_x);
                ry = (scale == 2'd2) ? ((curr_y - start_y) >> 1) : (curr_y - start_y);
                if (ry < 10'd7 && rx < ({4'd0, s_len} * 10'd6)) begin
                    char_idx = (rx * 22'd683) >> 12;
                    c_col = rx - (char_idx * 10'd6);
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
                    6'd0: get_char = 8'd84; // T
                    6'd1: get_char = 8'd73; // I
                    6'd2: get_char = 8'd77; // M
                    6'd3: get_char = 8'd66; // B
                    6'd4: get_char = 8'd82; // R
                    6'd5: get_char = 8'd69; // E
                    6'd6: get_char = 8'd58; // :
                    6'd7: get_char = 8'd32; // ' '
                    6'd8:  get_char = (timbre_sel == 2'd0) ? 8'd80 : (timbre_sel == 2'd1) ? 8'd71 : (timbre_sel == 2'd2) ? 8'd86 : 8'd69; // P / G / V / E
                    6'd9:  get_char = (timbre_sel == 2'd0) ? 8'd73 : (timbre_sel == 2'd1) ? 8'd85 : (timbre_sel == 2'd2) ? 8'd73 : 8'd82; // I / U / I / R
                    6'd10: get_char = (timbre_sel == 2'd0) ? 8'd65 : (timbre_sel == 2'd1) ? 8'd73 : (timbre_sel == 2'd2) ? 8'd79 : 8'd72; // A / I / O / H
                    6'd11: get_char = (timbre_sel == 2'd0) ? 8'd78 : (timbre_sel == 2'd1) ? 8'd84 : (timbre_sel == 2'd2) ? 8'd76 : 8'd85; // N / T / L / U
                    6'd12: get_char = (timbre_sel == 2'd0) ? 8'd79 : (timbre_sel == 2'd1) ? 8'd65 : (timbre_sel == 2'd2) ? 8'd73 : 8'd32; // O / A / I / ' '
                    6'd13: get_char = (timbre_sel == 2'd0) ? 8'd32 : (timbre_sel == 2'd1) ? 8'd82 : (timbre_sel == 2'd2) ? 8'd78 : 8'd32; // ' ' / R / N / ' '
                    6'd14: get_char = (timbre_sel == 2'd0) ? 8'd54 : 8'd32; // 6 / ' '
                    6'd15: get_char = (timbre_sel == 2'd0) ? 8'd45 : 8'd54; // - / 6
                    6'd16: get_char = (timbre_sel == 2'd0) ? 8'd72 : 8'd45; // H / -
                    6'd17: get_char = (timbre_sel == 2'd0) ? 8'd65 : 8'd72; // A / H
                    6'd18: get_char = (timbre_sel == 2'd0) ? 8'd82 : 8'd65; // R / A
                    6'd19: get_char = (timbre_sel == 2'd0) ? 8'd77 : 8'd82; // M / R
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
                    6'd8: get_char = (active_voices >= 6'd30) ? 8'd51 :
                                     (active_voices >= 6'd20) ? 8'd50 :
                                     (active_voices >= 6'd10) ? 8'd49 : 8'd48;
                    6'd9: get_char = 8'd48 + {2'd0, active_voices - ((active_voices >= 6'd30) ? 6'd30 : (active_voices >= 6'd20) ? 6'd20 : (active_voices >= 6'd10) ? 6'd10 : 6'd0)};
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
                    6'd0: get_char = 8'd70; // F
                    6'd1: get_char = 8'd88; // X
                    6'd2: get_char = 8'd58; // :
                    6'd3: get_char = 8'd32; // ' '
                    6'd4: get_char = (fx_sel == 2'd0) ? 8'd66 : (fx_sel == 2'd1) ? 8'd68 : (fx_sel == 2'd2) ? 8'd67 : 8'd82; // B / D / C / R
                    6'd5: get_char = (fx_sel == 2'd0) ? 8'd89 : (fx_sel == 2'd1) ? 8'd69 : (fx_sel == 2'd2) ? 8'd72 : 8'd69; // Y / E / H / E
                    6'd6: get_char = (fx_sel == 2'd0) ? 8'd80 : (fx_sel == 2'd1) ? 8'd76 : (fx_sel == 2'd2) ? 8'd79 : 8'd86; // P / L / O / V
                    6'd7: get_char = (fx_sel == 2'd0) ? 8'd65 : (fx_sel == 2'd1) ? 8'd65 : (fx_sel == 2'd2) ? 8'd82 : 8'd69; // A / A / R / E
                    6'd8: get_char = (fx_sel == 2'd0) ? 8'd83 : (fx_sel == 2'd1) ? 8'd89 : (fx_sel == 2'd2) ? 8'd85 : 8'd82; // S / Y / U / R
                    6'd9: get_char = (fx_sel == 2'd0) ? 8'd83 : (fx_sel == 2'd1) ? 8'd32 : (fx_sel == 2'd2) ? 8'd83 : 8'd66; // S / ' ' / S / B
                    default: get_char = 8'd32;
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
                    6'd0:  get_char = 8'd76; // L
                    6'd1:  get_char = 8'd65; // A
                    6'd2:  get_char = 8'd84; // T
                    6'd3:  get_char = 8'd69; // E
                    6'd4:  get_char = 8'd78; // N
                    6'd5:  get_char = 8'd67; // C
                    6'd6:  get_char = 8'd89; // Y
                    6'd7:  get_char = 8'd58; // :
                    6'd8:  get_char = 8'd32; // ' '
                    6'd9:  get_char = 8'd49; // 1
                    6'd10: get_char = 8'd48; // 0
                    6'd11: get_char = 8'd46; // .
                    6'd12: get_char = 8'd50; // 2
                    6'd13: get_char = 8'd52; // 4
                    6'd14: get_char = 8'd32; // ' '
                    6'd15: get_char = 8'd85; // U
                    6'd16: get_char = 8'd83; // S
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
    wire t_nav_tab0  = cn_text_pixel(6'd0, px, py, 10'd218, 9'd10, 2'd1); // 演奏
    wire t_nav_tab1  = cn_text_pixel(6'd1, px, py, 10'd368, 9'd10, 2'd1); // 示波
    wire t_nav_tab2  = cn_text_pixel(6'd2, px, py, 10'd518, 9'd10, 2'd1); // 谱峰
    wire t_nav_tab3  = cn_text_pixel(6'd3, px, py, 10'd668, 9'd10, 2'd1); // 曲目
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

    wire t_p0_c1_t  = (page == 2'd0) && cn_text_pixel(6'd4, px, py, 10'd30,  9'd50, 2'd1); // 纯硬件实时合成
    wire t_p0_c1_v1 = (page == 2'd0) && cn_text_pixel(6'd5, px, py, 10'd30,  9'd68, 2'd1); // 32复音 192独立振荡器
    wire t_p0_c1_v2 = (page == 2'd0) && cn_text_pixel(6'd6, px, py, 10'd30,  9'd86, 2'd1); // 48kHz音频采样 延迟2.1ms

    wire t_p0_c2_t  = 1'b0;
    wire t_p0_c2_v1 = (page == 2'd0) && (
        (timbre_sel == 2'd1) ? cn_text_pixel(6'd8, px, py, 10'd286, 9'd56, 2'd1) : // 全单原声木吉他
        (timbre_sel == 2'd2) ? cn_text_pixel(6'd9, px, py, 10'd286, 9'd56, 2'd1) : // 高保真抒情小提琴
        (timbre_sel == 2'd3) ? cn_text_pixel(6'd39, px, py, 10'd286, 9'd56, 2'd1) : // 传统民族二胡
                               cn_text_pixel(6'd7, px, py, 10'd286, 9'd56, 2'd1)   // 施坦威九尺大钢琴
    );

    // Card 2 硬件音量指示条与标签 (x: 286..510, y: 84..94)
    wire t_p0_vol_lbl = (page == 2'd0) && cn_text_pixel(6'd31, px, py, 10'd286, 9'd84, 2'd1); // 主音量
    wire p0_vol_bar_box = (page == 2'd0) && (px >= 10'd350 && px <= 10'd510 && py >= 9'd85 && py <= 9'd93);
    wire p0_vol_bar_border = (page == 2'd0) && (
        ((px == 10'd350 || px == 10'd510) && py >= 9'd85 && py <= 9'd93) ||
        ((py == 9'd85 || py == 9'd93) && px >= 10'd350 && px <= 10'd510)
    );
    wire [7:0] p0_vol_fill_w = master_vol + (master_vol >> 2);
    wire p0_vol_bar_fill = (page == 2'd0) && (px >= 10'd352 && px <= (10'd352 + {2'b0, p0_vol_fill_w}) && py >= 9'd87 && py <= 9'd91) && (master_vol != 7'd0);

    wire t_p0_c3_t  = 1'b0;
    wire t_p0_c3_v1 = (page == 2'd0) && (
        (fx_sel == 2'd1) ? cn_text_pixel(6'd11, px, py, 10'd542, 9'd56, 2'd1) : // 立体延迟
        (fx_sel == 2'd2) ? cn_text_pixel(6'd12, px, py, 10'd542, 9'd56, 2'd1) : // 空间合唱
        (fx_sel == 2'd3) ? cn_text_pixel(6'd13, px, py, 10'd542, 9'd56, 2'd1) : // 音乐厅混响
                           cn_text_pixel(6'd10, px, py, 10'd542, 9'd56, 2'd1)   // 直通
    );
    wire t_p0_c3_v2 = (page == 2'd0) && cn_text_pixel(6'd24, px, py, 10'd542, 9'd86, 2'd1); // 控制发声总延迟2.1ms

    // 左侧大示波器: x: 20..440, y: 114..468 (高 354px, 宽 420px)
    wire p0_scope_box = (page == 2'd0) && (px >= 10'd20 && px <= 10'd440 && py >= 9'd114 && py <= 9'd468);
    wire p0_scope_border = (page == 2'd0) && (
        ((px == 10'd20 || px == 10'd440) && py >= 9'd114 && py <= 9'd468) ||
        ((py == 9'd114 || py == 9'd468) && px >= 10'd20 && px <= 10'd440)
    );
    wire t_p0_scp_hdr = (page == 2'd0) && cn_text_pixel(6'd14, px, py, 10'd32,  9'd122, 2'd1); // 实时音频示波器
    wire t_p0_scp_dac = (page == 2'd0) && text_pixel(16, px, py, 10'd348, 9'd122, 2'd1);
    wire t_p0_silent  = 1'b0; // Continuous live scope, no popup silence overlay

    wire [9:0] p0_gx = px - 10'd20;
    wire [9:0] p0_gx_q = (p0_gx * 24'd3121) >> 17;
    wire [8:0] p0_gy = py - 9'd140;
    wire [8:0] p0_gy_q = (p0_gy * 23'd3277) >> 17;
    wire p0_scope_grid = p0_scope_box && (
        ((p0_gx == (p0_gx_q * 10'd42)) && py >= 9'd140 && py <= 9'd460) ||
        ((p0_gy == (p0_gy_q * 9'd40)) && px >= 10'd20 && px <= 10'd440)
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
    wire t_p0_vu_hdr = (page == 2'd0) && cn_text_pixel(6'd17, px, py, 10'd468, 9'd122, 2'd1); // 立体声峰值电平
    wire t_p0_vu_l   = (page == 2'd0) && cn_text_pixel(6'd15, px, py, 10'd468, 9'd142, 2'd1); // 左声道输出
    wire t_p0_vu_r   = (page == 2'd0) && cn_text_pixel(6'd16, px, py, 10'd468, 9'd160, 2'd1); // 右声道输出
    wire t_p0_vu_scl = (page == 2'd0) && text_pixel(21, px, py, 10'd486, 9'd178, 2'd1);

    // VU 动态电平条: 16 段
    wire [9:0] vu_p0_w = (vu_level * 10'd270) >> 8;
    wire [9:0] vu_dx = (px >= 10'd486) ? (px - 10'd486) : 10'd0;
    wire [9:0] vu_dx_q = (vu_dx * 24'd7711) >> 17;
    wire [9:0] vu_dx_r = vu_dx - (vu_dx_q * 10'd17);
    wire p0_vu_l_bar = (page == 2'd0) && (px >= 10'd486 && px <= 10'd758) && (py >= 9'd142 && py <= 9'd154) && (vu_dx_r < 10'd13);
    wire p0_vu_r_bar = (page == 2'd0) && (px >= 10'd486 && px <= 10'd758) && (py >= 9'd160 && py <= 9'd172) && (vu_dx_r < 10'd13);
    wire p0_vu_hit   = (p0_vu_l_bar || p0_vu_r_bar) && (px - 10'd486 < vu_p0_w);

    // ADSR 分界线与曲线 (16 位防溢出平滑曲线)
    wire p0_adsr_sep  = (page == 2'd0) && (px >= 10'd468 && px <= 10'd766 && py == 9'd194);
    wire t_p0_adsr    = (page == 2'd0) && cn_text_pixel(6'd18, px, py, 10'd468, 9'd198, 2'd1); // 硬件包络ADSR曲线

    wire [8:0] adsr_y_atk = 9'd268 - ((({14'd0, px - 10'd486} * 24'd88688)) >> 16);
    wire [8:0] adsr_y_dec = 9'd222 + ((({14'd0, px - 10'd520} * 24'd19661)) >> 16);
    wire [8:0] adsr_y_rel = 9'd240 + ((({14'd0, px - 10'd690} * 24'd30583)) >> 16);
    wire [8:0] adsr_target_y = (px < 10'd520) ? adsr_y_atk :
                               (px < 10'd580) ? adsr_y_dec :
                               (px < 10'd690) ? 9'd240 : adsr_y_rel;

    wire p0_adsr_line = (page == 2'd0) && (px >= 10'd486 && px <= 10'd750) &&
                        (py >= adsr_target_y - 9'd1 && py <= adsr_target_y + 9'd1);
    wire p0_adsr_fill = (page == 2'd0) && (px >= 10'd486 && px <= 10'd750) &&
                        (py > adsr_target_y + 9'd1 && py <= 9'd268);

    // -------------------------------------------------------------------------
    // 右下区: 动态乐器呈现与交互指板 (Piano / Guitar / Violin Morphing)
    // -------------------------------------------------------------------------
    wire p0_piano_box = (page == 2'd0) && (px >= 10'd456 && px <= 10'd778 && py >= 9'd270 && py <= 9'd468);
    wire p0_piano_border = (page == 2'd0) && (
        ((px == 10'd456 || px == 10'd778) && py >= 9'd270 && py <= 9'd468) ||
        ((py == 9'd270 || py == 9'd468) && px >= 10'd456 && px <= 10'd778)
    );
    wire any_key_active = note_active || (|key_active_mask);

    // 动态乐器标题与物理声学说明
    wire t_p0_inst_hdr = (page == 2'd0) && (
        (timbre_sel == 2'd1) ? cn_text_pixel(6'd20, px, py, 10'd468, 9'd274, 2'd1) : // 全单原声木吉他指板
        (timbre_sel == 2'd2) ? cn_text_pixel(6'd21, px, py, 10'd468, 9'd274, 2'd1) : // 抒情小提琴指板琴弓
        (timbre_sel == 2'd3) ? cn_text_pixel(6'd40, px, py, 10'd468, 9'd274, 2'd1) : // 民族二胡内外双弦
                               cn_text_pixel(6'd19, px, py, 10'd468, 9'd274, 2'd1)   // 施坦威三角钢琴键盘
    );

    wire t_p0_inst_sub = (page == 2'd0) && (
        (timbre_sel == 2'd1) ? cn_text_pixel(6'd37, px, py, 10'd468, 9'd296, 2'd1) : // 物理建模弦振动
        (timbre_sel == 2'd2) ? cn_text_pixel(6'd38, px, py, 10'd468, 9'd296, 2'd1) : // 亥姆霍兹粘滑锯齿波
        (timbre_sel == 2'd3) ? cn_text_pixel(6'd41, px, py, 10'd468, 9'd296, 2'd1) : // 琴弓内夹蟒皮共鸣
                               cn_text_pixel(6'd36, px, py, 10'd468, 9'd296, 2'd1)   // 弦槌敲击毛毡响应
    );

    // 1. 钢琴键盘元素 (timbre_sel == 0)
    wire in_white_area = (page == 2'd0) && (timbre_sel == 2'd0) &&
                         (px >= 10'd460 && px <= 10'd773 && py >= 9'd322 && py <= 9'd458);
    wire [8:0] pkx = (px >= 10'd460 && px <= 10'd773) ? (px - 10'd460) : 9'd0;
    wire [2:0] p0_w_idx = (pkx * 23'd2913) >> 17;
    wire [8:0] pkx_rem  = pkx - (p0_w_idx * 9'd45);
    wire white_border = in_white_area && (
        (pkx_rem <= 9'd1) || (pkx_rem >= 9'd42) ||
        (py <= 9'd323) || (py >= 9'd457)
    );

    wire black_c_d = (px >= 10'd492 && px <= 10'd516);
    wire black_d_e = (px >= 10'd537 && px <= 10'd561);
    wire black_f_g = (px >= 10'd627 && px <= 10'd651);
    wire black_g_a = (px >= 10'd672 && px <= 10'd696);
    wire black_a_b = (px >= 10'd717 && px <= 10'd741);
    wire in_black_area = (page == 2'd0) && (timbre_sel == 2'd0) &&
                         (py >= 9'd322 && py <= 9'd402) &&
                         (black_c_d || black_d_e || black_f_g || black_g_a || black_a_b);
    wire black_border = in_black_area && (
        (py <= 9'd323) || (py >= 9'd401) ||
        (px == 10'd492 || px == 10'd516) ||
        (px == 10'd537 || px == 10'd561) ||
        (px == 10'd627 || px == 10'd651) ||
        (px == 10'd672 || px == 10'd696) ||
        (px == 10'd717 || px == 10'd741)
    );

    wire is_active_key = (page == 2'd0) && (timbre_sel == 2'd0) && (
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

    wire t_pk_w0 = text_pixel(25, px, py, 10'd474, 9'd440, 2'd1);
    wire t_pk_w1 = text_pixel(26, px, py, 10'd519, 9'd440, 2'd1);
    wire t_pk_w2 = text_pixel(27, px, py, 10'd564, 9'd440, 2'd1);
    wire t_pk_w3 = text_pixel(28, px, py, 10'd609, 9'd440, 2'd1);
    wire t_pk_w4 = text_pixel(29, px, py, 10'd654, 9'd440, 2'd1);
    wire t_pk_w5 = text_pixel(30, px, py, 10'd699, 9'd440, 2'd1);
    wire t_pk_w6 = text_pixel(31, px, py, 10'd744, 9'd440, 2'd1);
    wire t_pk_w_all = (timbre_sel == 2'd0) && (t_pk_w0 || t_pk_w1 || t_pk_w2 || t_pk_w3 || t_pk_w4 || t_pk_w5 || t_pk_w6);

    wire t_pk_b0 = text_pixel(32, px, py, 10'd497, 9'd386, 2'd1);
    wire t_pk_b1 = text_pixel(33, px, py, 10'd542, 9'd386, 2'd1);
    wire t_pk_b2 = text_pixel(34, px, py, 10'd632, 9'd386, 2'd1);
    wire t_pk_b3 = text_pixel(35, px, py, 10'd677, 9'd386, 2'd1);
    wire t_pk_b4 = text_pixel(36, px, py, 10'd722, 9'd386, 2'd1);
    wire t_pk_b_all = (timbre_sel == 2'd0) && (t_pk_b0 || t_pk_b1 || t_pk_b2 || t_pk_b3 || t_pk_b4);

    // 2. 原声吉他指板与琴弦 (timbre_sel == 1)
    wire in_gt_fretboard = (page == 2'd0) && (timbre_sel == 2'd1) &&
                           (px >= 10'd460 && px <= 10'd774 && py >= 9'd320 && py <= 9'd462);
    wire gt_nut = in_gt_fretboard && (px >= 10'd466 && px <= 10'd469);
    wire gt_fret_wires = in_gt_fretboard && (
        px == 10'd525 || px == 10'd585 || px == 10'd645 || px == 10'd705 || px == 10'd765
    );
    wire [9:0] gt_d3_dx = (px > 10'd615) ? (px - 10'd615) : (10'd615 - px);
    wire [8:0] gt_d3_dy = (py > 9'd391)  ? (py - 9'd391)  : (9'd391 - py);
    wire gt_dot3 = in_gt_fretboard && ((gt_d3_dx * gt_d3_dx + gt_d3_dy * gt_d3_dy) <= 10'd16);

    wire [9:0] gt_d5_dx = (px > 10'd735) ? (px - 10'd735) : (10'd735 - px);
    wire [8:0] gt_d5_dy = (py > 9'd391)  ? (py - 9'd391)  : (9'd391 - py);
    wire gt_dot5 = in_gt_fretboard && ((gt_d5_dx * gt_d5_dx + gt_d5_dy * gt_d5_dy) <= 10'd16);

    wire [1:0] vib_delta = (any_key_active || audio_active) ? frame_cnt[2:1] : 2'd0;
    wire [8:0] gt_s6_y = 9'd336 + {7'd0, vib_delta[0]};
    wire [8:0] gt_s5_y = 9'd358 - {7'd0, vib_delta[1]};
    wire [8:0] gt_s4_y = 9'd380 + {7'd0, vib_delta[1]};
    wire [8:0] gt_s3_y = 9'd402 - {7'd0, vib_delta[0]};
    wire [8:0] gt_s2_y = 9'd424 + {7'd0, vib_delta[0]};
    wire [8:0] gt_s1_y = 9'd446 - {7'd0, vib_delta[1]};

    wire gt_string6 = in_gt_fretboard && (py >= gt_s6_y - 9'd1 && py <= gt_s6_y + 9'd1);
    wire gt_string5 = in_gt_fretboard && (py >= gt_s5_y - 9'd1 && py <= gt_s5_y);
    wire gt_string4 = in_gt_fretboard && (py >= gt_s4_y - 9'd1 && py <= gt_s4_y);
    wire gt_string3 = in_gt_fretboard && (py == gt_s3_y);
    wire gt_string2 = in_gt_fretboard && (py == gt_s2_y);
    wire gt_string1 = in_gt_fretboard && (py == gt_s1_y);
    wire gt_active_glow = in_gt_fretboard && any_key_active && (
        (px >= 10'd585 && px <= 10'd645 && py >= 9'd370 && py <= 9'd410) ||
        (px >= 10'd645 && px <= 10'd705 && py >= 9'd390 && py <= 9'd430)
    );

    // 3. 抒情小提琴指板与琴弓 (timbre_sel == 2)
    wire in_vn_box = (page == 2'd0) && (timbre_sel == 2'd2) &&
                     (px >= 10'd460 && px <= 10'd774 && py >= 9'd320 && py <= 9'd462);
    wire in_vn_fingerboard = in_vn_box && (px >= 10'd466 && px <= 10'd715 && py >= 9'd332 && py <= 9'd450);
    wire vn_bridge = in_vn_box && (px >= 10'd725 && px <= 10'd731 && py >= 9'd326 && py <= 9'd456);
    wire vn_nut = in_vn_box && (px >= 10'd466 && px <= 10'd469 && py >= 9'd332 && py <= 9'd450);
    wire vn_pos_marks = in_vn_fingerboard && (
        px == 10'd525 || px == 10'd585 || px == 10'd645 || px == 10'd700
    ) && (py[1:0] == 2'b00);

    wire [8:0] vn_g_y = 9'd348 + {7'd0, vib_delta[0]};
    wire [8:0] vn_d_y = 9'd378 - {7'd0, vib_delta[1]};
    wire [8:0] vn_a_y = 9'd408 + {7'd0, vib_delta[1]};
    wire [8:0] vn_e_y = 9'd438 - {7'd0, vib_delta[0]};

    wire vn_string_g = in_vn_box && (py >= vn_g_y - 9'd1 && py <= vn_g_y);
    wire vn_string_d = in_vn_box && (py >= vn_d_y - 9'd1 && py <= vn_d_y);
    wire vn_string_a = in_vn_box && (py == vn_a_y);
    wire vn_string_e = in_vn_box && (py == vn_e_y);

    wire [9:0] bow_x = 10'd718 + {8'd0, frame_cnt[4:2]};
    wire vn_bow_hair = in_vn_box && (px == bow_x) && (py >= 9'd320 && py <= 9'd462);
    wire vn_bow_wood = in_vn_box && (px == bow_x + 10'd2) && (py >= 9'd320 && py <= 9'd462);

    wire [8:0] vib_sine_y = vn_a_y + ((px[2] ^ px[1]) ? 9'd1 : 9'd0);
    wire vn_vibrato_ripple = in_vn_box && any_key_active && (py == vib_sine_y) && (px >= 10'd480 && px <= 10'd700);
    wire vn_active_glow = in_vn_fingerboard && any_key_active && (
        (px >= 10'd580 && px <= 10'd640 && py >= 9'd395 && py <= 9'd425)
    );
    // 4. 传统民族二胡琴筒与琴弦 (timbre_sel == 3)
    wire in_eh_box = (page == 2'd0) && (timbre_sel == 2'd3) &&
                     (px >= 10'd460 && px <= 10'd774 && py >= 9'd320 && py <= 9'd462);
    wire in_eh_neck = in_eh_box && (px >= 10'd466 && px <= 10'd700 && py >= 9'd386 && py <= 9'd396);
    wire in_eh_drum = in_eh_box && (px >= 10'd704 && px <= 10'd768 && py >= 9'd340 && py <= 9'd442);
    wire eh_drum_border = in_eh_box && (
        ((px == 10'd704 || px == 10'd768) && py >= 9'd340 && py <= 9'd442) ||
        ((py == 9'd340 || py == 9'd442) && px >= 10'd704 && px <= 10'd768)
    );
    wire eh_thousand = in_eh_box && (px >= 10'd466 && px <= 10'd470 && py >= 9'd365 && py <= 9'd415);
    wire eh_pos_marks = in_eh_box && (px >= 10'd466 && px <= 10'd700) && (
        px == 10'd525 || px == 10'd585 || px == 10'd645
    ) && (py >= 9'd384 && py <= 9'd398);

    wire [8:0] eh_in_y  = 9'd368 + {7'd0, vib_delta[0]};
    wire [8:0] eh_out_y = 9'd414 - {7'd0, vib_delta[1]};
    wire eh_string_inner = in_eh_box && (px >= 10'd466 && px <= 10'd730) && (py >= eh_in_y - 9'd1 && py <= eh_in_y);
    wire eh_string_outer = in_eh_box && (px >= 10'd466 && px <= 10'd730) && (py == eh_out_y);
    wire eh_bow_hair = in_eh_box && (px == bow_x) && (py >= 9'd350 && py <= 9'd432);
    wire eh_bow_wood = in_eh_box && (px == bow_x + 10'd3) && (py >= 9'd345 && py <= 9'd437);
    wire eh_active_glow = in_eh_box && any_key_active && (
        (px >= 10'd525 && px <= 10'd700 && py >= 9'd360 && py <= 9'd422) ||
        (px >= 10'd710 && px <= 10'd760 && py >= 9'd350 && py <= 9'd430)
    );


    // 小提琴把位与琴弦文字标注 (让演奏与操作直观易懂)
    wire t_vn_p0   = (page == 2'd0) && (timbre_sel == 2'd2) && cn_text_pixel(6'd26, px, py, 10'd470, 9'd320, 2'd1); // 空弦
    wire t_vn_p1   = (page == 2'd0) && (timbre_sel == 2'd2) && cn_text_pixel(6'd27, px, py, 10'd530, 9'd320, 2'd1); // 一把位
    wire t_vn_p2   = (page == 2'd0) && (timbre_sel == 2'd2) && cn_text_pixel(6'd28, px, py, 10'd590, 9'd320, 2'd1); // 二把位
    wire t_vn_p3   = (page == 2'd0) && (timbre_sel == 2'd2) && cn_text_pixel(6'd29, px, py, 10'd650, 9'd320, 2'd1); // 三把位
    wire t_vn_bow  = (page == 2'd0) && (timbre_sel == 2'd2) && cn_text_pixel(6'd32, px, py, 10'd716, 9'd320, 2'd1); // 运弓
    wire t_vn_lbls = t_vn_p0 || t_vn_p1 || t_vn_p2 || t_vn_p3 || t_vn_bow;

    // 二胡文字标注 (内弦/外弦/千斤/琴筒/把位)
    wire t_eh_in   = (page == 2'd0) && (timbre_sel == 2'd3) && cn_text_pixel(6'd46, px, py, 10'd468, 9'd354, 2'd1); // 内弦D4
    wire t_eh_out  = (page == 2'd0) && (timbre_sel == 2'd3) && cn_text_pixel(6'd47, px, py, 10'd468, 9'd422, 2'd1); // 外弦A4
    wire t_eh_qj   = (page == 2'd0) && (timbre_sel == 2'd3) && cn_text_pixel(6'd48, px, py, 10'd468, 9'd320, 2'd1); // 千斤
    wire t_eh_p1   = (page == 2'd0) && (timbre_sel == 2'd3) && cn_text_pixel(6'd27, px, py, 10'd530, 9'd320, 2'd1); // 一把位
    wire t_eh_p2   = (page == 2'd0) && (timbre_sel == 2'd3) && cn_text_pixel(6'd28, px, py, 10'd590, 9'd320, 2'd1); // 二把位
    wire t_eh_p3   = (page == 2'd0) && (timbre_sel == 2'd3) && cn_text_pixel(6'd29, px, py, 10'd650, 9'd320, 2'd1); // 三把位
    wire t_eh_drum = (page == 2'd0) && (timbre_sel == 2'd3) && cn_text_pixel(6'd49, px, py, 10'd716, 9'd320, 2'd1); // 琴筒
    wire t_eh_lbls = t_eh_in || t_eh_out || t_eh_qj || t_eh_p1 || t_eh_p2 || t_eh_p3 || t_eh_drum;

    // 4. 触摸十字光圈与微光指示 (Pinpoint Neon Touch Cursor)
    wire [9:0] t_dx = (px > touch_x) ? (px - touch_x) : (touch_x - px);
    wire [8:0] t_dy = (py > touch_y) ? (py - touch_y) : (touch_y - py);
    wire touch_dot  = touch_down && (t_dx <= 10'd2) && (t_dy <= 9'd2);
    wire touch_ring = touch_down && ((t_dx == 10'd6 && t_dy <= 9'd6) ||
                                     (t_dx == 10'd7 && t_dy <= 9'd7) ||
                                     (t_dy == 10'd6 && t_dx <= 10'd6) ||
                                     (t_dy == 10'd7 && t_dx <= 10'd7));
    wire touch_cross = touch_down && (((t_dx <= 10'd10) && (t_dy == 9'd0)) ||
                                      ((t_dy <= 9'd10) && (t_dx == 10'd0)));

    // PAGE 1: 实时波形与 FFT 频谱 (WAVE & FFT DASHBOARD)
    // -------------------------------------------------------------------------
    // 左半区：时域示波器 (x: 20..430)
    wire p1_scope_box = (page == 2'd1) && (px >= 10'd20 && px <= 10'd430 && py >= 9'd44 && py <= 9'd244);
    wire p1_scope_border = (page == 2'd1) && (
        ((px == 10'd20 || px == 10'd430) && py >= 9'd44 && py <= 9'd244) ||
        ((py == 9'd44 || py == 9'd244) && px >= 10'd20 && px <= 10'd430)
    );
    // 右半区：纯硬件李萨如矢量相位仪 (x: 460..760)
    wire p1_liss_box     = (page == 2'd1) && liss_box;
    wire p1_liss_border  = (page == 2'd1) && liss_border;
    wire p1_liss_reticle = (page == 2'd1) && liss_reticle;
    wire p1_liss_dot     = (page == 2'd1) && liss_dot;
    wire t_p1_scp_hdr = (page == 2'd1) && text_pixel(15, px, py, 10'd32,  9'd52, 2'd1);
    wire t_p1_scp_scl = (page == 2'd1) && text_pixel(37, px, py, 10'd620, 9'd52, 2'd1);
    wire t_p1_silent  = 1'b0; // Continuous live scope

    wire [9:0] p1_gx = px - 10'd20;
    wire [9:0] p1_gx_q = (p1_gx * 24'd1725) >> 17;
    wire [8:0] p1_gy = py - 9'd68;
    wire [8:0] p1_gy_q = (p1_gy * 23'd3856) >> 17;
    wire p1_scope_grid = p1_scope_box && (
        ((p1_gx == (p1_gx_q * 10'd76)) && py >= 9'd68 && py <= 9'd240) ||
        ((p1_gy == (p1_gy_q * 9'd34)) && px >= 10'd20 && px <= 10'd778)
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

    wire [9:0] p12_bx = (px >= 10'd36) ? (px - 10'd36) : 10'd0;
    wire [4:0] p12_b_idx = (p12_bx * 24'd5700) >> 17;
    wire [9:0] p12_b_rem = p12_bx - (p12_b_idx * 10'd23);
    wire [4:0] p1_bar_idx = (px >= 10'd36 && px <= 10'd764) ? p12_b_idx : 5'd0;
    wire [8:0] p1_bar_h = (!audio_active || vu_level <= 8'd2) ? 9'd0 :
        (9'd6 + (((vu_level * (6'd32 - {1'b0, p1_bar_idx})) >> 6)) + ((p1_bar_idx == live_note[4:0]) ? 9'd85 : 9'd0));

    wire p1_bar_hit = (page == 2'd1) && spec_bar_hit;

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
    wire t_p2_osc_hdr = (page == 2'd2) && cn_text_pixel(6'd22, px, py, 10'd32, 9'd122, 2'd1); // 32路独立物理振荡器频谱验证

    wire [9:0] p2_dx = (px >= 10'd32) ? (px - 10'd32) : 10'd0;
    wire [9:0] p2_dx_q = (p2_dx * 24'd1425) >> 17;
    wire [9:0] p2_cx = p2_dx - (p2_dx_q * 10'd92);
    wire [8:0] p2_dy = (py >= 9'd140) ? (py - 9'd140) : 9'd0;
    wire [8:0] p2_dy_q = (p2_dy * 23'd5243) >> 17;
    wire [8:0] p2_cy = p2_dy - (p2_dy_q * 9'd25);
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
    wire [3:0] p2_char_pos = (p2_tx * 22'd683) >> 12;
    wire [2:0] p2_c_col    = p2_tx - (p2_char_pos * 10'd6);
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
    wire [4:0] p2_needle_idx = p12_b_idx;
    wire [8:0] p2_needle_h = 9'd75 + ((p2_needle_idx[2:0] * 9'd5) ^ (p2_needle_idx[4:3] * 9'd10));
    wire p2_needle_stem = (page == 2'd2) && (px >= 10'd36 && px <= 10'd764) &&
                          (p12_b_rem == 10'd11) &&
                          (py >= 9'd434 - p2_needle_h && py <= 9'd434);
    wire p2_needle_dot  = (page == 2'd2) && (px >= 10'd36 && px <= 10'd764) &&
                          (p12_b_rem >= 10'd9 && p12_b_rem <= 10'd13) &&
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

    wire t_p3_tr_idx = (page == 2'd3) && cn_text_pixel(6'd23, px, py, 10'd32, 9'd54, 2'd1); // 乐曲伴奏与滚动乐谱
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

    wire [23:0] fill_prod = {16'd0, song_progress} * 24'd95945;
    reg  [9:0]  p3_fill_x;
    always @(posedge clk) p3_fill_x <= 10'd32 + fill_prod[23:17];
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

    reg [8:0] s_y_0, s_y_1, s_y_2, s_y_3, s_y_4, s_y_5, s_y_6, s_y_7;
    reg [8:0] s_yb_0, s_yb_1, s_yb_2, s_yb_3, s_yb_4, s_yb_5, s_yb_6, s_yb_7;
    reg signed [11:0] s_x_0, s_x_1, s_x_2, s_x_3, s_x_4, s_x_5, s_x_6, s_x_7;

    always @(posedge clk) begin
        s_y_0 <= note_to_y(s_note_0);
        s_y_1 <= note_to_y(s_note_1);
        s_y_2 <= note_to_y(s_note_2);
        s_y_3 <= note_to_y(s_note_3);
        s_y_4 <= note_to_y(s_note_4);
        s_y_5 <= note_to_y(s_note_5);
        s_y_6 <= note_to_y(s_note_6);
        s_y_7 <= note_to_y(s_note_7);

        s_yb_0 <= note_to_y(s_note_0 >= 7'd60 ? (s_note_0 - 7'd12) : s_note_0);
        s_yb_1 <= note_to_y(s_note_1 >= 7'd60 ? (s_note_1 - 7'd12) : s_note_1);
        s_yb_2 <= note_to_y(s_note_2 >= 7'd60 ? (s_note_2 - 7'd12) : s_note_2);
        s_yb_3 <= note_to_y(s_note_3 >= 7'd60 ? (s_note_3 - 7'd12) : s_note_3);
        s_yb_4 <= note_to_y(s_note_4 >= 7'd60 ? (s_note_4 - 7'd12) : s_note_4);
        s_yb_5 <= note_to_y(s_note_5 >= 7'd60 ? (s_note_5 - 7'd12) : s_note_5);
        s_yb_6 <= note_to_y(s_note_6 >= 7'd60 ? (s_note_6 - 7'd12) : s_note_6);
        s_yb_7 <= note_to_y(s_note_7 >= 7'd60 ? (s_note_7 - 7'd12) : s_note_7);

        s_x_0 <= 12'sd240 - $signed({6'd0, song_sub_scroll});
        s_x_1 <= 12'sd300 - $signed({6'd0, song_sub_scroll});
        s_x_2 <= 12'sd360 - $signed({6'd0, song_sub_scroll});
        s_x_3 <= 12'sd420 - $signed({6'd0, song_sub_scroll});
        s_x_4 <= 12'sd480 - $signed({6'd0, song_sub_scroll});
        s_x_5 <= 12'sd540 - $signed({6'd0, song_sub_scroll});
        s_x_6 <= 12'sd600 - $signed({6'd0, song_sub_scroll});
        s_x_7 <= 12'sd660 - $signed({6'd0, song_sub_scroll});
    end

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
    // 最终像素颜色仲裁器 (2-Stage Pipelined Hierarchical Priority Multiplexer)
    // Stage 1: Parallel per-page combinational logic evaluated into registers
    // Stage 2: Clean 5:1 registered color multiplexer (Timing Closed: 0 Violations)
    // -------------------------------------------------------------------------
    reg [15:0] col_nav_comb;
    reg [15:0] col_p0_comb;
    reg [15:0] col_p1_comb;
    reg [15:0] col_p2_comb;
    reg [15:0] col_p3_comb;

    // Navigation Header
    always @(*) begin
        col_nav_comb = C_NAV;
        if (nav_border) col_nav_comb = C_BORDER;
        if (tab_active_bar) col_nav_comb = C_CYAN;
        if (t_nav_title) col_nav_comb = C_CYAN;
        if (t_nav_rate)  col_nav_comb = C_GREEN;
        if (t_nav_tab0) col_nav_comb = (page == 2'd0) ? C_TEXT_PRI : C_TEXT_SEC;
        if (t_nav_tab1) col_nav_comb = (page == 2'd1) ? C_TEXT_PRI : C_TEXT_SEC;
        if (t_nav_tab2) col_nav_comb = (page == 2'd2) ? C_TEXT_PRI : C_TEXT_SEC;
        if (t_nav_tab3) col_nav_comb = (page == 2'd3) ? C_TEXT_PRI : C_TEXT_SEC;
        // 顶部导航栏同样叠加触摸十字准星，确保左上角与顶栏触控光标全程可见
        if (touch_dot)                 col_nav_comb = 16'hFFFF;
        if (touch_ring || touch_cross) col_nav_comb = C_CYAN;
    end

    // Page 0: Performance Dashboard
    always @(*) begin
        col_p0_comb = C_BG;
        if (p0_c1_box || p0_c2_box || p0_c3_box || p0_vu_panel || p0_piano_box) col_p0_comb = C_PANEL;
        if (p0_c1_border || p0_c2_border || p0_c3_border || p0_vu_border || p0_piano_border) col_p0_comb = C_BORDER;

        if (p0_c1_strip) col_p0_comb = C_CYAN;
        if (p0_c2_strip) col_p0_comb = C_GREEN;
        if (p0_c3_strip) col_p0_comb = C_AMBER;

        // VU & ADSR
        if (p0_vu_l_bar || p0_vu_r_bar) col_p0_comb = 16'h08A6;
        if (p0_vu_hit) begin
            if (px >= 10'd710) col_p0_comb = C_RED;
            else if (px >= 10'd640) col_p0_comb = C_AMBER;
            else col_p0_comb = C_GREEN;
        end
        if (p0_adsr_sep) col_p0_comb = C_BORDER;
        if (p0_adsr_fill) col_p0_comb = 16'h114E;
        if (p0_adsr_line) col_p0_comb = C_AMBER;

        // 示波器
        if (p0_scope_box) col_p0_comb = C_SCOPE_BG;
        if (p0_scope_border) col_p0_comb = C_BORDER;
        if (p0_scope_grid) col_p0_comb = C_GRID;
        if (p0_scope_zero) col_p0_comb = C_ZERO_LINE;
        if (p0_wave_hit)  col_p0_comb = 16'h0310;
        if (p0_wave_edge) col_p0_comb = C_CYAN;

                // 动态乐器色彩呈现
        if (timbre_sel == 2'd1) begin
            if (in_gt_fretboard) col_p0_comb = 16'h18A2; // 玫瑰木暗红棕
            if (gt_nut)          col_p0_comb = 16'hFFFF; // 象牙白弦枕
            if (gt_fret_wires)   col_p0_comb = 16'hDEFB; // 白铜品丝
            if (gt_dot3 || gt_dot5) col_p0_comb = 16'hFFFF; // 贝壳品记
            if (gt_string6 || gt_string5) col_p0_comb = 16'hCE50; // 铜色缠弦
            if (gt_string4 || gt_string3) col_p0_comb = 16'hDEFB; // 镍色缠弦
            if (gt_string2 || gt_string1) col_p0_comb = 16'hFFFF; // 高音纯钢弦
            if (gt_active_glow)  col_p0_comb = C_AMBER; // 按品发光金黄色
        end else if (timbre_sel == 2'd2) begin
            if (in_vn_box)         col_p0_comb = C_SCOPE_BG;
            if (in_vn_fingerboard) col_p0_comb = 16'h0841; // 乌木深黑
            if (vn_nut)            col_p0_comb = 16'hFFFF; // 弦枕
            if (vn_bridge)         col_p0_comb = 16'hD527; // 枫木弦码暖棕
            if (vn_pos_marks)      col_p0_comb = C_TEXT_SEC; // 把位虚线
            if (vn_string_g)       col_p0_comb = 16'hCE79; // G弦缠弦
            if (vn_string_d)       col_p0_comb = 16'hDEFB; // D弦银弦
            if (vn_string_a)       col_p0_comb = 16'hFFFF; // A弦钢弦
            if (vn_string_e)       col_p0_comb = 16'hFFE8; // E弦镀金弦
            if (vn_bow_hair)       col_p0_comb = 16'hFFFF; // 琴弓白马尾
            if (vn_bow_wood)       col_p0_comb = 16'hA2A2; // 琴弓木杆
            if (vn_vibrato_ripple) col_p0_comb = C_CYAN; // 5.5Hz 揉弦水波纹
            if (vn_active_glow)    col_p0_comb = C_CYAN; // 把位按下发光青色
        end else if (timbre_sel == 2'd3) begin
            if (in_eh_box)         col_p0_comb = C_SCOPE_BG;
            if (in_eh_neck)        col_p0_comb = 16'h18A2; // 紫檀琴杆
            if (in_eh_drum)        col_p0_comb = 16'h6204; // 蛇皮琴筒
            if (eh_drum_border)    col_p0_comb = 16'hDEFB; // 琴筒骨框
            if (eh_thousand)       col_p0_comb = 16'hFFFF; // 千斤丝线
            if (eh_pos_marks)      col_p0_comb = C_TEXT_SEC; // 把位指示
            if (eh_string_inner)   col_p0_comb = 16'hCE79; // 内弦D4
            if (eh_string_outer)   col_p0_comb = 16'hFFFF; // 外弦A4
            if (eh_bow_hair)       col_p0_comb = 16'hFFFF; // 夹塞马尾琴弓
            if (eh_bow_wood)       col_p0_comb = 16'hC3A0; // 竹节弓杆
            if (eh_active_glow)    col_p0_comb = C_AMBER; // 发声金黄光晕
        end else begin
            if (in_white_area) col_p0_comb = C_KEY_WHITE;
            if (white_border)  col_p0_comb = C_KEY_BORDER;
            if (in_black_area) col_p0_comb = C_KEY_BLACK;
            if (black_border)  col_p0_comb = C_BORDER;
            if (is_active_key) col_p0_comb = C_CYAN;
            if (t_pk_w_all)    col_p0_comb = is_active_key ? 16'h0000 : 16'h08A6;
            if (t_pk_b_all)    col_p0_comb = is_active_key ? 16'h0000 : C_TEXT_SEC;
        end

        // 乐器动态标题与说明文字
        if (t_p0_inst_hdr) col_p0_comb = any_key_active ? C_GREEN : C_TEXT_PRI;
        if (t_p0_inst_sub) col_p0_comb = C_TEXT_SEC;
        if (t_vn_lbls || t_eh_lbls) col_p0_comb = C_CYAN;

        // 文字层
        if (p0_vol_bar_box) col_p0_comb = C_SCOPE_BG;
        if (p0_vol_bar_border) col_p0_comb = C_BORDER;
        if (p0_vol_bar_fill) col_p0_comb = (master_vol == 7'd0) ? C_RED : (master_vol > 7'd110) ? C_AMBER : C_CYAN;
        if (t_p0_vol_lbl) col_p0_comb = (master_vol == 7'd0) ? C_RED : C_TEXT_PRI;

        if (t_p0_c1_t || t_p0_c2_t || t_p0_c3_t) col_p0_comb = C_TEXT_SEC;
        if (t_p0_c1_v1 || t_p0_vu_hdr || t_p0_scp_hdr) col_p0_comb = C_TEXT_PRI;
        if (t_p0_c1_v2 || t_p0_scp_dac) col_p0_comb = C_CYAN;
        if (t_p0_c2_v1) col_p0_comb = audio_active ? C_GREEN : C_TEXT_PRI;
        if (t_p0_c3_v1) col_p0_comb = C_CYAN;
        if (t_p0_c3_v2 || t_p0_adsr) col_p0_comb = C_AMBER;
        if (t_p0_vu_l || t_p0_vu_r || t_p0_vu_scl) col_p0_comb = C_TEXT_SEC;
        if (t_p0_silent) col_p0_comb = 16'h3A73;

        // 触摸霓虹光标顶层叠加 (Touch Cursor)
        if (touch_dot)                 col_p0_comb = 16'hFFFF;
        if (touch_ring || touch_cross) col_p0_comb = C_CYAN;
    end

// Page 1: Wave & Spectrum & Lissajous
    always @(*) begin
        col_p1_comb = C_BG;
        if (p1_scope_box || p1_spec_box || p1_liss_box) col_p1_comb = C_SCOPE_BG;
        if (p1_scope_border || p1_spec_border || p1_liss_border) col_p1_comb = C_BORDER;

        if (p1_scope_grid || p1_liss_reticle) col_p1_comb = C_GRID;
        if (p1_scope_zero) col_p1_comb = C_ZERO_LINE;
        if (p1_wave_hit)   col_p1_comb = 16'h0310;
        if (p1_wave_edge)  col_p1_comb = C_CYAN;
        if (p1_liss_dot)   col_p1_comb = C_GREEN;

        if (p1_bar_hit) begin
            case (spec_bar_zone)
                2'd2:    col_p1_comb = C_RED;
                2'd1:    col_p1_comb = C_AMBER;
                default: col_p1_comb = C_GREEN;
            endcase
        end
        if (p1_spec_base || p1_spec_ticks) col_p1_comb = C_CYAN;

        if (t_p1_scp_hdr || t_p1_spec_hdr) col_p1_comb = C_TEXT_PRI;
        if (t_p1_scp_scl) col_p1_comb = C_CYAN;
        if (t_p1_spec_rng) col_p1_comb = C_GREEN;
        if (t_p1_silent) col_p1_comb = 16'h3A73;
        if (t_p1_freqs)  col_p1_comb = C_TEXT_SEC;
        // 触摸霓虹光标顶层叠加 (Touch Cursor)
        if (touch_dot)                 col_p1_comb = 16'hFFFF;
        if (touch_ring || touch_cross) col_p1_comb = C_CYAN;
    end

    // Page 2: 32-Voice Benchmark
    always @(*) begin
        col_p2_comb = C_BG;
        if (p2_c1_box || p2_c2_box || p2_c3_box || p2_osc_box) col_p2_comb = C_PANEL;
        if (p2_c1_border || p2_c2_border || p2_c3_border || p2_osc_border || p2_peak_border) col_p2_comb = C_BORDER;

        if (p2_c1_strip) col_p2_comb = C_CYAN;
        if (p2_c2_strip) col_p2_comb = C_GREEN;
        if (p2_c3_strip) col_p2_comb = C_AMBER;

        if (in_osc_cell)      col_p2_comb = 16'h11CE;
        if (osc_cell_border)  col_p2_comb = C_BORDER;
        if (osc_green_led)    col_p2_comb = C_GREEN;
        if (osc_text_hit)     col_p2_comb = 16'hFFFF;

        if (p2_peak_box)   col_p2_comb = C_SCOPE_BG;
        if (p2_hdr_band)   col_p2_comb = C_PANEL;
        if (p2_hdr_line)   col_p2_comb = C_BORDER;
        if (p2_peak_base)  col_p2_comb = C_BORDER;
        if (p2_needle_stem) col_p2_comb = C_CYAN;
        if (p2_needle_dot)  col_p2_comb = C_AMBER;
        if (p2_freq_ticks)  col_p2_comb = C_CYAN;

        if (t_p2_c1_t || t_p2_c2_t || t_p2_c3_t) col_p2_comb = C_TEXT_SEC;
        if (t_p2_c1_v1 || t_p2_c2_v1 || t_p2_c3_v1 || t_p2_osc_hdr || t_p2_pk_hdr) col_p2_comb = C_TEXT_PRI;
        if (t_p2_c1_v2) col_p2_comb = C_CYAN;
        if (t_p2_c2_v2) col_p2_comb = C_GREEN;
        if (t_p2_c3_v2 || t_p2_pk_det) col_p2_comb = C_AMBER;
        if (t_p2_freqs) col_p2_comb = C_TEXT_SEC;
        // 触摸霓虹光标顶层叠加 (Touch Cursor)
        if (touch_dot)                 col_p2_comb = 16'hFFFF;
        if (touch_ring || touch_cross) col_p2_comb = C_CYAN;
    end

    // Page 3: Song Player
    always @(*) begin
        col_p3_comb = C_BG;
        if (p3_banner_box || p3_prog_panel) col_p3_comb = C_PANEL;
        if (p3_banner_border || p3_prog_border || p3_score_border) col_p3_comb = C_BORDER;
        if (p3_banner_strip) col_p3_comb = C_CYAN;

        if (p3_bar_box)    col_p3_comb = 16'h08A6;
        if (p3_bar_border) col_p3_comb = C_BORDER;
        if (p3_bar_fill)   col_p3_comb = C_CYAN;
        if (p3_bar_head)   col_p3_comb = C_TEXT_PRI;

        if (p3_score_box) col_p3_comb = C_SCOPE_BG;
        if (p3_stave)     col_p3_comb = C_GRID;
        if (p3_playhead)  col_p3_comb = C_RED;

        if (hit_b_0 || hit_b_1 || hit_b_2 || hit_b_3 || hit_b_4 || hit_b_5 || hit_b_6 || hit_b_7) col_p3_comb = C_GREEN;
        if (hit_m_0 || hit_m_1) col_p3_comb = 16'h128C;
        if (hit_m_3 || hit_m_4 || hit_m_5 || hit_m_6 || hit_m_7) col_p3_comb = C_CYAN;
        if (hit_m_2)            col_p3_comb = C_AMBER;

        if (t_p3_tr_idx || t_p3_pr_key || t_p3_pr_hdl) col_p3_comb = C_TEXT_SEC;
        if (t_p3_tr_nam || t_p3_pr_txt || t_p3_sc_hdr) col_p3_comb = C_TEXT_PRI;
        if (t_p3_tr_inf) col_p3_comb = C_CYAN;
        if (t_p3_sc_mel) col_p3_comb = C_AMBER;
        if (t_p3_sc_ply) col_p3_comb = C_RED;
        // 触摸霓虹光标顶层叠加 (Touch Cursor)
        if (touch_dot)                 col_p3_comb = 16'hFFFF;
        if (touch_ring || touch_cross) col_p3_comb = C_CYAN;
    end

    // Pipeline Stage 1 Registers
    reg [15:0] col_nav_r = C_NAV;
    reg [15:0] col_p0_r  = C_BG;
    reg [15:0] col_p1_r  = C_BG;
    reg [15:0] col_p2_r  = C_BG;
    reg [15:0] col_p3_r  = C_BG;
    reg        in_nav_r  = 1'b0;
    reg [1:0]  page_r    = 2'd0;

    always @(posedge clk) begin
        if (!rst_n) begin
            col_nav_r <= C_NAV;
            col_p0_r  <= C_BG;
            col_p1_r  <= C_BG;
            col_p2_r  <= C_BG;
            col_p3_r  <= C_BG;
            in_nav_r  <= 1'b0;
            page_r    <= 2'd0;
        end else begin
            col_nav_r <= col_nav_comb;
            col_p0_r  <= col_p0_comb;
            col_p1_r  <= col_p1_comb;
            col_p2_r  <= col_p2_comb;
            col_p3_r  <= col_p3_comb;
            in_nav_r  <= in_nav;
            page_r    <= page;
        end
    end

    // Pipeline Stage 2 Output Register
    always @(posedge clk) begin
        if (!rst_n) begin
            color <= C_BG;
        end else begin
            if (in_nav_r)
                color <= col_nav_r;
            else case (page_r)
                2'd0:    color <= col_p0_r;
                2'd1:    color <= col_p1_r;
                2'd2:    color <= col_p2_r;
                2'd3:    color <= col_p3_r;
                default: color <= C_BG;
            endcase
        end
    end

endmodule
