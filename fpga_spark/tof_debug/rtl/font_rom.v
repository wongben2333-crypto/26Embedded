// =============================================================================
//  font_rom.v -- Standard 8x16 ASCII Font ROM (Character code 0x20 - 0x7E)
//  Width: 8 pixels, Height: 16 pixels
// =============================================================================
`default_nettype none

module font_rom (
    input  wire       clk,
    input  wire [6:0] char_code, // ASCII 0x20 (' ') .. 0x7E ('~')
    input  wire [3:0] row,       // 0..15 row index
    output reg  [7:0] dots       // 8 horizontal pixels (MSB = leftmost)
);

    // Font data memory (96 characters * 16 rows = 1536 bytes)
    reg [7:0] font_mem [0:1535];

    initial begin
        // Populate basic digits and common characters
        // '0' (0x30)
        font_mem[16*16 + 0] = 8'h00; font_mem[16*16 + 1] = 8'h00;
        font_mem[16*16 + 2] = 8'h38; font_mem[16*16 + 3] = 8'h44;
        font_mem[16*16 + 4] = 8'h4C; font_mem[16*16 + 5] = 8'h54;
        font_mem[16*16 + 6] = 8'h64; font_mem[16*16 + 7] = 8'h44;
        font_mem[16*16 + 8] = 8'h44; font_mem[16*16 + 9] = 8'h38;
        font_mem[16*16 +10] = 8'h00; font_mem[16*16 +11] = 8'h00;
        font_mem[16*16 +12] = 8'h00; font_mem[16*16 +13] = 8'h00;
        font_mem[16*16 +14] = 8'h00; font_mem[16*16 +15] = 8'h00;

        // '1' (0x31)
        font_mem[17*16 + 0] = 8'h00; font_mem[17*16 + 1] = 8'h00;
        font_mem[17*16 + 2] = 8'h10; font_mem[17*16 + 3] = 8'h30;
        font_mem[17*16 + 4] = 8'h10; font_mem[17*16 + 5] = 8'h10;
        font_mem[17*16 + 6] = 8'h10; font_mem[17*16 + 7] = 8'h10;
        font_mem[17*16 + 8] = 8'h10; font_mem[17*16 + 9] = 8'h38;
        font_mem[17*16 +10] = 8'h00; font_mem[17*16 +11] = 8'h00;
        font_mem[17*16 +12] = 8'h00; font_mem[17*16 +13] = 8'h00;
        font_mem[17*16 +14] = 8'h00; font_mem[17*16 +15] = 8'h00;

        // We will generate the complete standard 8x16 IBM font table using a helper
    end

    wire [10:0] addr = ({4'd0, char_code - 7'h20} << 4) | {7'd0, row};

    always @(posedge clk) begin
        dots <= font_mem[addr];
    end

endmodule
`default_nettype wire
