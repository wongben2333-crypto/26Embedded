# -*- coding: utf-8 -*-
"""check_pitch.py —— 用 FFT 验证【半音变调】是否真的改变了音高

★ 为什么用 FFT 而不是数过零：
  第一版 tb_pitch 数过零率，实测 4000 个采样点只数到 0~1 次过零
  （200 Hz 在 97.656 kHz 下应有约 16 次），测量本身不可靠，
  既不能证明也不能证伪。已如实记录在 git e28de9f。
  本脚本改用与 check_peaks.py 同一套 FFT + Blackman 窗方法，
  而 check_peaks.py 已稳定给出 32/32 的可靠结果。

判据（固定期望值，不用相对比值，避免两个测量误差相乘）：
    基频 200 Hz
    pitch_semi =  0 -> 200.00 Hz
    pitch_semi = +7 -> 200 * 2^(7/12)  = 299.657 Hz
    pitch_semi = -5 -> 200 * 2^(-5/12) = 149.831 Hz

用法：
    python tools/verify/check_pitch.py --dir out/pitch --fs 97656.25
"""
from __future__ import annotations

import argparse
import os
import sys

import numpy as np

sys.stdout.reconfigure(encoding='utf-8')

BASE_HZ = 200.0
CASES = [0, 7, -5]


def load(path):
    v = []
    with open(path, encoding='utf-8', errors='replace') as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                v.append(int(line))
            except ValueError:
                pass
    return np.array(v, dtype=float)


def peak_hz(x, fs):
    """返回 (最低谱峰频率, 峰值, 次高峰频率)——用来确认不是只找到一个峰。"""
    x = x - x.mean()
    w = np.blackman(len(x))
    sp = np.abs(np.fft.rfft(x * w))
    fr = np.fft.rfftfreq(len(x), 1.0 / fs)
    # 只看 80..1000 Hz（基频应落在这个范围）
    m = (fr >= 80) & (fr <= 1000)
    if not m.any():
        return None, 0.0, None
    spm, frm = sp[m], fr[m]
    i = int(np.argmax(spm))
    # 用抛物线插值细化峰值位置（比直接取 bin 中心准得多）
    if 0 < i < len(spm) - 1:
        y0, y1, y2 = spm[i - 1], spm[i], spm[i + 1]
        denom = (y0 - 2 * y1 + y2)
        delta = 0.5 * (y0 - y2) / denom if denom != 0 else 0.0
    else:
        delta = 0.0
    df = fr[1] - fr[0]
    return frm[i] + delta * df, spm[i], df


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dir', required=True, help='存放 pitch_<n>.txt 的目录')
    ap.add_argument('--fs', type=float, required=True, help='实际采样率（必须填对）')
    ap.add_argument('--tol', type=float, default=1.0, help='频率容差 Hz')
    args = ap.parse_args()

    print('=' * 74)
    print('半音变调验证（FFT 谱峰定位）  fs = %.4f Hz' % args.fs)
    print('=' * 74)
    print('%-12s %-14s %-14s %-10s %s' % ('pitch_semi', '期望(Hz)', '实测(Hz)', '误差(Hz)', '结论'))

    ok = 0
    total = 0
    for n in CASES:
        p = os.path.join(args.dir, 'pitch_%d.txt' % n)
        if not os.path.exists(p):
            print('%-12d %-14s %-14s %-10s %s' % (n, '-', '-', '-', '缺文件 %s' % p))
            continue
        x = load(p)
        if len(x) < 4096:
            print('%-12d %-14s %-14s %-10s %s' % (n, '-', '-', '-', '样本仅 %d 个，太少' % len(x)))
            continue
        f_exp = BASE_HZ * (2.0 ** (n / 12.0))
        f_meas, mag, df = peak_hz(x, args.fs)
        total += 1
        if f_meas is None or mag <= 0:
            print('%-12d %-14.3f %-14s %-10s %s' % (n, f_exp, '未找到谱峰', '-', 'FAIL'))
            continue
        err = f_meas - f_exp
        good = abs(err) <= args.tol
        ok += 1 if good else 0
        print('%-12d %-14.3f %-14.3f %-+10.3f %s' % (n, f_exp, f_meas, err, 'PASS' if good else 'FAIL'))

    print('-' * 74)
    print('通过 %d / %d   （频率分辨率 %.3f Hz，容差 ±%.1f Hz）' % (ok, total, df if total else 0, args.tol))
    if total == 0:
        print('结论: 无有效数据，无法判定')
        return 2
    if ok == total:
        print('结论: PASS - 半音变调确实改变了音高，且与理论值在容差内一致')
        return 0
    # 关键诊断：如果所有档位的谱峰都落在同一个频率，说明变调【完全没生效】
    fm = []
    for n in CASES:
        p = os.path.join(args.dir, 'pitch_%d.txt' % n)
        if os.path.exists(p):
            x = load(p)
            if len(x) >= 4096:
                f, _, _ = peak_hz(x, args.fs)
                if f is not None:
                    fm.append(round(f, 3))
    if len(fm) >= 2 and max(fm) - min(fm) < 1.0:
        print('结论: FAIL - 各档位谱峰都在 ~%.1f Hz，**变调没有生效**' % fm[0])
    else:
        print('结论: FAIL - 部分档位与理论值不符，见上表')
    return 1


if __name__ == '__main__':
    sys.exit(main())
