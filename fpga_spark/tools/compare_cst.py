import os
import sys

sys.stdout.reconfigure(encoding='utf-8')

dir_cst = r"C:\Users\gjl50\Desktop\嵌赛\Tang_Mega_60K_138K硬件资料\04_引脚约束与线长_Pinout_Constraints"
p60 = os.path.join(dir_cst, "tang_mega_60K_pins.cst")
p138 = os.path.join(dir_cst, "tang_mega_138K_pins.cst")

def parse_cst(path):
    pins = {}
    with open(path, 'r', encoding='utf-8', errors='ignore') as f:
        for line in f:
            line = line.strip()
            if line.startswith("IO_LOC"):
                # format: IO_LOC "port" PIN;
                parts = line.split()
                if len(parts) >= 3:
                    port = parts[1].replace('"', '').replace(';', '')
                    loc = parts[2].replace(';', '')
                    pins[port] = loc
    return pins

pins60 = parse_cst(p60)
pins138 = parse_cst(p138)

print(f"Total IO_LOC in 60K: {len(pins60)}")
print(f"Total IO_LOC in 138K: {len(pins138)}")

print("\n--- 关键外设引脚对照分析 (60K vs 138K) ---")
categories = {
    "时钟与复位 (Clock & Reset)": ["clk", "rst", "sys_clk", "osc"],
    "按键 (Keys / Buttons)": ["key", "btn", "sw"],
    "板载 LED": ["led"],
    "音频接口 (Audio / DAC / Headphone)": ["audio", "i2s", "spk", "pa_", "hp_", "dac", "pt8211"],
    "HDMI / DVI 视频输出": ["hdmi", "tmds", "dvi"],
    "UART / 串口": ["uart", "rx", "tx"],
    "PMOD 接口": ["pmod"],
    "WS2812 幻彩灯": ["ws2812", "rgb"]
}

for cat, keywords in categories.items():
    print(f"\n【{cat}】")
    print(f"{'信号名称':<25} | {'Tang Mega 60K':<15} | {'Tang Mega 138K':<15}")
    print("-" * 65)
    # find all matching ports
    all_ports = set()
    for kw in keywords:
        for p in pins60:
            if kw in p.lower(): all_ports.add(p)
        for p in pins138:
            if kw in p.lower(): all_ports.add(p)
    for p in sorted(all_ports):
        loc60 = pins60.get(p, "—")
        loc138 = pins138.get(p, "—")
        print(f"{p:<25} | {loc60:<15} | {loc138:<15}")
