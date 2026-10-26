# -*- coding: utf-8 -*-
with open(r'C:\Users\gjl50\Desktop\FPGA\fpga_spark\lcd_test\rtl\lcd_test_top.v.bak_before_min', 'r', encoding='utf-8') as f:
    text = f.read()

# 1. Set SEG_FRAME = 8'd68
text = text.replace("localparam [7:0] SEG_FRAME     = 8'd70;", "localparam [7:0] SEG_FRAME     = 8'd68;")

# 2. Restore 68..98 FRAME header (which repeatedly refreshed F0/29/BE/B8/BA/36)
old_block = """        // ---------------- FRAME header (keep PWM/GPIO active + 0x2A/2B/2C)
        8'd70: rom_q = `C(8'hBE);       // PWM config (guarantee backlight stays ON)
        8'd71: rom_q = `D(8'h05);       // PWMF = 5
        8'd72: rom_q = `D(8'hFE);       // Duty = 254 (100% full brightness)
        8'd73: rom_q = `D(8'h01);       // PWM Enable
        8'd74: rom_q = `D(8'h00);
        8'd75: rom_q = `D(8'h00);
        8'd76: rom_q = `D(8'h00);
        8'd77: rom_q = `C(8'hB8);       // GPIO conf
        8'd78: rom_q = `D(8'h03);
        8'd79: rom_q = `D(8'h01);
        8'd80: rom_q = `C(8'hBA);       // GPIO val
        8'd81: rom_q = `D(8'h01);
        8'd82: rom_q = `C(8'h36);       // Address mode
        8'd83: rom_q = `D(8'h00);
        8'd84: rom_q = `C(8'h2A);
        8'd85: rom_q = `D(8'h00);
        8'd86: rom_q = `D(8'h00);
        8'd87: rom_q = `D(8'h03);
        8'd88: rom_q = `D(8'h1F);       // col 0..799
        8'd89: rom_q = `C(8'h2B);
        8'd90: rom_q = `D(8'h00);
        8'd91: rom_q = `D(8'h00);
        8'd92: rom_q = `D(8'h01);
        8'd93: rom_q = `D(8'hDF);       // page 0..479
        8'd94: rom_q = `C(8'h2C);       // write_memory_start
        8'd95: rom_q = `ENDS;"""

flashing_block = """        // ---------------- FRAME header (refresh F0/29/BE/B8/BA/36 + 2A/2B/2C)
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

if old_block in text:
    text = text.replace(old_block, flashing_block)
    print("Replaced LF old_block")
elif old_block.replace("\n", "\r\n") in text:
    text = text.replace(old_block.replace("\n", "\r\n"), flashing_block.replace("\n", "\r\n"))
    print("Replaced CRLF old_block")
else:
    raise RuntimeError("old_block not found!")

# 3. Delays back to 50ms / 100ms
text = text.replace("dly <= 28'd5000000;", "dly <= 24'd2500000;")
text = text.replace("dly <= 28'd25000000;", "dly <= 24'd5000000;")
text = text.replace("reg [27:0] dly;", "reg [23:0] dly;")

with open(r'C:\Users\gjl50\Desktop\FPGA\fpga_spark\lcd_test\rtl\lcd_test_top.v', 'w', encoding='utf-8') as f:
    f.write(text)

print("Restored rtl/lcd_test_top.v to exact flashing state!")
