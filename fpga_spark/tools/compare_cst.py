import os
import sys

sys.stdout.reconfigure(encoding='utf-8')

p_cst_60 = r"C:\Users\gjl50\Desktop\嵌赛\Tang_Mega_60K_138K硬件资料\04_管脚约束_Pinout_Constraints\tang_mega_60K_pins.cst"
p_cst_138 = r"C:\Users\gjl50\Desktop\嵌赛\Tang_Mega_60K_138K硬件资料\04_管脚约束_Pinout_Constraints\tang_mega_138K_pins.cst"

def read_cst(path, name):
    print(f"==================== {name} CST ====================")
    if os.path.exists(path):
        with open(path, 'r', encoding='utf-8', errors='ignore') as f:
            lines = [l.strip() for l in f if l.strip() and not l.strip().startswith('//')]
            print(f"Total non-comment constraints: {len(lines)}")
            # Search audio, clock, hdmi, uart, key, led
            for kw in ['clk', 'audio', 'pa_', 'spk', 'hp_', 'hdmi', 'tmds', 'uart', 'key', 'btn', 'led', 'ws2812']:
                matches = [l for l in lines if kw in l.lower()]
                if matches:
                    print(f"--- Keyword '{kw}' ({len(matches)} lines) ---")
                    for m in matches[:6]:
                        print("  ", m)
    else:
        print("File not found")

read_cst(p_cst_60, "Tang Mega 60K")
read_cst(p_cst_138, "Tang Mega 138K")
