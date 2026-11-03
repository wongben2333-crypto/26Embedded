# -*- coding: utf-8 -*-
"""quarantine_dead_code.py —— 把「未接入」的模块移出构建范围，并留下说明

★ 为什么做（评委要读 RTL，死代码是审查负担）：
  实测发现两个模块【无人例化】：
    · rtl/io/touch_pad.v       —— 电容触摸检测。从未接入顶层；其仿真也未通过。
    · rtl/synth/sine_rom.v     —— 单张正弦表。tone_bank 改用 wave_rom（多音色）
                                  之后它就没人用了。
  两者都被 build.tcl 收集（它 glob `rtl/{common,synth,audio,effects,io}`），
  于是会被编译但被综合器优化掉 —— 对资源没影响，但会让代码审查多出两个
  "这是什么？为什么在？"的疑问。

★ 做法：移到 rtl/not_integrated/（不在 build.tcl 的收集列表里），并放一份说明。
  好处：
    · 构建与交付的 RTL 只剩【真正在用】的模块，审查路径干净
    · 工作成果不丢（用户将来想接触摸还能用），但明确标注状态
    · 一键验收里那个长期存在的 tb_touch_pad FAIL 噪音一并消除
  同时把对应的 tb_touch_pad_a.v 移到 sim/tb/not_integrated/，
  并从 sim/run.do 的 testbench 列表里移除。
"""
from __future__ import annotations

import io
import os
import shutil
import sys

sys.stdout.reconfigure(encoding='utf-8')

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))

README = """# not_integrated —— 未接入本工程的模块（保留备查）

本目录下的模块**不会被 `tools/gowin/build.tcl` 收集**（它只收
`rtl/{common,synth,audio,effects,io}` 与 `rtl/` 根目录），因此**不参与构建**。
`sim/run.do` 也不再把它们的 testbench 列入一键运行清单。

这样做是为了让**交付的 RTL 只包含真正在用的模块** —— 评委审查时不会遇到
"这个文件是干什么的、为什么在"的疑问。

---

## rtl/not_integrated/touch_pad.v

**状态：未接入顶层，且仿真未通过。**

- 这是一个电容触摸检测模块（RC 充放电时间测量 + 基线自适应 + 迟滞 + 去抖）。
- 供电极的接口是显式的 `pad_oe` / `pad_out` / `pad_in`（早期的 `inout` 版本在
  三态强度模型下会死锁，已重构）。
- **未接入 `rtl/top.v`**，`constr/fpga_hank.cst` 里也没有它的引脚约束 ——
  因此它对主 bitstream **没有任何影响**。
- 仿真状态：`tb_touch_pad_a.v` 长期未通过。已定位到是**测试台侧的电极模型**问题
  （复位后头几次测量的建模不对），不是 DUT 逻辑本身，但**尚未修好**。
- **为什么还没修**：赛题基础要求①（≥2 个独立可控维度）已由两个板载按键
  （AB13/Y12）+ 一个 PMOD 自研变调键（Y22）满足，并且有 `tb_interaction.v`
  的 9 项功能验证；触摸是"锦上添花"的第 4 个维度，优先级低于其它工作。
- **将来要接入时需要做的**：① 修好电极模型、让 `tb_touch_pad_a` 通过；
  ② 在 `constr/fpga_hank.cst` 里给电极分配引脚（需外接铜箔/铝箔电极 + 1 MΩ 上拉）；
  ③ 在 `top.v` 里把 `touch` 信号并入 `gate` 或音色选择。

---

## rtl/not_integrated/sine_rom.v

**状态：已被 `wave_rom.v` 取代。**

- 这是单张 256 项正弦表（quarter-wave 折叠，16 bit）。
- `tone_bank.v` 改用 `wave_rom.v`（4 张表共用一份 ROM，支持多音色）之后，
  `sine_rom` 就**没有例化了**。
- 保留它只是因为"正弦表"这件事本身有价值可查（它是 `wave_rom` 的表 0 的
  独立实现，可用于交叉比对）。主通路用的是 `wave_rom`。

---

## 如果你要重新启用它们

1. 把文件移回原来的目录（`rtl/io/` 或 `rtl/synth/`）—— 移回后 `build.tcl`
   会自动收进去（它按目录 glob，不需要改脚本）。
2. 若要一并跑仿真，把对应 testbench 移回 `sim/tb/`，并加回 `sim/run.do`
   的 `ALL_TBS` 列表。
3. 记得同步更新 `tools/verify/run_acceptance.ps1` 的交付物清单（如果需要）。
"""


def main():
    rtl_ni = os.path.join(ROOT, 'rtl', 'not_integrated')
    tb_ni = os.path.join(ROOT, 'sim', 'tb', 'not_integrated')
    os.makedirs(rtl_ni, exist_ok=True)
    os.makedirs(tb_ni, exist_ok=True)

    moves = [
        (os.path.join(ROOT, 'rtl', 'io', 'touch_pad.v'),
         os.path.join(rtl_ni, 'touch_pad.v')),
        (os.path.join(ROOT, 'rtl', 'synth', 'sine_rom.v'),
         os.path.join(rtl_ni, 'sine_rom.v')),
        (os.path.join(ROOT, 'sim', 'tb', 'tb_touch_pad_a.v'),
         os.path.join(tb_ni, 'tb_touch_pad_a.v')),
    ]
    for src, dst in moves:
        if os.path.exists(src):
            shutil.move(src, dst)
            print('  移入 not_integrated: %s' % os.path.relpath(dst, ROOT))
        elif os.path.exists(dst):
            print('  已在 not_integrated: %s' % os.path.relpath(dst, ROOT))
        else:
            print('  [跳过] 不存在: %s' % os.path.relpath(src, ROOT))

    io.open(os.path.join(rtl_ni, 'README.md'), 'w',
            encoding='utf-8', newline='\n').write(README)
    print('  已写 rtl/not_integrated/README.md')

    # ---------------- 从 sim/run.do 的 ALL_TBS 移除 tb_touch_pad ----------------
    p = os.path.join(ROOT, 'sim', 'run.do')
    c = io.open(p, encoding='utf-8').read()
    old = 'set ALL_TBS {tb_pt8211_final tb_adsr tb_spectrum tb_interaction tb_touch_pad}'
    new = ('# 注意：tb_touch_pad 已移入 sim/tb/not_integrated/ —— touch_pad 未接入顶层，\n'
           '#       其仿真长期未通过，故不列入一键运行清单（详见 rtl/not_integrated/README.md）。\n'
           'set ALL_TBS {tb_pt8211_final tb_adsr tb_spectrum tb_interaction}')
    if old in c:
        c = c.replace(old, new, 1)
        io.open(p, 'w', encoding='utf-8', newline='\n').write(c)
        print('  sim/run.do 已移除 tb_touch_pad')
    else:
        print('  sim/run.do: ALL_TBS 锚点未匹配（可能已改）')

    # ---------------- 从 run.do 的编译 glob 里排除 not_integrated ----------------
    # run.do 用 `rtl/*/*.v`，会匹配到 rtl/not_integrated/*.v。
    # 保留编译它也无害（能编译过），但为一致性，明确排除更清晰。
    c = io.open(p, encoding='utf-8').read()
    oldg = 'foreach f [lsort [glob -nocomplain "$ROOT/rtl/*/*.v"]] { lappend srcs $f }'
    newg = ('# 排除 not_integrated（未接入的模块，不参与验收）\n'
            'foreach f [lsort [glob -nocomplain "$ROOT/rtl/*/*.v"]] {\n'
            '    if {[string match "*not_integrated*" $f]} { continue }\n'
            '    lappend srcs $f\n'
            '}')
    if oldg in c:
        c = c.replace(oldg, newg, 1)
        io.open(p, 'w', encoding='utf-8', newline='\n').write(c)
        print('  sim/run.do 已排除 rtl/not_integrated')
    else:
        print('  sim/run.do: 编译 glob 锚点未匹配（可能写法不同）')


if __name__ == '__main__':
    main()
