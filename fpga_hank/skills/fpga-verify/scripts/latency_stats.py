#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""latency_stats.py —— 控制→发声延迟统计（赛题要 P50/P95/P99/max，不是"大概很快"）

输入 CSV 每行一个延迟值：
  - 纯数字：按 --unit 解释（us / ms / cycles）
  - 两列 "t_control,t_sound"：同一单位的时间戳，自动相减
  - 可含表头行与 # 注释

输出：可直接贴进报告的 markdown 表格 + 硬指标判定。
判据（AGENTS.md §1）：基础要求 ≤10 ms；拓展③要求 ≤5 ms **且确定性无抖动**。

示例：
  python latency_stats.py --file lat.csv --unit us
  python latency_stats.py --file lat.csv --unit cycles --clk-mhz 50 --markdown
"""
from __future__ import annotations

import argparse
import statistics
import sys
from pathlib import Path

try:  # 中文 Windows 控制台默认 GBK：U+2212 等字符会抛 UnicodeEncodeError
    sys.stdout.reconfigure(errors="replace")
    sys.stderr.reconfigure(errors="replace")
except Exception:
    pass


def load_rows(path: Path):
    rows = []
    for ln in path.read_text(encoding="utf-8", errors="replace").splitlines():
        s = ln.strip()
        if not s or s.startswith("#") or s.startswith("//"):
            continue
        parts = [p for p in s.replace(",", " ").replace("\t", " ").split() if p]
        try:
            vals = [float(p) for p in parts[:2]]
        except ValueError:
            continue  # 表头
        if not vals:
            continue
        rows.append(vals)
    return rows


def stats(vals):
    vals = sorted(vals)
    n = len(vals)

    def pct(p):
        if n == 1:
            return vals[0]
        idx = p / 100.0 * (n - 1)
        lo, hi = int(idx), min(int(idx) + 1, n - 1)
        return vals[lo] + (vals[hi] - vals[lo]) * (idx - lo)

    return {
        "n": n,
        "min": vals[0],
        "p50": pct(50),
        "p95": pct(95),
        "p99": pct(99),
        "max": vals[-1],
        "mean": statistics.fmean(vals),
        "jitter_max_min": vals[-1] - vals[0],
        "stdev": statistics.pstdev(vals) if n > 1 else 0.0,
    }


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="控制->发声延迟统计")
    ap.add_argument("--file", required=True)
    ap.add_argument("--unit", default="us", choices=["us", "ms", "cycles"])
    ap.add_argument("--clk-mhz", type=float, default=50.0, help="--unit cycles 时用于换算成 ms")
    ap.add_argument("--hard-ms", type=float, default=10.0, help="基础要求上限")
    ap.add_argument("--ext-ms", type=float, default=5.0, help="拓展要求上限")
    ap.add_argument("--jitter-ms", type=float, default=0.0,
                    help="确定性判据：max-min 允许值（0 表示要求完全无抖动）")
    ap.add_argument("--markdown", action="store_true")
    args = ap.parse_args(argv)

    p = Path(args.file)
    if not p.exists():
        print(f"[ERR] 找不到 {p}")
        return 2
    rows = load_rows(p)
    if not rows:
        print(f"[ERR] {p} 里没有可解析的数据行")
        return 2

    if len(rows[0]) >= 2:
        vals = [r[1] - r[0] for r in rows]
        mode = "两列时间戳相减"
    else:
        vals = [r[0] for r in rows]
        mode = "单列延迟值"
    vals = [v for v in vals if v >= 0]
    if not vals:
        print("[ERR] 无有效延迟值")
        return 2

    if args.unit == "us":
        to_ms = 1e-3
    elif args.unit == "ms":
        to_ms = 1.0
    else:
        to_ms = 1000.0 / (args.clk_mhz * 1e6)  # cycles -> ms

    s = stats(vals)
    ms = {k: s[k] * to_ms for k in ("min", "p50", "p95", "p99", "max", "mean",
                                    "jitter_max_min", "stdev")}

    ok_hard = ms["max"] <= args.hard_ms
    ok_ext = ms["p99"] <= args.ext_ms
    ok_det = ms["jitter_max_min"] <= args.jitter_ms

    if args.markdown:
        print("| 指标 | 值 | 判据 | 结论 |")
        print("|---|---|---|---|")
        print(f"| 样本数 | {s['n']} | — | — |")
        for k, label in (("min", "最小"), ("p50", "P50"), ("p95", "P95"),
                         ("p99", "P99"), ("max", "最大")):
            print(f"| {label} | {ms[k]:.3f} ms | — | — |")
        print(f"| 抖动 (max-min) | {ms['jitter_max_min']:.3f} ms | <= {args.jitter_ms:g} ms | "
              f"{'PASS' if ok_det else 'FAIL'} |")
        print(f"| 基础要求 | max | ≤ {args.hard_ms:g} ms | {'PASS' if ok_hard else 'FAIL'} |")
        print(f"| 拓展要求 | P99 | ≤ {args.ext_ms:g} ms | {'PASS' if ok_ext else 'FAIL'} |")
    else:
        print(f"输入: {p}  ({mode}, 单位 {args.unit}, 样本 {s['n']})")
        print(f"  min={ms['min']:.3f}  P50={ms['p50']:.3f}  P95={ms['p95']:.3f}  "
              f"P99={ms['p99']:.3f}  max={ms['max']:.3f}  (ms)")
        print(f"  抖动 max-min={ms['jitter_max_min']:.3f} ms  stdev={ms['stdev']:.3f} ms")
        print(f"[{'PASS' if ok_hard else 'FAIL'}] 基础: max {ms['max']:.3f} <= {args.hard_ms:g} ms")
        print(f"[{'PASS' if ok_ext else 'FAIL'}] 拓展: P99 {ms['p99']:.3f} <= {args.ext_ms:g} ms")
        print(f"[{'PASS' if ok_det else 'FAIL'}] 确定性: 抖动 {ms['jitter_max_min']:.3f} <= "
              f"{args.jitter_ms:g} ms")

    return 0 if (ok_hard and ok_ext and ok_det) else 1


if __name__ == "__main__":
    sys.exit(main())
