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
FS = os.path.join(SRC, "bitstream", "tof_debug.fs")
if not os.path.exists(FS):
    FS = os.path.join(SRC, "eda_proj", "tof_debug", "impl", "pnr", "tof_debug.fs")

if not os.path.exists(FS):
    sys.exit(f"[FAIL] 未找到位流文件: {FS}，请先运行 python build.py 编译！")

DEV = "GW5AST-138C"

print("=" * 60)
print(f" Tang Mega 138K  ToF 测距调试工程位流烧录")
print(f" 器件: {DEV}   位流: {FS} ({os.path.getsize(FS):,} B)")
print("=" * 60)

cmd = [CLI, "--device", DEV, "--frequency", "2.5MHz", "--fsFile", FS, "--operation_index", "2"]
t0 = time.time()
res = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
elapsed = time.time() - t0

if res.returncode != 0 or "Error" in res.stdout or elapsed < 2.0:
    print(f"[FAIL] 烧录失败！耗时 {elapsed:.1f}s\n{res.stdout}")
    sys.exit(1)

print(f"[OK] SRAM 下载完成，耗时 {elapsed:.1f}s！位流已生效运行。")
