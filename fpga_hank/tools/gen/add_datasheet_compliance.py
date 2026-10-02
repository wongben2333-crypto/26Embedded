# -*- coding: utf-8 -*-
"""add_datasheet_compliance.py —— 把「PT8211 手册 AC 特性合规表」写进技术文档

来源：原厂手册 PTC V1.7 的 AC Characteristics 表（提取文本
      `_verify-flow/refs/pt8211_ptc_v17.txt` 第 1096-1282 行）：
        Fbck (BCK 频率)      max 18.4 MHz
        Fws  (WS 频率)       max 384  kHz
        Fdin (输入数据率)     max 18.4 Mbit/s
        tH   (H Level Time)  min 25  ns
        tR / tF (上升/下降)   max 20  ns  ← DAC 自身 I/O 特性，不受 FPGA 控制
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

anchor = "    H(doc, 3, '3.2.1 频谱取证数据（赛题必备交付物）')"
new = '''    H(doc, 3, '3.2.1 PT8211 时序合规性（逐项对照原厂手册）')

    PARA(doc, '音频链路能不能出声，不只取决于逻辑对不对，还取决于时序是否满足 DAC 的'
              '电气规格。本项目把原厂手册（PTC V1.7）AC 特性表里的每一项都提取出来，'
              '与设计逐项对照 —— 这项检查发现了一个【用波形截图完全看不出来】的规格偏差。')

    TABLE(doc,
          ['参数', '含义', '手册限值', '本设计实测', '结论'],
          [
              ['Fbck', 'BCK 位时钟频率', '≤ 18.4 MHz', '3.125 MHz', 'OK（占 17%）'],
              ['Fws', 'WS 字时钟频率', '≤ 384 kHz', '97.656 kHz', 'OK（占 25%）'],
              ['tH', 'BCK 高电平时间', '≥ 25 ns', '40 ns', 'OK（余量 60%）'],
              ['tR / tF', 'DAC 上升/下降时间', '≤ 20 ns',
               'DAC 自身 I/O 特性', '不受 FPGA 控制'],
          ],
          widths=[2.0, 3.6, 2.8, 3.2, 3.4])

    PARA(doc, '上表三项均由 tb_pt8211_final.v 在每次仿真时自动检查并打印，'
              '避免"改一处引入超规格"。')

    PARA(doc, '⚠️ 其中 tH 这一项是【修过的】：初版实现里 BCK 高电平只有 1 个时钟相位 = 20 ns，'
              '比手册最小值 25 ns 短 20%。由于 DIN 是在 BCK 的上升沿被锁存，'
              '高电平过短可能让 DAC 来不及可靠锁存 —— 也就是说，'
              '这【直接关系到上板第一次能不能出声】。'
              '它在波形截图上完全看不出来：肉眼只看到"有个高电平"，'
              '必须把时间真的量出来（20 ns vs 25 ns）才会暴露。'
              '修法是把高电平从 1 个相位加宽到 2 个（40 ns）；'
              '因为 BCK 周期仍是 16 个相位，所以【采样率完全不变】，修改零性能代价。')

''' + anchor

if anchor in g and 'PT8211 时序合规性' not in g:
    g = g.replace(anchor, new, 1)
    io.open(P, 'w', encoding='utf-8', newline='\n').write(g)
    print('技术文档生成器：已加 3.2.1 时序合规表，原频谱取证顺延')
else:
    print('锚点未匹配或已存在')

# 原「3.2.1 频谱取证数据」改名为 3.2.2
g = io.open(P, encoding='utf-8').read()
g = g.replace("H(doc, 3, '3.2.1 频谱取证数据（赛题必备交付物）')",
              "H(doc, 3, '3.2.2 频谱取证数据（赛题必备交付物）')")
io.open(P, 'w', encoding='utf-8', newline='\n').write(g)
print('已把频谱取证顺延为 3.2.2')
