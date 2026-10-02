# -*- coding: utf-8 -*-
"""check_pitch_shift.py —— 验证【半音变调】是否真的改变了音高（逐峰比对理论值）

★ 为什么不直接复用 check_peaks.py：
  check_peaks.py 只能按**整数**网格判定（--start/--step 是整数），
  而变调 +7 半音后的真实间距是 **299.657 Hz**（非整数）。
  按 step 300 判会累积漂移：到第 32 峰偏约 11 Hz，于是全部被误报为"杂散"。
  ⇒ 本脚本改为**逐峰与理论值比对**：找出最强的 32 个局部峰，
     与 200 × 2^(n/12) × (i+1) 逐一比较，报平均相对误差。

判据：
    检出 32 个峰，且平均相对误差 < 0.5%  → PASS（exit 0）
    否则 → FAIL（exit 1）

用法：
    python tools/verify/check_pitch_shift.py --file docs/evidence/tone_samples_pitch7.txt \
        --fs 97656.25 --semi 7
"""
from __future__ import annotations

import argparse
import sys

import numpy as np

sys.stdout.reconfigure(encoding='utf-8')

BASE_HZ = 200.0


def find_peaks(x, fs, fmin, fmax, nwant):
    """返回按幅度降序的前 nwant 个局部峰频率（按频率升序输出）。"""
    x = x - x.mean()
    w = np.blackman(len(x))
    sp = np.abs(np.fft.rfft(x * w))
    fr = np.fft.rfftfreq(len(x), 1.0 / fs)
    m = (fr > fmin) & (fr < fmax)
    spm, frm = sp[m], fr[m]
    cand = []
    for i in range(2, len(spm) - 2):
        if (spm[i] > spm[i - 1] and spm[i] > spm[i - 2] and
                spm[i] > spm[i + 1] and spm[i] > spm[i + 2]):
            cand.append((frm[i], spm[i]))
    cand.sort(key=lambda t: -t[1])
    return sorted(p[0] for p in cand[:nwant])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--file', required=True)
    ap.add_argument('--fs', type=float, required=True)
    ap.add_argument('--semi', type=int, default=7, help='半音数（用于算理论值）')
    ap.add_argument('--count', type=int, default=32)
    ap.add_argument('--tol-pct', type=float, default=0.5, help='平均相对误差上限（百分数，默认 0.5 表示 0.5%%）')
    args = ap.parse_args()

    vals = []
    with open(args.file, encoding='utf-8', errors='replace') as fh:
        for line in fh:
            line = line.strip()
            if line:
                try:
                    vals.append(int(line))
                except ValueError:
                    pass
    x = np.array(vals, dtype=float)
    if len(x) < 4096:
        print('FAIL: 样本仅 %d 个，太少' % len(x))
        return 1

    ratio = 2.0 ** (args.semi / 12.0)
    f_lo = BASE_HZ * ratio * 0.6
    f_hi = BASE_HZ * ratio * args.count * 1.8

    top = find_peaks(x, args.fs, f_lo, f_hi, args.count)
    exp = [BASE_HZ * ratio * (i + 1) for i in range(args.count)]

    print('  样本数        : %d' % len(x))
    print('  检出峰数      : %d  (期望 %d)' % (len(top), args.count))
    if len(top) >= 3:
        print('  前 3 峰 实测  : %s' % ' '.join('%.1f' % f for f in top[:3]))
        print('  前 3 峰 理论  : %s' % ' '.join('%.2f' % f for f in exp[:3]))
        print('  后 3 峰 实测  : %s' % ' '.join('%.1f' % f for f in top[-3:]))
        print('  后 3 峰 理论  : %s' % ' '.join('%.2f' % f for f in exp[-3:]))

    if len(top) != args.count:
        print('结论: FAIL - 检出 %d 个峰，期望 %d 个' % (len(top), args.count))
        return 1

    errs = [abs(top[i] - exp[i]) / exp[i] for i in range(args.count)]
    mean_pct = 100.0 * float(np.mean(errs))
    max_pct = 100.0 * float(np.max(errs))
    print('  平均相对误差  : %.4f %%' % mean_pct)
    print('  最大相对误差  : %.4f %%' % max_pct)
    print('-' * 74)
    if mean_pct < args.tol_pct:
        print('结论: PASS - 半音变调 +%d 确实生效：%d 个谱峰整体移动 %.4f 倍'
              % (args.semi, args.count, ratio))
        return 0
    print('结论: FAIL - 平均相对误差 %.4f%% 超过 %.1f%%' % (mean_pct, args.tol_pct))
    return 1


if __name__ == '__main__':
    sys.exit(main())
