# 基于 FPGA 的实时多音色合成电子乐器引擎
## 2026年全国大学生嵌入式芯片与系统设计竞赛（FPGA 创新设计赛道 - 高云半导体）

### 一、项目定位与目标
本项目基于高云 **GW5AT-LV60PG484A (Tang Mega 60K)** 平台，构建一套具备超低延迟（$< 0.3\text{ms}$）、超高复音吞吐量（64独立物理振荡器并发）的纯硬件多音色电子乐器系统。

### 二、目录结构规划
```text
嵌赛/
├── docs/                     # 设计文档、赛题指南与答辩资料
├── rtl/                      # 纯硬件 Verilog/SystemVerilog 源代码
│   ├── top/                  # 顶层集成模块
│   ├── interaction/          # 传感器采集、去抖动与表情解析 (Touch/FSR/TOF/Ribbon)
│   ├── voice_alloc/          # 多复音声部动态调度器 (Voice Allocator & LRU Stealing)
│   ├── synth_core/           # 实时合成引擎核心
│   │   ├── dds_wavetable/    # DDS 多波表与减法滤波引擎
│   │   ├── fm_synth/         # 2-Op/4-Op 调频合成引擎
│   │   ├── physical_ks/      # Karplus-Strong 拨弦物理建模引擎
│   │   ├── additive_synth/   # 64路加法谐波合成引擎
│   │   └── adsr/             # 指数型高精度 ADSR 包络发生器
│   ├── dsp_fx/               # 纯硬件音频效果器 (Reverb, Delay, Chorus)
│   ├── audio_out/            # 24-bit 48kHz I2S 发送控制器与饱和混音器
│   ├── visual/               # HDMI 720P 显控驱动与硬件 FFT 实时频谱仪
│   └── comm/                 # 蓝牙 UART 通信与脱机乐谱流控制器
├── sim/                      # 仿真测试激励与 Python 验证脚本
├── tools/                    # 波表数据生成脚本 (Python Wavetable Gen)
└── constraints/              # 物理管脚约束文件 (.cst) 与时序约束 (.sdc)
```

### 三、关键技术指标一览
* **主控芯片**：高云 GW5AT-LV60PG484A (Tang Mega 60K)
* **主音频采样率**：$48\text{kHz}$，24-bit 立体声输出
* **音频 DAC**：PCM5102A (I2S 接口)
* **物理复音数**：32 复音 $\times$ 双振荡器 = 64 独立物理振荡器
* **端到端响应延迟**：$< 0.3\text{ms}$（实测示波器抓取）
* **合成算法支持**：DDS 波表、FM 调频、Karplus-Strong 物理建模拨弦、64 路加法合成
* **效果器集成**：Schroeder 混响、乒乓延迟、立体声合唱
* **视听显示**：板载 HDMI 720P 实时波形示波器 + 64-bin 硬件 FFT 频谱柱状图 + 李萨如图形 + WS2812 瀑布指引灯

详细系统架构全案请查阅详细设计方案。
