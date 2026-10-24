// ============================================================================
// Module Name: lcd_test_top  (v5: Display + UART Diagnostics + Hardware Screenshot)
// Target     : Sipeed Tang Mega 138K NEO Dock (GW5AST-LV138PG484AC1/I0 = 138C)
// LCD        : ALIENTEK ATK-MD0700 V2.4 (SSD1963, 800x480, 16-bit 8080)
//
// Features:
//   1. Full SSD1963 initialization with 33.3 MHz pixel clock (0xE6 = 0x0553F6).
//   2. Per-frame register & pixel diagnostic telemetry over UART TX (U15, 115200 8N1).
//   3. Interactive UART RX (V14, 115200 8N1) commands from PC:
//      - 'q' / 'Q' : Capture 200x120 (4x4 subsampled) raw RGB565 screenshot
//                    directly from SSD1963 SRAM via CMD 0x2E ("IMGQ" + 48000B + "END!")
//      - 'c' / 'C' : Capture full 800x480 lossless RLE-compressed RGB565 screenshot
//                    directly from SSD1963 SRAM via CMD 0x2E ("IMGC" + RLE + "END!")
//      - '0'..'3'  : Lock screen to solid White / Red / Green / Blue
//      - '4'       : Lock screen to 8-Color Bar + White Border test pattern
//      - 'a' / 'A' : Resume automatic color cycling (White -> Red -> Green -> Blue)
// ============================================================================

module lcd_test_top (
    input  wire        sys_clk,    // 50MHz (V22)
    input  wire        sys_rst_n,  // reserved
    output reg         lcd_cs,
    output reg         lcd_rs,
    output reg         lcd_wr,
    output reg         lcd_rd,
    output reg         lcd_rst,
    inout  wire [15:0] lcd_db,
    output wire        ws_dout,
    output wire        uart_tx,    // U15 -> BL616 IO27_RX (PC COM8)
    input  wire        uart_rx     // V14 <- BL616 IO28_TX (PC COM8)
);

    // ------------------------------------------------------------------------
    // Data bus tri-state + 2-stage synchroniser on read data
    // ------------------------------------------------------------------------
    reg  [15:0] db_out;
    reg         db_oe;
    assign lcd_db = db_oe ? db_out : 16'hzzzz;

    reg [15:0] db_in_s1, db_in_s2;
    always @(posedge sys_clk) begin
        db_in_s1 <= lcd_db;
        db_in_s2 <= db_in_s1;
    end

    // ------------------------------------------------------------------------
    // Power-on reset (~10ms at 50MHz)
    // ------------------------------------------------------------------------
    reg [19:0] por_cnt = 20'd0;
    wire rst_n = por_cnt[19];
    always @(posedge sys_clk) if (!por_cnt[19]) por_cnt <= por_cnt + 1'b1;

    // ------------------------------------------------------------------------
    // Sequence ROM
    //   entry[31:30] kind : 00 = bus write, 01 = bus read (store byte(s)),
    //                       10 = delay (cycles in [23:0]), 11 = END of segment
    //   entry[29]    rs   : 0 = command, 1 = data
    //   entry[28]    w16  : for reads, store both bytes of the 16-bit word
    //   entry[23:0]  data / delay
    // ------------------------------------------------------------------------
    localparam K_WR = 2'b00, K_RD = 2'b01, K_DLY = 2'b10, K_END = 2'b11;

    `define C(x)   {K_WR , 1'b0, 1'b0, 4'd0, 24'h0 | (x)}
    `define D(x)   {K_WR , 1'b1, 1'b0, 4'd0, 24'h0 | (x)}
    `define R8     {K_RD , 1'b1, 1'b0, 4'd0, 24'h0}
    `define R16    {K_RD , 1'b1, 1'b1, 4'd0, 24'h0}
    `define DLY(x) {K_DLY, 1'b0, 1'b0, 4'd0, 24'h0 | (x)}
    `define ENDS   {K_END, 1'b0, 1'b0, 4'd0, 24'h0}

    // Segment start addresses
    localparam [7:0] SEG_INIT      = 8'd0;
    localparam [7:0] SEG_FRAME     = 8'd80;
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
        8'd7 : rom_q = `DLY(24'd500000);// 10ms
        8'd8 : rom_q = `C(8'hE0);
        8'd9 : rom_q = `D(8'h03);       // PLL lock
        8'd10: rom_q = `DLY(24'd600000);// 12ms
        8'd11: rom_q = `C(8'h01);       // soft reset
        8'd12: rom_q = `DLY(24'd500000);// 10ms
        // 0xE6 LSHIFT: datasheet p.76, LCDC_FPR[19:0], PCLK = PLL*(FPR+1)/2^20
        // 33.3MHz -> FPR = 349174 = 0x0553F6
        8'd13: rom_q = `C(8'hE6);
        8'd14: rom_q = `D(8'h05);
        8'd15: rom_q = `D(8'h53);
        8'd16: rom_q = `D(8'hF6);
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
        8'd47: rom_q = `C(8'hBE);       // PWM
        8'd48: rom_q = `D(8'h01);
        8'd49: rom_q = `D(8'h18);
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

        // ---------------- FRAME header (0x2A, 0x2B, 0x2C) ---------------
        8'd80: rom_q = `C(8'h2A);
        8'd81: rom_q = `D(8'h00);
        8'd82: rom_q = `D(8'h00);
        8'd83: rom_q = `D(8'h03);
        8'd84: rom_q = `D(8'h1F);       // col 0..799
        8'd85: rom_q = `C(8'h2B);
        8'd86: rom_q = `D(8'h00);
        8'd87: rom_q = `D(8'h00);
        8'd88: rom_q = `D(8'h01);
        8'd89: rom_q = `D(8'hDF);       // page 0..479
        8'd90: rom_q = `C(8'h2C);       // write_memory_start
        8'd91: rom_q = `ENDS;

        // ---------------- DIAG readback (32 bytes) ----------------------
        8'd100: rom_q = `C(8'hA1);
        8'd101: rom_q = `R8;
        8'd102: rom_q = `R8;
        8'd103: rom_q = `R8;
        8'd104: rom_q = `R8;
        8'd105: rom_q = `R8;            // 5
        8'd106: rom_q = `C(8'h0A);
        8'd107: rom_q = `R8;            // 6
        8'd108: rom_q = `C(8'hE4);
        8'd109: rom_q = `R8;            // 7
        8'd110: rom_q = `C(8'hF1);
        8'd111: rom_q = `R8;            // 8
        8'd112: rom_q = `C(8'h0B);
        8'd113: rom_q = `R8;            // 9
        8'd114: rom_q = `C(8'hB1);
        8'd115: rom_q = `R8;
        8'd116: rom_q = `R8;
        8'd117: rom_q = `R8;
        8'd118: rom_q = `R8;
        8'd119: rom_q = `R8;
        8'd120: rom_q = `R8;
        8'd121: rom_q = `R8;            // 16
        8'd122: rom_q = `C(8'hE7);
        8'd123: rom_q = `R8;
        8'd124: rom_q = `R8;
        8'd125: rom_q = `R8;            // 19
        8'd126: rom_q = `C(8'hBF);
        8'd127: rom_q = `R8;
        8'd128: rom_q = `R8;
        8'd129: rom_q = `R8;
        8'd130: rom_q = `R8;
        8'd131: rom_q = `R8;
        8'd132: rom_q = `R8;
        8'd133: rom_q = `R8;            // 26
        8'd134: rom_q = `C(8'h2A);
        8'd135: rom_q = `D(8'h00);
        8'd136: rom_q = `D(8'h00);
        8'd137: rom_q = `D(8'h00);
        8'd138: rom_q = `D(8'h0F);
        8'd139: rom_q = `C(8'h2B);
        8'd140: rom_q = `D(8'h00);
        8'd141: rom_q = `D(8'h00);
        8'd142: rom_q = `D(8'h00);
        8'd143: rom_q = `D(8'h0F);
        8'd144: rom_q = `C(8'h2E);
        8'd145: rom_q = `R16;
        8'd146: rom_q = `R16;
        8'd147: rom_q = `R16;           // 32
        8'd148: rom_q = `C(8'h00);      // NOP terminates memory read
        8'd149: rom_q = `ENDS;

        // ---------------- SCREENSHOT prep (0x2A 0..799, 0x2B 0..479, 0x2E)
        8'd160: rom_q = `C(8'h2A);
        8'd161: rom_q = `D(8'h00);
        8'd162: rom_q = `D(8'h00);
        8'd163: rom_q = `D(8'h03);
        8'd164: rom_q = `D(8'h1F);       // col 0..799
        8'd165: rom_q = `C(8'h2B);
        8'd166: rom_q = `D(8'h00);
        8'd167: rom_q = `D(8'h00);
        8'd168: rom_q = `D(8'h01);
        8'd169: rom_q = `D(8'hDF);       // page 0..479
        8'd170: rom_q = `C(8'h2E);       // read_memory_start
        8'd171: rom_q = `ENDS;

        default: rom_q = `ENDS;
        endcase
    end

    wire [1:0]  op_kind = rom_q[31:30];
    wire        op_rs   = rom_q[29];
    wire        op_w16  = rom_q[28];
    wire [23:0] op_data = rom_q[23:0];

    // ------------------------------------------------------------------------
    // Diag buffer (32 bytes) + snapshot for UART
    // ------------------------------------------------------------------------
    reg [7:0] dbuf [0:31];
    reg [5:0] dptr;

    // ------------------------------------------------------------------------
    // UART RX (115200 8N1 @ 50MHz, BAUD_DIV = 434)
    // ------------------------------------------------------------------------
    localparam BAUD_DIV = 434;
    reg [1:0] rx_sync = 2'b11;
    always @(posedge sys_clk) rx_sync <= {rx_sync[0], uart_rx};
    wire rx_pin = rx_sync[1];

    reg [8:0] rx_cnt = 9'd0;
    reg [3:0] rx_bit = 4'd0;
    reg [7:0] rx_sh  = 8'd0;
    reg       rx_act = 1'b0;
    reg       rx_vld = 1'b0;
    reg [7:0] rx_dat = 8'd0;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_act <= 1'b0; rx_cnt <= 9'd0; rx_bit <= 4'd0; rx_vld <= 1'b0; rx_dat <= 8'd0;
        end else begin
            rx_vld <= 1'b0;
            if (!rx_act) begin
                if (!rx_pin) begin
                    rx_act <= 1'b1;
                    rx_cnt <= BAUD_DIV / 2; // sample mid-start-bit
                    rx_bit <= 4'd0;
                end
            end else begin
                if (rx_cnt == BAUD_DIV - 1) begin
                    rx_cnt <= 9'd0;
                    if (rx_bit == 4'd0) begin
                        if (!rx_pin) rx_bit <= 4'd1;
                        else         rx_act <= 1'b0; // false start glitch
                    end else if (rx_bit <= 4'd8) begin
                        rx_sh  <= {rx_pin, rx_sh[7:1]};
                        rx_bit <= rx_bit + 1'b1;
                    end else begin
                        rx_act <= 1'b0;
                        if (rx_pin) begin
                            rx_dat <= rx_sh;
                            rx_vld <= 1'b1;
                        end
                    end
                end else begin
                    rx_cnt <= rx_cnt + 1'b1;
                end
            end
        end
    end

    // ------------------------------------------------------------------------
    // Pattern Selection & Screenshot Request Registers
    //   pat_lock == 0 : auto cycle White -> Red -> Green -> Blue
    //   pat_lock == 1 : locked to pat_sel (0=W, 1=R, 2=G, 3=B, 4=8-Color Bars)
    // ------------------------------------------------------------------------
    reg       pat_lock;
    reg [2:0] pat_sel;
    reg       snap_req;       // latched screenshot request from UART RX
    reg       snap_rle;       // 0 = 'q' (200x120 raw), 1 = 'c' (800x480 RLE)
    reg [1:0] snap_wait_frm;  // wait 1 frame after pattern change before capture
    reg       snap_clear_req;
    reg       frame_end_pulse;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            pat_lock      <= 1'b0;
            pat_sel       <= 3'd0;
            snap_req      <= 1'b0;
            snap_rle      <= 1'b0;
            snap_wait_frm <= 2'd0;
        end else begin
            if (snap_clear_req) snap_req <= 1'b0;
            if (rx_vld) begin
                case (rx_dat)
                    "0": begin pat_lock <= 1'b1; pat_sel <= 3'd0; snap_wait_frm <= 2'd1; end
                    "1": begin pat_lock <= 1'b1; pat_sel <= 3'd1; snap_wait_frm <= 2'd1; end
                    "2": begin pat_lock <= 1'b1; pat_sel <= 3'd2; snap_wait_frm <= 2'd1; end
                    "3": begin pat_lock <= 1'b1; pat_sel <= 3'd3; snap_wait_frm <= 2'd1; end
                    "4": begin pat_lock <= 1'b1; pat_sel <= 3'd4; snap_wait_frm <= 2'd1; end
                    "a", "A": begin pat_lock <= 1'b0; end
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
    // Pixel Generator (Solid Colors + 8-Color Bar / Border Test Card)
    // ------------------------------------------------------------------------
    reg  [7:0]  frame_cnt;
    reg  [9:0]  px;
    reg  [8:0]  py;
    wire [2:0]  active_pat = pat_lock ? pat_sel : {1'b0, frame_cnt[5:4]};

    // ------------------------------------------------------------------------
    // "spark" Logo（未锁定图案时的默认画面，逐字母配色）
    //   点阵 183x55，硬件 4 倍放大 -> 732x220，居中于 (34,130)
    // ------------------------------------------------------------------------
    // ========================================================================
    // "spark" 点阵字模（Arial Black 60px 渲染，阈值二值化）
    // 尺寸 183 x 55，每行 6 个 32bit 字，共 330 字
    // 硬件侧按 LOGO_SCALE 倍放大显示
    // ========================================================================
    localparam LOGO_W     = 183;
    localparam LOGO_H     = 55;
    localparam LOGO_WORDS = 6;
    localparam LOGO_SCALE = 4;

    reg [31:0] logo_rom [0:329];

    initial begin
        logo_rom[0] = 32'h00000000; logo_rom[1] = 32'h00000000; logo_rom[2] = 32'h00000000;
        logo_rom[3] = 32'h00000000; logo_rom[4] = 32'h00001FFE; logo_rom[5] = 32'h00000000;
        logo_rom[6] = 32'h00000000; logo_rom[7] = 32'h00000000; logo_rom[8] = 32'h00000000;
        logo_rom[9] = 32'h00000000; logo_rom[10] = 32'h00001FFE; logo_rom[11] = 32'h00000000;
        logo_rom[12] = 32'h00000000; logo_rom[13] = 32'h00000000; logo_rom[14] = 32'h00000000;
        logo_rom[15] = 32'h00000000; logo_rom[16] = 32'h00001FFE; logo_rom[17] = 32'h00000000;
        logo_rom[18] = 32'h00000000; logo_rom[19] = 32'h00000000; logo_rom[20] = 32'h00000000;
        logo_rom[21] = 32'h00000000; logo_rom[22] = 32'h00001FFE; logo_rom[23] = 32'h00000000;
        logo_rom[24] = 32'h00000000; logo_rom[25] = 32'h00000000; logo_rom[26] = 32'h00000000;
        logo_rom[27] = 32'h00000000; logo_rom[28] = 32'h00001FFE; logo_rom[29] = 32'h00000000;
        logo_rom[30] = 32'h00000000; logo_rom[31] = 32'h00000000; logo_rom[32] = 32'h00000000;
        logo_rom[33] = 32'h00000000; logo_rom[34] = 32'h00001FFE; logo_rom[35] = 32'h00000000;
        logo_rom[36] = 32'h00000000; logo_rom[37] = 32'h00000000; logo_rom[38] = 32'h00000000;
        logo_rom[39] = 32'h00000000; logo_rom[40] = 32'h00001FFE; logo_rom[41] = 32'h00000000;
        logo_rom[42] = 32'h00000000; logo_rom[43] = 32'h00000000; logo_rom[44] = 32'h00000000;
        logo_rom[45] = 32'h00000000; logo_rom[46] = 32'h00001FFE; logo_rom[47] = 32'h00000000;
        logo_rom[48] = 32'h00000000; logo_rom[49] = 32'h00000000; logo_rom[50] = 32'h00000000;
        logo_rom[51] = 32'h00000000; logo_rom[52] = 32'h00001FFE; logo_rom[53] = 32'h00000000;
        logo_rom[54] = 32'h00000000; logo_rom[55] = 32'h00000000; logo_rom[56] = 32'h00000000;
        logo_rom[57] = 32'h00000000; logo_rom[58] = 32'h00001FFE; logo_rom[59] = 32'h00000000;
        logo_rom[60] = 32'h00000000; logo_rom[61] = 32'h00000000; logo_rom[62] = 32'h00000000;
        logo_rom[63] = 32'h00000000; logo_rom[64] = 32'h00001FFE; logo_rom[65] = 32'h00000000;
        logo_rom[66] = 32'h001FFF00; logo_rom[67] = 32'h0000007F; logo_rom[68] = 32'h0000003F;
        logo_rom[69] = 32'hFE000000; logo_rom[70] = 32'h00F81FFE; logo_rom[71] = 32'h00000000;
        logo_rom[72] = 32'h00FFFFE0; logo_rom[73] = 32'h00FFE1FF; logo_rom[74] = 32'hE00003FF;
        logo_rom[75] = 32'hFFE000FF; logo_rom[76] = 32'hE3FF1FFE; logo_rom[77] = 32'h01FFFC00;
        logo_rom[78] = 32'h03FFFFF0; logo_rom[79] = 32'h00FFE7FF; logo_rom[80] = 32'hF0000FFF;
        logo_rom[81] = 32'hFFF000FF; logo_rom[82] = 32'hE7FF1FFE; logo_rom[83] = 32'h03FFF800;
        logo_rom[84] = 32'h07FFFFFC; logo_rom[85] = 32'h00FFEFFF; logo_rom[86] = 32'hF8001FFF;
        logo_rom[87] = 32'hFFFC00FF; logo_rom[88] = 32'hEFFE1FFE; logo_rom[89] = 32'h07FFF000;
        logo_rom[90] = 32'h0FFFFFFE; logo_rom[91] = 32'h00FFFFFF; logo_rom[92] = 32'hFC003FFF;
        logo_rom[93] = 32'hFFFC00FF; logo_rom[94] = 32'hEFFE1FFE; logo_rom[95] = 32'h07FFE000;
        logo_rom[96] = 32'h1FFFFFFE; logo_rom[97] = 32'h00FFFFFF; logo_rom[98] = 32'hFE007FFF;
        logo_rom[99] = 32'hFFFE00FF; logo_rom[100] = 32'hFFFE1FFE; logo_rom[101] = 32'h0FFFC000;
        logo_rom[102] = 32'h3FFFFFFF; logo_rom[103] = 32'h00FFFFFF; logo_rom[104] = 32'hFE00FFFF;
        logo_rom[105] = 32'hFFFE00FF; logo_rom[106] = 32'hFFFC1FFE; logo_rom[107] = 32'h1FFF8000;
        logo_rom[108] = 32'h3FFC1FFF; logo_rom[109] = 32'h00FFFFFF; logo_rom[110] = 32'hFF00FFFF;
        logo_rom[111] = 32'hFFFF00FF; logo_rom[112] = 32'hFFFC1FFE; logo_rom[113] = 32'h3FFF0000;
        logo_rom[114] = 32'h3FF807E0; logo_rom[115] = 32'h00FFFE1F; logo_rom[116] = 32'hFF00FFF8;
        logo_rom[117] = 32'h1FFF00FF; logo_rom[118] = 32'hFFF81FFE; logo_rom[119] = 32'h7FFE0000;
        logo_rom[120] = 32'h3FF80000; logo_rom[121] = 32'h00FFFC0F; logo_rom[122] = 32'hFF81FFF0;
        logo_rom[123] = 32'h0FFF00FF; logo_rom[124] = 32'hFE181FFE; logo_rom[125] = 32'hFFFC0000;
        logo_rom[126] = 32'h3FF80000; logo_rom[127] = 32'h00FFF807; logo_rom[128] = 32'hFF81FFE0;
        logo_rom[129] = 32'h07FF00FF; logo_rom[130] = 32'hFC001FFF; logo_rom[131] = 32'hFFF80000;
        logo_rom[132] = 32'h3FFE0000; logo_rom[133] = 32'h00FFF007; logo_rom[134] = 32'hFF8007E0;
        logo_rom[135] = 32'h07FF00FF; logo_rom[136] = 32'hF8001FFF; logo_rom[137] = 32'hFFF00000;
        logo_rom[138] = 32'h3FFFFC00; logo_rom[139] = 32'h00FFF003; logo_rom[140] = 32'hFFC00000;
        logo_rom[141] = 32'h1FFF00FF; logo_rom[142] = 32'hF8001FFF; logo_rom[143] = 32'hFFF00000;
        logo_rom[144] = 32'h1FFFFFC0; logo_rom[145] = 32'h00FFF003; logo_rom[146] = 32'hFFC00000;
        logo_rom[147] = 32'hFFFF00FF; logo_rom[148] = 32'hF0001FFF; logo_rom[149] = 32'hFFF00000;
        logo_rom[150] = 32'h1FFFFFF8; logo_rom[151] = 32'h00FFF003; logo_rom[152] = 32'hFFC0000F;
        logo_rom[153] = 32'hFFFF00FF; logo_rom[154] = 32'hF0001FFF; logo_rom[155] = 32'hFFF80000;
        logo_rom[156] = 32'h0FFFFFFC; logo_rom[157] = 32'h00FFF003; logo_rom[158] = 32'hFFC001FF;
        logo_rom[159] = 32'hFFFF00FF; logo_rom[160] = 32'hF0001FFF; logo_rom[161] = 32'hFFF80000;
        logo_rom[162] = 32'h07FFFFFE; logo_rom[163] = 32'h00FFF003; logo_rom[164] = 32'hFFC00FFF;
        logo_rom[165] = 32'hFFFF00FF; logo_rom[166] = 32'hF0001FFF; logo_rom[167] = 32'hFFFC0000;
        logo_rom[168] = 32'h03FFFFFF; logo_rom[169] = 32'h00FFF003; logo_rom[170] = 32'hFFC03FFF;
        logo_rom[171] = 32'hFFFF00FF; logo_rom[172] = 32'hF0001FFF; logo_rom[173] = 32'hFFFE0000;
        logo_rom[174] = 32'h007FFFFF; logo_rom[175] = 32'h80FFF003; logo_rom[176] = 32'hFFC0FFFF;
        logo_rom[177] = 32'hE7FF00FF; logo_rom[178] = 32'hF0001FFF; logo_rom[179] = 32'hFFFE0000;
        logo_rom[180] = 32'h0007FFFF; logo_rom[181] = 32'h80FFF003; logo_rom[182] = 32'hFFC0FFFE;
        logo_rom[183] = 32'h07FF00FF; logo_rom[184] = 32'hF0001FFF; logo_rom[185] = 32'hFFFF0000;
        logo_rom[186] = 32'h00003FFF; logo_rom[187] = 32'h80FFF003; logo_rom[188] = 32'hFFC1FFF0;
        logo_rom[189] = 32'h07FF00FF; logo_rom[190] = 32'hF0001FFF; logo_rom[191] = 32'hCFFF0000;
        logo_rom[192] = 32'h000003FF; logo_rom[193] = 32'hC0FFF007; logo_rom[194] = 32'hFF81FFC0;
        logo_rom[195] = 32'h0FFF00FF; logo_rom[196] = 32'hF0001FFF; logo_rom[197] = 32'h8FFF8000;
        logo_rom[198] = 32'h000003FF; logo_rom[199] = 32'hC0FFF807; logo_rom[200] = 32'hFF83FFC0;
        logo_rom[201] = 32'h0FFF00FF; logo_rom[202] = 32'hF0001FFF; logo_rom[203] = 32'h07FF8000;
        logo_rom[204] = 32'h03F801FF; logo_rom[205] = 32'h80FFFC0F; logo_rom[206] = 32'hFF83FFC0;
        logo_rom[207] = 32'h1FFF00FF; logo_rom[208] = 32'hF0001FFE; logo_rom[209] = 32'h07FFC000;
        logo_rom[210] = 32'h7FF803FF; logo_rom[211] = 32'h80FFFE1F; logo_rom[212] = 32'hFF83FFF0;
        logo_rom[213] = 32'h7FFF00FF; logo_rom[214] = 32'hF0001FFE; logo_rom[215] = 32'h03FFE000;
        logo_rom[216] = 32'h7FFE07FF; logo_rom[217] = 32'h80FFFFFF; logo_rom[218] = 32'hFF03FFFF;
        logo_rom[219] = 32'hFFFF00FF; logo_rom[220] = 32'hF0001FFE; logo_rom[221] = 32'h03FFE000;
        logo_rom[222] = 32'h7FFFFFFF; logo_rom[223] = 32'h00FFFFFF; logo_rom[224] = 32'hFF03FFFF;
        logo_rom[225] = 32'hFFFF80FF; logo_rom[226] = 32'hF0001FFE; logo_rom[227] = 32'h01FFF000;
        logo_rom[228] = 32'h3FFFFFFF; logo_rom[229] = 32'h00FFFFFF; logo_rom[230] = 32'hFE01FFFF;
        logo_rom[231] = 32'hFFFF80FF; logo_rom[232] = 32'hF0001FFE; logo_rom[233] = 32'h01FFF000;
        logo_rom[234] = 32'h1FFFFFFE; logo_rom[235] = 32'h00FFFFFF; logo_rom[236] = 32'hFC01FFFF;
        logo_rom[237] = 32'hFBFF80FF; logo_rom[238] = 32'hF0001FFE; logo_rom[239] = 32'h00FFF800;
        logo_rom[240] = 32'h0FFFFFFC; logo_rom[241] = 32'h00FFFFFF; logo_rom[242] = 32'hFC00FFFF;
        logo_rom[243] = 32'hF3FF80FF; logo_rom[244] = 32'hF0001FFE; logo_rom[245] = 32'h00FFFC00;
        logo_rom[246] = 32'h07FFFFF8; logo_rom[247] = 32'h00FFF7FF; logo_rom[248] = 32'hF0007FFF;
        logo_rom[249] = 32'hC3FF80FF; logo_rom[250] = 32'hF0001FFE; logo_rom[251] = 32'h007FFC00;
        logo_rom[252] = 32'h01FFFFE0; logo_rom[253] = 32'h00FFF3FF; logo_rom[254] = 32'hE0001FFF;
        logo_rom[255] = 32'h81FFC0FF; logo_rom[256] = 32'hF0001FFE; logo_rom[257] = 32'h007FFE00;
        logo_rom[258] = 32'h001FFE00; logo_rom[259] = 32'h00FFF07F; logo_rom[260] = 32'h000007FC;
        logo_rom[261] = 32'h00000000; logo_rom[262] = 32'h00000000; logo_rom[263] = 32'h00000000;
        logo_rom[264] = 32'h00000000; logo_rom[265] = 32'h00FFF000; logo_rom[266] = 32'h00000000;
        logo_rom[267] = 32'h00000000; logo_rom[268] = 32'h00000000; logo_rom[269] = 32'h00000000;
        logo_rom[270] = 32'h00000000; logo_rom[271] = 32'h00FFF000; logo_rom[272] = 32'h00000000;
        logo_rom[273] = 32'h00000000; logo_rom[274] = 32'h00000000; logo_rom[275] = 32'h00000000;
        logo_rom[276] = 32'h00000000; logo_rom[277] = 32'h00FFF000; logo_rom[278] = 32'h00000000;
        logo_rom[279] = 32'h00000000; logo_rom[280] = 32'h00000000; logo_rom[281] = 32'h00000000;
        logo_rom[282] = 32'h00000000; logo_rom[283] = 32'h00FFF000; logo_rom[284] = 32'h00000000;
        logo_rom[285] = 32'h00000000; logo_rom[286] = 32'h00000000; logo_rom[287] = 32'h00000000;
        logo_rom[288] = 32'h00000000; logo_rom[289] = 32'h00FFF000; logo_rom[290] = 32'h00000000;
        logo_rom[291] = 32'h00000000; logo_rom[292] = 32'h00000000; logo_rom[293] = 32'h00000000;
        logo_rom[294] = 32'h00000000; logo_rom[295] = 32'h00FFF000; logo_rom[296] = 32'h00000000;
        logo_rom[297] = 32'h00000000; logo_rom[298] = 32'h00000000; logo_rom[299] = 32'h00000000;
        logo_rom[300] = 32'h00000000; logo_rom[301] = 32'h00FFF000; logo_rom[302] = 32'h00000000;
        logo_rom[303] = 32'h00000000; logo_rom[304] = 32'h00000000; logo_rom[305] = 32'h00000000;
        logo_rom[306] = 32'h00000000; logo_rom[307] = 32'h00FFF000; logo_rom[308] = 32'h00000000;
        logo_rom[309] = 32'h00000000; logo_rom[310] = 32'h00000000; logo_rom[311] = 32'h00000000;
        logo_rom[312] = 32'h00000000; logo_rom[313] = 32'h00FFF000; logo_rom[314] = 32'h00000000;
        logo_rom[315] = 32'h00000000; logo_rom[316] = 32'h00000000; logo_rom[317] = 32'h00000000;
        logo_rom[318] = 32'h00000000; logo_rom[319] = 32'h00FFF000; logo_rom[320] = 32'h00000000;
        logo_rom[321] = 32'h00000000; logo_rom[322] = 32'h00000000; logo_rom[323] = 32'h00000000;
        logo_rom[324] = 32'h00000000; logo_rom[325] = 32'h00FFF000; logo_rom[326] = 32'h00000000;
        logo_rom[327] = 32'h00000000; logo_rom[328] = 32'h00000000; logo_rom[329] = 32'h00000000;
    end

    localparam LOGO_DX = 732;
    localparam LOGO_DY = 220;

    wire [10:0] ldx = px - 11'd34;                 // 越界回绕成大数，无符号比较自动排除
    wire [10:0] ldy = py - 11'd130;
    wire        in_logo = (ldx < LOGO_DX) && (ldy < LOGO_DY);

    wire [7:0]  lsx  = ldx[9:2];                   // /4
    wire [7:0]  lsy  = ldy[9:2];
    wire [10:0] lridx = lsy * 6 + {8'd0, lsx[7:5]};
    wire [31:0] lword = logo_rom[lridx];
    wire        lon   = lword[5'd31 - lsx[4:0]];

    // 逐字母配色（字母边界由点阵列墨迹自动测出：s 1..33 / p 40..73 / a 78..113 / r 120..143 / k 147..182）
    reg [15:0] logo_color;
    always @(*) begin
        if      (lsx < 8'd37)  logo_color = 16'h07FF;  // s  青
        else if (lsx < 8'd76)  logo_color = 16'h07E0;  // p  绿
        else if (lsx < 8'd116) logo_color = 16'hFFE0;  // a  黄
        else if (lsx < 8'd145) logo_color = 16'hFD20;  // r  橙
        else                   logo_color = 16'hF81F;  // k  品红
    end

    // 背景：上下对称的深蓝渐变
    reg [15:0] spark_bg;
    always @(*) begin
        case (py[8:6])
            3'd0:    spark_bg = 16'h0000;
            3'd1:    spark_bg = 16'h0841;
            3'd2:    spark_bg = 16'h0861;
            3'd3:    spark_bg = 16'h10A2;
            3'd4:    spark_bg = 16'h10A2;
            3'd5:    spark_bg = 16'h0861;
            3'd6:    spark_bg = 16'h0841;
            default: spark_bg = 16'h0000;
        endcase
    end

    wire [15:0] spark_color = (in_logo && lon) ? logo_color : spark_bg;

    // 8-color vertical bars (each 100 pixels wide across 800px) with 4px white border
    wire is_border = (px < 10'd4) || (px >= 10'd796) || (py < 9'd4) || (py >= 9'd476);
    reg  [15:0] bar_color;
    always @(*) begin
        if (is_border)           bar_color = 16'hFFFF; // White border
        else if (px < 10'd100)   bar_color = 16'hFFFF; // White
        else if (px < 10'd200)   bar_color = 16'hFFE0; // Yellow
        else if (px < 10'd300)   bar_color = 16'h07FF; // Cyan
        else if (px < 10'd400)   bar_color = 16'h07E0; // Green
        else if (px < 10'd500)   bar_color = 16'hF81F; // Magenta
        else if (px < 10'd600)   bar_color = 16'hF800; // Red
        else if (px < 10'd700)   bar_color = 16'h001F; // Blue
        else                     bar_color = 16'h0000; // Black
    end

    reg  [15:0] color;
    always @(*) begin
        if (!pat_lock) color = spark_color;          // 默认：spark Logo
        else case (pat_sel)
            3'd0:    color = 16'hFFFF; // White
            3'd1:    color = 16'hF800; // Red
            3'd2:    color = 16'h07E0; // Green
            3'd3:    color = 16'h001F; // Blue
            default: color = bar_color;// 8-Color Bars + White Border
        endcase
    end

    // ------------------------------------------------------------------------
    // UART TX (115200 8N1 @ 50MHz) - Shared between Diag Printer & Screenshot
    // ------------------------------------------------------------------------
    reg  [8:0]  u_div;
    reg  [3:0]  u_bit;
    reg  [9:0]  u_sh;
    reg         u_busy;
    reg         u_txr = 1'b1;
    assign uart_tx = u_txr;

    // Two sources can drive UART TX:
    //   1) Diag line printer (diag_u_start, diag_u_byte) when !snap_active
    //   2) Screenshot engine (snap_u_start, snap_u_byte) when snap_active
    reg         snap_active;
    reg         diag_u_start;
    reg  [7:0]  diag_u_byte;
    reg         snap_u_start;
    reg  [7:0]  snap_u_byte;

    wire        u_start = snap_active ? snap_u_start : diag_u_start;
    wire [7:0]  u_byte  = snap_active ? snap_u_byte  : diag_u_byte;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            u_busy <= 1'b0; u_txr <= 1'b1; u_div <= 0; u_bit <= 0; u_sh <= 10'h3FF;
        end else if (!u_busy) begin
            u_txr <= 1'b1;
            if (u_start) begin
                u_sh   <= {1'b1, u_byte, 1'b0};
                u_busy <= 1'b1; u_div <= 0; u_bit <= 0;
            end
        end else begin
            u_txr <= u_sh[0];
            if (u_div == BAUD_DIV-1) begin
                u_div <= 0;
                u_sh  <= {1'b1, u_sh[9:1]};
                if (u_bit == 4'd9) u_busy <= 1'b0;
                else               u_bit  <= u_bit + 1'b1;
            end else u_div <= u_div + 1'b1;
        end
    end

    function [7:0] hexc;
        input [3:0] n;
        hexc = (n < 4'd10) ? (8'h30 + n) : (8'h37 + n);
    endfunction

    reg [7:0] sbuf [0:31];
    reg [7:0] sframe;
    function [7:0] label_of;
        input [5:0] bi;
        case (bi)
            6'd0 : label_of = "S";
            6'd5 : label_of = "P";
            6'd6 : label_of = "L";
            6'd7 : label_of = "I";
            6'd8 : label_of = "A";
            6'd9 : label_of = "M";
            6'd16: label_of = "C";
            6'd19: label_of = "W";
            6'd26: label_of = "R";
            default: label_of = 8'h00;
        endcase
    endfunction

    // Sequential UART diagnostic line printer
    localparam U_IDLE=0, U_F=1, U_FH=2, U_FL=3, U_BYTE_LBL=4, U_LBL_SP=5, U_LBL_C=6, U_LBL_COL=7,
               U_BH=8, U_BL=9, U_N_SP=10, U_N_N=11, U_N_COL=12, U_N_V=13, U_CR=14, U_LF=15, U_WAIT=16;
    reg [4:0] us, us_ret;
    reg [5:0] ubi;
    reg       print_req;
    wire      print_busy = (us != U_IDLE);

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            us <= U_IDLE; us_ret <= U_IDLE; diag_u_start <= 1'b0; ubi <= 0; diag_u_byte <= 8'h00;
        end else begin
            diag_u_start <= 1'b0;
            case (us)
            U_IDLE    : if (print_req) begin ubi <= 0; us <= U_F; end
            U_WAIT    : if (!u_busy && !diag_u_start) us <= us_ret;
            U_F       : begin diag_u_byte <= "F";                  diag_u_start <= 1'b1; us_ret <= U_FH;       us <= U_WAIT; end
            U_FH      : begin diag_u_byte <= hexc(sframe[7:4]);    diag_u_start <= 1'b1; us_ret <= U_FL;       us <= U_WAIT; end
            U_FL      : begin diag_u_byte <= hexc(sframe[3:0]);    diag_u_start <= 1'b1; us_ret <= U_BYTE_LBL; us <= U_WAIT; end
            U_BYTE_LBL: us <= (label_of(ubi) != 8'h00) ? U_LBL_SP : U_BH;
            U_LBL_SP  : begin diag_u_byte <= " ";                  diag_u_start <= 1'b1; us_ret <= U_LBL_C;    us <= U_WAIT; end
            U_LBL_C   : begin diag_u_byte <= label_of(ubi);        diag_u_start <= 1'b1; us_ret <= U_LBL_COL;  us <= U_WAIT; end
            U_LBL_COL : begin diag_u_byte <= ":";                  diag_u_start <= 1'b1; us_ret <= U_BH;       us <= U_WAIT; end
            U_BH      : begin diag_u_byte <= hexc(sbuf[ubi][7:4]); diag_u_start <= 1'b1; us_ret <= U_BL;       us <= U_WAIT; end
            U_BL      : begin
                diag_u_byte <= hexc(sbuf[ubi][3:0]); diag_u_start <= 1'b1; us <= U_WAIT;
                if (ubi == 6'd31) us_ret <= U_N_SP;
                else begin ubi <= ubi + 1'b1; us_ret <= U_BYTE_LBL; end
            end
            U_N_SP    : begin diag_u_byte <= " ";                  diag_u_start <= 1'b1; us_ret <= U_N_N;      us <= U_WAIT; end
            U_N_N     : begin diag_u_byte <= "N";                  diag_u_start <= 1'b1; us_ret <= U_N_COL;    us <= U_WAIT; end
            U_N_COL   : begin diag_u_byte <= ":";                  diag_u_start <= 1'b1; us_ret <= U_N_V;      us <= U_WAIT; end
            U_N_V     : begin diag_u_byte <= hexc({1'b0, active_pat}); diag_u_start <= 1'b1; us_ret <= U_CR;  us <= U_WAIT; end
            U_CR      : begin diag_u_byte <= 8'h0D;                diag_u_start <= 1'b1; us_ret <= U_LF;       us <= U_WAIT; end
            U_LF      : begin diag_u_byte <= 8'h0A;                diag_u_start <= 1'b1; us_ret <= U_IDLE;     us <= U_WAIT; end
            default   : us <= U_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------------
    // Delay counter
    // ------------------------------------------------------------------------
    reg [23:0] dly;

    // ------------------------------------------------------------------------
    // Bus engine + Master FSM + Hardware Screenshot Engine (0x2E SRAM Readback)
    // ------------------------------------------------------------------------
    localparam M_RST_LO     = 4'd0,
               M_RST_HI     = 4'd1,
               M_SEQ        = 4'd2,
               M_WR         = 4'd3,
               M_RD         = 4'd4,
               M_DLY        = 4'd5,
               M_PIX        = 4'd6,
               M_PRINT      = 4'd7,
               M_PRINT_WAIT = 4'd8,
               M_SNAP_HDR   = 4'd9,
               M_SNAP_RD    = 4'd10,
               M_SNAP_PROC  = 4'd11,
               M_SNAP_TX    = 4'd12,
               M_SNAP_FLUSH = 4'd13,
               M_SNAP_FTR   = 4'd14;

    reg [3:0]  ms;
    reg [3:0]  tx_ret_ms;
    reg [1:0]  seg;           // 0 = init, 1 = frame header, 2 = diag, 3 = snap prep
    reg [5:0]  ph;            // phase counter within bus cycle
    reg        init_done;

    // Screenshot engine registers
    reg [3:0]  tx_idx;
    reg [3:0]  tx_len;
    reg [7:0]  tx_buf [0:7];
    reg [15:0] cur_pix;
    reg [15:0] rle_pix;
    reg [7:0]  rle_cnt;
    reg        last_pix_flag;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            ms <= M_RST_LO; tx_ret_ms <= M_RST_LO; seg <= 0; pc <= SEG_INIT; ph <= 0; dly <= 24'd1000000;
            lcd_cs <= 1'b1; lcd_rs <= 1'b1; lcd_wr <= 1'b1; lcd_rd <= 1'b1; lcd_rst <= 1'b0;
            db_out <= 16'h0000; db_oe <= 1'b1;
            px <= 0; py <= 0; frame_cnt <= 0; init_done <= 1'b0; dptr <= 0;
            print_req <= 1'b0; sframe <= 0;
            snap_active <= 1'b0; snap_u_start <= 1'b0; snap_u_byte <= 8'h00;
            snap_clear_req <= 1'b0; frame_end_pulse <= 1'b0;
            tx_idx <= 0; tx_len <= 0; cur_pix <= 0; rle_pix <= 0; rle_cnt <= 0; last_pix_flag <= 1'b0;
        end else begin
            print_req       <= 1'b0;
            snap_u_start    <= 1'b0;
            snap_clear_req  <= 1'b0;
            frame_end_pulse <= 1'b0;

            case (ms)
            M_RST_LO: begin
                lcd_rst <= 1'b0;
                if (dly == 0) begin lcd_rst <= 1'b1; dly <= 24'd2000000; ms <= M_RST_HI; end
                else dly <= dly - 1'b1;
            end
            M_RST_HI: begin
                if (dly == 0) begin pc <= SEG_INIT; seg <= 0; ms <= M_SEQ; end
                else dly <= dly - 1'b1;
            end

            // ---------------- Sequencer ---------------------------------
            M_SEQ: begin
                ph <= 0;
                case (op_kind)
                K_WR : begin db_out <= op_data[15:0]; lcd_rs <= op_rs; ms <= M_WR; end
                K_RD : begin lcd_rs <= 1'b1; ms <= M_RD; end
                K_DLY: begin dly <= op_data; ms <= M_DLY; end
                K_END: begin
                    if (seg == 2'd0) begin
                        init_done <= 1'b1;
                        seg <= 2'd1; pc <= SEG_FRAME;
                    end else if (seg == 2'd1) begin
                        px <= 0; py <= 0; ms <= M_PIX;
                        db_out <= color; lcd_rs <= 1'b1;
                    end else if (seg == 2'd2) begin
                        ms <= M_PRINT;
                    end else begin
                        // seg == 2'd3: SEG_SNAP_PREP (0x2A, 0x2B, 0x2E) finished!
                        px <= 0; py <= 0; rle_cnt <= 8'd0; last_pix_flag <= 1'b0;
                        ms <= M_SNAP_HDR;
                    end
                end
                endcase
            end

            M_DLY: begin
                lcd_cs <= 1'b1;
                if (dly == 0) begin pc <= pc + 1'b1; ms <= M_SEQ; end
                else dly <= dly - 1'b1;
            end

            // ---------------- Write cycle (cmd/param or pixel) ----------
            M_WR, M_PIX: begin
                db_oe <= 1'b1;
                ph <= ph + 1'b1;
                case (ph)
                    6'd0 : begin
                        lcd_cs <= 1'b0; lcd_wr <= 1'b1; lcd_rd <= 1'b1;
                        if (ms == M_PIX) db_out <= color;
                    end
                    6'd4 : lcd_wr <= 1'b0;
                    6'd10: lcd_wr <= 1'b1;
                    6'd14: begin
                        if (ms == M_WR) lcd_cs <= 1'b1;
                    end
                    6'd15: begin
                        ph <= 0;
                        if (ms == M_WR) begin
                            pc <= pc + 1'b1; ms <= M_SEQ;
                        end else begin
                            // next pixel
                            if (px == 10'd799) begin
                                px <= 0;
                                if (py == 9'd479) begin
                                    lcd_cs          <= 1'b1;
                                    py              <= 0;
                                    frame_end_pulse <= 1'b1;
                                    // Check if a screenshot is requested (and any pattern change has settled)
                                    if (snap_req && snap_wait_frm == 2'd0) begin
                                        snap_clear_req <= 1'b1;
                                        snap_active    <= 1'b1;
                                        seg            <= 2'd3;
                                        pc             <= SEG_SNAP_PREP;
                                        ms             <= M_SEQ;
                                    end else begin
                                        seg  <= 2'd2;
                                        pc   <= SEG_DIAG;
                                        dptr <= 0;
                                        ms   <= M_SEQ;
                                    end
                                end else py <= py + 1'b1;
                            end else px <= px + 1'b1;
                        end
                    end
                    default: ;
                endcase
            end

            // ---------------- Read cycle (for SEG_DIAG) -----------------
            M_RD: begin
                ph <= ph + 1'b1;
                case (ph)
                    6'd0 : begin db_oe <= 1'b0; lcd_cs <= 1'b0; lcd_wr <= 1'b1; lcd_rd <= 1'b1; end
                    6'd6 : lcd_rd <= 1'b0;
                    6'd28: begin
                        if (op_w16) begin
                            dbuf[dptr]       <= db_in_s2[15:8];
                            dbuf[dptr+1'b1]  <= db_in_s2[7:0];
                            dptr <= dptr + 2'd2;
                        end else begin
                            dbuf[dptr] <= db_in_s2[7:0];
                            dptr <= dptr + 1'b1;
                        end
                        lcd_rd <= 1'b1;
                    end
                    6'd38: begin
                        ph <= 0; pc <= pc + 1'b1; ms <= M_SEQ;
                        db_oe <= 1'b1;
                    end
                    default: ;
                endcase
            end

            // ---------------- Print diag line ---------------------------
            M_PRINT: begin
                lcd_cs <= 1'b1;
                if (!print_busy && us == U_IDLE) begin
                    sframe    <= frame_cnt;
                    print_req <= 1'b1;
                    ms        <= M_PRINT_WAIT;
                end
            end
            M_PRINT_WAIT: begin
                frame_cnt <= frame_cnt + 1'b1;
                seg <= 2'd1; pc <= SEG_FRAME; ms <= M_SEQ;
            end

            // ================================================================
            // HARDWARE SCREENSHOT ENGINE (Reads 800x480 from SSD1963 via 0x2E)
            // ================================================================
            M_SNAP_HDR: begin
                // Wait for any in-flight diag UART transmission to finish
                if (!print_busy && us == U_IDLE && !u_busy) begin
                    tx_buf[0] <= "I";
                    tx_buf[1] <= "M";
                    tx_buf[2] <= "G";
                    tx_buf[3] <= snap_rle ? "C" : "Q";
                    tx_buf[4] <= snap_rle ? 8'h20 : 8'hC8; // width low  (800=0x0320, 200=0x00C8)
                    tx_buf[5] <= snap_rle ? 8'h03 : 8'h00; // width high
                    tx_buf[6] <= snap_rle ? 8'hE0 : 8'h78; // height low (480=0x01E0, 120=0x0078)
                    tx_buf[7] <= snap_rle ? 8'h01 : 8'h00; // height high
                    tx_idx    <= 4'd0;
                    tx_len    <= 4'd8;
                    tx_ret_ms <= M_SNAP_RD;
                    ph        <= 6'd0;
                    ms        <= M_SNAP_TX;
                end
            end

            // Read 1 pixel (16-bit RGB565) from SSD1963 SRAM (0x2E stream)
            M_SNAP_RD: begin
                ph <= ph + 1'b1;
                case (ph)
                    6'd0 : begin
                        db_oe  <= 1'b0; // FPGA High-Z
                        lcd_cs <= 1'b0;
                        lcd_rs <= 1'b1; // DATA
                        lcd_wr <= 1'b1;
                        lcd_rd <= 1'b1;
                    end
                    6'd4 : lcd_rd <= 1'b0; // Assert RD# low (360ns)
                    6'd22: begin
                        cur_pix <= db_in_s2;
                        lcd_rd  <= 1'b1;
                    end
                    6'd28: begin
                        ph <= 6'd0;
                        ms <= M_SNAP_PROC;
                    end
                    default: ;
                endcase
            end

            // Process the pixel just read from SSD1963 SRAM
            M_SNAP_PROC: begin
                last_pix_flag <= (px == 10'd799 && py == 9'd479);

                // Advance (px, py) for next pixel
                if (px == 10'd799) begin
                    px <= 10'd0;
                    if (py == 9'd479) py <= 9'd0;
                    else              py <= py + 1'b1;
                end else begin
                    px <= px + 1'b1;
                end

                if (!snap_rle) begin
                    // 'q' mode: 200x120 raw RGB565 (every 4th x and 4th y)
                    if (px[1:0] == 2'd0 && py[1:0] == 2'd0) begin
                        tx_buf[0] <= cur_pix[15:8];
                        tx_buf[1] <= cur_pix[7:0];
                        tx_idx    <= 4'd0;
                        tx_len    <= 4'd2;
                        tx_ret_ms <= (px == 10'd799 && py == 9'd479) ? M_SNAP_FTR : M_SNAP_RD;
                        ms        <= M_SNAP_TX;
                    end else begin
                        ms <= (px == 10'd799 && py == 9'd479) ? M_SNAP_FTR : M_SNAP_RD;
                    end
                end else begin
                    // 'c' mode: 800x480 lossless RLE [count, hi, lo]
                    if (rle_cnt == 8'd0) begin
                        rle_pix <= cur_pix;
                        rle_cnt <= 8'd1;
                        ms      <= (px == 10'd799 && py == 9'd479) ? M_SNAP_FLUSH : M_SNAP_RD;
                    end else if (cur_pix == rle_pix && rle_cnt < 8'd255) begin
                        rle_cnt <= rle_cnt + 1'b1;
                        ms      <= (px == 10'd799 && py == 9'd479) ? M_SNAP_FLUSH : M_SNAP_RD;
                    end else begin
                        // Flush previous run, start new run with cur_pix
                        tx_buf[0] <= rle_cnt;
                        tx_buf[1] <= rle_pix[15:8];
                        tx_buf[2] <= rle_pix[7:0];
                        tx_idx    <= 4'd0;
                        tx_len    <= 4'd3;
                        rle_pix   <= cur_pix;
                        rle_cnt   <= 8'd1;
                        tx_ret_ms <= (px == 10'd799 && py == 9'd479) ? M_SNAP_FLUSH : M_SNAP_RD;
                        ms        <= M_SNAP_TX;
                    end
                end
            end

            // Flush final RLE run at end of 800x480 frame
            M_SNAP_FLUSH: begin
                tx_buf[0] <= rle_cnt;
                tx_buf[1] <= rle_pix[15:8];
                tx_buf[2] <= rle_pix[7:0];
                tx_idx    <= 4'd0;
                tx_len    <= 4'd3;
                tx_ret_ms <= M_SNAP_FTR;
                ms        <= M_SNAP_TX;
            end

            // Send 6-byte Footer "END!\r\n" and terminate 0x2E read mode
            M_SNAP_FTR: begin
                lcd_cs    <= 1'b1;
                db_oe     <= 1'b1;
                tx_buf[0] <= "E";
                tx_buf[1] <= "N";
                tx_buf[2] <= "D";
                tx_buf[3] <= "!";
                tx_buf[4] <= 8'h0D;
                tx_buf[5] <= 8'h0A;
                tx_idx    <= 4'd0;
                tx_len    <= 4'd6;
                tx_ret_ms <= M_PRINT_WAIT;
                ms        <= M_SNAP_TX;
            end

            // Multi-byte UART transmitter helper for Screenshot Engine
            M_SNAP_TX: begin
                if (!u_busy && !snap_u_start) begin
                    if (tx_idx < tx_len) begin
                        snap_u_byte  <= tx_buf[tx_idx];
                        snap_u_start <= 1'b1;
                        tx_idx       <= tx_idx + 1'b1;
                    end else begin
                        if (tx_ret_ms == M_PRINT_WAIT) snap_active <= 1'b0;
                        ms <= tx_ret_ms;
                    end
                end
            end

            default: ms <= M_RST_LO;
            endcase
        end
    end

    // snapshot buffer copy when print request issued
    integer k;
    always @(posedge sys_clk) begin
        if (print_req) for (k = 0; k < 32; k = k + 1) sbuf[k] <= dbuf[k];
    end

    // ------------------------------------------------------------------------
    // WS2812 Status LED:
    //   - Dim Red      : Initializing
    //   - Cyan/Purple  : Screenshot capture & UART transfer active
    //   - Green Breath : Normal frame refresh active
    // ------------------------------------------------------------------------
    reg [23:0] ws_color; // GRB
    always @(*) begin
        if (!init_done)        ws_color = 24'h10_00_00;  // 暗红：初始化中
        else if (snap_active)  ws_color = 24'h20_20_40;  // 蓝紫：正在截图回传电脑
        else if (frame_cnt[3]) ws_color = 24'h00_30_00;  // 亮绿
        else                   ws_color = 24'h00_10_00;  // 暗绿
    end

    ws2812_drv u_ws2812 (
        .clk   (sys_clk),
        .rst_n (rst_n),
        .color (ws_color),
        .dout  (ws_dout)
    );

endmodule
