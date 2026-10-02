# tests/ —— fpga-verify 的自检与诊断

## 一键自检（推荐先跑这个）

```powershell
powershell -ExecutionPolicy Bypass -File tests\run_selfcheck.ps1
# 加上 -RunModelSim 会额外用 ModelSim 生成真实 dump 并取证
```
**本机实测结果：SELFCHECK: PASS（10 项全部符合预期）**，包括：
正例 32/32、**负对照**（16 路必须报未命中）、**灵敏度对照**（削波必须被检出）、
`--fs` 陷阱对照、lint/formal 未装时必须返回 3（SKIPPED）。

## 目录内容

| 文件 | 说明 |
|---|---|
| `run_selfcheck.ps1` | 一键自检（UTF-8 with BOM；在 PowerShell 5.1 与 7 下均已验证） |
| `run_spectrum.do` | ModelSim：编译 `fpga_hank/rtl` + `tb_spectrum.v`，生成 `tone_samples.txt` |
| `run_diag.do` | ModelSim：编译 + 运行 `tb_diag.v`，生成 `diag.txt` |
| `tb_diag.v` | **读次数直方图**：统计每个采样周期里 32 个累加拍各自读到 `acc[索引]` 的次数 |
| `EVIDENCE-spectrum.md` / `summary.json` | 一次频谱取证的证据样例（含 C1..C4 结论与复现命令） |
| `EVIDENCE-compliance.md` | 一次红线自审的证据样例 |
| `spectrum_32peaks.png` | 频谱图样例（32 条期望线 + 检出点） |

## ⚠️ 证据文件的时效性

`EVIDENCE-*.md` / `summary.json` / `spectrum_32peaks.png` 是**某一次测量**的快照，
对应 `tone_bank.v` hash **9D01DA492F8E**（2026-10-02 23:03:51）。

**任何 RTL 改动后都必须重新生成**（RTL 在本项目里是快速迭代目标，实测两次测量之间 hash 就变过）：

```powershell
powershell -ExecutionPolicy Bypass -File tests\run_selfcheck.ps1 -RunModelSim
```

引用这些证据时请连同 **RTL hash + 时间戳**一起写进报告，否则无法说明测的是哪一版。

## 诊断"某一路音缺失或偏响"的标准流程

1. `run_spectrum.do` → 得到 dump
2. `spectrum_report.py` → 看 **C4 电平离散度**
   - ≈ **+9.54 dB** ⇒ 某一路每采样被读 **3** 次
   - ≈ **+6.02 dB** ⇒ 被读 **2** 次
   - 某路完全没峰 ⇒ 被读 **0** 次
3. `run_diag.do` → 看 `diag.txt` 直方图，确认是**哪一路**、差多少
4. 修 RTL 后重复 1–3（`references/traps.md` §2 有推导与最小修法）
