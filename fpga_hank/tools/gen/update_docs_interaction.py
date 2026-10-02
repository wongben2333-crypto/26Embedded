# -*- coding: utf-8 -*-
"""update_docs_interaction.py —— 把「交互通路已验证」写进 README 与技术文档生成器

背景：基础要求①（多维交互）此前只有"编译通过 + 引脚约束"作证据，
      不是功能验证。新增 sim/tb/tb_interaction.v 后，9 项功能检查全部 PASS。
      本脚本把这条证据同步进两份交付文档。
"""
from __future__ import annotations

import io
import os
import sys

sys.stdout.reconfigure(encoding='utf-8')

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))

# ---------------------------------------------------------------- README
P1 = os.path.join(ROOT, 'README.md')
c = io.open(P1, encoding='utf-8').read()
old = '| **多维交互 ≥2 维（基础要求①）** | ✅ **已接入** | 板载按键 `AB13`/`Y12` + PMOD 自研变调键 `Y22`；**12 引脚全 `constrained=Y`** |'
new = ('| **多维交互 ≥2 维（基础要求①）** | ✅ **PASS** | `tb_interaction.v` **9 项全 PASS**：'
       '去抖(抖 10 次只认 1 次)、按住→gate 全高、包络起音、松开→释放、'
       '换音色、变调、**且按住期间换音色/变调不影响 gate（维度独立）**；'
       '引脚 `AB13`/`Y12`/`Y22` 全 `constrained=Y` |')
if old in c:
    c = c.replace(old, new, 1)
    io.open(P1, 'w', encoding='utf-8', newline='\n').write(c)
    print('README 已更新（多维交互行）')
else:
    print('README: 未匹配该行')

# ---------------------------------------------------------------- 技术文档生成器
P2 = os.path.join(ROOT, 'tools', 'gen', 'gen_techdoc.py')
g = io.open(P2, encoding='utf-8').read()

old2 = ("['多维交互检测（基础要求①）', '已完成', "
        "'两个板载按键 AB13/Y12 + PMOD 自研变调键 Y22；12 引脚全部 constrained=Y'],")
new2 = ("['多维交互检测（基础要求①）', '已完成',\n"
        "               'tb_interaction.v 9 项全 PASS（去抖/起音/释放/换音色/变调/维度独立性）；'\n"
        "               '引脚 AB13/Y12/Y22 全 constrained=Y'],")
if old2 in g:
    g = g.replace(old2, new2, 1)
    print('技术文档：完成情况表已更新')
else:
    print('技术文档：完成情况表未匹配')

# 在 3.3.3 的缺陷表后补一段"交互通路"的验证说明
anchor = ("    PARA(doc, '这些缺陷的共同点：**它们都不影响编译，也不影响\"波形看起来对不对\"**。'\n"
          "              '只有把\"期望值\"算出来、和实测值逐项比对，才会暴露。'\n"
          "              '这也是我们把验证方法单独成节的原因。')")
add = anchor + """

    H(doc, 3, '3.3.4 基础要求①（多维交互）的功能验证')

    PARA(doc, '在写完交互逻辑之后，我们一度只有"编译通过 + 12 个引脚全部 constrained=Y"'
              '作为该项要求的证据。但那只证明【接线对了】，不证明【功能对了】——'
              '按键按下究竟有没有让 gate 变高、包络有没有真的起音、换音色有没有生效，'
              '都还没有验证过。对一项【基础要求】来说这是不够的。')

    PARA(doc, '为此新增 tb_interaction.v。它把顶层用 TEST_MODE=0（演奏模式）例化，'
              '从而真正测到"按键 → 两级同步 → 去抖 → gate → ADSR 包络"这条通路。'
              '（原先 TEST_MODE 是文件级 localparam、测试台无法覆盖，'
              '已改为模块参数——默认值不变，正式构建行为不受影响。）')

    TABLE(doc,
          ['#', '验证内容', '实测结果'],
          [
              ['1', '复位后应静音', 'gate=0、包络电平=0'],
              ['2', '抖动用例：key 快速通断 10 次（每次远短于去抖窗）',
               '去抖后状态不变 —— 去抖生效'],
              ['3', '按住 key', 'gate 变为全 1、去抖后 key_db=1'],
              ['4', '包络起音', '电平 25 280 → 55 808（递增）'],
              ['5', '按住 key 期间按 key2 换音色',
               '音色号 +1，且 gate 仍为全 1'],
              ['6', '按住 key 期间按第三键变调',
               'pitch_semi 由 0 变 +1，且 gate 仍为全 1'],
              ['7', '松开 key', 'gate 归 0'],
              ['8', '包络释放', '电平 49 120 → 39 744（递减）'],
              ['9', '连按 4 下切换键', '音色号 1→2→3→0，回到起点（4 档循环）'],
          ],
          widths=[1.2, 7.0, 6.8])

    PARA(doc, '其中第 5、6 项是"独立可控维度"的关键证据：'
              '**在按住发声的过程中换音色或变调，gate 不受任何影响** ——'
              '说明三个维度互不干扰，是真正独立的控制通道，'
              '而不是"同一个开关的不同写法"。')
"""
if anchor in g:
    g = g.replace(anchor, add, 1)
    print('技术文档：已加 3.3.4 交互验证小节')
else:
    print('技术文档：3.3.3 末尾锚点未匹配')

io.open(P2, 'w', encoding='utf-8', newline='\n').write(g)
print('技术文档生成器已更新')
