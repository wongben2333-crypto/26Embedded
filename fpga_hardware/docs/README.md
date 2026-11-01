# FPGA 乐器硬件文档入口

> 整理日期：2026-10-28  
> 当前工程：Tang Mega 60K + 13 键 + 6 光电 + 2 ToF + 4 EC11  
> 当前阶段：面包板链路已验证，PCB 与整壳已通过数字检查，实体首件未制造

## 1. 先看这里

本目录只把五份文档作为当前设计主线。遇到冲突时按以下优先级判断：

1. 实际 PCB Gerber、真实 3D STEP 和硬件实测。
2. [HARDWARE-DESIGN-SPEC.md](HARDWARE-DESIGN-SPEC.md)：整机意图和硬约束。
3. [PCB-DESIGN.md](PCB-DESIGN.md)、[ENCLOSURE-DESIGN.md](ENCLOSURE-DESIGN.md)：
   当前板级和机械事实。
4. [BREADBOARD-BRINGUP.md](BREADBOARD-BRINGUP.md)：历史验证链与迁移原因。
5. `archive/`：旧方案，只用于追溯，不应当作当前设计输入。

## 2. 主文档

| 文档 | 回答什么问题 |
|---|---|
| [HARDWARE-DESIGN-SPEC.md](HARDWARE-DESIGN-SPEC.md) | 整机怎么组成、为什么这样分层、电源/信号/组件边界、哪些已验收、哪些未闭环 |
| [BREADBOARD-BRINGUP.md](BREADBOARD-BRINGUP.md) | 面包板如何接、实测看到什么、I2C/ToF/事件速率踩过哪些坑、如何迁移到 PCB |
| [PCB-DESIGN.md](PCB-DESIGN.md) | 100×70 PCB 的接口、13 键坐标、PC817、两条 ToF 总线、EC11、布局、制造包缺口 |
| [ENCLOSURE-DESIGN.md](ENCLOSURE-DESIGN.md) | 两件式整壳、键床、双导柱、ToF 上下分件、40P 和前侧窗口、装配顺序、DfAM |
| [MANUFACTURING-AND-ACCEPTANCE.md](MANUFACTURING-AND-ACCEPTANCE.md) | 采购、PCB 下单、PCBA、PETG 打印、首件装配和逐项验收 |

## 3. 专项参考

这些文件保留得更细，但只解释一个方面：

| 文件 | 用途 |
|---|---|
| [NETLIST.md](NETLIST.md)、[netlist.csv](netlist.csv)、[netlist.dot](netlist.dot) | FPGA 球号、J13/J8/J9 逐针和机器可读网表 |
| [PCB-SCHEMATIC-SPEC.md](PCB-SCHEMATIC-SPEC.md) | 嘉立创 EDA 原理图分页、逐通道接法和网络命名 |
| [PCB-POWER-ESD.md](PCB-POWER-ESD.md) | 可选保护/ESD 增强方案；不等于当前已装 BOM |
| [TOF-VB22B-PROTOCOL.md](TOF-VB22B-PROTOCOL.md) | VB22B 地址、寄存器、突发读字节序和电气实测 |
| [INSTRUMENT-MAPPING.md](INSTRUMENT-MAPPING.md) | 音符、光电“弦”、ToF、EC11 和 8 声部仲裁语义 |
| [../enclosure/MODELING-NOTES.md](../enclosure/MODELING-NOTES.md) | CAD 参数、原始 STL 检查、DfAM 实测和输出文件说明 |
| [../enclosure/MODIFICATION-2026-10-28.md](../enclosure/MODIFICATION-2026-10-28.md) | 本次硬件确认版的外壳改动、复检数据和打印说明 |
| [../enclosure/src/README.md](../enclosure/src/README.md) | 参数化 CAD 脚本、生成命令和输出文件 |

## 4. 当前已冻结的关键事实

- 主控：Tang Mega 60K Dock，GW5AT-60B。
- 音频：底板 PT8211；自制板不重做音频。
- 13 键：C4–C5，8 白 + 5 黑；开关总高 5.0 mm，行程约 2.0 mm。
- 光电：6 路 E3F-20C1，12 V；PCB 用 6×PC817 隔离。
- ToF：2×VB22B，31×15×6.2 mm，双轴向上，各自独立 I2C，地址均为 0x52。
- 编码器：4×EC11，A/B 正交，无按压。
- PCB：100×70×1.6 mm，R3，4 个 Ø3.4 mm 安装孔。
- 外壳：下壳 130×109×22.124 mm；上壳主平面 140×109×26.2 mm，
  40P 局部拱盖最高 Z=27.0；PCB 完全内置。
- 键床：98×53.575×2 mm，键盘开口 97×49.5 mm；开关口袋 9.2×8.3 mm，
  底面焊盘让位 10.6×10.6×0.8 mm。
- 键床定位：4 个 Ø1.6 mm 定位柱进入上盖 Ø2.0 mm 盲孔，不再抵靠 J13。
- 强制装配：安装键床前，H5 朝上残留引脚必须剪平至 PCB 上表面或更低。
- 固定：M3 塑料自攻螺丝；上下壳 M3×10，PCB M3×8；底孔 Ø2.5。
- 40P：J13/CN2 实际包络 58.4×8.91×12.2；后口 56.8×12，
  可让两端预压接的标准 IDC 插头通过。
- ToF 分件：下壳保留下段筒和线缆，上壳只保留 Z=22.124 以上的上段筒。

## 5. 仍未闭环

- 键床水平定位已建模，但垂直防上跳和首件插拔手感仍需实物验证。
- 开关正式封装、柱塞截面和键帽锁合仍需实物确认。
- Gerber 双钻孔文件有 479 个重复坐标，缺 ERC/DRC、BOM、坐标和装配图。
- 实际 IDC 附件、线缆最小弯曲半径、压线片硬件和 EC11 面板未选型。
- ToF 镜头中心、安装孔/卡槽和四芯线弯曲半径仍需实物复核。
- PCB、整壳和线束尚未进行实体首件装配。
- PCB 已规划的光电 2–6、EC2–EC4 和 ToF B 尚未完成固件闭环。

## 6. 阅读路径

想复现实验：从 `BREADBOARD-BRINGUP.md` 开始，再看 `NETLIST.md`。  
想改 PCB：先读 `HARDWARE-DESIGN-SPEC.md`，再读 `PCB-DESIGN.md` 和
`PCB-SCHEMATIC-SPEC.md`。  
想改外壳：读 `ENCLOSURE-DESIGN.md`，再到 `../enclosure/MODELING-NOTES.md`
核对参数和检查脚本。  
想下单或装配：按 `MANUFACTURING-AND-ACCEPTANCE.md` 的放行表逐项签字，不要只看
数字检查 PASS。

旧设计说明、启动提示词、S5 交接和 R1–R5 Gerber 审查已移入
[archive/README.md](archive/README.md)；旧文件没有删除。
