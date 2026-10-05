# -*- coding: utf-8 -*-
"""compare_regression.py —— 逐样本比对"加表情前 / 加表情后"的仿真输出

用法：
    python compare_regression.py <改后样本目录> [<改前参考目录>]

默认参考目录 = 本脚本同目录下的 ref_before/（piano-tone 在改动前用同一 TB、同一
激励序列跑出来的原始样本）。判定标准是**逐样本完全一致**（不是"听起来差不多"）：

  这 6 个新输入（glide_on/glide_time/vib_on/vib_depth/vib_rate/sustain）全为 0 时，
  piano_engine 的输出必须与加表情之前逐字节相同。
  实现上是结构性保证：表情关闭 ⇒ 相位增量走回原来的 inc[] 通路，
  note-off 走回原来的 gate_r<=0（见 piano_engine.v 文件头"回归保证"）。

⚠️ 比对的前提是【同一份 TB、同一段激励序列】。本工程的做法是把表情测试
   （T8/T9/T10）**追加**在原有 T1~T7 之后，因此 T1~T7 落盘的文件可直接比对。
"""
from __future__ import annotations

import hashlib
import os
import sys

FILES = [
    "piano_a4.txt",       # 单音 A4
    "piano_a4_rel.txt",   # note-off 后衰减
    "piano_chord.txt",    # 三音和弦
    "piano_vel030.txt",   # 力度 30
    "piano_vel120.txt",   # 力度 120
    "piano_hold_c6.txt",  # 按住不放
    "piano_poly8.txt",    # 8 音满复音
]


def main() -> int:
    new_dir = sys.argv[1] if len(sys.argv) > 1 else "."
    ref_dir = sys.argv[2] if len(sys.argv) > 2 else \
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "ref_before")
    print("改前参考 = %s" % ref_dir)
    print("改后样本 = %s" % new_dir)
    print("%-20s %8s %8s  %-22s %s" % ("文件", "行数(前)", "行数(后)", "逐样本比对", "sha256(前/后)"))
    bad = 0
    for f in FILES:
        pa, pb = os.path.join(ref_dir, f), os.path.join(new_dir, f)
        if not os.path.exists(pa) or not os.path.exists(pb):
            print("%-20s %8s %8s  %s" % (f, "-", "-", "缺文件（跳过）"))
            bad += 1
            continue
        ba, bb = open(pa, "rb").read(), open(pb, "rb").read()
        a = ba.decode().strip().split("\n")
        b = bb.decode().strip().split("\n")
        ha = hashlib.sha256(ba).hexdigest()[:12]
        hb = hashlib.sha256(bb).hexdigest()[:12]
        if len(a) != len(b):
            print("%-20s %8d %8d  %-22s %s/%s" % (f, len(a), len(b), "长度不同 ⇒ 不一致", ha, hb))
            bad += 1
            continue
        diff = sum(1 for x, y in zip(a, b) if x != y)
        same = "逐样本一致" if diff == 0 else "有 %d 个样本不同" % diff
        print("%-20s %8d %8d  %-22s %s/%s" % (f, len(a), len(b), same, ha, hb))
        if diff:
            bad += 1
    print()
    if bad == 0:
        print("回归结论：PASS —— 6 个表情输入全 0 时，输出与加表情之前【逐样本完全一致】")
    else:
        print("回归结论：FAIL —— 有 %d 个文件不一致" % bad)
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    sys.exit(main())
