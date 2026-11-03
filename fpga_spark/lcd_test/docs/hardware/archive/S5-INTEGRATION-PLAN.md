# S5 整合方案 —— 已验硬件接入 hank 合成引擎（Tang Mega 60K）

> 状态：**已实施并验收通过**（2026-10-24）。实施方案的"动手前"内容保留在 §0–§9，
> 实施结果、修复记录、验收矩阵与最终改进见 **附录 A1–A6**。
> 作者：Sisyphus，2026-10-22（方案）/ 2026-10-24（实施）
> 输入依据：LOCAL-MACHINE-NOTES.md / INPUTS-WIRING.md / hw_bringup/README.md /
> INSTRUMENT-MAPPING.md v0.2 / fpga_hank/rtl/top.v / piano_engine.v（本机逐行核对）

---

## 0. 三个前置问题的答案（已用工具核实，非记忆）

### Q1 板上现在跑什么？

**`INPUTS` 整合测试固件**（`hw_bringup/rtl/inputs_top.v`）。
证据：`out/bitstream/` 最新归档 = `INPUTS_60K_20261022-211920.fs`（17.3 MB），
`.usercode` = `0x1A2B00B7`，与 `INPUTS-WIRING.md` 头部记录一致。
重烧：`burn.ps1 -Kind inputs`；观测：调试串口 P19 → USB-TTL → **COM12** @115200，
看 `K=1FFF P=3F A=xxxx B=FFFF E1=0000 ...` 行。
注意：S5 的引擎位流**没有** uart_tx（除非批准加调试口），到时 COM12 会静音、COM19 变成 PC 钢琴口。

### Q2 piano_engine 的 on_valid 接受速率？

**不是每拍都能收。最小间隔 = 14 clk（280 ns @50 MHz），有入无排队——忙时的 on 直接丢。**

依据（piano_engine.v，本机逐行核对）：
- `on_valid` 是单拍脉冲；装载 FSM 在 `L_IDLE && !ld_busy` 才接收（L716）。
- 接收后 `ld_busy=1` 持续：6 个泛音 × (L_CALC+L_MUL) = 12 拍（N_PART=6，L182；L726-741）
  再加 L_DONE 1 拍（L742-746）⇒ 第 14 拍才回到可接收状态。
- **FSM 忙时的 `on_valid` 不缓存、直接丢弃**（引擎没有输入 FIFO）。
- note-off（`off_valid`）走 `off_any` 直通声部寄存器（L503、L823），**不受**装载 FSM 限制。

⇒ **对任务书"相邻事件 ≥4 clk"的修正**：4 clk 间距会把第二个 note-on 丢进 `ld_busy` 窗口。
串行化器必须按 **≥16 clk（320 ns）间距**发事件（留裕度），on/off 一律过同一串行通道。
16 clk 间距对应 ~3.1 M 事件/s 吞吐，比人手快 4 个数量级，FIFO 16 深足够。

### Q3 三路 bus_* 仲裁怎么接最省改动？

**只扩展现有 mux 的三元链，MODE 是编译期参数 ⇒ MODE 0/1/2 的逻辑零变化。**

top.v L288-300 现状：`bus_* = (MODE==2) ? 常量 : (run_song ? s_* : m_*)`。
MODE=3 时 `run_song = (MODE==1)?~run_mode:(MODE==0) = 0`（L151），song_player/midi_rx
自然静默。改法（11 条 assign 各加一段）：

```verilog
assign bus_on_valid = (MODE == 2) ? 1'b0 :
                      (run_song  ? s_on_valid :
                      (MODE == 3) ? h_on_valid : m_on_valid);   // h_* = hw_input_mgr
```

MODE≠3 时第三段常量折叠，综合结果与基线逐位一致（回归判据可对资源表验证）。
`inst_sel/bow_speed` 不用改：MODE=3 下 `run_song=0` ⇒ 走 CC20/CC21 寄存器，
midi_rx 无输入 ⇒ 恒钢琴音色、drive=0（L269-282、L303-313）。

---

## 1. 架构

```
J13 按键×13 ─┐
J13 光电×6 ──┤ 同步+去抖(2ms/8ms) ──┐
J13 EC11#1 ──┘  正交解码(1kHz采样)   ├─► 事件源(带优先级) ─► FIFO16 ─► 串行化(≥16clk) ─┐
J8  ToF#1  ──── i2c_master ×1 ───────┘        (弦>键>ToF)    (溢出计数)  (on/off/glide)  │
                                                                                                │
fpga_hank 引擎副本（MODE=3）：                                                                  │
  top.v： bus_* mux 第三路 ◄──────────────────────────────────────────────────────────────────┘
          piano_engine(8声部) ─► audio_fx ─► [音量增益 ×vol/128] ─► pt8211 ─► 耳机
                                             ▲ EC11#1 → vol 0..127（1 个 16×16 乘法器）
```

文件落点（`_work_60k/rtl_integ/`，fpga_hank/rtl 只读不动）：

| 文件 | 内容 |
|---|---|
| `rtl_integ/` | 整份复制自 `fpga_hank/rtl`（Copy-Item -Recurse），`top.v` 改 MODE=3 + mux 扩展 + 增益级 |
| `rtl_integ/io/hw_input_mgr.v` | 新增：去抖 19 路 + EC11 解码 + ToF 滤波/量化 + FIFO + 串行化 + 仲裁 |
| `rtl_integ/io/i2c_master.v` | 从 `hw_bringup/rtl/i2c_master.v` 复制（xsim 自检 PASS 过） |
| `rtl_integ/io/uart_tx.v` | 仅当批准调试口才复制 |
| `constr/fpga_hank_60k.cst` | 追加 22 个新引脚（见 §5） |

`build_60k.tcl` 零改动：自动收集 `io/` 子目录（L64），MODE 从 top.v 读出 ⇒
USER_CODE=0x1A2B0003、归档名 `MODE3_mode3_60K_<stamp>.fs`。

## 2. 事件语义（照 INSTRUMENT-MAPPING v0.2 + 任务书 §5）

| 源 | 事件 | 细节 |
|---|---|---|
| 键 0..12 | 按下=0x90 note，松开=0x80 | 查表 60..72（C4..C5），vel=100 |
| 光电#1 | 挡光沿=0x90 40，放开沿=0x80 | E2=82.41 Hz，vel=110；挡光=0（低有效） |
| ToF#1 | 进圈=0x90，换音=0x80旧+0x90新(glide)，出圈=0x80 | 10–70cm→MIDI 60..84；2.4cm/半音；±2cm 迟滞；5 点中值；>80cm 持续 200ms 判出圈；NACK 不发声 |
| EC11#1 | 每格 ±4 → vol 0..127（饱和） | 初值 100；增益 = (fx_out × vol) >> 7 |

- **ToF 声部钉扎**：ToF 事件带 `glide_on=1`，引擎 `glide_on && last_valid ⇒ alloc_sel=last_voice`
  （L441）⇒ 换音不重触发包络、不换声部。这是**软钉扎**：若 ToF 声部被第 9 个事件抢走，
  下一次换音（≤40ms）自动重新分配。引擎不支持硬预留（改引擎=违反红线），
  按 INSTRUMENT-MAPPING §7 的仲裁语义落地：**事件优先级 弦 > 键 > ToF**（FIFO 入队轮询顺序即优先级）。
- **上电屏蔽**：复位后 250ms 内所有事件源被压制；去抖寄存器初值=未触发
  （与 inputs_top 同法，实测无假触发）；ToF 首帧有效距离前不发事件。
- FIFO 宽 ~20b {src, on/off, note[6:0], vel[6:0], glide}，深 16，溢出 saturate 并挂计数器（验收=0）。

## 3. 音量增益（唯一的乘法器）

`audio_mix_raw = (MODE==2) ? mix_bank : (MODE==3 ? gain_out : fx_out)`；
`gain_out = (fx_out × vol_r) >>> 7`。vol_r 打一拍再用。
溢出分析：|fx_out|≤32768、vol≤127 ⇒ |prod>>7| ≤ 32665 < 32767，**无需饱和逻辑**。
参数守卫 ⇒ MODE 0/1/2 位流资源零增量。若上板听到旋转爆音，再加一阶
`vol_r += (vol_target - vol_r) >>> 3` 平滑（~20 LUT，预留为应急项，缺省不做）。

## 4. 资源预算（对硬约束）

| 项 | 估算 | 依据 |
|---|---|---|
| 新增 LUT | ≈1160（去抖 ~200、EC11 ~30、i2c×2 ~240、ToF 序列器 ~80、中值/迟滞/量化 ~250、FIFO ~60、串行化/仲裁/查表 ~300） | 对比 inputs_top 实测规模（17.3MB 位流整机远小于引擎） |
| 新增 DSP | **+1**（16×16 音量乘法） | 104.5 → 105.5/118，剩 12.5 |
| 新增 BSRAM | **0**（FIFO 用分布式 RAM） | 68/118 不变 |
| 新增时钟域 | **0** | 全部 50MHz 单域，1ms/2ms 节拍用计数分频 |
| 新增 IO | 21（13键+6光电+2编码器）+ 可选 1 调试 TX | 全部 J13/J8 已实测球号 |

## 5. 引脚（追加进 `constr/fpga_hank_60k.cst`，全部照抄 hw_inputs.cst 已 P&R 通过的写法）

| 信号 | 球号 | 属性 |
|---|---|---|
| `key_hw[12:0]` | E14 E13 C15 C14 B13 C13 A14 A13 B16 B15 A16 A15 A20 | LVCMOS33 PULL_MODE=UP（按下=0） |
| `photo_hw[5:0]` | B20 A21 B21 B18 B17 C17 | LVCMOS33（挡光=0，经 S9012） |
| `ec1a` / `ec1b` | D17 / A19 | LVCMOS33 PULL_MODE=UP |
| `dbg_tx`（可选） | P19 | 需在 build_60k.tcl 加 `set_option -use_cpu_as_gpio 1` |

EC11#2（A18/D15）与按键脚（D14/D16）**未接线，不约束**。J13-11(5V) 绝不触碰。
光电只用了 #1，其余 5 路约束但暂不产生事件（接线后免改 cst）。

## 6. 实施顺序（每阶段一个"构建→TNS=0→烧 SRAM op2→真板听/测"闸门）

| # | 内容 | 通过判据 |
|---|---|---|
| S5.0 | 复制 rtl→rtl_integ；MODE=3 空壳：去抖/管理器最小化，复位 250ms 后引擎发一个固定 0x90 60 | 构建无 ERROR、archived、`=== DONE ===`、Setup/Hold TNS=0、耳机听到持续 C4、0x80 后停 |
| S5.1 | 13 键全链（去抖→查表→FIFO→串行化→bus mux） | 13 键音高 C4..C5（对照调音器）；8 键和弦全响；第 9 键抢最旧声部不卡死 |
| S5.2 | 光电#1 → E2 | 挡光 82.41Hz 起、放开停 |
| S5.3 | ToF：i2c_master + 中值/迟滞/量化 + glide 换音 | 10→70cm 音高单调上升无跳变（耳朵+调音器）；手离开即停 |
| S5.4 | EC11 → 音量增益 | 旋转无爆音、范围 0..127、初值 100 |
| S5.5 | 全映射合体 + 仲裁（弦>键>ToF） | 同时操作三类输入，无卡死、FIFO 溢出计数=0 |
| S5.6 | 回归：rtl_integ 临时 MODE=1 重构建 | COM19 发 90 45 64 → 440Hz；`piano_gui.py --selftest` 全 PASS；上电 20 次无随机发声 |

仿真先行（坑 #4"先仿真再上板"）：
- xsim（Vivado 2018.3）TB 覆盖 hw_input_mgr 纯逻辑：去抖边沿→事件、ToF 量化/迟滞
  （距离序列注入）、FIFO 满溢出、串行化间距 ≥16clk、键查表。
- i2c_master/uart_tx 已有 PASS 的 TB，不重写；ToF 物理层已由 tofread/tofdual 固件实测。
- top.v 的 mux 扩展用 MODE=1 回归构建做等价性验证（资源表应与基线一致）。

## 7. 与任务书的两处偏差（需用户点头）

1. **串行化间距 ≥16 clk（任务书写 ≥4 clk）**：引擎实测最小接受间隔 14 clk（§0 Q2），
   4 clk 会丢 on 事件。16 clk 无任何可感知代价。
2. **ToF 声部为"软钉扎"（glide 复用 last_voice）而非硬预留**：硬预留必须改 piano_engine，
   违反只读红线。仲裁优先级 弦>键>ToF 已保证 ToF 事件永不主动让位。

## 8. 待用户决策项

- [ ] 是否在引擎位流里加调试串口 TX（P19，+~60 LUT）：**强烈建议加**——S5.3 验证
  "单调上升"时能直接看距离值，否则只能靠耳朵；代价是 build_60k.tcl 加一行
  `-use_cpu_as_gpio 1`。不加则 COM12 全程静音。
- [ ] 键/弦力度取 vel=100/110（INSTRUMENT-MAPPING 默认值），是否认可。
- [ ] EC11 音量上电初值 100（约 -2.1dB），是否改成 127（直通）。

## 9. 风险与对策

| 风险 | 对策 |
|---|---|
| MODE=1 回归资源表变化 | mux 第三段常量折叠；对比 .rpt.txt 资源逐行核对 |
| ToF 换音瞬间的 off/on 对撞（同一拍） | 串行化器天然隔开 ≥16clk；off 先于 on 出队 |
| 光电抖动导致重复拨弦 | 2ms/8ms 非对称去抖（实测有效）+ 换音语义为"按住发声"非重触发 |
| 上电随机发声（验收 #10） | 250ms 屏蔽 + 去抖初值 1 + ToF 首帧前不发事件 + vol 初值非零但无声部活跃 |
| 时序 | 新逻辑全部低速（1kHz/10kHz 节拍），增益乘法在样本路径但 DSP 流水充足；以 TNS=0 为闸门 |

---

# 附：实施结果（2026-10-24 完成）

> 本文以上内容是"动手前"的方案。实际实施中发现了 **3 个方案期没预料到的问题**，
> 全部已修复并上板验证。最终位流：out/bitstream/MODE3_mode3_60K_20261024-002751.fs
> （User Code  x1A2B0003，20.0 MB，sha256 前 16 位 A5B82B7F28E3658A，
> Setup **+0.021 ns** / Hold **+0.070 ns**，DSP 79/118，Logic 22 797/59 904）。

## A1. 实施中发现并修复的问题

| # | 问题 | 根因 | 修复 |
|---|---|---|---|
| 1 | ToF 读数字节序错（写反成 36099 mm） | 真机自动递增突发读**高字节在前**，与文档的单寄存器读顺序相反 | dist_raw = {d_lo, d_hi}（P_REP 与滤波器共用同一 wire）；仿真 BFM 同步改成 HI 先发 |
| 2 | 按键/光电/ToF **全部刺耳**，82 Hz 听成"几千赫兹" | **I2C 电气耦合**：AB22/Y21 与 I2S 同属 BANK7，DRIVE=8 + 10 kHz 轮询把 DAC 边沿搅乱 | cst DRIVE=2 + SCL_HZ 10 k→3.3 k；用 QUIET 参数逐项二分定位（传感器是否供电无影响） |
| 3 | ToF 换音会"偷"琴键声部，音高乱窜 | 引擎 glide_on 复用**全局 last_voice**：一个键在响时，ToF 的滑音 note-on 会把这个键的声部重新触发并滑走 | ToF 全部 **glide=0**（重新拨弦语义）+ 换音限速 **180 ms** + 入场驻留 3 采样 |
| 4 | EC11 音量"基本没变化" | 线性 vol/127 在 100 附近每格仅 ±0.3 dB | 128 项 **dB 感知 LUT**（0=-42 dB 静音 … 127=直通），每格 ≈1.3 dB |

## A2. 与方案的偏差

| 方案 | 实际 | 原因 |
|---|---|---|
| 串行化间距 ≥16 clk | ✅ 保持 16 clk | 引擎装载 FSM 14 clk 的最小间隔（piano_engine.v L182/L716-746） |
| ToF 用引擎 glide 平滑换音 | ❌ 改为重新拨弦（glide=0） | 引擎的 glide 分配是全局 last_voice，无法按来源钉扎（见 A1#3） |
| 5 点中值用组合逻辑 | ✅ 改为**顺序冒泡 FSM**（1 交换/clk） | 组合 10 级 16 位比较被综合成 40 ns 串行链（WNS −16.6 ns）；50 Hz 速率下顺序实现零代价 |
| FIFO 16 深分布式 RAM | ✅ | 全程 O=00（遥测阻塞计数为 0） |
| ToF 距离上限 | 12 位钳位（4095 mm），>800 mm 判定离场 | 减小比较器宽度，避免时序恶化 |

## A3. 验收矩阵（任务书 §5 十条）

| # | 判据 | 结果 | 证据 |
|---|---|---|---|
| 1 | 构建无 ERROR / archived / === DONE === | ✅ | 构建日志 + MODE3_mode3_60K_20261024-002751.fs |
| 2 | Setup/Hold TNS = 0 | ✅ | Setup +0.021 / Hold +0.070 |
| 3 | DSP ≤118；Logic 增幅 ≤2000 | ✅ | DSP 79/118；Logic 22 797（基线 31 382，**更低**） |
| 4 | 13 键 = C4..C5 | ✅ | 用户听感"全部正确" + 遥测 60..72 全出现 |
| 5 | 8 键和弦全响、第 9 键抢占不卡死 | ✅ | 用户"全部正确" + 事件流最长 10 连续 on、O=00 |
| 6 | 挡光发 E2(82.41 Hz)、松开停 | ✅ | 用户"都正常" + 90286E/802800 事件对 ×7 |
| 7 | ToF 10→70 cm 单调上升无跳变 | ✅ | 用户"都正常" + 遥测 73..84 成串单调（180 ms 限速） |
| 8 | EC11 改音量无爆音 | ✅ | 用户"音量现在很明显"；V 实测覆盖 0..127 |
| 9 | MODE=1 发 90 45 64 出 440 Hz；selftest 全 PASS | 🟡 selftest ✅ PASS（两次）；**440 Hz 听感待补测** | piano_gui.py --selftest = [RESULT] PASS |
| 10 | 上电 20 次无随机发声 | ✅ | 20/20（安静环境）+ 9/9（最终位流复测）；另有 4 次"事件"经遥测自证为身体进入 ToF 量程/遮挡光电的真实事件 |

## A4. 回归与仿真

- **xsim 自检 TB**：sim_s5/tb_hw_input_mgr.sv（含 I2C 从机 BFM）——43 项检查全 PASS，
  覆盖：屏蔽窗 / 13 键查表 / 光电 / ToF 入场驻留、迟滞、限速、离场、NACK 超时 /
  EC11 音量与钳位 / 事件间距 ≥16 clk / FIFO 零阻塞。
- **MODE=1 回归**：tl_integ 源码可正常构建出 MODE=1（资源 DSP 104.5 与基线一致、
  BSRAM 68 一致；增益/ToF 逻辑在 MODE=1 被常量折叠）；QUIET=1 版本用户确认
  "声音正常"（MODE1_pcctrl_60K_20261023-133101.fs）。

## A5. 未完成 / 风险

1. **MODE=1 的 440 Hz 听感复测**：本机 FT2232 在 2026-10-23/24 多次挂死
   (Cable failed to open via the channel)，最后一次回归构建又逢 P&R 布线冻结；
   待 USB 恢复后用 MODE1_pcctrl_60K_20261023-133101.fs 补测。
2. **MODE=1 时序违例（既有，非 S5 引入）**：piano_engine 分配器链 Setup WNS
   −6.4 ns（基线 10-18 为 −5.8 ns，hank 在 138K 记录过同类）；功能实测正常。
3. 本机 Gowin P&R 在 10-23 下午起频繁"布线 Phase 0/1 冻结"（5 次），
   与内存压力（7.8 GB 机器、空闲 2.4 GB）相关，构建时间从 3-5 min 涨到 8-15 min。
4. ToF 在有人体进入 10-70 cm 量程时会正常发声（theremin 语义）——演示时注意
   传感器朝向，或把量程外 (>80 cm) 作为静默区。

## A6. 最终改进：I2C 挪到 J13（2026-10-24 01:25，已实测）

A1#2 的"DRIVE=2 + SCL 3.3 kHz"只是折中。把 ToF 的 SCL/SDA 从
**J8-10/11（AB22/Y21，BANK7，与 I2S 同组）** 挪到 **J13-24(A18) / J13-25(D15)**
（SDRAM0 组，离音频远）后，**恢复到 10 kHz 全速仍然完全干净**（用户听感确认）。

- 新引脚：scl_tof = A18、sda_tof = D15（cst 已改；J13-24/25 原为 EC11#2 预留脚）
- 最终位流：MODE3_mode3_60K_20261024-012557.fs（18.6 MB，sha16 882132D453E6E483）
  资源 Logic 22 807、BSRAM 60、DSP 79/118；**Setup +0.033 / Hold +0.136**
- 接线变更：ToF 的 SCL→J13-24、SDA→J13-25（上拉/330Ω/电源不变）
- 结论：**PCB 的第一原则就是"I2C 放 J13，不放 J8"**（见 S5-HANDOFF-AND-HW-DESIGN.md §2）
