#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
melody_table_to_rom.py —— 把「旋律表」机械转换成 gen_song_rom.py 的音符数据
===============================================================================
为什么要这个脚本（**这是本项目的教训，不是洁癖**）
-------------------------------------------------------------------------------
2026-10-05：演示模式里《Faded》的旋律被用户听出不对。复核发现旧数据是从
队里那份**吉他指弹编配**里提取的 —— 那一层其实是**分解和弦伴奏**（主歌 92%
的音都是当小节的和弦音），根本不是人声旋律。改用一份"经三重印证"的旋律表后
用户又确认**那首根本不是《Faded》**。

两轮下来结论只有一条是稳的：
    **源数据对不对，我这边管不了；但"从源数据到 ROM"这一段必须做到零手抄。**
所以本脚本把这一段全自动化，并自带两道护栏：
    ① 机器生成，不给人手打音符的机会；
    ② 两条判据（级进率 / 重合率）自动算，用来在**上板之前**就分辨
       "这是一条旋律"还是"这是分解和弦"。

[!] 注意判据的**证据强度**（AGENTS.md §8.1 的延伸）：
    这两条只能证明"拿到的是一条**单声部旋律线**"，
    **不能证明"它是哪一首歌"**。识别一首歌只有一条判据：**旋律的音程走向**
    （逐音比对）。宏观属性（音阶 7 音、和弦进行 i-VI-III-VII、BPM）**全都不能识别一首歌**
    —— 这是 `liaison` 那份"三重独立印证"翻车的根因：结论强度超过了证据。

用法
-------------------------------------------------------------------------------
    # 1) 只看结果与判据，不改任何文件
    python tools/gen/melody_table_to_rom.py --in <旋律表> --shift 5 --bpm 120

    # 2) 原地写入 gen_song_rom.py 的机器生成区（零手抄）
    python tools/gen/melody_table_to_rom.py --in <旋律表> --shift 5 --bpm 120 --write

    # 3) 幂等自检：验证 gen_song_rom.py 现有数据确实等于本脚本的产物
    python tools/gen/melody_table_to_rom.py --in <旋律表> --shift 5 --bpm 120 --verify

输入格式（制表符分隔，`#` 开头为注释；与 liaison 的 MELODY-*.txt 一致）
-------------------------------------------------------------------------------
    idx  note  midi  vel  start_s  dur_ms  dur_tick
    0    D5    74    118  37.000   538.54  52592

★ 时值口径：用【相邻起拍之差】而不是 dur_ms（note-off 时长）。
  理由：播放器是**单声部顺序播发**，用 note-off 时长（它略长于起拍间隔，
  例如 538.54 ms > 间隔 500 ms）会让误差**逐个累积**，整段节奏越走越偏。
  最后一个音没有"下一个起拍"，用它自身的 dur_ms。
"""

import argparse
import re
import sys
from fractions import Fraction
from pathlib import Path

# 采样率（与工程一致：50 MHz / 512 = 97656.25 Hz）
FS = Fraction(9765625, 100)
NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

BEGIN_MARK = "# ==== FADED_CHORUS-BEGIN ===="
END_MARK = "# ==== FADED_CHORUS-END ===="


def midi_to_name(m: int) -> str:
    """MIDI 号 → 音名（60 = C4，即科学音高记号）。"""
    return "%s%d" % (NOTE_NAMES[m % 12], m // 12 - 1)


def read_table(path: Path, schema: str = "auto"):
    """读旋律表。返回 list[dict]。schema: auto / liaison / piano（见下方列说明）。"""
    rows = []
    seen_schema = set()
    for ln, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        f = s.split("\t")
        if len(f) < 7:
            f = s.split()
        if len(f) < 7:
            raise SystemExit("[err] %s:%d 字段不足 7 个: %r" % (path.name, ln, line))
        # ---- 两种表头自动识别（本项目出现过两种，别再让人手工换算列号）----
        #   liaison: idx note midi vel   start_s dur_ms dur_tick     （第 4 列是整数力度）
        #   piano  : idx note midi freq  onset_s dur_ms conf         （第 4 列是浮点频率）
        #   判据：第 4 列含小数点 => freq 表。也可用 --schema 强制。
        sc = schema
        if sc == "auto":
            sc = "piano" if "." in f[3] else "liaison"
        try:
            if sc == "liaison":
                rec = dict(idx=int(f[0]), note=f[1].strip(), midi=int(f[2]), vel=int(f[3]),
                           start=Fraction(f[4]).limit_denominator(10 ** 6),
                           dur_ms=Fraction(f[5]).limit_denominator(10 ** 6),
                           dur_tick=int(f[6]), conf=None)
            else:                                   # piano（无力度/无 dur_tick，多一个置信度）
                rec = dict(idx=int(f[0]), note=f[1].strip(), midi=int(f[2]), vel=None,
                           freq=float(f[3]),
                           start=Fraction(f[4]).limit_denominator(10 ** 6),
                           dur_ms=Fraction(f[5]).limit_denominator(10 ** 6),
                           dur_tick=None, conf=float(f[6]))
            rows.append(rec)
            seen_schema.add(sc)
        except ValueError as e:
            raise SystemExit("[err] %s:%d 解析失败（识别为 %s 表）: %s" % (path.name, ln, sc, e))
    if not rows:
        raise SystemExit("[err] 表是空的: %s" % path)
    if len(seen_schema) > 1:
        raise SystemExit("[err] 同一份表里混了两种列格式，拒绝解析")
    # 起拍必须单调递增，否则"起拍差"没意义 —— 早失败，别让它悄悄产出错数据
    for i in range(len(rows) - 1):
        if rows[i + 1]["start"] <= rows[i]["start"]:
            raise SystemExit("[err] 第 %d/%d 个音起拍没有递增，表可能没排序"
                             % (i + 1, i + 2))
    return rows


def build_notes(rows, shift: int, bpm: int):
    """
    返回 [(音名, 拍数Fraction, 源midi, 目标midi, tick), ...]
    时值 = 相邻起拍之差；最后一音用自身 dur_ms。
    """
    beats_per_sec = Fraction(bpm, 60)
    out = []
    for i, r in enumerate(rows):
        if i + 1 < len(rows):
            dur_s = rows[i + 1]["start"] - r["start"]
        else:
            dur_s = r["dur_ms"] / 1000
        beats = dur_s * beats_per_sec
        tgt = r["midi"] + shift
        ticks = int(round(float(beats * Fraction(60, bpm) * FS)))
        out.append((midi_to_name(tgt), beats, r["midi"], tgt, ticks))
    return out


def fmt_beats(b: Fraction) -> str:
    if b.denominator == 1:
        return str(b.numerator)
    # 用小数表示，保留 5 位（不够就多留），并去掉多余的 0
    s = ("%.5f" % float(b)).rstrip("0").rstrip(".")
    return s or "0"


def interval_stats(mid):
    """
    把相邻音程拆成三类 —— 这个拆分是【踩坑之后】才做的：
      · 真级进 step  : |d| in {1,2}   —— 旋律特征
      · 同音重复 rep : d == 0         —— 单音反复（伴奏持续音 / 跟踪抖动 / 真的反复音）
      · 跳进  leap   : |d| >= 3
    [!] 早期版本把 |d|<=2 一律算"级进"，**把同音重复也当成级进** ——
       于是"连续 15 个 A#5"这种明显不是旋律的东西，级进率被算成 77.8%。
       => 只报一个笼统的"级进率"会骗人；必须把重复单列。
    """
    d = [mid[i + 1] - mid[i] for i in range(len(mid) - 1)]
    n = len(d) or 1
    step = sum(1 for x in d if 1 <= abs(x) <= 2)
    rep = sum(1 for x in d if x == 0)
    return d, 100.0 * step / n, 100.0 * rep / n


def max_same_run(mid):
    """最长"连续同一个音高"的长度（连续 15 个 A#5 就是 15）。"""
    best = cur = 1 if mid else 0
    for i in range(1, len(mid)):
        cur = cur + 1 if mid[i] == mid[i - 1] else 1
        best = max(best, cur)
    return best


def metrics(rows, notes):
    """两条判据：级进率（排除同音重复）/ 重合率。返回可打印的文本行列表。"""
    lines = []
    mid = [r["midi"] for r in rows]
    d, step_pct, rep_pct = interval_stats(mid)
    lines.append("真级进率 = %.1f%%（|音程| 为 1~2 半音，**已排除同音重复**）"
                 % step_pct)
    lines.append("同音重复率 = %.1f%%（音程 = 0；单音反复/伴奏持续音会很高）" % rep_pct)
    lines.append("最长连续同音 = %d 个（连续 15 个 A#5 这种一定不是旋律）" % max_same_run(mid))
    lines.append("音程序 = " + " ".join("%+d" % x for x in d))
    # ---- 重合率：按 dur_ms（note-off）算"同时响 >1 音"的时间占比 ----
    cov = [0] * 20000                      # 1 ms 分辨率，覆盖 20 s
    for r in rows:
        a = int(float(r["start"] - rows[0]["start"]) * 1000)
        b = a + int(float(r["dur_ms"]))
        for k in range(max(0, a), min(len(cov), b)):
            cov[k] += 1
    span = [c for c in cov if c > 0]
    over = sum(1 for c in span if c > 1)
    if span:
        lines.append("重合率 = %d/%d = %.1f%%   （旋律应有：≈0；参考 旋律轨0.4%% / 分解和弦轨46.3%%）"
                     % (over, len(span), 100.0 * over / len(span)))
    # ---- 附加：单调性/音域 ----
    tgt = [n[3] for n in notes]
    lines.append("音域 = %s .. %s（移调 %+d 后）"
                 % (midi_to_name(min(tgt)), midi_to_name(max(tgt)), 0))
    lines.append("总长 = %.2f s，音符数 = %d"
                 % (float(rows[-1]["start"] - rows[0]["start"] + rows[-1]["dur_ms"] / 1000),
                    len(rows)))
    return lines


def render_block(notes, var="FADED_CHORUS", per_line=4):
    """渲染 gen_song_rom.py 里那段可被机器替换的代码块。"""
    body = []
    items = ['("%s", %s)' % (n[0], fmt_beats(n[1])) for n in notes]
    for i in range(0, len(items), per_line):
        body.append("    " + ", ".join(items[i:i + per_line]) + ",")
    return "\n".join([BEGIN_MARK, "%s = [" % var] + body + ["]", END_MARK])


def patch_file(py_path: Path, block: str):
    t = py_path.read_text(encoding="utf-8")
    i0 = t.find(BEGIN_MARK)
    i1 = t.find(END_MARK)
    if i0 < 0 or i1 < 0 or i1 < i0:
        raise SystemExit("[err] 在 %s 里找不到 BEGIN/END 标记对，拒绝改写" % py_path)
    i1 += len(END_MARK)
    new = t[:i0] + block + t[i1:]
    py_path.write_text(new, encoding="utf-8", newline="\n")
    return len(new) - len(t)


def parse_existing(py_path: Path, var="FADED_CHORUS"):
    """把 gen_song_rom.py 里现有的数据块解析成 [(音名, Fraction), ...]，用于幂等自检。"""
    t = py_path.read_text(encoding="utf-8")
    i0 = t.find(BEGIN_MARK)
    i1 = t.find(END_MARK)
    if i0 < 0 or i1 < 0:
        raise SystemExit("[err] 找不到 BEGIN/END 标记，无法自检")
    seg = t[i0:i1]
    out = []
    for m in re.finditer(r'\(\s*"([A-G][#b]?\d)"\s*,\s*([0-9.]+)\s*\)', seg):
        out.append((m.group(1), Fraction(m.group(2)).limit_denominator(10 ** 6)))
    return out


# ============================================================================
#  ★★ 旋律表"体检"（硬门禁）★★
# ----------------------------------------------------------------------------
#  它的来历：本项目《Faded》连续错了两次 ——
#    第 1 次抓成了吉他分解和弦（92% 是和弦音）；
#    第 2 次源数据干脆不是那首歌。
#  两次都是"数据畸形/抓错轨"，但都要等到**上板用人耳听**才发现。
#  体检就是为了把这类错误**在上板之前**拦下来。
#
#  [!][!] 边界（必须一起看，否则会造出第 5 类事故）[!][!]
#      **体检通过 ≠ 歌对了。**
#  体检只能排除「抓错轨 / 数据畸形 / 明显不像单声部旋律」，
#  **不能证明"这是哪一首歌"** —— 识别一首歌的唯一判据是【旋律的音程走向】，
#  而"是不是那首歌"**只有人耳能定**。
#  => 禁止把"体检 PASS"当成"确证"。这是 AGENTS.md §8.1 的同一条纪律：
#     **结论强度不能超过证据强度。**
#
#  ★★ 实测边界（2026-10-05，**拿本项目两次真实事故反测**）★★
#  把两版出过事的 Faded 数据喂进体检，结论必须写在最前面：
#
#    | 事故 | 级进率 | 体检 | 说明 |
#    |---|---|---|---|
#    | 第 1 版：抓成**吉他分解和弦伴奏层**（47 音） | **58.7%** | **放行** | 远高于 40% 阈值 |
#    | 第 2 版：源数据**根本不是那首歌**（29 音） | **60.7%** | **放行** | 阈值再高也救不了 |
#
#  => **本门禁【两次真实事故一次都没拦住】。** 它拦的是"数据畸形"，不是"内容错误"。
#     能拦的只有：音符数异常 / 音域过宽 / 非单声部 / 超长铺底音 / 大量大跳
#     —— 这些是"抓错轨"的**粗**特征，不是"抓错歌"的判据。
#
#  => 由此得出一条比门禁本身更值钱的结论：
#     **没有哪个自动指标能替代人耳。** 级进率若卡到能拒绝 58.7%，
#     就会把大量正常旋律（真旋律常落在 55~65%）一起拒绝 ——
#     **这个指标在"真旋律 60%"与"分解和弦 58.7%"之间【没有可分的阈值】。**
#
#  ★ 真正能识破第 1 版的是【和弦音占比】（那一版主歌 11/12 = 92% 是当小节和弦音，
#    已人工核对），但它需要外部提供**和弦进行**，旋律表里没有。
#    将来若要加，做成 `--chords "Em C G D"` 的可选检查，并注明"需要额外数据"。
#
#  设计原则：**告警 + 拒绝生成，绝不悄悄修正。**
#  数据不对时我们要的是"停下来"，不是"自动补一个看起来像的"。
# ============================================================================

# 阈值集中在这里，**全部经过实测标定，不是拍脑袋**（标定样本见下）
EXAM = dict(
    n_min=8, n_max=200,          # 音符数
    range_max_semitone=24,       # 音域上下限差（半音）＝ 2 个八度
    range_min_semitone=5,        # 音域过窄也可疑（不到 4 度）→ 告警
    # ★ stepwise_min_pct：初版照 Lead 建议用 40% —— **实测证明那是错的**：
    #   本项目【用户已确认正确】的《铃儿响叮当》真级进率只有 **28.6%**
    #   （它的旋律大量是同音反复 E E E E E E E + 分解和弦 E-G-C-D）。
    #   => 40% 会把一首**正确的曲子**拒掉。**任何阈值都不能只看"听起来合理"。**
    #   实测样本（真级进率，已排除同音重复）：
    #       欢乐颂 70.5% / 致爱丽丝 47.2% / 小星星 46.3% / 铃儿响叮当 28.6%
    #       <- 以上 4 首用户确认正确，最低 28.6%
    #       钢琴录音提取 13.2%  <- 要拒绝的
    #   => 取 **20%**：位于 13.2% 与 28.6% 之间，两侧各留 ~1.4x 余量。
    #   [!] 余量并不宽（28.6 / 20 = 1.43），所以这条**只当强提示用也说得过去**；
    #      但它确实是目前唯一能分开"钢琴录音提取"与"已知正确旋律"的指标。
    stepwise_min_pct=20.0,
    overlap_max_pct=5.0,         # 重合率上限
    long_note_reject_s=3.0,      # 单音超此值 → 拒绝（疑似持续铺底音）
    long_note_warn_s=2.0,        # 单音超此值 → 告警
    leap_warn_semitone=5,        # 相邻音程达到此绝对值 → 告警
    # ★ 连续同音：实测 —— 铃儿响叮当 7（已知正确，是流行旋律里的极值）、
    #   钢琴录音提取 9。取拒绝线 9、告警线 6。
    same_run_warn=6,
    same_run_reject=9,
)
# ★★ 标定表（2026-10-05 实测，改阈值前请先看这张表）★★
#   样本                     原级进率  真级进率  同音重复  最长同音   判定
#   欢乐颂   (用户确认正确)     93.4%    70.5%    23.0%      2      应 PASS
#   致爱丽丝 (用户确认正确)     47.2%    47.2%     0.0%      1      应 PASS
#   小星星   (用户确认正确)     90.2%    46.3%    43.9%      2      应 PASS
#   铃儿响叮当(用户确认正确)    85.7%    28.6%    57.1%      7      应 PASS <- 最紧的一个
#   钢琴录音提取(本次要判)      63.2%    13.2%    50.0%      9      应 FAIL
#   ── 以下两个是【已经翻过车】的数据，用来验证门禁的"能力边界" ──
#   第1版 吉他分解和弦层        58.7%    50.0%     8.7%      3      门禁抓不到(已记录)
#   第2版 错歌                 60.7%    57.1%     3.6%      2      门禁抓不到(已记录)
#
#   [!] **同音重复率不能当判据**：铃儿响叮当 57.1% 比钢琴录音提取 50.0% **还高** ——
#      真旋律照样可以大量同音反复。这一条只作展示，不参与拒绝。
#
#   [!] 真正的边界（反复强调）：**门禁只能挡"畸形数据"，挡不住"错歌"。**
#      上表最后两行就是证据：两次真实事故它都放行了。


def exam(rows, notes, thresholds=None):
    """
    体检。返回 (violations, warnings, lines)。
    violations 非空 = **拒绝生成**；warnings 只提示，不阻断。
    """
    th = dict(EXAM)
    if thresholds:
        th.update(thresholds)
    viol, warn, lines = [], [], []

    n = len(rows)
    mid = [r["midi"] for r in rows]
    span = max(mid) - min(mid)
    d = [mid[i + 1] - mid[i] for i in range(len(mid) - 1)]
    dur_s = [float(r["dur_ms"]) / 1000 for r in rows]

    # ---- ① 音符数 ----
    if n < th["n_min"]:
        viol.append("音符数 %d < %d：太短，不成旋律" % (n, th["n_min"]))
    elif n > th["n_max"]:
        viol.append("音符数 %d > %d：过长，可能整曲/多轨混入" % (n, th["n_max"]))
    lines.append("音符数        = %d            [%d .. %d]" % (n, th["n_min"], th["n_max"]))

    # ---- ② 音域 ----
    if span > th["range_max_semitone"]:
        viol.append("音域 %d 半音 > %d：过宽，可能混进伴奏/低音轨" % (span, th["range_max_semitone"]))
    if span < th["range_min_semitone"]:
        warn.append("音域只有 %d 半音（< %d）：过窄，可疑" % (span, th["range_min_semitone"]))
    lines.append("音域          = %d 半音 (%s..%s)  [<= %d]"
                 % (span, midi_to_name(min(mid)), midi_to_name(max(mid)), th["range_max_semitone"]))

    # ---- ③ 真级进率（已排除同音重复）+ 同音重复率 + 最长连续同音 ----
    d, step_pct, rep_pct = interval_stats(mid)
    run = max_same_run(mid)
    if step_pct < th["stepwise_min_pct"]:
        viol.append("真级进率 %.1f%% < %.0f%%：偏低 = 分解和弦/伴奏特征（第 1 次事故就是栽在这）"
                    % (step_pct, th["stepwise_min_pct"]))
    if run >= th["same_run_reject"]:
        viol.append("最长连续同音 %d 个 >= %d：**旋律不可能这样**，"
                    "基本可断定抓到了伴奏持续音/重复音"
                    "（'钢琴录音提取'那次：全曲最长 9 个连续 A#5，高置信度子集里连出 15 个）"
                    % (run, th["same_run_reject"]))
    elif run >= th["same_run_warn"]:
        warn.append("最长连续同音 %d 个（>= %d）：请确认这是真的反复音而不是持续音/跟踪卡住"
                    "（本项目《铃儿响叮当》是连续 7 个 E4，属正常）" % (run, th["same_run_warn"]))
    lines.append("真级进率      = %.1f%%         [>= %.0f%%]（已排除同音重复）"
                 % (step_pct, th["stepwise_min_pct"]))
    lines.append("同音重复率    = %.1f%%         （音程=0 的占比；伴奏持续音会很高）" % rep_pct)
    lines.append("最长连续同音  = %d 个        [告警>=%d / 拒绝>=%d]"
                 % (run, th["same_run_warn"], th["same_run_reject"]))

    # ---- ④ 重合率（按 dur_ms 算"同时响 >1 音"）----
    cov = [0] * 20000
    for r in rows:
        a = int(float(r["start"] - rows[0]["start"]) * 1000)
        b = a + int(float(r["dur_ms"]))
        for k in range(max(0, a), min(len(cov), b)):
            cov[k] += 1
    span_ms = [c for c in cov if c > 0]
    over_pct = 100.0 * sum(1 for c in span_ms if c > 1) / len(span_ms) if span_ms else 0.0
    if over_pct > th["overlap_max_pct"]:
        viol.append("重合率 %.1f%% > %.0f%%：不是单声部旋律（第 1 次事故的分解和弦轨是 46.3%%）"
                    % (over_pct, th["overlap_max_pct"]))
    lines.append("重合率        = %.1f%%         [<= %.0f%%]" % (over_pct, th["overlap_max_pct"]))

    # ---- ⑤ 异常长音 ----
    longest = max(dur_s)
    if longest > th["long_note_reject_s"]:
        viol.append("存在 %.2f s 的长音 > %.1f s：疑似持续铺底音/踏板音"
                    % (longest, th["long_note_reject_s"]))
    elif longest > th["long_note_warn_s"]:
        warn.append("最长音 %.2f s（> %.1f s）：请确认这不是铺底/延音，而是真的旋律长音"
                    % (longest, th["long_note_warn_s"]))
    long_list = ["%s@%.1fs" % (rows[i]["note"], float(rows[i]["start"] - rows[0]["start"]))
                 for i in range(n) if dur_s[i] > th["long_note_warn_s"]]
    lines.append("最长单音      = %.2f s  (拒绝>%.1f / 告警>%.1f)"
                 % (longest, th["long_note_reject_s"], th["long_note_warn_s"]))
    if long_list:
        lines.append("  超过告警线的长音: " + ", ".join(long_list))

    # ---- ⑥ 大跳（告警）----
    leaps = [(i, d[i]) for i in range(len(d)) if abs(d[i]) >= th["leap_warn_semitone"]]
    if leaps:
        warn.append("有 %d 处 >= %d 半音的大跳：%s"
                    % (len(leaps), th["leap_warn_semitone"],
                       ", ".join("#%d(%+d)" % (i, x) for i, x in leaps[:8])))
    lines.append("大跳(>=%d半音) = %d 处" % (th["leap_warn_semitone"], len(leaps)))

    return viol, warn, lines


def print_exam(viol, warn, lines, n_notes=None):
    # ★ 纯 ASCII 的机器可读标记行：控制台是 GBK，中文可能乱码/被转码，
    #   但这一行永远可 grep => 自动化流水线可以只认它判成败（本项目吃过乱码的亏）。
    print("[EXAM] result=%s violations=%d warnings=%d notes=%s"
          % ("FAIL" if viol else "PASS", len(viol), len(warn),
             n_notes if n_notes is not None else "?"))
    for v in viol:
        print("[EXAM-VIOLATION] " + v.encode("ascii", "replace").decode("ascii"))
    for w in warn:
        print("[EXAM-WARNING] " + w.encode("ascii", "replace").decode("ascii"))
    print("\n" + "=" * 74)
    print("★ 旋律表体检（硬门禁：不合格【拒绝生成】，绝不悄悄修正）")
    print("=" * 74)
    for ln in lines:
        print("   " + ln)
    for w in warn:
        print("   [告警] " + w)
    if viol:
        print("\n   [拒绝] 体检不通过，共 %d 条：" % len(viol))
        for v in viol:
            print("        - " + v)
    else:
        print("\n   [通过] 体检未发现畸形（但见下面的边界声明）")
    print("\n   " + "-" * 70)
    print("   [!] 体检通过 /= 歌对了。")
    print("      体检只能排除「抓错轨 / 数据畸形 / 不是单声部旋律」；")
    print("      它**不能**证明'这是哪一首歌' —— 那只有【人耳】能定。")
    print("      禁止把'体检 PASS'当成'确证'（结论强度不能超过证据强度）。")
    print("")
    print("   [!] 这条边界是【实测】出来的，不是理论担心 —— 拿本项目两次真实事故反测：")
    print("        第1版 抓成吉他分解和弦伴奏层(47音)：级进率 58.7% -> 体检【放行】")
    print("        第2版 源数据根本不是那首歌(29音)：级进率 60.7% -> 体检【放行】")
    print("       => 两次真实事故，本门禁一次都没拦住。")
    print("       => 级进率在'真旋律 60%'与'分解和弦 58.7%'之间【没有可分的阈值】；")
    print("          卡到能拒绝 58.7%，就会把大量正常旋律一起拒绝。")
    print("       => 结论：**没有哪个自动指标能替代人耳。**")
    print("   " + "-" * 70)
    print("=" * 74)


def main():
    ap = argparse.ArgumentParser(description="旋律表 → gen_song_rom.py 音符数据（零手抄）")
    ap.add_argument("--in", dest="inp", required=True, help="旋律表（idx/note/midi/vel/start_s/dur_ms/dur_tick）")
    ap.add_argument("--shift", type=int, default=0, help="整体移调半音数（如 +5）")
    ap.add_argument("--bpm", type=int, default=120, help="速度（用于秒→拍）")
    ap.add_argument("--var", default="FADED_CHORUS", help="目标变量名")
    ap.add_argument("--songs-py", default=None, help="gen_song_rom.py 路径（默认同目录）")
    ap.add_argument("--write", action="store_true", help="原地写入 gen_song_rom.py 的 BEGIN/END 之间")
    ap.add_argument("--verify", action="store_true", help="幂等自检：现有数据是否等于本脚本产物")
    ap.add_argument("--force", action="store_true",
                    help="体检不通过时仍强制生成（会留痕；默认拒绝且不改任何文件）")
    ap.add_argument("--schema", choices=("auto", "liaison", "piano"), default="auto",
                    help="旋律表列格式：liaison(idx note midi vel start dur dur_tick) / "
                         "piano(idx note midi freq onset dur conf)；默认按第 4 列自动识别")
    a = ap.parse_args()

    inp = Path(a.inp)
    rows = read_table(inp, a.schema)
    notes = build_notes(rows, a.shift, a.bpm)

    print("=" * 74)
    print("旋律表 → ROM 数据   源:%s" % inp.name)
    print("  音符数=%d   移调=%+d 半音   速度=%d BPM" % (len(rows), a.shift, a.bpm))
    print("=" * 74)

    print("\n--- 两条判据（只能证明'是单声部旋律'，不能证明'是哪首歌'）---")
    for ln in metrics(rows, notes):
        print("  " + ln)

    print("\n--- 逐音对照（源 MIDI → 移调后）---")
    for i, (name, beats, src, tgt, ticks) in enumerate(notes):
        print("  %2d  %-4s(midi %3d) → %-4s(midi %3d)  %8s 拍 = %7d tick"
              % (i, midi_to_name(src), src, name, tgt, fmt_beats(beats), ticks))

    block = render_block(notes, a.var)

    # ---------------- 体检（硬门禁）：必须在任何写文件动作【之前】 ----------------
    viol, warn, lines = exam(rows, notes)
    print_exam(viol, warn, lines, n_notes=len(rows))

    py_path = Path(a.songs_py) if a.songs_py else Path(__file__).resolve().parent / "gen_song_rom.py"

    if viol and not a.force:
        print("\n" + "!" * 74)
        print("!! 拒绝生成：旋律表体检不通过（%d 条）。" % len(viol))
        print("!! **没有修改任何文件。**")
        print("!! 处理原则：数据不对时我们要的是【停下来】，不是自动补一个看起来像的。")
        print("!! 若你已人工确认数据没问题（例如真的是一段宽音域/带长音的旋律），")
        print("!! 可以加 --force 显式绕过 —— 但绕过会在下面留痕。")
        print("!" * 74)
        return 2
    if viol and a.force:
        print("\n" + "!" * 74)
        print("!! [警告] 体检不通过，但你用了 --force 显式绕过（%d 条）。" % len(viol))
        print("!! **这次绕过会被如实记录**：产物里应写清'体检未通过、经人工强制生成'。")
        print("!" * 74)

    print("\n--- 生成的代码块 ---")
    print(block)

    if a.verify:
        cur = parse_existing(py_path, a.var)
        want = [(n[0], n[1]) for n in notes]
        print("\n--- 幂等自检：%s ---" % py_path.name)
        print("  现有 %d 项，本脚本产物 %d 项" % (len(cur), len(want)))
        bad = 0
        for i in range(max(len(cur), len(want))):
            c = cur[i] if i < len(cur) else None
            w = want[i] if i < len(want) else None
            ok = (c is not None and w is not None and c[0] == w[0]
                  and abs(float(c[1]) - float(w[1])) < 1e-4)
            if not ok:
                bad += 1
                if bad <= 8:
                    print("  [DIFF] #%d 现有=%s  产物=%s" % (i, c, w))
        if bad == 0:
            print("  [ok] 逐项一致（现有数据确实由本脚本机械生成，无手抄痕迹）")
        else:
            print("  [FAIL] %d 项不一致 —— 现有数据与源表对不上，需要重新生成" % bad)
            return 1
        return 0

    if a.write:
        n = patch_file(py_path, block)
        print("\n--- 已写入 %s（字节变化 %+d）---" % (py_path, n))
        print("  [!] 下一步必须：① 跑 gen_song_rom.py --write（含回读逐 bit 校验）"
              "② 跑 tb_song_player")
        print("  [!] 还有一步机器替代不了：**让用户听**。体检过≠歌对了。")
    else:
        print("\n（未写文件；要原地写入请加 --write）")

    return 0


if __name__ == "__main__":
    sys.exit(main())
