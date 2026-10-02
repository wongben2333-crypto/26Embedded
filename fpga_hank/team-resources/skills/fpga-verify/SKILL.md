---
name: fpga-verify
description: 高云 FPGA 竞赛项目的验证与取证门禁：32 谱峰频谱取证、真实采样率推导（本项目是 48828.125 Hz 而非 48000）、控制到发声延迟 P50/P95/P99、赛题红线自审（禁预录 PCM/禁 CPU 承担合成）、lint 与 sby 形式验证门禁，以及"某一路振荡器被读多次或漏读"的读次数直方图诊断。当需要验证 RTL 是否真的出声、数谱峰、出频谱证据、测延迟分布、排查某一路音缺失或偏响、做提交前自查、或跑 ModelSim/verilator/iverilog 仿真与形式验证时使用。
whenToUse: 需要"证明"而不是"相信"的时候——出频谱证据、测延迟分布、提交前红线自审、排查某一路音缺失或偏响、判断"这次验证到底跑没跑"。
---

# fpga-verify —— 验证与取证门禁（Tang Mega 138K / GW5AST-138C）

本 skill 负责赛题里**一切需要拿出证据**的环节。它不写 RTL（那是 `gowin-flow` 与 `verilog-review` 的事），
它只回答三个问题：**真的出声了吗？真的满足指标吗？真的没踩红线吗？**

> 本 skill 的脚本都在 `<skill 目录>/scripts/`，**已在本机实测**（Python 3.14.5 + numpy/scipy + ModelSim 10.7 SE-64）。
> 凡未实测的都标了「未验证」。

## 加载方式与两条硬约束（均为本机实测，先读这一节）

**① 加载方式：若 `skill` 工具报 unknown，直接 `read` 本文件即可（等效）。**
实测 `skill("fpga-verify")` 返回 unknown；**对照组同样失败**——早已存在的 `gowin-flow` 也 unknown，
用户级根下的 `probe-user-root` 也 unknown，而 `Config.listConfigs` 显示
`@deepseek-ai/dsh-skill-filesystem` 状态为 `inactive` → 该 provider 在本会话未生效，**不是文件写错**。
`skill` 工具只是加载器，正文就是普通文件，所以 `read <本文件>` 完全等效，再按文中路径调用 `scripts/`。

**② 硬约束一：`.ps1` 必须保存为 UTF-8 with BOM。**
DSH 的 `pwsh` 工具实测是 **Windows PowerShell 5.1**（`$PSVersionTable.PSVersion = 5.1.26100.9444`，PSEdition `Desktop`）——
本机 `Get-Command pwsh` **不存在**，即**根本没有 PowerShell 7**，不是"DSH 选了 5.1"。
无 BOM + 中文 ⇒ **中文必然乱码**（实测输出 `涓枃娴嬭瘯`）；**是否进一步变成语法错误取决于具体字节序列**
（我在 `run_lint.ps1` 上实测到 `Array index expression is missing` / `Missing closing '}'`，换一个文件可能只是乱码）。
⚠️ **乱码比报错更危险：它 exit 0 照常跑完**，脚本拿着错字符串继续（比较中文标签、匹配中文路径会**静默失配**）。
本 skill 所有 `.ps1` 均带 BOM。**给本项目写任何含中文的 `.ps1` 都要照做。**

**③ 硬约束二：调用 `.ps1` 必须带 `-ExecutionPolicy Bypass`。**
本机实测 `Get-ExecutionPolicy = AllSigned`（`-List` 显示仅 `LocalMachine = AllSigned`，
且 `$env:PSExecutionPolicyPreference` 为空 → **DSH 不会替我们注入 Bypass，必须自己写**）。
`powershell -File x.ps1` 与 `& x.ps1` 都会以 *"is not digitally signed"* 失败（exit 1），只有下面这种写法可用：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <脚本路径>
```
（注：ExecutionPolicy **只管脚本文件、不管 `-Command`** —— DSH 的内联命令从不被拦，
真正受限的只有"调用 `.ps1` 文件"这一件事。）

## 0. 环境事实（本机实测，直接用）

| 项 | 值 |
|---|---|
| 真实采样率 | **fs = 48828.125 Hz**（= 50 MHz / (BCK_DIV=2 × 512)），**不是 48000** |
| 仿真器 | `F:\Modelsim_10.7\win64\vsim.exe`（SE-64 10.7，含 GW5AT 库） |
| 频谱工具 | `fpga_hank/tools/verify/check_peaks.py`（唯一事实来源，**不要复制修改**） |
| 采样 dump | `fpga_hank/sim/tb/tb_spectrum.v` → `tone_samples.txt`（每行一个十进制有符号样本） |
| Python | 3.14.5，numpy/scipy/matplotlib **已装**；verilator/iverilog/sby **未装**（见 `_research/fpga-tools/INSTALL-PLAN.md`） |

## 1. 60 秒上手

```powershell
$sk = Join-Path (Get-Location) '.dsh\skills\fpga-verify'      # 或在仓库根直接写全路径
python "$sk\scripts\derive_fs.py"                              # 1) 先确认采样率
python "$sk\scripts\spectrum_report.py" --file fpga_hank\out\tone_samples.txt --plot out\spectrum_32peaks.png
python "$sk\scripts\audit_compliance.py"                        # 3) 提交前红线自审
```
`spectrum_report.py` 不传 `--fs` 时会自己从 RTL+SDC 推导，**不要手写 48000**。

## 2. ★ 头号陷阱：漏传 `--fs` 会让 32 个峰全部误判 FAIL（实测）

`check_peaks.py` 的 `--fs` 默认值是 `48000`，而本设计真实 fs 是 `48828.125`。
`tb_spectrum.v` 头部注释里写的示例命令**恰好漏了 `--fs`**，照抄会得到：

```
  #  期望(Hz)   实测(Hz)    误差(Hz)   电平(dBc)  判定
  1     200.00     196.29      -3.71      -0.62  FAIL
  2     400.00     393.31      -6.69      -0.05  FAIL
  ...                                               全部 FAIL
结论: FAIL - 命中 0/32, 杂散 32        ← 退出码 1
```
同一份 dump，加上 `--fs 48828.125` 后：**32/32 PASS，退出码 0**（实测，见 `references/traps.md` §1）。

**根因**：误差 = 期望 × (1 − 48000/48828.125) ≈ 1.7%，200 Hz 就偏 −3.7 Hz，超过 ±2 Hz 容差。
**纪律**：任何频谱/延迟计算，先跑 `derive_fs.py`，把 `--fs` 显式带上。
**顺手修一下 tb 头注释**（会误导队友）——但注意 `tb_spectrum.v` 属别人的写作用域。

## 3. ★ 案例：谱峰数达标了，但增益不均 9.74 dB（本 skill 抓到的真缺陷）

对同一份 dump 跑 `spectrum_report.py`：

```
期望谱峰 32   命中 32   未命中 0
命中峰电平范围 -9.74 ~ 0.00 dBc (离散度 9.74 dB)     ← 200 Hz 明显偏响
C4 电平离散度 9.74 dB  (门限 6 dB)  FAIL
最终结论: 谱峰数达标但增益不均（离散度 9.74 dB > 6 dB）   ← 退出码 4（不是 0！）
```

`spectrum_report.py` 因此比 `check_peaks.py` 多了 **C4 判据**：离散度接近
**+9.54 dB = 20·log₁₀(3)** 说明某一路每个采样被**读了 3 次**；**+6.02 dB = 20·log₁₀(2)** 说明被读 2 次。

用 `tests/tb_diag.v`（读次数直方图）确认了根因：

```
累计读取次数 total=170（34 拍 × 5 周期）
读 0 次(静音) = 无
读多次(偏响) = {0: 15}        ← voice[0] 每周期被读 3 次，其余每路 1 次
```

即 `tone_bank.v` 的时分复用 ROM 地址推进，在 34 拍累加窗口里把 `acc[0]` 读了 3 次、
并把 200 Hz 的幅度抬高了 9.54 dB（同时 `sum` 变成 34 项，等效增益 +0.52 dB）。

**最小修法（推导见 `references/traps.md` §2，RTL 由 Lead 改，改完必须用 tb_diag 复测）**：
让累加窗口恰好 32 拍、且 32 拍读到的地址集合恰好是 `acc[0..31]` 各一次——
`sine_rom` 是 **1 拍延迟**（`val <= mem[addr]`，无地址寄存器），所以
累加第 j 拍加上的是 `f(addr(j-1))`。把 tick 拍的地址预置为 `5'd31`、窗口收回到 32 拍、地址按 `samp_cnt[4:0]` 递增，
读集合即 `{31, 0, 1, …, 30}` = 每路恰好一次。

**复测标准**：`tb_diag` 直方图每路都恰好 = 周期数；`spectrum_report.py` 的 C4 ≤ 1 dB 且退出码 0。

## 4. 脚本清单与退出码约定（重要）

| 脚本 | 作用 | 退出码 |
|---|---|---|
| `scripts/derive_fs.py` | 从 RTL+SDC 推导 fs，交叉校验注释 | 0 成功 / 1 `--expect` 不符 / 2 解析失败 |
| `scripts/spectrum_report.py` | **频谱取证单一入口**（C1..C4 + 文件指纹/稳定性 + 出图 + 证据 md/json） | 0 PASS / 4 谱峰达标但增益不均 / 1 FAIL / 2 输入错 / **5 输入文件不稳定（结论无效）** |
| `scripts/make_fixture.py` | 造合成 dump（含负对照/削波对照），无硬件也能自检 | 0 |
| `scripts/latency_stats.py` | 延迟 P50/P95/P99/max/抖动 + 报告表格 | 0 全达标 / 1 不达标 / 2 输入错 |
| `scripts/audit_compliance.py` | 赛题红线自审 | 0 无红线 / 3 需人工确认 / 1 命中红线 / 2 路径错 |
| `scripts/check_portability.ps1` | **交付可移植性检查**：Gowin `.gprj` 是否绑死本机绝对路径（换机器会报 EX5998） | 0 无 .gprj / **3 有绝对路径但有 build.tcl（正常）** / 1 有绝对路径且无法重建（交付风险） |
| `scripts/run_lint.ps1` | verilator `--lint-only` + Verible 门禁 | **3 = SKIPPED（工具未装）** / 0 PASS / 1 FAIL |
| `scripts/run_formal.ps1` | sby 门禁 | **3 = SKIPPED** / 0 PASS / 1 FAIL |
| `tests/tb_diag.v` + `tests/run_diag.do` | **读次数直方图**诊断（哪一路被读多次/漏读） | — |
| `tests/run_spectrum.do` | 用 ModelSim 跑真实 tb_spectrum 生成 dump | — |

> **退出码 3 = 没跑**。任何自动化（含给评委看的脚本）都不允许把 3 当 0 —— 这是本 skill 最重要的约定。

## 5. 工作流 A：32 谱峰取证（赛题必备交付物）

```powershell
# 5.1 无硬件先自检：证明分析链本身可靠（含负对照与灵敏度对照）
python "$sk\scripts\make_fixture.py" --out "$env:TEMP\ok.txt"
python "$sk\scripts\make_fixture.py" --out "$env:TEMP\clip.txt" --clip 0.5    # 削波对照
python "$sk\scripts\spectrum_report.py" --file "$env:TEMP\ok.txt"   --fs 48828.125 --no-plot  # 期望 exit 0
python "$sk\scripts\spectrum_report.py" --file "$env:TEMP\clip.txt" --fs 48828.125 --no-plot  # 期望 exit 1（有杂散）

# 5.2 用 ModelSim 跑真实 RTL 采样（在 skill 的 tests 目录下执行，dump 落在该目录）
cd "$sk\tests"
& "F:\Modelsim_10.7\win64\vsim.exe" -c -do run_spectrum.do      # 约 22 秒，输出 tone_samples.txt

# 5.3 出证据（不传 --fs，自动推导；同时出 PNG + markdown + JSON）
python "$sk\scripts\spectrum_report.py" --file tone_samples.txt `
       --plot spectrum_32peaks.png --md-out EVIDENCE-spectrum.md --json-out summary.json --xmax 8000
```
**判据**：C1 32/32 命中、C2 每路 ≥ −40 dBc、C3 无杂散、C4 离散度 ≤ 6 dB → 退出码 0 才算过。
**交付素材**：`spectrum_32peaks.png`（32 条红色期望线 + 绿色检出点 + 判据标题）+ `EVIDENCE-spectrum.md` 的表格。

## 6. 工作流 B：控制→发声延迟（基础 ≤10 ms；拓展 ≤5 ms 且无抖动）

1. 用 `templates/latency_tb.v` 的思路在测试平台里记录每次「控制事件时间 → 首个非零音频样本时间」，
   每行写一条 CSV（同单位时间戳，或直接一个延迟值）。**模板需按实际端口名改造（未验证）**。
2. 统计：
```powershell
python "$sk\scripts\latency_stats.py" --file lat.csv --unit cycles --clk-mhz 50 --markdown
python "$sk\scripts\latency_stats.py" --file lat.csv --unit us --jitter-ms 0     # 拓展要求：无抖动
```
3. 报告里必须给 **P50/P95/P99/max + 抖动**（赛题原文要求），不要只说"很快"。

## 7. 工作流 C：Lint 与形式验证门禁

```powershell
# 本机执行策略是 AllSigned，必须带 -ExecutionPolicy Bypass（见文首硬约束③）
powershell -NoProfile -ExecutionPolicy Bypass -File "$sk\scripts\run_lint.ps1"      # 未装工具 → exit 3 SKIPPED（不是 PASS）
powershell -NoProfile -ExecutionPolicy Bypass -File "$sk\scripts\run_formal.ps1"    # 未装 sby → exit 3 SKIPPED
```
- **verilator `--lint-only` 不需要 C++ 编译器**，装上 oss-cad-suite 即可用（P0）。
- sby 也在 oss-cad-suite 的 Windows 包里（含 z3/boolector/cvc5），**不必 WSL**。
- 本机现在两者都没有 → 这两个门禁目前返回 3。**在它们返回 0 之前，不要说"已通过 lint/形式验证"。**

## 8. 工作流 D：提交前自审（红线 + 交付可移植性）

```powershell
python "$sk\scripts\audit_compliance.py" --md-out EVIDENCE-compliance.md
# 交付可移植性：换机器/打包前必查（3 = 正常，1 = 交付风险；详见 references/traps.md §7）
powershell -NoProfile -ExecutionPolicy Bypass -File "$sk\scripts\check_portability.ps1"
```
机检 7 条：R1 可综合 RTL 里的 `$readmemh/$readmemb`（预录样本入口）、R2 仓库内音频文件、
R3 大体积初始化数据、R4 RTL 大内存数组、R5 CPU/软核是否出现在音频通路、
R6 测试模式是否存在、R7 相位累加器迹象。结论 **PASS/REVIEW/FAIL** 直接贴报告。
> 它只做启发式排查，**不替代评委的 RTL 审查**；`WARN` 项必须人工确认并写进文档。

## 9. 反自欺三原则（本 skill 的方法论，务必遵守）

1. **负对照**：判据必须能报错。只发 16 路时，32 路判据必须报 16 命中 + 16 未命中（已实测）。
2. **灵敏度对照**：判据必须能抓到坏信号。人为削波后必须检出大量杂散（已实测检出 81 个互调峰）。
3. **无工具不得 PASS**：lint/formal 未安装一律返回 3 = SKIPPED。**"没跑"永远不等于"通过"。**

## 10. 未验证事项（不要当成已验证结论）

1. `templates/latency_tb.v`：**语法已由 ModelSim `vlog -sv` 验证通过（Errors: 0）**，但**行为未跑通**（DUT 端口需按实际模块改造）。
2. `templates/formal/*.sby` 未跑通（本机无 sby）；`acc_overflow_fv.v` 也只验证了语法（`vlog -sv` Errors: 0），**没有证明结果**。
3. `run_lint.ps1` 在有 verilator 的机器上的行为未验证（本机无 verilator，只验证了 SKIPPED 分支）。
4. 96 kHz 采样率下的频谱判据未验证（需同时改 RTL、`--fs` 与频率网格）。
5. `audit_compliance.py` 的规则是启发式，误报/漏报都可能存在。

## 11. 相关文档

- `_research/fpga-tools/SPECTRUM-VERIFY.md`：频谱取证的完整原理、I2S 解码、参数表、失败排查表
- `_research/fpga-tools/FINDINGS.md` / `INSTALL-PLAN.md`：工具链可用性与安装清单（verilator/sby/Verible）
- `references/traps.md`：本 skill 实测过的坑与证据（含 fs 陷阱、增益不均推导）
- `.dsh/skills/gowin-flow/SKILL.md`：构建链路；`.dsh/skills/verilog-review/SKILL.md`：RTL 审查
