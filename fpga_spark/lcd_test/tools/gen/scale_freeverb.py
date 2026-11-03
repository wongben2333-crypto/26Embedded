#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""scale_freeverb.py -- 把 Freeverb 的 44.1 kHz 系数换算到任意采样率，并做稳定性 / 资源检查。

只输出数据表，**不生成任何 RTL**。

为什么需要它
------------
Freeverb 的延迟表是在 44.1 kHz 下**用听感试出来的**，其源码注释原文写着：

    These values assume 44.1KHz sample rate; they will probably be OK for
    48KHz sample rate but would need scaling for 96KHz (or other) sample rates.

本项目 I2S 实际输出采样率是 **97 656.25 Hz**，不能直接用原始表。

三条换算规则（本脚本的核心）
----------------------------
(1) **延迟样本数 x (fs/44100)**，四舍五入取整。
    因为按比例缩放 => **延迟的毫秒数不变** => 每圈往返时间不变
    => **反馈系数 g 不变、衰减时间 T60 不变**。
    （T60 = -3*ln(10)*D / ln(g)，D 不变则 T60 不变。）
    ⚠️ 立体声扩展 `stereospread=23` 也定义在 44.1 kHz 样本域，
       所以是 round((orig+23)*k)，**不是** round(orig*k)+23。用 --no-spread-scale 可切换。
(2) **阻尼系数要改。** 阻尼那一级 filterstore = output*damp2 + filterstore*damp1
    是一阶低通，其转折频率与采样率成正比。fs 抬高后同样 damp1 下高频衰减少
    => 听感偏亮。保持转折频率不变需：
        damp1_new = 1 - (1 - damp1_old)^(44100/fs)
(3) **输入增益有上限。** 梳状滤波器直流增益 = 1/(1-g)，g 最大 0.98 时达 50 倍。
    Freeverb 取 fixedgain = 0.015 ~= 1/66.7，正好使 0.015*50 = 0.75 < 1（不溢出）。
    => 定点实现必须满足 A_in <= 1/(1-g_max)。

环境适配
--------
本机控制台是 **GBK**（代码页 936），无法编码 `=>` 之外的箭头/emoji 等符号。
本脚本**只用 ASCII 符号 + 中文**，并把 stdout/stderr 的 errors 设为 "replace"，
因此在 GBK 控制台上不会崩（这是本项目已实测过的坑）。

来源与许可
----------
Freeverb 常数取自 Jezar @ Dreampoint, June 2000（Components/tuning.h 等 7 个文件），
其每个源文件头部逐字写明 "This code is public domain"。
本脚本只使用这些**常数事实**，不复制其实现代码。

用法
----
    python scale_freeverb.py                                  # 默认 97656.25 Hz
    python scale_freeverb.py --fs 48000
    python scale_freeverb.py --fs 97656.25 --room 0.5 --damp 0.5 --bits 16
    python scale_freeverb.py --verilog                        # 额外输出可贴的 Verilog 常量块

退出码：0 = 全部检查通过（可能有警告）；1 = 有硬错误。
"""

from __future__ import annotations

import argparse
import math
import sys

# ---- 本机 GBK 控制台适配：任何无法编码的字符替换而非崩溃 ----
for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(errors="replace")  # type: ignore[attr-defined]
    except Exception:
        pass

# ---------------------------------------------------------------- 原始常数
FS_REF = 44100.0

# Freeverb tuning.h -- 44.1 kHz 听感调出的延迟表
COMB_L = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
ALLPASS_L = [556, 441, 341, 225]
STEREOSPREAD = 23          # 右声道每条延迟 +23 样本（44.1 kHz 域）

NUM_COMBS = 8
NUM_ALLPASSES = 4

FIXEDGAIN = 0.015          # 输入增益
SCALEWET = 3.0
SCALEDRY = 2.0
SCALEDAMP = 0.4
SCALEROOM = 0.28
OFFSETROOM = 0.7
INITIALROOM = 0.5
INITIALDAMP = 0.5
INITIALWET = 1.0 / SCALEWET
INITIALDRY = 0.0
INITIALWIDTH = 1.0
ALLPASS_FB = 0.5

# 器件事实（本机 GW5AST-138C）
BSRAM_BITS_PER_BLOCK = 18432      # 18 Kbit（UG300 2.1）
BSRAM_BLOCKS_TOTAL = 340          # AGENTS.md：6120 Kb / 340 块
BSRAM_MAX_DEPTH_16 = 1024         # 1K x 16（UG300 表 2-2）
BSRAM_MAX_DEPTH_32 = 512          # 512 x 32

# 器件硬约束（UG300 2.1 注 1）：Arora V 138K 不支持 Read-before-Write
DEVICE_NO_RBW = True


def scaled_delay(orig: int, k: float) -> int:
    """按采样率比例缩放，四舍五入，至少 1。"""
    return max(1, int(round(orig * k)))


def retune_damp1(damp1_old: float, k: float) -> float:
    """保持一阶低通转折频率不变：damp1_new = 1 - (1-damp1_old)^(1/k)。"""
    if not (0.0 <= damp1_old < 1.0):
        raise ValueError("damp1 必须在 [0, 1) 内")
    return 1.0 - (1.0 - damp1_old) ** (1.0 / k)


def t60_seconds(delay_samples: int, fs: float, g: float) -> float:
    """T60 = -3*ln(10)*D / ln(g)，D 为每圈往返时间（秒）。"""
    if not (0.0 < g < 1.0):
        return float("inf")
    d = delay_samples / fs
    return (-3.0 * math.log(10.0) * d) / math.log(g)


def blocks_for(depth: int, max_depth: int) -> int:
    """单条延迟线独立占块时需要的 BSRAM 块数。"""
    return max(1, -(-depth // max_depth))


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Freeverb 系数换算到任意采样率（只出数据，不生成 RTL）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--fs", type=float, default=97656.25,
                   help="目标采样率 Hz（默认 97656.25，本项目 I2S 实际输出）")
    p.add_argument("--room", type=float, default=INITIALROOM,
                   help="room 参数 [0,1]，默认 0.5")
    p.add_argument("--damp", type=float, default=INITIALDAMP,
                   help="damp 参数 [0,1]，默认 0.5")
    p.add_argument("--bits", type=int, default=16, choices=(8, 16, 32),
                   help="样本位宽（决定每块 BSRAM 深度），默认 16")
    p.add_argument("--mono", action="store_true", help="只算单声道")
    p.add_argument("--verilog", action="store_true", help="额外输出 Verilog 常量块")
    p.add_argument("--out", default=None,
                   help="把报告写到该文件（UTF-8）。⚠️ 本机控制台是 GBK，"
                        "直接看 stdout 可能出现乱码，建议用本选项")
    p.add_argument("--no-spread-scale", action="store_true",
                   help="stereospread 不随 fs 缩放（保持固定 +23 样本）")
    return p


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)

    # ---- GBK 控制台适配：把报告直接写 UTF-8 文件，避开控制台转码 ----
    if args.out:
        try:
            sys.stdout = open(args.out, "w", encoding="utf-8", errors="replace", newline="\n")
        except OSError as e:
            print("ERROR: 无法写入 --out 文件 %s: %s" % (args.out, e))
            return 1

    if args.fs <= 0:
        print("ERROR: --fs 必须为正数")
        return 1

    errors = []
    warns = []

    k = args.fs / FS_REF

    # ---- 反馈系数 g：不随采样率变 ----
    g = args.room * SCALEROOM + OFFSETROOM
    g_max = 1.0 * SCALEROOM + OFFSETROOM      # room=1 -> 0.98
    g_min = 0.0 * SCALEROOM + OFFSETROOM      # room=0 -> 0.70

    # ---- 阻尼：需要换算 ----
    damp1_old = args.damp * SCALEDAMP
    damp2_old = 1.0 - damp1_old
    damp1_new = retune_damp1(damp1_old, k)
    damp2_new = 1.0 - damp1_new

    # ---- 输入增益上限 ----
    # 梳状稳态：b = x + g*b  =>  b = x/(1-g)  => 直流增益 = 1/(1-g)，g_max=0.98 时 = 50
    # 要不溢出（|b| <= 1）：A_in * 1/(1-g_max) <= 1  =>  A_in <= 1 - g_max
    comb_dc_gain_max = 1.0 / (1.0 - g_max)     # = 50
    a_in_max = 1.0 - g_max                     # = 0.02  <- 真正的输入增益上限
    occupancy = FIXEDGAIN / a_in_max           # 0.015 / 0.02 = 0.75
    a_in_suggest = 0.75 * a_in_max             # = 0.015

    max_depth = {8: 2048, 16: BSRAM_MAX_DEPTH_16, 32: BSRAM_MAX_DEPTH_32}[args.bits]

    channels = ["L"] if args.mono else ["L", "R"]
    spread = 0 if args.no_spread_scale else STEREOSPREAD
    scale_spread = (not args.no_spread_scale)

    rows = []
    total_samples = 0
    total_blocks = 0
    for ch in channels:
        off = 0 if ch == "L" else STEREOSPREAD
        for i, orig in enumerate(COMB_L, start=1):
            if ch == "L":
                d = scaled_delay(orig, k)
            else:
                d = scaled_delay(orig + off, k) if scale_spread else scaled_delay(orig, k) + spread
            blocks = blocks_for(d, max_depth)
            rows.append(("COMB", ch, i, orig + (off if ch != "L" else 0), d,
                         d / args.fs * 1e3, blocks))
            total_samples += d
            total_blocks += blocks
        for i, orig in enumerate(ALLPASS_L, start=1):
            if ch == "L":
                d = scaled_delay(orig, k)
            else:
                d = scaled_delay(orig + off, k) if scale_spread else scaled_delay(orig, k) + spread
            blocks = blocks_for(d, max_depth)
            rows.append(("ALLPASS", ch, i, orig + (off if ch != "L" else 0), d,
                         d / args.fs * 1e3, blocks))
            total_samples += d
            total_blocks += blocks

    # ---- 断言 ----
    for kind, ch, i, orig, d, ms, blocks in rows:
        if d < 1:
            errors.append("%s%s%d: 延迟 %d < 1（非法）" % (kind, ch, i, d))
        if d > max_depth:
            warns.append("%s%s%d: 延迟 %d > 单块 BSRAM 深度 %d => 需 %d 块级联（地址高位做块选择）"
                         % (kind, ch, i, d, max_depth, blocks))
    if not (0.0 < g < 1.0):
        errors.append("反馈 g = %.4f 不在 (0,1) 内 => 会发散" % g)
    if g >= 0.995:
        warns.append("反馈 g = %.4f 非常接近 1，定点舍入误差可能推过 1 => 建议留 1~2%% 余量" % g)
    if FIXEDGAIN > a_in_max:
        errors.append("输入增益 %s > 上限 1-g_max = %.4f => 反馈环可能溢出" % (FIXEDGAIN, a_in_max))
    if total_blocks > BSRAM_BLOCKS_TOTAL:
        errors.append("需要 %d 块 BSRAM > 器件可用 %d 块" % (total_blocks, BSRAM_BLOCKS_TOTAL))

    W = 78
    line = "=" * W
    dash = "-" * W

    print(line)
    print("Freeverb 系数换算表")
    print(line)
    print("目标采样率 fs      : %s Hz" % format(args.fs, ",.2f"))
    print("参考采样率         : %s Hz (Freeverb 原始表)" % format(FS_REF, ",.0f"))
    print("缩放系数 k         : %.7f" % k)
    print("样本位宽           : %d bit  (单块 BSRAM 深度 %d)" % (args.bits, max_depth))
    print("声道数             : %d" % len(channels))
    print("room / damp 输入   : %s / %s" % (args.room, args.damp))
    print("stereospread       : %d (%s)" % (
        STEREOSPREAD, "随 fs 缩放" if scale_spread else "固定样本数，不缩放"))
    print()

    print(dash)
    print("(1) 延迟表（样本数已按 fs 缩放；【毫秒数与 44.1 kHz 时相同】）")
    print(dash)
    print("%-9s%-5s%-4s%12s%10s%11s%6s" %
          ("类型", "声道", "#", "原始(44.1k)", "换算后", "时间(ms)", "块数"))
    for kind, ch, i, orig, d, ms, blocks in rows:
        print("%-9s%-5s%-4d%12d%10d%11.2f%6d" % (kind, ch, i, orig, d, ms, blocks))
    print()
    print("总样本数 = %s   总 BSRAM 块数 = %d / %d (%.1f%%)" % (
        format(total_samples, ","), total_blocks, BSRAM_BLOCKS_TOTAL,
        total_blocks / BSRAM_BLOCKS_TOTAL * 100.0))
    print("存储时长 = %.1f ms" % (total_samples / args.fs * 1e3))
    print()

    print(dash)
    print("(2) 反馈系数 g -- 【不随采样率改变】")
    print(dash)
    print("理由：按比例缩放延迟 => 每圈往返时间不变 => T60 不变 => g 保持原值。")
    print("g(room=%s) = room*%s + %s = %.4f" % (args.room, SCALEROOM, OFFSETROOM, g))
    print("g 的范围            = [%.2f, %.2f]  (room: 0 -> 1)" % (g_min, g_max))
    if DEVICE_NO_RBW:
        print("注意：Arora V 138K 器件不支持 Read-before-Write，")
        print("      WRITE_MODE 只能用 Normal(2'b00) 或 write-through(2'b01)。")
    print()
    print("各梳状滤波器的 T60（按 g 计，取 L 声道）：")
    for kind, ch, i, orig, d, ms, blocks in rows:
        if kind == "COMB" and ch == "L":
            print("  COMB L%d: %5d 样本  T60 = %.3f s" % (i, d, t60_seconds(d, args.fs, g)))
    print()

    print(dash)
    print("(3) 阻尼系数 -- 【必须换算】")
    print(dash)
    print("理由：阻尼一级是一阶低通，转折频率随 fs 成正比；fs 抬高后同样 damp1 下")
    print("      高频衰减少 => 听感偏亮。保持转折频率不变需 damp1_new = 1-(1-damp1_old)^(1/k)。")
    print("damp1_old = %s * %s = %.4f   damp2_old = %.4f" % (args.damp, SCALEDAMP, damp1_old, damp2_old))
    print("damp1_new = %.6f          damp2_new = %.6f" % (damp1_new, damp2_new))
    if abs(k - 1.0) < 1e-12:
        print("  (k = 1，无需调整)")
    print()

    print(dash)
    print("(4) 输入增益")
    print(dash)
    print("梳状最大直流增益 1/(1-g_max) = %.4f" % comb_dc_gain_max)
    print("=> 不溢出的输入增益上限：A_in <= 1 - g_max = %.4f" % a_in_max)
    print("   (推导：b = x + g*b => b = x/(1-g)；要 |b| <= 1 则 x <= 1-g)")
    print("Freeverb 原值 fixedgain = %s  => 占用率 %.3f (<1 才安全)" % (FIXEDGAIN, occupancy))
    print("同样 0.75 占用率下建议 A_in <= %.4f" % a_in_suggest)
    print("=> 不要把满幅信号直接送进反馈环。")
    print()

    if warns:
        print(dash)
        print("[WARN]")
        print(dash)
        for w in warns:
            print("  WARN: " + w)
        print()
    if errors:
        print(dash)
        print("[ERROR]")
        print(dash)
        for e in errors:
            print("  ERROR: " + e)
        print()

    if args.verilog:
        print(dash)
        print("(5) 可直接贴进 RTL 的常量块（Verilog）")
        print(dash)
        print("// 由 fpga_hank/tools/gen/scale_freeverb.py 生成，勿手改")
        print("// fs = %.2f Hz, k = %.7f, bits = %d" % (args.fs, k, args.bits))
        print("// 来源：Freeverb (Jezar@Dreampoint, 2000, public domain) 系数按采样率换算")
        print("// 反馈 g = %.4f（不随 fs 变）；damp1 = %.6f（已换算）" % (g, damp1_new))
        print("localparam integer NUM_COMBS   = %d;" % NUM_COMBS)
        print("localparam integer NUM_ALLPASS = %d;" % NUM_ALLPASSES)
        for ch in channels:
            off = 0 if ch == "L" else STEREOSPREAD
            comb = []
            allp = []
            for o in COMB_L:
                if ch == "L" or not scale_spread:
                    comb.append(scaled_delay(o, k) + (0 if ch == "L" else spread))
                else:
                    comb.append(scaled_delay(o + off, k))
            for o in ALLPASS_L:
                if ch == "L" or not scale_spread:
                    allp.append(scaled_delay(o, k) + (0 if ch == "L" else spread))
                else:
                    allp.append(scaled_delay(o + off, k))
            print("// 声道 " + ch)
            print("localparam integer COMB_DLY_" + ch + " [0:7] = '{"
                  + ", ".join(str(x) for x in comb) + "};")
            print("localparam integer ALLPASS_DLY_" + ch + " [0:3] = '{"
                  + ", ".join(str(x) for x in allp) + "};")
        print("// 定点系数（Q15 近似，具体字长请自行决定）")
        print("localparam signed [15:0] FX_DAMP1    = 16'sd%d;  // %.6f"
              % (int(round(damp1_new * 32768)), damp1_new))
        print("localparam signed [15:0] FX_DAMP2    = 16'sd%d;  // %.6f"
              % (int(round(damp2_new * 32768)), damp2_new))
        print("localparam signed [15:0] FX_FEEDBACK = 16'sd%d;  // g = %.4f"
              % (int(round(g * 32768)), g))
        print("// 读延迟：SDPB READ_MODE=0 -> 1 拍；=1 -> 2 拍。延迟计算需计入。")
        print()

    print(line)
    if errors:
        print("结果：[ERROR] 有错误，请修正后再用")
        return 1
    if warns:
        print("结果：[OK] 通过（有警告）")
        return 0
    print("结果：[OK] 全部检查通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
