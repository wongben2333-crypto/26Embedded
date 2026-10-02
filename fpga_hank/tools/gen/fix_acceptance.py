# -*- coding: utf-8 -*-
"""fix_acceptance.py —— 修 run_acceptance.ps1 的两处缺陷

★ 为什么修（这是我自己写的验收脚本里的真实 bug）：
  1) 变调那一段用了 PowerShell here-string 内嵌 Python 代码，
     **here-string 的结束标记必须顶格**，而我缩进了 ⇒ 它没被识别成字符串，
     PowerShell 把 Python 代码当成命令去执行，报
     "is not recognized as the name of a cmdlet"，**而脚本仍报 PASS**。
     ⇒ **假 PASS**：正是"看起来成功"的典型，必须改成调用独立 .py 文件。
  2) 32 峰那一段用正则 `命中\\s*(\\d+)` 取数字，实际没匹配上，
     打印成"命中 /32"。已在新的独立脚本里由 Python 自己输出。

用法：python tools/gen/fix_acceptance.py
"""
from __future__ import annotations

import io
import os
import sys

sys.stdout.reconfigure(encoding='utf-8')

HERE = os.path.dirname(os.path.abspath(__file__))
P = os.path.normpath(os.path.join(HERE, '..', 'verify', 'run_acceptance.ps1'))

START = '# ============================================================ E. 证据② 变调'
END = '# ============================================================ F. 波形数据集'

NEW = '''# ============================================================ E. 证据② 变调
Section "E. 证据②：半音变调（基础要求③）"

$p7 = Join-Path $ROOT 'docs\\evidence\\tone_samples_pitch7.txt'
$cp = Join-Path $ROOT 'tools\\verify\\check_pitch_shift.py'
if ((Test-Path $p7) -and (Test-Path $cp) -and (Test-Path $PY)) {
    Write-Host "  pitch_semi=+7 时，32 个谱峰应从 200..6400 Hz 整体移到 300..9600 Hz"
    Write-Host ("  证据文件 : {0}  ({1} B)" -f $p7, (Get-Item $p7).Length)
    Write-Host ""
    # ★ 必须调用【独立 .py 文件】，不要用 here-string 内嵌 Python ——
    #   here-string 的结束标记必须顶格，一旦缩进就会失效、Python 代码被
    #   当成 PowerShell 命令执行，**而脚本仍报 PASS（假 PASS）**。本项目踩过。
    $eout = & $PY $cp --file $p7 --fs 97656.25 --semi 7 2>&1
    $eout | ForEach-Object { "$_" }
    $erc = $LASTEXITCODE
    Add-Result '证据②：半音变调' $(if ($erc -eq 0) { 'PASS' } else { 'FAIL' }) `
        "check_pitch_shift exit=$erc（32 峰整体移动 2^(7/12) 倍）"
} else {
    Write-Host "  [FAIL] 变调证据或判据脚本缺失" -ForegroundColor Red
    Add-Result '证据②：半音变调' 'FAIL' '证据文件或判据脚本缺失'
}

'''


def main():
    c = io.open(P, encoding='utf-8').read()
    i = c.find(START)
    j = c.find(END)
    assert i > 0, '起点标记未找到'
    assert j > i, '终点标记未找到'
    c2 = c[:i] + NEW + c[j:]
    io.open(P, 'w', encoding='utf-8', newline='\r\n').write(c2)
    print('已替换变调段（%d -> %d 字符）' % (j - i, len(NEW)))
    print('  改动 1：改用独立 check_pitch_shift.py（消除 here-string 假 PASS）')
    print('  改动 2：32 峰计数交由 Python 侧输出（不再用易失败的正则）')


if __name__ == '__main__':
    main()
