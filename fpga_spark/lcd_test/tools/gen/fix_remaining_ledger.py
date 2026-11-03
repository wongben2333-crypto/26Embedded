# -*- coding: utf-8 -*-
"""fix_remaining_ledger.py —— 修 A2 / A10 / REL_SH 默认值

★ A2：pt8211_tx.v 头部 L21-22 仍写"每 16 个相位里只有相位 15 一拍为高 / 占空比 1/16"
      那是**改 tH 之前**的描述。当前实现是相位 14、15 为高 ⇒ 占空比 2/16 = 12.5%。
      （L25 已写对，但 L21-22 的旧描述没删，会造成同一段注释自相矛盾。）

★ A10：释放时长不能写"8192 步 ≈ 83.9 ms"就完事 —— 那只在"从满幅 65536 释放"时成立。
      实际释放是从**保持电平 SUS_LEVEL = 49152** 往下降：
          步数 = 49152 / ((1<<16) >> REL_SH) = 49152 / 8 = **6144 步**
          时长 = 6144 × (EN_DIV/clk) = 6144 × 10.24 µs = **62.9146 ms**
      而 8192 步 / 83.886 ms 是"从满幅释放"的情形。
      两处（top.v L187、adsr.v L45）都用了错误近似，且与技术文档（62.9 ms）矛盾。

★ adsr.v 默认 REL_SH = 11 而 top.v 传 13 ⇒ 默认值与生产不一致（观感问题，对齐掉）。
"""
from __future__ import annotations

import io
import os
import sys

sys.stdout.reconfigure(encoding='utf-8')

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))


def patch(rel, pairs, label):
    p = os.path.join(ROOT, *rel.split('/'))
    c = io.open(p, encoding='utf-8').read()
    ok = 0
    for a, b in pairs:
        if a in c:
            c = c.replace(a, b, 1)
            ok += 1
        else:
            print('  [未匹配] %s' % a[:60])
    io.open(p, 'w', encoding='utf-8', newline='\n').write(c)
    print('%s：替换 %d/%d 处' % (label, ok, len(pairs)))


# ---------------------------------------------------------------- A2
patch('rtl/audio/pt8211_tx.v', [(
    """//      BCK **不是 50% 占空比方波**，而是【每 16 个相位里只有相位 15 一拍为高】
//      的窄脉冲（占空比 1/16）。周期仍由下面公式决定，但若把 BCK 画成方波、
//      或按"高电平持续半个周期"去推算，都会得到错误结论。""",
    """//      BCK **不是 50% 占空比方波**，而是【每 16 个相位里相位 14、15 两拍为高】
//      的窄脉冲（占空比 2/16 = 12.5%）。周期仍由下面公式决定，但若把 BCK 画成方波、
//      或按"高电平持续半个周期"去推算，都会得到错误结论。
//      （早期实现只高 1 拍 = 20 ns，低于 PT8211 手册 tH 最小值 25 ns，
//        已改为 2 拍 = 40 ns；详见下方 rise/bck_hi 处的注释。）""")], 'A2 pt8211 注释')

# ---------------------------------------------------------------- A10
RELEASE_OLD_TOP = '.REL_SH   (13),                     // 8192 步 × 10.24 µs ≈ 83.9 ms'
RELEASE_NEW_TOP = ('.REL_SH   (13),                     // 从 sustain 49152 起 6144 步 × 10.24 µs ≈ 62.9 ms\n'
                   '                                        //（从满幅 65536 起才是 8192 步 ≈ 83.9 ms）')

patch('rtl/top.v', [(RELEASE_OLD_TOP, RELEASE_NEW_TOP)], 'A10 top.v 释放注释')

RELEASE_OLD_ADSR = '//        REL_SH=13 → 8192 步 ≈ 83.9 ms  （释放，明显能听到"落下去"）'
RELEASE_NEW_ADSR = ('//        REL_SH=13 → 6144 步 ≈ 62.9 ms  （释放；从 sustain 49152 往下降）\n'
                    '//                   8192 步 ≈ 83.9 ms  （若从满幅 65536 起降，才是这个值）')

patch('rtl/synth/adsr.v', [
    (RELEASE_OLD_ADSR, RELEASE_NEW_ADSR),
    ('parameter integer REL_SH    = 11,           // 释放',
     'parameter integer REL_SH    = 13,           // 释放（与 top.v 生产配置对齐；默认 11 会与生产不符）'),
], 'A10 + REL_SH adsr.v')

print('\n完成。')
