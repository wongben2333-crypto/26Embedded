> **📦 本目录是一个"团队资料包"** —— 除本工程外，还带了一份给队友的
> [`team-resources/`](team-resources/README.md)：3 个实测过的 Skill
> （`gowin-flow` 高云命令行构建规范 / `verilog-review` RTL 审查清单 /
> `fpga-verify` 验证取证门禁，含 8 个脚本与形式验证模板），
> 以及一份 [`traps/关键坑位速查.md`](team-resources/traps/关键坑位速查.md)。
>
> **如果你是队友、第一次打开这个目录：先读 `team-resources/关键坑位速查.md`**，
> 它能省掉几个小时（Gowin 参数大小写、`.tcl` 的 BOM、`.fs` 大小没有鉴别力、
> ModelSim `-novopt` 已废弃、PowerShell 5.1 + AllSigned + UTF-8 BOM 三重坑……）。
>
> ⛔ `team-resources/` 是**只读参考资料**；`rtl/`/`constr/`/`sim/`/`tools/`/`docs/` 才是工程本体。
> ⚠️ 目录里**不含** `eda_proj/`、`_tools/venv/`、`out/` —— 那些是可丢弃的构建/虚拟环境产物，
> 不要提交进仓库（见 `team-resources/skills/fpga-verify/references/traps.md` §7 的"工程不可移植"结论）。

---

# fpga_hank

**2026 FPGA 创新设计赛道·高云杯·选题二：基于 FPGA 的实时多音色合成电子乐器引擎**

板卡：Sipeed Tang Mega 138K Dock ｜ FPGA：`GW5AST-LV138PG484AC1/I0`（GW5AST-138C）

---

## 当前状态

> ⚠️ **本表以实际 testbench 运行结果为准，不是计划。** 更新于 2026-10-02 23:5x。

| 模块 | 状态 | 实测证据 |
|---|---|---|
| 高云 Gowin 全链路构建 | ✅ **跑通** | bitstream 生成成功，9 引脚全部按 `.cst` 分配 |
| PT8211 I2S 发送器 | ✅ **PASS** | `tb_pt8211_final.v`：0 位错、BCK 恒 640 ns、fs = 48828.1 Hz |
| **32 复音 + 测试模式频谱取证** | ✅ **PASS** | `tb_spectrum.v`：**32/32 谱峰、0 杂散、电平离散度 0.77 dB**（96 kHz）|
| ADSR 包络 | ✅ **PASS** | `tb_adsr.v`：9/9（起音→衰减→保持→释放→声部复用） |
| 多音色波表 | ✅ **已接入通路** | `wave_rom.v` 4 种音色；综合后 BSRAM 2→1（证明 ROM 结构真的换了） |
| 电容触摸检测 | ❌ **FAIL** | `tb_touch_pad_a.v`：3 个错误。**未接入顶层、无引脚，不影响 bitstream** |
| **整机上板出声** | ⬜ **未做** | 从未在真板上运行过 |

详细数据见 [32复音-验证报告.md](docs/32复音-验证报告.md) 与 [PT8211-验证报告.md](docs/PT8211-验证报告.md)。

> ⚠️ **以上全部是仿真与综合层面的验证。** 赛题要求的"频谱数出 32 个谱峰"最终
> **必须在真实硬件上取证**（接声卡/示波器）。仿真数据是必要证据，不能替代上板。

---

## 数据通路（当前实现）

```
bench_gate ──gate[32]──► adsr ──level_rd──► tone_bank ──mix──► pt8211_tx ──► PT8211 DAC
     ▲                     ▲                   │
     │                     └── env_voice ◄──────┘
     └── 真实演奏模式下换成「电容触摸/光电/压力 → 按键扫描 → 声部分配器」
```

- **32 路 ×（独立相位累加器 + 独立频率字 + 独立包络）= 32 个完整振荡器**
  （赛题【振荡器统计规则】三要素缺一不可）
- 音色：`wave_rom` 4 张表共用一份 ROM，地址 = `{音色[1:0], 相位高 8 位}`
- 全 HDL、逐样本实时合成，**无任何预录 PCM / 音频样本 ROM**（赛题红线）

### 两种工作模式（赛题要求"测试模式"）

| 模式 | 开关 | gate | 音色 | 用途 |
|---|---|---|---|---|
| **测试模式** | `top.v` 的 `TEST_MODE = 1` | 32 路恒按住 | **锁定表 0（纯正弦）** | 频谱取证：32 路 → 32 个独立谱峰 |
| 演奏模式 | `TEST_MODE = 0` | 由交互逻辑驱动 | 可切换（每 ~2 s 自动轮换演示） | 真实演奏 |

⚠️ **测试模式必须用纯正弦表**：若用含谐波的表，每路会产生多个谱峰，
"32 路 → 32 个谱峰"的判据会被误判为杂散（实测过：门控调制的演奏波形只命中 6/32）。


---

## 目录结构

```
fpga_hank/
├── rtl/                     综合用 RTL（全 HDL，赛题红线要求）
│   ├── common/              公共模块
│   ├── synth/               合成引擎（振荡器、波表、ADSR）
│   ├── audio/               音频输出链路
│   │   └── pt8211_tx.v      ✅ PT8211 I2S 发送器（已仿真验证）
│   ├── effects/             效果器（混响/延迟/合唱）
│   └── io/                  交互检测（电容触摸/光电/力度）
├── constr/                  约束
│   ├── fpga_hank.cst        物理约束（引脚）
│   └── fpga_hank.sdc        时序约束
├── sim/
│   ├── run.do               ModelSim 运行脚本
│   └── tb/                  testbench
├── tools/gowin/             高云命令行构建工具
│   └── build.tcl            ✅ 全链路构建脚本（实测通过）
├── docs/                    设计文档与验证报告
├── plugin/                  DSH 插件（含逐个 README）
├── skills/                  Claude Code 项目级 skills 源文件
└── eda_proj/                Gowin 工程与构建产物（git 忽略）
```

---

## 快速开始

### 1. 构建 bitstream

```powershell
# 直接调 Tcl（推荐，不依赖工作目录）
& "F:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe" `
  "C:\Users\Danny\Desktop\FPGA competition\fpga_hank\tools\gowin\build.tcl"
```

产物：

| 文件 | 说明 |
|---|---|
| `eda_proj/fpga_hank/impl/pnr/fpga_hank.fs` | **bitstream**，用 Gowin Programmer 烧录 |
| `eda_proj/fpga_hank/impl/pnr/fpga_hank.rpt.txt` | PnR 报告（含资源占用、告警） |
| `eda_proj/fpga_hank/impl/pnr/fpga_hank.tr.html` | 时序报告 |
| `eda_proj/fpga_hank/impl/pnr/fpga_hank.pin.html` | 引脚分配报告 |

### 2. 跑仿真

```powershell
Set-Location "C:\Users\Danny\Desktop\FPGA competition\fpga_hank"
& "F:\Modelsim_10.7\win64\vsim.exe" -c -do sim\run.do
```

---

## ⚠️ 实测踩过的坑（务必先读，能省你几个小时）

### Gowin 工具链

1. **`-synthesis_tool` 只能写小写 `gowinsynthesis`**。`GowinSynthesis`/`GW_SH`/`Synplify`
   全部报 `unknown synthesis tool` 并**中断整个脚本**（不是警告）。
2. **`gw_sh.exe` 不会切到 .tcl 所在目录**，`[pwd]` 是调用者的 CWD。
   必须用 `[file dirname [info script]]` 定位工程根。
3. **`.tcl` 不能带 UTF-8 BOM**，否则第一条命令被解析成
   `invalid command name "??oreach"`。
4. **器件型号必须精确匹配**：part `GW5AST-LV138PG484AC1/I0`、封装 `PBG484A`、
   device version 按板上实际选 B/C。型号写错不会报错，但烧录后引脚行为不对。

### RTL / 仿真

5. **`32'd1 << FRAC_BITS` 在 Verilog 里，当 `FRAC_BITS ≥ 32` 时等于 0。**
   会让分数分频的小数补偿彻底失效（`frac_carry` 恒为真）。写分频器时务必注意位宽。
6. **不要为了"可读性"引入影子寄存器**，例如 `new_ph <= ph+1; ph <= new_ph;`。
   若后者每拍无条件执行而前者只在条件成立时更新，就构成串行延迟链，
   寄存器会每个周期只前进"半格"并最终彻底停滞。
7. **不要在同一个 `always` 里用两个并列 `if` 分支给同一寄存器赋值。**
   条件重叠时"最后一次赋值生效"，极易造成寄存器卡死。
8. **位序/半帧边界类错误"看波形完全正常"。** 唯一可靠的验证方式是按 BCK 上升沿
   逐位解码 DIN 再与期望样本比对。本项目 `sim/tb/tb_pt8211_final.v` 就是这么做的，
   它抓出了 5 个"波形正常"的错误实现。
9. **ModelSim 优化后读 DUT 内部寄存器可能得到与实际不符的值。** 调试时优先做纯黑盒
   验证（只看输出端口），否则会被误导。
10. **ModelSim 10.7 起 `-novopt` 已废弃**，加上会导致 `Error loading design`。
11. **不要用 PowerShell `Set-Content -Encoding UTF8` 修改带中文的 .v/.tcl 文件** ——
   它会加 BOM 并破坏中文编码，导致 `vlog` 报
    `unexpected non-printable character with the hex value '0xef'`。
    统一用无 BOM UTF-8（编辑器的 write 工具即可）。

---

## 硬件事实（已核对权威资料，勿凭记忆）

### 引脚

```
clk        V22      50 MHz 板载有源晶振
led[0..3]  T18 R18 R17 P16      板载 LED，低有效
           （V13 无灯珠；U21 是 CPU/SSPI 专用脚，布局器会拒绝）
HP_BCK     Y17      PT8211 I2S 位时钟
HP_WS      AB17     PT8211 I2S 字选（高=左，低=右）
HP_DIN     AA16     PT8211 I2S 数据
PA_EN      AB16     功放使能，低有效（必须拉低才出声）
```

TMDS/HDMI 差分对：`tmds_d_p_0[0]=J14,H14`、`[1]=J15,H15`、`[2]=K17,J17`、
`tmds_clk_p_0=G15,G16`，`IO_TYPE=LVCMOS33D`。

### 资源

138 240 LUT4 / 138 240 FF / 6120 Kb BSRAM（340 块）/ 298 个 18×18 乘法器 / 12 PLL

### 供电

12V DC，或 **USB3.0 + DEBUG-USB 双路 5V**。**单口 USB 供电会掉电重启。**

---

## 赛题要点提醒（详见仓库根 `AGENTS.md`）

- 评分公式：**同时活跃可闻独立振荡器总数 × 实际音频输出采样率**（唯一乘数项）
- 「一个振荡器」必须同时有 **独立相位累加器 + 频率调控 + 包络控制**
- 单波表查表**只算 1 个**振荡器
- 🚫 **严禁播放预录 PCM / 预置推流 / 整段录音**
- 交付必须有**测试模式**：输出 N 路不同频率 → 频谱能数出 N 个独立谱峰
- 作品提交截止 **2026-11-04 18:00**
