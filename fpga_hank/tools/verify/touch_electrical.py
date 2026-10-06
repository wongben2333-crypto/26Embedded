#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""touch_electrical.py —— 电容触摸的**电路数值分析**（不需要 SPICE，RC 是一阶方程）

背景：本机没有 ngspice/LTspice/KiCad，但 RC 充电有解析解 ⇒ 用 scipy/numpy 直接算。

模型（与 `rtl/io/touch_key.v` 的测量方式一一对应）：
    1) PAD 被强驱低放电到 0
    2) 释放为高阻，PAD 经外部上拉电阻 R 从 VCC 充电：  V(t) = VCC·(1 − e^(−t/RC))
    3) FPGA 输入缓冲器在 V(t) 达到门限 V_IH 时读到逻辑 1 ⇒ 那一刻的 clk 计数就是测量值
       ⇒ t_cross = −R·C·ln(1 − V_IH/VCC)      counts = t_cross × F_CLK + 常数偏移

★ 常数偏移：RTL 里 pad 要过 2 级同步 + 计数器的 1 拍 ⇒ **+3 clk**（被基线自动吸收，不影响判定）。
★ 输出：所有数字都会打印，并画两张 PNG 到本目录。

用法： python touch_electrical.py
"""

import math
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt          # noqa: E402
import numpy as np                       # noqa: E402

# ★ 中文标签必须指定 CJK 字体，否则图上全是"豆腐块"（实测 DejaVu Sans 缺中文字形）
plt.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei", "DejaVu Sans"]
plt.rcParams["axes.unicode_minus"] = False

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

F_CLK = 50_000_000.0        # 我们的计数时钟
VCC = 3.3                   # LVCMOS33
SYNC_OFFSET = 3             # RTL 常数偏移（2 级同步 + 1 拍）
HERE = os.path.dirname(os.path.abspath(__file__))
# tools/verify → tools → fpga_hank → <仓库根>（**少一级就会落到 fpga_hank/_research/，实测踩过**）
OUTDIR = os.path.abspath(os.path.join(HERE, "..", "..", "..", "_research", "pc-link"))

# 输入门限：**这是本分析最大的不确定项**，所以给一组值看敏感度
#   · JEDEC/常见 CMOS 约定 V_IH = 0.7×VCC = 2.31 V
#   · 很多 FPGA 数据手册给 LVCMOS33 的 V_IH(min) = 2.0 V
VTH_SET = {"1.7 V (乐观下界)": 1.7, "2.0 V (常见 min)": 2.0,
           "2.31 V (0.7×VCC)": 2.31, "2.4 V (保守)": 2.4}
VTH_MAIN = 2.0


def t_cross(R, C, vth=VTH_MAIN):
    """充电到 V_IH 所需时间（秒）。"""
    return -R * C * math.log(1.0 - vth / VCC)


def counts(R, C, vth=VTH_MAIN):
    """RTL 会数到的 clk 数（含常数偏移）。"""
    return int(round(t_cross(R, C, vth) * F_CLK)) + SYNC_OFFSET


def hr(title):
    print("\n" + "=" * 76)
    print(f" {title}")
    print("=" * 76)


# =============================================================================
hr("0. 基础换算：灵敏度 counts/pF（这是行业标准指标，见 Infineon AN75400 词汇表 p86）")
R_REF, C_REF = 1e6, 20e-12
base = counts(R_REF, C_REF)
print(f"  R=1 MΩ, C=20 pF, V_IH={VTH_MAIN} V:")
print(f"    t_cross = {t_cross(R_REF, C_REF)*1e6:.2f} us")
print(f"    计数    = {base}  (含 +{SYNC_OFFSET} 常数偏移)")
print(f"    灵敏度  = {counts(R_REF, C_REF+1e-12) - base} counts/pF  ← 每 pF 多少计数")
print(f"  ⇒ 解析式：dcounts/dC = -ln(1-V_IH/VCC)·R·F_CLK"
      f" = {-math.log(1-VTH_MAIN/VCC):.4f} × {R_REF:.0e} × {F_CLK:.0e} "
      f"= {counts(R_REF, C_REF+1e-12)-base} counts/pF")

# =============================================================================
hr("1. 灵敏度分析：C = 10/20/30/40/60/100 pF 时的计数（R=1 MΩ）")
C_LIST = [10, 20, 30, 40, 60, 100]
print(f"  {'C(pF)':>7} {'t_cross(us)':>12} {'counts':>8} {'扫描单通道(us)':>15}")
rows_c = []
for cp in C_LIST:
    C = cp * 1e-12
    t = t_cross(R_REF, C)
    n = counts(R_REF, C)
    per_pad_us = (200 + 256 + n) / F_CLK * 1e6        # SCAN_DIV + DISCHARGE + counts
    rows_c.append((cp, t * 1e6, n, per_pad_us))
    print(f"  {cp:>7} {t*1e6:>12.2f} {n:>8} {per_pad_us:>15.1f}")
print(f"  （参考设计实测对照：stnolting/captouch 用 ~1 MΩ + 3.3 V，"
      f"文档未给计数；我们 tb 实测 V_IH 门限模型下 20 pF ≈ 934，与上表一致）")

# =============================================================================
hr("2. ★手指电容增量 vs 计数增量（力度维度的物理基础）")
print("  文献锚点（可引用，我逐个核对了原文）：")
print("   · Infineon AN75400《PSoC 3/5LP CapSense Design Guide》p70：")
print("       「CP for all sensors must be **5–45 pF**」（传感器基础/寄生电容的允许范围）")
print("   · 同文档 p8：「Detects touches as low as **0.1 pF**」（CapSense 能检测的最小触摸量）")
print("   · 同文档 p86：灵敏度定义为「**change in Raw Count ... expressed in counts/pF**」")
print("   · stnolting/captouch（BSD-3）文档给的检测门限档：基础电容的 **+6.25% / +12.5% / +25%**")
print("   ⚠️ 诚实标注：我**没能**从 AN75400 原文取到「手指按上去等于多少 pF」的确切数值；")
print("      文献给的是一条**能力边界**（≥0.1 pF 可测）与**基础电容范围**（5–45 pF），")
print("      所以下面按 ΔC **扫描 0.5~20 pF** 给出计数增量，PCB 设计据此选 R 即可，")
print("      不必依赖某个「手指=多少 pF」的传说数字。")
print()
print(f"  {'ΔC(pF)':>8} {'counts':>8} {'Δcounts':>9} {'占基础电容%':>12}")
dc_rows = []
for dc in [0.0, 0.5, 1, 2, 5, 10, 20]:
    n = counts(R_REF, C_REF + dc * 1e-12)
    d = n - base
    dc_rows.append((dc, n, d, dc / 20.0 * 100))
    print(f"  {dc:>8.1f} {n:>8} {d:>9} {dc/20.0*100:>11.1f}%")
print(f"  ⇒ 1 pF ≈ {counts(R_REF, C_REF+1e-12)-base} 个计数；"
      f"只要手指增量 ≥0.2 pF 就有 ~9 个计数（远高于噪声底，见 §4）")

# =============================================================================
hr("3. 上拉电阻 R 的选择：220k / 470k / 680k / 1M / 2.2M（C=20 pF，V_IH=2.0 V）")
print(f"  {'R':>8} {'counts':>8} {'counts/pF':>10} {'单通道(us)':>11} {'4通道轮(us)':>12} {'扫描率(kHz)':>12}")
rows_r = []
for rk in [220, 470, 680, 1000, 2200]:
    R = rk * 1e3
    n = counts(R, C_REF)
    sens = counts(R, C_REF + 1e-12) - n
    per_pad = (200 + 256 + n) / F_CLK * 1e6
    round4 = per_pad * 4
    rate_khz = 1e3 / round4                  # round4 单位是 us ⇒ 1e3/us = kHz
    rows_r.append((rk, n, sens, per_pad, round4, rate_khz))
    print(f"  {rk:>6} kΩ {n:>8} {sens:>10} {per_pad:>11.1f} {round4:>12.1f} {rate_khz:>12.2f}")
print("  取舍：R 越大 ⇒ 计数越多、counts/pF 越高（分辨率好），但单通道越慢；")
print("        且 R 太大时漏电流/湿度影响变大、输入缓冲器的输入漏电会形成误差。")
print("  ⇒ 推荐 **1 MΩ**：灵敏度 ~47 counts/pF（0.1 pF 也有 ~5 个计数）、")
print("     4 通道整轮仅 ~111 us、扫描率 ~9 kHz（远低于音频 97.7 kHz）。")
print("     captouch(BSD-3) 也用 ~1 MΩ ⇒ 与权威参考一致。")

# =============================================================================
hr("4. ★噪声/抗干扰估算 ⇒ 阈值该留多少裕量")
print("  (a) 工频 50 Hz 干扰（通过空气/手指耦合到 PAD）")
for cc in [0.01e-12, 0.1e-12, 0.5e-12]:
    i = 2 * math.pi * 50 * cc * 220.0            # 220 V 有效值
    q = i * t_cross(R_REF, C_REF)
    dv = q / C_REF
    frac = dv / VTH_MAIN
    dt = frac * t_cross(R_REF, C_REF)
    print(f"    耦合 {cc*1e12:>5.2f} pF: 感应电流 {i*1e9:>6.2f} nA, 测量窗口内注入 {dv*1e3:>6.2f} mV "
          f"⇒ 时间偏差 {dt*1e9:>6.1f} ns ≈ {dt*F_CLK:>4.1f} 个计数")
print("  (b) 门限电压 V_IH 的容差（**主要不确定项**）")
vals = {k: counts(R_REF, C_REF, v) for k, v in VTH_SET.items()}
for k, v in vals.items():
    print(f"    V_IH = {k:<16} ⇒ counts = {v}")
print(f"    极差 = {max(vals.values())-min(vals.values())} 个计数"
      f"（但这部分是**常数偏置** ⇒ 被基线跟踪吸收，不影响触摸判定）")
print("  (c) 元件容差")
print(f"    R ±1%:  ⇒ ±{base*0.01:.0f} 个计数          （常数偏置，基线吸收）")
print(f"    C ±5%（PCB 尺寸/覆膜）: ⇒ ±{base*0.05:.0f} 个计数（同上）")
print("  (d) 环境漂移（温湿度、手靠近未触碰）")
print("    ⇒ **无法先验算准**，靠 `touch_key.v` 的基线持续跟踪（BASE_SH=6）+ 迟滞处理。")
print()
print("  ⇒ 综合：**随机分量**约 ±5 个计数（工频为主），**系统性分量**由基线吸收。")
print(f"    当前默认阈值 = 基础计数的 25% ≈ {int(base*0.25)} 个计数 ⇒ "
      f"相对随机噪声有 **{int(base*0.25)/5:.0f} 倍**余量。")
print("    ⇒ 这从数量上支持「第一阶段用 25% 阈值」（不要一上来用 6.25%）：")
print("      6.25% ≈ 58 个计数，只剩 ~12 倍余量，且更怕基线跟踪滞后（我在 tb 里实测 12.5% 会因滞后误触）。")

# =============================================================================
hr("5. 扫描周期 vs 通道数（单通道 = SCAN_DIV 200 + 放电 256 + 计数 934 ≈ 1390 clk）")
print(f"  {'通道数':>6} {'整轮(us)':>10} {'扫描率(kHz)':>12} {'按下延迟(ms,3轮去抖)':>20} {'音频周期占比':>13}")
rows_n = []
per_pad = (200 + 256 + counts(R_REF, C_REF)) / F_CLK
for nch in [2, 4, 8, 12]:
    round_s = per_pad * nch
    rate = 1.0 / round_s
    lat = 3 * round_s * 1e3
    rows_n.append((nch, round_s * 1e6, rate / 1e3, lat, round_s * 97656.25))
    print(f"  {nch:>6} {round_s*1e6:>10.1f} {rate/1e3:>12.2f} {lat:>20.3f} {round_s*97656.25:>13.2f}")
print("  ⇒ 即使 12 通道：扫描率 3.0 kHz（音频的 1/33）、按下延迟 0.99 ms（≪ 10 ms 赛题指标）✅")

# =============================================================================
hr("6. ★『力度』能分辨几档？（如实说，不吹成 127 级）")
noise_counts = 5.0                     # §4 估计的随机噪声（计数）
full_dc = 20.0                         # 一个"用力按"的 ΔC 假设上界（见 §2 的说明）
full_delta = counts(R_REF, C_REF + full_dc * 1e-12) - base
print(f"  · 满按（ΔC={full_dc:.0f} pF）⇒ Δcounts = {full_delta}")
print(f"  · 随机噪声 ≈ ±{noise_counts:.0f} 个计数")
print(f"  · ⇒ **电子上**可分辨约 {full_delta/noise_counts:.0f} 档（Δcounts/噪声）")
print(f"  · 若只算「轻触」ΔC=5 pF ⇒ Δcounts={counts(R_REF, C_REF+5e-12)-base}，"
      f"可分辨约 {(counts(R_REF, C_REF+5e-12)-base)/noise_counts:.0f} 档")
print("  ⚠️ **但这不是力度的真实分辨率**：电子分辨率 ≠ 力度分辨率。")
print("     真正限制在于【手指的 力 → ΔC  transduction】——我没有找到任何来源给出"
      "指腹压力到电容的标定曲线；")
print("     能确证的只有：ΔC 随接触面积变大而单调增（平行板 εA/d 模型），且按压力度会同时改变"
      "接触面积与覆膜间距。")
print("  ⇒ 建议对外宣称 **16 档力度**（保守、可复现），并明确它是「相对强度」而非标定力度；")
print(f"     若要更激进，电子上支持 ~{int(full_delta/noise_counts)} 档，但那取决于人手指的重复性，"
      "没有标定数据，不该写进报告当结论。")

# =============================================================================
hr("7. 画图")
os.makedirs(OUTDIR, exist_ok=True)

# 图1：充电曲线 V(t)（不同 C），标出门限
fig, ax = plt.subplots(figsize=(9, 5.2))
t = np.linspace(0, 80e-6, 2000)
for cp in [10, 20, 30, 40, 60, 100]:
    C = cp * 1e-12
    v = VCC * (1 - np.exp(-t / (R_REF * C)))
    ax.plot(t * 1e6, v, label=f"C={cp} pF  (t_cross={t_cross(R_REF,C)*1e6:.1f} us)")
    tc = t_cross(R_REF, C)
    ax.plot([tc * 1e6], [VTH_MAIN], "k.", ms=6)
ax.axhline(VTH_MAIN, color="r", ls="--", lw=1,
           label=f"V_IH = {VTH_MAIN} V（输入门限，主假设）")
ax.axhline(2.31, color="orange", ls=":", lw=1, label="V_IH = 2.31 V (0.7·VCC)")
ax.set_xlabel("t (us)"); ax.set_ylabel("V_pad (V)")
ax.set_title("PAD 充电曲线 V(t)=VCC(1-e^(-t/RC))，R=1 MΩ，50 MHz 计数")
ax.grid(alpha=0.3); ax.legend(fontsize=8); ax.set_ylim(0, 3.5)
f1 = os.path.join(OUTDIR, "touch_rc_charge.png")
fig.tight_layout(); fig.savefig(f1, dpi=130); plt.close(fig)
print(f"  已存 {f1}")

# 图2：计数 vs 电容（多条 R 曲线），以及 ΔC→Δcounts
fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(12, 4.8))
cs = np.linspace(5, 100, 400)
for rk in [220, 470, 680, 1000, 2200]:
    R = rk * 1e3
    nn = [counts(R, c * 1e-12) for c in cs]
    ax1.plot(cs, nn, label=f"R={rk} kΩ")
ax1.set_xlabel("PAD 电容 C (pF)"); ax1.set_ylabel("计数 (clk @50 MHz)")
ax1.set_title("计数 vs 电容（V_IH=2.0 V）"); ax1.grid(alpha=0.3); ax1.legend(fontsize=8)
ax1.axvspan(5, 45, color="green", alpha=0.08)
ax1.text(7, ax1.get_ylim()[1] * 0.9, "Infineon AN75400 p70:\nCP 允许 5–45 pF", fontsize=8, color="green")

dc = np.linspace(0, 25, 200)
ax2.plot(dc, [counts(R_REF, C_REF + d * 1e-12) - base for d in dc], color="C3")
ax2.set_xlabel("手指带来的电容增量 ΔC (pF)"); ax2.set_ylabel("计数增量 Δcounts")
ax2.set_title("ΔC → Δcounts（R=1 MΩ ⇒ 约 47 counts/pF）")
ax2.grid(alpha=0.3)
ax2.axhline(5, color="gray", ls="--", lw=1, label="估计噪声底 ±5 counts")
ax2.axhline(base * 0.25, color="purple", ls=":", lw=1, label=f"25% 阈值 ≈ {int(base*0.25)} counts")
ax2.legend(fontsize=8)
f2 = os.path.join(OUTDIR, "touch_counts_vs_cap.png")
fig.tight_layout(); fig.savefig(f2, dpi=130); plt.close(fig)
print(f"  已存 {f2}")

hr("结论（给画板的人）")
print(f"  · 上拉电阻：**1 MΩ ±1%**，每通道一个，接到该 bank 的 VCCIO=3.3 V；")
print("              可选串联 100 Ω~1 kΩ 做 ESD/限流（对时间影响 +0.1%）")
print(f"  · PAD 基础电容目标：**10–40 pF**（落在 Infineon 允许的 5–45 pF 内）；")
print("              对应 10×10~15×15 mm 铜箔、覆膜 ~0.1–0.5 mm、PAD 下方不铺地铜")
print(f"  · 计数范围（V_IH=2.0 V, R=1 MΩ）：10 pF→{counts(R_REF,10e-12)}，"
      f"20 pF→{counts(R_REF,20e-12)}，40 pF→{counts(R_REF,40e-12)}")
print(f"  · 灵敏度：**~47 counts/pF** ⇒ 0.1 pF 也有 ~5 个计数")
print(f"  · 阈值：默认 **25%（≈{int(base*0.25)} counts）**，对噪声有 ~"
      f"{int(base*0.25)/5:.0f} 倍余量；")
print("          调灵敏请用 THRESH_SH=3(12.5%)，但实测会因基线滞后在漂移时误触 ⇒ 先别用")
print(f"  · 扫描：4 通道整轮 {per_pad*4*1e6:.0f} us（9 kHz），按下延迟 {3*per_pad*4*1e3:.2f} ms")
print("  · 力度：建议对外 **16 档**（电子上可分辨更多，但手指力度→电容无标定数据）")
print("\n[RESULT] DONE（本文件所有数字均由本脚本算出，非引用他人结果）")
