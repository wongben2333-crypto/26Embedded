#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""make_fixture.py —— 生成合成采样 dump，让整条频谱取证链在**没有 ModelSim / 没有板子**时也能自检。

用途：
  1. 验证 check_peaks.py 与判据本身可用（正例）
  2. 生成**负对照**（少发几路 → 判据必须报未命中）
  3. 生成**灵敏度对照**（人为削波/降位深 → 判据必须报杂散，否则说明判据过松）

输出格式与 fpga_hank/sim/tb/tb_spectrum.v 的 dump 一致：每行一个十进制有符号样本。

示例：
  python make_fixture.py --out _tmp_ok.txt
  python make_fixture.py --out _tmp_16.txt --count 16
  python make_fixture.py --out _tmp_clip.txt --clip 0.5
  python make_fixture.py --out _tmp_i2s.csv --format i2s-bits
"""
from __future__ import annotations

import argparse
import sys

import numpy as np

try:  # 中文 Windows 控制台默认 GBK
    sys.stdout.reconfigure(errors="replace")
    sys.stderr.reconfigure(errors="replace")
except Exception:
    pass


def fmt_num(x) -> str:
    """48828.125 -> '48828.125'（:g 只有 6 位有效数字，会截成 48828.1）"""
    s = f"{float(x):.6f}".rstrip("0").rstrip(".")
    return s if s else "0"


def build(fs, n, freqs, amp_dbfs, dac_bits, clip, seed):
    rng = np.random.default_rng(seed)
    t = np.arange(n) / fs
    x = np.zeros(n)
    for f in freqs:
        x += np.sin(2.0 * np.pi * f * t + rng.uniform(0, 2 * np.pi))
    x /= max(float(np.max(np.abs(x))), 1e-12)     # 归一化到 ±1
    if clip < 1.0:
        # ★ 先对【归一化】信号限幅再缩放：这样 --clip 0.5 无论 amp 取多少都会真正削波。
        #   （若放在 amp 之后限幅，amp=-12 dBFS 时峰值仅 0.25，clip 0.5 永远不会触发 —— 曾踩过。）
        x = np.clip(x, -clip, clip)
    amp = 10.0 ** (amp_dbfs / 20.0)
    x = x * amp
    q = (1 << (dac_bits - 1)) - 1
    return np.round(x * q).astype(np.int64)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="生成 32 音合成采样 dump")
    ap.add_argument("--out", required=True)
    ap.add_argument("--fs", type=float, default=48828.125, help="默认取本项目真实 fs")
    ap.add_argument("--n", type=int, default=65536)
    ap.add_argument("--start", type=float, default=200.0)
    ap.add_argument("--step", type=float, default=200.0)
    ap.add_argument("--count", type=int, default=32)
    ap.add_argument("--amp-dbfs", type=float, default=-12.0)
    ap.add_argument("--dac-bits", type=int, default=16)
    ap.add_argument("--clip", type=float, default=1.0,
                    help="对【归一化】信号硬限幅后再缩放（<1.0 即引入非线性，用于灵敏度对照）")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--format", default="samples", choices=["samples", "i2s-bits"])
    args = ap.parse_args(argv)

    freqs = [args.start + args.step * i for i in range(args.count)]
    q = build(args.fs, args.n, freqs, args.amp_dbfs, args.dac_bits, args.clip, args.seed)

    if args.format == "samples":
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write("\n".join(str(int(v)) for v in q))
            fh.write("\n")
    else:
        # 每个 BCLK 一行 "ws,din"：16bit 左声道，MSB 延迟 1 bit（Philips I2S），右声道静音
        lines = []
        for fi, s in enumerate(q):
            u = int(s) & 0xFFFF
            w = (u << 15) & 0xFFFFFFFF
            ws = 0 if fi % 2 == 0 else 1
            for k in range(32):
                lines.append(f"{ws},{(w >> (31 - k)) & 1}")
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines))
            fh.write("\n")

    print(f"wrote {args.out}: {q.size} samples  fs={fmt_num(args.fs)}  voices={args.count}  "
          f"clip={args.clip}  amp={args.amp_dbfs} dBFS  format={args.format}")
    print("接着运行（注意 --fs 必须显式给出）：")
    fmt = "i2s-bits" if args.format == "i2s-bits" else "samples"
    print(f"  python fpga_hank/tools/verify/check_peaks.py --file {args.out} "
          f"--format {fmt} --fs {fmt_num(args.fs)} --count {args.count} "
          f"--start {fmt_num(args.start)} --step {fmt_num(args.step)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
