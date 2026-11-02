# J14（上侧 40P 排针）引脚可用性 —— 138C 实测报告

> 结论先行：**138K 上 14/15 个「仅 SDRAM1」球号可作为普通 LVCMOS33 输出**；
> 只有 **`N17` 不可用**（`PR2017 dedicated pin (SSPI)`）。
> **60K 未测**（无板），对方的「60K 上 16 脚没连」无法在本机验证。

---

## 1. 版本指纹（按 AGENTS.md §8.1 强制要求）

| 项 | 值 |
|---|---|
| 时间 | **2026-10-21 23:54 ~ 23:56**（北京时间） |
| part | `GW5AST-LV138PG484AC1/I0` |
| device version | **C** |
| 工具 | Gowin V1.9.12.04 (x64) |
| 工程 | 独立探针工程，**不读写正式工程、不动已固化 Flash** |
| 构建次数 | 2 轮（第 1 轮 15 脚 FAIL、第 2 轮 14 脚 PASS）|
| 单轮耗时 | 约 **4 s** |

> ⚠️ **Gowin 不认中文路径**：工程放在 `E:\学\...` 下会报
> `ERROR (SP0002) : Corrupted project file: "E:/?/.dsh-tools/..."`（`学` 被替换成 `?`）。
> ⇒ 必须用**纯 ASCII 路径**（本次用 `E:\dsh-tmp\j14_probe`）。

---

## 2. 待测球号的来源

原理图 `_research/pc-link/_dock_sch.pdf` 第 6/7/19 页：
`J14` 的标注是 **`{SDRAM1|DVP_CAM|PMOD}`** ⇒ 它的网络分三类：

| 类别 | 与什么复用 | 数量（本机解析）|
|---|---|---|
| A. 与 PMOD 复用 | `PMOD0_IO0..7` / `PMOD1_IO0..7` | 13~16 个球 |
| B. 与 DVP 摄像头复用 | `CAM0_D0..D7` / `PCLK` / `HSYNC` / `VSYNC` / `MCLK` / `~PWDN` / `~RST` | 14 个球（其中 **6 个与 PMOD 三者共用**）|
| C. **仅 SDRAM1**（不与 PMOD/CAM0 重叠）| 无 | **15 个球（本次实测对象）** |

**⇒ A、B 两类「接它等于把已有的线再接一遍」，没有增量价值**（对方结论正确）。
**⇒ 只有 C 类才可能提供「新增 IO」** ⇒ 本次就测 C 类。

---

## 3. 实测结果（14 PASS / 1 FAIL）

| # | 球号 | 原理图网络 | 138C 结果 | 错误原文 |
|---|---|---|---|---|
| 0 | **`A15`** | `SDRAM1_A10` | ✅ **PASS** | — |
| 1 | **`AA18`** | `SDRAM1_DM0` | ✅ **PASS** | — |
| 2 | **`AB18`** | `SDRAM1_DM1` | ✅ **PASS** | — |
| 3 | **`D14`** | `SDRAM1_BA1` | ✅ **PASS** | — |
| 4 | **`N13`** | `SDRAM1_D8` | ✅ **PASS** | — |
| 5 | **`N14`** | `SDRAM1_D9` | ✅ **PASS** | — |
| 6 | ⛔ **`N17`** | `SDRAM1_D10` | ❌ **FAIL** | `PR2028` + `PR2017 ... 'o[6]' ... dedicated pin (SSPI)` |
| 7 | **`P17`** | `SDRAM1_D11` | ✅ **PASS** | — |
| 8 | **`V17`** | `SDRAM1_D14` | ✅ **PASS** | — |
| 9 | **`V20`** | `SDRAM1_A12` | ✅ **PASS** | — |
| 10 | **`W17`** | `SDRAM1_D15` | ✅ **PASS** | — |
| 11 | **`W21`** | `SDRAM1_D12` | ✅ **PASS**（与旧探针结论一致）| — |
| 12 | **`W22`** | `SDRAM1_D13` | ✅ **PASS** | — |
| 13 | **`Y18`** | `SDRAM1_~RAS` | ✅ **PASS** | — |
| 14 | **`Y19`** | `SDRAM1_~CAS` | ✅ **PASS** | — |

**通过率 14/15 = 93.3%**

**错误原文（`probe/evidence_fail_r1.log`）**：
```
ERROR  (PR2028) : The constrained location is useless in current package
ERROR  (PR2017) : 'o[6]' cannot be placed according to constraint, for the location is a dedicated pin (SSPI)
```
（`o[6]` 对应列表第 7 个 = `N17`）

---

## 4. 方法：为什么这个结论可信

**用的是「真跑 P&R + 逐个剔除」**，不是查表、不是推断：

1. 写一个最小顶层（`clk` + N 位输出），把候选球号**全部**约束成 `LVCMOS33` 推挽输出；
2. 跑 `run syn` + `run pnr`（约 4 s）；
3. 若失败，从报错里正则提取 `'o[i]'`，把该球号记入 `FAIL` 并移出；
4. 重跑，直到 P&R 通过；
5. 剩下的球号 = **在同一 bitstream 内可共存的**可用脚。

**关键优点**：因为是一次约束多个脚，**排除掉失败脚后的 PASS 证明这些脚能在同一设计里共存**（不只是单独可用）。

**证据文件**（`fpga_hank/_research/pinout/probe/`）：
- `probe_io.v` / `probe_io.cst` / `probe_io.tcl` —— 可复现的探针工程
- `evidence_fail_r1.log` —— 第 1 轮 15 脚的失败记录（含 `PR2017`/`PR2028` 原文）
- `evidence_pass14.log` —— 第 2 轮 14 脚的通过记录

---

## 5. 这个结论的边界（按 AGENTS.md §9.1 必须说清）

| 覆盖到的 | **没有**覆盖到的 |
|---|---|
| ✅ 138K / device version C 上这 15 个球号能否**被布局器接受** | ⛔ **板子上 J14 座子是否真的焊了、走线是否真的通到 FPGA** —— 我**只验证了 FPGA 侧可约束**，没有电气通断证据 |
| ✅ 这些脚能否**同时**作为同一设计的输出 | ⛔ **60K** 上是否可用（无板，未测）|
| ✅ 失败脚的确切错误码与原文 | ⛔ **作为输入**是否也可用（本次只测了输出方向；同一脚有输出能力一般也有输入能力，但**未实测**）|
| | ⛔ **0Ω 电阻 R72~R75 的实际焊接状态**（决定信号实际走 J14 还是别处）|

**⇒ 因此**：「138K 上这 14 个脚**可以写进 `.cst` 且能过 P&R**」是**实测确立**的；
「焊上排针插传感器就一定能通」还需要**万用表通断测试**才能算实测。

---

## 6. 对项目的实际意义

| 问题 | 结论 |
|---|---|
| **J14 能不能增加可用 IO？** | ⚠️ **能，但只有 14 个脚**（A、B 两类是镜像，无增量）|
| **值不值得为此焊一个 40P 座？** | **取决于需求** —— 若 24 键 + 传感器在 `J13`（37 脚）里塞不下，这 14 个脚可以救急 |
| **`N17` 要避开** | ✅ 已确认，写进 `.cst` 会直接 P&R 失败 |
| **60K 上是否也这样** | ❓ **未验证**。官方说 60K/138K **共用同一块底板**（TANG MEGA NEO），但**核心板 FPGA 不同**，故底板走线能否连通取决于核心板球号引出 ⇒ **60K 上是另一套结论，不能用本报告外推** |

---

## 7. 顺带确认的两件事

1. **官方 wiki 确认 60K 与 138K 共用底板**：
   > 「60K Dock 和 138K Dock 共用一套底板（TANG MEGA NEO），因此两者的外设完全相同。」
   ⇒ 所以「上侧 40P 与 PMOD 和 DVP 复用」这个**结构**在两块板上都成立；
   差别只在**核心板 FPGA**（60K = `GW5AT-LV60PG484A` / 11 bank；138K = `GW5AST-LV138PG484A` / 10 bank）。

2. **官方给出了 Flash 烧录的正确模式**（与我们实测一致）：
   `exFlash Erase,Program thru GAO-Bridge 5A`（≥V1.9.11.03）
   或 `exFlash Erase,Program thru GAO-Bridge Arora V`（≥V1.9.12）
   ⇒ 我们用的 **op 68 = thru GAO-Bridge Arora V** ✅ 正确。

---

## 8. 复现步骤

```powershell
# 1. 拷到纯 ASCII 路径（Gowin 不认中文路径！）
Copy-Item fpga_hank\_research\pinout\probe E:\dsh-tmp\j14_probe -Recurse

# 2. 跑
& 'F:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe' E:\dsh-tmp\j14_probe\probe_io.tcl

# 3. 看结果
Select-String -Path E:\dsh-tmp\j14_probe\probe_run.log -Pattern 'RESULT|PR2017|PR2028'
```
