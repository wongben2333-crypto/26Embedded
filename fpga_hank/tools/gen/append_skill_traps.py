# -*- coding: utf-8 -*-
"""append_skill_traps.py —— 把 5 条新教训补进 `.dsh/skills/fpga-verify/references/traps.md`

为什么必须补：objective (2) 要求"安装四类能力，每项附 README 与兼容性说明"。
自建 skill 是我们的核心交付物之一，而这 5 条是最近几轮**真金白银踩出来**的教训，
不补进去，skill 就不是"当前的"，下次复用还会再踩一遍。

同时清掉 `fpga-verify/scripts/__pycache__/`（编译缓存不应进交付物）。
"""
from __future__ import annotations

import io
import os
import shutil
import sys

sys.stdout.reconfigure(encoding='utf-8')

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..', '..'))   # 竞赛目录根
TRAPS = os.path.join(ROOT, '.dsh', 'skills', 'fpga-verify', 'references', 'traps.md')

SECTION = r'''

---

## §9 ★★ 五条"看起来对、实际错"的教训（2026-10-03 集中踩到）

本节五条都是**同一类病**：**证据/工具本身在骗你**。
共同点 —— **它们都不报错、不打日志、不失败；只是让你相信一个错结论。**

### §9.1 ⚠️ 位流的 SHA256 **不能**当修订标识（P&R 非确定性）

**现象**：同一份 RTL、连续构建两次，`.fs` 的 SHA256 **不同**：
```
构建 A  34840489 B  Logic 5920  FF 1699  DSP 58  违例 0/0  1DD9C8D7…
构建 B  34840489 B  Logic 5920  FF 1699  DSP 58  违例 0/0  9B0729DB…
```
**根因**：高云的**时序驱动 P&R 是非确定性的**（布局/布线在不同运行间存在合法差异）。

**正确做法**：
1. **不能用 `.fs` 哈希判断"两个位流是不是同一版设计"** —— 哈希不同**不代表**设计不同；
2. **判断修订要哈希【RTL 源码 + 约束】**，不是位流；
3. **"重建后哈希不一致"不是构建失败** —— 判据是**大小 + 资源 + 时序违例**三者一致。

**为什么危险**：不知道这条，会把"两次哈希不同"误判成"构建坏了"或"代码被人改了"，
去查一个**根本不存在**的问题。

### §9.2 ⚠️ 构建必须绑**修订号守卫**（另一面：哈希什么才是关键）

**现象**：7 级位流**每一级单独都 PASS、`.rpt.txt` 0 ERROR、日志毫无异常**，
但它们是 **"混合修订"**——构建窗口（01:39:43–01:43:45）中间有人改了 3 个 `.v`（01:41:26）。
⇒ 前 5 级用旧版、后 2 级用新版，**整套不可交付**，而**日志完全看不出来**。

**正确做法**（`build_smoke.ps1` 已实现）：
```
构建前  → 对 rtl/**/*.v + constr/*.cst|*.sdc 拍 SHA256 快照并打印
构建后  → 再拍一次，逐文件比对 MODIFIED / ADDED / DELETED
有任何变化 ⇒ 红字宣告"这批位流是混合修订，不可交付" + exit 6
全一致     ⇒ exit 0，并打印最终修订号表（可直接抄进报告）
```

**要点**：**哈希源码，不是哈希产物**（§9.1）。把"人记得绑修订号"变成**机制强制**。

### §9.3 ⚠️ 判据脚本自己也会错：**here-string 造成的"假 PASS"**

**现象**：一个 PowerShell 验收脚本里，变调那一段**明明报了 PASS**，
实际上那段 Python 代码**根本没执行**——PowerShell 把它当命令去跑，报了
`is not recognized as the name of a cmdlet`，**而脚本继续走到 PASS**。

**根因**：用 PowerShell **here-string 内嵌 Python 代码**时，
**here-string 的结束标记必须顶格**，一旦缩进就**不被识别为字符串**。

**正确做法**：
1. **不要在 PowerShell 里内嵌另一种语言的代码** ⇒ 写成**独立 `.py` 文件**再调用；
2. 同理：含**反引号 / 花括号 / 中文引号**的文本，**不要用 PowerShell here-string** 处理，
   直接写 `.py` 文件（本项目因此反复中招，最后定为纪律）；
3. **"PASS" 必须附证据**（退出码 + 关键数字），否则"报 PASS"本身不可信。

### §9.4 ⚠️ ModelSim：不 `log` 则 `-wlf` 产出的波形库是**空的**

**现象**：`.wlf` 文件**存在、有体积**，但里面**没有任何信号**。

**根因**：`vsim -wlf <file>` **只指定文件名，不会自动记录信号**。

**正确做法**：
- 要"全部信号"用 **`log -r /*`**（此条来自 GitHub
  [VUnit issue #1081](https://github.com/VUnit/vunit/issues/1081)）；
- **更好的做法是选择性 log**：本项目 ADSR 仿真里 `clk` 要翻转 **3500 万次**，
  `log -r /*` 会让 `.wlf` 变成几百 MB；只记图上要看的 5–9 个信号 ⇒ **49–311 KB**。
- ⚠️ 但**不要在 skill 里把"嵌套 `vsim` 不行""含空格路径会被 Tcl 拆参"当结论**——
  实测**这两条都被推翻**：嵌套 `vsim` 可行；**Tcl 变量替换不做词分割**。
  唯一真因就是"没 `log`"。（这是"根据结果倒推原因"的典型错误：失败那次恰好
  既没 `log`、又是嵌套结构，把功劳/罪责误记到了结构上。）

### §9.5 ⚠️ 从**位级 VCD** 重组多 bit 总线，必须**按时间戳对齐**

**现象**：解析器报出 `level 最大 = 131071`（真值 65536）、步长出现 ±8/±16/±32
（真值恒为 +8）、衰减 **−2.62 ms**（真值 **+20.97 ms**）、变化次数 147455（真值 73729）。

**根因**：VCD 把 17 位的 `level` 导成 **17 个独立单 bit 信号**；
解析器**每见一个 bit 变化就重组一次** ⇒ 同一时刻的多 bit 变化被拆成**中间态**，
于是**自己制造出了假信号**。

**正确做法**：
- **同一 `#t` 时间戳内的所有 bit 变化攒齐后，只重组一次**；
- 这也解释了另外两条"自己骗自己"：把"上升途中穿过 49152"当成"衰减结束"（得到负时长）；
- **判据要用"量出来的数"和"算出来的理论值"对撞**，不要用图"看起来对不对"判断。

---

## §10 这五条的共同教训

| # | 骗你的是什么 | 你怎么发现 |
|---|---|---|
| 9.1 | 位流哈希 | 重建两次比对，发现哈希不同但三项指标一致 |
| 9.2 | 构建日志 | 修订号守卫比对源码哈希 |
| 9.3 | 脚本自己的 PASS | 追问"这个 PASS 有什么证据" |
| 9.4 | 波形库文件存在 | 打开看里面有没有信号 |
| 9.5 | 解析器输出 | 与理论值/预期量级对撞 |

**一句话**：**"看起来成功"和"看起来失败"都不可信；
可信的是"把期望值算出来，和实测值逐项对撞"。**
'''

c = io.open(TRAPS, encoding='utf-8').read()
if '§9 ★★ 五条' in c:
    print('traps.md 已含 §9，跳过')
else:
    io.open(TRAPS, 'w', encoding='utf-8', newline='\n').write(c.rstrip() + '\n' + SECTION)
    print('OK 已补 §9 + §10（%d -> %d 字符）' % (len(c), len(c) + len(SECTION)))

# 清理 __pycache__
for dirpath, dirnames, filenames in os.walk(os.path.join(ROOT, '.dsh', 'skills')):
    for d in list(dirnames):
        if d == '__pycache__':
            p = os.path.join(dirpath, d)
            shutil.rmtree(p, ignore_errors=True)
            print('已删除 %s' % os.path.relpath(p, ROOT))
            dirnames.remove(d)
