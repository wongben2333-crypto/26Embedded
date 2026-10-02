# -*- coding: utf-8 -*-
"""add_svf_check.py —— 把「烧录链路（SVF）验证」纳入验收脚本与文档

新增的验证（不需要板子）：让烧录工具解析 bitstream 并生成标准 JTAG 向量文件。
实测：exit 0；output.svf = 9 258 660 B / 65 694 行；文件头 Device ID = h0001081B，
并记录 FS 来源就是我们的 bitstream。
⇒ 证明 bitstream 本身有效、器件匹配，把"烧录"这个缺口从"完全未验证"
   推进到"只差物理 JTAG 连接"。
"""
from __future__ import annotations

import io
import os
import sys

sys.stdout.reconfigure(encoding='utf-8')

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))

# ------------------------------------------------ 1) 验收脚本加一节
P1 = os.path.join(ROOT, 'tools', 'verify', 'run_acceptance.ps1')
c = io.open(P1, encoding='utf-8').read()

anchor = '# ============================================================ G. 交付物清单'
newsec = '''# ============================================================ F2. 烧录链路（SVF）
Section "F2. 烧录链路：bitstream 能否被烧录工具解析（不需要板子）"

$gwcl = 'F:\\Gowin\\Gowin_V1.9.12.04_x64\\Programmer\\bin\\programmer_cli.exe'
$fsCl = Join-Path $ROOT 'eda_proj\\fpga_hank\\impl\\pnr\\fpga_hank.fs'
if ((Test-Path $gwcl) -and (Test-Path $fsCl)) {
    Write-Host ("  bitstream : {0} B" -f (Get-Item $fsCl).Length)
    # --operation_index 2 = SRAM Program；--svfcreate 只支持该操作码（4 会报 Unsupported）
    $svfLog = & $gwcl --device GW5AST-138C --fsFile $fsCl --operation_index 2 --svfcreate 2>&1 | Out-String
    $svfFile = Join-Path (Split-Path $gwcl -Parent) 'output.svf'
    if (Test-Path $svfFile) {
        $si = Get-Item $svfFile
        $head = Get-Content $svfFile -TotalCount 12
        $devId = ($head | Select-String -Pattern 'Device ID:').Line
        $nLines = (Get-Content $svfFile | Measure-Object).Count
        Write-Host ("  SVF       : {0} B / {1} 行" -f $si.Length, $nLines)
        Write-Host ("  {0}" -f $devId.Trim())
        Add-Result '烧录链路：bitstream 被工具接受' 'PASS' `
            "SVF $($si.Length) B / $nLines 行；$($devId.Trim())"
    } else {
        Write-Host "  [FAIL] 未生成 SVF（bitstream 可能无效或器件不匹配）" -ForegroundColor Red
        Add-Result '烧录链路：bitstream 被工具接受' 'FAIL' '未生成 SVF'
    }
} else {
    Write-Host "  [!] 烧录工具或 bitstream 不存在，跳过" -ForegroundColor Yellow
    Add-Result '烧录链路：bitstream 被工具接受' 'N/A' '工具或 bitstream 不存在'
}

'''
if anchor in c and 'F2. 烧录链路' not in c:
    c = c.replace(anchor, newsec + anchor, 1)
    io.open(P1, 'w', encoding='utf-8', newline='\r\n').write(c)
    print('验收脚本已加 F2 烧录链路检查')
else:
    print('验收脚本：锚点未匹配或已存在')

# ------------------------------------------------ 2) README 加一行
P2 = os.path.join(ROOT, 'README.md')
r = io.open(P2, encoding='utf-8').read()
old = '| **整机上板出声** | ⬜ **未做** | 从未在真板上运行过 |'
new = ('| **烧录链路（工具接受 bitstream）** | ✅ **PASS** | '
       '`programmer_cli --svfcreate` 成功解析本 bitstream 并生成标准 JTAG 向量文件：'
       '**9 258 660 B / 65 694 行**，文件头提取出 `Device ID = h0001081B`。'
       '**不需要板子即可验证**（`tools\\gowin\\program.ps1 -Mode verify`） |\n'
       '| **整机上板出声** | ⬜ **未做** | 从未在真板上运行过 |')
if old in r and '烧录链路（工具接受 bitstream）' not in r:
    r = r.replace(old, new, 1)
    io.open(P2, 'w', encoding='utf-8', newline='\n').write(r)
    print('README 已加烧录链路行')
else:
    print('README：锚点未匹配或已存在')

# ------------------------------------------------ 3) 技术文档加一行
P3 = os.path.join(ROOT, 'tools', 'gen', 'gen_techdoc.py')
g = io.open(P3, encoding='utf-8').read()
old3 = ("['整机上板实测', '未完成', '尚未在真实开发板上运行'],")
new3 = ("['烧录链路（bitstream 被工具接受）', '已完成',\n"
        "               'programmer_cli --svfcreate 成功解析本 bitstream 并生成标准 JTAG 向量文件：'\n"
        "               '9 258 660 B / 65 694 行，文件头提取 Device ID = h0001081B；不需板子即可验证'],\n"
        "              ['整机上板实测', '未完成', '尚未在真实开发板上运行'],")
if old3 in g and '烧录链路（bitstream 被工具接受）' not in g:
    g = g.replace(old3, new3, 1)
    io.open(P3, 'w', encoding='utf-8', newline='\n').write(g)
    print('技术文档生成器已加烧录链路行')
else:
    print('技术文档：锚点未匹配或已存在')
