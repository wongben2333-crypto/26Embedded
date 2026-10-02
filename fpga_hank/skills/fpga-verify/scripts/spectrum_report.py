#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""spectrum_report.py —— 32 谱峰取证的**单一入口**：判定 + 增益均匀性 + 出图 + 证据文件

它把 fpga_hank/tools/verify/check_peaks.py 当模块复用（单一事实来源，不复制代码），
额外增加了本项目实测踩到的两条判据：

  C1  32 个期望频率上都检出谱峰（误差 <= --tol-hz）
  C2  每个峰电平 >= --floor-db（保证 32 路"都可闻"）
  C3  没有未预期谱峰（杂散/互调/削波产物）
  C4  【本项目新增】32 路电平离散度 <= --max-spread-db
      —— 这一条能抓到"时分复用 ROM 地址错位导致某一路被读多次/漏读"的缺陷。
      实测案例：tone_bank.v 曾把 voice[0] 每采样读 3 次 → 200 Hz 高出 9.54 dB。

用法：
  python spectrum_report.py --file tone_samples.txt --fs 48828.125
  python spectrum_report.py --file dump.txt --project-root <root> --plot spec.png --md-out EVIDENCE.md
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import sys
from datetime import datetime
from pathlib import Path

import numpy as np

try:  # 中文 Windows 控制台默认 GBK
    sys.stdout.reconfigure(errors="replace")
    sys.stderr.reconfigure(errors="replace")
except Exception:
    pass


def fmt_num(x) -> str:
    s = f"{float(x):.6f}".rstrip("0").rstrip(".")
    return s if s else "0"


def load_checker(path: Path):
    spec = importlib.util.spec_from_file_location("check_peaks_mod", str(path))
    if spec is None or spec.loader is None:
        raise SystemExit(f"无法加载 checker: {path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def derive_fs(root: Path, py_exe: str | None = None) -> float | None:
    """调用同目录的 derive_fs.py 逻辑（直接 import，避免子进程编码问题）。"""
    p = Path(__file__).resolve().parent / "derive_fs.py"
    if not p.exists():
        return None
    spec = importlib.util.spec_from_file_location("derive_fs_mod", str(p))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    import io
    from contextlib import redirect_stdout
    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = mod.main(["--project-root", str(root), "--json"])
    if rc != 0:
        return None
    try:
        return float(json.loads(buf.getvalue())["fs_hz"])
    except Exception:
        return None


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="32 谱峰取证报告（check_peaks 的封装）")
    ap.add_argument("--file", required=True, help="采样 dump")
    ap.add_argument("--format", default="samples",
                    choices=["samples", "i2s-bits", "i2s-words", "pcm16"])
    ap.add_argument("--fs", type=float, default=None,
                    help="采样率；不传则用 --project-root 从 RTL+SDC 推导")
    ap.add_argument("--project-root", default=None)
    ap.add_argument("--checker", default=None,
                    help="check_peaks.py 路径（默认 <root>/fpga_hank/tools/verify/check_peaks.py）")
    ap.add_argument("--count", type=int, default=32)
    ap.add_argument("--start", type=float, default=200.0)
    ap.add_argument("--step", type=float, default=200.0)
    ap.add_argument("--floor-db", type=float, default=-40.0)
    ap.add_argument("--tol-hz", type=float, default=2.0)
    ap.add_argument("--max-spread-db", type=float, default=6.0,
                    help="C4：允许的电平离散度（默认 6 dB；>9.5 dB 强烈提示某路被读多次）")
    ap.add_argument("--plot", default=None)
    ap.add_argument("--xmax", type=float, default=None)
    ap.add_argument("--md-out", default=None)
    ap.add_argument("--json-out", default=None)
    ap.add_argument("--no-plot", action="store_true")
    args = ap.parse_args(argv)

    root = Path(args.project_root) if args.project_root else Path(__file__).resolve().parents[4]
    checker = Path(args.checker) if args.checker else root / "fpga_hank" / "tools" / "verify" / "check_peaks.py"
    if not checker.exists():
        print(f"[ERR] 找不到 checker: {checker}")
        print("      可从 _research/fpga-tools/SPECTRUM-VERIFY.md 第 4 节恢复（该脚本已实测 PASS）")
        return 2

    dump = Path(args.file)
    if not dump.exists():
        print(f"[ERR] 找不到 dump: {dump}")
        return 2

    fs = args.fs
    fs_source = "命令行 --fs"
    if fs is None:
        fs = derive_fs(root)
        fs_source = "derive_fs.py 从 RTL+SDC 推导"
        if fs is None:
            print("[ERR] 未指定 --fs 且无法从 RTL 推导（缺 pt8211_tx.v / .sdc）")
            return 2
    if abs(fs - 48000.0) > 1.0:
        print(f"[提示] fs = {fmt_num(fs)} Hz（不是 48000）。这是本项目真实采样率，"
              f"漏传会让所有谱峰整体偏移而误判 FAIL。")

    m = load_checker(checker)
    freqs = [args.start + args.step * i for i in range(args.count)]

    # ---- 一次性读入字节：避免"边写边读"读到半截文件（本项目实测踩过）----
    # fpga_hank/out/tone_samples.txt 会被正在运行的 ModelSim 持续改写；
    # 逐行读可能读到"写到一半"的内容，从而给出自相矛盾的结论。
    st_before = dump.stat()
    raw = dump.read_bytes()
    file_hash = hashlib.sha256(raw).hexdigest()[:16]
    st_after = dump.stat()
    stable = (st_before.st_size == st_after.st_size and st_before.st_mtime == st_after.st_mtime)

    if args.format == "pcm16":
        x = np.frombuffer(raw, dtype="<i2").astype(float)
    else:
        lines = raw.decode("utf-8", errors="replace").splitlines()
        if args.format == "i2s-bits":
            x = m.parse_i2s_bits_lines(lines).astype(float)
        elif args.format == "i2s-words":
            x = m.parse_word_lines(lines).astype(float)
        else:
            x = m.parse_sample_lines(lines)

    print(f"输入 {dump.name}  格式 {args.format}  样本 {x.size}  fs {fmt_num(fs)} Hz ({fs_source})")
    print(f"     文件 {st_before.st_size} 字节  sha256:{file_hash}  "
          f"mtime {datetime.fromtimestamp(st_before.st_mtime):%H:%M:%S}  "
          f"{'稳定' if stable else '★读取期间被改写★'}")
    if not stable:
        print("[WARNING] 该文件在读取期间又被修改（很可能正被仿真写入）——")
        print("          本次结论【不可作为证据】。请先复制快照再测，例如：")
        print(f"          Copy-Item '{dump}' '<snapshot>'; 再对快照运行本脚本")
    res = m.analyze(x, fs, freqs, args.floor_db, args.tol_hz)
    hit = m.report(res, freqs)

    levels = [r["level"] for r in res["rows"] if r["ok"]]
    spread = (max(levels) - min(levels)) if len(levels) > 1 else 0.0
    c1 = hit == len(freqs)
    c3 = len(res["spurious"]) == 0
    c4 = spread <= args.max_spread_db
    print(f"--- 附加判据 ---")
    print(f"C4 电平离散度 {spread:.2f} dB  (门限 {args.max_spread_db:g} dB)  "
          f"{'PASS' if c4 else 'FAIL'}")
    if not c4:
        hot = sorted(res["rows"], key=lambda r: -r["level"])[:2]
        print("   最响的两路: " + ", ".join(f"{r['expect']:.0f}Hz {r['level']:.2f}dBc" for r in hot))
        print("   离散度接近 9.5 dB 时，几乎一定是某一路每个采样被读了 3 次"
              "（或 6.0 dB 时被读了 2 次）—— 检查时分复用 ROM 的地址推进/流水对齐。")

    if args.plot and not args.no_plot:
        print("频谱图:", m.plot(args.plot, res, freqs, fs, args.xmax))

    verdict = "PASS" if (c1 and c3 and c4) else ("PASS_WITH_WARNING" if (c1 and c3 and not c4) else "FAIL")
    if not stable:
        verdict = "UNSTABLE"
    summary = {
        "timestamp": datetime.now().isoformat(timespec="seconds"),
        "dump": str(dump),
        "file_bytes": st_before.st_size,
        "file_sha256_16": file_hash,
        "file_mtime": datetime.fromtimestamp(st_before.st_mtime).isoformat(timespec="seconds"),
        "file_stable": stable,
        "format": args.format,
        "fs_hz": fs,
        "fs_source": fs_source,
        "checker": str(checker),
        "checker_cmd": (f"python {checker} --file {dump} --format {args.format} "
                        f"--fs {fmt_num(fs)} --count {args.count} "
                        f"--start {fmt_num(args.start)} --step {fmt_num(args.step)}"),
        "n_samples": int(x.size),
        "peaks_detected": int(res["pk"].size),
        "expected": len(freqs),
        "matched": int(hit),
        "missing": [r["expect"] for r in res["rows"] if not r["ok"]],
        "spurious": [[round(f, 3), round(d, 2)] for f, d in res["spurious"]],
        "level_spread_db": round(float(spread), 3),
        "level_min_db": round(min(levels), 2) if levels else None,
        "level_max_db": round(max(levels), 2) if levels else None,
        "criteria": {"C1_all_matched": c1, "C2_all_audible": all(r["ok"] for r in res["rows"]),
                     "C3_no_spurious": c3, "C4_spread_ok": c4},
        "verdict": verdict,
    }

    if args.json_out:
        Path(args.json_out).write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
        print("JSON:", args.json_out)

    if args.md_out:
        md = [
            f"# 32 谱峰取证（{summary['timestamp']}）",
            "",
            f"- 结论：**{verdict}**",
            f"- dump：`{dump}`（{summary['n_samples']} 样本，格式 {args.format}）",
            f"- 文件指纹：sha256:{file_hash}（{st_before.st_size} 字节，mtime {summary['file_mtime']}，"
            f"{'稳定' if stable else '★读取期间被改写，结论无效★'}）",
            f"- 采样率：**{fmt_num(fs)} Hz**（来源：{fs_source}）",
            f"- checker：`{checker}`",
            f"- 复现命令：`{summary['checker_cmd']}`",
            "",
            "| 判据 | 门限 | 实测 | 结论 |",
            "|---|---|---|---|",
            f"| C1 期望谱峰全部命中 | {len(freqs)}/{len(freqs)} | {hit}/{len(freqs)} | "
            f"{'PASS' if c1 else 'FAIL'} |",
            f"| C2 每路可闻 | >= {args.floor_db:g} dBc | 最低 {summary['level_min_db']} dBc | "
            f"{'PASS' if summary['criteria']['C2_all_audible'] else 'FAIL'} |",
            f"| C3 无未预期谱峰 | 0 | {len(res['spurious'])} | {'PASS' if c3 else 'FAIL'} |",
            f"| C4 电平离散度 | <= {args.max_spread_db:g} dB | {spread:.2f} dB | "
            f"{'PASS' if c4 else 'FAIL'} |",
            "",
        ]
        if summary["missing"]:
            md.append("未命中的期望频率：" + ", ".join(f"{v:g} Hz" for v in summary["missing"]))
            md.append("")
        if res["spurious"]:
            md.append("未预期谱峰（前 10）：")
            md.append("")
            md.append("| 频率 Hz | 电平 dBc |")
            md.append("|---|---|")
            for f, d in summary["spurious"][:10]:
                md.append(f"| {f} | {d} |")
            md.append("")
        if args.plot and not args.no_plot:
            md.append(f"![spectrum]({Path(args.plot).name})")
            md.append("")
        Path(args.md_out).write_text("\n".join(md), encoding="utf-8")
        print("证据 markdown:", args.md_out)

    if not stable:
        print("最终结论: UNSTABLE —— 输入文件在读取期间被改写，本次结论无效；请对快照重测")
        return 5
    if c1 and c3 and c4:
        print("最终结论: PASS —— 检出 %d 路独立谱峰，电平离散度 %.2f dB" % (hit, spread))
        return 0
    if c1 and c3:
        print(f"最终结论: 谱峰数达标但增益不均（离散度 {spread:.2f} dB > "
              f"{args.max_spread_db:g} dB）—— 交付前建议修")
        return 4
    print(f"最终结论: FAIL —— 命中 {hit}/{len(freqs)}，杂散 {len(res['spurious'])}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
