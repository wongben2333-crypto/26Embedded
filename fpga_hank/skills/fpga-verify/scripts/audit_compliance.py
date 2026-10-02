#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""audit_compliance.py —— 赛题红线自审（可在提交前反复跑）

赛题硬约束（AGENTS.md §1）：
  🚫 严禁播放预录 PCM / 预置推流 / 整段录音触发（现场用频谱 + RTL 代码审查双重验证）
  🚫 不得用 CPU / 软核承担音频合成算法（AE350 只能做参数配置或 UI）
  ✅ 全 HDL、逐样本、逐声部运算

本脚本把这三条变成可机检的启发式规则，输出带 file:line 证据的报告。
它不是"代替评委"，而是**提交前把明显踩线的地方先找出来**。

退出码：0 = 未见红线；3 = 仅有需人工确认项；1 = 命中红线。
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

try:
    sys.stdout.reconfigure(errors="replace")
    sys.stderr.reconfigure(errors="replace")
except Exception:
    pass

RTL_EXT = {".v", ".sv", ".vh", ".svh"}
AUDIO_EXT = {".wav", ".mp3", ".flac", ".ogg", ".aac", ".m4a", ".pcm", ".raw", ".aiff"}
INIT_EXT = {".mem", ".hex", ".coe", ".mif", ".dat"}
SKIP_DIRS = {"out", "work", "transcript", "_tools", ".git", "sim_build", "obj_dir", "eda_proj"}


def iter_files(root: Path):
    for p in root.rglob("*"):
        if p.is_dir():
            continue
        if any(part in SKIP_DIRS for part in p.parts):
            continue
        yield p


def scan_text(path: Path, pattern: str):
    hits = []
    try:
        for i, ln in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            if re.search(pattern, ln):
                hits.append((i, ln.strip()[:150]))
    except Exception:
        pass
    return hits


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="FPGA 赛题红线自审")
    ap.add_argument("--root", default=None, help="扫描根目录（默认 <root>/fpga_hank）")
    ap.add_argument("--json-out", default=None)
    ap.add_argument("--md-out", default=None)
    ap.add_argument("--big-mem-threshold", type=int, default=1024,
                    help="RTL 内存数组深度超过此值即提示（默认 1024）")
    args = ap.parse_args(argv)

    root = Path(args.root) if args.root else Path(__file__).resolve().parents[4] / "fpga_hank"
    if not root.exists():
        print(f"[ERR] 找不到 {root}")
        return 2

    findings = []   # (level, rule, detail, evidence)

    def add(level, rule, detail, ev=""):
        findings.append({"level": level, "rule": rule, "detail": detail, "evidence": ev})

    files = list(iter_files(root))
    rtl_files = [p for p in files if p.suffix.lower() in RTL_EXT]
    rtl_synth = [p for p in rtl_files if "tb" not in p.parts and "sim" not in p.parts]

    # R1: 可综合 RTL 里的 $readmemh/$readmemb（最典型的"预录样本"入口）
    for p in rtl_synth:
        for ln, txt in scan_text(p, r"\$readmem[hb]"):
            add("FAIL", "R1 预录样本 ROM 入口",
                f"可综合 RTL 中出现 $readmemh/$readmemb：{txt}",
                f"{p.relative_to(root)}:{ln}")
    if not any(f["rule"].startswith("R1") for f in findings):
        add("PASS", "R1 预录样本 ROM 入口", "可综合 RTL 中未出现 $readmemh/$readmemb")

    # R2: 仓库里的音频样本文件
    audio = [p for p in files if p.suffix.lower() in AUDIO_EXT]
    if audio:
        detail = "; ".join(f"{p.relative_to(root)} ({p.stat().st_size // 1024} KB)" for p in audio[:8])
        add("FAIL", "R2 音频样本文件", f"发现 {len(audio)} 个音频文件，交付物里不应存在样本音频", detail)
    else:
        add("PASS", "R2 音频样本文件", "未发现 .wav/.mp3/.pcm 等样本文件")

    # R3: 大体量初始化文件（可能是采样表）
    init_files = []
    for p in files:
        if p.suffix.lower() in INIT_EXT and p.stat().st_size > 8192:
            init_files.append(p)
    if init_files:
        detail = "; ".join(f"{p.relative_to(root)} ({p.stat().st_size // 1024} KB)" for p in init_files[:8])
        add("WARN", "R3 初始化数据文件", f"{len(init_files)} 个较大的 .mem/.hex/.coe 文件，需确认是查找表而非采样", detail)
    else:
        add("PASS", "R3 初始化数据文件", "无大体积初始化数据文件")

    # R4: RTL 里的大内存数组（可能是波形表）
    for p in rtl_synth:
        for ln, txt in scan_text(p, r"\b(reg|wire|logic)\b[^;]*\[\s*(\d+)\s*:\s*0\s*\]"):
            m = re.search(r"\[\s*(\d+)\s*:\s*0\s*\]", txt)
            if m and int(m.group(1)) + 1 > args.big_mem_threshold:
                add("WARN", "R4 RTL 大内存数组",
                    f"深度 {int(m.group(1)) + 1} 的数组：{txt}（正弦表 256/1024 项属正常；"
                    f"上万元素的表要能说清来源）",
                    f"{p.relative_to(root)}:{ln}")

    # R5: CPU/软核是否出现在音频路径
    cpu_pat = r"AE350|\briscv\b|RV32|\bcpu_|soft_core|micropython"
    cpu_hits = []
    for p in rtl_files:
        for ln, txt in scan_text(p, cpu_pat):
            cpu_hits.append((p, ln, txt))
    if cpu_hits:
        ev = "; ".join(f"{p.relative_to(root)}:{ln}" for p, ln, _ in cpu_hits[:6])
        add("WARN", "R5 CPU 参与音频路径",
            f"RTL 中出现 CPU/软核相关标识 {len(cpu_hits)} 处：赛题禁止 CPU 承担音频合成算法"
            f"（只能做参数配置/UI）。若这些引用出现在 mix/osc/adsr 路径上即为踩线。", ev)
    else:
        add("PASS", "R5 CPU 参与音频路径", "RTL 中未发现 CPU/软核标识，音频通路为纯 RTL")

    # R6: 测试模式是否存在（赛题必备交付物）
    test_hits = []
    for p in rtl_synth:
        for ln, txt in scan_text(p, r"test_mode|tone_bank|TEST_MODE|mode_test"):
            test_hits.append((p, ln, txt))
            break
    if test_hits:
        add("PASS", "R6 测试模式", "发现测试模式/音源模块：" +
            ", ".join(str(p.relative_to(root)) for p, _, _ in test_hits))
    else:
        add("WARN", "R6 测试模式", "未在 RTL 中找到测试模式标识（赛题必备交付物：能输出 N 路均匀频率）")

    # R7: 逐样本并行振荡器结构的迹象（相位累加器数量）
    acc_hits = []
    for p in rtl_synth:
        for ln, txt in scan_text(p, r"acc\s*\[|phase_acc|phase\b"):
            acc_hits.append((p, ln, txt))
    add("INFO", "R7 相位累加器", f"发现 {len(acc_hits)} 处相位累加器相关代码；"
        f"报告里应给出「独立相位累加器 + 频率调控 + 包络控制」的框图对照")

    # 汇总
    fails = [f for f in findings if f["level"] == "FAIL"]
    warns = [f for f in findings if f["level"] == "WARN"]
    print("=== 赛题红线自审 ===")
    print(f"扫描根: {root}   RTL 文件 {len(rtl_synth)} 个（可综合）")
    for f in findings:
        mark = {"FAIL": "[FAIL]", "WARN": "[WARN]", "PASS": "[ ok ]", "INFO": "[info]"}[f["level"]]
        print(f"{mark} {f['rule']}: {f['detail']}")
        if f["evidence"]:
            print(f"        {f['evidence']}")
    print(f"--- 汇总: FAIL {len(fails)}  WARN {len(warns)} ---")
    verdict = "FAIL" if fails else ("REVIEW" if warns else "PASS")
    print("结论:", verdict)

    if args.json_out:
        Path(args.json_out).write_text(
            json.dumps({"root": str(root), "verdict": verdict, "findings": findings},
                       ensure_ascii=False, indent=2), encoding="utf-8")
    if args.md_out:
        lines = [f"# 赛题红线自审（{root}）", "", f"结论：**{verdict}**", "",
                 "| 级别 | 规则 | 说明 | 证据 |", "|---|---|---|---|"]
        for f in findings:
            lines.append(f"| {f['level']} | {f['rule']} | {f['detail']} | {f['evidence']} |")
        Path(args.md_out).write_text("\n".join(lines), encoding="utf-8")
        print("markdown:", args.md_out)

    return 1 if fails else (3 if warns else 0)


if __name__ == "__main__":
    sys.exit(main())
