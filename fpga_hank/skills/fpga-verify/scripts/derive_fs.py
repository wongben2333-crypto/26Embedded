#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""derive_fs.py —— 从 RTL + SDC 推导音频真实采样率 fs（拒绝凭记忆猜）

为什么必须做这件事（本项目实测陷阱）：
  本设计 fs = clk / (BCK_DIV x 帧长) = 50e6 / (2 x 512) = 48828.125 Hz，**不是** 48000。
  tools/verify/check_peaks.py 的 --fs 默认值是 48000；若漏传 --fs，分析器会把
  200 Hz 读成 196.29 Hz（误差 -3.71 Hz > 容差 2 Hz）→ **32 个峰全部判 FAIL**（已实测）。

用法：
  python derive_fs.py                     # 人类可读
  python derive_fs.py --json              # 机器可读（供 verify_spectrum.ps1 调用）
  python derive_fs.py --expect 48000      # 校验某个假设值，不符则退出码 1
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

try:  # 中文 Windows 控制台默认 GBK：个别 Unicode 字符会抛 UnicodeEncodeError
    sys.stdout.reconfigure(errors="replace")
    sys.stderr.reconfigure(errors="replace")
except Exception:
    pass


def fmt_num(x) -> str:
    """48828.125 -> '48828.125'（不能用 :g，6 位有效数字会截成 48828.1）"""
    s = f"{float(x):.6f}".rstrip("0").rstrip(".")
    return s if s else "0"


def project_root_default() -> Path:
    # <root>/.dsh/skills/fpga-verify/scripts/derive_fs.py
    #   parents[0]=scripts [1]=fpga-verify [2]=skills [3]=.dsh [4]=<root>
    return Path(__file__).resolve().parents[4]


def parse_bck_div(text: str):
    m = re.search(r"parameter\s+integer\s+BCK_DIV\s*=\s*(\d+)", text)
    return int(m.group(1)) if m else None


def parse_frame_len(text: str):
    """从 `if (bc_cnt == 9'd511)` 之类取帧长（模值 = N+1）。"""
    cands = re.findall(r"bc_cnt\s*==\s*\d+\s*'\s*d\s*(\d+)", text)
    if not cands:
        return None
    return max(int(c) for c in cands) + 1


def parse_clk_period_ns(sdc_text: str):
    m = re.search(r"create_clock[^\n]*?-period\s+([0-9.]+)", sdc_text)
    return float(m.group(1)) if m else None


def parse_comment_hz(text: str):
    """扫描注释里出现的 `... Hz` 数值（交叉校验用；可能含过时的中间推导值）。"""
    vals = []
    for m in re.finditer(r"([0-9][0-9_ ]*(?:\.[0-9]+)?)\s*Hz", text):
        raw = m.group(1).replace("_", "").replace(" ", "")
        try:
            vals.append(float(raw))
        except ValueError:
            continue
    out = []
    for v in vals:
        if v not in out:
            out.append(v)
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="推导项目真实音频采样率 fs")
    ap.add_argument("--project-root", default=None)
    ap.add_argument("--rtl", default=None, help="pt8211_tx.v 路径（默认 rtl/audio/pt8211_tx.v）")
    ap.add_argument("--sdc", default=None, help=".sdc 路径（默认自动找 constr/*.sdc）")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--expect", type=float, default=None, help="校验值；不符则退出码 1")
    args = ap.parse_args(argv)

    root = Path(args.project_root) if args.project_root else project_root_default()
    rtl = Path(args.rtl) if args.rtl else root / "fpga_hank" / "rtl" / "audio" / "pt8211_tx.v"
    sdcs = [Path(args.sdc)] if args.sdc else sorted((root / "fpga_hank" / "constr").glob("*.sdc"))

    result = {"project_root": str(root), "rtl": str(rtl), "errors": [], "warnings": []}

    if not rtl.exists():
        result["errors"].append(f"未找到 RTL: {rtl}")
        print(json.dumps(result, ensure_ascii=False, indent=2) if args.json else result["errors"][0])
        return 2

    rtl_text = rtl.read_text(encoding="utf-8", errors="replace")
    bck_div = parse_bck_div(rtl_text)
    frame_len = parse_frame_len(rtl_text)
    if bck_div is None:
        result["errors"].append("无法从 RTL 解析 `parameter integer BCK_DIV = N`")
    if frame_len is None:
        result["errors"].append("无法从 RTL 解析帧长（`bc_cnt == <W>'d<N>`）")

    period, sdc_used = None, None
    for s in sdcs:
        if not s.exists():
            continue
        p = parse_clk_period_ns(s.read_text(encoding="utf-8", errors="replace"))
        if p:
            period, sdc_used = p, s
            break
    if period is None:
        result["errors"].append("无法从 .sdc 解析 `create_clock ... -period <ns>`（缺文件或未写 create_clock）")
    if result["errors"]:
        print(json.dumps(result, ensure_ascii=False, indent=2) if args.json else "\n".join(result["errors"]))
        return 2

    clk_hz = 1e9 / period
    fs = clk_hz / (bck_div * frame_len)
    result.update(
        bck_div=bck_div,
        frame_len_clk=frame_len,
        clk_period_ns=period,
        clk_hz=clk_hz,
        sdc=str(sdc_used),
        fs_hz=fs,
        formula=(f"fs = clk / (BCK_DIV x frame_len) = {fmt_num(clk_hz)} / "
                 f"({bck_div} x {frame_len})"),
    )

    comment_hz = parse_comment_hz(rtl_text)
    result["comment_hz_values"] = comment_hz
    near = [v for v in comment_hz if abs(v - fs) < 0.01]
    result["comment_confirms_fs"] = bool(near)
    if not near and comment_hz:
        result["warnings"].append("注释中没有与推导结果一致的 Hz 值（注释可能过时，以 RTL 实际参数为准）")
    others = [v for v in comment_hz if abs(v - fs) >= 0.01]
    if others:
        result["warnings"].append(
            "注释中还有其它 Hz 值，属过时/中间推导值，勿引用: " + ", ".join(fmt_num(v) for v in others)
        )
    if abs(fs - 48000.0) > 1.0:
        result["warnings"].append(
            f"fs={fmt_num(fs)} Hz 与标称 48000 Hz 不同：频谱/延迟计算必须显式使用 {fmt_num(fs)}"
        )

    if args.expect is not None and abs(args.expect - fs) > 0.01:
        result["errors"].append(f"--expect {fmt_num(args.expect)} 与推导值 {fmt_num(fs)} 不符")
        print(json.dumps(result, ensure_ascii=False, indent=2) if args.json
              else f"[FAIL] --expect {fmt_num(args.expect)} != 推导 fs {fmt_num(fs)} Hz")
        return 1

    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print(f"project_root : {root}")
        print(f"RTL          : {rtl}")
        print(f"SDC          : {sdc_used}")
        print(f"BCK_DIV      : {bck_div}")
        print(f"frame_len    : {frame_len} clk")
        print(f"clk          : {fmt_num(clk_hz)} Hz  (period {fmt_num(period)} ns)")
        print(result["formula"])
        print(f"=> fs        : {fmt_num(fs)} Hz")
        if near:
            print("注释佐证     : " + ", ".join(fmt_num(v) for v in near) + " Hz (一致)")
        for w in result["warnings"]:
            print(f"[WARN] {w}")
        print()
        print("check_peaks.py 必须带上的参数：")
        print(f"  --fs {fmt_num(fs)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
