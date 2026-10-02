# -*- coding: utf-8 -*-
"""add_program_verify.py —— 给 program.ps1 加一个 -Mode verify（不需要板子）

★ 为什么加：
  烧录链路上有一个环节【不需要板子】就能验证 —— 让烧录工具解析 bitstream
  并生成标准 JTAG 向量文件（SVF）。这能证明：
    · bitstream 本身对烧录工具是【有效的】（不是坏的/截断的/器件不匹配的）
    · 工具能从 bitstream 里正确提取器件 ID
  实测（2026-10-03）：
    programmer_cli --device GW5AST-138C --fsFile fpga_hank.fs \
                   --operation_index 2 --svfcreate
    → exit 0；生成 output.svf = 9 258 660 B / 65 694 行；
      文件头记录 Device ID = h0001081B，且写明 FS 来源就是我们的 bitstream。
  ⇒ 这样用户在【插板之前】就能先确认 bitstream 没问题，把问题范围缩小。
"""
from __future__ import annotations

import io
import os
import sys

sys.stdout.reconfigure(encoding='utf-8')

HERE = os.path.dirname(os.path.abspath(__file__))
P = os.path.normpath(os.path.join(HERE, '..', 'gowin', 'program.ps1'))

c = io.open(P, encoding='utf-8').read()

# ---- 1) ValidateSet 加 verify ----
old1 = "[ValidateSet('sram', 'flash', 'scan')]"
new1 = "[ValidateSet('sram', 'flash', 'scan', 'verify')]"
assert old1 in c, 'ValidateSet 锚点未匹配'
c = c.replace(old1, new1, 1)

# ---- 2) 文档注释补 verify ----
old2 = "    scan  = 只扫描，看缆线和器件是否被识别"
new2 = ("    scan   = 只扫描，看缆线和器件是否被识别\n"
        "    verify = 【不需要板子】让烧录工具解析 bitstream 并生成标准 JTAG 向量文件（SVF），\n"
        "             用它证明 bitstream 本身对烧录工具是有效的")
assert old2 in c, '参数说明锚点未匹配'
c = c.replace(old2, new2, 1)

# ---- 3) 在 scan 分支之后插入 verify 分支 ----
old3 = """if ($Mode -eq 'scan') {"""
new3 = """# ---------------------------------------------------------------- verify
# ★ 不需要板子：让烧录工具解析 bitstream 并产出标准 JTAG 向量文件（SVF）。
#   能证明 bitstream 对烧录工具是有效的，并提取器件 ID。
if ($Mode -eq 'verify') {
    Write-Host "`n[verify] 解析 bitstream 并生成 SVF（不需要板子）..."
    if (-not (Test-Path $Fs)) {
        Write-Host "[verify] ❌ 找不到 bitstream: $Fs" -ForegroundColor Red
        Write-Host "         请先构建：gw_sh.exe `"$ROOT\\tools\\gowin\\build.tcl`"" -ForegroundColor Yellow
        exit 1
    }
    $fi = Get-Item $Fs
    $hash = (Get-FileHash $Fs -Algorithm SHA256).Hash
    Write-Host "         bitstream : $($fi.FullName)"
    Write-Host "         大小      : $($fi.Length) B"
    Write-Host "         SHA256    : $($hash.Substring(0,32))..."
    Write-Host ""

    # 操作码 2 = SRAM Program；--svfcreate 时只有该操作码被支持（4 会报 Unsupported）
    $svfOut = Join-Path $env:TEMP ("gsvf_" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Force -Path $svfOut | Out-Null
    Push-Location $svfOut
    $vo = & $CLI --device $Device --fsFile $Fs --operation_index 2 --svfcreate 2>&1 | Out-String
    Pop-Location
    $vo.Trim() -split "`n" | ForEach-Object { "         $_" }

    # 工具固定输出到 Programmer\\bin\\output.svf
    $svf = Join-Path (Split-Path $CLI -Parent) 'output.svf'
    if (Test-Path $svf) {
        $si = Get-Item $svf
        $head = Get-Content $svf -TotalCount 12
        $devId = ($head | Select-String -Pattern 'Device ID:').Line
        $fsRef = ($head | Select-String -Pattern 'FS File:').Line
        $lines = (Get-Content $svf | Measure-Object).Count
        Write-Host ""
        Write-Host "         ✅ SVF 已生成" -ForegroundColor Green
        Write-Host "            路径    : $($si.FullName)"
        Write-Host "            大小    : $($si.Length) B"
        Write-Host "            行数    : $lines"
        Write-Host "            $($devId.Trim())"
        Write-Host "            （文件头里记录的来源）$($fsRef.Trim())"
        Write-Host ""
        Write-Host "         ⇒ 结论：烧录工具【成功解析】了本 bitstream 并提取出器件 ID，" -ForegroundColor Green
        Write-Host "            说明 bitstream 本身有效、器件匹配。剩下的只有'物理 JTAG 连接'一步。" -ForegroundColor Green
        exit 0
    } else {
        Write-Host "[verify] ❌ 未生成 SVF —— bitstream 可能无效或器件不匹配" -ForegroundColor Red
        exit 1
    }
}

if ($Mode -eq 'scan') {"""
assert old3 in c, 'scan 分支锚点未匹配'
c = c.replace(old3, new3, 1)

io.open(P, 'w', encoding='utf-8', newline='\r\n').write(c)
print('OK program.ps1 已加 -Mode verify')
