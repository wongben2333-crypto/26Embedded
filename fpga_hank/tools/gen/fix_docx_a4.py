# -*- coding: utf-8 -*-
"""fix_docx_a4.py —— 把技术文档从 US Letter 改成 A4，并让表格宽度自动适配

★ 问题（实测）：
  · 生成器 `gen_techdoc.py` **没有显式设置页面尺寸** ⇒ python-docx 默认模板是
    **US Letter（215.9 x 279.4 mm）**；而中文竞赛文档的惯例是 **A4（210 x 297 mm）**。
    已核实往届国二模板 `技术文档-冯若陈-国二.pdf` 的 MediaBox = **A4**。
  · 而且现有表格宽度合计 **16.39 cm**，正好等于 Letter 在 2.6 cm 边距下的可用宽
    ⇒ **直接改成 A4 会让全部 14 个表格溢出**（A4 可用宽只有 15.8 cm）。

★ 修法：
  1. 显式把页面设为 **A4（21.0 x 29.7 cm）**，边距保持 2.2/2.2/2.6/2.6 cm（正式文档观感）；
  2. 在 `TABLE()` 里加**自动缩放**：若给的 widths 合计超过可用宽，就按比例缩到可用宽的 98%
     —— 这样以后再加表格也**不会溢出**，不用每次手算。
"""
from __future__ import annotations

import io
import os
import sys

sys.stdout.reconfigure(encoding='utf-8')

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
P = os.path.join(ROOT, 'tools', 'gen', 'gen_techdoc.py')

g = io.open(P, encoding='utf-8').read()
orig = g

# ---------------------------------------------------------------- 1) 页面设 A4
old1 = """for s in doc.sections:
    s.top_margin = Cm(2.2)"""
new1 = """# ★ 页面尺寸必须显式设为 A4：python-docx 的默认模板是 US Letter（215.9x279.4 mm），
#   而中文竞赛文档的惯例是 A4（210x297 mm）。
#   已核实往届国二模板 `技术文档-冯若陈-国二.pdf` 的 MediaBox = A4。
#   ⚠️ 不设的话不会报错，但打印/转 PDF 时页面尺寸与预期不符。
A4_W_CM, A4_H_CM = 21.0, 29.7
for s in doc.sections:
    s.page_width = Cm(A4_W_CM)
    s.page_height = Cm(A4_H_CM)
    s.top_margin = Cm(2.2)"""
if old1 in g:
    g = g.replace(old1, new1, 1)
    print('OK 1/2 页面已显式设为 A4')
else:
    print('!! 1/2 页面设置锚点未匹配')

# ---------------------------------------------------------------- 2) TABLE 自动缩放
old2 = """    if widths:
        for i, w in enumerate(widths):
            for row in t.rows:
                row.cells[i].width = Cm(w)
    return t"""
new2 = """    if widths:
        # ★ 自动缩放：合计宽度不得超过可用宽度，否则打印时会被裁切/挤压。
        #   这样以后新增表格不必手算，也不会溢出。
        avail_cm = A4_W_CM - 2.6 * 2          # 左右各 2.6 cm
        total = float(sum(widths))
        if total > avail_cm:
            k = (avail_cm * 0.98) / total
            widths = [w * k for w in widths]
            print('   [TABLE] 宽度合计 %.2f cm > 可用 %.2f cm，按 %.4f 缩放'
                  % (total, avail_cm, k))
        for i, w in enumerate(widths):
            for row in t.rows:
                row.cells[i].width = Cm(w)
    return t"""
if old2 in g:
    g = g.replace(old2, new2, 1)
    print('OK 2/2 TABLE() 已加自动缩放')
else:
    print('!! 2/2 TABLE 锚点未匹配')

if g != orig:
    io.open(P, 'w', encoding='utf-8', newline='\n').write(g)
    print('\n生成器已更新')
else:
    print('\n无改动')
