# -*- coding: utf-8 -*-
"""add_pnr_nondeterminism.py —— 在 README 记录「位流 SHA256 不能当修订标识」

★ 实测：同一份 RTL 连续构建两次，`.fs` 的 SHA256 不同
    （大小 34 840 489 B / Logic 5920 / FF 1699 / DSP 58 / 时序违例 0-0 全部相同）
  ⇒ 高云时序驱动 P&R 是**非确定性**的。
"""
from __future__ import annotations

import io
import os
import sys

sys.stdout.reconfigure(encoding='utf-8')

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
P = os.path.join(ROOT, 'README.md')

TITLE = '## ⚠️ 一条重要方法论：位流的 SHA256【不能】当修订标识'

ENTRY = '''## ⚠️ 一条重要方法论：位流的 SHA256【不能】当修订标识

实测发现：**同一份 RTL、连续构建两次，`.fs` 的 SHA256 不同**：

| | 大小 | Logic | FF | DSP | 时序违例 | SHA256 |
|---|---|---|---|---|---|---|
| 构建 A | 34 840 489 B | 5920 | 1699 | 58 | 0 / 0 | `1DD9C8D7…` |
| 构建 B | 34 840 489 B | 5920 | 1699 | 58 | 0 / 0 | `9B0729DB…` |

⇒ **高云的时序驱动 P&R 是非确定性的**（布局/布线在不同运行间存在合法差异）。

**由此产生三个必须记住的结论**：

1. **不能用 `.fs` 的哈希判断"两个位流是不是同一版设计"** ——
   哈希不同**不代表**设计不同。
2. **判断修订，要哈希【RTL 源码】，不是位流。**
   本项目 `tools/gowin/build_smoke.ps1` 的修订号守卫就是这么做的
   （构建前后对 `rtl/**/*.v` + `constr/*` 拍 SHA256 并比对，不一致就 `exit 6` 拒绝交付）。
3. **"重建后哈希不一致"不是构建失败** —— 要看**大小 + 资源占用 + 时序违例**
   三者是否一致。本例三者完全一致 ⇒ 功能等价。

> 这条是实测撞出来的：我原想用"重建并比对哈希"来证明"交付的位流 == 交付的 RTL"，
> 结果两次哈希不同。**如果没有意识到 P&R 的非确定性，很容易把这个误判成
> "构建有问题"或"代码被人改过"，从而浪费大量时间去查一个不存在的问题。**

---

'''

c = io.open(P, encoding='utf-8').read()
if TITLE in c:
    print('已存在，跳过')
else:
    anchor = '## 硬件事实（已核对权威资料，勿凭记忆）'
    if anchor in c:
        c = c.replace(anchor, ENTRY + anchor, 1)
        io.open(P, 'w', encoding='utf-8', newline='\n').write(c)
        print('OK README 已加该节')
    else:
        print('!! 锚点未匹配；现有二级标题：')
        for line in c.split('\n'):
            if line.startswith('## '):
                print('   ', line)
