# -*- coding: utf-8 -*-
"""inspect_spectrum.py —— 在指定频段直接打印频谱能量，用于定位"某一路没出声"

比逐条比对更有用：直接看目标频率附近有没有峰，以及峰在哪。
"""
from __future__ import annotations

import argparse
import sys

import numpy as np
from scipy.signal import windows

sys.stdout.reconfigure(encoding='utf-8')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--file', required=True)
    ap.add_argument('--fs', type=float, default=48828.125)
    ap.add_argument('--around', type=float, action='append', default=[],
                    help='要查看的频率，可多次指定')
    ap.add_argument('--span', type=float, default=100.0, help='查看带宽 ±span Hz')
    ap.add_argument('--top', type=int, default=40, help='打印最强的 N 个峰')
    args = ap.parse_args()

    x = np.loadtxt(args.file, dtype=np.float64)
    x = x - np.mean(x)
    n = len(x)
    w = windows.blackmanharris(n)
    X = np.abs(np.fft.rfft(x * w))
    X /= (np.max(X) + 1e-30)
    Xdb = 20 * np.log10(X + 1e-30)
    freqs = np.fft.rfftfreq(n, d=1.0 / args.fs)

    print('samples=%d  fs=%.3f  res=%.4f Hz' % (n, args.fs, args.fs / n))

    if args.around:
        for f0 in args.around:
            lo, hi = f0 - args.span, f0 + args.span
            m = (freqs >= lo) & (freqs <= hi)
            if not m.any():
                print('  %.1f Hz: 超出范围' % f0)
                continue
            sub_f, sub_d = freqs[m], Xdb[m]
            k = int(np.argmax(sub_d))
            print('  目标 %8.1f Hz -> 附近最强 %.2f Hz (%.1f dBc)'
                  % (f0, sub_f[k], sub_d[k]))
    else:
        # 打印全局最强的 top N 个峰
        idx = np.argsort(Xdb)[::-1][:args.top]
        idx = np.sort(idx)
        print('最强的 %d 个谱峰：' % args.top)
        for i in idx:
            print('   %9.2f Hz  %7.2f dBc' % (freqs[i], Xdb[i]))


if __name__ == '__main__':
    main()
