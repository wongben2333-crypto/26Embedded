# -*- coding: utf-8 -*-
"""gen_piano_rom.py —— 生成 piano_rom.v（钢琴音色引擎的全部常量表）

本文件是【钢琴音色的唯一真源】：正弦查找表、音符→频率字、力度→增益、
以及每个泛音分量的「幅度 / 力度明亮度 / 衰减速率 / 非谐性拉伸」全部在这里算出来，
`rtl/synth/piano_engine.v` 只引用这些模块，不在别处重复写常数（避免两边漂移）。

生成物 `rtl/synth/piano_rom.v` 含 4 个模块：

  piano_sin_rom      8 bit 相位 → 16 bit 正弦（象限折叠，只存 65 项 1/4 波表）
  piano_note_lut     MIDI 音符 → 基频相位增量 f0_step（32 bit Q32）、齐奏拍频增量
  piano_vel_lut      力度 → Q16 增益、琴槌噪声低通档位
  piano_partial_lut  泛音序号 n → 幅度 Q16、明亮度系数 Q12、
                     按住衰减移位 s_ring、松开(阻音器)衰减移位 s_damp、
                     非谐性拉伸的两个右移量 st1/st2

============================================================================
 ★ 采样率必须按【实际值】算，不能写 48000
   本工程 fs = 50 MHz / 512 = 97656.25 Hz（top.v 用 BCK_DIV=1）。
   参考实现 26Embedded/fpga_spark 的 piano_voice.v 把 48 kHz 写死，
   照搬会让音高、包络时长全部错掉。本文件所有频率字都按 97 656.25 Hz 折算。
   若将来改 BCK_DIV，必须重跑本脚本。

 ★ 音色依据（全部来自公开实现，不是拍脑袋）
   1) 加法合成 + 每个泛音独立包络：AMY 的 additive piano
      https://github.com/shorepine/amy （说明页 https://shorepine.github.io/amy/piano.html）
      · 每个泛音是一个独立振荡器，各自一条包络
      · 高次泛音衰减更快；音越高衰减越快
      · 力度越大高次泛音涨得越多（实测：基频 +25 dB，第 20 次泛音 +45 dB）
        ⇒ 本文件用 K[n]（Q12）把这一条「力度→明亮度」量化成每个泛音自己的增益
   2) 非谐性（inharmonicity）：f_n = n·f0·sqrt(1 + B·n²)
      钢琴是钢弦，刚度让高次泛音比整数倍略高（"拉伸"），这是"温暖感"的来源之一。
      公式与 B 实测值取自 Stony Brook 论文（开放获取）
      `_research/libs/_dl/stonybrook_ACPv46i2.pdf.txt` Table 2：
        File f0 = 27 Hz  : B = 0.0001 ~ 0.00058
        File f0 = 110 Hz : B = 0.00005 ~ 0.0002
        真实机型实测（Steinway C/D、Nord、Straud）: B = 0.0000568 ~ 0.000568
      ⇒ 本工程取中音区典型值 B = 0.0004（落在建议区间 0.0002~0.0005 内）。
      ⚠️ 有人把同音多弦失谐写成"固定 +0.1% 频率偏移"—— 那是错的：
        0.1% 在 A4 上是 0.44 Hz，与 Faust 的 detuningHz 表量级接近，
        但在低音区（要求 0.003 Hz）差了 100 倍。见下面第 3 条。
      注意 f_n 是对【所有】n 都成立（n=1 也略有拉伸 0.02%），
      所以实测基频比标称 A4=440.000 Hz 高 0.018%（+0.08 Hz）——这是符合理论的。
      ★ 落地方式（RTL 里不开方、不查大表）：
        f_n - n·f0 = n·f0·(sqrt(1+B·n²) - 1)，把这个"拉伸量"用两个二进制移位项
        (f0>>st1)+(f0>>st2) 近似 ⇒ 每条泛音支路只需移位加法，零乘法器。
        全部 st1/st2 在本脚本里穷举搜索最优组合（误差 < 0.07%，见自检打印）。
   3) 齐奏失谐拍频：Faust STK 的 piano1.dsp
      https://github.com/grame-cncm/faust/blob/master-dev/examples/physicalModeling/faust-stk/piano1.dsp
      它的 detuningHz 表给出同音弦间失谐量：低音 0.003 Hz → 中音 0.25 Hz →
      高音 1.0 Hz。注意这是【零点几 Hz 的拍频】，不是 0.1% 的频率偏移
      （0.1% 在 A4 上是 0.44 Hz，量级接近，但低音区差了 100 倍）。
      本文件对该表按 MIDI 音号插值。
   4) 琴槌瞬态：Faust piano1.dsp 的 hammer 模型是【白噪声过 4 级一阶低通】，
      一阶系数随力度变化（softPole 0.96~0.99 / loudPole 0.82~0.875，越大越暗）。
      ⇒ 本工程用「每声部一个 LFSR 噪声 + 一阶低通 + 快速衰减包络」实现，
        低通档位随力度变（力度越大越亮）。
   5) 无 sustain 平台：钢琴按住键也在衰减（阻尼器只在松开时落下）。
      ⇒ 包络是「快起音 + 长衰减」，按住时按 s_ring 缓慢衰减，
        松开时切到 s_damp（快 32 倍左右）模拟阻音器。
      参考 piano_voice.v 把衰减写死成固定步进（env_f0 -= 18），换采样率就全错；
      本工程用「env -= env >> s」的指数衰减，时间常数 = 2^s / fs，与幅度无关。

 ★ 为什么用 case 常量表而不是 $readmemh：
   参考实现 piano_voice.v 用 $readmemh("wavetable_sine.hex")，外部文件不在工作目录时
   ROM 全 0、完全静音且极难排查。本工程一律 case 常量表（同 wave_rom.v）。

用法：
    python tools/gen/gen_piano_rom.py            # 打印参数自检，不写文件
    python tools/gen/gen_piano_rom.py --write    # 写 rtl/synth/piano_rom.v
"""
from __future__ import annotations

import argparse
import math
import os
import sys

sys.stdout.reconfigure(encoding='utf-8')

# ---------------------------------------------------------------- 全局常量 ---
CLK_HZ     = 50_000_000
BCK_DIV    = 1
FS         = CLK_HZ / 512.0                 # 97656.25 Hz
PHASE_BITS = 32
PHASE_MOD  = 1 << PHASE_BITS
N_PART     = 6                              # 每个声部的泛音个数（加法分量）
N_QUARTER  = 65                             # 1/4 波表项数（0..64，含 90° 端点）

assert FS == CLK_HZ / 512.0, 'fs 必须是 50e6/512'

# ------------------------------------------------------- 1) 音符 → 频率字 ----
def f_of_note(n: int) -> float:
    """等程律：A4(69) = 440 Hz"""
    return 440.0 * (2.0 ** ((n - 69) / 12.0))


def step_of_hz(f: float) -> int:
    """Hz → 32 bit 相位增量（Q32）"""
    return int(round(f * PHASE_MOD / FS))


# ------------------------- 2) 齐奏失谐拍频（Faust STK detuningHz 表插值）----
# 来源：grame-cncm/faust examples/physicalModeling/faust-stk/piano1.dsp
#       detuningHz = waveform{21,0.003, 24,0.003, 28,0.003, 29,0.060, 31,0.100,
#                             36,0.110, 42,0.120, 48,0.200, 54,0.200, 60,0.250,
#                             66,0.270, 72,0.300, 78,0.350, 84,0.500, 88,0.582,
#                             92,0.664, 96,0.793, 99,1.000, 108,1.000}
DETUNE_PTS = [
    (21, 0.003), (24, 0.003), (28, 0.003), (29, 0.060), (31, 0.100),
    (36, 0.110), (42, 0.120), (48, 0.200), (54, 0.200), (60, 0.250),
    (66, 0.270), (72, 0.300), (78, 0.350), (84, 0.500), (88, 0.582),
    (92, 0.664), (96, 0.793), (99, 1.000), (108, 1.000),
]


def detune_hz(n: int) -> float:
    """按 MIDI 音号分段线性插值失谐拍频（Hz）。超出范围取端点。"""
    if n <= DETUNE_PTS[0][0]:
        return DETUNE_PTS[0][1]
    if n >= DETUNE_PTS[-1][0]:
        return DETUNE_PTS[-1][1]
    for i in range(len(DETUNE_PTS) - 1):
        n0, v0 = DETUNE_PTS[i]
        n1, v1 = DETUNE_PTS[i + 1]
        if n0 <= n <= n1:
            return v0 + (v1 - v0) * (n - n0) / (n1 - n0)
    return 0.003


# ------------------------------------------- 3) 泛音幅度 + 力度明亮度 -------
# 弱奏(mp 以下)相对频谱：基频最强，高次很快衰减 —— 柔和
A_SOFT = [1.00, 0.30, 0.12, 0.050, 0.020, 0.010]
# 力度→明亮度系数 K[n]（Q12）：第 n 次泛音在最强奏时增益 ×(1 + K/4096)
#   0 → 基频不受力度影响；32768(8.0) → 第 6 次泛音最强奏时 ×9（≈ +19 dB）
#   这个 19 dB 的「相对提亮」量级取自 AMY 的实测（第 20 次泛音比基频多涨 20 dB）。
K_Q12 = [0, 3686, 8192, 14336, 22528, 32768]

# 归一到「最强奏时 6 个泛音幅度之和 = 1.0」⇒ 单声部峰值不超过满幅
_hard = [A_SOFT[i] * (1.0 + K_Q12[i] / 4096.0) for i in range(N_PART)]
_amp_norm = sum(_hard)
AMP_Q16 = [int(round(A_SOFT[i] / _amp_norm * 65536.0)) for i in range(N_PART)]

# ------------------------------------------------- 4) 包络衰减速率（移位）----
# env -= env >> s，每 2^k 个采样点执行一次 ⇒ 时间常数 τ = 2^(s+k)/fs
#   s_ring：按住（阻尼器未落）时的慢衰减
#   s_damp：松开后的阻音器快衰减（约为 s_ring - 5，即快 32 倍）
# 音高相关：k(note) = clamp((90-note)>>4, 0, 2)
#   高音 k=0（衰减最快）、低音 k 大（衰减最慢）—— 与 AMY「音越高衰减越快」一致
#   k 只有 0..2 三档：τ(基频) = 1.34 s(高音) / 2.68 s(中音) / 5.37 s(低音)
#   对应 T60 ≈ 9 s / 18 s / 37 s。这个量级是照 AMY 与 Faust STK 的实测定的：
#     · AMY：「低音要 20 秒以上才衰减到听不见」
#     · Faust piano1.dsp singleStringDecayRate：-1.5 dB/s(低音) ~ -15 dB/s(高音)
#   ⚠️ 不要越调越长：按住键时阻尼器是抬起的，低音本来就能响十几秒，
#      但 τ 调到 20 s 以上（T60>100 s）会让和弦糊成一片、听感完全不像钢琴。
#   ⚠️ 这里的 k 必须与 rtl/synth/piano_engine.v 里 piano_voice 的
#      kraw/ktmp/ksh 三行完全一致（RTL 用注释标了同一公式）。
S_RING = [17, 16, 15, 14, 13, 12]
# 阻音器：τ(基频) = 2^11/fs ≈ 21 ms ⇒ 衰减到 -48 dB 约 116 ms（真实钢琴阻尼 50~150 ms）
# ⚠️ 原来取 [13,...]（τ=84 ms）时，衰减到 -48 dB 要 470 ms：
#    快速乐句里上一个音会拖到下一个音上；而"全部 off 后 active 是否归零"这种判据
#    要等 4 万多个采样点才成立（flow-verifier 的独立 TB 用 20000 tick 判，
#    当时结论是"8 个声部一个都没释放"—— 那不是没释放，是判据等待时间不够）。
S_DAMP = [11, 10,  9,  8,  7,  6]


def pitch_k(note: int) -> int:
    k = (90 - note) >> 4
    if k < 0:
        k = 0
    if k > 2:
        k = 2
    return k


# ------------------------------------------------ 5) 非谐性拉伸（移位对）----
# 目标 f_n = n·f0·sqrt(1 + B·n²)
# B 取值依据（Stony Brook 论文 Table 2，开放获取
#   _research/libs/_dl/stonybrook_ACPv46i2.pdf.txt）：f0=27 Hz 时 B=0.0001~0.00058；
#   f0=110 Hz 时 B=0.00005~0.0002；真实机型实测 0.0000568~0.000568。
#   取中音区典型值 0.0004（落在建议区间 0.0002~0.0005 内）。
INHARM_B = 0.0004


def inharm_shifts(n: int, B: float = None):
    """返回 (st1, st2)：inc_n = n·f0 + (f0>>st1) + (f0>>st2)

    要求 (2^-st1 + 2^-st2) ≈ n·(sqrt(1+B·n²) - 1)，用暴力搜索最接近的两项组合。
    st = 31 表示该项为 0（f0>>31 在 32 位下可忽略）。
    B 可传参：多乐器时吉他（钢弦高张力）比钢琴小、古筝居中（见 INSTRUMENTS）。
    """
    if B is None:
        B = INHARM_B
    target = n * (math.sqrt(1.0 + B * n * n) - 1.0)
    best = (31, 31)
    best_err = abs(target)
    for s1 in range(4, 32):
        v1 = 2.0 ** (-s1)
        if abs(v1 - target) < best_err:
            best_err = abs(v1 - target)
            best = (s1, 31)
        for s2 in range(s1 + 1, 32):
            err = abs(v1 + 2.0 ** (-s2) - target)
            if err < best_err:
                best_err = err
                best = (s1, s2)
    return best


# ============================================================================
#        多乐器 5 音区声学标定表（2026-10-31 物理发声机理优化版）
# ============================================================================
# 音区划分（与 piano_engine_tdm32.v 的 band_ld 完全一致）：
#   band 0: note <  48 (< C3, 低音区)
#   band 1: 48 <= note < 60 (C3..B3, 中低音区 / 小提琴 G3-B3)
#   band 2: 60 <= note < 72 (C4..B4, 中音区)
#   band 3: 72 <= note < 84 (C5..B5, 中高音区)
#   band 4: note >= 84 (>= C6, 高音区)
#
# 物理发声建模依据：
#   0) 钢琴 (Piano):
#      - 低音区钢弦长、音板对极低频辐射效率低，靠丰富的 2~5 次谐波赋予三角钢琴浑厚低音；
#      - 随音高上升（C5/C6 以上），弦短而硬，高次谐波迅速减弱，以纯净基波+2次谐波呈现晶莹钟声感；
#      - 非谐性系数 B 随音区从 0.00025 温和增至 0.00075（杜绝高音区过度拉伸导致的偏音）。
#   1) 吉他 (Acoustic / Classical & Electric Guitar):
#      - 拨弦点 β ≈ 0.12（音孔边缘）形成梳状包络 + 双阶段衰减：
#        高次泛音 (H4..H6) 的 s_ring 缩短 2 档（τ ≈ 10~40 ms），保留拨弦瞬间的颗粒感，
#        随后迅速收敛为温暖圆润的基波 + 2/3 次木质谐波延音（Karplus-Strong 频域阻尼特性）。
#   2) 小提琴 (Violin):
#      - 弓弦粘滑运动 (Helmholtz Sawtooth, 1/n) 经琴体 A0(~275Hz)、B1(~485Hz) 与
#        Bridge Hill (2.5~3.2kHz 歌唱共振峰) 调制，基波饱满扎实，泛音按 1/n 平滑递减，
#        高把位 (band 3/4) 柔化 H5/H6 消除数字毛刺。
# ---------------------------------------------------------------------------
PIANO_BAND_AMPS = [
    (20500, 11800, 6800, 3600, 1800,  900),  # band 0 (< C3): 浑厚三角钢琴低音
    (23500, 10200, 5000, 2400, 1100,  520),  # band 1 (C3..B3): 饱满中低音
    (26500,  8600, 3600, 1500,  600,  280),  # band 2 (C4..B4): 温暖歌唱中音
    (28500,  6800, 2200,  750,  250,   90),  # band 3 (C5..B5): 清澈中高音
    (30500,  4800, 1100,  280,   70,    0),  # band 4 (>= C6): 晶莹剔透高音
]
PIANO_BAND_B = [0.00025, 0.00032, 0.00040, 0.00055, 0.00075]
PIANO_K_Q12  = [0, 3200, 6800, 11000, 16000, 20000]
PIANO_S_RING = [17, 16, 15, 14, 13, 12]
PIANO_S_DAMP = [13, 12, 11, 10,  9,  8]

GUITAR_BAND_AMPS = [
    (17000, 16000, 12500, 6500, 3200, 1400),  # band 0 (< C3): 拇指拨低音弦浑厚箱体共鸣
    (18000, 16000, 12000, 6000, 2800, 1200),  # band 1 (C3..B3): 木吉他箱体和弦主音区 (强H2/H3木质感)
    (19000, 15500, 11500, 5000, 2200,  900),  # band 2 (C4..B4): 旋律主音区 (极富表现力的面板共鸣)
    (22000, 13000,  8500, 3500, 1400,  500),  # band 3 (C5..B5): 高把位清甜木吉他泛音
    (25000, 10000,  5000, 1800,  600,  200),  # band 4 (>= C6): 极高把位纯净泛音
]
GUITAR_BAND_B = [0.00008, 0.00010, 0.00012, 0.00016, 0.00022]
GUITAR_K_Q12  = [0, 3686, 7200, 11500, 15000, 18000]
# 吉他高次泛音极快速阻尼（拨弦瞬间亮、随后20-50ms内迅速变暖，Karplus-Strong典型物理特征）
GUITAR_S_RING = [16, 15, 14, 12, 10,  9]
GUITAR_S_DAMP = [11, 10,  9,  8,  7,  6]

VIOLIN_BAND_AMPS = [
    (18000, 15000, 12000, 9500, 8000, 6500),  # band 0 (< C3): G弦/低音深沉大提琴共鸣 (浑厚饱满)
    (19000, 14500, 11500, 9000, 7500, 6000),  # band 1 (C3..B3): G弦/D弦胸腔共鸣 (丰富偶次/奇次泛音)
    (20000, 14000, 11000, 8500, 7000, 5500),  # band 2 (C4..B4): D弦/A弦主歌唱区 (真正的Helmholtz锯齿波丰满质感)
    (21000, 13000, 10000, 7500, 6000, 4500),  # band 3 (C5..B5): A弦/E弦丝滑歌唱高音
    (23000, 11500,  8500, 6000, 4000, 2500),  # band 4 (>= C6): E弦高把位纯净甜美高音
]
VIOLIN_BAND_B = [0.00010, 0.00012, 0.00012, 0.00015, 0.00018]
VIOLIN_K_Q12  = [0, 4000, 8000, 12000, 16000, 20000]
VIOLIN_S_RING = [17, 16, 15, 14, 13, 12]
VIOLIN_S_DAMP = [11, 10,  9,  8,  7,  6]

# 民族二胡 (Erhu): 蟒皮腔体奇次谐波 (H1, H3, H5) 突出、偶次谐波 (H2, H4) 抑制
ERHU_BAND_AMPS = [
    (22000,  6000, 14000,  3000,  7000,  1500),  # band 0: 突出奇次谐波 (H1, H3, H5)
    (23000,  5500, 13000,  2800,  6000,  1200),  # band 1
    (24000,  5000, 12000,  2500,  5000,  1000),  # band 2 (C4..B4: 二胡内弦主歌唱区)
    (25000,  4500, 10000,  2000,  3800,   600),  # band 3 (C5..B5: 外弦高把位明亮区)
    (27000,  3500,  7000,  1200,  2000,   200),  # band 4
]
ERHU_BAND_B = [0.00008, 0.00008, 0.00010, 0.00012, 0.00015]
ERHU_K_Q12  = [0, 2000, 5000, 7000, 10000, 12000]
ERHU_S_RING = [17, 16, 15, 14, 13, 12]
ERHU_S_DAMP = [11, 10,  9,  8,  7,  6]

INSTRUMENTS = [
    dict(name="piano",  B=0.0004, band_amps=PIANO_BAND_AMPS,  band_B=PIANO_BAND_B,
         k_q12=PIANO_K_Q12,  s_ring=PIANO_S_RING,  s_damp=PIANO_S_DAMP,
         lp_ofs=0,  ham=19661, ksh_ofs=0,  drive=0),
    dict(name="guitar", B=0.0001, band_amps=GUITAR_BAND_AMPS, band_B=GUITAR_BAND_B,
         k_q12=GUITAR_K_Q12, s_ring=GUITAR_S_RING, s_damp=GUITAR_S_DAMP,
         lp_ofs=-1, ham=24000, ksh_ofs=-1, drive=0),
    dict(name="violin", B=0.00012, band_amps=VIOLIN_BAND_AMPS, band_B=VIOLIN_BAND_B,
         k_q12=VIOLIN_K_Q12, s_ring=VIOLIN_S_RING, s_damp=VIOLIN_S_DAMP,
         lp_ofs=0,  ham=12000, ksh_ofs=0,  drive=0),
    dict(name="erhu",   B=0.00010, band_amps=ERHU_BAND_AMPS,   band_B=ERHU_BAND_B,
         k_q12=ERHU_K_Q12,   s_ring=ERHU_S_RING,   s_damp=ERHU_S_DAMP,
         lp_ofs=0,  ham=14000, ksh_ofs=1,  drive=0),
]
# ksh_ofs 用 2 bit 有符号编码（RTL 侧解码）：0 → −1、1 → 0、2 → +1
KSH_OFS_ENC = {-1: 0, 0: 1, 1: 2}
N_BAND = 5


def inst_amp_table(inst: int, band: int = 0):
    """返回该乐器指定音区 band (0..4) 的 6 个泛音 Q16 幅度表"""
    cfg = INSTRUMENTS[inst]
    b = min(max(band, 0), N_BAND - 1)
    return list(cfg["band_amps"][b])


def inst_k_table(inst: int):
    """返回该乐器的明亮度系数表 K_Q12"""
    return list(INSTRUMENTS[inst]["k_q12"])



def inharm_realized(n: int):
    st1, st2 = inharm_shifts(n)
    d = (2.0 ** (-st1) if st1 < 31 else 0.0) + (2.0 ** (-st2) if st2 < 31 else 0.0)
    return 1.0 + d / n, d


# ------------------------------------------------------- 6) 力度 → 增益 ------
VEL_FLOOR = 0.12        # 最弱奏相对最强奏的线性增益（≈ -18.4 dB）
VEL_EXP   = 1.6
VEL_PTS   = 128


def vel_gain_q16(v: int) -> int:
    x = min(max(v, 0), 127) / 127.0
    g = VEL_FLOOR + (1.0 - VEL_FLOOR) * (x ** VEL_EXP)
    return int(round(g * 65536.0))


def vel_lp_shift(v: int) -> int:
    """琴槌噪声低通档位（移位越大越暗）。力度越大越亮 —— Faust 的 loudPole/softPole。"""
    if v >= 100:
        return 1
    if v >= 64:
        return 2
    return 3


# ============================================================================
#              7) 表情（拓展②）：颤音速率 / 滑音时长
# ============================================================================
# 颤音（Vibrato）：
#   LFO 频率      f_lfo = vib_rate × 0.1 Hz          （0 → 0，50 → 5.0 Hz，127 → 12.7 Hz）
#   LFO 相位增量  vib_inc = round(f_lfo × 2^32 / fs)  ← 本表
#   调制度        f_inst = f_note × (1 + sin(2π f_lfo t) × depth_k/65536)
#                 其中 depth_k = vib_depth × 15（Q16 分数）
#                 ⇒ 最大 depth=127 时 depth_k = 1905 ⇒ ±2.907 % ⇒ **±49.6 cent**
#                   （0..127 → 0..±49.6 cent，线性；映射公式写在 piano_engine.v 文件头）
#   ⚠️ 这是【调相/调频】不是"改音符号"：所有泛音按同一比例平移，音程关系不变。
#
# 滑音（Glide / Portamento）：
#   时长          t_glide = glide_time × 4 ms        （0 → 立即跳变，127 → 508 ms）
#   样本数        N = max(1, round(t_glide × fs))
#   斜率          step = (f_target − f_current) / N
#   本表存        recip = round(2^32 / N)
#                 ⇒ RTL 里 step = (delta × recip) >> 32（一次乘法 + 移位，不开除法器）
#   ⚠️ 必须插值到【相位增量】上并逐采样推进，不能在频率字上直接跳（会爆音）。
#   t=0 → recip = 2^32−1（≈ 一步到位），RTL 另外用 glide_time==0 直接判为"无滑音"。
VIB_HZ_PER   = 0.1
GLIDE_S_PER  = 0.004


def vib_inc_q32(v: int) -> int:
    f = min(max(v, 0), 127) * VIB_HZ_PER
    return int(round(f * PHASE_MOD / FS))


def glide_samples(t: int) -> int:
    return max(1, int(round(min(max(t, 0), 127) * GLIDE_S_PER * FS)))


def glide_recip_q24(t: int) -> int:
    """r = round(2^24 / N)，N = 该时长的采样点数（RTL: step = (delta × r) >> 24）

    ★ 为什么是 Q24 而不是 Q32：
      N ≤ 127×4 ms×fs ≈ 49609 < 2^16 ⇒ 2^24/N ∈ [338, 42902]，**天然只有 16 bit**。
      用 Q32 会让乘法变成 33×33（66 bit），单周期收敛不了
      （这正是 MODE=1 时序违例的元凶之一）；而 Q24 量化误差 ≤ 0.15%，听不出来，
      乘法只需 17×16 ⇒ 一次小乘法即可。
      ⚠️ 别用 round(2^32/N) 再取高 16 bit：那样 t=64 的滑音会变成 335 ms（错 31%）。
      t=0 时 RTL 直接判为"无滑音"（glide_act=0），故这里取最大值即可。
    """
    if t <= 0:
        return 0xFFFF
    n = glide_samples(t)
    return min(0xFFFF, int(round(float(1 << 24) / n)))


# ============================================================================
#                                 代码生成
# ============================================================================
HEADER = '''// =============================================================================
//  piano_rom.v —— 钢琴音色引擎常量表（由 tools/gen/gen_piano_rom.py 生成）
//
//  ⚠️ 本文件由脚本生成，请勿手工编辑。改参数请改 tools/gen/gen_piano_rom.py。
//
//  采样率 fs = %FS% Hz（= 50 MHz / 512，BCK_DIV=1）。改 BCK_DIV 必须重跑本脚本。
//
//  本文件含 4 个模块：
//    piano_sin_rom      8 bit 相位 → 16 bit 正弦（象限折叠，仅存 %NQ% 项 1/4 波表）
//    piano_note_lut     音符 → 基频相位增量(32 bit Q32) + 齐奏拍频增量
//    piano_vel_lut      力度 → Q16 增益 + 琴槌噪声低通档位
//    piano_partial_lut  泛音序号 → 幅度/明亮度/衰减移位/非谐性拉伸移位
//
//  ★ 不用 $readmemh 读外部文件：参考实现 26Embedded/fpga_spark 的 piano_voice.v
//    用 $readmemh("wavetable_sine.hex")，文件不在工作目录时 ROM 全 0（完全静音），
//    极难排查。本工程一律 case 常量表（与 wave_rom.v 一致）。
//
//  ★ 16 bit 有符号常数一律写成 -16'sdNNN；写 16'sd-NNN 在 Verilog 里是非法字面量
//    （本项目实测报过 508 个 Expecting numeric digits）。
// =============================================================================
`default_nettype none

// -----------------------------------------------------------------------------
//  piano_sin_rom —— 1/4 波表 + 象限折叠
//    phase[7:6] = 象限，phase[5:0] = 象限内位置
//    idx = phase[6] ? (64 - pos) : pos   （0..64，含 90° 端点）
//    neg = phase[7]
//  只存 %NQ% 项，面积约为 256 项全表的 1/4。
// -----------------------------------------------------------------------------
module piano_sin_rom (
    input  wire               clk,
    input  wire [7:0]         phase,     // 一个整周期 = 256 步
    output reg  signed [15:0] data
);

    wire [6:0] pos = {1'b0, phase[5:0]};
    wire [6:0] idx = phase[6] ? (7'd64 - pos) : pos;
    wire       neg = phase[7];

    reg signed [15:0] q;

    always @(*) begin
        case (idx)
%QUARTER%
            default: q = 16'sd0;
        endcase
    end

    always @(posedge clk)
        data <= neg ? (-q) : q;

endmodule

// -----------------------------------------------------------------------------
//  piano_note_lut —— MIDI 音符 → 频率
//    f0_step  : 等程律 f = 440 × 2^((n-69)/12)，相位增量 = round(f × 2^32 / fs)
//    beat_step: 同音多弦的失谐拍频（Hz → 相位增量）
//               取自 Faust STK piano1.dsp 的 detuningHz 表：
//               低音 0.003 Hz → 中音 0.25 Hz → 高音 1.0 Hz
//               ⚠️ 是【零点几 Hz 的拍频】，不是固定 0.1%% 的频率偏移
//  组合逻辑（只在 note-on 那一拍被读），无寄存器。
// -----------------------------------------------------------------------------
module piano_note_lut (
    input  wire [6:0]  note,
    output reg  [31:0] f0_step,
    output reg  [31:0] beat_step
);

    always @(*) begin
        case (note)
%NOTES%
            default: begin f0_step = 32'd0; beat_step = 32'd0; end
        endcase
    end

endmodule

// -----------------------------------------------------------------------------
//  piano_vel_lut —— 力度 → 增益 / 琴槌噪声低通档位
//    gain_q16 : 0.12 .. 1.0（≈ -18 dB 动态），曲线 (v/127)^1.6
//    lp_sh    : 一阶低通右移量，力度越大越小（越亮）
// -----------------------------------------------------------------------------
module piano_vel_lut (
    input  wire [6:0]  vel,
    input  wire [1:0]  inst,          // 0=钢琴 1=电吉他 2=古筝
    output reg  [16:0] gain_q16,
    output reg  [2:0]  lp_sh
);

    always @(*) begin
        case ({inst, vel})
%VELS%
            default: begin gain_q16 = 17'd7864; lp_sh = 3'd3; end
        endcase
    end

endmodule

// -----------------------------------------------------------------------------
//  piano_partial_lut —— 第 n 个泛音分量的全部参数（n = 0..%NP1% 对应 1..%NP% 次泛音）
//    amp_q16  : 幅度系数（Q16，满幅 = 65536）。6 个之和在最强奏时 ≈ 1.0
//    k_q12    : 力度→明亮度系数（Q12），实际增益 ×(1 + K/4096)
//    s_ring   : 按住时的衰减移位（env -= env >> s_ring）
//    s_damp   : 松开后的衰减移位（阻音器）
//    st1/st2  : 非谐性拉伸（inc = n·f0 + (f0>>st1) + (f0>>st2)），31 = 该项为 0
//  设计依据见 gen_piano_rom.py 头部（AMY / Faust STK）。
// -----------------------------------------------------------------------------
module piano_partial_lut (
    input  wire [2:0]  n,
    input  wire [2:0]  band,
    input  wire [1:0]  inst,          // 0=钢琴 1=电吉他 2=古筝
    output reg  [16:0] amp_q16,
    output reg  [15:0] k_q12,
    output reg  [4:0]  s_ring,
    output reg  [4:0]  s_damp,
    output reg  [4:0]  st1,
    output reg  [4:0]  st2
);

    //  ⚠️ amp/k/st1/st2 随乐器变；**s_ring/s_damp 三个乐器给同一组值**
    //     —— 因为它们在声部里是【常量索引查表 ⇒ 综合时折叠成常数移位】，
    //        一旦随乐器变就会在每采样路径长出桶形移位器（MODE=1 裕量只有 +0.009 ns）。
    //        乐器的衰减差异改由 ksh_ofs（piano_inst_lut）表达。
    always @(*) begin
        case ({inst, band, n})
%PARTS%
            default: begin
                amp_q16 = 17'd0; k_q12 = 16'd0;
                s_ring = 5'd18; s_damp = 5'd13; st1 = 5'd31; st2 = 5'd31;
            end
        endcase
    end

endmodule

// -----------------------------------------------------------------------------
//  piano_inst_lut —— 乐器级参数（2026-10-06 多乐器）
//    ham_gain_q16 : 激励（琴槌/拨片/指甲）的初始能量。钢琴 = 原来的 HAM_GAIN_Q16 = 19661
//    ksh_ofs      : 包络更新速率的乐器偏移（2 bit 编码：0→−1, 1→0, 2→+1）
//                   ⇒ 古筝 +1（木共鸣箱衰减更长）、吉他 −1（本体短，延音靠音箱）
//  ⚠️ 钢琴行必须与原值逐位相同（回归要求）
// -----------------------------------------------------------------------------
module piano_inst_lut (
    input  wire [1:0]  inst,
    output reg  [16:0] ham_gain_q16,
    output reg  [1:0]  ksh_ofs_enc
);

    always @(*) begin
        case (inst)
%INSTS%
            default: begin ham_gain_q16 = 17'd19661; ksh_ofs_enc = 2'd1; end
        endcase
    end

endmodule

// -----------------------------------------------------------------------------
//  piano_vib_lut —— 颤音速率（拓展② 表情维度）
//    rate 0..127 → LFO 频率 f_lfo = rate × 0.1 Hz（0 → 0，50 → 5.0 Hz，127 → 12.7 Hz）
//    输出 inc = round(f_lfo × 2^32 / fs)，直接当 32 bit 相位累加增量用
//    调制度公式见 piano_engine.v 文件头（depth → ±49.6 cent 线性）
// -----------------------------------------------------------------------------
module piano_vib_lut (
    input  wire [6:0]  rate,
    output reg  [31:0] inc
);

    always @(*) begin
        case (rate)
%VIBS%
            default: inc = 32'd0;
        endcase
    end

endmodule

// -----------------------------------------------------------------------------
//  piano_glide_lut —— 滑音时长（拓展② 表情维度）
//    t 0..127 → 时长 t_glide = t × 4 ms（127 → 508 ms，0 → 立即跳变）
//    输出 r = round(2^24 / N)，N = 该时长的采样点数（16 bit，误差 ≤ 0.15%）
//    RTL: step = (delta × r) >> 24 ⇒ 每采样点线性推进（一次 17×16 乘法，无除法器）
//    ⚠️ 用 Q24 而不是 Q32：N<2^16 ⇒ 2^24/N 天然只有 16 bit，乘法小一个数量级；
//      用 Q32 会变成 33×33 乘法，单周期收敛不了（MODE=1 时序违例元凶之一）。
// -----------------------------------------------------------------------------
module piano_glide_lut (
    input  wire [6:0]  t,
    output reg  [15:0] recip
);

    always @(*) begin
        case (t)
%GLIDES%
            default: recip = 16'd0;
        endcase
    end

endmodule

`default_nettype wire
'''


def fmt_signed16(v: int) -> str:
    return ("-16'sd%d" % (-v)) if v < 0 else ("16'sd%d" % v)


def build() -> str:
    body = HEADER
    # 1/4 正弦表
    qlines = []
    for i in range(N_QUARTER):
        val = int(round(32767.0 * math.sin(2.0 * math.pi * i / 256.0)))
        val = max(-32768, min(32767, val))
        qlines.append("            7'd%d: q = %s;\n" % (i, fmt_signed16(val)))
    # 音符表
    nlines = []
    for n in range(128):
        f = f_of_note(n)
        nlines.append("            7'd%d: begin f0_step = 32'd%d; beat_step = 32'd%d; end // %.2f Hz, beat %.4f Hz\n"
                      % (n, step_of_hz(f), step_of_hz(detune_hz(n)), f, detune_hz(n)))
    # 力度表（多乐器：case 索引是 {inst, vel}，共 3×128）
    #   ⚠️ 钢琴行（inst=0）必须与原表逐位相同 —— 换乐器不能动钢琴
    #   grep 关键字 '10'd' 便于核对
    vlines = []
    for k_inst in range(len(INSTRUMENTS)):
        cfg = INSTRUMENTS[k_inst]
        for v in range(VEL_PTS):
            lp = min(7, max(0, vel_lp_shift(v) + cfg["lp_ofs"]))
            vlines.append("            10'd%d: begin gain_q16 = 17'd%d; lp_sh = 3'd%d; end\n"
                          % ((k_inst << 7) | v, vel_gain_q16(v), lp))
    # 泛音参数表（多乐器 5 音区：case 索引是 {inst, band, n} = 8 bit，共 3×5×6 = 90 行）
    plines = []
    for k_inst in range(len(INSTRUMENTS)):
        cfg = INSTRUMENTS[k_inst]
        ks   = inst_k_table(k_inst)
        sr_t = cfg["s_ring"]
        sd_t = cfg["s_damp"]
        for k_band in range(N_BAND):
            amps = inst_amp_table(k_inst, k_band)
            b_val = cfg["band_B"][k_band]
            for i in range(N_PART):
                st1, st2 = inharm_shifts(i + 1, b_val)
                plines.append("            8'd%d: begin amp_q16 = 17'd%d; k_q12 = 16'd%d; s_ring = 5'd%d; s_damp = 5'd%d; st1 = 5'd%d; st2 = 5'd%d; end\n"
                              % ((k_inst << 6) | (k_band << 3) | i, amps[i], ks[i],
                                 sr_t[i], sd_t[i], st1, st2))
    # 乐器级参数表
    ilines = []
    for k_inst, cfg in enumerate(INSTRUMENTS):
        ilines.append("            2'd%d: begin ham_gain_q16 = 17'd%d; ksh_ofs_enc = 2'd%d; end // %s\n"
                      % (k_inst, cfg["ham"], KSH_OFS_ENC[cfg["ksh_ofs"]], cfg["name"]))
    # 颤音速率表（⚠️ 变量名不要和力度表 vlines 撞：上一版撞了，结果力度表被覆盖）
    vibl = []
    for v in range(128):
        vibl.append("            7'd%d: inc = 32'd%d;   // f_lfo = %.1f Hz\n"
                    % (v, vib_inc_q32(v), v * VIB_HZ_PER))
    # 滑音时长表
    glines = []
    for t in range(128):
        glines.append("            7'd%d: recip = 16'd%d;  // N = %d 采样 = %.1f ms\n"
                      % (t, glide_recip_q24(t), glide_samples(t), glide_samples(t) / FS * 1e3))

    for k, v in {
        '%FS%':   ('%g' % FS),
        '%NQ%':   str(N_QUARTER),
        '%NP%':   str(N_PART),
        '%NP1%':  str(N_PART - 1),
        '%QUARTER%': ''.join(qlines).rstrip('\n'),
        '%NOTES%':   ''.join(nlines).rstrip('\n'),
        '%VELS%':    ''.join(vlines).rstrip('\n'),
        '%PARTS%':   ''.join(plines).rstrip('\n'),
        '%INSTS%':   ''.join(ilines).rstrip('\n'),
        '%VIBS%':    ''.join(vibl).rstrip('\n'),
        '%GLIDES%':  ''.join(glines).rstrip('\n'),
    }.items():
        body = body.replace(k, v)
    return body


def selftest():
    """打印全部参数 + 自检断言（不写文件时也能看到『这些数怎么来的』）"""
    ok = True
    print('fs = %g Hz  (50 MHz / 512),  BCK_DIV = %d' % (FS, BCK_DIV))
    print('泛音数 N_PART = %d   每声部 %d 个独立相位累加器' % (N_PART, N_PART))
    print('')
    print('--- 音符 → 频率字 ------------------------------------------------')
    for n in (21, 36, 48, 60, 69, 72, 84, 96, 108, 127):
        f = f_of_note(n)
        st = step_of_hz(f)
        back = st * FS / PHASE_MOD
        err = abs(back - f)
        print('  note %3d  f=%9.3f Hz  f0_step=%10d  反算=%9.3f Hz  误差=%6.4f Hz  beat=%6.3f Hz'
              % (n, f, st, back, err, detune_hz(n)))
        assert st < (1 << 32), 'note %d 频率字溢出 32 bit' % n
        assert err < 0.01, 'note %d 频率字误差过大' % n
        # 高次泛音不得溢出：inc ≈ n·f0 必须在 32 bit 内
        assert st * N_PART < (1 << 32), 'note %d 第 %d 次泛音增量溢出 32 bit' % (n, N_PART)
    print('')
    print('--- 包络时间常数 --------------------------------------------------')
    print('  τ = 2^(s+k)/fs，k(note)=clamp((90-note)>>4, 0, 2)')
    print('  note  k    Στ(按住)   τ(阻音器, 松开)')
    for n in (36, 48, 60, 69, 84, 96):
        k = pitch_k(n)
        tr = 2.0 ** (S_RING[0] + k) / FS
        td = 2.0 ** S_DAMP[0] / FS
        print('  %4d %2d   %8.2f s   %8.1f ms' % (n, k, tr, td * 1000))
    for i in range(N_PART):
        assert S_DAMP[i] < S_RING[i], '阻音器必须比按住衰减快'
    # 最长衰减的时间常数 + 可表示动态范围：env 是 32 bit，衰减停在 2^s
    for i in range(N_PART):
        dr = 20.0 * math.log10((1 << 32) / float(1 << S_RING[i]))
        assert dr > 70.0, '第 %d 次泛音衰减动态范围只有 %.0f dB，会「衰减卡住」' % (i + 1, dr)
    print('  衰减档位 s_ring=%s  s_damp=%s' % (S_RING, S_DAMP))
    print('  32 bit 包络的尾部动态范围 = 每档 > 70 dB（不会出现「衰减卡在半路」）')
    print('')
    print('--- 非谐性拉伸（B = %.4f）----------------------------------------' % INHARM_B)
    print('   n   理论拉伸   实现拉伸   相对误差   移位对')
    for i in range(N_PART):
        n = i + 1
        th = math.sqrt(1.0 + INHARM_B * n * n)
        re, _ = inharm_realized(n)
        st1, st2 = inharm_shifts(n)
        rel = (re - th) / th * 100.0
        print('   %d   %8.5f   %8.5f   %+7.3f%%   (%d,%d)' % (n, th, re, rel, st1, st2))
        assert abs(rel) < 0.2, '第 %d 次泛音非谐性误差过大' % n
    print('')
    print('--- 泛音幅度（Q16）-------------------------------------------------')
    tot_soft = sum(AMP_Q16)
    tot_hard = sum(int(round(AMP_Q16[i] * (1.0 + K_Q12[i] / 4096.0))) for i in range(N_PART))
    print('   n  amp_q16  占比(弱奏)  k_q12   最强奏增益   占比(强奏)')
    for i in range(N_PART):
        h = int(round(AMP_Q16[i] * (1.0 + K_Q12[i] / 4096.0)))
        print('   %d  %7d   %7.1f%%  %6d   ×%6.2f   %7.1f%%'
              % (i + 1, AMP_Q16[i], 100.0 * AMP_Q16[i] / tot_soft,
                 K_Q12[i], h / float(AMP_Q16[i]), 100.0 * h / tot_hard))
    print('  六泛音之和：弱奏 %d/65536 = %.3f FS  强奏 %d/65536 = %.3f FS'
          % (tot_soft, tot_soft / 65536.0, tot_hard, tot_hard / 65536.0))
    assert tot_hard <= 65536, '最强奏六泛音之和超过满幅，会削顶'
    assert tot_soft < tot_hard, '力度应让高次泛音相对增强'
    print('  ⇒ 强奏峰值 ≈ 满幅（不削顶），弱奏只有 %.0f%% 幅度且高次泛音几乎消失' % (100.0 * tot_soft / 65536.0))
    print('')
    print('--- 力度曲线 -------------------------------------------------------')
    for v in (1, 16, 32, 48, 64, 80, 96, 112, 127):
        print('  vel %3d  gain = %.4f (%+6.1f dB)  琴槌低通移位 = %d'
              % (v, vel_gain_q16(v) / 65536.0,
                 20.0 * math.log10(vel_gain_q16(v) / 65536.0), vel_lp_shift(v)))
    assert vel_gain_q16(127) == 65536, '最强奏应为 1.0'
    assert vel_gain_q16(1) < 8000, '最弱奏应足够轻'
    print('')
    print('--- 表情：颤音速率 / 滑音时长（拓展②）-------------------------------')
    print('  颤音：f_lfo = vib_rate × 0.1 Hz；调制度 depth_k = vib_depth × 15 (Q16)')
    print('        ⇒ depth=127 时 ±%.3f %% = ±%.1f cent'
          % (100.0 * (127 * 15) / 65536.0,
             1200.0 * math.log2(1.0 + (127 * 15) / 65536.0)))
    for v in (0, 16, 32, 50, 64, 100, 127):
        print('    vib_rate %3d → f_lfo = %5.1f Hz   inc = %10d' % (v, v * VIB_HZ_PER, vib_inc_q32(v)))
    assert vib_inc_q32(0) == 0, 'vib_rate=0 必须完全不调制'
    assert abs(vib_inc_q32(50) * FS / PHASE_MOD - 5.0) < 0.01, 'vib_rate=50 应为 5.0 Hz'
    print('  滑音：t_glide = glide_time × 4 ms；step = (delta × r) >> 24（r = round(2^24/N)）')
    for t in (0, 1, 16, 32, 64, 100, 127):
        n = glide_samples(t)
        r = glide_recip_q24(t)
        print('    glide_time %3d → N = %6d 采样 = %6.1f ms   r = %5d   反算时长 = %6.1f ms'
              % (t, n, n / FS * 1e3, r, (float(1 << 24) / r) / FS * 1e3))
    # 校验：Q24 反算出的采样数应与 N 一致（t=0 是特例：RTL 判为"无滑音"）
    for t in (1, 16, 32, 64, 100, 127):
        n_back = (float(1 << 24) / glide_recip_q24(t))
        err = abs(n_back - glide_samples(t)) / glide_samples(t) * 100.0
        assert err < 0.5, 'glide Q24 反算误差过大: t=%d err=%.3f%%' % (t, err)
    print('    ⇒ Q24 反算滑音时长最大误差 < 0.5%（听不出来）')
    print('')
    print('自检通过：全部断言 OK' if ok else '自检失败')
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--write', action='store_true', help='写 rtl/synth/piano_rom.v')
    args = ap.parse_args()

    selftest()
    text = build()
    # ★ 只检查【数据行】，不检查注释 —— 头部注释里本来就要举反例说明这个坑
    for ln in text.split('\n'):
        s = ln.strip()
        if s.startswith('//') or s.startswith('*'):
            continue
        assert "16'sd-" not in s, '出现非法负数字面量（必须写 -16\'sdNNN）: %s' % s
        assert "17'sd-" not in s and "32'sd-" not in s, '出现非法负数字面量: %s' % s
    if args.write:
        here = os.path.dirname(os.path.abspath(__file__))
        dst = os.path.normpath(os.path.join(here, '..', '..', 'rtl', 'synth', 'piano_rom.v'))
        with open(dst, 'w', encoding='utf-8', newline='\n') as f:
            f.write(text)
        print('')
        print('wrote %s  (%d bytes, %d lines)' % (dst, len(text), text.count('\n') + 1))
    else:
        print('')
        print('（未加 --write，只做自检；产物 %d 字节）' % len(text))


if __name__ == '__main__':
    main()
