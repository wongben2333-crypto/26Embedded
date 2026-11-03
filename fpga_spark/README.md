# 基于高云 FPGA 的实时多模态物理建模智能乐器与大屏交互系统
## 2026年全国大学生嵌入式芯片与系统设计竞赛（FPGA 创新设计赛道 - 高云半导体）

> **开发分支与工作区**：`fpga_spark`  
> **核心芯片**：高云半导体 Arora V 系列 `GW5AST-LV138PG484AC1/I0`（`GW5AST-138C`，Tang Mega 138K Dock，兼容 GW5AT-60B 核心逻辑）  
> **显示与触控**：7 英寸 800×480 ATK-MD0700 电容触摸大屏（SSD1963 16-bit 8080 + Goodix GT911 / FT5206 硬件 I2C）  
> **音频数模输出**：PT8211 Dual 16-bit DAC（97.656 kHz 物理采样率，3.5mm 耳机 + 板载双声道 2×3W 扬声器功放）  
> **最新关键进展**：**自研 PCB 硬件电阻错焊故障已完全排查修复，J13 硬件乐器外设（13 键键盘 + 6 弦光电吉他 + 激光 ToF 特雷门琴 + EC11 旋钮）全链路打通并完成实机声学验证！**

---

### 一、 工作区架构与工程目录指引

```text
fpga_spark/
├── lcd_test/                     # 【主工程】32 复音 TDM 多音色合成器 + 7 寸大屏触控系统
│   ├── lcd_test_j14.gprj         # Gowin EDA 工程主文件 (双击直接打开)
│   ├── build_j14.py              # 一键自动化综合、布局布线脚本 (gw_sh)
│   ├── burn_lcd_j14.py           # 一键烧录已编译位流至板载 SRAM
│   ├── rtl/                      # 纯硬件 Verilog 源码
│   │   ├── top.v                 # 顶层集成 (MODE=3 全模态乐器，MODE=0 曲库演示，MODE=1 电脑控制)
│   │   ├── synth/                # 32 复音 TDM 核心、谐波正弦 ROM、流水线 ADSR 包络引擎
│   │   ├── audio/                # PT8211 97.656 kHz 高速立体声 I2S 驱动
│   │   ├── effects/              # Freeverb 混响、立体声合唱、乒乓延迟、电吉他过载与 4x12 箱体模拟
│   │   ├── ui/                   # SSD1963 8080 并行驱动、硬件汉字引擎、示波器/频谱仪双缓冲系统
│   │   └── io/                   # 硬件外设管理器 (按键去抖、光电弦判决、双 ToF I2C 轮询、EC11正交解码)
│   ├── constraints/              # 物理引脚约束与 50MHz 时钟约束 (lcd_test_j14.cst / sdc)
│   ├── bitstream/                # 最新实机验证生成的位流 (lcd_test_j14.fs)
│   ├── docs/                     # 系统使用手册与技术规范
│   │   └── USER_MANUAL.md        # 【权威用户手册】详细引脚定义、操作与演奏指南
│   └── host/                     # 上位机 Python 控制台与测试工具 (piano_gui.py)
│
├── tof_debug/                    # 【专用调试工程】ToF 激光测距与双总线 I2C 探测系统
│   ├── eda_proj/                 # Gowin EDA 工程文件 (tof_debug.gprj，编译极速，仅约 25 秒)
│   ├── rtl/                      # 纯硬件轻量级源码 (双总线 0x08~0x77 扫描器、SSD1963 直显 UI、UART)
│   ├── constr/                   # J13 引脚约束 (tof_debug.cst / sdc)
│   ├── bitstream/                # 预编译生成的调试位流 (tof_debug.fs)
│   ├── build.py / burn.py        # 一键快速编译与下载工具
│   ├── tof_monitor.py            # PC 终端实时彩色动态监视器
│   └── README.md                 # 调试工程专属使用与协议文档
│
├── docs/                         # 系统设计、引脚核对与联调归档
│   ├── HARDWARE-BRINGUP-LOG-20261103.md # 【最新】硬件故障排查、错焊修复与联调全记录
│   ├── 60K_硬件资源核对.md        # 资源占用与跨平台适配报告
│   └── LCD引脚表-ATK-MD0700-34P_to_J13-40P.md # 屏幕引脚定义
│
├── archive/                      # 【历史工程归档】原 Spark lcd_test 基础工程封存包
│   ├── ARCHIVE_MANIFEST.md       # 归档清单与详细说明
│   ├── fpga_spark_lcd_test_backup_20261102.zip # 完整压缩备份 (~91 MB)
│   └── lcd_test_spark_v1_backup/ # 解压镜像目录 (含全部源码/约束/位流/文档)
│
└── P34-P40转接板/                # 7寸大屏转接板 PCB 原理图、PCB 工程与制造 Gerber 包
```

---

### 二、 核心系统技术指标与创新点

| 维度 | 指标参数 | 架构实现与技术创新 |
| :--- | :--- | :--- |
| **合成规模** | **32 复音 $\times$ 6 谐波 = 192 振荡器** | 单正弦波表 4 级流水线时分复用（TDM），零 DSP 乘法器爆炸 |
| **音频保真度** | **97.656 kHz @ 16-bit 双声道** | 板载 PT8211 芯片驱动，全流水线无阻塞运算，信噪比高、零爆音 |
| **乐器音色库** | **大钢琴、原声吉他、小提琴、二胡** | 包含高次谐波衰减拟真、拉弦摩擦非线性共鸣、渐进揉弦与滑音连奏 |
| **纯硬件效果器** | **Freeverb、合唱、乒乓延迟、箱体模拟** | 8 路并联梳状滤波 + 4 路全通滤波空间混响，电吉他专用 4x12 密闭箱体 IIR 模拟 |
| **多模态外设** | **13 琴键 + 6 光电弦 + 激光 ToF + 旋钮** | 支持键盘和弦演奏、光学吉他拨弦、手势空间高低音控制、触感旋钮音量调节 |
| **7 寸仪器大屏** | **800×480 @ 16-bit 8080 并行总线** | 纯 RTL 硬件驱动，包含 16×16 汉字引擎、3.0 秒双缓冲滚动示波器、32 通道硬件 FFT 频谱柱、李萨如图 |
| **电容触控交互** | **80 Hz 硬件 I2C 轮询电容屏** | 支持大屏虚拟键盘点击、音符滑音、选项卡切页与触控音量推子调节 |

---

### 三、 最新硬件故障排查与闭环成果 (2026-11-03)

在真机联调阶段，团队经历了由“面包板验证”到“定制 PCB 实装”的硬件故障闭环：
1. **故障现象**：烧录最新主工程位流后，13 键键盘（钢琴）与 6 路光电弦（吉他）发声完全正常，唯独激光 ToF 空间特雷门琴没有任何反应，上位机串口持续报告 I2C `NACK`。
2. **根因定位**：
   - 深入对比自研 PCB 原理图网表（`Netlist_Schematic1_2026-10-24.tel`）与面包板实测接线；
   - 查出 PCB 上 I2C 相关的限流与上拉电阻存在元器件**阻值错焊**，导致总线无法正确下拉或电平失常；
   - 明确了 Tang Mega 138K 底板 J13 排针无 3.3V 输出、自研 PCB 需由 `H3` 端子输入 3.3V 的电气规则。
3. **闭环修复**：
   - 硬件端已重新焊装更换了正确阻值的电阻，排除了硬件短路与错位问题；
   - 固件端提供了专用的 `tof_debug/` 双总线快速扫描调试系统，并为主工程配置了双总线（Bus 1: `A18/D15`，Bus 2: `F14/F13`）自适应轮询逻辑；
   - **实测验证**：ToF 传感器在 10~70cm 范围内距离响应极速、测量精准，特雷门琴空间发声与滑音手势完全恢复正常！

---

### 四、 快速上手与操作指南

#### 1. 运行主乐器工程 (`lcd_test`)
```powershell
# 1. 进入主工程目录
cd "c:\Users\gjl50\Desktop\FPGA\fpga_spark\lcd_test"

# 2. 一键烧录到 Tang Mega 138K SRAM
python burn_lcd_j14.py

# 3. 运行上位机交互控制面板（可选）
cd host
python piano_gui.py --autoconnect
```

#### 2. 运行专用 ToF 调试工程 (`tof_debug`)
当需要对 ToF 传感器进行单独测试或验证新批次模块时：
```powershell
cd "c:\Users\gjl50\Desktop\FPGA\fpga_spark\tof_debug"

# 极速重新编译（约 20 秒）
python build.py

# 烧录调试固件
python burn.py

# 开启终端彩色动态实时监控
python tof_monitor.py COM8
```

---

### 五、 文档索引

- **系统使用与操作手册**：[`lcd_test/docs/USER_MANUAL.md`](file:///C:/Users/gjl50/Desktop/FPGA/fpga_spark/lcd_test/docs/USER_MANUAL.md)
- **硬件联调与故障排除记录**：[`docs/HARDWARE-BRINGUP-LOG-20261103.md`](file:///C:/Users/gjl50/Desktop/FPGA/fpga_spark/docs/HARDWARE-BRINGUP-LOG-20261103.md)
- **ToF 调试工程专属说明**：[`tof_debug/README.md`](file:///C:/Users/gjl50/Desktop/FPGA/fpga_spark/tof_debug/README.md)
- **历史工程归档清单**：[`archive/ARCHIVE_MANIFEST.md`](file:///C:/Users/gjl50/Desktop/FPGA/fpga_spark/archive/ARCHIVE_MANIFEST.md)
