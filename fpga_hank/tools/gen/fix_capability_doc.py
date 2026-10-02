# -*- coding: utf-8 -*-
"""fix_capability_doc.py —— 修《工程能力与工具链说明.md》里的三处不准确

★ 为什么必须修（这是 objective (2) 的验收依据文档）：
  1) 第 124 行写「波形图 …… 由真实仿真导出（testbench $fwrite → CSV → 渲染）」——
     **与实际状态和用户指令都矛盾**：
       · 用户明确否决过自绘图（"不要自己绘图，可能自己骗自己"）；
       · 现在 `docs/waveforms/` 下只有 `real/`，是 6 张 **ModelSim 真窗口截图**
         （用 PrintWindow 抓的，不是渲染的）。
     这句话会让评委以为我们的波形证据是"脚本画的图"，**正好踩在用户最在意的点上**。
  2) 第 62 行提到 `spectrum_report.py` 与 `check_portability.ps1` —— **两个文件都不存在**。
     实际存在的是 `check_peaks.py`（32 谱峰判据）、`check_pitch_shift.py`（变调判据）、
     `run_acceptance.ps1`（端到端验收）。
  3) 波形图路径应写 `docs\\waveforms\\real\\*.png`。
"""
from __future__ import annotations

import io
import os
import sys

sys.stdout.reconfigure(encoding='utf-8')

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
P = os.path.join(ROOT, 'docs', '工程能力与工具链说明.md')

c = io.open(P, encoding='utf-8').read()
orig = c

# ---- 修 1：skill 表里两个不存在的脚本名 ----
old1 = ('| `fpga-verify` | 取证纪律 + 8 个脚本 + 形式验证模板 | '
        '`spectrum_report.py`（32 谱峰判据，含 UNSTABLE 稳定性防护）、'
        '`check_portability.ps1`（交付可移植性门禁）等 |')
new1 = ('| `fpga-verify` | 取证纪律 + 判据脚本 + 形式验证模板 | '
        '**实际存在**的判据脚本：`tools\\verify\\check_peaks.py`（32 谱峰判据）、'
        '`tools\\verify\\check_pitch_shift.py`（半音变调判据，逐峰对理论值）、'
        '`tools\\verify\\run_acceptance.ps1`（端到端验收，打印 PASS/FAIL 汇总） |')
if old1 in c:
    c = c.replace(old1, new1, 1)
    print('OK 修 1：skill 表里的脚本名改为实际存在的三个')
else:
    print('!! 修 1 锚点未匹配')

# ---- 修 2+3：验收口径里的波形图描述 ----
old2 = ('3. **波形图**：`docs\\waveforms\\*.png`，由**真实仿真导出**'
        '（testbench `$fwrite` → CSV → 渲染）')
new2 = ('3. **波形图**：`docs\\waveforms\\real\\*.png` —— 共 6 张，'
        '**全部是 ModelSim 真窗口截图**（用 `PrintWindow(hwnd, hdc, 2)` 抓的真实窗口，'
        '不是脚本画出来的图）。\n'
        '   > ⚠️ **本项目明确禁止"自己绘图"**（用户原话："不要自己绘图，可能自己骗自己"）。\n'
        '   > 早先尝试过"testbench `$fwrite` → CSV → matplotlib 渲染"的路线，'
        '   > **已废弃**，所有自绘草稿移到 `_smoke-test/matplotlib-drafts/`，不进交付物。\n'
        '   > 理由：渲染图是"用我们自己的数据、我们自己的假设画的图"，'
        '   > 一旦渲染逻辑或假设错了，图会**自证其说**；\n'
        '   > 真窗口截图则是 ModelSim 自己的显示结果，**不给我们在中间做手脚的机会**。')
if old2 in c:
    c = c.replace(old2, new2, 1)
    print('OK 修 2+3：波形图描述改为"ModelSim 真窗口截图"并写明禁止自绘图的理由')
else:
    print('!! 修 2 锚点未匹配，实际内容：')
    i = c.find('波形图')
    print(c[max(0, i - 200):i + 300])

# ---- 补：把"一键验收"补进验收口径 ----
old3 = ('其它手段（Python 脚本、形式验证、隔离基准实验）**只作辅助排查，不得作为验收依据**。')
new3 = ('其它手段（Python 脚本、形式验证、隔离基准实验）**只作辅助排查，不得作为验收依据**。\n'
        '\n'
        '### 一键复核\n'
        '\n'
        '```powershell\n'
        'powershell -NoProfile -ExecutionPolicy Bypass -File tools\\verify\\run_acceptance.ps1\n'
        '```\n'
        '\n'
        '跑完 前置检查 → 构建 → 全部仿真 → 32 谱峰判据 → 变调判据 → 波形数据集 →\n'
        '真窗口截图 → 烧录链路（SVF）→ 交付物清单，并打印 PASS/FAIL 汇总。\n'
        '最近一次：**PASS = 9，FAIL = 0**。\n'
        '\n'
        '> ⚠️ **注意**：这个脚本自己也曾有过一个"假 PASS"（变调那段用 PowerShell\n'
        '> here-string 内嵌 Python，结束标记没顶格 ⇒ 代码没执行却报 PASS）。\n'
        '> 已改为调用独立 `.py` 文件。**判据脚本自己也会错**，这一点请一并注意。')
if old3 in c:
    c = c.replace(old3, new3, 1)
    print('OK 补：一键验收命令 + "判据脚本自己也会错"的提醒')
else:
    print('!! 补锚点未匹配')

if c != orig:
    io.open(P, 'w', encoding='utf-8', newline='\n').write(c)
    print('\n文档已更新：%d -> %d 字符' % (len(orig), len(c)))
else:
    print('\n无改动')
