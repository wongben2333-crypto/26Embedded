# -*- coding: utf-8 -*-
"""Build the ATK-MD0700 8080 LCD + Audio Instrument Synthesizer for Tang Mega 138K Dock."""
import os
import shutil
import subprocess
import sys
import time

SRC = os.path.dirname(os.path.abspath(__file__))
GW = r"D:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe"
MIRROR = r"C:\lcd_j14_build"

TCL = """set root [file dirname [info script]]
cd $root
open_project lcd_test_j14.gprj
set_option -top_module lcd_test_top
set_option -synthesis_tool gowinsynthesis
set_option -output_base_name lcd_test_j14
set_option -verilog_std sysv2017
set_option -show_all_warn 1
run all
exit
"""


def find_files(work):
    v_files = []
    for r, d, fs in os.walk(os.path.join(work, "rtl")):
        for f in fs:
            if f.endswith(".v") and not f.startswith("bench_"):
                rel = os.path.relpath(os.path.join(r, f), work)
                v_files.append(rel.replace("\\", "/"))
    return sorted(v_files)


def generate_gprj(work):
    v_files = find_files(work)
    file_list_xml = "\n".join([f'<File path="{f}" type="file.verilog" enable="1"/>' for f in v_files])
    file_list_xml += '\n<File path="constraints/lcd_test_j14.cst" type="file.cst" enable="1"/>'
    gprj = f'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE gowin-fpga-project>
<Project><Template>FPGA</Template><Version>5</Version>
<Device name="GW5AST-138C" pn="GW5AST-LV138PG484AC1/I0">gw5ast138c-007</Device>
<FileList>
{file_list_xml}
</FileList>
<OptionList>
    <Option key="top_module" value="lcd_test_top"/>
    <Option key="verilog_std" value="sysv2017"/>
</OptionList>
</Project>'''
    with open(os.path.join(work, "lcd_test_j14.gprj"), "w", encoding="utf-8") as f:
        f.write(gprj)
    with open(os.path.join(work, "build_j14.tcl"), "w", encoding="utf-8") as f:
        f.write(TCL)


def copy_tree_sync(src, dst):
    if os.path.exists(dst):
        shutil.rmtree(dst)
    shutil.copytree(src, dst)


def prepare(work):
    if os.path.abspath(work) != os.path.abspath(SRC):
        os.makedirs(work, exist_ok=True)
        copy_tree_sync(os.path.join(SRC, "rtl"), os.path.join(work, "rtl"))
        copy_tree_sync(os.path.join(SRC, "constraints"), os.path.join(work, "constraints"))
    generate_gprj(work)


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
    if "Corrupted project file" in output or result.returncode != 0:
        work = MIRROR
        prepare(work)
        result = run(work)
        output = result.stdout + result.stderr
    print(output[-4000:])
    fs = os.path.join(work, "impl", "pnr", "lcd_test_j14.fs")
    if not os.path.exists(fs):
        sys.exit(f"[FAIL] No J14 bitstream generated; exit code {result.returncode}")
    dst = os.path.join(SRC, "bitstream", "lcd_ui_j14_138c_verified.fs")
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if os.path.exists(dst):
        try:
            os.chmod(dst, 0o666)
        except Exception:
            pass
    shutil.copy2(fs, dst)
    print(f"[OK] {dst} ({os.path.getsize(dst):,} bytes, {time.time() - t0:.0f}s)")


if __name__ == "__main__":
    main()
