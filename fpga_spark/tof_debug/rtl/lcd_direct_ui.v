// =============================================================================
//  lcd_direct_ui.v -- 7-inch 800x480 (ATK-MD0700 / SSD1963) Direct RTL UI Engine
//  Features:
//    1. Hardware SSD1963 8080 16-bit timing generator & frame scanner
//    2. Big Distance Readout with Dynamic Visual Progress Bar
//    3. Dual-Bus I2C Status Cards (Online/Offline, Dev ID, ACK counters)
//    4. 16x8 I2C Address Scan Grid (highlighting detected devices)
// =============================================================================
`default_nettype none

module lcd_direct_ui (
    input  wire        clk,            // 50 MHz
    input  wire        rst_n,

    // Status inputs from tof_scan_mgr
    input  wire        active_bus,     // 0 = Bus 1, 1 = Bus 2
    input  wire [6:0]  active_addr,
    input  wire        sensor_online,
    input  wire [7:0]  sensor_dev_id,
    input  wire [15:0] distance_mm,
    input  wire [15:0] ack_counter,
    input  wire [15:0] nack_counter,
    input  wire [127:0] scan_bitmap_1,
    input  wire [127:0] scan_bitmap_2,
    input  wire        scl1_raw,
    input  wire        sda1_raw,
    input  wire        scl2_raw,
    input  wire        sda2_raw,
    input  wire        scan_busy,

    // J14 8080 Physical Interface
    output reg         lcd_cs,         // AB21
    output reg         lcd_rs,         // R14
    output reg         lcd_wr,         // AB20
    output reg         lcd_rd,         // AB18
    output reg         lcd_rst,        // Y18
    inout  wire [15:0] lcd_db,         // 16-bit 8080 bidirectional data
    output wire        lcd_dpi_bl      // P20 (set to 0)
);

    assign lcd_dpi_bl = 1'b0;

    // -------------------------------------------------------------------------
    // 1. 5x7 Font Dot Lookup Function
    // -------------------------------------------------------------------------
    function font_dot;
        input [7:0] ascii;
        input [2:0] col;
        input [2:0] row;
        reg [4:0] b;
        begin
            case (ascii)
                " ": b = 5'b00000;
                "-": b = (row == 3'd3) ? 5'b11111 : 5'b00000;
                ":": b = (row == 3'd2 || row == 3'd4) ? 5'b01100 : 5'b00000;
                ".": b = (row == 3'd6) ? 5'b01100 : 5'b00000;
                "=": b = (row == 3'd2 || row == 3'd4) ? 5'b11111 : 5'b00000;
                "/": case(row)
                    3'd0: b = 5'b00001; 3'd1: b = 5'b00010; 3'd2: b = 5'b00100;
                    3'd3: b = 5'b00100; 3'd4: b = 5'b01000; 3'd5: b = 5'b10000;
                    default: b = 5'b00000;
                endcase
                "[": b = (row == 3'd0 || row == 3'd6) ? 5'b11100 : 5'b10000;
                "]": b = (row == 3'd0 || row == 3'd6) ? 5'b00111 : 5'b00001;
                "0": case(row)
                    3'd0: b = 5'b01110; 3'd1: b = 5'b10001; 3'd2: b = 5'b10011;
                    3'd3: b = 5'b10101; 3'd4: b = 5'b11001; 3'd5: b = 5'b10001;
                    3'd6: b = 5'b01110; default: b = 5'b00000;
                endcase
                "1": case(row)
                    3'd0: b = 5'b00100; 3'd1: b = 5'b01100; 3'd2: b = 5'b00100;
                    3'd3: b = 5'b00100; 3'd4: b = 5'b00100; 3'd5: b = 5'b00100;
                    3'd6: b = 5'b01110; default: b = 5'b00000;
                endcase
                "2": case(row)
                    3'd0: b = 5'b01110; 3'd1: b = 5'b10001; 3'd2: b = 5'b00001;
                    3'd3: b = 5'b00010; 3'd4: b = 5'b00100; 3'd5: b = 5'b01000;
                    3'd6: b = 5'b11111; default: b = 5'b00000;
                endcase
                "3": case(row)
                    3'd0: b = 5'b11110; 3'd1: b = 5'b00001; 3'd2: b = 5'b00001;
                    3'd3: b = 5'b01110; 3'd4: b = 5'b00001; 3'd5: b = 5'b00001;
                    3'd6: b = 5'b11110; default: b = 5'b00000;
                endcase
                "4": case(row)
                    3'd0: b = 5'b00010; 3'd1: b = 5'b00110; 3'd2: b = 5'b01010;
                    3'd3: b = 5'b10010; 3'd4: b = 5'b11111; 3'd5: b = 5'b00010;
                    3'd6: b = 5'b00010; default: b = 5'b00000;
                endcase
                "5": case(row)
                    3'd0: b = 5'b11111; 3'd1: b = 5'b10000; 3'd2: b = 5'b11110;
                    3'd3: b = 5'b00001; 3'd4: b = 5'b00001; 3'd5: b = 5'b10001;
                    3'd6: b = 5'b01110; default: b = 5'b00000;
                endcase
                "6": case(row)
                    3'd0: b = 5'b01110; 3'd1: b = 5'b10000; 3'd2: b = 5'b11110;
                    3'd3: b = 5'b10001; 3'd4: b = 5'b10001; 3'd5: b = 5'b10001;
                    3'd6: b = 5'b01110; default: b = 5'b00000;
                endcase
                "7": case(row)
                    3'd0: b = 5'b11111; 3'd1: b = 5'b00001; 3'd2: b = 5'b00010;
                    3'd3: b = 5'b00100; 3'd4: b = 5'b01000; 3'd5: b = 5'b01000;
                    3'd6: b = 5'b01000; default: b = 5'b00000;
                endcase
                "8": case(row)
                    3'd0: b = 5'b01110; 3'd1: b = 5'b10001; 3'd2: b = 5'b10001;
                    3'd3: b = 5'b01110; 3'd4: b = 5'b10001; 3'd5: b = 5'b10001;
                    3'd6: b = 5'b01110; default: b = 5'b00000;
                endcase
                "9": case(row)
                    3'd0: b = 5'b01110; 3'd1: b = 5'b10001; 3'd2: b = 5'b10001;
                    3'd3: b = 5'b01111; 3'd4: b = 5'b00001; 3'd5: b = 5'b00001;
                    3'd6: b = 5'b01110; default: b = 5'b00000;
                endcase
                "A": case(row)
                    3'd0: b = 5'b01110; 3'd1: b = 5'b10001; 3'd2: b = 5'b10001;
                    3'd3: b = 5'b11111; 3'd4: b = 5'b10001; 3'd5: b = 5'b10001;
                    3'd6: b = 5'b10001; default: b = 5'b00000;
                endcase
                "B": case(row)
                    3'd0: b = 5'b11110; 3'd1: b = 5'b10001; 3'd2: b = 5'b10001;
                    3'd3: b = 5'b11110; 3'd4: b = 5'b10001; 3'd5: b = 5'b10001;
                    3'd6: b = 5'b11110; default: b = 5'b00000;
                endcase
                "C": case(row)
                    3'd0: b = 5'b01111; 3'd1: b = 5'b10000; 3'd2: b = 5'b10000;
                    3'd3: b = 5'b10000; 3'd4: b = 5'b10000; 3'd5: b = 5'b10000;
                    3'd6: b = 5'b01111; default: b = 5'b00000;
                endcase
                "D": case(row)
                    3'd0: b = 5'b11110; 3'd1: b = 5'b10001; 3'd2: b = 5'b10001;
                    3'd3: b = 5'b10001; 3'd4: b = 5'b10001; 3'd5: b = 5'b10001;
                    3'd6: b = 5'b11110; default: b = 5'b00000;
                endcase
                "E": case(row)
                    3'd0: b = 5'b11111; 3'd1: b = 5'b10000; 3'd2: b = 5'b10000;
                    3'd3: b = 5'b11110; 3'd4: b = 5'b10000; 3'd5: b = 5'b10000;
                    3'd6: b = 5'b11111; default: b = 5'b00000;
                endcase
                "F": case(row)
                    3'd0: b = 5'b11111; 3'd1: b = 5'b10000; 3'd2: b = 5'b10000;
                    3'd3: b = 5'b11110; 3'd4: b = 5'b10000; 3'd5: b = 5'b10000;
                    3'd6: b = 5'b10000; default: b = 5'b00000;
                endcase
                "G": case(row)
                    3'd0: b = 5'b01111; 3'd1: b = 5'b10000; 3'd2: b = 5'b10000;
                    3'd3: b = 5'b10111; 3'd4: b = 5'b10001; 3'd5: b = 5'b10001;
                    3'd6: b = 5'b01110; default: b = 5'b00000;
                endcase
                "H": case(row)
                    3'd0: b = 5'b10001; 3'd1: b = 5'b10001; 3'd2: b = 5'b10001;
                    3'd3: b = 5'b11111; 3'd4: b = 5'b10001; 3'd5: b = 5'b10001;
                    3'd6: b = 5'b10001; default: b = 5'b00000;
                endcase
                "I": case(row)
                    3'd0: b = 5'b01110; 3'd1: b = 5'b00100; 3'd2: b = 5'b00100;
                    3'd3: b = 5'b00100; 3'd4: b = 5'b00100; 3'd5: b = 5'b00100;
                    3'd6: b = 5'b01110; default: b = 5'b00000;
                endcase
                "K": case(row)
                    3'd0: b = 5'b10001; 3'd1: b = 5'b10010; 3'd2: b = 5'b10100;
                    3'd3: b = 5'b11000; 3'd4: b = 5'b10100; 3'd5: b = 5'b10010;
                    3'd6: b = 5'b10001; default: b = 5'b00000;
                endcase
                "L": case(row)
                    3'd0: b = 5'b10000; 3'd1: b = 5'b10000; 3'd2: b = 5'b10000;
                    3'd3: b = 5'b10000; 3'd4: b = 5'b10000; 3'd5: b = 5'b10000;
                    3'd6: b = 5'b11111; default: b = 5'b00000;
                endcase
                "M": case(row)
                    3'd0: b = 5'b10001; 3'd1: b = 5'b11011; 3'd2: b = 5'b10101;
                    3'd3: b = 5'b10001; 3'd4: b = 5'b10001; 3'd5: b = 5'b10001;
                    3'd6: b = 5'b10001; default: b = 5'b00000;
                endcase
                "N": case(row)
                    3'd0: b = 5'b10001; 3'd1: b = 5'b11001; 3'd2: b = 5'b10101;
                    3'd3: b = 5'b10011; 3'd4: b = 5'b10001; 3'd5: b = 5'b10001;
                    3'd6: b = 5'b10001; default: b = 5'b00000;
                endcase
                "O": case(row)
                    3'd0: b = 5'b01110; 3'd1: b = 5'b10001; 3'd2: b = 5'b10001;
                    3'd3: b = 5'b10001; 3'd4: b = 5'b10001; 3'd5: b = 5'b10001;
                    3'd6: b = 5'b01110; default: b = 5'b00000;
                endcase
                "P": case(row)
                    3'd0: b = 5'b11110; 3'd1: b = 5'b10001; 3'd2: b = 5'b10001;
                    3'd3: b = 5'b11110; 3'd4: b = 5'b10000; 3'd5: b = 5'b10000;
                    3'd6: b = 5'b10000; default: b = 5'b00000;
                endcase
                "R": case(row)
                    3'd0: b = 5'b11110; 3'd1: b = 5'b10001; 3'd2: b = 5'b10001;
                    3'd3: b = 5'b11110; 3'd4: b = 5'b10100; 3'd5: b = 5'b10010;
                    3'd6: b = 5'b10001; default: b = 5'b00000;
                endcase
                "S": case(row)
                    3'd0: b = 5'b01111; 3'd1: b = 5'b10000; 3'd2: b = 5'b10000;
                    3'd3: b = 5'b01110; 3'd4: b = 5'b00001; 3'd5: b = 5'b00001;
                    3'd6: b = 5'b11110; default: b = 5'b00000;
                endcase
                "T": case(row)
                    3'd0: b = 5'b11111; 3'd1: b = 5'b00100; 3'd2: b = 5'b00100;
                    3'd3: b = 5'b00100; 3'd4: b = 5'b00100; 3'd5: b = 5'b00100;
                    3'd6: b = 5'b00100; default: b = 5'b00000;
                endcase
                "U": case(row)
                    3'd0: b = 5'b10001; 3'd1: b = 5'b10001; 3'd2: b = 5'b10001;
                    3'd3: b = 5'b10001; 3'd4: b = 5'b10001; 3'd5: b = 5'b10001;
                    3'd6: b = 5'b01110; default: b = 5'b00000;
                endcase
                "V": case(row)
                    3'd0: b = 5'b10001; 3'd1: b = 5'b10001; 3'd2: b = 5'b10001;
                    3'd3: b = 5'b10001; 3'd4: b = 5'b01010; 3'd5: b = 5'b01010;
                    3'd6: b = 5'b00100; default: b = 5'b00000;
                endcase
                "X": case(row)
                    3'd0: b = 5'b10001; 3'd1: b = 5'b01010; 3'd2: b = 5'b00100;
                    3'd3: b = 5'b00100; 3'd4: b = 5'b01010; 3'd5: b = 5'b10001;
                    3'd6: b = 5'b10001; default: b = 5'b00000;
                endcase
                "Y": case(row)
                    3'd0: b = 5'b10001; 3'd1: b = 5'b01010; 3'd2: b = 5'b00100;
                    3'd3: b = 5'b00100; 3'd4: b = 5'b00100; 3'd5: b = 5'b00100;
                    3'd6: b = 5'b00100; default: b = 5'b00000;
                endcase
                "Z": case(row)
                    3'd0: b = 5'b11111; 3'd1: b = 5'b00001; 3'd2: b = 5'b00010;
                    3'd3: b = 5'b00100; 3'd4: b = 5'b01000; 3'd5: b = 5'b10000;
                    3'd6: b = 5'b11111; default: b = 5'b00000;
                endcase
                default: b = 5'b00000;
            endcase
            font_dot = b[3'd4 - col];
        end
    endfunction

    function [7:0] to_hex_char;
        input [3:0] n;
        begin
            to_hex_char = (n < 4'd10) ? ("0" + {4'd0, n}) : ("A" + {4'd0, n - 4'd10});
        end
    endfunction

    // -------------------------------------------------------------------------
    // 2. Pixel Coordinate Tracker (800 x 480)
    // -------------------------------------------------------------------------
    reg [9:0] px;
    reg [8:0] py;

    // Decimal conversion for distance_mm (0..9999)
    wire [13:0] d_val = (distance_mm > 16'd9999) ? 14'd9999 : distance_mm[13:0];
    wire [3:0]  d_th  = d_val / 1000;
    wire [13:0] r_th  = d_val % 1000;
    wire [3:0]  d_hu  = r_th / 100;
    wire [13:0] r_hu  = r_th % 100;
    wire [3:0]  d_te  = r_hu / 10;
    wire [3:0]  d_un  = r_hu % 10;

    // -------------------------------------------------------------------------
    // 3. UI Element Renderer (Color Generation based on (px, py))
    // -------------------------------------------------------------------------
    reg [15:0] pixel_color;

    // Colors (RGB565)
    localparam [15:0]
        C_BLACK    = 16'h0000,
        C_DARK_BG  = 16'h0821, // Very dark navy
        C_PANEL_BG = 16'h1084, // Dark slate panel
        C_BORDER   = 16'h31A6,
        C_WHITE    = 16'hFFFF,
        C_CYAN     = 16'h07FF,
        C_GREEN    = 16'h07E0,
        C_RED      = 16'hF800,
        C_YELLOW   = 16'hFFE0,
        C_GRAY     = 16'h7BEF,
        C_ORANGE   = 16'hFD20,
        C_HEADER   = 16'h0237;

    // Big digit rendering helper (Scale = 4x: 20x28 px per char)
    function is_big_char;
        input [9:0] x_start;
        input [8:0] y_start;
        input [7:0] ch;
        input [9:0] cur_x;
        input [8:0] cur_y;
        reg [9:0] rel_x;
        reg [8:0] rel_y;
        begin
            if (cur_x >= x_start && cur_x < x_start + 10'd20 &&
                cur_y >= y_start && cur_y < y_start + 9'd28) begin
                rel_x = cur_x - x_start;
                rel_y = cur_y - y_start;
                is_big_char = font_dot(ch, rel_x[4:2], rel_y[4:2]);
            end else begin
                is_big_char = 1'b0;
            end
        end
    endfunction

    // Normal text helper (Scale = 2x: 10x14 px per char)
    function is_norm_char;
        input [9:0] x_start;
        input [8:0] y_start;
        input [7:0] ch;
        input [9:0] cur_x;
        input [8:0] cur_y;
        reg [9:0] rel_x;
        reg [8:0] rel_y;
        begin
            if (cur_x >= x_start && cur_x < x_start + 10'd10 &&
                cur_y >= y_start && cur_y < y_start + 9'd14) begin
                rel_x = cur_x - x_start;
                rel_y = cur_y - y_start;
                is_norm_char = font_dot(ch, rel_x[3:1], rel_y[3:1]);
            end else begin
                is_norm_char = 1'b0;
            end
        end
    endfunction

    // String drawing logic
    always @(*) begin
        pixel_color = C_DARK_BG;

        // 1. Header (py: 0..36)
        if (py < 9'd36) begin
            pixel_color = C_HEADER;
            if (py == 9'd35) pixel_color = C_CYAN;
            // Title text: "TANG MEGA 138K - TOF SENSOR DEBUGGER" (35 chars, x=150..500)
            if (is_norm_char(10'd150, 9'd10, "T", px, py) ||
                is_norm_char(10'd162, 9'd10, "A", px, py) ||
                is_norm_char(10'd174, 9'd10, "N", px, py) ||
                is_norm_char(10'd186, 9'd10, "G", px, py) ||
                is_norm_char(10'd204, 9'd10, "M", px, py) ||
                is_norm_char(10'd216, 9'd10, "E", px, py) ||
                is_norm_char(10'd228, 9'd10, "G", px, py) ||
                is_norm_char(10'd240, 9'd10, "A", px, py) ||
                is_norm_char(10'd258, 9'd10, "1", px, py) ||
                is_norm_char(10'd270, 9'd10, "3", px, py) ||
                is_norm_char(10'd282, 9'd10, "8", px, py) ||
                is_norm_char(10'd294, 9'd10, "K", px, py) ||
                is_norm_char(10'd312, 9'd10, "-", px, py) ||
                is_norm_char(10'd330, 9'd10, "T", px, py) ||
                is_norm_char(10'd342, 9'd10, "O", px, py) ||
                is_norm_char(10'd354, 9'd10, "F", px, py) ||
                is_norm_char(10'd372, 9'd10, "D", px, py) ||
                is_norm_char(10'd384, 9'd10, "E", px, py) ||
                is_norm_char(10'd396, 9'd10, "B", px, py) ||
                is_norm_char(10'd408, 9'd10, "U", px, py) ||
                is_norm_char(10'd420, 9'd10, "G", px, py) ||
                is_norm_char(10'd432, 9'd10, "G", px, py) ||
                is_norm_char(10'd444, 9'd10, "E", px, py) ||
                is_norm_char(10'd456, 9'd10, "R", px, py))
                pixel_color = C_WHITE;
        end

        // 2. Left Panel: Status Card (px: 20..380, py: 50..180)
        else if (px >= 10'd20 && px <= 10'd380 && py >= 9'd50 && py <= 9'd180) begin
            if (px == 10'd20 || px == 10'd380 || py == 9'd50 || py == 9'd180)
                pixel_color = C_BORDER;
            else begin
                pixel_color = C_PANEL_BG;

                // Line 1: BUS 1 (A18/D15) SCL:x SDA:x
                if (is_norm_char(10'd35, 9'd60, "B", px, py) ||
                    is_norm_char(10'd47, 9'd60, "U", px, py) ||
                    is_norm_char(10'd59, 9'd60, "S", px, py) ||
                    is_norm_char(10'd71, 9'd60, "1", px, py) ||
                    is_norm_char(10'd83, 9'd60, ":", px, py) ||
                    is_norm_char(10'd101, 9'd60, "A", px, py) ||
                    is_norm_char(10'd113, 9'd60, "1", px, py) ||
                    is_norm_char(10'd125, 9'd60, "8", px, py) ||
                    is_norm_char(10'd137, 9'd60, "/", px, py) ||
                    is_norm_char(10'd149, 9'd60, "D", px, py) ||
                    is_norm_char(10'd161, 9'd60, "1", px, py) ||
                    is_norm_char(10'd173, 9'd60, "5", px, py) ||
                    is_norm_char(10'd210, 9'd60, "S", px, py) ||
                    is_norm_char(10'd222, 9'd60, "C", px, py) ||
                    is_norm_char(10'd234, 9'd60, "L", px, py) ||
                    is_norm_char(10'd246, 9'd60, ":", px, py) ||
                    is_norm_char(10'd258, 9'd60, scl1_raw ? "1" : "0", px, py) ||
                    is_norm_char(10'd285, 9'd60, "S", px, py) ||
                    is_norm_char(10'd297, 9'd60, "D", px, py) ||
                    is_norm_char(10'd309, 9'd60, "A", px, py) ||
                    is_norm_char(10'd321, 9'd60, ":", px, py) ||
                    is_norm_char(10'd333, 9'd60, sda1_raw ? "1" : "0", px, py))
                    pixel_color = (active_bus == 1'b0) ? C_CYAN : C_GRAY;

                // Line 2: BUS 2 (F14/F13) SCL:x SDA:x
                else if (is_norm_char(10'd35, 9'd85, "B", px, py) ||
                         is_norm_char(10'd47, 9'd85, "U", px, py) ||
                         is_norm_char(10'd59, 9'd85, "S", px, py) ||
                         is_norm_char(10'd71, 9'd85, "2", px, py) ||
                         is_norm_char(10'd83, 9'd85, ":", px, py) ||
                         is_norm_char(10'd101, 9'd85, "F", px, py) ||
                         is_norm_char(10'd113, 9'd85, "1", px, py) ||
                         is_norm_char(10'd125, 9'd85, "4", px, py) ||
                         is_norm_char(10'd137, 9'd85, "/", px, py) ||
                         is_norm_char(10'd149, 9'd85, "F", px, py) ||
                         is_norm_char(10'd161, 9'd85, "1", px, py) ||
                         is_norm_char(10'd173, 9'd85, "3", px, py) ||
                         is_norm_char(10'd210, 9'd85, "S", px, py) ||
                         is_norm_char(10'd222, 9'd85, "C", px, py) ||
                         is_norm_char(10'd234, 9'd85, "L", px, py) ||
                         is_norm_char(10'd246, 9'd85, ":", px, py) ||
                         is_norm_char(10'd258, 9'd85, scl2_raw ? "1" : "0", px, py) ||
                         is_norm_char(10'd285, 9'd85, "S", px, py) ||
                         is_norm_char(10'd297, 9'd85, "D", px, py) ||
                         is_norm_char(10'd309, 9'd85, "A", px, py) ||
                         is_norm_char(10'd321, 9'd85, ":", px, py) ||
                         is_norm_char(10'd333, 9'd85, sda2_raw ? "1" : "0", px, py))
                    pixel_color = (active_bus == 1'b1) ? C_CYAN : C_GRAY;

                // Line 3: ACTIVE: BUS x  ADDR: 0x52
                else if (is_norm_char(10'd35, 9'd115, "A", px, py) ||
                         is_norm_char(10'd47, 9'd115, "C", px, py) ||
                         is_norm_char(10'd59, 9'd115, "T", px, py) ||
                         is_norm_char(10'd71, 9'd115, "I", px, py) ||
                         is_norm_char(10'd83, 9'd115, "V", px, py) ||
                         is_norm_char(10'd95, 9'd115, "E", px, py) ||
                         is_norm_char(10'd107, 9'd115, ":", px, py) ||
                         is_norm_char(10'd125, 9'd115, "B", px, py) ||
                         is_norm_char(10'd137, 9'd115, "U", px, py) ||
                         is_norm_char(10'd149, 9'd115, "S", px, py) ||
                         is_norm_char(10'd167, 9'd115, active_bus ? "2" : "1", px, py) ||
                         is_norm_char(10'd195, 9'd115, "A", px, py) ||
                         is_norm_char(10'd207, 9'd115, "D", px, py) ||
                         is_norm_char(10'd219, 9'd115, "D", px, py) ||
                         is_norm_char(10'd231, 9'd115, "R", px, py) ||
                         is_norm_char(10'd243, 9'd115, ":", px, py) ||
                         is_norm_char(10'd261, 9'd115, "0", px, py) ||
                         is_norm_char(10'd273, 9'd115, "X", px, py) ||
                         is_norm_char(10'd285, 9'd115, to_hex_char({1'b0, active_addr[6:4]}), px, py) ||
                         is_norm_char(10'd297, 9'd115, to_hex_char(active_addr[3:0]), px, py))
                    pixel_color = C_YELLOW;

                // Line 4: STATUS: ONLINE/OFFLINE  ID: 0x4A
                else if (is_norm_char(10'd35, 9'd145, "S", px, py) ||
                         is_norm_char(10'd47, 9'd145, "T", px, py) ||
                         is_norm_char(10'd59, 9'd145, "A", px, py) ||
                         is_norm_char(10'd71, 9'd145, "T", px, py) ||
                         is_norm_char(10'd83, 9'd145, "U", px, py) ||
                         is_norm_char(10'd95, 9'd145, "S", px, py) ||
                         is_norm_char(10'd107, 9'd145, ":", px, py))
                    pixel_color = C_WHITE;
                else if (sensor_online && (
                         is_norm_char(10'd125, 9'd145, "O", px, py) ||
                         is_norm_char(10'd137, 9'd145, "N", px, py) ||
                         is_norm_char(10'd149, 9'd145, "L", px, py) ||
                         is_norm_char(10'd161, 9'd145, "I", px, py) ||
                         is_norm_char(10'd173, 9'd145, "N", px, py) ||
                         is_norm_char(10'd185, 9'd145, "E", px, py)))
                    pixel_color = C_GREEN;
                else if (!sensor_online && (
                         is_norm_char(10'd125, 9'd145, "N", px, py) ||
                         is_norm_char(10'd137, 9'd145, "A", px, py) ||
                         is_norm_char(10'd149, 9'd145, "C", px, py) ||
                         is_norm_char(10'd161, 9'd145, "K", px, py)))
                    pixel_color = C_RED;
                else if (is_norm_char(10'd215, 9'd145, "I", px, py) ||
                         is_norm_char(10'd227, 9'd145, "D", px, py) ||
                         is_norm_char(10'd239, 9'd145, ":", px, py) ||
                         is_norm_char(10'd255, 9'd145, "0", px, py) ||
                         is_norm_char(10'd267, 9'd145, "X", px, py) ||
                         is_norm_char(10'd279, 9'd145, to_hex_char(sensor_dev_id[7:4]), px, py) ||
                         is_norm_char(10'd291, 9'd145, to_hex_char(sensor_dev_id[3:0]), px, py))
                    pixel_color = (sensor_dev_id == 8'h4A) ? C_GREEN : C_WHITE;
            end
        end

        // 3. Left Panel: Big Distance & Dynamic Visual Gauge (px: 20..380, py: 200..460)
        else if (px >= 10'd20 && px <= 10'd380 && py >= 9'd200 && py <= 9'd460) begin
            if (px == 10'd20 || px == 10'd380 || py == 9'd200 || py == 9'd460)
                pixel_color = C_BORDER;
            else begin
                pixel_color = C_PANEL_BG;

                // Section Label: "MEASURED DISTANCE"
                if (is_norm_char(10'd35, 9'd215, "M", px, py) ||
                    is_norm_char(10'd47, 9'd215, "E", px, py) ||
                    is_norm_char(10'd59, 9'd215, "A", px, py) ||
                    is_norm_char(10'd71, 9'd215, "S", px, py) ||
                    is_norm_char(10'd83, 9'd215, "U", px, py) ||
                    is_norm_char(10'd95, 9'd215, "R", px, py) ||
                    is_norm_char(10'd107, 9'd215, "E", px, py) ||
                    is_norm_char(10'd119, 9'd215, "D", px, py) ||
                    is_norm_char(10'd137, 9'd215, "D", px, py) ||
                    is_norm_char(10'd149, 9'd215, "I", px, py) ||
                    is_norm_char(10'd161, 9'd215, "S", px, py) ||
                    is_norm_char(10'd173, 9'd215, "T", px, py) ||
                    is_norm_char(10'd185, 9'd215, "A", px, py) ||
                    is_norm_char(10'd197, 9'd215, "N", px, py) ||
                    is_norm_char(10'd209, 9'd215, "C", px, py) ||
                    is_norm_char(10'd221, 9'd215, "E", px, py))
                    pixel_color = C_CYAN;

                // Big Digits (Scale 4x): "1234 mm" or "---- mm" (x: 45..350, y: 250..280)
                else if (sensor_online && distance_mm != 16'hFFFF) begin
                    if (is_big_char(10'd55,  9'd250, (d_th > 0) ? ("0" + {4'd0, d_th}) : " ", px, py) ||
                        is_big_char(10'd85,  9'd250, (d_th > 0 || d_hu > 0) ? ("0" + {4'd0, d_hu}) : " ", px, py) ||
                        is_big_char(10'd115, 9'd250, (d_th > 0 || d_hu > 0 || d_te > 0) ? ("0" + {4'd0, d_te}) : " ", px, py) ||
                        is_big_char(10'd145, 9'd250, "0" + {4'd0, d_un}, px, py) ||
                        is_big_char(10'd185, 9'd250, "M", px, py) ||
                        is_big_char(10'd215, 9'd250, "M", px, py))
                        pixel_color = C_GREEN;
                end else begin
                    if (is_big_char(10'd55,  9'd250, "-", px, py) ||
                        is_big_char(10'd85,  9'd250, "-", px, py) ||
                        is_big_char(10'd115, 9'd250, "-", px, py) ||
                        is_big_char(10'd145, 9'd250, "-", px, py) ||
                        is_big_char(10'd185, 9'd250, "M", px, py) ||
                        is_big_char(10'd215, 9'd250, "M", px, py))
                        pixel_color = C_RED;
                end

                // Dynamic Progress Bar (x: 45..355, y: 310..340, width=310 px)
                if (px >= 10'd45 && px <= 10'd355 && py >= 9'd310 && py <= 9'd340) begin
                    if (px == 10'd45 || px == 10'd355 || py == 9'd310 || py == 9'd340)
                        pixel_color = C_BORDER;
                    else begin
                        // Map 0..1000 mm -> 0..308 px
                        // filled_width = (distance_mm * 308) / 1000
                        if (sensor_online && (px - 10'd46) < ((distance_mm > 16'd1000) ? 10'd308 : (distance_mm * 10'd308) / 10'd1000)) begin
                            if (distance_mm < 16'd200)       pixel_color = C_GREEN;
                            else if (distance_mm < 16'd500)  pixel_color = C_YELLOW;
                            else if (distance_mm < 16'd800)  pixel_color = C_ORANGE;
                            else                             pixel_color = C_CYAN;
                        end else begin
                            pixel_color = C_BLACK;
                        end
                    end
                end

                // Statistics: ACK: xxxxx  NACK: xxxxx
                if (is_norm_char(10'd35, 9'd370, "A", px, py) ||
                    is_norm_char(10'd47, 9'd370, "C", px, py) ||
                    is_norm_char(10'd59, 9'd370, "K", px, py) ||
                    is_norm_char(10'd71, 9'd370, ":", px, py) ||
                    is_norm_char(10'd85, 9'd370, to_hex_char(ack_counter[15:12]), px, py) ||
                    is_norm_char(10'd97, 9'd370, to_hex_char(ack_counter[11:8]), px, py) ||
                    is_norm_char(10'd109, 9'd370, to_hex_char(ack_counter[7:4]), px, py) ||
                    is_norm_char(10'd121, 9'd370, to_hex_char(ack_counter[3:0]), px, py) ||
                    is_norm_char(10'd165, 9'd370, "N", px, py) ||
                    is_norm_char(10'd177, 9'd370, "A", px, py) ||
                    is_norm_char(10'd189, 9'd370, "C", px, py) ||
                    is_norm_char(10'd201, 9'd370, "K", px, py) ||
                    is_norm_char(10'd213, 9'd370, ":", px, py) ||
                    is_norm_char(10'd227, 9'd370, to_hex_char(nack_counter[15:12]), px, py) ||
                    is_norm_char(10'd239, 9'd370, to_hex_char(nack_counter[11:8]), px, py) ||
                    is_norm_char(10'd251, 9'd370, to_hex_char(nack_counter[7:4]), px, py) ||
                    is_norm_char(10'd263, 9'd370, to_hex_char(nack_counter[3:0]), px, py))
                    pixel_color = C_WHITE;

                // Help hint: "PRESS KEY0 TO RESCAN BUS"
                if (is_norm_char(10'd35, 9'd415, "P", px, py) ||
                    is_norm_char(10'd47, 9'd415, "R", px, py) ||
                    is_norm_char(10'd59, 9'd415, "E", px, py) ||
                    is_norm_char(10'd71, 9'd415, "S", px, py) ||
                    is_norm_char(10'd83, 9'd415, "S", px, py) ||
                    is_norm_char(10'd105, 9'd415, "K", px, py) ||
                    is_norm_char(10'd117, 9'd415, "E", px, py) ||
                    is_norm_char(10'd129, 9'd415, "Y", px, py) ||
                    is_norm_char(10'd141, 9'd415, "0", px, py) ||
                    is_norm_char(10'd163, 9'd415, "T", px, py) ||
                    is_norm_char(10'd175, 9'd415, "O", px, py) ||
                    is_norm_char(10'd197, 9'd415, "R", px, py) ||
                    is_norm_char(10'd209, 9'd415, "E", px, py) ||
                    is_norm_char(10'd221, 9'd415, "S", px, py) ||
                    is_norm_char(10'd233, 9'd415, "C", px, py) ||
                    is_norm_char(10'd245, 9'd415, "A", px, py) ||
                    is_norm_char(10'd257, 9'd415, "N", px, py))
                    pixel_color = C_GRAY;
            end
        end

        // 4. Right Panel: I2C Scanner Matrix (px: 410..770, py: 50..460)
        else if (px >= 10'd410 && px <= 10'd770 && py >= 9'd50 && py <= 9'd460) begin
            if (px == 10'd410 || px == 10'd770 || py == 9'd50 || py == 9'd460)
                pixel_color = C_BORDER;
            else begin
                pixel_color = C_PANEL_BG;

                // Matrix Title
                if (is_norm_char(10'd430, 9'd65, "I", px, py) ||
                    is_norm_char(10'd442, 9'd65, "2", px, py) ||
                    is_norm_char(10'd454, 9'd65, "C", px, py) ||
                    is_norm_char(10'd472, 9'd65, "S", px, py) ||
                    is_norm_char(10'd484, 9'd65, "C", px, py) ||
                    is_norm_char(10'd496, 9'd65, "A", px, py) ||
                    is_norm_char(10'd508, 9'd65, "N", px, py) ||
                    is_norm_char(10'd526, 9'd65, "M", px, py) ||
                    is_norm_char(10'd538, 9'd65, "A", px, py) ||
                    is_norm_char(10'd550, 9'd65, "P", px, py) ||
                    is_norm_char(10'd570, 9'd65, "[", px, py) ||
                    is_norm_char(10'd582, 9'd65, "B", px, py) ||
                    is_norm_char(10'd594, 9'd65, "U", px, py) ||
                    is_norm_char(10'd606, 9'd65, "S", px, py) ||
                    is_norm_char(10'd624, 9'd65, active_bus ? "2" : "1", px, py) ||
                    is_norm_char(10'd636, 9'd65, "]", px, py))
                    pixel_color = C_YELLOW;

                // 16 Columns Header (0 1 2 3 4 5 6 7 8 9 A B C D E F)
                // Grid bounds: x: 460..748 (16 cols x 18 px = 288 px), y: 110..350 (8 rows x 30 px = 240 px)
                else if (py >= 9'd95 && py <= 9'd105 && px >= 10'd460 && px < 10'd748) begin
                    // Print column index
                    pixel_color = C_CYAN;
                end
                // Grid Cells
                else if (px >= 10'd460 && px < 10'd748 && py >= 9'd110 && py < 9'd350) begin
                    // Compute row (0..7) and col (0..15)
                    begin : grid_cell
                        reg [2:0] crow;
                        reg [3:0] ccol;
                        reg [6:0] cell_addr;
                        reg       hit;
                        crow = (py - 9'd110) / 9'd30;
                        ccol = (px - 10'd460) / 10'd18;
                        cell_addr = {crow, ccol};
                        hit = active_bus ? scan_bitmap_2[cell_addr] : scan_bitmap_1[cell_addr];

                        if (hit) begin
                            // Highlight detected device in glowing green
                            pixel_color = C_GREEN;
                        end else if (cell_addr >= 7'h08 && cell_addr <= 7'h77) begin
                            // Valid address slot, subtle gray dot
                            if ((px % 18 == 8) && (py % 30 == 15))
                                pixel_color = C_GRAY;
                            else
                                pixel_color = C_BLACK;
                        end else begin
                            pixel_color = C_PANEL_BG;
                        end
                    end
                end

                // Legend at bottom of right panel
                if (is_norm_char(10'd430, 9'd390, "G", px, py) ||
                    is_norm_char(10'd442, 9'd390, "R", px, py) ||
                    is_norm_char(10'd454, 9'd390, "E", px, py) ||
                    is_norm_char(10'd466, 9'd390, "E", px, py) ||
                    is_norm_char(10'd478, 9'd390, "N", px, py) ||
                    is_norm_char(10'd496, 9'd390, "=", px, py) ||
                    is_norm_char(10'd514, 9'd390, "D", px, py) ||
                    is_norm_char(10'd526, 9'd390, "E", px, py) ||
                    is_norm_char(10'd538, 9'd390, "V", px, py) ||
                    is_norm_char(10'd550, 9'd390, "I", px, py) ||
                    is_norm_char(10'd562, 9'd390, "C", px, py) ||
                    is_norm_char(10'd574, 9'd390, "E", px, py) ||
                    is_norm_char(10'd596, 9'd390, "A", px, py) ||
                    is_norm_char(10'd608, 9'd390, "C", px, py) ||
                    is_norm_char(10'd620, 9'd390, "K", px, py))
                    pixel_color = C_GREEN;
            end
        end
    end

    // -------------------------------------------------------------------------
    // 4. SSD1963 8080 LCD Controller State Machine (Direct RTL)
    // -------------------------------------------------------------------------
    localparam [2:0]
        L_INIT_RST = 3'd0,
        L_INIT_ROM = 3'd1,
        L_FRAME_ST = 3'd2,
        L_PIX_WR   = 3'd3;

    reg [2:0]  l_state;
    reg [23:0] l_timer;
    reg [7:0]  rom_idx;

    reg [15:0] db_r;
    assign lcd_db = db_r;

    // SSD1963 initialization ROM sequence
    localparam ROM_LEN = 62;
    reg [23:0] rom_cmd [0:61];
    initial begin
        rom_cmd[0]  = {1'b0, 8'hE2, 15'd0};  // CMD 0xE2
        rom_cmd[1]  = {1'b1, 8'h1D, 15'd0};  // DAT 0x1D
        rom_cmd[2]  = {1'b1, 8'h02, 15'd0};  // DAT 0x02
        rom_cmd[3]  = {1'b1, 8'h04, 15'd0};  // DAT 0x04
        rom_cmd[4]  = {1'b0, 8'hE0, 15'd0};  // CMD 0xE0
        rom_cmd[5]  = {1'b1, 8'h01, 15'd100};// DAT 0x01 (delay 100)
        rom_cmd[6]  = {1'b0, 8'hE0, 15'd0};  // CMD 0xE0
        rom_cmd[7]  = {1'b1, 8'h03, 15'd100};// DAT 0x03
        rom_cmd[8]  = {1'b0, 8'h01, 15'd500};// CMD 0x01 (Soft reset)
        rom_cmd[9]  = {1'b0, 8'hE6, 15'd0};  // CMD 0xE6 (PCLK)
        rom_cmd[10] = {1'b1, 8'h05, 15'd0};
        rom_cmd[11] = {1'b1, 8'h53, 15'd0};
        rom_cmd[12] = {1'b1, 8'hF6, 15'd0};  // 33.3 MHz PCLK
        rom_cmd[13] = {1'b0, 8'hB0, 15'd0};  // CMD 0xB0 (LCD Mode)
        rom_cmd[14] = {1'b1, 8'h20, 15'd0};
        rom_cmd[15] = {1'b1, 8'h00, 15'd0};
        rom_cmd[16] = {1'b1, 8'h03, 15'd0};
        rom_cmd[17] = {1'b1, 8'h1F, 15'd0};  // 799
        rom_cmd[18] = {1'b1, 8'h01, 15'd0};
        rom_cmd[19] = {1'b1, 8'hDF, 15'd0};  // 479
        rom_cmd[20] = {1'b1, 8'h00, 15'd0};
        rom_cmd[21] = {1'b0, 8'hB4, 15'd0};  // H-period
        rom_cmd[22] = {1'b1, 8'h04, 15'd0};
        rom_cmd[23] = {1'b1, 8'h1F, 15'd0};  // HT=1055
        rom_cmd[24] = {1'b1, 8'h00, 15'd0};
        rom_cmd[25] = {1'b1, 8'h2E, 15'd0};  // HPS=46
        rom_cmd[26] = {1'b1, 8'h00, 15'd0};
        rom_cmd[27] = {1'b1, 8'h00, 15'd0};
        rom_cmd[28] = {1'b1, 8'h00, 15'd0};
        rom_cmd[29] = {1'b1, 8'h00, 15'd0};
        rom_cmd[30] = {1'b0, 8'hB6, 15'd0};  // V-period
        rom_cmd[31] = {1'b1, 8'h02, 15'd0};
        rom_cmd[32] = {1'b1, 8'h0C, 15'd0};  // VT=524
        rom_cmd[33] = {1'b1, 8'h00, 15'd0};
        rom_cmd[34] = {1'b1, 8'h17, 15'd0};  // VPS=23
        rom_cmd[35] = {1'b1, 8'h16, 15'd0};
        rom_cmd[36] = {1'b1, 8'h00, 15'd0};
        rom_cmd[37] = {1'b1, 8'h00, 15'd0};
        rom_cmd[38] = {1'b0, 8'hF0, 15'd0};  // Pixel format
        rom_cmd[39] = {1'b1, 8'h03, 15'd0};  // 16-bit 565
        rom_cmd[40] = {1'b0, 8'h29, 15'd0};  // Display ON
        rom_cmd[41] = {1'b0, 8'hBE, 15'd0};  // PWM backlight
        rom_cmd[42] = {1'b1, 8'h05, 15'd0};
        rom_cmd[43] = {1'b1, 8'hFE, 15'd0};
        rom_cmd[44] = {1'b1, 8'h01, 15'd0};
        rom_cmd[45] = {1'b1, 8'h00, 15'd0};
        rom_cmd[46] = {1'b1, 8'h00, 15'd0};
        rom_cmd[47] = {1'b1, 8'h00, 15'd0};
        rom_cmd[48] = {1'b0, 8'h2A, 15'd0};  // Column Address Set
        rom_cmd[49] = {1'b1, 8'h00, 15'd0};
        rom_cmd[50] = {1'b1, 8'h00, 15'd0};
        rom_cmd[51] = {1'b1, 8'h03, 15'd0};
        rom_cmd[52] = {1'b1, 8'h1F, 15'd0};  // 799
        rom_cmd[53] = {1'b0, 8'h2B, 15'd0};  // Page Address Set
        rom_cmd[54] = {1'b1, 8'h00, 15'd0};
        rom_cmd[55] = {1'b1, 8'h00, 15'd0};
        rom_cmd[56] = {1'b1, 8'h01, 15'd0};
        rom_cmd[57] = {1'b1, 8'hDF, 15'd0};  // 479
        rom_cmd[58] = {1'b0, 8'h2C, 15'd0};  // Memory Write
        rom_cmd[59] = {1'b0, 8'h00, 15'd0};
        rom_cmd[60] = {1'b0, 8'h00, 15'd0};
        rom_cmd[61] = {1'b0, 8'h00, 15'd0};
    end

    reg [3:0] init_phase;
    reg [2:0] pix_sub_phase;

    always @(posedge clk) begin
        if (!rst_n) begin
            l_state       <= L_INIT_RST;
            l_timer       <= 24'd2500000; // 50ms HW reset dwell
            rom_idx       <= 8'd0;
            init_phase    <= 4'd0;
            pix_sub_phase <= 3'd0;
            px            <= 10'd0;
            py            <= 9'd0;
            lcd_cs        <= 1'b1;
            lcd_rs        <= 1'b1;
            lcd_wr        <= 1'b1;
            lcd_rd        <= 1'b1;
            lcd_rst       <= 1'b0;
            db_r          <= 16'h0000;
        end else begin
            case (l_state)
                L_INIT_RST: begin
                    if (l_timer != 24'd0) begin
                        l_timer <= l_timer - 1'b1;
                        if (l_timer == 24'd1250000) lcd_rst <= 1'b1; // Release reset
                    end else begin
                        l_state    <= L_INIT_ROM;
                        rom_idx    <= 8'd0;
                        init_phase <= 4'd0;
                    end
                end

                L_INIT_ROM: begin
                    case (init_phase)
                        4'd0: begin
                            // Setup command/data
                            lcd_cs <= 1'b0;
                            lcd_rs <= rom_cmd[rom_idx][23]; // 0=CMD, 1=DAT
                            db_r   <= {8'h00, rom_cmd[rom_idx][22:15]};
                            lcd_wr <= 1'b0;
                            init_phase <= 4'd1;
                        end
                        4'd1, 4'd2: begin
                            init_phase <= init_phase + 1'b1;
                        end
                        4'd3: begin
                            lcd_wr <= 1'b1; // Latch
                            init_phase <= 4'd4;
                        end
                        4'd4: begin
                            lcd_cs <= 1'b1;
                            if (rom_idx < 8'd58) begin
                                rom_idx    <= rom_idx + 1'b1;
                                init_phase <= 4'd0;
                            end else begin
                                // Finished init, start continuous frame streaming
                                l_state    <= L_FRAME_ST;
                                init_phase <= 4'd0;
                            end
                        end
                    endcase
                end

                L_FRAME_ST: begin
                    // Send 0x2A (col), 0x2B (page), 0x2C (mem write)
                    case (init_phase)
                        4'd0: begin
                            lcd_cs <= 1'b0; lcd_rs <= 1'b0; db_r <= 16'h002C; lcd_wr <= 1'b0;
                            init_phase <= 4'd1;
                        end
                        4'd1, 4'd2: init_phase <= init_phase + 1'b1;
                        4'd3: begin
                            lcd_wr <= 1'b1;
                            init_phase <= 4'd4;
                        end
                        4'd4: begin
                            lcd_rs <= 1'b1; // Ready for data
                            px <= 10'd0; py <= 9'd0;
                            pix_sub_phase <= 3'd0;
                            l_state <= L_PIX_WR;
                        end
                    endcase
                end

                L_PIX_WR: begin
                    case (pix_sub_phase)
                        3'd0: begin
                            db_r   <= pixel_color;
                            lcd_wr <= 1'b0;
                            pix_sub_phase <= 3'd1;
                        end
                        3'd1, 3'd2: begin
                            pix_sub_phase <= pix_sub_phase + 1'b1;
                        end
                        3'd3: begin
                            lcd_wr <= 1'b1; // Rising edge latches pixel
                            pix_sub_phase <= 3'd4;
                        end
                        3'd4: begin
                            pix_sub_phase <= 3'd0;
                            if (px == 10'd799) begin
                                px <= 10'd0;
                                if (py == 9'd479) begin
                                    py <= 9'd0;
                                    lcd_cs <= 1'b1;
                                    init_phase <= 4'd0;
                                    l_state <= L_FRAME_ST; // Next frame
                                end else begin
                                    py <= py + 1'b1;
                                end
                            end else begin
                                px <= px + 1'b1;
                            end
                        end
                    endcase
                end

                default: l_state <= L_INIT_RST;
            endcase
        end
    end

endmodule
`default_nettype wire
