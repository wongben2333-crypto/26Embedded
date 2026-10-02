# references/traps.md —— fpga-verify 实测过的坑与证据

> 本文所有结论都来自本机实测（Python 3.14.5 + numpy/scipy + ModelSim 10.7 SE-64），
> 每条都给出**可复现命令**与**原始输出**。测量对象是 `fpga_hank/rtl/` 的真实 RTL。

---

## §1 采样率陷阱：`--fs` 漏传 → 32 个峰全部误判 FAIL

### 事实
本设计音频 fs 由 `pt8211_tx.v` 决定：

```
fs = clk / (BCK_DIV × 帧长) = 50 MHz / (2 × 512) = 48828.125 Hz
```
（`parameter integer BCK_DIV = 2`；帧长来自 `if (bc_cnt == 9'd511)` → 512 clk；时钟来自
`fpga_hank/constr/fpga_hank.sdc` 的 `create_clock -period 20`。）

`fpga_hank/tools/verify/check_peaks.py` 的 `--fs` 默认值是 **48000**。
`fpga_hank/sim/tb/tb_spectrum.v` 头部注释给出的示例命令 **漏了 `--fs`**。

### 实测证据（同一份 dump，唯一差别是 `--fs`）

用 `make_fixture.py` 按真实 fs 合成 32 音（`--fs 48828.125`），然后：

| 命令 | 结果 |
|---|---|
| `check_peaks.py --file ... --format samples --count 32` | **exit 1**，`命中 0/32`，200 Hz 读成 196.29 Hz（误差 −3.71 Hz） |
| `check_peaks.py --file ... --format samples --fs 48828.125 --count 32` | **exit 0**，`命中 32/32`，最大误差 0.32 Hz |

对**真实 RTL 的 ModelSim dump**（65536 样本）同样成立：漏传 `--fs` → 全 FAIL。

### 为什么会这样
误差 = 期望频率 × (1 − 48000/48828.125) ≈ 1.696%：
- 200 Hz → −3.39 Hz（> 容差 2 Hz，FAIL）
- 6400 Hz → −108 Hz（远超容差）

### 纪律
1. 任何频谱/延迟计算前先跑 `scripts/derive_fs.py`。
2. `scripts/spectrum_report.py` 不传 `--fs` 会自动推导并打印提示。
3. 顺手修 `tb_spectrum.v` 头注释里的示例命令（该文件属他人写作用域，需先协调）。

### 附带发现（注释噪音）
`pt8211_tx.v` 第 18 行的注释里留着一个**错误的中间推导值** `97656.25 Hz`（作者自己写了"等等，这不对"）。
`derive_fs.py` 会把注释里所有 `… Hz` 值列出来做交叉校验，并把它标记为"过时/中间推导值，勿引用"。

---

## §2 谱峰数达标但增益不均 9.74 dB：时分复用 ROM 的地址推进缺陷

### 现象
`spectrum_report.py` 对真实 dump 的判定：

```
期望谱峰 32   命中 32   未命中 0
命中峰电平范围 -9.74 ~ 0.00 dBc (离散度 9.74 dB)
C4 电平离散度 9.74 dB  (门限 6 dB)  FAIL
最终结论: 谱峰数达标但增益不均（离散度 9.74 dB > 6 dB）   ← exit 4
```
200 Hz 比其他各路高 9.74 dB —— 交付时"32 路都同等可闻"这条会被评委一眼看出问题。

### 根因（用读次数直方图定位，不靠猜）
`sine_rom` 是 **1 拍延迟**（源码只有 `val <= mem[addr]`，无地址寄存器），
所以**累加第 j 拍实际加上的是 `f(addr(j-1))`**。

`tests/tb_diag.v` 在 **negedge** 采样（避开 posedge 的 NBA 观察顺序歧义），
统计每个采样周期里 32 个累加拍各自读到的 `acc[索引]`：

```
累计读取次数 total=170（34 拍 × 5 周期）
读 0 次(静音) = 无
读多次(偏响) = {0: 15}      ← 即 voice[0] 每周期被读 3 次；其余 31 路各 1 次
```
→ `20·log₁₀(3) = 9.54 dB`，与频谱实测的 **9.74 dB** 相互印证。

对应当时的 RTL（`tone_bank.v`）三处叠加导致：
- `if (sample_tick) … addr_mux <= 5'd0;`（tick 拍把地址清零）
- 累加窗口是 `samp_cnt <= N_VOICES+1`（**34 拍**，不是 32 拍）
- `addr_mux <= (samp_cnt >= N_VOICES) ? 5'd0 : samp_cnt[4:0];`（末尾回绕到 0）

于是 34 拍里地址序列为 `0,0,0,1,2,…,30,31` → `acc[0]` 被读 3 次、
`sum` 变成 34 项（等效增益 +0.52 dB）。

### 最小修法（推导，需 Lead 在 RTL 侧实施并复测）
目标：**累加窗口恰好 32 拍，且 32 拍读到的索引恰好是 `0..31` 各一次**。
因为累加第 j 拍加上的是 `f(addr(j-1))`，读集合 = `{addr(tick)} ∪ {addr(0…30)}`
= `{addr(tick)} ∪ {0…30}`，要凑成 `{0..31}`，只需 **`addr(tick) = 31`**。

即：
```verilog
// 1) tick 拍：预置地址为 N_VOICES-1（而不是 0）
addr_mux <= 5'd31;                                  // 原为 5'd0
// 2) 累加窗口收回 32 拍
end else if (samp_cnt < N_VOICES[5:0]) begin         // 原为 <= N_VOICES+1
    samp_cnt <= samp_cnt + 6'd1;
    sum      <= sum + rom_val;
    addr_mux <= samp_cnt[4:0];                       // 去掉末尾回绕
// 3) 输出拍相应改为 samp_cnt == N_VOICES
end else if (samp_cnt == N_VOICES[5:0]) begin
    mix_out  <= sat16(sum >>> 5);                    // 32 项，>>>5 正确
```
**复测标准**：`tb_diag` 直方图每路恰好等于周期数；`spectrum_report.py` C4 ≤ 1 dB 且 exit 0。

> ⚠️ RTL 归 Lead/他人写作用域，本 skill 只提供诊断与推导。改完请务必用 `tb_diag` + `spectrum_report.py` 双向复测。
> ⚠️ 文件在 23:00 前后被频繁修改过（实测两次测量间 hash 变化），**任何结论都要记录 RTL hash + 时间戳**。

---

## §3 反自欺：判据本身必须先被验证

`check_peaks.py --selftest` 的四项对照（本机实测 PASS）：

| 对照 | 期望 | 实测 |
|---|---|---|
| 32 音合成 → int16 → I2S 打包/解包 | 逐样本无损 | True |
| 32 音 → 逐 BCLK 位流 `(ws,din)` → 解码 → 分析 | 32/32 命中 | 32/32，0 杂散 |
| **负对照**：只发 16 路、用 32 路判据 | 16 命中 + 16 未命中 | 16 + 16 ✓（说明判据有分辨力） |
| **灵敏度对照**：人为硬限幅到 50% | 必须检出杂散 | 检出 **81** 个互调峰 ✓（说明能抓到坏信号） |

**没有负对照与灵敏度对照的"验证"，等于没验证。** 这是本 skill 存在的主要理由。

---

## §4 工具缺失必须报 SKIPPED，不许报 PASS

实测：
```
run_lint.ps1   → verilator 未安装 → [lint] SKIPPED … exit 3
run_formal.ps1 → sby 未安装       → [formal] SKIPPED … exit 3
```
本机现状：`verilator` / `iverilog` / `sby` / `verible` **全部未安装**（`Get-Command` 全空）。
所以现在**不能**声称"已通过 lint"或"已形式验证"。安装见 `_research/fpga-tools/INSTALL-PLAN.md`。

---

## §5 两个 PowerShell 环境坑（本机实测，会影响队友写的任何脚本）

### §5.1 DSH 的 `pwsh` 工具其实是 **Windows PowerShell 5.1**，不是 7
```
$PSVersionTable.PSVersion = 5.1.26100.9444
PSEdition                  = Desktop
```
后果：`.ps1` 若是 **UTF-8 无 BOM** 且含中文 ⇒ **中文必然乱码**（实测 `涓枃娴嬭瘯`）；
**是否进一步升级成语法错误取决于具体字节序列**——某个汉字的 UTF-8 字节恰好"吞掉"后续引号/括号时才会解析失败
（我在 `run_lint.ps1` 上实测到 `Array index expression is missing` / `Missing closing '}'`，
但 dsh-plugins 用另一份内容复测时**只复现了乱码、没有语法错误**，两者并不矛盾）。
**含中文的 `.ps1` 一律存成 UTF-8 with BOM**；本 skill 的 `.ps1` 都已带 BOM，在 5.1 下实测可运行。

⚠️ **乱码比报错更危险**：乱码时脚本 **exit 0 照常跑完**，还继续拿着错字符串工作——
比较中文标签、匹配中文路径会**静默失配**（例如把 `[lint] SKIPPED` 写成别的中文串就再也匹配不上）。
所以"能跑通"绝不等于"结果对"。

> **更正**：我最初判断"DSH 走 pwsh 7、BOM 只是给队友手跑做保险"——**该前提是错的**
> （由 dsh-plugins 指出、我在本机复测确认）。**本机 `Get-Command pwsh` 不存在，根本没有 PowerShell 7**，
> 所以不是"DSH 选了 5.1"，而是**没有 7 可选**；BOM 对 DSH **自身**执行脚本就是必需的。

### §5.2 本机执行策略是 **AllSigned**，调用脚本必须带 `-ExecutionPolicy Bypass`
```
Get-ExecutionPolicy = AllSigned           # -List 显示仅 LocalMachine = AllSigned
$env:PSExecutionPolicyPreference = (空)   # → DSH 没有替我们注入 Bypass，必须自己写
powershell -File run_lint.ps1                          → 失败：is not digitally signed（exit 1）  ← 实测
& .\run_lint.ps1                                       → 同上失败                              ← 实测
powershell -ExecutionPolicy Bypass -File run_lint.ps1  → 正常                                 ← 实测
```
所以文档/自动化里**不能**写 `powershell -File x.ps1`。统一写法：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <脚本路径>
```
（`run_selfcheck.ps1` 内部调用子脚本时已带该参数，所以一键自检能跑通。）

**边界澄清（避免误读）**：ExecutionPolicy **只约束脚本文件**，不约束 `-Command`。
所以 **DSH 的 `pwsh` 工具本身从不被拦**（这就是所有内联命令都能跑的原因）；
真正受限的**只有"调用 `.ps1` 文件"这一件事**。

### §5.3 非 `.ps1` 文件的编码体检（本 skill 实测）

| 类型 | 编码 | 结论 |
|---|---|---|
| 6 个 `.py` | UTF-8 **无 BOM** | ✅ **正确**（Python 3 默认按 UTF-8 读源码，**加 BOM 反而不好**） |
| 2 个 `.do`（ModelSim Tcl） | UTF-8 无 BOM + 中文注释 | ✅ **已验证可跑**（`run_spectrum.do` / `run_diag.do` 实测多次成功） |
| 3 个 `.v` | UTF-8 无 BOM + 中文注释 | ✅ **ModelSim 下已验证**：`latency_tb.v`、`acc_overflow_fv.v` 用 `vlog -sv` 编译 **Errors: 0**；`tb_diag.v` 编译并跑通 |
| Gowin 综合 | 含中文注释的 RTL | ✅ **项目自身已证明**：`fpga_hank/eda_proj/fpga_hank/impl/pnr/fpga_hank.fs`（33.2 MB）已生成，而 RTL 通篇中文注释 |
| `.sby` | UTF-8 无 BOM + 中文注释 | ⚠️ **未验证**（本机无 sby） |

> 附注：ModelSim 的 `vlog` **没有 `-formal` 选项**（那是 Yosys/Verific 侧的）；
> ModelSim 下直接用 `vlog -sv` 即可编译 `assert`，加 `-formal` 会报 `vlog-1902`。

---

## §6 证据必须来自**稳定快照**（本项目实测踩过，最容易被忽略的坑）

`fpga_hank/out/tone_samples.txt` 是**正在迭代的活文件**：实测在几分钟内被重写多次，
甚至在读取时被仿真进程独占锁定（`Get-FileHash` 报"正由另一进程使用"）。
我在它上面**连续两次**得到**互相矛盾**的结论（先 `离散度 6.83 dB`，再 `match 13/32 + 19 杂散`），
原因就是读到了"写到一半"的文件——**这种错误比没有测量更糟，因为它看起来像数据**。

**纪律**：
1. 先 `Copy-Item <活文件> <快照>`，只对快照做分析。
2. `spectrum_report.py` 已内置防护：**一次性读入字节** + 记录 `sha256/mtime/字节数`，
   并在读取前后比对（`file_stable`）。若检测到读取期间被改写 → **退出码 5 = UNSTABLE**，
   明确告诉你"结论无效"，而不是给一个看起来正常的数字。
3. 证据（`EVIDENCE-*.md` / `summary.json`）里已带文件指纹，引用时**连指纹和 RTL hash 一起写**。
4. **同一纪律也适用于"读文件 / 搜索"本身**：多人（多 agent）并行编辑时，一次 `read` / `grep` 可能读到**写入前的快照**，
   据此下结论就会与别人文件的实际内容不符。**关键结论要复查一次再下** —— 这与"一次静止读数不能定论"是同一类问题，
   只不过一个是文件**版本**、一个是文件**内容**（实测：dsh-plugins 复核 §8 挂载时第一次 grep 没看到、重读才看到，
   因为我那次写入正好落在两次调用之间）。

**退出码约定补充**：`0` PASS ｜ `4` 谱峰达标但增益不均 ｜ `1` FAIL ｜ `2` 输入错 ｜ **`5` UNSTABLE（结论无效）**。

---

## §7 交付级风险：Gowin 工程**不可移植**（实测：换路径即报 EX5998）

### 现象
`fpga_hank/eda_proj/fpga_hank/fpga_hank.gprj` 的 `<FileList>` 里 **6 条全部是绝对路径**，
且含空格与用户名（`C:/Users/Danny/Desktop/FPGA competition/fpga_hank/rtl/top.v`）。

### 我做的对照实验（全部本机实测）
用一份自建的最小工程（`rtl/blinky.v` + 两个 build 脚本，布局刻意模仿本项目：源码在工程目录之外）：

| # | 实验 | 结果 |
|---|---|---|
| 1 | `add_file` 传**相对路径**（`../../rtl/blinky.v`） | ❌ 生成的 `.gprj` 里**仍然写成绝对路径** → Gowin 强制规范化，**无法用相对路径规避** |
| 2 | 工程目录整体改名（模拟"移动/打包/换机器"），再 `open_project <移动后的.gprj>; run syn` | ❌ **硬失败**：`ERROR (EX5998) : Cannot open Verilog file '<旧绝对路径>'` |
| 3 | 在**新位置重新跑 `build.tcl`**，再综合 | ✅ 成功，新 `.gprj` 指向新绝对路径 |

### 结论与交付姿势
1. **交付物 = 源码 + 约束(`.cst`/`.sdc`) + `build.tcl` + 已生成的 `.fs`**。
2. **不要把 `eda_proj/*.gprj` 当交付物依赖** —— 它绑死本机绝对路径；`eda_proj/`、`out/` 应视为**可丢弃产物**。
3. 评委/换机复现只需两步：烧写现成的 `.fs`（`programmer_cli.exe`），或在新机器上重跑
   `gw_sh.exe <路径>\build.tcl` 重建工程。
4. 前提：`build.tcl` 必须用 `[file dirname [info script]]` 定位 ROOT（`gowin-flow` skill 已作要求），
   否则重建也会写进错误的绝对路径。
5. **好消息**：这个失败是**响亮的**——Gowin 会把缺失的绝对路径直接打印出来，不会静默用错文件。

### 工具
`scripts/check_portability.ps1`（三态退出码）：
```
0 = 没有 .gprj（走 Tcl 重建路线，最省事）
3 = 有 .gprj 且含绝对路径，但旁边有 build.tcl（正常，已打印重建命令）   ← 本项目当前状态
1 = 有 .gprj 含绝对路径，且找不到 build.tcl（真正的交付风险）
```
调用示例（**必须带 `-ExecutionPolicy Bypass`**，见 §5.2；直接 `& .\check_portability.ps1` 会撞 AllSigned）：
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .dsh\skills\fpga-verify\scripts\check_portability.ps1
# 也可指定扫描目录（默认 <root>\fpga_hank）：
powershell -NoProfile -ExecutionPolicy Bypass -File .dsh\skills\fpga-verify\scripts\check_portability.ps1 -ScanDir <目录>
```
对真实工程的实测输出：`绝对路径条目 6 / 相对路径条目 0` → `exit 3`，并给出
`& 'F:\Gowin\...\gw_sh.exe' '...\fpga_hank\tools\gowin\build.tcl'` 的重建命令。

### ⚠️ "换机复现"的 3 个前提（**均未验证**，别把上面结论读成已闭环）
1. **目标机器需要可用的 Gowin 授权**。本机是 STD license 到 2027-09-24；换机器是**全新的授权问题**，
   没有 license 连综合/PnR 都跑不起来（烧录是否也受限**未验证**）。
2. **目标机器的 Gowin 版本与器件库必须兼容** `build.tcl` 里写死的 `GW5AST-LV138PG484AC1/I0`
   + `-device_version C`；版本过老可能不认 GW5AST-138C。
3. **`.fs` 是"器件+版本"相关的产物**：直接烧录只在**器件一致**时成立，
   它**解决不了**"必须重建工程"的场景——那时上面 1、2 条就是硬前提。

---

## §8 ★方法论：**隔离基准不能用来"排除嫌疑"**（我被实测推翻的一次）

### 现象
我做了"N 份 `wave_rom` → 综合耗时/资源"的隔离基准，得到：
`N=1/2/4/8/16/32 → BSRAM=1/2/4/8/16/32、LUT=2/18/19/52/85/182、耗时 2.4→4.6 s`
⇒ 我据此**排除**了 `ROM_PARALLEL=32`，宣称"它不是卡死主因"。
**随后 Lead 在主工程显式传 `.ROM_PARALLEL(1)` → 35 秒完成；而 `=32` 无限卡死** ⇒ **我的排除被推翻**。

### 根因（我的实验设计缺陷）
隔离算例里只有 **N 份裸 `wave_rom`**；真实 `tone_bank.v` 里是
**32 份并行波表 + `acc[32]×32bit` 相位累加器数组 + 并行读通路 + 地址 MUX + 求和 + ADSR×32** 的**组合**。
综合卡在 `device independent optimization`，而日志里恰好有 **`Extracting RAM for identifier 'acc'`**
—— 我的算例里**根本没有 `acc`**。所以"单体便宜"完全推不出"放进真实设计也便宜"。

### 正确做法（以后照这个来）
1. **隔离基准只用于"理解单体代价"**（如"一份 ROM = 1 BSRAM"），**不得用于"排除嫌疑"**；
2. 要排除某个嫌疑，必须**在真实工程里二分**：改**一个**参数（如 `ROM_PARALLEL`）→ 跑**完整**构建 → 看是否 35 s 完成；
3. 报告里严格区分「实测」与「推断」；**推断被推翻必须留更正记录**
   （本项目实例：`_research/fpga-tools/ROUND2-CORRECTIONS.md`，原文不删、以更正为准）。

### 顺带两个"指标会骗人"的例子
- **文件 0 字节 ≠ 卡死**：那是"写入中的瞬时状态"（同一日志随后是 1828 B）。判卡死要看**日志是否停止增长**；
- **进程还在 ≠ 在算**：CPU 增长从 99% 掉到 ~6% 单核，说明它**停住了**，不是在慢慢算。

即：**「交付源码+Tcl+.fs」解决的是"绝对路径绑死"这一件事**，
不解决授权/版本/器件一致性——那三件属于交付说明里要写清的边界。
（此前提清单由 dsh-plugins 复核时补充，我确认其成立；标注为未验证。）

