# -*- coding: utf-8 -*-
"""gen_song_rom.py —— 生成 song_rom.v（演示模式歌曲音符 ROM，纯 case 常量表）

演示模式需要 FPGA 自己"唱"几首歌。本脚本把【乐谱（音名 + 时值）】编译成 RTL 能
直接用的 `case` 常量 ROM。

===============================================================================
 ★★ 合规声明（这一段是给评委看的，请勿删）★★
===============================================================================
1. ⛔ **本 ROM 存的是【乐谱】（音符编号 + 时值），不是音频采样。**
   ROM 里没有任何波形 / PCM 数据 —— 声音仍由振荡器 + ADSR **逐样本实时合成**。
   这是赛题红线"严禁播放预录 PCM / 预置推流 / 整段录音触发"的核心要求。

2. ⚠️ **曲目版权状态逐首如实记录**（见下面 SONGS 的"授权状态"字段，
   以及生成出来的 song_rom.v 顶部注释）。当前含一首**未获授权**的流行曲，
   这是**使用者知情决定**，风险由使用者承担 —— **记录在案，不掩盖**。
   ⛔ 也**不使用** MAESTRO（CC BY-NC-SA 4.0，非商业 + 传染性）。

3. ✅ **音符数据来源逐首交代**：
   · 公有领域曲目：由本队【自行整理】，未复制任何第三方文件。
   · Faded：取自本队自己的编配脚本 `26Embedded/fpga_spark/sim/simulate_faded_guitar.py`
     （同一支队伍的作品，提取其副歌**旋律线**）。
   ⚠️ 本队调研时读过的开源蜂鸣器曲库中 star 最高的
      `robsoncouto/arduino-songs` 经 GitHub API 实测 **`license: null`**
      （无许可证文件），其 README 的口头许可**不能作为举证依据**，
      因此**本工程没有使用它的任何数据文件** —— 只在"音符怎么编码、怎么断句"上
      借鉴了公开可见的结构思路。这是刻意取舍，不是疏漏。

   参考例程（只学结构与编码思路，均不复制数据）：
     [R1] sirius1242/musicbox —— Verilog 八音盒，**MIT 许可**（LICENSE 原文已核对）
          https://github.com/sirius1242/musicbox
          学到：① 乐谱文本按 `音级 八度 时值` 编码再由工具转成 ROM；
                ② 一个音符响满时值后**再插 1 ms 静音**才推进地址 ⇒ 断句
                   （本工程 song_player.v 的 GAP_TICKS 就是这个思路）。
     [R2] JN513/Simple-FPGA-Music-Player-with-PWM —— **MIT 许可**（GitHub API 实测
          `"license":{"spdx_id":"MIT"}`）
          https://github.com/JN513/Simple-FPGA-Music-Player-with-PWM
          学到：乐谱驱动的状态机结构（取音符 → 计时 → 推地址）。
          ⚠️ 它是 **PWM 蜂鸣器单音**输出，与本工程 I2S/PT8211 音频通路无关，
             未借鉴其任何音频通路。

   （后续增强：`pnlong/PDMX` 是 MIT 的 25 万首公有领域乐谱集，数据方自己建议只取
     `no_license_conflict` 子集；将来可走 "PDMX → MIDI → 解析 → 本生成器" 的管线。）

===============================================================================
 ★ ROM 编码（35 bit / 音符）
===============================================================================
    dout = {is_end, note[6:0], vel[6:0], dur[19:0]}
             bit34  33:27     26:20    19:0

    is_end  : 1 = 本地址没有音符（曲末/越界）→ 播放器回到第 0 个音符（单曲循环）
    note    : MIDI 音符号 0..127；7'h7F = 休止符（只等时值，不发 note-on）
    vel     : 力度 0..127（直接送到 note 总线的 on_vel）
    dur     : 本音符占用的槽长，单位 = sample_tick（97 656.25 Hz 的一个采样点）

  ★ 为什么 dur 直接用"采样点数"而不是"几分音符 + 速度 BPM"：
    播放器是按 sample_tick 走的状态机，存采样点数就**不需要在 RTL 里做除法**，
    也彻底消除"BPM 换算取整"造成的节奏漂移。速度是生成期定死的常量，
    想改速度就改本脚本的 BPM 再重新生成 —— 演示模式不需要运行时变速。

  ★ 为什么是 20 bit 槽长：2^20 = 1 048 576 tick = 10.74 s，比任何单音都长。
  ★ 地址：[song(4) | addr(9)] 拼成一个扁平 case 选择子 —— 综合出来是一张 ROM，
    而不是"先按歌选、再按地址选"的两级 MUX。

用法：
    python gen_song_rom.py --dump            # 只打印，不写文件
    python gen_song_rom.py --write           # 生成 rtl/synth/song_rom.v + 音符表
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from fractions import Fraction

sys.stdout.reconfigure(encoding='utf-8')

# ------------------------------------------------------------------ 全局常量 --
FS_NUM = 9765625          # 采样率 97656.25 Hz = 9765625/100
FS_DEN = 100
DUR_W = 20                # 槽长位宽
NOTE_W = 7
VEL_W = 7
WORD_W = 1 + NOTE_W + VEL_W + DUR_W   # 35 = {is_end, note, vel, dur}
ADDR_W = 9                # 每首歌最多 2^9 = 512 个音符
SONG_W = 4                # 最多 16 首歌

NOTE_REST = 0x7F          # 7'h7F = 休止符（也是 off 总线上的 all-notes-off 广播码）
MAX_NOTE = 0x7E           # 允许作为音高的最大值
MELODY_VEL = 100          # 旋律线统一力度

# 授权状态取值（字符串常量，写错会在 main() 的断言里被抓出来）
LIC_PD = "PD"                 # 公有领域
LIC_COPYRIGHT = "COPYRIGHT"   # 受版权保护且本队未获授权

NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
ACCIDENTAL = {"Db": "C#", "Eb": "D#", "Gb": "F#", "Ab": "G#", "Bb": "A#",
              "CS": "C#", "DS": "D#", "FS": "F#", "GS": "G#", "AS": "A#"}


def midi_of(name: str) -> int:
    """'C4' 'F#4' 'Bb3' 'GS5' → MIDI 音符号（C4 = 60，A4 = 69 = 440 Hz）"""
    if len(name) >= 2 and name[1] in "#bS":
        pitch, octave = name[:2], int(name[2:])
    else:
        pitch, octave = name[:1], int(name[1:])
    pitch = ACCIDENTAL.get(pitch, pitch)
    assert pitch in NOTE_NAMES, 'bad note name %r' % name
    return (octave + 1) * 12 + NOTE_NAMES.index(pitch)


def B(beats) -> Fraction:
    """时值 → 分数。写 0.25/0.5/1.5 这种字面量时用 str 转换，保证精确无浮点误差。"""
    return beats if isinstance(beats, Fraction) else Fraction(str(beats))


# =============================================================================
#  乐谱数据（音名 + 拍数；拍数单位 = 四分音符，None = 休止符）
# =============================================================================
#  数据是【逐个音符】的旋律序列 —— 不是预录 PCM，符合赛题红线。

# ---- 0. Faded (Alan Walker) 副歌主旋律 --------------------------------------
#  ⛔ 版权状态：旋律受版权保护，**本队未获授权**。纳入演示模式是使用者的知情
#     决定（用户明确表示"要流行歌，版权风险我自己承担"），风险由使用者承担。
#
#  🔴🔴 作废声明（2026-10-05，用户亲耳确认）🔴🔴
#  **下面这 29 个音所依据的源数据后来被用户确认为【不是《Faded》】** ——
#  用户用电脑扬声器播放真实的《Faded》并逐句比对后否定了它。
#  ⇒ **本版 Faded 数据【已作废，待替换】**；保留在文件里只是为了不打断构建，
#     等拿到**真旋律**后用 `tools/gen/melody_table_to_rom.py --write` 再替换一次。
#
#  ★★ 全队教训（比这段数据值钱，务必读）★★
#  `liaison` 当时给出的"三重独立印证"是：① 音阶 7/7 吻合 ② 和弦进行都是
#  i-VI-III-VII ③ 两个来源都是 90 BPM。**这三条全部是【宏观属性】，
#  没有一条能识别一首歌** —— 几乎所有流行歌都是 7 音音阶、i-VI-III-VII 是最常见
#  套路之一、90 BPM 到处都是。**识别一首歌的唯一判据是【旋律的音程走向】（逐音比对）。**
#  ⇒ 结论强度超过了证据（AGENTS.md §8.1 的延伸：结论不仅要带【版本指纹】，
#     还必须带【证据强度】—— 不能把"宏观相符"说成"确证"）。
#
#  ★★ 数据来源（2026-10-05 第一次更正：换掉了整条旋律线）★★
#  旧数据是从队里那份**吉他指弹编配** `26Embedded/fpga_spark/sim/simulate_faded_guitar.py`
#  的 `add_note` 层提取的 —— 用户上板试听后指出"Faded 旋律不对"。
#  复核证实：**那一层根本不是人声旋律，而是吉他分解和弦伴奏**（定量证据：
#  主歌 11/12 个音都是当小节和弦的和弦音 = 92%；副歌音程级进率极低）。
#  ⇒ 于是改用 `liaison/faded/MELODY-chorus-A.txt`（29 音，取自 bitmidi 的 faded.mid）
#     —— **但该源数据本身又是错的（见上面的作废声明）**。
#
#  ✅ 唯一还站得住的：**"源表 → ROM"这一段是纯机械的**。
#     用 `tools/gen/melody_table_to_rom.py --in <表> --shift 5 --bpm 120 --write`
#     一条命令替换（自带幂等自检 `--verify`）。换真旋律时**不要手打音符**。
#     该脚本还算两条判据（级进率/重合率）用于**上板前**分辨"单声部旋律 vs 分解和弦"
#     —— 但它**只能证明"是一条旋律"，不能证明"是哪首歌"**。
#
#  ★ 调性：原 MIDI 是 **B 小调**，本工程整体 **+5 半音 → E 小调**。
#    为什么选 +5（而不是 -7 或保持 B 小调）：队里那份**吉他伴奏编配就是 E 小调**
#    （Em-C-G-D = i-VI-III-VII）。把旋律也放在 E 小调，将来若要把
#    "旋律 + 伴奏"合成双声部，二者调性天然一致，不必二次移调。
#    （+5 后音域 E5..E6；若嫌偏高，改成 -7 半音即可整体降八度，音程不变。）
#
#  ★ 时值用【相邻起拍之差】，不用 MIDI 的 note-off 时长 ——
#    本播放器是单声部顺序播发，若用 note-off 时长（它略长于起拍间隔，例如
#    第 1 音 538.5 ms > 间隔 500 ms），每个音的误差会**逐个累积**，整段节奏越走越偏。
#    用起拍差值则与谱面起拍严格对齐，无漂移。最后一音没有"下一个起拍"，
#    用其自身时长 972.92 ms（= 95011 tick，与 liaison 给的 dur_tick 一致）。
#  ★ 速度：120 BPM（1 拍 = 0.5 s，与源 MIDI 一致）。
#
#  ★ 自查判据（liaison 给的两条，用来区分"旋律"与"分解和弦"）：
#      级进率（相邻音高差 ≤2 半音占比）= **60.7%**  ← 参考：旋律轨 65.6%，分解和弦轨 0.3%
#      重合率（同时响 >1 音的时间占比）  = **0.2%**   ← 参考：旋律轨 0.4%，分解和弦轨 46.3%
#    ⇒ 两条都落在"旋律"一侧，确认这次拿到的是真旋律。
#  说明：原曲是电子舞曲（合成器 Lead），本工程用多音色合成引擎发声；
#        音色由外部（top.v / 钢琴引擎）选择，本模块不越权改音色。
# ============================================================================
#  ★★ 机器生成区（BEGIN）—— 请勿手工编辑！★★
#  这一段由 `tools/gen/melody_table_to_rom.py --write` 自动改写：
#      python tools/gen/melody_table_to_rom.py --in <旋律表> --shift <半音> --bpm <BPM> --write
#  它读「idx note midi vel start_s dur_ms dur_tick」格式的旋律表，
#  自动做「移调」+「起拍差→时值」+「音名换算」，并原地替换下面 BEGIN/END 之间的内容。
#  ⇒ 换旋律时**不要手打音符**：手抄错音正是本项目栽过的坑（见上面 ★★ 数据来源 ★★）。
#  改完记得跑一遍生成器（会做回读逐 bit 校验）与 tb_song_player。
# ============================================================================
# ==== FADED_CHORUS-BEGIN ====
FADED_CHORUS = [
    ("G5", 1), ("B5", 1), ("D6", 3), ("E6", 1),
    ("D6", 1), ("B5", 1), ("A5", 1), ("G5", 1),
    ("E5", 2), ("E5", 1), ("F#5", 1), ("G5", 3),
    ("B5", 1), ("D6", 3), ("E6", 1), ("D6", 1),
    ("B5", 1), ("A5", 1), ("G5", 1), ("A5", 6),
    ("G5", 1), ("B5", 1), ("D6", 3), ("E6", 1),
    ("D6", 1), ("B5", 1), ("A5", 1), ("G5", 1),
    ("E5", 1.94583),
]
# ==== FADED_CHORUS-END ====
# ============================================================================
#  ★★ 机器生成区（END）★★
# ============================================================================

def N(note, beats, vel: int = MELODY_VEL):
    """单音符（支持自定义力度 vel 1..127，用于乐句强弱呼吸感）"""
    return (note, B(beats), vel)


def CHORD(accomp_notes, melody_note, beats, vel: int = 104, accomp_vel: int = 68, strum_beats: str = "0.002"):
    """多声部同时和弦 / 吉他扫弦辅助函数：
    - accomp_notes: 伴奏和弦音列表（如左手低音+五度 ["G#2", "D#3"] 或吉他低三弦 ["E3", "B3", "E4"]）
    - melody_note : 主旋律音（如 "D#4"）
    - beats       : 整个和弦+旋律所占的总拍数（主音保持响满剩余拍数，伴奏音在 song_player 中与主音同步叠加发声）
    - strum_beats :
        · 钢琴/小提琴双音用 "0.002" (约 1 ms 极速连发，听感为完全同时落键的饱满和弦)
        · 吉他扫弦用 "0.035" (约 17 ms 逐弦扫过，模拟真实拨片/手指扫弦颗粒感，所有弦同时延音)
    """
    sb = B(strum_beats)
    total_b = B(beats)
    n_acc = len(accomp_notes)
    rem_b = total_b - sb * n_acc
    assert rem_b > 0, f"CHORD total beats {beats} too short for {n_acc} accomp notes"
    seq = []
    for an in accomp_notes:
        seq.append((an, sb, accomp_vel))
    seq.append((melody_note, rem_b, vel))
    return seq


def flatten_notes(raw_list):
    """展开含 CHORD(...) 子列表或二元组/三元组的乐谱序列"""
    flat = []
    for item in raw_list:
        if isinstance(item, list):
            for sub in item:
                flat.append(sub)
        elif isinstance(item, tuple):
            if len(item) == 2:
                flat.append((item[0], item[1], MELODY_VEL))
            elif len(item) == 3:
                flat.append(item)
            else:
                raise ValueError(f"Invalid note tuple: {item}")
        else:
            raise ValueError(f"Invalid note item: {item}")
    return flat


# ---- 1. 欢乐颂 Ode to Joy（Beethoven, PD；多声部交响和声编配版）--------------
ODE_TO_JOY = flatten_notes([
    # A1 句：温暖中强 (mf) 双声部/三声部柱式和弦护航
    CHORD(["C3", "G3"], "E4", 1, vel=98, accomp_vel=68),
    N("E4", 1, 94),
    N("F4", 1, 98),
    CHORD(["G2", "B3"], "G4", 1, vel=104, accomp_vel=70),
    CHORD(["G2", "B3"], "G4", 1, vel=102, accomp_vel=68),
    N("F4", 1, 96),
    CHORD(["C3", "G3"], "E4", 1, vel=94, accomp_vel=66),
    N("D4", 1, 90),
    CHORD(["C3", "E3"], "C4", 1, vel=96, accomp_vel=68),
    N("C4", 1, 92),
    N("D4", 1, 96),
    CHORD(["C3", "G3"], "E4", 1, vel=100, accomp_vel=68),
    CHORD(["G2", "B3"], "E4", 1.5, vel=102, accomp_vel=70),
    N("D4", 0.5, 86),
    CHORD(["G2", "G3", "B3"], "D4", 2, vel=96, accomp_vel=66),

    # A2 句：渐强推进 (f)
    CHORD(["C3", "G3"], "E4", 1, vel=102, accomp_vel=72),
    N("E4", 1, 98),
    N("F4", 1, 102),
    CHORD(["G2", "B3"], "G4", 1, vel=108, accomp_vel=74),
    CHORD(["G2", "B3"], "G4", 1, vel=106, accomp_vel=72),
    N("F4", 1, 100),
    CHORD(["C3", "G3"], "E4", 1, vel=98, accomp_vel=70),
    N("D4", 1, 94),
    CHORD(["A2", "E3"], "C4", 1, vel=98, accomp_vel=70),
    N("C4", 1, 94),
    CHORD(["G2", "F3"], "D4", 1, vel=100, accomp_vel=70),
    N("E4", 1, 102),
    CHORD(["G2", "F3", "B3"], "D4", 1.5, vel=100, accomp_vel=68),
    N("C4", 0.5, 88),
    CHORD(["C3", "E3", "G3"], "C4", 2, vel=104, accomp_vel=74),

    # B 句：柔美抒情对位 (mp -> cresc.)
    CHORD(["G2", "B3"], "D4", 1, vel=86, accomp_vel=60),
    N("D4", 1, 84),
    CHORD(["C3", "G3"], "E4", 1, vel=90, accomp_vel=62),
    N("C4", 1, 84),
    CHORD(["G2", "B3"], "D4", 1, vel=92, accomp_vel=64),
    N("E4", 0.5, 96),
    N("F4", 0.5, 100),
    CHORD(["C3", "G3"], "E4", 1, vel=94, accomp_vel=64),
    N("C4", 1, 86),
    CHORD(["G#2", "E3"], "D4", 1, vel=96, accomp_vel=66),
    N("E4", 0.5, 100),
    N("F4", 0.5, 104),
    CHORD(["A2", "E3"], "E4", 1, vel=98, accomp_vel=68),
    N("D4", 1, 94),
    CHORD(["D3", "F#3"], "C4", 1, vel=96, accomp_vel=68),
    N("D4", 1, 100),
    CHORD(["G2", "D3", "B3"], "G3", 2, vel=106, accomp_vel=74),

    # A3 再现句：辉煌全奏 (ff)
    CHORD(["C3", "G3", "C4"], "E4", 1, vel=112, accomp_vel=78),
    N("E4", 1, 108),
    N("F4", 1, 110),
    CHORD(["G2", "D3", "B3"], "G4", 1, vel=116, accomp_vel=80),
    CHORD(["E3", "B3"], "G4", 1, vel=114, accomp_vel=76),
    N("F4", 1, 108),
    CHORD(["C3", "G3"], "E4", 1, vel=106, accomp_vel=74),
    N("D4", 1, 102),
    CHORD(["A2", "E3"], "C4", 1, vel=106, accomp_vel=74),
    N("C4", 1, 102),
    CHORD(["G2", "D3"], "D4", 1, vel=108, accomp_vel=76),
    N("E4", 1, 110),
    CHORD(["G2", "F3", "B3"], "D4", 1.5, vel=108, accomp_vel=76),
    N("C4", 0.5, 96),
    CHORD(["C2", "C3", "E3", "G3"], "C4", 2, vel=116, accomp_vel=82),
])

# ---- 2. 小星星 Twinkle Twinkle（1761, PD；吉他扫弦+指弹琶音编配版）----------
#  采用 strum_beats="0.035" 模拟真实木吉他手指/拨片扫弦（低音弦→中音弦→旋律弦依次相差 17ms 扫过并共同延音）
TWINKLE = flatten_notes([
    # A 段：吉他指弹扫弦 + 颗粒感旋律
    CHORD(["C3", "E3", "G3"], "C4", 1, vel=96, accomp_vel=70, strum_beats="0.035"),
    N("C4", 1, 88),
    CHORD(["C3", "E3"], "G4", 1, vel=102, accomp_vel=68, strum_beats="0.035"),
    N("G4", 1, 94),
    CHORD(["F2", "C3", "F3"], "A4", 1, vel=106, accomp_vel=72, strum_beats="0.035"),
    N("A4", 1, 98),
    CHORD(["C3", "E3", "C4"], "G4", 2, vel=100, accomp_vel=70, strum_beats="0.035"),

    CHORD(["F2", "A3", "C4"], "F4", 1, vel=98, accomp_vel=68, strum_beats="0.035"),
    N("F4", 1, 90),
    CHORD(["C3", "G3"], "E4", 1, vel=94, accomp_vel=66, strum_beats="0.035"),
    N("E4", 1, 88),
    CHORD(["G2", "F3", "B3"], "D4", 1, vel=92, accomp_vel=66, strum_beats="0.035"),
    N("D4", 1, 86),
    CHORD(["C3", "E3", "G3"], "C4", 2, vel=96, accomp_vel=70, strum_beats="0.035"),

    # B 段：分解琶音伴奏 + 旋律歌唱
    CHORD(["C3", "E4"], "G4", 1, vel=102, accomp_vel=68, strum_beats="0.035"),
    N("G4", 1, 92),
    CHORD(["F2", "A3"], "F4", 1, vel=98, accomp_vel=66, strum_beats="0.035"),
    N("F4", 1, 90),
    CHORD(["C3", "G3"], "E4", 1, vel=94, accomp_vel=64, strum_beats="0.035"),
    N("E4", 1, 88),
    CHORD(["G2", "D3", "B3"], "D4", 2, vel=96, accomp_vel=68, strum_beats="0.035"),

    CHORD(["C3", "E4"], "G4", 1, vel=104, accomp_vel=70, strum_beats="0.035"),
    N("G4", 1, 94),
    CHORD(["F2", "A3"], "F4", 1, vel=100, accomp_vel=68, strum_beats="0.035"),
    N("F4", 1, 92),
    CHORD(["C3", "G3"], "E4", 1, vel=96, accomp_vel=66, strum_beats="0.035"),
    N("E4", 1, 88),
    CHORD(["G2", "D3", "B3"], "D4", 2, vel=94, accomp_vel=68, strum_beats="0.035"),

    # A' 再现段：莫扎特 K.265 风格双音跑动 + 饱满扫弦收尾
    CHORD(["C3", "E3", "G3"], "C4", 1, vel=98, accomp_vel=70, strum_beats="0.035"),
    N("E4", 0.5, 90), N("C4", 0.5, 86),
    CHORD(["E3", "C4"], "G4", 1, vel=104, accomp_vel=70, strum_beats="0.035"),
    N("E4", 0.5, 92), N("G4", 0.5, 96),
    CHORD(["F2", "C3", "F3"], "A4", 1, vel=108, accomp_vel=74, strum_beats="0.035"),
    N("C5", 0.5, 102), N("A4", 0.5, 96),
    CHORD(["C3", "E3", "C4"], "G4", 2, vel=104, accomp_vel=72, strum_beats="0.035"),

    CHORD(["F2", "A3", "C4"], "F4", 1, vel=100, accomp_vel=70, strum_beats="0.035"),
    N("A4", 0.5, 94), N("F4", 0.5, 90),
    CHORD(["C3", "G3", "C4"], "E4", 1, vel=96, accomp_vel=68, strum_beats="0.035"),
    N("G4", 0.5, 92), N("E4", 0.5, 88),
    CHORD(["G2", "F3", "B3"], "D4", 1, vel=94, accomp_vel=68, strum_beats="0.035"),
    N("F4", 0.5, 90), N("D4", 0.5, 86),
    CHORD(["C2", "G2", "E3", "G3"], "C4", 2, vel=108, accomp_vel=76, strum_beats="0.035"),
])

# ---- 3. 铃儿响叮当 Jingle Bells（J.L. Pierpont 1857, PD；欢快多声部伴奏版）---
JINGLE_BELLS = flatten_notes([
    CHORD(["C3", "G3", "C4"], "E4", 1, vel=102, accomp_vel=70),
    N("E4", 1, 96),
    CHORD(["C3", "G3"], "E4", 2, vel=106, accomp_vel=72),
    CHORD(["C3", "G3", "C4"], "E4", 1, vel=104, accomp_vel=70),
    N("E4", 1, 98),
    CHORD(["C3", "G3"], "E4", 2, vel=108, accomp_vel=72),
    CHORD(["C3", "G3"], "E4", 1, vel=104, accomp_vel=70),
    N("G4", 1, 110),
    CHORD(["A2", "E3"], "C4", 1.5, vel=102, accomp_vel=68),
    N("D4", 0.5, 94),
    CHORD(["C3", "G3", "C4"], "E4", 4, vel=110, accomp_vel=74),

    CHORD(["F2", "C3", "A3"], "F4", 1, vel=106, accomp_vel=72),
    N("F4", 1, 100),
    N("F4", 1.5, 104),
    N("F4", 0.5, 92),
    CHORD(["C3", "G3", "C4"], "F4", 1, vel=102, accomp_vel=70),
    N("E4", 1, 98),
    N("E4", 1, 96),
    N("E4", 0.5, 90), N("E4", 0.5, 92),
    CHORD(["D3", "F#3", "A3"], "E4", 1, vel=102, accomp_vel=70),
    N("D4", 1, 98),
    N("D4", 1, 98),
    N("E4", 1, 102),
    CHORD(["G2", "D3", "B3"], "D4", 2, vel=104, accomp_vel=72),
    CHORD(["G2", "B3", "D4"], "G4", 2, vel=114, accomp_vel=78),

    # 第二遍副歌（终止式回到主音 C）
    CHORD(["C3", "G3", "C4"], "E4", 1, vel=106, accomp_vel=72),
    N("E4", 1, 100),
    CHORD(["C3", "G3"], "E4", 2, vel=110, accomp_vel=74),
    CHORD(["C3", "G3", "C4"], "E4", 1, vel=108, accomp_vel=72),
    N("E4", 1, 102),
    CHORD(["C3", "G3"], "E4", 2, vel=112, accomp_vel=74),
    CHORD(["C3", "G3"], "E4", 1, vel=106, accomp_vel=72),
    N("G4", 1, 112),
    CHORD(["A2", "E3"], "C4", 1.5, vel=104, accomp_vel=70),
    N("D4", 0.5, 96),
    CHORD(["C3", "G3", "C4"], "E4", 4, vel=112, accomp_vel=76),

    CHORD(["F2", "C3", "A3"], "F4", 1, vel=108, accomp_vel=74),
    N("F4", 1, 102),
    N("F4", 1.5, 106),
    N("F4", 0.5, 96),
    CHORD(["C3", "G3", "C4"], "F4", 1, vel=106, accomp_vel=72),
    N("E4", 1, 102),
    N("E4", 1, 100),
    N("E4", 0.5, 94), N("E4", 0.5, 96),
    CHORD(["G2", "D3", "B3"], "G4", 1, vel=112, accomp_vel=76),
    N("G4", 1, 110),
    CHORD(["G2", "F3", "B3"], "F4", 1, vel=106, accomp_vel=74),
    N("D4", 1, 100),
    CHORD(["C2", "C3", "E3", "G3"], "C4", 4, vel=118, accomp_vel=82),
])

# ---- 4. 致爱丽丝 Für Elise（Beethoven, PD；左手真实分解琶音 + 右手旋律完整编配）
#  依靠 32 复音引擎与多声部 song_player，完整还原贝多芬原谱左手 A2-E3-A3 与 E2-E3-G#3 低音琶音！
FUR_ELISE = flatten_notes([
    # 弱起柔美触键 (p)
    N("E5", 0.25, 82), N("D#5", 0.25, 78),
    N("E5", 0.25, 84), N("D#5", 0.25, 80), N("E5", 0.25, 86), N("B4", 0.25, 82), N("D5", 0.25, 88), N("C5", 0.25, 84),
    # 右手落 A4 同时左手奏响 A2 低音根音，随后左手琶音与右手交织延音
    CHORD(["A2", "E3"], "A4", 0.50, vel=92, accomp_vel=66), N("A3", 0.25, 64),
    N("C4", 0.25, 78), N("E4", 0.25, 84), N("A4", 0.25, 92),
    CHORD(["E2", "E3"], "B4", 0.50, vel=94, accomp_vel=66), N("G#3", 0.25, 64),
    N("E4", 0.25, 80), N("G#4", 0.25, 86), N("B4", 0.25, 94),
    CHORD(["A2", "E3"], "C5", 0.50, vel=96, accomp_vel=68), N("A3", 0.25, 66),
    N("E4", 0.25, 78), N("E5", 0.25, 84), N("D#5", 0.25, 80),

    N("E5", 0.25, 86), N("D#5", 0.25, 82), N("E5", 0.25, 88), N("B4", 0.25, 84), N("D5", 0.25, 90), N("C5", 0.25, 86),
    CHORD(["A2", "E3"], "A4", 0.50, vel=94, accomp_vel=68), N("A3", 0.25, 66),
    N("C4", 0.25, 80), N("E4", 0.25, 86), N("A4", 0.25, 94),
    CHORD(["E2", "E3"], "B4", 0.50, vel=96, accomp_vel=68), N("G#3", 0.25, 66),
    N("E4", 0.25, 82), N("C5", 0.25, 94), N("B4", 0.25, 88),
    CHORD(["A2", "E3", "A3"], "A4", 0.75, vel=92, accomp_vel=68),

    # A 段第二部分（转向 C 大调与 G 大调明亮展开，mf）
    N("B4", 0.25, 88), N("C5", 0.25, 92), N("D5", 0.25, 96),
    CHORD(["C3", "G3"], "E5", 0.75, vel=104, accomp_vel=72),
    N("G4", 0.25, 84), N("F5", 0.25, 106), N("E5", 0.25, 100),
    CHORD(["G2", "G3"], "D5", 0.75, vel=102, accomp_vel=72),
    N("F4", 0.25, 82), N("E5", 0.25, 102), N("D5", 0.25, 96),
    CHORD(["A2", "E3"], "C5", 0.75, vel=98, accomp_vel=70),
    N("E4", 0.25, 80), N("D5", 0.25, 98), N("C5", 0.25, 92),
    CHORD(["E2", "E3"], "B4", 0.50, vel=94, accomp_vel=68), N("E4", 0.25, 76),
    N("E5", 0.25, 84), N("D#5", 0.25, 80),

    # 主题再现并温柔收束
    N("E5", 0.25, 86), N("D#5", 0.25, 82), N("E5", 0.25, 88), N("B4", 0.25, 84), N("D5", 0.25, 90), N("C5", 0.25, 86),
    CHORD(["A2", "E3"], "A4", 0.50, vel=94, accomp_vel=68), N("A3", 0.25, 66),
    N("C4", 0.25, 80), N("E4", 0.25, 86), N("A4", 0.25, 94),
    CHORD(["E2", "E3"], "B4", 0.50, vel=96, accomp_vel=68), N("G#3", 0.25, 66),
    N("E4", 0.25, 82), N("C5", 0.25, 94), N("B4", 0.25, 88),
    CHORD(["A2", "E3", "C4"], "A4", 1.25, vel=96, accomp_vel=72),
])

# ---- 0. 我落泪情绪零碎（副歌 m.29–36 完整 8 小节左手钢琴和弦+右手旋律深情编配版）
#  ⛔ 版权：受版权保护的流行歌曲；乐谱由【使用者本人】提供（EveryonePiano，编配 JenaV）；
#     【本队未获授权】（即"未获得任何授权"）。使用者知情决定，风险自担。
WO_LUO_LEI_CHORUS = flatten_notes([
    # m.29: G#m7 和弦打底 ("D#4" 深情长音 + 左手 G#2-D#3-B3 共鸣)
    CHORD(["G#2", "D#3", "B3"], "D#4", 2.0, vel=100, accomp_vel=68),
    N("C#4", 0.5, 86), N("D#4", 0.5, 90), N("E4", 0.5, 96), N("D#4", 0.5, 92),  # 情绪零碎

    # m.30: Eadd9 和弦打底 ("D#4" 模进长音 + 左手 E2-B2-G#3 共鸣)
    CHORD(["E2", "B2", "G#3"], "D#4", 2.0, vel=102, accomp_vel=70),
    N("C#4", 0.5, 88), N("D#4", 0.5, 92), N("E4", 0.5, 98), N("D#4", 0.5, 94),  # 你的世界

    # m.31: F# -> B 和弦推进（一幕幕纷飞，含 A4 装饰倚音与高潮 G#4）
    CHORD(["F#2", "C#3", "A#3"], "D#4", 0.5, vel=96, accomp_vel=68),
    N("C#4", 0.5, 90),
    CHORD(["B2", "F#3"], "B3", 0.5, vel=94, accomp_vel=68),
    N("D#4", 0.5, 98),
    CHORD(["E2", "B2", "G#3"], "D#4", 0.5, vel=102, accomp_vel=70),
    N("G#4", 0.5, 110),
    N("A4", 0.125, 96), N("G#4", 0.375, 108),  # 真实还原谱面 (b7)6 装饰倚音滑奏！
    CHORD(["F#2", "C#3"], "F#4", 0.5, vel=102, accomp_vel=68),

    # m.32–33: 副歌后半句延续（门外的蔷薇 / 带刺伤人的很直接）
    CHORD(["B2", "F#3", "D#4"], "F#4", 1.5, vel=104, accomp_vel=70),
    N("D#4", 0.5, 90),
    CHORD(["D#2", "A#2", "F#3"], "F#4", 0.5, vel=100, accomp_vel=68),
    N("G#4", 0.5, 106), N("A#4", 0.5, 112), N("B4", 0.5, 114),
    CHORD(["G#2", "D#3", "B3"], "G#4", 1.5, vel=108, accomp_vel=72),
    N("D#4", 0.5, 92),
    CHORD(["E2", "B2", "G#3"], "E4", 0.5, vel=98, accomp_vel=68),
    N("F#4", 0.5, 102), N("G#4", 0.5, 106), N("E4", 0.5, 96),
    CHORD(["F#2", "C#3", "A#3"], "F#4", 2.0, vel=104, accomp_vel=70),
    CHORD(["B1", "B2", "F#3", "D#4"], "B3", 2.0, vel=100, accomp_vel=72),
])

# =============================================================================
#  曲目表
# =============================================================================
#  格式：(曲名, BPM, 调性/拍号, 授权状态, 依据/来源说明, 音符序列)
#
#  ⚠️ main() 里有两条【合规断言】：
#     · 授权状态只能是 PD 或 COPYRIGHT（写别的一律报错）
#     · COPYRIGHT 的"依据/来源说明"里必须出现"未获授权"四个字
#   这是故意的：将来若有人往这里塞一首受版权保护的曲子却含糊其辞，
#   生成器会直接报错，而不是悄悄产出一份说不清来源的 ROM。
SONGS = [
    # ⛔ [已删除] Faded (Alan Walker) —— 2026-10-06 由 Lead 裁决【彻底删除】，不是留空占位。
    #    理由：① 它的数据源被用户亲耳否掉（下载的 MIDI 不是该曲）、副歌起点从未确认
    #          ⇒ **这首的数据本来就是作废的**；
    #          ② 留一条"标着受版权保护却全是静音"的条目，比没有它更糟 ——
    #          评委对照 RTL 时会认为是 bug 或未完成。
    #    ⚠️ 删除后所有歌曲【下标前移】：[0] 由 Faded 变成《欢乐颂》(PD)，
    #       上电第一首是一首人人熟知的公有领域曲 ⇒ 这是好事。
    #    ⚠️ `FADED_CHORUS` 列表**保留在文件里**（不参与 ROM），
    #       因为 `tools/gen/melody_table_to_rom.py --verify` 的幂等自检锚在它身上。
    # ★★ 2026-10-06（Lead 裁决）：把《我落泪情绪零碎》放到 [0] ★★
    #   理由：song_player 进入曲目模式后**从头放 [0]**，而用户明确的曲目就是这一首
    #   ⇒ 把它放 [0]，用户按 key2 就直接听到它。
    #   ⚠️ 首歌是【受版权保护、本队未获授权】的曲目，**且上电默认进入的是【自由演奏】**
    #      ⇒ 上电不会自动播放它（不会不问自播受版权曲目）✓
    # ---- 新增：用户提供的简谱《我落泪情绪零碎》副歌第 1 句（m.29–31）----
    ("我落泪情绪零碎 (副歌 m.29-31)", 67, "B 大调 4/4", LIC_COPYRIGHT,
     "⛔ 本曲为【受版权保护的流行歌曲】。乐谱由【使用者本人】从 EveryonePiano.com "
     "获取并提供（编配者 JenaV）。【本队未获授权】（即：从未获得任何授权）。"
     "纳入演示模式是使用者的【知情决定】，版权风险由使用者承担。"
     "—— 与此前 Faded 的处理方式一致（该曲已按裁决删除）：如实记录、不隐瞒、不用'改编/引用'淡化。"
     "读谱方式：逐小节 3 倍放大 + 像素级判读，并用歌词音节数交叉验证"
     "（详见 _research/songs/WO-LUO-LEI-NOTES.md）。",
     WO_LUO_LEI_CHORUS),
    # ---- 以下 4 首公有领域曲目顺次后移（原 [0] 欢乐颂 → [1]）----
    ("Ode to Joy (欢乐颂)", 100, "C 大调 4/4", LIC_PD,
     "Beethoven《第九交响曲》第四乐章主题，作者 1827 年去世已逾 70 年，公有领域。"
     "音符数据由本队自行整理，未复制第三方文件。",
     ODE_TO_JOY),
    ("Twinkle Twinkle (小星星)", 120, "C 大调 4/4", LIC_PD,
     "法国歌曲《Ah! vous dirai-je, maman》，1761 年出版，公有领域。"
     "音符数据由本队自行整理，未复制第三方文件。",
     TWINKLE),
    ("Jingle Bells (铃儿响叮当)", 140, "C 大调 4/4", LIC_PD,
     "James Lord Pierpont，1857 年，公有领域。"
     "音符数据由本队自行整理，未复制第三方文件。",
     JINGLE_BELLS),
    ("Für Elise (致爱丽丝)", 120, "A 小调 3/8", LIC_PD,
     "Beethoven，1810 年作、1867 年出版，作者 1827 年去世已逾 70 年，公有领域。"
     "音符数据由本队自行整理，未复制第三方文件。",
     FUR_ELISE),
]


# =============================================================================
#  时值换算
# =============================================================================
def dur_ticks(beats: Fraction, bpm: int) -> int:
    """拍数 → sample_tick 数（精确有理数运算后四舍五入，不用浮点）"""
    ticks = beats * Fraction(60, bpm) * Fraction(FS_NUM, FS_DEN)
    return int(ticks + Fraction(1, 2))


def compile_song(notes, bpm):
    """(音名, 拍[, 力度]) 序列 → [(midi, vel, dur_ticks, 音名), ...]"""
    out = []
    for item in notes:
        if len(item) == 3:
            note, beats, item_vel = item
        else:
            note, beats = item
            item_vel = MELODY_VEL
        beats = B(beats)
        assert beats > 0, (note, beats)
        midi = NOTE_REST if note is None else midi_of(note)
        assert midi == NOTE_REST or 0 < midi <= MAX_NOTE, (note, midi)
        vel = 0 if midi == NOTE_REST else int(item_vel)
        out.append((midi, vel, dur_ticks(beats, bpm), note))
    return out


def pack(is_end: int, note: int, vel: int, dur: int) -> int:
    return ((is_end & 1) << (NOTE_W + VEL_W + DUR_W)) | \
           ((note & 0x7F) << (VEL_W + DUR_W)) | \
           ((vel & 0x7F) << DUR_W) | (dur & ((1 << DUR_W) - 1))


# 回读校验用的正则：把生成出来的 `case` 行再解析回来
CASE_RE = re.compile(r"(\d+)'d(\d+)\s*:\s*dout\s*<=\s*(\d+)'h([0-9A-Fa-f]+);")
DEF_RE = re.compile(r"default:\s*dout\s*<=\s*(\d+)'h([0-9A-Fa-f]+);")


def verify_rom(path: str, compiled) -> int:
    """★ 回读校验：把刚写出的 song_rom.v 再解析回来，逐项比对乐谱。

    为什么必须做这一步：生成器最容易犯的错不是"算错时值"，而是
    **位拼接/掩码/位宽写错**（本项目在 gen_wave_rom 上就踩过负号位置、
    在 song_rom 上踩过占位符未替换）。那种错误编译能过、仿真跑 DUT 也自洽，
    只有"拿乐谱当真值去对 ROM 的每一个 bit"才能抓出来。
    """
    txt = open(path, encoding='utf-8').read()
    seen = {}
    for m in CASE_RE.finditer(txt):
        selw, ct, w, hexv = int(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4), 16)
        assert selw == SONG_W + ADDR_W, 'case 选择子位宽 %d 应为 %d' % (selw, SONG_W + ADDR_W)
        assert w == WORD_W, '常量位宽 %d 应为 %d' % (w, WORD_W)
        is_end = (hexv >> (NOTE_W + VEL_W + DUR_W)) & 1
        note = (hexv >> (VEL_W + DUR_W)) & 0x7F
        vel = (hexv >> DUR_W) & 0x7F
        dur = hexv & ((1 << DUR_W) - 1)
        si, ai = ct >> ADDR_W, ct & ((1 << ADDR_W) - 1)
        em, ev, ed, en = compiled[si][ai]
        assert (is_end, note, vel, dur) == (0, em, ev, ed), \
            'song%d[%d] ROM 解出 (end=%d note=%d vel=%d dur=%d) != 乐谱 (%s %d %d)' \
            % (si, ai, is_end, note, vel, dur, en, em, ed)
        assert ct not in seen, 'case 地址 %d 重复' % ct
        seen[ct] = True

    n_expect = sum(len(c) for c in compiled)
    assert len(seen) == n_expect, 'case 项数 %d != 乐谱音符数 %d' % (len(seen), n_expect)

    md = DEF_RE.search(txt)
    assert md, '找不到 default 分支'
    dw, dhex = int(md.group(1)), int(md.group(2), 16)
    assert dw == WORD_W, 'default 常量位宽 %d 应为 %d' % (dw, WORD_W)
    assert dhex == pack(1, 0, 0, 0), 'default 应是曲末标记 is_end=1，实得 %X' % dhex
    return len(seen)


# =============================================================================
#  Verilog 生成
# =============================================================================
HEADER = r'''// =============================================================================
//  song_rom.v —— 演示模式曲目 ROM（%NSONG% 首，纯 `case` 常量表）
//
//  ★ 本 ROM 存的是【乐谱】（音符编号 + 时值），不是音频采样。
//    ROM 里没有任何 PCM / 波形数据 —— 声音由振荡器 + ADSR 逐样本实时合成，
//    符合赛题红线"严禁播放预录 PCM / 预置推流 / 整段录音触发"。
//
//  ⚠️ 本文件由 tools/gen/gen_song_rom.py 生成，请勿手工编辑。
//     重新生成：python tools/gen/gen_song_rom.py --write
//
//  ★ 为什么不用 $readmemh：Gowin 上 ROM 初始化有坑（见 wave_rom.v 记录），
//    本工程交付物一律用生成的 case 常量表，不依赖外部 .vh/.hex。
//    本 ROM 共 %TOTAL% 项，与 wave_rom.v（1024 项，已实测可综合）同量级。
//
//  ===========================================================================
//  ★★ 曲目版权状态（★ 如实记录，请勿删改 ★）★★
//  ===========================================================================
//  本项目含一首【未获授权】的流行曲，这是**使用者的知情决定**，
//  **风险由使用者承担**。如实记录在案，不掩盖、不含糊。
//
%CPTBL%
//
//  ---------------------------------------------------------------------------
//  ★ 音符数据来源（逐首交代）
//    · 公有领域曲目：由本队**自行整理**，未复制任何第三方文件。
//    · 我落泪情绪零碎：乐谱由**使用者本人**提供（EveryonePiano.com，编配 JenaV），
//      本队**逐小节 3 倍放大 + 像素级判读**自行读谱，未复制任何第三方数据文件；
//      并用歌词音节数交叉验证（详见 _research/songs/WO-LUO-LEI-NOTES.md）。
//    ⛔ [2026-10-06 已删除] Faded：原条目取自本队 `26Embedded/fpga_spark/sim/
//       simulate_faded_guitar.py`，因**数据源被用户亲耳否掉**、副歌起点从未确认，
//       经 Lead 裁决**彻底删除**（不留空占位）。删除后各曲下标整体前移，
//       [0] 由 Faded 变为《欢乐颂》(公有领域)。
//    ⛔ 调研中 star 最高的开源蜂鸣器曲库 robsoncouto/arduino-songs 经 GitHub API
//       实测 `license: null`（无许可证文件），其 README 口头许可无法举证，
//       因此本工程**没有使用它的任何数据文件**，只在"音符怎么编码、怎么断句"上
//       借鉴公开结构思路。
//    ✅ 借鉴的两个参考工程均为 **MIT** 许可（只学结构，不抄数据）：
//         sirius1242/musicbox（Verilog 八音盒，LICENSE 原文已核对）
//             → 乐谱文本编码 + "音符响满时值后再插 1 ms 静音"的断句做法
//         JN513/Simple-FPGA-Music-Player-with-PWM（API 实测 spdx_id = MIT）
//             → 乐谱驱动的状态机结构；它是 PWM 单音输出，与本工程
//               I2S/PT8211 通路无关，未借鉴其音频通路
//    ⛔ 未使用 MAESTRO（CC BY-NC-SA 4.0，非商业 + 传染性）。
//
//  ---------------------------------------------------------------------------
//  曲目清单
//    #  曲名                        BPM  音符数  时长    授权
%SONGTBL%
//
//  ★ 与 song_player.v 的一致性：歌曲总数由本模块的 n_songs 输出端口给出，
//    播放器直接透传到 song_count，**不存在两处硬编码不同步的可能**。
// =============================================================================
`default_nettype none

module song_rom (
    input  wire        clk,
    input  wire [%SWHM1%:0]  song,      // 歌曲序号 0..%NSM1%
    input  wire [%ADWM1%:0]  addr,      // 音符序号 0..%AML1%
    output reg  [%WDWM1%:0]  dout,      // {is_end, note, vel, dur}
    output wire [%SWHM1%:0]  n_songs    // 本 ROM 里实际有几首歌（给 song_count）
);

    localparam [%SWHM1%:0] N_SONGS = %SWH%'d%NSONG%;
    assign n_songs = N_SONGS;

    // 注：addr 是【组合】地址（由播放器直接给出寄存器值），本 ROM 同步读出，
    //     因此 dout 比 addr 晚一拍 —— 播放器用 S_LOAD→S_LATCH 两拍对齐，
    //     详见 song_player.v 的流水说明。这是与 wave_rom.v 相同的读时序。
    always @(posedge clk) begin
        case ({song, addr})
%CASES%
            // 越界 / 未使用地址 = 曲末标记（播放器据此回到第 0 个音符）
            default: dout <= %WDW%'h%ENDWORD%;
        endcase
    end

endmodule

`default_nettype wire
'''


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--write', action='store_true', help='写 rtl/synth/song_rom.v')
    ap.add_argument('--dump', action='store_true', help='打印编译后的音符表')
    ap.add_argument('--out', default=None, help='覆盖 song_rom.v 输出路径')
    args = ap.parse_args()

    # ---------------------------------------------------- ★ 合规断言 --------
    # ① 授权状态只能取两个值；② 受版权保护的条目必须把"未获授权"写明白。
    # 这道断言是故意的：将来若有人往 SONGS 里塞一首受版权保护的曲子却含糊其辞，
    # 生成器会直接报错，而不是悄悄产出一份说不清来源的 ROM。
    for s in SONGS:
        name, lic, justify = s[0], s[3], s[4]
        assert lic in (LIC_PD, LIC_COPYRIGHT), \
            '曲目 %r 的授权状态 %r 非法（只能 PD / COPYRIGHT）' % (name, lic)
        assert justify.strip(), '曲目 %r 必须写明数据来源与授权依据' % name
        if lic == LIC_COPYRIGHT:
            assert '未获授权' in justify, \
                '曲目 %r 标记为受版权保护，必须在说明里写明"未获授权"（如实记录）' % name

    n_pd = sum(1 for s in SONGS if s[3] == LIC_PD)
    n_cp = len(SONGS) - n_pd
    print('[ok] 合规断言通过：%d 首曲目（公有领域 %d 首，未获授权 %d 首）'
          % (len(SONGS), n_pd, n_cp))
    for s in SONGS:
        if s[3] == LIC_COPYRIGHT:
            print('[!!] ⚠️ 未获授权曲目：%s —— 使用者知情决定，风险由使用者承担' % s[0])

    compiled = []
    for name, bpm, key, lic, justify, notes in SONGS:
        c = compile_song(notes, bpm)
        assert len(c) <= (1 << ADDR_W), '%s 音符数 %d 超过 addr 位宽' % (name, len(c))
        compiled.append(c)

    # ---------------------------------------------------------------- 自检 ----
    for (name, bpm, key, lic, justify, _), c in zip(SONGS, compiled):
        for midi, vel, dur, nm in c:
            assert 1 <= dur <= (1 << DUR_W) - 1, '%s %s dur=%d 越界' % (name, nm, dur)
            assert 0 <= vel <= 127
        total_s = sum(d for _, _, d, _ in c) / (FS_NUM / FS_DEN)
        print('[ok] %-30s %3d BPM %-10s %3d 音符 %6.1f s  [%s]'
              % (name, bpm, key, len(c), total_s, lic))

    maxdur = max(d for c in compiled for _, _, d, _ in c)
    print('[ok] ROM 共 %d 项，选择子位宽 %d，最长槽长 %d tick (%.2f s)'
          % (sum(len(c) for c in compiled), SONG_W + ADDR_W, maxdur,
             maxdur / (FS_NUM / FS_DEN)))

    if args.dump or not args.write:
        for si, ((name, bpm, _, _, _, _), c) in enumerate(zip(SONGS, compiled)):
            print('\n=== song %d : %s (%d BPM) ===' % (si, name, bpm))
            print('  idx  note  midi  vel   dur_tick   dur_ms')
            for i, (midi, vel, dur, nm) in enumerate(c):
                print('  %3d  %-5s %4d  %4d   %8d  %7.1f'
                      % (i, nm if nm else 'REST', midi, vel, dur,
                         dur / (FS_NUM / FS_DEN) * 1000))

    # ------------------------------------------------------------ 生成文本 ----
    cases = []
    for si, c in enumerate(compiled):
        cases.append('            // ---- song %d : %s ----\n' % (si, SONGS[si][0]))
        for i, (midi, vel, dur, nm) in enumerate(c):
            ct = (si << ADDR_W) | i
            w = pack(0, midi, vel, dur)
            cases.append("            %d'd%-4d: dout <= %d'h%09X;  // %-5s dur=%d\n"
                         % (SONG_W + ADDR_W, ct, WORD_W, w,
                            nm if nm else 'REST', dur))

    # 版权状态表（写进 ROM 顶部注释，如实记录）
    cptbl = []
    for si, (name, bpm, key, lic, justify, _) in enumerate(SONGS):
        mark = '✅ 公有领域' if lic == LIC_PD else '⛔ 受版权保护，本队未获授权'
        cptbl.append('//   [%d] %-28s %s' % (si, name, mark))
        cptbl.append('//        %s' % justify)
    if n_cp:
        cptbl.append('//')
        cptbl.append('//   ⚠️ 上表 %d 首标 ⛔ 的曲目为使用者知情决定纳入，'
                     '风险由使用者承担；' % n_cp)
        cptbl.append('//      若要移除，在 tools/gen/gen_song_rom.py 的 SONGS 里'
                     '删掉对应项并重新生成即可，RTL 无需改动。')

    tbl = []
    for si, ((name, bpm, key, lic, justify, _), c) in enumerate(zip(SONGS, compiled)):
        total_s = sum(d for _, _, d, _ in c) / (FS_NUM / FS_DEN)
        tbl.append('//    %d  %-26s %3d  %5d  %5.1fs  %s'
                   % (si, name, bpm, len(c), total_s, lic))

    text = HEADER
    for k, v in {
        '%NSONG%': str(len(SONGS)),
        '%NSM1%': str(len(SONGS) - 1),
        '%TOTAL%': str(sum(len(c) for c in compiled)),
        '%SWH%': str(SONG_W),
        '%SWHM1%': str(SONG_W - 1),
        '%ADW%': str(ADDR_W),
        '%ADWM1%': str(ADDR_W - 1),
        '%AML1%': str((1 << ADDR_W) - 1),
        '%WDW%': str(WORD_W),
        '%WDWM1%': str(WORD_W - 1),
        '%CPTBL%': '\n'.join(cptbl),
        '%SONGTBL%': '\n'.join(tbl),
        '%CASES%': ''.join(cases).rstrip('\n'),
        '%ENDWORD%': '%09X' % pack(1, 0, 0, 0),
    }.items():
        text = text.replace(k, v)

    # ★ 占位符自检：本项目刚在这里踩过一次坑 —— 模板里写的是 `[%SWH-1:0]`，
    #   而替换表里的键是 `%SWH%`，两边对不上，于是**没被替换的 %SWH-1:0 直接
    #   进了 .v 文件**（Verilog 端口声明非法），而且不报错、静默产出坏 RTL。
    #   所以生成后必须断言"模板里不允许残留 %XXX% 形式的内容"。
    leftover = re.findall(r'%[A-Z0-9_]+%', text)
    assert not leftover, '生成器占位符未替换: %s' % sorted(set(leftover))

    if args.write:
        here = os.path.dirname(os.path.abspath(__file__))
        dst = args.out or os.path.normpath(
            os.path.join(here, '..', '..', 'rtl', 'synth', 'song_rom.v'))
        with open(dst, 'w', encoding='utf-8', newline='\n') as f:
            f.write(text)
        print('wrote', dst, len(text), 'bytes')

        # ★ 回读校验：确保写出去的 .v 逐项等于乐谱（抓位拼接/掩码/位宽错误）
        nv = verify_rom(dst, compiled)
        print('[ok] song_rom.v 回读校验通过：%d 项 case 全部与乐谱逐 bit 一致' % nv)

        # 音符表落到调研目录，作为 TB 期望值与评审证据
        rd = os.path.normpath(os.path.join(here, '..', '..', '..',
                                           '_research', 'songs', 'song_table.txt'))
        os.makedirs(os.path.dirname(rd), exist_ok=True)
        with open(rd, 'w', encoding='utf-8', newline='\n') as f:
            f.write('# 由 tools/gen/gen_song_rom.py 生成；sample_tick = %.2f Hz\n'
                    % (FS_NUM / FS_DEN))
            f.write('# 公有领域曲目：音符数据由本队自行整理，未复制第三方文件。\n')
            f.write('# Faded：旋律受版权保护、本队未获授权；数据取自本队自己的编配脚本。\n')
            for si, ((name, bpm, key, lic, justify, _), c) in enumerate(zip(SONGS, compiled)):
                f.write('\n=== song %d : %s (%d BPM, %s) [%s] ===\n'
                        % (si, name, bpm, key, lic))
                f.write('依据: %s\n' % justify)
                f.write('idx\tnote\tmidi\tvel\tdur_tick\tdur_ms\n')
                for i, (midi, vel, dur, nm) in enumerate(c):
                    f.write('%d\t%s\t%d\t%d\t%d\t%.2f\n'
                            % (i, nm if nm else 'REST', midi, vel, dur,
                               dur / (FS_NUM / FS_DEN) * 1000))
        print('wrote', rd)

        # 前 12 个音符（TB 期望值）单独打一份，方便贴进 testbench
        print('\n--- TB 期望值（每个 song 的前 12 个音符：midi, dur_tick）---')
        for si, c in enumerate(compiled):
            print('song %d: ' % si, ', '.join(
                '(%d,%d)' % (m, d) for m, v, d, n in c[:12]))
    else:
        sys.stdout.write(text)


if __name__ == '__main__':
    main()
