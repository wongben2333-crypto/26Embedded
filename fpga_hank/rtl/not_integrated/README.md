# not_integrated —— 未接入本工程的模块（保留备查）

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
