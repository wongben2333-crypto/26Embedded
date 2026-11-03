# -*- coding: utf-8 -*-
"""check_docx_layout.py —— 技术文档的版式体检（页面尺寸 / 页边距 / 表格宽度 / 字体）

★ 为什么要查：这份 .docx 是要提交的主文档。
  用 python-docx 的默认模板 `Document()` 时，页面是 **US Letter（8.5x11 in）**，
  而中文竞赛文档的惯例是 **A4（210x297 mm）**。
  尺寸不对不会让任何检查失败，但打印/转换 PDF 时会与预期不符。
"""
from __future__ import annotations

import sys

from docx import Document
from docx.shared import Mm

sys.stdout.reconfigure(encoding='utf-8')

PATH = sys.argv[1] if len(sys.argv) > 1 else r'docs\技术文档.docx'

MM = 914400 / 25.4  # EMU per mm


def mm(v):
    return None if v is None else v / MM


d = Document(PATH)
sec = d.sections[0]

pw, ph = mm(sec.page_width), mm(sec.page_height)
lm = mm(sec.left_margin) or 0
rm = mm(sec.right_margin) or 0
tm = mm(sec.top_margin) or 0
bm = mm(sec.bottom_margin) or 0
avail = pw - lm - rm

print('页面尺寸   : %.1f x %.1f mm' % (pw, ph))
kind = 'A4 (210x297)' if abs(pw - 210) < 2 and abs(ph - 297) < 2 else (
    'US Letter (215.9x279.4)' if abs(pw - 215.9) < 2 else '其它')
print('            → %s' % kind)
print('页边距     : 上%.1f 下%.1f 左%.1f 右%.1f mm' % (tm, bm, lm, rm))
print('可用宽度   : %.1f mm' % avail)
print('段落 %d   表格 %d' % (len(d.paragraphs), len(d.tables)))
print()

bad = 0
for i, t in enumerate(d.tables, 1):
    widths = [mm(c.width) for c in t.columns]
    tot = sum(w for w in widths if w)
    over = tot - avail
    flag = ''
    if over > avail * 0.02:
        flag = '   ⚠️ 超出可用宽度 %.1f mm' % over
        bad += 1
    print('  表%-2d %2d行 x %2d列   总宽 %6.1f mm%s' % (i, len(t.rows), len(t.columns), tot, flag))

print()
if bad:
    print('⚠️ %d 个表格超出可用宽度 —— 打印/转 PDF 时会被裁切或挤压' % bad)
else:
    print('✅ 全部表格宽度在可用范围内')

# 中文字体
from docx.oxml.ns import qn
tot_run = miss = 0
for p in d.paragraphs:
    for r in p.runs:
        if not r.text.strip():
            continue
        tot_run += 1
        rpr = r._element.find(qn('w:rPr'))
        rf = rpr.find(qn('w:rFonts')) if rpr is not None else None
        if rf is None or not rf.get(qn('w:eastAsia')):
            miss += 1
print('\n中文字体   : 含文本 run %d 个，未设 eastAsia 的 %d 个 %s'
      % (tot_run, miss, '✅' if miss == 0 else '⚠️'))
