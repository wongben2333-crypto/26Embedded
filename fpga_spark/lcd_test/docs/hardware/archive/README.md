# 历史硬件文档归档

本目录保留旧版本，目的是追溯设计取舍、实测证据和 Gerber 修订过程。这里的内容
不是当前设计输入；若与当前五份主文档冲突，以主文档和实际 Gerber/STEP 为准。

## 替代关系

| 归档文件 | 现在应看什么 | 归档原因 |
|---|---|---|
| `ENCLOSURE-DESIGN-BRIEF.md` | [../ENCLOSURE-DESIGN.md](../ENCLOSURE-DESIGN.md) | 含旧 21×15×7.43 ToF、一横一上、三件式/热熔螺母等已被替换内容 |
| `SHELL-TASK-PROMPT.md` | 同上 | 初始 CAD 任务提示词，不是最终设计 |
| `SHELL-TOF-SPLIT-R6.md` | 同上 | 最终分件原则已吸收；保留 R6 的检查证据 |
| `PCB-TASK-PROMPT.md` | [../PCB-DESIGN.md](../PCB-DESIGN.md) | 早期启动提示词，板框和连接器信息已过时 |
| `PCB-LAYOUT-DESIGN.md` | 同上 | 标题为布局前 R1 设计稿；实际 Gerber 已替代其中假设 |
| `PCB-PROTOTYPE-REQUIREMENTS.md` | 同上及 [../MANUFACTURING-AND-ACCEPTANCE.md](../MANUFACTURING-AND-ACCEPTANCE.md) | 早期 52×10 后口等阶段信息已被 R5/R6 替换 |
| `PCB-GERBER-REVIEW-2026-10-27.md` 及 `-R2.md`、`-R3.md`、`-R4.md`、`-R5.md` | 当前 `PCB-DESIGN.md` 和实际 Gerber | 保留每次审查的发现和演化；最新文件仍需以实物网表复核 |
| `S5-HANDOFF-AND-HW-DESIGN.md` | [../HARDWARE-DESIGN-SPEC.md](../HARDWARE-DESIGN-SPEC.md) | 旧三件壳、热熔螺母和“分体 FPGA”方向已不采用 |
| `S5-INTEGRATION-PLAN.md` | [../BREADBOARD-BRINGUP.md](../BREADBOARD-BRINGUP.md) | 详细 S5 实施记录和历史位流验收，保留为证据 |
| `INPUTS-WIRING.md` | 同上 | 早期逐针、S9012 和遥测记录；当前 PCB 已改为 PC817/J13 |

## 仍然有效的原始证据

- `S5-INTEGRATION-PLAN.md` 的附录 A1–A6：真板实测、I2C 改动和最终位流资源。
- `PCB-GERBER-REVIEW-2026-10-27-R2.md`：双钻孔 479 个重复坐标等制造风险来源。
- `PCB-GERBER-REVIEW-2026-10-27-R5.md`：40P 预压接插头与上壳拱盖的阶段决策。
- `SHELL-TOF-SPLIT-R6.md`：ToF 上下分件探针和 DfAM 数值来源。

归档是历史证据，不是“已作废所以没有价值”。首件遇到异常时，仍可回到这些文件比对
当时的测量、坐标和审查结论。
