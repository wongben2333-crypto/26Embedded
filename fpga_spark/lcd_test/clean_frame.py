# -*- coding: utf-8 -*-
path = 'C:/Users/gjl50/Desktop/FPGA/fpga_spark/lcd_test/rtl/lcd_test_top.v'
with open(path, 'r', encoding='utf-8') as f:
    text = f.read()

# 1. Change SEG_FRAME back to 80
text = text.replace("localparam [7:0] SEG_FRAME     = 8'd68;", "localparam [7:0] SEG_FRAME     = 8'd80;")

# 2. Replace lines 68-98 with clean 80-91
old_frame = """        // ---------------- FRAME header (refresh F0/29/BE/B8/BA/36 + 2A/2B/2C)
        8'd68: rom_q = `C(8'hF0);
        8'd69: rom_q = `D(8'h03);       // 16-bit 565
        8'd70: rom_q = `C(8'h29);       // display on
        8'd71: rom_q = `C(8'hD0);
        8'd72: rom_q = `D(8'h00);       // DBC off
        8'd73: rom_q = `C(8'hBE);       // PWM config
        8'd74: rom_q = `D(8'h05);
        8'd75: rom_q = `D(8'hFE);
        8'd76: rom_q = `D(8'h01);
        8'd77: rom_q = `D(8'h00);       // DBC manual brightness = 0
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
        8'd98: rom_q = `ENDS;"""

new_frame = """        // ---------------- FRAME header (0x2A, 0x2B, 0x2C) ---------------
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
        8'd91: rom_q = `ENDS;"""

if old_frame in text:
    text = text.replace(old_frame, new_frame)
elif old_frame.replace("\n", "\r\n") in text:
    text = text.replace(old_frame.replace("\n", "\r\n"), new_frame.replace("\n", "\r\n"))
else:
    raise RuntimeError("old_frame block not found!")

with open(path, 'w', encoding='utf-8') as f:
    f.write(text)

print('Cleaned SEG_FRAME successfully!')
