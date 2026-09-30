# 2026年全国大学生嵌入式芯片与系统设计竞赛（FPGA创新赛道 - 高云半导体）
## 实时多音色合成电子乐器引擎

本项目采用**双独立工作区物理隔离架构**进行团队协作开发。硬件工程与算法模型分别位于独立文件夹下，各自自闭环，互不干扰、互不覆盖。

---

```text
嵌赛/
│
├── fpga_spark/                   # 【硬件工作区 - Spark】Tang Mega 60K 纯硬件工程与板级实测
│   ├── fpga_synthesizer.gprj     # 高云云源软件 (Gowin EDA) 完整工程文件
│   ├── rtl/                      # 纯硬件 Verilog 源代码 (DDS/ADSR/KS拨弦/调频/混音/I2S)
│   ├── constraints/              # Tang Mega 60K 物理引脚约束 (tang_mega_60k_pins.cst)
│   ├── sim/                      # 硬件行为级测试激励 (tb_synth_engine.v) 与定点仿真
│   ├── tools/                    # 波表 HEX 转换工具
│   ├── 原始音频/                  # 原曲试听与对比音频
│   ├── *.wav                     # 纯硬件模型生成的演示音频
│   └── README.md                 # 硬件系统技术指标与架构说明
│
├── fpga_ben/                     # 【算法与理论工作区 - Ben】Python 黄金参考模型与赛题材料
│   ├── sim/                      # Python 黄金参考模型 (synthsim) 及验证脚本
│   ├── 题目/                     # 赛题逐条精解、选型建议与外设准备清单
│   ├── 选题/                     # 2026 嵌赛各赛道官方指南 PDF 资料
│   ├── 原题目-高云半导体赛道...md   # 赛题原始说明文档
│   └── .vscode/                  # Python 解释器配置
│
├── .agents/                      # 团队协同与隔离常驻规则（永久生效）
├── .gitignore                    # 全局忽略配置
└── README.md                     # 团队协同与分工总览说明（本文档）
```

---

## 👥 团队分工与工作范围明细

### 📌 致队友 Ben 的工作范围说明 (`fpga_ben/`)

> **工作根目录**：`fpga_ben/`（请在此目录下进行所有算法建模、脚本运行与文档维护）

1. **Python 黄金参考算法模型 (`fpga_ben/sim/synthsim/`)**：
   * 负责音色合成算法的前期探索与数学建模，包括 DDS 波表发生器、指数/多段 ADSR 包络生成、多声部动态复音分配器（Allocator & LRU 策略）、饱和混音器（Mixer）以及 DSP 音频效果器（Chorus 合唱、Ping-pong Delay 延迟、Schroeder Reverb 混响）。
   * 负责算法定点化位宽分析、量化信噪比评估、理论延迟与资源预估。

2. **算法集成与音色验证脚本 (`fpga_ben/sim/scripts/`)**：
   * 负责维护音色演示例程（管风琴、八音盒、电钢琴、FM 音色等）及自动化评测脚本（`run_all.py`、`realtime_demo.py`、`demo_timbres.py`）。
   * 负责输出算法层面对齐文档（如 `sim/前期算法模拟-完整说明.md`、`sim/synthsim/CONTRACT.md`）。

3. **硬件与算法接口定义与参数导出**：
   * 负责将验证良好的音色配置、谐波系数、包络参数导出为结构化数据（如参数头文件或定点化系数表），供硬件端直接映射与使用。

4. **赛题分析与选题论证 (`fpga_ben/题目/`、`fpga_ben/选题/`)**：
   * 负责高云赛题指标深度拆解、评分要点对齐、外设准备方案与竞赛答辩材料论证。

---

### 📌 队友 Spark 的工作范围说明 (`fpga_spark/`)

> **工作根目录**：`fpga_spark/`（负责全部底层硬件逻辑与板级工程）

1. **FPGA 纯硬件逻辑实现 (`fpga_spark/rtl/`)**：
   * 负责基于高云 GW5AT-LV60 架构的纯 Verilog 硬件电路实现，涵盖多复音 DDS 振荡器、硬件指数型 ADSR 状态机、Karplus-Strong 拨弦物理建模引擎、加法合成器、饱和加法混音器以及 24-bit 48kHz I2S 硬件音频驱动。
2. **EDA 工程构建与约束 (`fpga_spark/constraints/`、`fpga_synthesizer.gprj`)**：
   * 负责高云云源软件工程的配置管理、引脚分配、物理约束与时序收敛。
3. **硬件仿真与音频实测 (`fpga_spark/sim/`、`*.wav`)**：
   * 负责硬件 Testbench（`tb_synth_engine.v`）编写、与 DAC（PCM5102A）硬件联调及实录音频产出。

---

## ⚠️ 团队协同与防冲突守则

1. **工作区边界清晰**：
   * 算法探索、Python 代码及文档材料请严格限制在 `fpga_ben/` 内编辑与提交。
   * 硬件 RTL 代码、约束文件（`.cst`）及高云工程文件（`.gprj`）请严格限制在 `fpga_spark/` 内编辑与提交。
2. **禁止跨区覆盖**：
   * 双方请勿直接修改对方目录下的源代码与配置文件，杜绝因路径变更导致高云 EDA 编译失败或 Python 环境报错。
3. **接口交接机制**：
   * 算法端如需向硬件端同步新算法参数或波表数据，请在 `fpga_ben/` 中导出并通知 Spark，由 Spark 侧确认后引入 `fpga_spark/` 中进行硬件映射与上板综合。
4. **Git 提交原则**：
   * `git add` 时请优先指定各自的子目录（如 `git add fpga_ben/` 或 `git add fpga_spark/`），避免一次性 `git add .` 导致非意图文件混入提交。
