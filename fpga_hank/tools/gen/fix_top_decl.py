# -*- coding: utf-8 -*-
"""fix_top_decl.py —— 把 DB_MAX 的声明提前到使用之前

问题：`top.v` 里 `DB_MAX` 的 localparam 声明在"交互维度 3（变调键）"之后，
      但那段逻辑在复位分支里就用了 DB_MAX ⇒ vlog 报
      `Undefined variable: 'DB_MAX'`。
      Verilog 对 localparam/net/reg 的**声明顺序敏感**（不同于函数内变量）。

做法：把该 localparam 移到 `wire rst_n = &por;` 之后（仍在使用点之前）。
"""
from __future__ import annotations

import io
import os
import sys

sys.stdout.reconfigure(encoding='utf-8')

HERE = os.path.dirname(os.path.abspath(__file__))
P = os.path.normpath(os.path.join(HERE, '..', '..', 'rtl', 'top.v'))

DECL = "    localparam [19:0] DB_MAX = 20'd131071;      // 2^17-1 \u2192 131072 clk = 2.621 ms"
ANCHOR = '    wire       rst_n = &por;'

c = io.open(P, encoding='utf-8').read()

if c.count(DECL) == 0:
    print('未找到原始声明，现有 DB_MAX 行：')
    for i, l in enumerate(c.split('\n'), 1):
        if 'DB_MAX' in l:
            print(' ', i, repr(l))
    sys.exit(1)

if c.count(DECL) > 1:
    print('已有多处声明，先归一化')
    c = c.replace('\n' + DECL + '\n', '\n')
    c = c.replace(DECL + '\n', '')
    c = c.replace(DECL, '')

# 删除原处
c = c.replace('\n' + DECL + '\n', '\n')

assert ANCHOR in c, '锚点 wire rst_n = &por; 未找到'

ADD = ('\n\n    // 去抖时长（两个板载按键 + 自研变调键共用）：2^17 clk = 2.621 ms\n'
       '    // ⚠️ 这是【控制→发声延迟的主要贡献项】，改它必须同步更新文档的延迟预算。\n'
       + DECL)
c = c.replace(ANCHOR, ANCHOR + ADD, 1)

io.open(P, 'w', encoding='utf-8', newline='\n').write(c)
print('已把 DB_MAX 提前到 rst_n 之后')
print('--- 确认 ---')
for i, l in enumerate(io.open(P, encoding='utf-8').read().split('\n'), 1):
    if 'DB_MAX' in l:
        print(' ', i, l.strip()[:90])
