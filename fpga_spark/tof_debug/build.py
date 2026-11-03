# -*- coding: utf-8 -*-
import os, subprocess, sys

GW_CANDIDATES = [
    r"D:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe",
    r"F:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe",
    r"C:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe"
]
GW = next((p for p in GW_CANDIDATES if os.path.exists(p)), None)
if not GW:
    sys.exit("[FAIL] 未找到 gw_sh.exe")

SRC = os.path.dirname(os.path.abspath(__file__))
TCL = os.path.join(SRC, "tools", "build.tcl")

print("=" * 60)
print(f" 开始构建 Tang Mega 138K ToF 调试工程 (gw_sh)")
print("=" * 60)
res = subprocess.run([GW, TCL], cwd=SRC)
sys.exit(res.returncode)
