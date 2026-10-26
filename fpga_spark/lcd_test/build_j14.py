# -*- coding: utf-8 -*-
"""Build the ATK-MD0700 8080 LCD test bitstream for Dock J14."""
import os
import shutil
import subprocess
import sys
import time

SRC = os.path.dirname(os.path.abspath(__file__))
GW = r"D:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe"
MIRROR = r"C:\lcd_j14_build"

GPRJ = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE gowin-fpga-project>
<Project><Template>FPGA</Template><Version>5</Version>
<Device name="GW5AST-138C" pn="GW5AST-LV138PG484AC1/I0">gw5ast138c-007</Device>
<FileList><File path="rtl/lcd_test_top.v" type="file.verilog" enable="1"/><File path="rtl/ws2812_drv.v" type="file.verilog" enable="1"/><File path="constraints/lcd_test_j14.cst" type="file.cst" enable="1"/></FileList></Project>'''
TCL = "set root [file dirname [info script]]\ncd $root\nopen_project lcd_test_j14.gprj\nrun all\nexit\n"


def prepare(work):
    for d in ("rtl", "constraints"):
        os.makedirs(os.path.join(work, d), exist_ok=True)
    if os.path.abspath(work) != os.path.abspath(SRC):
        for d, names in (("rtl", ("lcd_test_top.v", "ws2812_drv.v")),
                         ("constraints", ("lcd_test_j14.cst",))):
            for name in names:
                shutil.copy2(os.path.join(SRC, d, name), os.path.join(work, d, name))
    with open(os.path.join(work, "lcd_test_j14.gprj"), "w", encoding="utf-8") as f:
        f.write(GPRJ)
    with open(os.path.join(work, "build_j14.tcl"), "w", encoding="utf-8") as f:
        f.write(TCL)


def run(work):
    return subprocess.run([GW, "build_j14.tcl"], cwd=work, capture_output=True,
                          text=True, encoding="utf-8", errors="replace")


def main():
    if not os.path.exists(GW):
        sys.exit(f"[FAIL] Gowin shell not found: {GW}")
    t0 = time.time()
    work = SRC
    prepare(work)
    result = run(work)
    output = result.stdout + result.stderr
    if "Corrupted project file" in output:
        work = MIRROR
        prepare(work)
        result = run(work)
        output = result.stdout + result.stderr
    print(output[-5000:])
    fs = os.path.join(work, "impl", "pnr", "lcd_test_j14.fs")
    if not os.path.exists(fs):
        sys.exit(f"[FAIL] No J14 bitstream generated; exit code {result.returncode}")
    dst = os.path.join(SRC, "bitstream", "lcd_test_j14_138c_verified.fs")
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if os.path.exists(dst):
        os.chmod(dst, 0o666)
    shutil.copy2(fs, dst)
    print(f"[OK] {dst} ({os.path.getsize(dst):,} bytes, {time.time() - t0:.0f}s)")


if __name__ == "__main__":
    main()

