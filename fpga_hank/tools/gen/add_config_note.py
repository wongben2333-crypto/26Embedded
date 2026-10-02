# -*- coding: utf-8 -*-
"""add_config_note.py —— 技术文档补一句「生产值 vs 波形取证值」的说明

★ 为什么必须加（liaison 提出，且我认同）：
  本项目 ADSR 有【两套配置】，时长数字不同但都"对"：
    · 生产配置（top.v）    EN_DIV=512, ATK_SH=10, DEC_SH=10, REL_SH=13
                          起音 10.49 / 衰减 2.62 / 释放 62.91 ms
    · 波形取证配置（tb_wave.v）EN_DIV=64, ATK_SH=13, DEC_SH=16, REL_SH=16
                          起音 10.49 / 衰减 20.97 / 释放 62.91 ms
  如果不加说明，读者对照技术文档（2.6 ms）与波形取证数据（20.97 ms）会看到
  一个**看起来像矛盾**的数字 —— 而实际上两者各自都正确，只是配置不同。
  这类"数字对不上但其实都对"的地方，是评审最容易误解、也最伤可信度的地方，
  所以必须显式写出来。
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

anchor = "    H(doc, 3, '3.2.1 PT8211 时序合规性（逐项对照原厂手册）')"

note = '''    PARA(doc, '⚠️ 关于 ADSR 时长，本项目存在【两套配置】，数字不同但都正确，'
              '此处必须说明以免误读：')

    TABLE(doc,
          ['配置', '参数（EN_DIV / ATK_SH / DEC_SH / REL_SH）', '起音', '衰减', '释放'],
          [
              ['生产配置（rtl/top.v）', '512 / 10 / 10 / 13',
               '10.49 ms', '2.62 ms', '62.91 ms'],
              ['波形取证配置（sim/tb/tb_wave.v）', '64 / 13 / 16 / 16',
               '10.49 ms', '20.97 ms', '62.91 ms'],
          ],
          widths=[5.2, 4.6, 2.0, 2.0, 2.2])

    PARA(doc, '两套配置的差异是为了不同的目的：波形取证时把包络放慢，'
              '才能在屏幕上看清起音/衰减/释放的斜坡形状（2.6 ms 的衰减在整屏时间轴上'
              '只有几个像素）；而生产配置的包络更接近乐器的手感。'
              '**本文档第 3.2 节所列均为【生产配置】的数值。**')

''' + anchor

if anchor in g and '两套配置' not in g:
    g = g.replace(anchor, note, 1)
    io.open(P, 'w', encoding='utf-8', newline='\n').write(g)
    print('OK 技术文档已加「生产配置 vs 波形取证配置」说明表')
else:
    print('锚点未匹配或已存在')
