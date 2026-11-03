# -*- coding: utf-8 -*-
"""mark_stale_reports.py —— 给两份【历史配置】的验证报告加醒目横幅

★ 问题：`docs/32复音-验证报告.md` 与 `docs/PT8211-验证报告.md` 写于 **10-02**，
  描述的是**【旧的 48.828 kHz 配置】（BCK_DIV=2）**：
      采样率 48828.125 Hz、BCK 周期 640 ns、位流 34 967 977 B、9 引脚、离散度 0.82 dB
  而当前配置（BCK_DIV=1）是：
      采样率 97656.25 Hz、BCK 周期 320 ns、位流 34 840 489 B、12 引脚、离散度 0.77 dB
  ⇒ 评委若先读到这两份，会与 README / 技术文档.docx 的数字**直接矛盾**。

★ 为什么【加横幅】而不是【改数字】：
  这两份是**特定时间点的验证记录**，其中的**方法论内容仍然有效且有价值**
  （怎么发现的 31/32、9.74 dB、87 个杂散等问题，以及当时的判据推导）。
  直接把数字改掉等于**伪造历史记录** —— 会失去"我们真的逐步验证过"这个价值。
  正确做法是**保留原文 + 明确标注它描述的是哪个配置 + 指向当前数据**。
"""
from __future__ import annotations

import io
import os
import sys

sys.stdout.reconfigure(encoding='utf-8')

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))

BANNER = """> # ⚠️ 历史文档 —— 描述的是【旧配置】，数字已过期，请勿据此引用
>
> **本文档写于 2026-10-02，描述的是当时的 `BCK_DIV = 2`（48.828 kHz）配置。**
> 项目后来把采样率提到 **96 kHz**（`BCK_DIV = 1`），并修掉了 BCK 高电平的规格问题，
> 因此下表里的多个数字**已经不是当前值**：
>
> | 项 | 本文档（历史，48.8 kHz） | **当前实际（96 kHz）** | 当前数值记录在 |
> |---|---|---|---|
> | 采样率 | 48 828.125 Hz | **97 656.25 Hz** | README / 技术文档.docx |
> | BCK 周期 | 640 ns | **320 ns** | 同上 |
> | BCK 高电平 | 40 ns（**当时低于手册 tH 25 ns 要求，已修**） | **40 ns**（周期减半后占 2/16） | 技术文档 3.2.1 |
> | 位流大小 | 34 967 977 B | **34 840 489 B** | README |
> | 引脚数 | 9 | **12**（新增三个交互按键） | README / 上电操作卡 |
> | 谱峰离散度 | 0.82 dB | **0.77 dB** | `docs/evidence/32谱峰-取证报告.md` |
>
> **本文档仍然有价值的**：它记录了**当时的验证方法与过程**
> —— 怎么发现"32 路只有 31 个谱峰""某一路电平高 9.74 dB""87 个谐波杂散"等问题，
> 以及判据的推导过程。**方法论部分依然成立，数字部分请以上表右列为准。**
>
> **要看当前的有效证据，请读**：
> - `docs/evidence/32谱峰-取证报告.md`（含 SHA256 指纹与一次真实回归的复盘）
> - [技术文档.docx](技术文档.docx)（3.2 性能参数 / 3.3 验证方法与证据）
> - `README.md` → 「当前状态」与「代码审查指引」

---

"""

FILES = ['32复音-验证报告.md', 'PT8211-验证报告.md']

for name in FILES:
    p = os.path.join(ROOT, 'docs', name)
    if not os.path.exists(p):
        print('  [跳过] %s 不存在' % name)
        continue
    c = io.open(p, encoding='utf-8').read()
    if '历史文档 —— 描述的是' in c:
        print('  [已标注] %s' % name)
        continue
    io.open(p, 'w', encoding='utf-8', newline='\n').write(BANNER + c)
    print('  [已加横幅] %s  (%d -> %d 字符)' % (name, len(c), len(BANNER) + len(c)))

print('\n完成。')
