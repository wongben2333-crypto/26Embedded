# -*- coding: utf-8 -*-
"""link_tutorial.py —— 在两份 README 的索引里加上保姆级教程的链接

两份 README 的结构不同，锚点也不同：
  · 源 `fpga_hank\README.md`  —— 用 `- [文件名](路径) —— 说明` 的列表
  · 团队 `26Embedded\fpga_hank\README.md` —— 用 `| 图标 **名称** | 路径 |` 的表格
所以要分别处理。
"""
from __future__ import annotations

import io
import sys

sys.stdout.reconfigure(encoding='utf-8')

SRC = r'C:\Users\Danny\Desktop\FPGA competition\fpga_hank\README.md'
DST = r'C:\Users\Danny\Desktop\FPGA competition\26Embedded\fpga_hank\README.md'

# ---------- 源：列表式 ----------
p = SRC
c = io.open(p, encoding='utf-8').read()
anchor = '- [上电操作卡-正式交付.md](docs/上电操作卡-正式交付.md)'
add = ('- [138K开发板-保姆级上手指南.docx](docs/138K开发板-保姆级上手指南.docx) —— '
       '★ **从零开始：认识板子 → 接线 → 装驱动 → 烧录 → 听到声音**'
       '（含 12 张表格、术语表、症状速查表；假设读者完全没接触过 FPGA）\n')
if '保姆级上手指南' in c:
    print('源 README：已存在，跳过')
elif anchor in c:
    c = c.replace(anchor, add + anchor, 1)
    io.open(p, 'w', encoding='utf-8', newline='\n').write(c)
    print('源 README：✅ 已加教程链接')
else:
    print('源 README：!! 锚点未匹配')

# ---------- 团队：表格式 ----------
p = DST
c = io.open(p, encoding='utf-8').read()
anchor = '| 🔌 **上电后怎么操作** |'
add = ('| 📘 **138K 板子保姆级教程** | '
       '[`docs/138K开发板-保姆级上手指南.docx`](docs/138K开发板-保姆级上手指南.docx) '
       '← **从零开始，完全没接触过 FPGA 也能跟着做** |\n')
if '保姆级教程' in c:
    print('团队 README：已存在，跳过')
elif anchor in c:
    c = c.replace(anchor, add + anchor, 1)
    io.open(p, 'w', encoding='utf-8', newline='\n').write(c)
    print('团队 README：✅ 已加教程链接')
else:
    print('团队 README：!! 锚点未匹配')
