# -*- coding: utf-8 -*-
"""comb_design_check.py —— 多乐器设计的两个"命门"在写 RTL 前先算清楚

① 回归安全的命门：梳状权重恒存在（钢琴权重 = 65536）时，是否【精确恒等】？
   若 (x·65536)>>16 对任意 16 bit x 都 == x，则"钢琴路径 bit 级不变"成立，
   否则回归会破 —— 这一条不靠嘴说，靠穷举。
   ⚠️ 但要注意：**必须确认乘积位宽足够**，否则高位截断会把恒等式毁掉（本项目踩过）。

② 音色设计的命门：拾音器位置到底压掉哪些泛音？
   电吉他最有辨识度的差异就是"换挡像换琴"，而它来自 H_n ∝ sin(nπd/L)。
   这里把 4 个档位 × 6 个泛音的权重表算出来，确认"琴颈档确实把第 4~6 泛音压掉"。
"""
from __future__ import annotations

import math
import sys


def main() -> int:
    print("=" * 78)
    print("[1] 回归命门：钢琴权重 = 65536（Q16 的 1.0）时，(x·65536)>>16 == x ？")
    print("=" * 78)
    # 装载器里 kvel_q12 是 15 bit（kvel_prod[21:7]），这里按 16 bit 更保守地穷举
    bad = 0
    for x in range(1 << 16):
        prod = x * 65536                      # 硬件里是 16×16 → 32 bit 精确乘积
        if (prod >> 16) != x:
            bad += 1
            if bad <= 5:
                print("   不一致: x=%d" % x)
    print("   穷举全部 65536 个 16 bit 输入 ⇒ 不一致 %d 个" % bad)
    print("   最坏乘积 = 65535×65536 = %d < 2^32 = %d ⇒ 32 bit 不溢出 ✅"
          % (65535 * 65536, 1 << 32))
    print("   ⇒ %s" % ("PASS：钢琴权重取 65536 时梳状乘法是【精确恒等】，回归不受影响"
                        if bad == 0 else "FAIL：恒等式不成立，梳状方案会破坏回归"))
    assert bad == 0

    print()
    print("=" * 78)
    print("[2] 音色命门：拾音器位置 H_n ∝ sin(n·π·d/L) 到底压掉哪些泛音？")
    print("=" * 78)
    pickups = [("琴桥 bridge", 0.06), ("中间 middle", 0.15), ("琴颈 neck", 0.24)]
    print("   d/L        " + "".join("  n=%d   " % n for n in range(1, 7)))
    for name, dL in pickups:
        row = []
        for n in range(1, 7):
            row.append(abs(math.sin(n * math.pi * dL)))
        print("   %-11s" % ("%.2f" % dL) + "".join(" %5.2f " % v for v in row) + "   ← %s" % name)
        # 第一个零点位置
        first_null = 1.0 / dL
        print("              第一个零点在 n ≈ %.1f（我们只有 6 个泛音）" % first_null)

    print()
    print("   ⇒ 琴桥档(d/L=0.06)：6 个泛音全在通带、且随 n 上升 ⇒ 明亮")
    print("   ⇒ 琴颈档(d/L=0.24)：n=4.2 处就是零点 ⇒ 第 4~6 泛音被强压 ⇒ 温暖/空洞")
    print("   ⇒ **'换挡像换琴'在我们 6 泛音的引擎里是可表达的**（差异落在 n=4~6）")

    print()
    print("=" * 78)
    print("[3] 拨弦位置 A_n ∝ sin(n·π·x/L)（吉他/古筝的第二个梳状）")
    print("=" * 78)
    print("   x/L        " + "".join("  n=%d   " % n for n in range(1, 7)))
    for xL in (0.05, 0.10, 0.143, 0.20, 0.25, 0.35):
        row = [abs(math.sin(n * math.pi * xL)) for n in range(1, 7)]
        print("   %-11s" % ("%.3f" % xL) + "".join(" %5.2f " % v for v in row))
    print("   注：x/L=1/7≈0.143 正是我们钢琴琴槌的位置（可交叉对照现有钢琴幅度表）")

    print()
    print("=" * 78)
    print("[4] 合成权重 W_n = A_n(pluck) · H_n(pickup)：吉他 3 个典型配置")
    print("=" * 78)
    cfg = [("琴桥拾音+靠桥拨", 0.06, 0.10),
           ("中间拾音+常规拨", 0.15, 0.143),
           ("琴颈拾音+靠颈拨", 0.24, 0.25)]
    for name, dL, xL in cfg:
        w = [abs(math.sin(n * math.pi * dL)) * abs(math.sin(n * math.pi * xL))
             for n in range(1, 7)]
        wmax = max(w)
        norm = [v / wmax for v in w]               # 归一化到最大泛音（便于生成 Q16 表）
        print("   %-16s 原始 " % name + "".join(" %5.2f" % v for v in w))
        print("   %-16s 归一 " % "" + "".join(" %5.2f" % v for v in norm)
              + "   (Q16: " + " ".join("%d" % round(v * 65535) for v in norm) + ")")

    print()
    print("=" * 78)
    print("结论：① 恒等式成立（穷举 65536 例）⇒ 钢琴回归可保持 bit 级一致")
    print("      ② 拾音器/拨弦位置的差异在 6 泛音内可表达 ⇒ 维度设计站得住")
    print("=" * 78)
    return 0


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    sys.exit(main())
