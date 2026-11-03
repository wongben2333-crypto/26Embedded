# -*- coding: utf-8 -*-
"""make_python_robust.py —— 让 run_acceptance.ps1 在 venv 缺失时优雅回退

★ 问题：`$PY = Join-Path $ROOT '_tools\venv\Scripts\python.exe'`
  这个 venv 是本机的开发环境（14 MB / 890 个文件），**没有随交付包一起走**。
  队友拿到仓库后直接跑 run_acceptance.ps1 会在"前置检查"就失败。

★ 修法：依次尝试
    1) <root>\_tools\venv\Scripts\python.exe  （本项目自带 venv，若在）
    2) 系统 PATH 里的 python
    3) 都没有 ⇒ 打印**明确的安装指引**并跳过依赖 Python 的判据（而不是崩掉）
  并同时补一句"需要哪些包"。

★ 同时改【两处】以保持一致：
    · fpga_hank\tools\verify\run_acceptance.ps1        （源，本机开发用）
    · 26Embedded\fpga_hank\tools\verify\run_acceptance.ps1（交付副本）
"""
from __future__ import annotations

import io
import os
import sys

sys.stdout.reconfigure(encoding='utf-8')

P_ROOT = r'C:\Users\Danny\Desktop\FPGA competition'
TARGETS = [
    os.path.join(P_ROOT, 'fpga_hank', 'tools', 'verify', 'run_acceptance.ps1'),
    os.path.join(P_ROOT, '26Embedded', 'fpga_hank', 'tools', 'verify', 'run_acceptance.ps1'),
]

OLD = "$PY   = Join-Path $ROOT '_tools\\venv\\Scripts\\python.exe'"

NEW = r'''# ★ Python 解释器：优先用项目自带 venv，找不到就回退到系统 python，都没有则提示安装。
#   为什么：`_tools\venv` 是本机的开发环境（约 14 MB / 890 个文件），
#   它**不随交付包一起走**；队友拿到仓库直接跑本脚本时，原来会在前置检查就失败。
$PY = Join-Path $ROOT '_tools\venv\Scripts\python.exe'
if (-not (Test-Path $PY)) {
    $sysPy = Get-Command python -ErrorAction SilentlyContinue
    if ($sysPy) {
        $PY = $sysPy.Source
        Write-Host "  [提示] 未找到项目自带 venv，改用系统 Python: $PY" -ForegroundColor Yellow
        Write-Host "         依赖 Python 的判据需要这些包：numpy scipy matplotlib python-docx lxml Pillow" -ForegroundColor Yellow
        Write-Host "         安装：python -m pip install numpy scipy matplotlib python-docx lxml Pillow" -ForegroundColor Yellow
    } else {
        Write-Host "  [警告] 找不到任何 Python —— 依赖 Python 的判据将被跳过或失败。" -ForegroundColor Yellow
        Write-Host "         请安装 Python 后执行：python -m pip install numpy scipy matplotlib python-docx lxml Pillow" -ForegroundColor Yellow
        $PY = 'python'
    }
}'''

for p in TARGETS:
    if not os.path.exists(p):
        print('  [跳过] %s 不存在' % p)
        continue
    c = io.open(p, encoding='utf-8').read()
    if 'Python 解释器：优先用项目自带 venv' in c:
        print('  [已改] %s' % os.path.basename(os.path.dirname(os.path.dirname(os.path.dirname(p)))))
        continue
    if OLD in c:
        io.open(p, 'w', encoding='utf-8', newline='\r\n').write(c.replace(OLD, NEW, 1))
        print('  [OK] 已加回退逻辑: %s' % p)
    else:
        print('  [!!] 锚点未匹配: %s' % p)
        i = c.find('$PY')
        print('       实际:', c[max(0, i - 60):i + 120].replace('\n', ' | '))
