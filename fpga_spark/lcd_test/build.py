# -*- coding: utf-8 -*-
"""
构建 lcd_test 位流（Tang Mega 138K / 138C）

用法：  python build.py
产物：  bitstream/lcd_test_138c.fs

说明：
  - 正常情况下直接在工程目录里编译。
  - 如果工程被放在含中文的路径下（例如 "桌面\\嵌赛\\..."），gw_sh 会报
    ERROR (SP0002) Corrupted project file，此时自动改为镜像到 C:\\lcd_build 再编译。
  - gw_sh 经常在构建成功后、退出时崩溃（退出码 3221226505），属已知现象，
    因此判断成功只看位流是否真的生成，不看退出码。
"""
import os
import shutil
import subprocess
import sys
import time

SRC = os.path.dirname(os.path.abspath(__file__))
GW = r"D:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe"
MIRROR = r"C:\lcd_build"

GPRJ = """<?xml version="1" encoding="UTF-8"?>
<!DOCTYPE gowin-fpga-project>
<Project>
    <Template>FPGA</Template>
    <Version>5</Version>
    <Device name="GW5AST-138C" pn="GW5AST-LV138PG484AC1/I0">gw5ast138c-007</Device>
    <FileList>
        <File path="rtl/lcd_test_top.v" type="file.verilog" enable="1"/>
        <File path="rtl/ws2812_drv.v" type="file.verilog" enable="1"/>
        <File path="constraints/lcd_test.cst" type="file.cst" enable="1"/>
    </FileList>
</Project>
"""

TCL = """set root [file dirname [info script]]
cd $root
open_project lcd_test.gprj
run all
exit
"""


def prepare(work):
    """把源码和工程文件放到 work 目录（用相对路径，避免中文绝对路径）"""
    for d in ("rtl", "constraints"):
        os.makedirs(os.path.join(work, d), exist_ok=True)
    # 原地构建时文件已经在位，不能再 copy 到自己身上（Windows 会报 WinError 32）
    if os.path.abspath(work) != os.path.abspath(SRC):
        shutil.copy2(os.path.join(SRC, "rtl", "lcd_test_top.v"), os.path.join(work, "rtl"))
        shutil.copy2(os.path.join(SRC, "constraints", "lcd_test.cst"), os.path.join(work, "constraints"))
    with open(os.path.join(work, "lcd_test.gprj"), "w", encoding="utf-8") as f:
        f.write(GPRJ)
    with open(os.path.join(work, "build.tcl"), "w", encoding="utf-8") as f:
        f.write(TCL)


def run_build(work):
    r = subprocess.run([GW, "build.tcl"], cwd=work, capture_output=True,
                       text=True, encoding="utf-8", errors="replace")
    return r.returncode, r.stdout, r.stderr


def main():
    if not os.path.exists(GW):
        sys.exit(f"[FAIL] 找不到 gw_sh.exe: {GW}")

    print("=" * 62)
    print(" Tang Mega 138K (138C)  LCD 测试工程构建")
    print(f" 工程目录: {SRC}")
    print("=" * 62)

    t0 = time.time()
    work = SRC
    prepare(work)
    rc, out, err = run_build(work)

    if "Corrupted project file" in (out + err):
        print("[INFO] 中文路径导致 gw_sh 解析失败，改为镜像到 ASCII 目录构建…")
        work = MIRROR
        prepare(work)
        rc, out, err = run_build(work)

    for ln in [x for x in out.splitlines() if x.strip()][-6:]:
        print("   ", ln)

    if rc != 0:
        print(f"[WARN] gw_sh 退出码 {rc}（构建后退出崩溃，属已知现象，继续检查产物）")

    fs = os.path.join(work, "impl", "pnr", "lcd_test.fs")
    if not os.path.exists(fs):
        sys.exit(f"[FAIL] 没有生成位流（gw_sh 退出码 {rc}）")
    if os.path.getmtime(fs) < t0 - 2:
        sys.exit(f"[FAIL] 位流是旧的，本次没有真正构建（gw_sh 退出码 {rc}）")

    dst_dir = os.path.join(SRC, "bitstream")
    os.makedirs(dst_dir, exist_ok=True)
    dst = os.path.join(dst_dir, "lcd_test_138c.fs")
    if os.path.exists(dst):
        os.chmod(dst, 0o666)
    shutil.copy2(fs, dst)

    print("-" * 62)
    print(f"[OK] 用时 {time.time() - t0:.0f}s")
    print(f"     位流 -> {dst}")
    print(f"     大小 {os.path.getsize(dst):,} 字节")
    print("     下一步：python burn_lcd.py")


if __name__ == "__main__":
    main()
