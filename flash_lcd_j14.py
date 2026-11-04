# -*- coding: utf-8 -*-
import os, subprocess, sys, time

CLI_CANDIDATES = [
    r"D:\Gowin\Gowin_V1.9.12.04_x64\Programmer\bin\programmer_cli.exe",
    r"F:\Gowin\Gowin_V1.9.12.04_x64\Programmer\bin\programmer_cli.exe",
    r"C:\Gowin\Gowin_V1.9.12.04_x64\Programmer\bin\programmer_cli.exe"
]
CLI = next((p for p in CLI_CANDIDATES if os.path.exists(p)), None)
if not CLI:
    sys.exit("[FAIL] 未找到 programmer_cli.exe")

SRC = os.path.dirname(os.path.abspath(__file__))
FS = os.path.join(SRC, "bitstream", "lcd_test_j14.fs")
if not os.path.exists(FS):
    FS = os.path.join(SRC, "eda_proj", "lcd_test_j14", "impl", "pnr", "lcd_test_j14.fs")

DEV = "GW5AST-138C"

print("=" * 60)
print(f" Tang Mega 138K  J14 LCD 合成器 Flash 固化烧录 (op 68)")
print(f" 器件: {DEV}   位流: {FS} ({os.path.getsize(FS):,} B)")
print("=" * 60)

# 操作码 68: exFlash Erase,Program thru GAO-Bridge Arora V (Tang Mega 138K 专用外部 SPI Flash 固化)
cmd = [CLI, "--device", DEV, "--frequency", "2.5MHz", "--fsFile", FS, "--operation_index", "68"]
t0 = time.time()
print("[FLASH] 正在擦除并烧录外部 SPI Flash (通常需 60~90 秒)，请勿断开电源或拔掉 USB...")
res = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
elapsed = time.time() - t0

print(res.stdout)

if res.returncode != 0 or "Error" in res.stdout or elapsed < 5.0:
    print(f"[FAIL] 固化失败！耗时 {elapsed:.1f}s")
    sys.exit(1)

print(f"[OK] Flash 固化完成，耗时 {elapsed:.1f}s！位流已永久写入板载 SPI Flash，重新上电自动加载运行。")
