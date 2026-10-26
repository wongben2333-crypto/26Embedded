# -*- coding: utf-8 -*-
with open('C:/Users/gjl50/Desktop/FPGA/fpga_spark/lcd_test/rtl/lcd_test_top.v', 'r', encoding='utf-8') as f:
    text = f.read()

import re
matches = re.findall(r"8'd(\d+)\s*:\s*rom_q\s*=\s*([^;]+);", text)
for pc, val in matches:
    if int(pc) <= 105:
        print(f"pc={int(pc):3d}: {val.strip()}")
