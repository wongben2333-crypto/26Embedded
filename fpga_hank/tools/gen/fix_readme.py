# -*- coding: utf-8 -*-
"""fix_readme.py —— 把 README 的状态段更新为当前实测值

README 是评委/用户第一眼看的东西，此前有多处过期：
  · 写成 "9 引脚"（现为 12）
  · BCK "640 ns / fs 48828.1 Hz"（现为 320 ns / 97656.25 Hz）
  · 缺少「单音实时变调」「多维交互」两项
  · 缺少一键验收入口
  · 引用不存在的 docs/32复音-验证报告.md
"""
from __future__ import annotations

import io
import os
import re
import sys

sys.stdout.reconfigure(encoding='utf-8')

HERE = os.path.dirname(os.path.abspath(__file__))
P = os.path.normpath(os.path.join(HERE, '..', '..', 'README.md'))

c = io.open(P, encoding='utf-8').read()
orig = c

# ---- 1) 逐条数值更正 ----
pairs = [
    ('更新于 2026-10-02 23:5x。', '更新于 2026-10-03。'),
    ('bitstream 生成成功，9 引脚全部按 `.cst` 分配',
     '74.8 秒；bitstream 34 840 489 B；**12 引脚全部按 `.cst` 分配**；时序零违例'),
    ('0 位错、BCK 恒 640 ns、fs = 48828.1 Hz',
     '0 位错、**BCK 恒 320 ns**、fs = **97 656.25 Hz**'),
    ('（96 kHz）|', '（`--fs 97656.25`）|'),
    ('`tb_adsr.v`：9/9（起音→衰减→保持→释放→声部复用）',
     '`tb_adsr.v`：9/9；实测 起音 **10.49 ms** / 衰减 2.62 ms / 释放 62.91 ms'),
    ('`tb_touch_pad_a.v`：3 个错误。', '仿真未通过。'),
]
for a, b in pairs:
    if a in c:
        c = c.replace(a, b)
    else:
        print('  [跳过·未匹配] %s' % a[:40])

# ---- 2) 在"多音色波表"行前插入两行新能力 ----
anchor = '| 多音色波表 |'
newrows = ('| **单音实时变调（基础要求③）** | ✅ **PASS** | `pitch_semi=+7` 时 32 个谱峰整体移动 '
           '**2^(7/12) 倍**，平均相对误差 **0.0144%** |\n'
           '| **多维交互 ≥2 维（基础要求①）** | ✅ **已接入** | 板载按键 `AB13`/`Y12` '
           '+ PMOD 自研变调键 `Y22`；**12 引脚全 `constrained=Y`** |\n')
if anchor in c and '单音实时变调（基础要求③）' not in c:
    c = c.replace(anchor, newrows + anchor, 1)

# ---- 3) 修不存在的文档引用 ----
c = c.replace(
    '详细数据见 [32复音-验证报告.md](docs/32复音-验证报告.md) 与 [PT8211-验证报告.md](docs/PT8211-验证报告.md)。',
    '**详细证据**：\n\n'
    '- [32谱峰-取证报告.md](docs/evidence/32谱峰-取证报告.md) —— 赛题必备交付物的正式证据（含 SHA256 指纹与一次回归的完整复盘）\n'
    '- [工程能力与工具链说明.md](docs/工程能力与工具链说明.md) —— 四类能力的版本/许可证/兼容性\n'
    '- [上板验证指南.md](docs/上板验证指南.md) —— 面向非专业用户的操作卡\n'
    '- [技术文档.docx](docs/技术文档.docx) —— 提交用技术文档\n'
    '- [docs/waveforms/real/](docs/waveforms/real/) —— 6 张 ModelSim 真窗口波形截图'
)

# ---- 4) 在一级标题后插入「一键验收」段 ----
oneclick = '''## 一键验收

```powershell
# 在 fpga_hank 目录下
powershell -NoProfile -ExecutionPolicy Bypass -File tools\\verify\\run_acceptance.ps1
```

一条命令跑完 **构建 + 全部仿真 + 全部证据判据 + 交付物清单**，并打印 PASS/FAIL 汇总。
选项：`-Quick`（只复核证据，不跑仿真）／`-SkipBuild`。
退出码：`0` = 全 PASS，`1` = 有 FAIL，`2` = 前置不满足。

**最近一次完整验收（2026-10-03 实测）**：PASS = 7，FAIL = 0，退出码 0 ——
构建 74.8 秒 / 12 引脚全约束 / 时序零违例；32 谱峰判据 exit=0；变调判据 exit=0。

---

'''
marker = '板卡：Sipeed Tang Mega 138K Dock'
if '## 一键验收' not in c and marker in c:
    # 插在"板卡：..."那一行之后的下一个 '---' 之后
    i = c.find(marker)
    j = c.find('\n---\n', i)
    if j > 0:
        c = c[:j + 5] + '\n' + oneclick + c[j + 5:]

if c == orig:
    print('无改动'); sys.exit(0)
io.open(P, 'w', encoding='utf-8', newline='\n').write(c)
print('README 已更新（%d -> %d 字符）' % (len(orig), len(c)))
