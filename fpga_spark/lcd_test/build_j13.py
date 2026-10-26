# -*- coding: utf-8 -*-
import os, shutil, subprocess, sys, time
SRC=os.path.dirname(os.path.abspath(__file__))
GW=r"D:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe"
MIRROR=r"C:\lcd_j13_build"
GPRJ='''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE gowin-fpga-project>
<Project><Template>FPGA</Template><Version>5</Version>
<Device name="GW5AST-138C" pn="GW5AST-LV138PG484AC1/I0">gw5ast138c-007</Device>
<FileList><File path="rtl/lcd_test_top.v" type="file.verilog" enable="1"/><File path="rtl/ws2812_drv.v" type="file.verilog" enable="1"/><File path="constraints/lcd_test_j13.cst" type="file.cst" enable="1"/></FileList></Project>'''
TCL="set root [file dirname [info script]]\ncd $root\nopen_project lcd_test_j13.gprj\nrun all\nexit\n"
def prep(work):
    for d in ('rtl','constraints'): os.makedirs(os.path.join(work,d),exist_ok=True)
    if os.path.abspath(work)!=os.path.abspath(SRC):
        for d,names in (('rtl',('lcd_test_top.v','ws2812_drv.v')),('constraints',('lcd_test_j13.cst',))):
            for n in names: shutil.copy2(os.path.join(SRC,d,n),os.path.join(work,d,n))
    open(os.path.join(work,'lcd_test_j13.gprj'),'w',encoding='utf-8').write(GPRJ)
    open(os.path.join(work,'build_j13.tcl'),'w',encoding='utf-8').write(TCL)
def main():
    if not os.path.exists(GW): sys.exit(f'[FAIL] Gowin shell not found: {GW}')
    work=SRC; prep(work); t0=time.time(); r=subprocess.run([GW,'build_j13.tcl'],cwd=work,capture_output=True,text=True,encoding='utf-8',errors='replace')
    if 'Corrupted project file' in r.stdout+r.stderr: work=MIRROR; prep(work); r=subprocess.run([GW,'build_j13.tcl'],cwd=work,capture_output=True,text=True,encoding='utf-8',errors='replace')
    print((r.stdout+r.stderr)[-4000:]); fs=os.path.join(work,'impl','pnr','lcd_test_j13.fs')
    if not os.path.exists(fs): sys.exit(f'[FAIL] No bitstream generated; exit code {r.returncode}')
    dst=os.path.join(SRC,'bitstream','lcd_test_j13_138c.fs'); os.makedirs(os.path.dirname(dst),exist_ok=True); shutil.copy2(fs,dst); print(f'[OK] {dst} ({os.path.getsize(dst):,} bytes, {time.time()-t0:.0f}s)')
if __name__=='__main__': main()
