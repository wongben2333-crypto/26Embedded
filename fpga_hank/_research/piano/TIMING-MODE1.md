# MODE=1 时序违例：定位 / 判断 / 修复（piano-tone）

**版本指纹（本结论对应的源码）**
| 文件 | sha256(前16) |
|---|---|
| `rtl/synth/piano_engine.v` | `B5089DD27EAC97DA` |
| `rtl/synth/piano_rom.v` | `355F530F13CF29C6` |
| `sim/tb/tb_piano_engine.v` | `DBBAA77784BB757C` |
| `tools/gen/gen_piano_rom.py` | `0231BF1D477AFD30` |

> ⚠️ **MODE=1 的 P&R 报告在磁盘上不存在**：`fpga_hank/eda_proj/fpga_hank/impl/pnr/` 里
> 最新的 `fpga_hank.tr` 是 **2026-10-05 16:50:37** 那一次构建，资源是
> **Logic 16344 / BSRAM 60 / DSP 76 = MODE=0 的数字**，时序 **0 setup / 0 hold 违例**、Fmax 50.026 MHz。
> MODE=1（851 s 那次）的产物被随后的 MODE=0 构建**覆盖**了。
> 我全盘搜过 `%TEMP%`、桌面、`F:\`，4 小时内没有第二份 fpga_hank 时序报告。
> ⇒ 所以**"Top 20 违例路径"这一步我无法按你的要求给出**；下面是基于 MODE=0 报告的
> **同一条逻辑路径**做的定位（MODE=1 只是多了滑音分支、布局更挤）。

---

## 1. 定位：MODE=0 报告里的最差路径（slack 仅 **+0.010 ns** / 20 ns）

`fpga_hank.tr` §3.1.1 Setup Paths Table 第 1~18 名**全部**是同一类路径：

```
Path 1  Slack +0.010  Data Delay 19.748 ns  Logic Level 15
  From: u_piano/g_voice[3].u_voice/env_env_RAMREG_0_G[125]_s0/Q     ← 某声部的【包络】寄存器
  To  : u_piano/g_voice[0].u_voice/ph_ph_RAMREG_0_G[95]_s0/CE       ← 另一声部【相位累加器】的时钟使能
```

逐段延迟（`Arrival Data Path Delay`）：

| 段 | 内容 | 耗时 |
|---|---|---|
| tC2Q | env 寄存器输出 | 0.34 ns |
| A | `piano_active_3_s14/s2/s` = `act_c` 的 OR 树（8 bit 顶字节归约） | ~2.9 ns |
| B | `n562_s8 → n653_s8/s7 → n1101_s21 → on_pulse_sel_1_s9 → n1100_s30/s15/s4/s0 → on_pulse_sel_0_s0` = **分配器 4 层串行优先级链 + on_pulse_sel** | ~10.4 ns |
| C | `on_pulse_sel_0_s0`(fanout 235) → `g_voice[0]/n10357_s0`(fanout 192) → `ph/CE` | ~6.6 ns |

`Arrival Data Path Delay` 里 **cell 占 27.8%、route 占 70.5%** ⇒ **路由/扇出主导**，不是纯逻辑深。

### 判断：哪些是"真危险"，哪些只是静态分析过严

| 路径 | 每多久结算一次 | 判定 |
|---|---|---|
| **`env → act_c → 分配器 → on_pulse_sel → ph/CE`** | **每次 note-on 一次**（人/串口最快也 ≥320 µs） | **真危险**：它决定"按键按下后能不能分配到声部"。虽然是罕见事件，但它**不是** sample_tick 门控的，Gowin 按单周期检查 ⇒ 必须修（而且它是 MODE=0 的 #1）。 |
| `f0_cur → 颤音乘法 → 6 路泛音增量重算 → inc_use → ph 加法器` | **每 512 拍一次**（sample_tick 门控） | **静态分析过严**：实际有 512 拍（10.24 µs）余量。但它是 MODE=1 独有的长组合链，会拉低 Fmax、挤占布局 ⇒ 仍然值得缩短（已做），只是不必"为其加流水级"。 |
| 滑音斜率 `delta × recip` | 装载期间 1 拍（且 12 拍后才用） | **静态过严**（12 拍余量），但 33×33 乘法本身太贵 ⇒ 已换成两次 17×16。 |
| 引擎混音 `vsum → 软膝限幅 → mix_out` | 每 512 拍一次（vld[2] 门控） | 静态过严；而且 MODE=0 已验证满足。 |
| 声部内流水 `env_q → prod 乘法 → prod`、`nz_q → ham_prod`、`vout`、`mix_out` | **每拍**（未门控） | 真单周期路径，但它们都是**短乘法/短加**，MODE=0 已满足（且未改动）。 |

**⚠️ 给 Lead 的一条建议（在你的 `constr/fpga_hank.sdc` 里，属你的范围）**：
本设计的音频通路寄存器**只在 `sample_tick`（每 512 拍）更新**，这些路径是**天然多周期**的。
若给它们加多周期约束，Gowin 就不会再按单周期报违例，也就不会逼着 RTL 做无意义的流水化：
```tcl
# 音频通路：寄存器只在 sample_tick 更新（512 clk 一拍）⇒ 多周期
# ⚠️ 只对【确实由 sample_tick 门控】的寄存器加，不能对所有 FF 一把梭
set_multicycle_path -setup 512 -to [get_cells {u_piano/g_voice[*].u_voice/ph_*_s0}]
set_multicycle_path -hold  511 -to [get_cells {u_piano/g_voice[*].u_voice/ph_*_s0}]
```
（我没有改 SDC —— 那是你的文件；且**加约束必须确保该路径真的 512 拍才用一次**，
`ph` 是 `if (sample_tick && ...)` 写的 ✓ 成立。）

---

## 2. 修了什么（全部**逐样本回归可证**）

### ① 分配器：串行 4×8 优先级链 → 并行掩码 + 树形优先级编码
- 原来用 `!alloc_hit` 把 4 层 × 8 声部串成 ~24 级链；现在三层候选掩码并行算，
  每层用 3 级树形"最低置位"编码器，最后 3 选 1 ⇒ 链深 ~6 级。
- **等价性证明**（先证明再改 RTL）：`_research/piano/check_allocator_equiv.py`
  - 穷举全部 256 个 8 bit 掩码 × 8 个 rr：`prio_lowest` / `prio_rot` 与串行扫描**全部一致**
  - 穷举 `(v_active, v_gate, rr)` = 2^24 组合 × 12 组音号匹配模式 = **6.3M 组合**：一致
  - 200 万随机组合（含滑音优先级）：一致
  - 结果存 `evidence/allocator_equiv.txt`
- **RTL 级复核**：`_research/piano/tb_alloc_check.v` 在仿真里把"老算法的参考模型"和 DUT 的
  `alloc_sel` **逐拍对照**（覆盖 T3 和弦 → T4 单音 → T6 八音）⇒ 0 不一致。

### ② 滑音斜率：33×33 一次大乘法 → 两次 17×16 小乘法
- 查表改为 **Q24 倒数** `r = round(2^24/N)`：因为 `N < 2^16`，`r` 天然只有 **16 bit**
  （精度 ≤0.15%），乘法从 66 bit 降到 33 bit。
  ⚠️ 中间版本曾用"Q32 再取高 16 bit"，那会让 t=64 的滑音变成 335 ms（错 31%）—— 自检断言拦住了。
- delta 拆 17 bit 低半 + 16 bit 高半，两拍各做一次乘法：`step = (hi·r)>>7 + (lo·r)>>24`。

### ③ 颤音：33×18 乘法 → 33×12 乘法
- `f0_mod = f0_cur × (1 + dev/65536)` 改写成 `f0_cur + ((f0_cur × dev) >> 16)`，
  只乘 12 bit 的 `dev`（±1905），并省掉一级 18 bit 加法。

### ④ 调制结果打一拍
- `inc_vib_r` 寄存后再进 `inc_use` mux：把"乘法 + 6 路移位加法"与"相位累加器"隔开。
- **表情全关时 mux 仍选原来的 `inc[j]` ⇒ 对回归零影响。**

### ⑤ 顺带修掉的两个自己引入的 bug（都被检查抓住）
- `low8()` 字面量位宽：写了 `2'd4`/`2'd5`/`2'd6`/`2'd7` —— **2 bit 装不下 4~7，溢出回绕成 0~3**，
  导致高 4 个声部全部分配错（实测 `low8(0x10)=0`、`low8(0x80)=3`）。改成 `3'dN`。
- 滑音 delta 时序：原来在 `L_IDLE` 那一拍用 `ld_f0/ld_sel` 算 delta，而这两个寄存器
  **正是在那一拍被写入**（非阻塞）⇒ 读到的是**上一个音符**的值 ⇒ delta=0 ⇒ step=0 ⇒
  滑音退化成"瞬间跳变"。改到 `L_CALC`（下一拍）算，读到的才是本次音符。

---

## 3. 改后验证（全部通过）

| 项 | 结果 |
|---|---|
| `vlog` | 0 error / **0 warning** |
| **逐样本回归**（6 个表情输入全 0，与"加表情之前"比） | **7/7 文件 sha256 完全相同** ✅ |
| 原 5 项 FFT 判据（音高/泛音/和弦/力度/衰减） | 全 PASS |
| 颤音（边带 + 外差解调） | 全 PASS（边带 −4.2/−15.9/−32.0 dB vs 贝塞尔理论 −4.8/−16.5/−32.0） |
| 滑音 | R²=1.0000、t=0 截距 **440.0 Hz**、斜率 **1.717 Hz/ms**（设计 1.719）、10%→90% **207.1 ms**（理论 205） |
| 延音踏板 | PASS |
| 相位扫描回归（TICKDIV=512，64 相位） | **64/64** |
| flow-verifier 自己的 TB + analyze_piano.py（补 6 个端口接 0） | A5/A4 = **2.000122**、C4/A4 = **0.594596** |

---

## 4. 诚实说明

1. **我没有 MODE=1 的时序报告**，所以"修完 MODE=1 违例是否归零"**我无法验证**（不跑 gw_sh）。
   请重建一次 MODE=1 并把 `*.tr` **保留下来**（别被下一次 MODE=0 构建覆盖）。
2. MODE=1 的违例**未必全部来自我**：资源对比里 **BSRAM 60→122（+62 块）**、**DSP 76→117.5（+41.5）**
   这两项跟我无关（我的表情逻辑不用 BSRAM，DSP 增量约 +20）—— 说明 `audio_fx` 在 MODE=1 时才被
   真正综合出来（MODE=0 把它的参数常量折叠了）。**它的时序也要一起看。**
3. 我给的修复是"把我知道的最长组合路径缩短"，属于**必要的必要条件，不是充分条件**；
   MODE=1 若仍有违例，请把报告给我，我按 Top 20 继续。
4. 资源数字（LUT/FF/DSP）仍是**分析值**，我没跑 gw_sh。
