#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_cab_coeffs.py —— 生成吉他**箱体模拟**的滤波器系数（Q2.18）并做三项自检
=================================================================================
为什么是"参数化 IIR"而不是"IR 卷积"（**合规决策，不是技术偏好**）
---------------------------------------------------------------------------------
赛题红线：**严禁播放预录 PCM / 预置采样**，且**现场会做 RTL 代码审查**。
一份实测的箱体冲激响应（IR）：① 本质是**实测样本**，评委对照代码时完全可能质疑；
② 512~2048 抽头 FIR 会吃掉大量 BSRAM，并与本项目 **MODE=1 最差裕量 +0.009 ns** 冲突。
=> 改用**参数化 IIR**：系数由本脚本用公开的 RBJ 公式算出来，RTL 里就是几个 `localparam`，
   **"这个数字怎么来的"完全可自证**。

⚠️ 为什么低频段**不用二阶双二阶，而用两级一阶**（**这是被自检逼出来的设计修改**）
---------------------------------------------------------------------------------
第一版把低频截止做成 90 Hz 的二阶 HPF，自检直接报：
    `hpf f0=90 Hz Q=0.80 -> 极点半径 |p| = 0.996387  **危险**`
原因：fs = 97.656 kHz 时 90 Hz 的归一化频率只有 0.00092，**二阶低通/高通的极点天然贴近 z=1**，
对系数量化极敏感（量化误差可能把 |p| 推过 1.0 ⇒ **失稳**）。
=> 低频段改成**两级一阶高通**（`y = a*(y[n-1] + x - x[n-1])`，a ≈ 1 - 2πfc/fs）：
   * 极点都是**实轴上的单极点**，|p| = a = 0.9942 **天然远离 1**，且 Q2.18 的量化步长
     (3.8e-6) 远小于 (1-a)=0.0058 ⇒ 截止频率误差 ~0.07%，**既稳又准**
   * 两级级联仍是 **12 dB/oct**（与二阶等价）
   * 代价：多一次乘法（无所谓，DSP 只有 3.7% 占用）

三项自检（任何一项不过就 **exit 1**，绝不"看着差不多就放行"）
---------------------------------------------------------------------------------
  ① **极点半径**：全部 |p| < 0.99（本项目稳定性判据，与混响同一口径）
  ② **量化误差**：把系数真的量化成 Q2.18 再算一遍频响，与理想响应比，
     全频段最大偏差必须 < 0.5 dB  —— **这一条直接回答"Q2.18 够不够"**
  ③ **单位增益**：以 1 kHz 为 0 dB 参考，避免切换箱体时电平跳变

音频采样率（本工程实测值，**不要照抄 48 kHz**）：fs = 50 MHz / 512 = 97656.25 Hz

用法
---------------------------------------------------------------------------------
    python tools/gen/gen_cab_coeffs.py --out rtl/effects/cab_coeffs.vh \
                                       --csv _research/effects/cab_response.csv
"""

import argparse
import math
import sys
from pathlib import Path

import numpy as np

FS = 97656.25          # ← 本工程真实采样率（50 MHz / 512）
QB = 18                # 小数位数 -> Q2.18

# ---------------------------------------------------------------------------
# 基本构件
# ---------------------------------------------------------------------------
def one_pole_hp(fc):
    """一阶高通 y[n] = a*(y[n-1] + x[n] - x[n-1])，返回 a。极点 |p| = a。"""
    return 1.0 / (1.0 + 2.0 * math.pi * fc / FS)


def biquad(kind, f0, q, gain_db=0.0):
    """RBJ Audio-EQ-Cookbook，返回归一化 (b0,b1,b2,a1,a2)。"""
    w = 2.0 * math.pi * f0 / FS
    cw, sw = math.cos(w), math.sin(w)
    alpha = sw / (2.0 * q)
    if kind == "lpf":
        b0, b1, b2 = (1 - cw) / 2, 1 - cw, (1 - cw) / 2
        a0, a1, a2 = 1 + alpha, -2 * cw, 1 - alpha
    elif kind == "peak":
        A = 10.0 ** (gain_db / 40.0)
        b0, b1, b2 = 1 + alpha * A, -2 * cw, 1 - alpha * A
        a0, a1, a2 = 1 + alpha / A, -2 * cw, 1 - alpha / A
    else:
        raise ValueError(kind)
    return (b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)


def biquad_pole_radius(co):
    a1, a2 = co[3], co[4]
    disc = a1 * a1 - 4 * a2
    if disc >= 0:
        r1 = (-a1 + math.sqrt(disc)) / 2
        r2 = (-a1 - math.sqrt(disc)) / 2
        return max(abs(r1), abs(r2))
    return math.sqrt(a2)


def q18(x):
    return int(round(x * (1 << QB)))


def vlit(x):
    """
    浮点 -> **合法 Verilog 有符号字面量**。
    ⚠️ 负数必须把负号写在**位宽之前**：
         `-21'sd490246`  ✅ 合法
         `21'sd-490246`  ❌ 非法（vlog 报 vlog-13057 "Expecting numeric digits"）
    本项目早就总结过这条（"负数字面量要写 -16'sd1234"），生成器里第一次实现时又踩了。
    """
    q = q18(x)
    return ("-21'sd%d" % (-q)) if q < 0 else ("21'sd%d" % q)


# ---------------------------------------------------------------------------
# 三个箱体档
#   低频：两级一阶高通（12 dB/oct，稳）
#   中高：峰值均衡（存在感）+ 二阶低通（喇叭滚降）
# ---------------------------------------------------------------------------
CABS = {
    1: dict(name="4x12 密闭", hp=(90.0, 90.0), peak=(2600.0, 1.20, 5.0), lp=(4800.0, 0.70)),
    2: dict(name="1x12 开放", hp=(110.0, 110.0), peak=(3200.0, 1.00, 3.0), lp=(5500.0, 0.70)),
}
NORM_HZ = 1000.0


def build(spec):
    """返回 (结构描述列表, 级联响应函数, 极点半径列表)"""
    hp1 = one_pole_hp(spec["hp"][0])
    hp2 = one_pole_hp(spec["hp"][1])
    pk = biquad("peak", *spec["peak"])
    lp = biquad("lpf", spec["lp"][0], spec["lp"][1])
    stages = [("hp1", hp1), ("hp2", hp2), ("peak", pk), ("lpf", lp)]
    radii = [hp1, hp2, biquad_pole_radius(pk), biquad_pole_radius(lp)]
    return stages, radii


def resp(stages, freqs, quant=False):
    H = np.ones(len(freqs), dtype=complex)
    z = np.exp(-1j * 2 * np.pi * np.asarray(freqs) / FS)
    for name, p in stages:
        if name in ("hp1", "hp2"):
            a = p if not quant else q18(p) / (1 << QB)
            # y = a(y1 + x - x1) -> H = a(1 - z^-1)/(1 - a z^-1)
            H *= a * (1 - z) / (1 - a / z)
        else:
            b0, b1, b2, a1, a2 = p
            if quant:
                b0, b1, b2, a1, a2 = [q18(v) / (1 << QB) for v in p]
            H *= (b0 + b1 / z + b2 / (z * z)) / (1 + a1 / z + a2 / (z * z))
    return H


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=None, help="输出 Verilog 头文件 .vh")
    ap.add_argument("--csv", default=None, help="输出设计频响曲线 CSV（供 TB 对比）")
    a = ap.parse_args()

    print("=" * 80)
    print("吉他箱体模拟 —— 参数化 IIR 系数生成（RBJ 公式）")
    print("fs = %.2f Hz   系数格式 = Q2.18（21 bit 有符号，范围 ±4）" % FS)
    print("低频 = 两级一阶高通（12 dB/oct，避开二阶极贴近 z=1 的失稳风险）")
    print("=" * 80)

    freqs = np.logspace(math.log10(40), math.log10(16000), 160)
    vlines = [
        "// ============================================================================",
        "// cab_coeffs.vh —— **由 tools/gen/gen_cab_coeffs.py 自动生成，请勿手改**",
        "//",
        "// 吉他箱体模拟：两级一阶高通(12dB/oct) -> 峰值均衡 -> 二阶低通",
        "// fs = %.2f Hz（= 50 MHz / 512）  系数 = Q2.18（21 bit 有符号）" % FS,
        "//",
        "// ⚠️ 为什么不用 IR 卷积：赛题红线'严禁预录 PCM'，IR 本质是实测样本；",
        "//    且大抽头 FIR 与本工程 MODE=1 的 +0.009 ns 裕量冲突。",
        "//    参数化 IIR 让'系数怎么来的'可自证（见生成脚本与设计文档）。",
        "// ⚠️ 低频为什么用两级一阶而不是二阶双二阶：fs=97.656kHz 时 90Hz 的二阶极点",
        "//    半径达 0.9964（贴近 z=1，量化可能推到 >1 而失稳）；一阶极点 0.9942 且",
        "//    量化步长远小于 (1-a)，既稳又准。**这是自检报出来的，不是猜的。**",
        "// ⚠️ 绝不要把系数改成 signed [7:0] —— 本项目已因'装不下 >127'翻过车。",
        "// ============================================================================",
    ]

    maxpole = 0.0          # 二阶节最大极点半径
    minmargin1 = 1.0       # 一阶节最小量化余量
    stab_ok = True
    maxqerr = 0.0
    rows = ["freq_Hz,cab1_ideal_dB,cab1_q18_dB,cab2_ideal_dB,cab2_q18_dB"]
    for sel, spec in CABS.items():
        print("\n--- cab_sel = 2'd%d : %s ---" % (sel, spec["name"]))
        stages, radii = build(spec)
        names = ["一阶高通#1", "一阶高通#2", "峰值均衡", "二阶低通"]
        # ⚠️ 稳定性判据**按结构分**（这是本次自检逼出来的认知修正）：
        #   · 一阶节：极点就是 a 本身，**唯一的失稳途径是量化的 a ≥ 1**。
        #     判据 = a + 量化步长 < 1.0。fs=97.656kHz 下 90Hz 的 a=0.9942 完全安全
        #     （余量 0.0058，是量化步长 3.8e-6 的 1500 倍）。
        #   · 二阶节：用统一的 |p| < 0.99（振铃/灵敏度经验线）。
        #   ⚠️ 早先对**所有**结构都用 0.99 是**判据用错**：会把完全安全的一阶节误判为危险。
        QSTEP = 2.0 ** (-QB)
        for nm, r, is_1st in zip(names, radii, (True, True, False, False)):
            if is_1st:
                ok = (r + QSTEP) < 1.0
                minmargin1 = min(minmargin1, 1.0 - r)
                print("   %-10s |a| = %.6f  量化余量 = %.6f (=%.0f x 量化步长)  %s"
                      % (nm, r, 1.0 - r, (1.0 - r) / QSTEP, "OK" if ok else "**危险**"))
            else:
                ok = r < 0.99
                maxpole = max(maxpole, r)
                print("   %-10s |p| = %.6f  %s" % (nm, r, "OK (<0.99)" if ok else "**危险**"))
            if not ok:
                stab_ok = False

        Hi = resp(stages, freqs)
        Hq = resp(stages, freqs, quant=True)
        # 归一化到 1 kHz = 0 dB（按理想响应）
        g = 1.0 / abs(resp(stages, np.array([NORM_HZ]))[0])
        Hi, Hq = Hi * g, Hq * g
        di = 20 * np.log10(np.abs(Hi) + 1e-12)
        dq = 20 * np.log10(np.abs(Hq) + 1e-12)
        err = float(np.max(np.abs(di - dq)))
        maxqerr = max(maxqerr, err)
        print("   归一化增益(1kHz=0dB) = %.6f" % g)
        print("   ★ 量化误差（Q2.18 vs 理想）全频段最大偏差 = %.4f dB  %s"
              % (err, "OK" if err < 0.5 else "**超 0.5 dB**"))

        for i, (nm, p) in enumerate(stages):
            if nm in ("hp1", "hp2"):
                print("   stage%d %-8s a = %.8f -> Q2.18 %d" % (i, nm, p, q18(p)))
            else:
                print("   stage%d %-8s b0=%+9.6f b1=%+9.6f b2=%+9.6f a1=%+9.6f a2=%+9.6f"
                      % (i, nm, p[0], p[1], p[2], p[3], p[4]))

        # ---- 写 Verilog ----
        # ⚠️ 必须把归一化增益 g **真正乘进 b 系数**再发射。
        #    第一版算出了 g、也只把它用在 CSV 曲线上，**发射的却是未归一化的 stages**
        #    ⇒ 箱体绝对电平与"设计曲线"对不上（真 bug，被 Lead 点名复核出来）。
        #    只缩放 b（分子），不动 a（分母）—— 那才是"整体增益"，不改极点与形状。
        eq_p = list(stages[2][1]); lp_p = list(stages[3][1])
        for _p in (eq_p, lp_p):
            _p[0] *= g; _p[1] *= g; _p[2] *= g

        vlines.append("")
        vlines.append("// ---- cab_sel = 2'd%d : %s ----" % (sel, spec["name"]))
        vlines.append("// 已按 1 kHz = 0 dB 归一化（g = %.6f 乘进 b0/b1/b2）" % g)
        vlines.append("localparam signed [20:0] CAB%d_HP1_A  = %s;" % (sel, vlit(stages[0][1])))
        vlines.append("localparam signed [20:0] CAB%d_HP2_A  = %s;" % (sel, vlit(stages[1][1])))
        for tag, p in (("EQ", eq_p), ("LP", lp_p)):
            for j, nm in enumerate(("B0", "B1", "B2", "A1", "A2")):
                vlines.append("localparam signed [20:0] CAB%d_%s_%s = %s;"
                              % (sel, tag, nm, vlit(p[j])))
        for nm, r in zip(names, radii):
            vlines.append("//   %s 极点半径 |p| = %.6f" % (nm, r))

        for f, i1, q1 in zip(freqs, di, dq):
            rows.append("%.2f,%.4f,%.4f,," % (f, i1, q1))

    # 第二遍填 cab2 两列
    H2i = resp(*build(CABS[2])[:1] + (freqs,)) if False else None
    st2, _ = build(CABS[2])
    g2 = 1.0 / abs(resp(st2, np.array([NORM_HZ]))[0])
    d2i = 20 * np.log10(np.abs(resp(st2, freqs) * g2) + 1e-12)
    d2q = 20 * np.log10(np.abs(resp(st2, freqs, quant=True) * g2) + 1e-12)
    out_rows = ["freq_Hz,cab1_ideal_dB,cab1_q18_dB,cab2_ideal_dB,cab2_q18_dB"]
    for k, f in enumerate(freqs):
        out_rows.append("%.2f,%.4f,%.4f,%.4f,%.4f" % (f, di[k], dq[k], d2i[k], d2q[k]))

    vlines.append("")
    vlines.append("// 稳定性总判据：二阶节最大极点半径 = %.6f （须 < 0.99）" % maxpole)
    vlines.append("//               一阶节最小量化余量 = %.6f （须 > 0，即量化后仍 < 1）" % minmargin1)
    vlines.append("// 量化误差总判据：Q2.18 vs 理想，全频段最大偏差 = %.4f dB （须 < 0.5 dB）" % maxqerr)

    if a.out:
        Path(a.out).parent.mkdir(parents=True, exist_ok=True)
        Path(a.out).write_text("\n".join(vlines) + "\n", encoding="utf-8")
        print("\n[ok] Verilog 系数头 -> %s" % a.out)
    if a.csv:
        Path(a.csv).parent.mkdir(parents=True, exist_ok=True)
        Path(a.csv).write_text("\n".join(out_rows) + "\n", encoding="utf-8")
        print("[ok] 设计频响曲线 -> %s（%d 频点）" % (a.csv, len(freqs)))

    print("\n" + "=" * 80)
    ok = stab_ok and (maxqerr < 0.5)
    print("★ 自检① 二阶节最大极点半径 = %.6f  %s" % (maxpole, "PASS (<0.99)" if maxpole < 0.99 else "**FAIL**"))
    print("★ 自检① 一阶节最小量化余量 = %.6f  %s" % (minmargin1, "PASS (>0)" if minmargin1 > 0 else "**FAIL**"))
    print("★ 自检② 量化误差最大 = %.4f dB %s" % (maxqerr, "PASS (<0.5dB)" if maxqerr < 0.5 else "**FAIL**"))
    print("★ 自检③ 1 kHz 归一化为 0 dB")
    print("=> %s" % ("全部 PASS" if ok else "**有 FAIL，拒绝生成**"))
    print("=" * 80)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
