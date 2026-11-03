# -*- coding: utf-8 -*-
"""
把 lcd_test_j14 位流烧进 Tang Mega 138K（138C）的 SRAM

用法：  python burn_lcd_j14.py
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
FS  = os.path.join(SRC, "bitstream", "lcd_ui_j14_138c_verified.fs")
DEV = "GW5AST-138C"

if not os.path.exists(CLI):
    sys.exit(f"[FAIL] 找不到 programmer_cli.exe: {CLI}")
if not os.path.exists(FS):
    sys.exit(f"[FAIL] 找不到位流: {FS}\n       先运行 python build_j14.py")

print("=" * 62)
print(" Tang Mega 138K (138C)  J14 LCD 测试位流烧录")
print(f" 器件   : {DEV}")
print(f" 位流   : {FS}")
print(f" 大小   : {os.path.getsize(FS):,} 字节")
print("=" * 62)

# 1. 先扫描 JTAG 链路，确保板子已通电且器件被识别
print("[1/2] 检查 JTAG 链上的器件...")
scan_res = subprocess.run([CLI, "--scan"], capture_output=True, text=True, encoding="utf-8", errors="replace")
if "GW5AST-138" not in scan_res.stdout:
    print("[FAIL] 未检测到 FPGA 芯片！")
    print("      请检查：")
    print("      1. 板子是否已开机？(按一下或长按底板上的 PWR 电源键开机)")
    print("      2. 下载器 USB 线是否松动/接触不良？")
    print("      3. 板载电源指示灯是否正常亮起？")
    print("\n扫描详细输出：")
    print(scan_res.stdout)
    sys.exit(1)

print("      检测到 GW5AST-138 芯片在线！")

# 2. 烧录位流到 SRAM
print("[2/2] 开始向 SRAM 烧录位流 (预计耗时 ~30 秒)...")
cmd = [CLI, "--device", DEV, "--frequency", "2.5MHz",
       "--fsFile", FS, "--operation_index", "2"]

t0 = time.time()
res = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
elapsed = time.time() - t0

if res.returncode != 0 or "Error" in res.stdout or elapsed < 3.0:
    print(f"\n[FAIL] 烧录失败！用时 {elapsed:.1f}s，退出码 {res.returncode}")
    print(res.stdout)
    if res.stderr:
        print("[stderr]", res.stderr)
    sys.exit(1)

print(f"\n[OK] SRAM 下载完成，用时 {elapsed:.1f}s，退出码 {res.returncode}")
print(res.stdout)
print("[待验证] 尚未验证程序运行及 LCD 显示，请检查实屏或通过串口截图验证。")
