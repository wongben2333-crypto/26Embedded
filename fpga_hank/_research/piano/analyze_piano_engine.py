# -*- coding: utf-8 -*-
"""analyze_piano_engine.py —— 对 tb_piano_engine 落盘的样本做 FFT 判据（真采样率 fs）

判据（与工程真采样率一致：fs = 50e6/512 = 97656.25 Hz）：
  1) 单音 A4：基频应等于 440 Hz × 1.00018（非谐性把 n=1 也拉伸了 0.018%），
     并且能看到 6 个泛音分量，且高次泛音幅度依次下降。
  2) 三音和弦：C4/E4/G4 三个基频必须同时存在（复音）。
  3) 力度：vel=120 的高次泛音/基频比必须明显高于 vel=30（"力度→变亮"）。
  4) note-off：平均电平必须持续下落（阻音器），没有 sustain 平台。

用法：python _research/piano/analyze_piano_engine.py <样本目录>
      <样本目录> 里应有 piano_a4.txt / piano_chord.txt / piano_vel030.txt / ...
"""
from __future__ import annotations

import os
import sys

import numpy as np

FS = 50_000_000 / 512.0          # 97656.25 Hz
A4 = 440.0
# 生成脚本里 B = 0.0004，n=1 的拉伸 = sqrt(1+B) = 1.00019998，实现的移位对给 1.000183
STRETCH1_THEORY = np.sqrt(1.0 + 0.0004)
STRETCH1_IMPL = 1.0 + 2.0 ** -13 + 2.0 ** -14


def et(n: float) -> float:
    return A4 * 2.0 ** ((n - 69) / 12.0)


def load(d: str, name: str) -> np.ndarray:
    p = os.path.join(d, name)
    vals, nx = [], 0
    with open(p, 'r', errors='replace') as fh:
        for ln in fh:
            t = ln.strip()
            if not t:
                continue
            try:
                vals.append(float(t))
            except ValueError:
                vals.append(np.nan)
                nx += 1
    x = np.asarray(vals)
    print('  %-20s n=%6d  min=%7d max=%7d mean=%8.1f rms=%8.1f  X=%d' % (
        name, x.size, np.nanmin(x), np.nanmax(x), np.nanmean(x),
        np.sqrt(np.nanmean(x.astype(float) ** 2)), nx))
    if nx:
        print('    [!!] 有 %d 个 X 样本 —— 数据通路存在未初始化寄存器' % nx)
    return x


def spec(x: np.ndarray):
    n = x.size
    w = np.hanning(n)
    X = np.abs(np.fft.rfft((x - x.mean()) * w))
    df = FS / n
    return X, df


def peak_at(X: np.ndarray, df: float, f0: float, span: int = 6):
    """在期望频率附近找最大峰并做抛物线插值，返回 (频率, 幅度)。"""
    k0 = int(round(f0 / df))
    lo, hi = max(1, k0 - span), min(X.size - 2, k0 + span)
    k = lo + int(np.argmax(X[lo:hi + 1]))
    a, b, c = np.log(X[k - 1] + 1e-30), np.log(X[k] + 1e-30), np.log(X[k + 1] + 1e-30)
    den = a - 2 * b + c
    dd = 0.0 if abs(den) < 1e-30 else 0.5 * (a - c) / den
    return (k + dd) * df, X[k], k


def peaks(x: np.ndarray, thr_db=-45.0, maxn=20):
    X, df = spec(x)
    db = 20 * np.log10(np.maximum(X, 1e-12) / X.max())
    idx = np.flatnonzero((db[1:-1] > db[:-2]) & (db[1:-1] >= db[2:])) + 1
    idx = [i for i in idx if db[i] >= thr_db]
    idx.sort(key=lambda i: -db[i])
    return [(i * df, float(db[i])) for i in idx[:maxn]], df


def main():
    d = sys.argv[1] if len(sys.argv) > 1 else '.'
    nfail = 0
    print('=' * 78)
    print('钢琴引擎 FFT 判据   fs = %.2f Hz   (样本目录 %s)' % (FS, d))
    print('=' * 78)

    # ---------------- 1) 单音 A4 ----------------
    print('\n[1] 单音 A4 (note 69) —— 基频与 6 个泛音')
    x = load(d, 'piano_a4.txt')
    X, df = spec(x)
    # 期望：实现上 n=1 被拉伸 1.000183
    f_exp = et(69) * STRETCH1_IMPL
    f_meas, _, _ = peak_at(X, df, et(69))
    err_pct = (f_meas - f_exp) / f_exp * 100
    err_hz = f_meas - f_exp
    print('    期望基频（含非谐性拉伸 ×%.6f）= %.3f Hz' % (STRETCH1_IMPL, f_exp))
    print('    实测基频（FFT + 抛物线插值）    = %.3f Hz   误差 %+.4f Hz (%+.4f %%)'
          % (f_meas, err_hz, err_pct))
    print('    FFT 频率分辨率 df = %.3f Hz' % df)
    ok_f = abs(err_hz) < 1.0
    print('    %s: |误差| %.3f Hz < 1.0 Hz（判据）' % ('PASS' if ok_f else 'FAIL', abs(err_hz)))
    nfail += 0 if ok_f else 1

    # 泛音实测 vs 理论（非谐性 f_n = n·f0·sqrt(1+B n²)）
    B = 0.0004
    print('\n    泛音频率实测 vs 非谐性理论 f_n = n·f0·sqrt(1+B n²), B=%.4f' % B)
    print('      n   理论(Hz)    实测(Hz)    误差(cent)   相对幅度(dB)  设计比例(dB)')
    # 设计比例要按【vel=100 的实际系数】算：K 是"最强奏"系数，实际 = K×vel/128
    design_amp = np.array([27594, 8278, 3311, 1380, 552, 276], dtype=float)
    kv = np.array([0, 3686, 8192, 14336, 22528, 32768], dtype=float)
    bright100 = 1.0 + (kv * 100 // 128) / 4096.0
    design_eff = design_amp * bright100
    design_db = 20 * np.log10(design_eff / design_eff[0])
    amps = []
    for n in range(1, 7):
        # 实现里 n=1 已被拉伸，故理论 = n·(实测基频)·sqrt(1+B n²)
        fn = n * f_meas * np.sqrt(1 + B * n * n)
        fm, a, _ = peak_at(X, df, fn, span=8)
        amps.append(a)
        cents = 1200 * np.log10(fm / fn) / np.log10(2)
        print('      %d  %9.2f  %9.2f  %+8.1f   %8.1f      %8.1f'
              % (n, fn, fm, cents, 20 * np.log10(a / amps[0]), design_db[n - 1]))
    # 与设计系数的比较必须【补偿各泛音自己的衰减】：
    #   设计系数是 t=0 的初值，而 FFT 记录的是 16384 个采样点（168 ms）的平均。
    #   高次泛音衰减快（A4 的第 6 泛音 τ≈84 ms），168 ms 内平均只剩约 -7 dB，
    #   所以"实测 -31.6 dB vs 设计 -22.8 dB"不是错，正是"高次泛音衰减更快"的证据。
    #   这里把窗口平均因子算出来补偿后再比（同时也就验证了各泛音的衰减速率）。
    S_RING = np.array([17, 16, 15, 14, 13, 12], dtype=float)
    k_a4 = 1                                   # note 69 → clamp((90-69)>>4,0,2) = 1
    T = x.size / FS                            # 记录时长(s)
    tau = 2.0 ** (S_RING + k_a4) / FS          # 各泛音时间常数(s)
    avg = (tau / T) * (1.0 - np.exp(-T / tau))  # 指数衰减在该窗口内的平均/初值
    print('\n    衰减补偿（窗口 %.0f ms）：' % (T * 1e3))
    print('      n   τ(ms)   窗口平均/初值(dB)   设计(dB)   补偿后期望(dB)   实测(dB)   偏差')
    dev_max = 0.0
    for n in range(6):
        comp = design_db[n] + 20 * np.log10(avg[n])
        meas = 20 * np.log10(amps[n] / amps[0])
        dev = abs((meas - 20 * np.log10(avg[n])) - design_db[n])
        dev_max = max(dev_max, dev)
        print('      %d  %6.0f      %+7.2f       %7.1f       %8.1f      %7.1f    %5.1f'
              % (n + 1, tau[n] * 1e3, 20 * np.log10(avg[n]), design_db[n],
                 comp, meas, dev))
    print('    补偿衰减后，实测泛音比例与设计系数最大偏差 = %.1f dB（允差 3 dB）' % dev_max)
    if dev_max <= 3.0:
        print('    PASS: 泛音幅度分布与生成表一致，且各泛音衰减速率符合设计（越高的越快）')
    else:
        print('    FAIL: 泛音比例与设计不符')
        nfail += 1
    mono = all(amps[i] > amps[i + 1] for i in range(len(amps) - 1))
    print('    %s: 6 个泛音幅度单调递减（高次泛音更弱）' % ('PASS' if mono else 'FAIL'))
    nfail += 0 if mono else 1
    f_ok = all(abs(1200 * np.log2(peak_at(X, df, n * f_meas * np.sqrt(1 + B * n * n), 8)[0]
                         / (n * f_meas * np.sqrt(1 + B * n * n)))) < 60 for n in range(1, 5))
    print('    %s: 前 4 个泛音频率与"非谐性拉伸"模型吻合（<60 cent = 半音的一半）'
          % ('PASS' if f_ok else 'FAIL'))
    nfail += 0 if f_ok else 1

    # ---------------- 2) 复音三和弦 ----------------
    print('\n[2] 三音和弦 C4(60)/E4(64)/G4(67) —— 复音')
    xc = load(d, 'piano_chord.txt')
    found = []
    Xc, dfc = spec(xc)
    for n in (60, 64, 67):
        f_exp_n = et(n) * STRETCH1_IMPL
        # ⚠️ 搜索窗必须窄：8192 点的 df≈11.9 Hz，窗宽 ±10 bin 会把邻近的
        #    C4 峰错认成 E4 峰（第一次就踩了这个坑）
        fm, a, _ = peak_at(Xc, dfc, et(n), span=2)
        dbc = 20 * np.log10(a / Xc.max())
        found.append((n, f_exp_n, fm, dbc))
        print('    note %d  期望 %8.3f Hz  实测 %8.3f Hz  相对最强峰 %+6.1f dB'
              % (n, f_exp_n, fm, dbc))
    ok_ch = all(abs(fm - fe) < 2.0 for _, fe, fm, _ in found)
    print('    %s: 3 个基频同时可测（误差 < 2 Hz）' % ('PASS' if ok_ch else 'FAIL'))
    nfail += 0 if ok_ch else 1

    # ---------------- 3) 力度 → 变亮 ----------------
    print('\n[3] 力度对音色的影响（vel=30 vs vel=120）')
    res = {}
    for tag, name in (('vel30', 'piano_vel030.txt'), ('vel120', 'piano_vel120.txt')):
        xv = load(d, name)
        Xv, dfv = spec(xv)
        fa, aa, _ = peak_at(Xv, dfv, et(69), span=8)
        hi = 0.0
        for n in range(3, 7):
            _, a, _ = peak_at(Xv, dfv, n * fa * np.sqrt(1 + B * n * n), span=8)
            hi += a * a
        res[tag] = (aa, np.sqrt(hi))
        print('    %-6s 基频幅度 %9.1f  3~6 次泛音总幅度(RSS) %9.1f  比值 %+7.2f dB'
              % (tag, aa, np.sqrt(hi), 20 * np.log10(np.sqrt(hi) / aa)))
    d_db = 20 * np.log10(res['vel120'][1] / res['vel120'][0]) - \
           20 * np.log10(res['vel30'][1] / res['vel30'][0])
    print('    vel120 相对 vel30 的高次泛音"提亮" = %+.2f dB（应 > 3 dB）' % d_db)
    ok_v = d_db > 3.0
    print('    %s: 力度增大时高次泛音相对增强（音色变亮）' % ('PASS' if ok_v else 'FAIL'))
    nfail += 0 if ok_v else 1

    # ---------------- 4) 松键衰减 ----------------
    print('\n[4] note-off 后阻音器衰减（A4 松键后 0.08 s 记录）')
    xr = load(d, 'piano_a4_rel.txt')
    nseg = 8
    seg = xr.size // nseg
    print('    分段平均电平：')
    lv = []
    for i in range(nseg):
        s = xr[i * seg:(i + 1) * seg]
        v = float(np.mean(np.abs(s)))
        lv.append(v)
        print('      #%d  t=%5.1f~%5.1f ms  MAV=%8.2f  peak=%6d'
              % (i, i * seg / FS * 1e3, (i + 1) * seg / FS * 1e3, v, int(np.max(np.abs(s)))))
    ok_r = lv[-1] < lv[0] * 0.3
    print('    %s: 从 %.1f 掉到 %.1f（> %.1f dB）'
          % ('PASS' if ok_r else 'FAIL', lv[0], lv[-1],
             20 * np.log10(max(lv[0], 1e-9) / max(lv[-1], 1e-9))))
    nfail += 0 if ok_r else 1

    # ---------------- 5) 按住不放无 sustain 平台 ----------------
    print('\n[5] 按住不放 C6：电平自然下落（无 sustain 平台）')
    xh = load(d, 'piano_hold_c6.txt')
    nseg = 8
    seg = xh.size // nseg
    hv = [float(np.mean(np.abs(xh[i * seg:(i + 1) * seg]))) for i in range(nseg)]
    print('    ' + ' '.join('%.0f' % v for v in hv))
    ok_h = hv[-1] < hv[0]
    print('    %s: 首段 %.0f → 末段 %.0f' % ('PASS' if ok_h else 'FAIL', hv[0], hv[-1]))
    nfail += 0 if ok_h else 1

    print('\n' + '=' * 78)
    print('结论：%s（FAIL 项 %d）' % ('全部判据 PASS' if nfail == 0 else '有 FAIL', nfail))
    print('=' * 78)
    return 0 if nfail == 0 else 1


# =============================================================================
#  表情（拓展②）：颤音 / 滑音 / 延音踏板
# =============================================================================
def section_expression(d, nfail):
    from scipy.signal import butter, filtfilt, hilbert

    print('\n[6] 颤音 Vibrato：vib_depth=127（±49.6 cent）, vib_rate=127（f_lfo=12.7 Hz）')
    xv = load(d, 'piano_vib.txt')
    xn = load(d, 'piano_novib.txt')
    F_LFO = 12.7
    # ---- 6.1 频域：基频周围应出现间隔 ≈ f_lfo 的边带 ----
    print('    基频附近谱线（相对基频峰 dB）：开颤音 vs 关颤音')
    print('      offset(Hz)  开颤音(dB)   关颤音(dB)')
    Xv, dfv = spec(xv)
    Xn, _ = spec(xn)
    for k in range(-3, 4):
        off = k * F_LFO
        f = et(69) + off
        _, av, _ = peak_at(Xv, dfv, f, span=2)
        _, an, _ = peak_at(Xn, dfv, f, span=2)
        _, a0v, _ = peak_at(Xv, dfv, et(69), span=2)
        _, a0n, _ = peak_at(Xn, dfv, et(69), span=2)
        print('      %+6.1f      %7.1f      %7.1f'
              % (off, 20 * np.log10(av / a0v), 20 * np.log10(an / a0n)))
    # 判据：开颤音时 ±f_lfo 处的能量应显著高于关颤音（至少高 10 dB）
    _, a_p, _ = peak_at(Xv, dfv, et(69) + F_LFO, span=2)
    _, a_m, _ = peak_at(Xv, dfv, et(69) - F_LFO, span=2)
    _, a0, _ = peak_at(Xv, dfv, et(69), span=2)
    _, b_p, _ = peak_at(Xn, dfv, et(69) + F_LFO, span=2)
    _, b0, _ = peak_at(Xn, dfv, et(69), span=2)
    sb_on = 20 * np.log10(max(a_p, a_m) / a0)
    sb_off = 20 * np.log10(max(b_p, 1e-9) / b0)
    print('    一次边带相对基频：开颤音 %+.1f dB，关颤音 %+.1f dB' % (sb_on, sb_off))
    if sb_on > sb_off + 10:
        print('    PASS: 开颤音后基频两侧出现边带（+%.1f dB），关掉后消失' % (sb_on - sb_off))
    else:
        print('    FAIL: 边带没有出现或没有随开关变化')
        nfail += 1

    # ---- 6.2 时域：用【外差解调】测瞬时频偏（比 Hilbert+窄带 IIR 稳得多）----
    #   把信号乘 e^{-j2πf0 t} 搬到基带再低通，相位导数就是频偏。
    #   这与 AMY 分析钢琴录音用的是同一套外差思路。
    #   ⚠️ 别用"极窄带通 + Hilbert"：415..468 Hz 的 6 阶 IIR 在 fs=97656 下
    #      归一化带宽只有 0.1%，数值病态（实测直接出 NaN）。
    #   ⚠️ 别用峰峰值：孤立野值会把 pp 从 26 Hz 抬到 48 Hz，用 RMS / 百分位更稳。
    def fm_demod(sig, f0=440.0, lp=80.0):
        n = np.arange(sig.size)
        z = sig.astype(float) * np.exp(-2j * np.pi * f0 * n / FS)
        b, a = butter(4, lp / (FS / 2))
        env = filtfilt(b, a, z)[200:-200]
        fi = np.diff(np.unwrap(np.angle(env))) / (2 * np.pi) * FS
        return fi - fi.mean()

    dev_th = (2 ** (49.6 / 1200) - 1) * et(69)          # 峰值频偏
    fi = fm_demod(xv[4096:4096 + 24576])
    Fi = np.abs(np.fft.rfft(fi * np.hanning(fi.size)))
    fdev = np.fft.rfftfreq(fi.size, 1 / FS)
    keep = fdev > 2.0
    kdev = int(np.argmax(Fi[keep]) + np.flatnonzero(keep)[0])
    p1, p99 = np.percentile(fi, [1, 99])
    print('    外差解调：频偏 RMS=%.2f Hz（理论 %.2f） 1%%~99%% 摆幅=%.2f Hz（理论峰峰 %.2f）'
          % (fi.std(), dev_th / np.sqrt(2), p99 - p1, 2 * dev_th))
    print('    摆动频率实测 %.2f Hz（设计 f_lfo = %.1f Hz）' % (fdev[kdev], F_LFO))
    ok_v1 = abs(fi.std() - dev_th / np.sqrt(2)) < 2.5 and abs(fdev[kdev] - F_LFO) < 1.5
    if ok_v1:
        print('    PASS: 瞬时频偏按 f_lfo 正弦摆动，摆幅与 ±49.6 cent 设计相符')
    else:
        print('    FAIL: 瞬时频率摆动与设计不符')
        nfail += 1

    # ---- 6.3 关颤音时必须完全没有残余抖动 ----
    fin = fm_demod(xn[4096:4096 + 24576])
    print('    关颤音时频偏 RMS = %.3f Hz（开颤音 %.2f Hz，抑制比 %.0f 倍）'
          % (fin.std(), fi.std(), fi.std() / max(fin.std(), 1e-9)))
    if fin.std() * 4 < fi.std():
        print('    PASS: 关颤音后基本无残余抖动')
    else:
        print('    FAIL: 关颤音后仍有抖动')
        nfail += 1

    # =========================================================================
    print('\n[7] 滑音 Glide：glide_time=64（t=256 ms），A4(440) → A5(880)')
    xg = load(d, 'piano_glide.txt')
    win, hop = 2048, 256
    ts, fs_ = [], []
    for s in range(0, xg.size - win, hop):
        seg2 = xg[s:s + win].astype(float)
        X2, df2 = spec(seg2)
        k0 = int(round(et(69) / df2))
        lo2, hi2 = max(1, k0 - 40), min(X2.size - 2, k0 + 80)
        k = lo2 + int(np.argmax(X2[lo2:hi2 + 1]))
        a_, b_, c_ = (np.log(X2[k - 1] + 1e-30), np.log(X2[k] + 1e-30),
                      np.log(X2[k + 1] + 1e-30))
        den = a_ - 2 * b_ + c_
        dd = 0.0 if abs(den) < 1e-30 else 0.5 * (a_ - c_) / den
        ts.append((s + win / 2) / FS * 1e3)
        fs_.append((k + dd) * df2)
    ts = np.array(ts)
    ftr = np.array(fs_)
    # 起点/终点（取中位数，避免纹波）
    f_lo = np.median(ftr[:8])
    f_hi = np.median(ftr[-8:])
    print('    频率轨迹（每 %d 个采样点取一窗）：' % hop)
    step = max(1, len(ts) // 24)
    for i in range(0, len(ts), step):
        print('      t=%6.1f ms   f=%7.1f Hz' % (ts[i], ftr[i]))
    print('    起点 %.1f Hz（记录从滑音【开始后】几毫秒才起，故不是 440）'
          '  终点 %.1f Hz（期望 ≈%.1f）' % (f_lo, f_hi, et(81) * STRETCH1_IMPL))
    # ★ 滑音是【频率线性】的（step 是常数，加在相位增量上），所以拟合要在频率域做，
    #   不能在 log2(f) 域做 —— 后者会把线性斜坡看成微凸，反推 t=0 起点偏到 462 Hz。
    m = (ftr > et(69) * STRETCH1_IMPL + 5) & (ftr < et(81) * STRETCH1_IMPL - 5)
    ss = 0.0
    f_at0 = float('nan')
    slope = float('nan')
    if m.sum() > 4:
        A = np.polyfit(ts[m], ftr[m], 1)
        pred = np.polyval(A, ts[m])
        ss = 1 - ((ftr[m] - pred) ** 2).sum() / ((ftr[m] - ftr[m].mean()) ** 2).sum()
        f_at0 = float(np.polyval(A, 0.0))
        slope = float(A[0])
        print('    线性频率拟合：R²=%.4f  t=0 截距=%.1f Hz  斜率=%.3f Hz/ms'
              % (ss, f_at0, slope))
        print('      设计：440→880 Hz / 256 ms ⇒ 斜率 1.719 Hz/ms、截距 440.0 Hz')
    # 10%→90% 上升时间（按频率跨度）
    t10 = ts[np.argmax(ftr >= et(69) * STRETCH1_IMPL + 0.1 * 440)]
    t90 = ts[np.argmax(ftr >= et(69) * STRETCH1_IMPL + 0.9 * 440)]
    print('    10%%→90%% 上升时间 = %.1f ms（设计 256 ms ⇒ 理论 0.8×256 = 205 ms）'
          % (t90 - t10))
    ok_g = abs(f_at0 - et(69) * STRETCH1_IMPL) < 10 and \
           abs(f_hi - et(81) * STRETCH1_IMPL) < 12 and \
           (150 < (t90 - t10) < 260) and ss > 0.97 and \
           abs(slope - 440.0 / 256.0) < 0.1
    if ok_g:
        print('    PASS: 频率从 A4 连续【线性】滑到 A5（R²=%.4f，斜率 %.3f Hz/ms），'
              '不是瞬间跳变' % (ss, slope))
    else:
        print('    FAIL: 滑音行为与设计不符')
        nfail += 1

    # =========================================================================
    print('\n[8] 延音踏板 Sustain：')
    xs = load(d, 'piano_sustain.txt')
    seg_s = 8
    n_s = xs.size // seg_s
    lv = [float(np.mean(np.abs(xs[i * n_s:(i + 1) * n_s]))) for i in range(seg_s)]
    print('    踏板踩下、已 note-off 的 84 ms 内分段平均电平：'
          + ' '.join('%.0f' % v for v in lv))
    print('    （应持续发声并按「按住」的慢衰减速率下降，而不是阻音器的快衰减）')
    if lv[0] > 100 and lv[-1] > lv[0] * 0.5:
        print('    PASS: 踏板踩下时 note-off 后仍在发声')
    else:
        print('    FAIL: 踏板踩下时声音被放掉了')
        nfail += 1
    return nfail


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    _d = sys.argv[1] if len(sys.argv) > 1 else '.'
    _n = main()
    _n = section_expression(_d, _n)
    print('\n' + '=' * 78)
    print('最终结论（含表情）：%s（FAIL 项 %d）'
          % ('全部判据 PASS' if _n == 0 else '有 FAIL', _n))
    print('=' * 78)
    sys.exit(0 if _n == 0 else 1)
