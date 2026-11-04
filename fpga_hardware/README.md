> **平台与状态（2026-11-04）**：最终整机 138K，60K 仅作早期 bring-up；PCB1、贴装、两件式 PETG 外壳已制造并完成整机联调；13 键、6 路光电、双路 ToF（A 主/B 热备）、7 寸触控均已实测；4 路 EC11 仅预留，不参与评分口径。PCB1 定位为“输入调理与隔离转接板”（上拉/限流/RC/PC817/ToF 供电/地分割），防爆音在 RTL+PA_EN，不在 PCB。

# fpga_hardware —— 硬件乐器（Tang Mega 138K；60K 为早期 bring-up）

> **这是什么**：面向 13 键、6 路对射光电、2 只 VB22B ToF 和 4 只预留 EC11 的
> Tang Mega 138K（60K 为早期 bring-up）输入调理与隔离转接板与两件式整壳。FPGA 运行 MODE=3 的 hank
> **TDM32 32 声部×6 泛音=192 路合成**，音频使用底板 PT8211，整机不依赖电脑。
> **当前状态**：2026-10-24 面包板/真板控制链路验收通过；PCB 与整壳已完成
> 数字回装，实体首件已制造并装配。当前权威硬件文档从 `docs/README.md` 进入。
>
> **与 `fpga_hank/` 的关系**：本目录是 `fpga_hank/rtl` 的**整份副本 + 改动**（团队约定：
> 上游只读、改动整份复制）。上游后续变更需要手工合并。**只有两处不同**：
> `rtl/top.v`（MODE=3 通路、5 处改动）与 `rtl/io/`（新增 `hw_input_mgr.v`、
> 复用 `i2c_master.v` / `uart_tx.v`）。

---

## 1. 三分钟上手

```powershell
$EDA = "D:\all soft\Gowin\Gowin_V1.9.12_x64"
$CLI = "$EDA\Programmer\bin\programmer_cli.exe"

# 构建（产物在 eda_proj/，位流自动归档到 out/bitstream/）
& "$EDA\IDE\bin\gw_sh.exe" "E:\26Embedded\fpga_hardware\build.tcl"

# 仿真（hw_input_mgr 自检，43 项 + I2C 从机 BFM）
powershell -NoProfile -ExecutionPolicy Bypass -File "E:\26Embedded\fpga_hardware\sim\run.ps1"

# 烧录（SRAM，掉电即失；不要用 --operation_index 4）
& $CLI --device GW5AT-60B `
    --fsFile "E:\26Embedded\fpga_hardware\out\bitstream\<归档文件名>.fs" `
    --operation_index 2 --frequency 2.5MHz
```

调试串口：**COM12**（P19 → USB-TTL，115200，3.3V 档），每 40 ms 一行：

```
K=1FFF P=3F A=0398 V=64 N=000000 O=00 @0000xxxx
K 13键电平(按下=0)  P 6光电(挡光=0)  A ToF距离mm(FFFF=NACK)
V 音量(0..127)      N 最近事件(90/80 note vel)   O FIFO阻塞计数(应为00)
```

---

## 2. 接线（全部 3.3 V；J13 第 11 脚是 5V，绝不能接）

| 功能 | 针/球 | 说明 |
|---|---|---|
| key[0..12] | J13 1–10,13,14,15（E14 E13 C15 C14 B13 C13 A14 A13 B16 B15 A16 A15 A20） | 按下=0，内部上拉 |
| photo[0..5] | J13 16–21（B20 A21 B21 B18 B17 C17） | 挡光=0；面包板原型用 S9012，PCB v1 用 PC817 |
| EC11 #1 A/B | J13-22 / J13-23（D17 / A19） | 正交，RTL 内 1 kHz 邻接解码 |
| **ToF #1 SCL** | **J13-24（A18）** | **4.7k 上拉 + 330Ω 串联** |
| **ToF #1 SDA** | **J13-25（D15）** | 同上 |
| 调试 TX | P19（J9-11） | 需 `set_option -use_cpu_as_gpio 1`（build.tcl 已加） |

> ⚠️ **I2C 不要再用 J8（AB22/Y21）**：那组球与音频 I2S 同属 BANK7，10 kHz 会把 DAC
> 搅成尖锐噪声。挪到 J13-24/25 后 10 kHz 全速也完全干净（已实测）。
> 详见 `docs/BREADBOARD-BRINGUP.md` §6.1。

## 3. 演奏语义（MODE=3）

| 输入 | 事件 | 备注 |
|---|---|---|
| 13 键 | note-on/off 60..72（C4..C5），vel 100 | 查表，可整体移调 |
| 光电 #1 | 挡光 = on 40（E2），松开 = off，vel 110 | 2ms/8ms 非对称去抖 |
| ToF #1 | 10–70 cm → note 60..84；入场驻留 3 采样；换音 = off+on，**≥180 ms 限速**；>800 mm 持续 200 ms 或 NACK 500 ms 离场 | 5 点中值 + ±2 cm 迟滞；24 mm/半音 |
| EC11 #1 | 音量 0..127（每格 4 步），dB 感知 LUT（0=静音，127=直通） | 混音后一级增益，1 个 16×16 乘法器 |

**事件串行化 ≥16 clk（320 ns）**：引擎装载一个音符要 14 个时钟节拍且没有输入队列，
喂快会直接丢音。**ToF 不使用引擎滑音**（`glide_on` 复用全局 `last_voice`，会偷走
正在响的键声部）。

## 4. 验收结论（2026-10-24）

| 项 | 结果 |
|---|---|
| 构建 | 无 ERROR / archived / `=== DONE ===`；Setup **+0.033** / Hold **+0.136** |
| 资源 | Logic 22 807/59 904（39%）、BSRAM 60/118、**DSP 79/118** |
| 13 键 | C4..C5 全部正确（用户听感 + 遥测 60..72 全出现） |
| 8 键和弦 + 第 9 键 | 全响、最旧声部被抢占、不卡死 |
| 光电 E2 / ToF 分段滑升 / EC11 音量 | 均正常（用户确认） |
| 上电 20 次 | 无随机发声（另有 9/9 安静环境复测） |
| MODE=1 回归 | 从本目录源码构建 + `90 45 64` → 440 Hz「非常好」；`piano_gui.py --selftest` PASS |

最终位流（`_work_60k/out/bitstream/` 归档，不入库）：
`MODE3_mode3_60K_20261024-012557.fs`（User Code `0x1A2B0003`，sha16 `882132D453E6E483`）。

## 5. 文档

完整入口见 **`docs/README.md`**。当前硬件事实分成五份主线文档：

| 文件 | 内容 |
|---|---|
| **`docs/HARDWARE-DESIGN-SPEC.md`** | 整机架构、具体部件、电源域、演奏语义、已验收/未闭环边界 |
| **`docs/BREADBOARD-BRINGUP.md`** | 面包板接线、S9012 过渡方案、遥测、实测结论和故障表 |
| **`docs/PCB-DESIGN.md`** | 成品 PCB 板框、J13 网表、13 键坐标、PC817、双 ToF 总线、制造包风险 |
| **`docs/ENCLOSURE-DESIGN.md`** | 两件式外壳、键床、防倾斜导柱、ToF 上下分件、40P/线缆窗、打印检查 |
| **`docs/MANUFACTURING-AND-ACCEPTANCE.md`** | PCB/PCBA/外壳下单、采购、首件装配和验收门槛 |
| `docs/NETLIST.md` | 详细 FPGA 球号与逐针连接；配套 `netlist.csv`、`netlist.dot` |
| `docs/PCB-SCHEMATIC-SPEC.md` | 嘉立创 EDA 原理图分页和逐通道接法 |
| `docs/PCB-POWER-ESD.md` | 可选保护/ESD 增强方案，不代表当前已装器件 |
| `docs/INSTRUMENT-MAPPING.md` | 音符、光电“弦”、ToF、EC11 与 TDM32 32 声部仲裁语义 |
| `docs/TOF-VB22B-PROTOCOL.md` | VB22B 地址、寄存器、突发读字节序和实测坑 |
| `enclosure/MODELING-NOTES.md` | CAD 参数、原 STL 检查、DfAM 和输出文件 |
| `enclosure/MODIFICATION-2026-10-28.md` | 本轮硬件确认后的外壳修改、复检结果和打印说明 |

早期提示词、S5 交接、旧外壳说明和 Gerber R1–R5 审查已归档到
`docs/archive/`，原内容未删除；它们只作为历史证据使用。

## 6. 注意事项

1. **SRAM 掉电即失**：每次重新上电要重烧；固化 Flash 需先获得用户同意（`--operation_index 9`）。
2. **不要用 `--operation_index 4`**（本板族回读校验不可用，必然假报 Verify failed）。
3. **`.tcl`/`.v` 不得带 BOM**；`build.tcl` 必须保持纯 ASCII（Gowin 按系统 GBK 读）。
4. **DSP 只剩约 13 个余量**（开启颤音/滑音时会回到 ~104.5/118），加音色前先查资源。
5. 本机 Gowin P&R 偶发"布线冻结"：无进展 5–10 min 就杀进程重试（换种子常可过）。
