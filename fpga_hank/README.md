# fpga_hank —— 选题二「基于 FPGA 的实时多音色合成电子乐器引擎」

> **2026 第九届全国大学生嵌入式芯片与系统设计竞赛 · FPGA 创新设计赛道（高云半导体命题）**
> 板卡：Sipeed Tang Mega 138K Dock ｜ 器件：`GW5AST-138C` ｜ 音频：PT8211 I2S DAC

**这是 `fpga_hank` 工作区的完整成果包**，与 `fpga_ben`（算法模型）、`fpga_spark`（另一条技术路线）平级、互不干扰。

---

## 一、一句话结论

> **赛题基础三项 + 拓展① 全部达成，并逐项有实测证据；软件层已闭环，只差上板通电。**

| 赛题要求 | 状态 | 证据 |
|---|---|---|
| ① 多维交互 ≥2 个独立可控维度 | ✅ | `tb_interaction.v` **9 项全 PASS**（含"按住发声时换音色/变调不影响 gate"的**独立性证明**） |
| ② 纯硬件逐样本 + 延迟 ≤10 ms | ✅ | 仿真 **2.656 ms**（去抖 2.621 + 音频通路 34.8 µs） |
| ③ 复音≥4 + ADSR + **变调** + 混音 | ✅ | 复音 **32**；ADSR 10.49 / 2.62 / 62.91 ms；**变调误差 0.0144%** |
| **拓展① 复音 ≥32** | ✅ | **32/32 独立谱峰、0 杂散、离散度 0.77 dB**（两份证据带 SHA256） |
| 必备交付物：测试模式频谱取证 | ✅ | `docs/evidence/32谱峰-取证报告.md` |

**⚠️ 诚实边界**：以上**全部是仿真与综合层面的验证**。
**实际的物理烧录、真板发声、真板频谱取证都还没有做**（需要硬件在场）。
详见 [`docs/上电操作卡-正式交付.md`](docs/上电操作卡-正式交付.md) 第 6 节。

---

## 二、关键成果速查（我要找什么，在哪）

| 我要找… | 路径 |
|---|---|
| 📄 **提交用技术文档（Word）** | [`docs/技术文档.docx`](docs/技术文档.docx)（A4 / 14 表格 / 49.8 KB） |
| 🧪 **32 谱峰证据（赛题必备）** | [`docs/evidence/32谱峰-取证报告.md`](docs/evidence/32谱峰-取证报告.md) |
| 📘 **138K 板子保姆级教程** | [docs/138K开发板-保姆级上手指南.docx](docs/138K开发板-保姆级上手指南.docx) ← **从零开始，什么都不懂也能跟着做** |
| 🔌 **上电后怎么操作** | [`docs/上电操作卡-正式交付.md`](docs/上电操作卡-正式交付.md) ← **插上板子照这份做** |
| 🔊 **要烧的位流怎么来** | [`docs/预先构建的位流.md`](docs/预先构建的位流.md) |
| 💻 **RTL 源码** | `rtl/`（9 个 `.v`，其中 **6 个参与正式构建**） |
| 🎓 **四类能力 / 工具链 / 许可证** | [`docs/工程能力与工具链说明.md`](docs/工程能力与工具链说明.md) |
| 📚 **踩坑知识库（3 个 skill）** | [`skills/`](skills/) ← 见第四节 |
| ✅ **一条命令复核全部验证** | `tools/verify/run_acceptance.ps1` |
| 📊 **6 张 ModelSim 真窗口波形图** | [`docs/waveforms/real/`](docs/waveforms/real/) |
| 🩺 **分级排障（S0–S6）** | [`docs/上板验证指南.md`](docs/上板验证指南.md) |

---

## 三、怎么用

### 环境要求（本机实测版本）

| 项 | 版本 / 路径 |
|---|---|
| 高云 EDA | **V1.9.12.04**，`F:\Gowin\Gowin_V1.9.12.04_x64`（STD license） |
| 命令行 Tcl | `F:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe` |
| 仿真器 | **ModelSim SE-64 10.7**，`F:\Modelsim_10.7`（自带 `GW5AT` 预编译库） |
| 烧录 CLI | `F:\Gowin\...\Programmer\bin\programmer_cli.exe` |

### Python 依赖（仅验收脚本需要）

`run_acceptance.ps1` 里的判据脚本需要：**numpy / scipy / matplotlib / python-docx / lxml / Pillow**。

```powershell
python -m pip install numpy scipy matplotlib python-docx lxml Pillow
```

脚本会**优先用项目自带的 venv**（`_tools\venv`，本仓库未包含），找不到就**自动回退到系统 Python** 并打印上面这行安装指引 —— 所以缺包时它会告诉你，不会静默失败。

> 只想看结果、不想配环境？直接读 [`docs/evidence/32谱峰-取证报告.md`](docs/evidence/32谱峰-取证报告.md)（含 SHA256 指纹）。

### 构建 / 仿真 / 验收

```powershell
# ① 全链路构建（综合 → 布局布线 → 位流），约 85 秒
& "F:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe" tools\gowin\build.tcl
# 产物：eda_proj\fpga_hank\impl\pnr\fpga_hank.fs

# ② 一键验收：构建 + 全部仿真 + 全部判据 + 烧录链路 + 交付物清单
powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify\run_acceptance.ps1
#   -Quick 只复核证据不跑仿真；-SkipBuild 跳过构建
#   最近一次：PASS = 9，FAIL = 0

# ③ 烧录（第一次一律用 SRAM：易失、不改 Flash，反复试最安全）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\gowin\program.ps1 -Mode scan    # 确认板子被认出
powershell -NoProfile -ExecutionPolicy Bypass -File tools\gowin\program.ps1 -Mode sram    # 下载
```

### 两个工作模式（**上板前必读**）

`rtl/top.v` 有一个编译期参数 `TEST_MODE`：

| 模式 | `TEST_MODE` | 按键 | 音色 | 用途 |
|---|---|---|---|---|
| **演奏模式** | `0` | **真按键驱动发声** | 按键切换 4 种 | ★ 先烧这个听声音 |
| **测试模式** | `1`（当前默认） | 无效（32 路恒发声） | 锁定纯正弦 | ★ 频谱取证：数 32 根谱峰 |

**两种模式都已实测综合通过**（时序零违例、12 引脚全约束）：
`TEST_MODE=0` → Logic 5986 / FF 1745；`TEST_MODE=1` → Logic 5920 / FF 1699。

### 三个按键

| 按键 | 引脚 | 作用 |
|---|---|---|
| `key` | `AB13`（板载） | **按住 = 发声**（32 路齐发），松开进入释放段 |
| `key2` | `Y12`（板载） | 每按一下换音色（4 种循环） |
| `key_pitch` | `Y22`（**PMOD 排针，需自备按钮接 GND**） | 每按一下升 1 个半音 |

> ⚠️ `Y22` 是 PMOD 排针上的脚，**板上没有现成按钮**。接一个按钮：一端 `Y22`、一端 **GND**，
> 内部已上拉，按下 = 0，无需外接电阻。**这正是赛题要求的"自研交互形态"。**

---

## 四、skills（踩坑知识库）

`skills/` 下是**本项目自建的 3 个 skill**，记录了开发中真实踩过的坑：

| Skill | 内容 |
|---|---|
| `gowin-flow` | 高云命令行全链路规范 + 实测坑位（`-synthesis_tool` 只认小写、`.tcl` 不能带 BOM、顶层不能放 `rtl/` 根…） |
| `verilog-review` | RTL 审查清单 + "波形正常但实际错误"的案例复盘 |
| `fpga-verify` | 取证纪律 + 判据脚本 + `references/traps.md`（**§1–§10，22.7 KB**） |

### 怎么让 DSH 真正加载它们

⚠️ **DSH 的 skill 发现深度【只有一层】**：必须是 `<root>/<name>/SKILL.md`。

```powershell
# 在你自己的项目根下（或 C:\Users\<你>\.dsh\skills\）
New-Item -ItemType Directory -Force -Path .dsh\skills
Copy-Item skills\gowin-flow, skills\verilog-review, skills\fpga-verify .dsh\skills\ -Recurse
```

**放在 `fpga_hank/skills/` 下不会自动加载** —— 那是给你**阅读**和**装到正确位置**用的。

> 另一个实测坑：Claude 的 skill frontmatter 常见 `tools:` / `allowed-tools:` 字段，
> **DSH 不认**，而且会**静默丢弃整个 skill**。本项目的 skill 只用 `name` + `description`。

---

## 五、目录结构

```
fpga_hank/
├─ README.md                 ← 你在这里
├─ rtl/                      RTL 源码
│  ├─ top.v                  顶层（含 TEST_MODE 参数、按键同步去抖）
│  ├─ synth/                 tone_bank（32 路振荡器）/ adsr / wave_rom / bench_gate
│  ├─ audio/                 pt8211_tx（I2S 发送器）
│  ├─ smoke/                 smoke_top（分级冒烟用的另一套顶层）
│  └─ not_integrated/        未接入的模块 + README 说明（touch_pad / sine_rom）
├─ sim/                      仿真
│  ├─ tb/                    testbench（含 tb_interaction 交互验证）
│  ├─ run.do                 一键跑全部 testbench 并打印 PASS/FAIL
│  ├─ wave_*.do              「打开即完美」的波形视图脚本
│  └─ make_wlf.do            生成 .wlf 数据集（选择性 log）
├─ constr/                   引脚 .cst + 时序 .sdc
├─ tools/
│  ├─ gowin/                 build.tcl（构建）/ build_smoke.ps1 / program.ps1（烧录）
│  ├─ verify/                run_acceptance.ps1 / check_peaks.py / check_pitch_shift.py …
│  └─ gen/                   RTL 与文档生成器
├─ docs/                     ★ 全部文档
│  ├─ 技术文档.docx           提交用技术文档
│  ├─ 上电操作卡-正式交付.md    ★ 上板照这份做
│  ├─ 工程能力与工具链说明.md   四类能力 / 许可证 / 兼容性
│  ├─ 预先构建的位流.md
│  ├─ 上板验证指南.md          分级排障 S0–S6
│  ├─ evidence/              32 谱峰取证报告 + 三份样本数据（带 SHA256）
│  └─ waveforms/real/        6 张 ModelSim 真窗口截图
└─ skills/                   自建 skill（见第四节）
```

**未包含在本仓库的**（构建产物，需要时自行生成）：

| 项 | 生成方式 |
|---|---|
| `eda_proj/`（Gowin 工程，约 135 MB） | `gw_sh tools\gowin\build.tcl` |
| `out/bitstream/*.fs`（位流，各约 33 MB） | 同上；或改 `TEST_MODE` 后重跑 |
| `work/`（ModelSim 编译库） | 跑仿真自动生成 |

---

## 六、给评审的代码审查指引

赛题要求"RTL 代码要经得起评委对照审查（无音频样本 ROM、无 SD 卡读 WAV）"。逐条指路：

| 红线 | 怎么看 | 预期 |
|---|---|---|
| **无预录 PCM** | 搜 `$readmem` | **RTL 里没有**（`wave_rom.v` 里出现过这个词，但**只在注释中**，是说明"为什么**不**用它"） |
| | 查有无 `.wav/.mp3/.pcm/.mif/.hex/.coe` | **一个都没有** |
| | 搜 `sd_` / `spi` / `fat` | **没有** |
| **波的来源** | 看 `rtl/synth/wave_rom.v` | 1024 项**常量表**（`case`），由三角函数与傅里叶级数**计算生成**。`table0` 正弦 256 项全部 = `32767·sin(2πi/256)`（误差 ≤1 LSB）；table1–3 是**带限**波形（5 / 9 次谐波） |
| **≥2 个独立可控维度** | 看 `top.v` 三个输入 | `key`(AB13) / `key2`(Y12) / `key_pitch`(Y22)。**独立性**由 `tb_interaction.v` 第 5、6 项证明：**在按住发声过程中**换音色/变调，`gate` 不受影响 |
| **32 个完整振荡器** | 看 `tone_bank.v` | `acc[0:31]`（**32 个独立 32 bit 相位累加器**）+ `pitch_inc(k,…)`（独立频率字）+ `en_level[k]`（独立包络）。`ROM_PARALLEL=1` 共用一份 ROM **不影响该认定**（统计的是振荡器实例，不是 ROM 实例） |
| **逐样本运算、无 CPU** | 看三个合成模块 | 均在 `always @(posedge clk)` 里做定点逐拍运算；**`top.v` 里没有任何 AE350 / CPU 实例** |

---

## 七、几个容易误判的点（重要）

1. **位流的 SHA256 不能当修订标识** —— 实测同一份 RTL 连续构建两次，`.fs` 哈希就不同
   （高云时序驱动 P&R 非确定性）。**判断修订要哈希 RTL 源码**，不是位流。
2. **ADSR 有两套配置，数字不同但都对**：
   生产 `top.v`（`EN_DIV=512`）衰减 **2.62 ms**；波形取证的 `tb_wave.v`（`EN_DIV=64`）衰减 **20.97 ms**。
   技术文档里写的是**生产值**。两套配置是为了让取证时斜坡在屏幕上看得出形状。
3. **`docs/` 里两份带"历史文档"横幅的报告**（`32复音-验证报告.md` / `PT8211-验证报告.md`）
   描述的是**旧的 48.8 kHz 配置**，数字已过期，**勿据此引用**；方法论部分仍成立。
4. **`tb_spectrum.v` 的 `EN_DIV=8` 是刻意的测量设置**，不是与设计不一致的 bug
   （原因见该文件内注释：`bench_gate` 是轮换门控，包络太快到顶会让 FFT 被直流淹没）。

---

## 八、许可与出处

- 本项目 RTL（`pt8211_tx.v` / `tone_bank.v` / `adsr.v` / `wave_rom.v` 等）**全部为独立实现**，
  只借鉴设计决策，未复制任何第三方代码 ⇒ **不涉及许可证传染**。
- 参考过（仅事实引用）：`sipeed/TangMega-138K-example`（**Apache-2.0**，引脚事实来源）、
  `vdalex/tangmega-138k-fpga-projects`（**无 LICENSE，未复制代码**）、`stnolting/captouch`（BSD-3-Clause）。
- PT8211 手册时序参数引自原厂 **PTC V1.7** AC Characteristics 表。
- 详见 [`docs/工程能力与工具链说明.md`](docs/工程能力与工具链说明.md)。
