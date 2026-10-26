# -*- coding: utf-8 -*-
path = 'C:/Users/gjl50/Desktop/FPGA/fpga_spark/lcd_test/rtl/lcd_test_top.v'
with open(path, 'r', encoding='utf-8') as f:
    text = f.read()

# 1. Expand dly to 28-bit
text = text.replace("reg [23:0] dly;", "reg [27:0] dly;")

# 2. Reset delays (100ms RST low, 500ms RST high)
text = text.replace("dly <= 24'd2500000;", "dly <= 28'd5000000;")
text = text.replace("dly <= 24'd5000000;", "dly <= 28'd25000000;")

# 3. PWM parameters: PWMF=0x01, duty=0x80 (50% brightness)
text = text.replace("8'd48: rom_q = `D(8'h05);", "8'd48: rom_q = `D(8'h01);")
text = text.replace("8'd49: rom_q = `D(8'hFE);", "8'd49: rom_q = `D(8'h80);")

# 4. Fix WS2812 colors (GRB format)
old_ws = """    reg [23:0] ws_color; // GRB
    always @(*) begin
        if (!init_done)        ws_color = 24'h10_00_00;  // 暗红：初始化中
        else if (snap_active)  ws_color = 24'h20_20_40;  // 蓝紫：正在截图回传电脑
        else if (frame_cnt[3]) ws_color = 24'h00_30_00;  // 亮绿
        else                   ws_color = 24'h00_10_00;  // 暗绿
    end"""

new_ws = """    reg [23:0] ws_color; // GRB
    always @(*) begin
        if (!init_done)        ws_color = 24'h00_20_00;  // 暗红：复位与500ms晶振稳定等待中
        else if (snap_active)  ws_color = 24'h20_20_40;  // 蓝紫：正在截图回传电脑
        else if (frame_cnt[3]) ws_color = 24'h30_00_00;  // 亮绿：正常逐帧刷新
        else                   ws_color = 24'h10_00_00;  // 暗绿：正常逐帧刷新
    end"""

if old_ws in text:
    text = text.replace(old_ws, new_ws)
elif old_ws.replace("\n", "\r\n") in text:
    text = text.replace(old_ws.replace("\n", "\r\n"), new_ws.replace("\n", "\r\n"))

with open(path, 'w', encoding='utf-8') as f:
    f.write(text)

print('Patch applied successfully!')
