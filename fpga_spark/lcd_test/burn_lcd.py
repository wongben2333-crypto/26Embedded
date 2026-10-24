# -*- coding: utf-8 -*-
"""
把 lcd_test 位流烧进 Tang Mega 138K（138C）的 SRAM

用法：  python burn_lcd.py
说明：
  - 用 operation_index = 2（SRAM Program，不带 Verify）。
    本板回读校验通路不可用，用 op 4 会误报 Verify failed（见 fpga_hank/README）。
  - SRAM 烧录掉电即失，重新上电后要再烧一次。
"""
import os
import subprocess
import sys
import time

CLI = r"D:\Gowin\Gowin_V1.9.12.04_x64\Programmer\bin\programmer_cli.exe"
SRC = os.path.dirname(os.path.abspath(__file__))
FS  = os.path.join(SRC, "bitstream", "lcd_test_138c.fs")
DEV = "GW5AST-138C"

if not os.path.exists(CLI):
    sys.exit(f"[FAIL] 找不到 programmer_cli.exe: {CLI}")
if not os.path.exists(FS):
    sys.exit(f"[FAIL] 找不到位流: {FS}\n       先运行 python build.py")

print("=" * 62)
print(" Tang Mega 138K (138C)  LCD 测试位流烧录")
print(f" 器件   : {DEV}")
print(f" 位流   : {FS}")
print(f" 大小   : {os.path.getsize(FS):,} 字节")
print("=" * 62)

cmd = [CLI, "--device", DEV, "--frequency", "2.5MHz",
       "--fsFile", FS, "--operation_index", "2"]

t0 = time.time()
res = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
print(f"完成，用时 {time.time()-t0:.1f}s，退出码 {res.returncode}")
print(res.stdout)
if res.stderr:
    print("[stderr]", res.stderr)
