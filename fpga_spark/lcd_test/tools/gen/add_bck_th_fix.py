# -*- coding: utf-8 -*-
"""add_bck_th_fix.py —— 把「BCK 高电平低于手册 tH 最小值」这个缺陷写进技术文档与 README

这是本项目的第 6 个"编译无错、截图看不出、只能靠量化提取发现"的缺陷，
且是**唯一可能让上板没声音**的规格偏差 —— 很值得写进报告。
"""
from __future__ import annotations

import io
import os
import sys

sys.stdout.reconfigure(encoding='utf-8')

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))

# ---------------------------------------------- 技术文档：3.3.3 缺陷表加一行
P1 = os.path.join(ROOT, 'tools', 'gen', 'gen_techdoc.py')
g = io.open(P1, encoding='utf-8').read()

old = ("              ['32 谱峰判据突然全 FAIL',\n"
       "               '信号幅值从 ±18000 掉到 ±1200，直流偏置严重',\n"
       "               '对比 min/max/std 的数据形态；根因是新加的变调乘法高位被截断'\n"
       "               '（32 位容纳不下 44 位乘积）'],")
new = (old + "\n"
       "              ['BCK 高电平低于 DAC 手册最小值',\n"
       "               'BCK 高电平实测 20 ns，而 PT8211 手册对高电平时间 tH 要求 ≥25 ns；'\n"
       "               'DIN 在 BCK 上升沿被锁存，高电平过短可能锁存失败 ⇒ 上板可能没声音',\n"
       "               '把 BCK 高电平时间【量出来】才发现（20 vs 25 ns）。'\n"
       "               '波形截图上完全看不出来 —— 肉眼只看到\"有个高电平\"。'\n"
       "               '已改为占 2 个相位 = 40 ns，周期与采样率不变；'\n"
       "               '并把\"高电平 ≥ 手册 tH\"固化进 tb_pt8211_final 的判据'],")
if old in g and 'BCK 高电平低于 DAC 手册最小值' not in g:
    g = g.replace(old, new, 1)
    io.open(P1, 'w', encoding='utf-8', newline='\n').write(g)
    print('技术文档：3.3.3 缺陷表已加 BCK tH 一行')
else:
    print('技术文档：锚点未匹配或已存在')

# ---------------------------------------------- README：PT8211 行补上高电平实测
P2 = os.path.join(ROOT, 'README.md')
r = io.open(P2, encoding='utf-8').read()
old2 = '`tb_pt8211_final.v`：0 位错、**BCK 恒 320 ns**、fs = **97 656.25 Hz**'
new2 = ('`tb_pt8211_final.v`：0 位错、**BCK 恒 320 ns**、**高电平 40 ns**'
        '（≥ 手册 tH 最小值 25 ns）、fs = **97 656.25 Hz**')
if old2 in r:
    r = r.replace(old2, new2, 1)
    io.open(P2, 'w', encoding='utf-8', newline='\n').write(r)
    print('README：PT8211 行已补 BCK 高电平实测')
else:
    print('README：锚点未匹配')
