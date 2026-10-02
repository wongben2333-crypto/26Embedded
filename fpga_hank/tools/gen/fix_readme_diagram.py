# -*- coding: utf-8 -*-
"""fix_readme_diagram.py —— 更新 README 的数据通路图（加入按键与变调）

此前图里只有 bench_gate，没有反映已接入的三个按键与 pitch_semi 通路。
"""
from __future__ import annotations

import io
import os
import sys

sys.stdout.reconfigure(encoding='utf-8')

HERE = os.path.dirname(os.path.abspath(__file__))
P = os.path.normpath(os.path.join(HERE, '..', '..', 'README.md'))

FENCE = '`' * 3

OLD = '\n'.join([
    FENCE,
    'bench_gate ──gate[32]──► adsr ──level_rd──► tone_bank ──mix──► pt8211_tx ──► PT8211 DAC',
    '     ▲                     ▲                   │',
    '     │                     └── env_voice ◄──────┘',
    '     └── 真实演奏模式下换成「电容触摸/光电/压力 → 按键扫描 → 声部分配器」',
    FENCE,
])

NEW = '\n'.join([
    FENCE,
    '按键 AB13 ─┐',
    '按键 Y12  ─┼─► 同步+去抖(2.621ms) ─► gate[32] ─► adsr ─► tone_bank ─► pt8211_tx ─► PT8211 DAC',
    '按键 Y22  ─┘        │                         ▲          │',
    ' (变调)             │                         │          │',
    '                    └── pitch_semi ───────────┘  env_voice ─┘',
    '                         (运行时半音变调)',
    '',
    '测试模式：gate 改由 bench_gate 提供（32 路恒按住），音色锁纯正弦表',
    FENCE,
])

c = io.open(P, encoding='utf-8').read()
if OLD in c:
    io.open(P, 'w', encoding='utf-8', newline='\n').write(c.replace(OLD, NEW, 1))
    print('OK 数据通路图已更新')
elif '按键 AB13' in c:
    print('OK 已是新版，跳过')
else:
    i = c.find('## 数据通路')
    print('未匹配。实际内容：')
    print(c[i:i + 400])
    sys.exit(1)
