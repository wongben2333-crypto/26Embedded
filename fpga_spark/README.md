# 基于 FPGA 的实时多音色合成电子乐器引擎
## 2026年全国大学生嵌入式芯片与系统设计竞赛（FPGA 创新设计赛道 - 高云半导体）

### 一、工作区结构与目录指引 (Spark 专属目录)

本工程已完成阶段性重构：原 `lcd_test` 已完整归档封存，现 `lcd_test/` 目录已全面升级为最新的 32 复音 TDM 架构与 7 寸大屏电容触控系统。

```text
fpga_spark/
├── lcd_test/                 # 【主工程】升级后的 32 复音 TDM 合成器与 7 寸大屏触控系统
│   ├── lcd_test_j14.gprj     # Gowin EDA 图形界面工程文件 (双击打开)
│   ├── burn_lcd_j14.py       # 一键烧录位流至板载 SRAM
│   ├── build_j14.py          # 一键自动综合与布局布线 (gw_sh)
│   ├── rtl/                  # Verilog 纯硬件源码 (top, synth, audio, effects, ui, io)
│   ├── constraints/          # 物理引脚约束与 50MHz 时钟约束 (lcd_test_j14.cst / sdc)
│   ├── host/                 # 上位机 Python 控制台 (piano_gui.py)
│   ├── bitstream/            # 已验证最新位流 (lcd_test_j14.fs, 39.3MB)
│   └── tools/                # 编译与测试工具链
│
├── archive/                  # 【历史工程归档】原 Spark lcd_test 封存包
│   ├── ARCHIVE_MANIFEST.md   # 归档清单与详细说明
│   ├── fpga_spark_lcd_test_backup_20261102.zip # 完整压缩备份 (~91 MB)
│   └── lcd_test_spark_v1_backup/               # 解压镜像目录 (含全部源码/约束/位流/文档)
│
├── P34-P40转接板/            # 7寸屏转接板 PCB 原理图与制造包
└── docs/                     # 硬件设计与引脚核对文档
```

### 二、核心系统特性
* **主控平台**：高云 GW5AST-LV138PG484AC1/I0 (Tang Mega 138K Dock，兼容 GW5AT-60B 核心逻辑)
* **合成架构**：32 复音 $\times$ 6 泛音 = 192 独立物理振荡器，单正弦 ROM 4 级流水线时分复用
* **音频指标**：97.656 kHz 物理采样率、PT8211 16-bit 双声道高清无杂音输出
* **乐器音色库**：大钢琴 (Grand Piano)、原声吉他 (Acoustic Guitar)、小提琴 (Violin，渐进揉弦+滑音连奏)、二胡 (Erhu)
* **纯硬件效果器链**：Freeverb 混响、立体声合唱 (Chorus)、乒乓延迟 (Delay)、过载失真与 4x12 箱体模拟
* **7 寸 800×480 大屏 UI**：纯硬件 16×16 中文字符点阵引擎、多页面实时显示（状态看板、乐谱瀑布流、3.0s 双缓冲示波器、32 通道硬件 FFT 频谱仪、李萨如图）
* **电容触摸键盘**：Goodix GT911 / FocalTech FT5206 硬件 I2C 轮询驱动，支持琴键点按、滑音连奏与选项卡触控
