---
name: gowin-flow
description: 高云 Gowin EDA V1.9.12.04 命令行全链路构建（综合→布局布线→bitstream→烧录）与 Tang Mega 138K (GW5AST-138C) 工程规范。当需要编译 FPGA 工程、新建 Gowin 工程、写 gw_sh Tcl 脚本、排查综合/布线/时序错误、生成或烧录 .fs 码流、或问及 GW5AST-138 器件型号与引脚约束时使用。
---

# 高云 Gowin 全链路构建（已实测 V1.9.12.04 + Tang Mega 138K）

## 0. 环境事实（本机实测，直接用，不要重新探测）

| 项 | 值 |
|---|---|
| EDA 安装 | `F:\Gowin\Gowin_V1.9.12.04_x64` |
| 命令行入口 | `F:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe` |
| 综合器 | `IDE\bin\GowinSynthesis.exe`（由 `run syn` 自动调用） |
| 烧录 CLI | `F:\Gowin\Gowin_V1.9.12.04_x64\Programmer\bin\programmer_cli.exe` |
| License | `F:\gowin_E_F43BD81C9E81.lic`，`TYPE=STD`、`EXP_DATE=2027-09-24`。⚠️ 文件里写的 `MODE = NODELOCK` **有误导性**：`HOST_ID = F43BD81C9E81` 与本机 WLAN MAC `F4:3B:D8:1C:9E:81` 完全一致 → 实际是**绑本机网卡的节点锁**，不是"无锁"。换网卡/换机器需重新申请。 |
| 目标器件 | part `GW5AST-LV138PG484AC1/I0`，device `GW5AST-138C`，device id `gw5ast138c-007` |
| Tcl 官方文档 | `IDE\doc\CN\SUG1220-2.1_Gowin云源软件Tcl命令用户指南.pdf` |

## 1. 必踩的坑（全部实测踩过，务必遵守）

1. **`-synthesis_tool` 只能用小写 `gowinsynthesis`。**
   `GowinSynthesis` / `GW_SH` / `Synplify` 全部报 `unknown synthesis tool` 并中断脚本。
   ⚠️ **官方 PDF SUG1220-2.1 的示例写的是 `set_option -synthesis_tool GowinSynthesis`（大写）—— 照抄官方文档必踩。**
   另：该选项**其实可以不设**；`synplify_pro` 也被接受，但到 `run syn` 才死。
2. **`gw_sh.exe` 不会切到 .tcl 所在目录**，`[pwd]` 是调用者的 CWD。
   必须用脚本自身位置定位工程根：`set ROOT [file normalize [file dirname [info script]]]`。
   ⚠️ `run close` 会把 CWD 弹回调用目录 —— 收尾后用相对路径做的校验会全部失效。
3. **`.tcl` 文件不能带 UTF-8 BOM。** 带 BOM 时第一条命令会变成 `invalid command name "??oreach"`。
   写脚本时用无 BOM 的 UTF-8（本仓库 `tools/gowin/build.tcl` 已处理）。
4. **`-verilog_std` 的合法值只有 `v1995` | `v2001` | `sysv2017`。**
   写 `sysv2009` 会报 `unknown verilog language value` 并中断脚本。
5. **`-device_version B` 会被静默接受**，生成 `gw5ast138b-011` 的 B 硅片码流，而 part 仍写 `C1/I0`
   —— **零警告**，烧到 C 硅片上直接错。只有 A/NA/X 才报错。务必按板上实际选 B/C。
6. **缺 `.cst` 不报错**：I/O 会自动摆放且默认不报位置 → 静默错脚。
   构建后必须核对 `impl/pnr/<name>.pin.html` 里的引脚是否**确实是你要的**。
7. **`.sdc` 不支持反斜杠续行** → `TA2000 near token '\'`，pnr 失败。每条约束写一行。
8. **`TA1132`（时钟未创建）与 `PR1014`（时钟走通用布线）不在 `.rpt.txt` 里**，
   只在 console 输出和 `impl/pnr/<name>.log`。**检查告警必须看 log**，不能只看 rpt。
9. **`.fs` 字节数对该器件是常量**（本设计恒为 34 840 489 B）→ **文件大小没有鉴别力**，
   不能用来判断"构建成功"或"内容已更新"。要核 `LastWriteTime` + 引脚报告 + 资源报告。
10. **`open_project` 重跑会把产物名变成 `project.*`**（`-output_base_name` 不进 .gprj），
    且**旧 `<name>.fs` 不会被删** → CI 里会拿**陈旧码流**当成功。
    对策：每次构建前先删 `eda_proj/`（本仓库 `build.tcl` 的调用方已这么做）。
11. **没有 `-force` 且工程已存在** → `Project already exists on disk`；
    而 `-force` 会**清空文件列表**，必须重新 `add_file`。
12. **`gw_sh` 间歇往 stderr 打 OpenGL 错误** → PowerShell 里 `$ErrorActionPreference='Stop'`
    会**误杀构建**。别开 Stop。

补充：`create_project -dir <P>` 会创建 `<P>/<工程名>/` 并把工作目录切进去；`.gprj` 落在 `<P>/<工程名>/`。
`process_config.json` 与 `.gprj.user` **都不是构建必需**（删掉照跑并自动重建）。

---

## 2. ★ 交付可移植性（比赛要交作品，这条是交付级硬要求）

**Gowin 的 `.gprj` 天生绑死本机绝对路径，不可移植 —— 这是设计使然，无法规避。**
以下三条都经过对照实验（`fpga-tools` 做实验，`dsh-plugins` 复核前提）：

| 实验 | 结果 |
|---|---|
| `add_file` 传**相对路径** | ❌ 生成的 `.gprj` **仍被规范化成绝对路径** → 绕不过去 |
| 工程目录改名/移动后 `open_project …; run syn` | ❌ **硬失败 `ERROR (EX5998): Cannot open Verilog file '<旧绝对路径>'`** |
| 在**新位置重跑 `build.tcl`** | ✅ 成功，新 `.gprj` 指向新绝对路径 |

本项目的 `.gprj` 实测 **6 条全是绝对路径 / 0 条相对路径**，且路径含空格与用户名
（`C:/Users/Danny/Desktop/FPGA competition/...`）。

### 交付姿势（本项目结构本来就是对的，无需改代码）

**交付物 = 源码 + `.cst`/`.sdc` + `tools/gowin/build.tcl` + 已生成的 `.fs`。**
**`eda_proj/`、`out/` 视为可丢弃产物，绝不要把 `eda_proj/*.gprj` 当交付依赖。**

评委侧只需二选一：
1. 直接烧 `.fs`；
2. 在新机器上 `gw_sh.exe <路径>\build.tcl` 一键重建。

**前提（交付级硬要求）**：`build.tcl` 必须用 `[file dirname [info script]]` 定位 ROOT
（本项目 `build.tcl` L35 已符合）—— 这样脚本与 cwd 无关，换任何位置都能跑。

好消息：失败是**响亮的**（直接打印缺失的绝对路径 + EX5998），**不会静默用错文件**。

### 换机复现的 3 条前提（实验未覆盖，必须写进交付清单）

1. 评委机器上是否有 **Gowin 授权** —— 本机 license 绑本机网卡 MAC，**换机是全新的授权问题**；
2. 评委机器的 **Gowin 版本 / 器件库**是否兼容（本机 V1.9.12.04，器件库含 `GW5AST-138B/138C`）；
3. **`.fs` 是器件与版本相关的产物** —— 只解决"直接烧录"，不解决"需要重建"。

### 提交前自检

```powershell
# 调用 .ps1 必须带 Bypass（本机 ExecutionPolicy = AllSigned）
powershell -NoProfile -ExecutionPolicy Bypass -File `
  ".dsh\skills\fpga-verify\scripts\check_portability.ps1"
```

三态退出码：`0` 无 `.gprj` ／ **`3` 有绝对路径但有 `build.tcl` = 正常** ／
`1` 有绝对路径且找不到 `build.tcl` = 真风险。



## 2. 标准全链路脚本骨架

```tcl
set TOP    top
set PART   GW5AST-LV138PG484AC1/I0
set DEVVER C

set ROOT   [file normalize [file dirname [info script]]]
set PRJDIR [file join $ROOT eda_proj]
file mkdir $PRJDIR
cd $PRJDIR

create_project -name <name> -dir $PRJDIR -pn $PART -device_version $DEVVER -force
add_file -type verilog [file join $ROOT rtl top.v]
add_file -type cst     [file join $ROOT constr top.cst]
add_file -type sdc     [file join $ROOT constr top.sdc]

set_option -top_module     $TOP
set_option -synthesis_tool gowinsynthesis
set_option -output_base_name <name>

run syn
run pnr
run close
```

运行：`& "F:\Gowin\...\gw_sh.exe" "<绝对路径>\build.tcl"`

## 3. 产物路径

| 产物 | 路径 |
|---|---|
| 综合网表 | `eda_proj/<name>/impl/gwsynthesis/<name>.vg` |
| 综合报告 | `.../gwsynthesis/<name>_syn.rpt.html` |
| **bitstream** | `eda_proj/<name>/impl/pnr/<name>.fs`（138K 约 34 MB） |
| 时序报告 | `.../pnr/<name>.tr` / `<name>.tr.html` |
| PnR 报告（含资源占用） | `.../pnr/<name>.rpt.txt` |
| 引脚报告 | `.../pnr/<name>.pin.html` |
| 功耗报告 | `.../pnr/<name>.power.html` |

`run` 失败会以非零退出中断脚本；用 `catch {run syn} e` 可自行捕获并打印 `$e`。

## 4. Tang Mega 138K 引脚（已核对权威 .cst，勿猜）

```
clk        V22    50 MHz 板载有源晶振
led[0..3]  T18 R18 R17 P16    板载 LED，低有效
           （V13 无灯珠；U21 是 CPU/SSPI 专用脚，布局器会拒绝）
HP_BCK     Y17    PT8211 I2S 位时钟
HP_WS      AB17   PT8211 I2S 字选（左右声道）
HP_DIN     AA16   PT8211 I2S 数据
PA_EN      AB16   功放使能，低有效（拉低才出声）
```

TMDS/HDMI 差分对（若要用）：`tmds_d_p_0[0]=J14,H14`、`[1]=J15,H15`、`[2]=K17,J17`、`tmds_clk_p_0=G15,G16`，`IO_TYPE=LVCMOS33D`。

## 5. 必须写 SDC，否则只有 WARN 但不是"无问题"

不写 `.sdc` 时 `run pnr` 会报：
`WARN (TA1132): 'clk' was determined to be a clock but was not created.`

最小 SDC（`create_clock` 用端口名）：

```tcl
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]
set_false_path -to [get_ports {led[*]}]
set_false_path -to [get_ports {HP_BCK HP_WS HP_DIN PA_EN}]
```

注意：Gowin 的 SDC 解析器**不接受反斜杠续行**，每条约束写成一行。

## 6. 烧录

- GUI：`Gowin Programmer`（桌面快捷方式）。
- 固化到外部 Flash 推荐模式：`exFlash Erase,Program thru GAO-Bridge 5A`（需 ≥V1.9.11.03）。
- 命令行：`programmer_cli.exe`，先 `--help` 确认当前版本参数形态再写脚本；**不要凭记忆构造参数**。

## 7. 验证构建是否真的成功（不要只看退出码）

1. `<name>.fs` 存在且体积合理（非 0、非几百字节）。
2. 读 `<name>.rpt.txt` 的 `3. Resource Usage Summary`，确认 Logic/Register/BSRAM/DSP 占用与预期相符——**若某项为 0 而设计里显然用了它，说明被优化掉了或推断失败**。
3. 读 `<name>.tr.html` 确认无 setup/hold violation。
4. 确认 `WARN` 列表里没有 `TA1132`（未创建时钟）与 `PR1014`（时钟走通用布线，会带来过大偏斜）。

---

## §13 两个被实测推翻的旧说法（2026-10-03 更正）

### 13.1 `.fs` 大小**不是**器件常量 —— 旧说法作废

**旧结论（本 skill 早期写过）**：「`.fs` 大小在同一器件上是常量，没有区分力」。
**实测推翻**：同一器件 `GW5AST-138C`、同一工程：

| 设计 | `.fs` 大小 |
|---|---|
| 无 BSRAM（S0/S1 级） | **34 690 865 B** |
| 有 BSRAM（S2–S6 级） | **34 840 489 B** |

差 **149 624 B** ⇒ **`.fs` 大小能反映"是否用到了 BSRAM/大块存储"**，
但**仍然不能**用来判断"构建是否成功"或"烧的是不是最新版"（同配置下大小恒定）。
判据仍是：**mtime + 引脚报告 + 资源报告**，三者缺一不可。

### 13.2 顶层**不能**放在 `rtl/` 根目录（会被 `build.tcl` 的 glob 收走）

`build.tcl` 用 glob 收集源文件，形如：
```tcl
foreach f [lsort [glob -nocomplain "$ROOT/rtl/*/*.v"]] { add_file $f }
```
⇒ **`rtl/*/*.v` 只匹配"子目录里的 .v"**。若把冒烟测试顶层放在 `rtl/smoke_top.v`，
它**既不匹配 `rtl/*/*.v`（少一层）也不会**被误收 —— 但若有人写成 `rtl/*.v` glob，
根目录下的**每一个 `.v` 都会被收进正式构建**，包括测试顶层 → 出现多个顶层/多余告警。

**本项目的实际教训**：冒烟测试顶层最终放在 **`rtl/smoke/smoke_top.v`**（多一层子目录），
并**复刻 `build.tcl` 的收集逻辑验证**：正式工程收到 8 个 `.v`，**含 smoke 的 0 个**。
⇒ **规则：任何"平行实验"的顶层/模块，一律放进子目录，不要放 `rtl/` 根下。**

### 13.3 `ROM_PARALLEL` 类"默认值陷阱"（真实卡死事故）

**事故**：给 `tone_bank` 加了参数 `ROM_PARALLEL`（1 = 时分复用一份波形 ROM；
= N_VOICES 则每路一份），**默认值设成 32**，而顶层没有覆盖 →
综合日志出现：
```
Extracting RAM for identifier 'acc'(tone_bank.v:74)
WARN (EX1998): Net 'rom_val[15]' does not have a driver (tone_bank.v:131)
→ 停在 "Running device independent optimization"，不再输出，产不出 .fs
```
**根因**：参数选了"并行分支"后，**串行分支里的实例不存在**，而 `rom_val` 只在
串行实例的输出端口上有驱动 ⇒ 变成无驱动网络 ⇒ 优化阶段卡死。
（两个 teammate 各自独立复现：无该模块的构建 33 秒；有则卡 >5 分钟。）

**对策**：
1. **顶层必须显式传参**，不要依赖子模块默认值 —— 尤其当参数有"分支行为"时。
2. 参数化分支里，**每个分支都要保证其输出信号在另一分支下也有驱动**
   （或干脆把互斥信号声明在分支内部）。
3. **判据**：一条 `WARN ... does not have a driver` **绝不能放过** ——
   它可能不是警告，而是"综合器会卡死"的前兆。

### 13.4 多 Agent 并行下的版本纪律（本项目真实踩过）

**事故**：`board-smoke` 构建的中途，`adsr.v` 与 `top.v` 被其他 agent 修改
⇒ 它那批位流对应的**已不是最新源码**，结论**静默失效**。
同时仓库当时**零提交**，唯一一份 good 位流被删 ⇒ **没有任何回退路径**。

**规则**：
- **任何"已构建验证"的结论，必须附所依赖文件的字节数 + mtime（或 hash）**，
  否则该结论**不得作为取证材料**。
- 多 agent 并行时，**同一时刻只允许一个构建**；构建前先确认无残留 `gw_sh`。
- 权威源必须**纳入版本控制**（哪怕只在本地 commit），否则"可重生/可回退"都是空话。