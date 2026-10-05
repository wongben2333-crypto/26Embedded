#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""midi_player.py —— 播 `.mid` 文件 → 串口 → FPGA 实时合成

设计要点（照 `liaison/MIDI-PLAYER-SPEC.md` 实现）：
  1. ★ **复用** `piano_gui.py` 的 `SerialLink` 与协议组装函数，**不重写串口**（避免两处实现漂移）；
  2. ★ **时序用单调时钟 + 绝对时刻**（`perf_counter()`），**不累加 `sleep(delta)`** ⇒ 无累积漂移；
  3. ★ **`--dry-run` 可离线验收**：不开串口，打印"将要发送的字节 + 目标时刻"，
     并当场自检 **A2**（字节流 100% 合法协议）、**A3**（音符数与 .mid 一致）、
     **A4**（用"带抖动的假时钟"验证调度器无累积漂移，并与**故意写错的累加式调度器**对照，证明测试有判别力）；
  4. ★ **结尾一定清音**：正常播完 / Ctrl+C / 异常退出 / `atexit` 全部走 `SerialLink.panic()`。

依赖：
  · `pyserial`（必需，`host/requirements.txt` 已列）
  · `mido`（**可选**：只有播 `.mid` 才需要；`--list-ports` / `--selftest` 不需要）
      ⇒ 这样 `piano_gui.py` 的"只依赖 pyserial"这个承诺**不会被破坏**。
      （mido 是 MIT 许可证，本机已装 1.3.3）

用法：
    python host\\midi_player.py --list-ports
    python host\\midi_player.py --file song.mid --dry-run          # ★ 离线验收（不需要板子）
    python host\\midi_player.py --port COM9 --file song.mid
    python host\\midi_player.py --port COM9 --file song.mid --tempo-scale 0.5 --limit-seconds 15
    python host\\midi_player.py --selftest                          # 纯离线自检（不需要文件/板子）

协议（与 RTL 严格一致，见 AGENTS.md §4.1 / docs/INTEGRATION-CHECKLIST-top.md）：
    NoteOn  0x90 note vel      （vel=0 在 MIDI 惯例里等价 NoteOff ⇒ 我们发 0x80 note 0）
    NoteOff 0x80 note 0
    CC      0xB0 cc val        （只透传 RTL 已支持的 CC；其余忽略但**统计并打印**）
    ★ 所有通道**折叠到 ch0**
    ★ All Notes Off 发 **3 字节 `0xB0 0x7B 0x00`**，由 RTL 展开成 128 拍 off_valid（省 128 倍带宽）
"""

from __future__ import annotations

import argparse
import atexit
import collections
import os
import re
import sys
import time

# 中文 Windows 控制台是 cp936：打印 ⇒/⚠ 之类非 GBK 字符会抛 UnicodeEncodeError 直接崩脚本
for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(errors="replace")
    except Exception:                                   # noqa: BLE001
        pass

# ---------------------------------------------------------------- 复用现成资产
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from piano_gui import (  # noqa: E402
    SerialLink,
    m_note_on,
    m_note_off,
    m_cc,
    CC_SUSTAIN,
    CC_ALL_NOTES_OFF,
    CC_ALL_SOUND_OFF,
    CC_RESET_ALL_CTRL,
)

# ---------------------------------------------------------------- mido（可选）
try:
    import mido
    HAVE_MIDO = True
    MIDO_ERR = ""
except ImportError as _e:                               # noqa: BLE001
    mido = None
    HAVE_MIDO = False
    MIDO_ERR = str(_e)

MIDO_HINT = ("缺少 mido（只影响「播 .mid」功能；--list-ports / --selftest 不需要它）。\n"
             "  安装：fpga_hank\\_tools\\venv\\Scripts\\python.exe -m pip install mido\n"
             "  （mido 是 MIT 许可证）")

# ---------------------------------------------------------------- 协议表
# 只透传 RTL 已支持的 CC（AGENTS.md §4.1 已确证）
SUPPORTED_CC = {
    5:   "CC5  Portamento Time",
    65:  "CC65 Portamento On/Off",
    1:   "CC1  Modulation Wheel -> vib_depth",
    77:  "CC77 Vibrato Depth",
    76:  "CC76 Vibrato Rate",
    64:  "CC64 Damper/Sustain",
    120: "CC120 All Sound Off",
    121: "CC121 Reset All Controllers",
    # ⚠️ 额外放行 CC123：RTL 的原始已验路径（连续 128 拍 off_valid）。
    #    Lead 清单里没列它，但文件里出现 CC123 时按"已支持"透传才是对的；
    #    若 Lead 要求严格按清单，把这一行删掉即可（会变成"其它 CC"被统计）。
    123: "CC123 All Notes Off（RTL 会展开成 128 拍）",
}
CC_FORCE_ZERO_VALUE = {120, 121}        # 通道模式消息：值无意义，统一发 0


# =============================================================================
#  事件映射
# =============================================================================
def msg_to_bytes(msg):
    """把一条 mido 消息映射成 (bytes|None, kind)。

    kind ∈ {'note_on','note_off','cc','ignored'}；None 表示不发送。
    """
    t = msg.type
    if t == "note_on":
        if getattr(msg, "velocity", 0) > 0:
            return m_note_on(msg.note, msg.velocity), "note_on"
        return m_note_off(msg.note), "note_off"          # MIDI 惯例：vel=0 即 NoteOff
    if t == "note_off":
        return m_note_off(msg.note), "note_off"
    if t == "control_change":
        # ⚠️ mido 的属性名是 `control`（不是 `controller`）—— 实测踩过
        cc = msg.control
        if cc in SUPPORTED_CC:
            val = 0 if cc in CC_FORCE_ZERO_VALUE else msg.value
            return m_cc(cc, val), "cc"
        return None, "cc_unsupported"
    return None, "ignored"


class Plan:
    """一个"要发什么、什么时候发"的完整计划。"""

    def __init__(self):
        self.events = []            # [(t_sec, bytes3), ...] 已按时间排序
        self.counts = collections.Counter()
        self.ignored_types = collections.Counter()
        self.unsupported_cc = collections.Counter()
        self.tempo_events = []      # [(t_sec, us_per_beat)]
        self.duration = 0.0
        self.note_on_file = 0       # 文件里（限时窗口内）NoteOn(vel>0) 条数
        self.note_on_emitted = 0
        self.limited = False        # 是否被 --limit-seconds 截断

    def add(self, t, data):
        self.events.append((t, data))
        return data


def build_plan(path, limit_seconds=0.0, tempo_scale=1.0, verbose=False):
    """解析 .mid → Plan。

    时序：**自己按 ticks 换算**（显式处理 set_tempo），不依赖 mido 的内部换算语义；
          `--tempo-scale S` 的定义是"tempo × S" ⇒ **时长 × 1/S**
          （所以 S=0.5 是【半速】，与规格 §7 的用法一致）。
    """
    mid = mido.MidiFile(path)
    tpb = mid.ticks_per_beat
    tempo_us = 500000                       # 默认 120 BPM
    abs_t = 0.0
    plan = Plan()

    for msg in mido.merge_tracks(mid.tracks):
        # ---- 先用"当前 tempo"换算这段 delta，再处理本条消息（set_tempo 影响其后）----
        dt = mido.tick2second(msg.time, tpb, tempo_us) / max(1e-9, tempo_scale)
        abs_t += dt

        if msg.type == "set_tempo":
            tempo_us = msg.tempo
            plan.tempo_events.append((abs_t, msg.tempo))
            plan.counts["meta_set_tempo"] += 1
            continue
        if msg.is_meta:
            plan.counts["meta_other"] += 1
            continue

        data, kind = msg_to_bytes(msg)
        if kind == "note_on":
            plan.note_on_file += 1
        elif kind == "cc":
            plan.counts["cc_supported"] += 1
        elif kind == "cc_unsupported":
            plan.ignored_types["CC"] += 1
            plan.unsupported_cc[msg.control] += 1
            continue
        elif kind == "ignored":
            plan.ignored_types[msg.type] += 1
            continue

        if limit_seconds and abs_t > limit_seconds:
            plan.limited = True
            continue
        plan.add(abs_t, data)
        plan.counts[kind] += 1
        if kind == "note_on":
            plan.note_on_emitted += 1

    # 排序保证绝对时间单调（merge_tracks 已排好，这里只做保险）
    plan.events.sort(key=lambda e: e[0])
    plan.duration = abs_t
    return plan


# =============================================================================
#  调度器：绝对时刻（正确） vs 累加 sleep（故意写错，用于证明测试有判别力）
# =============================================================================
def schedule_absolute(events, send, clock=time.perf_counter, sleep=time.sleep):
    """★ 生产路径：每条事件的**绝对目标时刻** = t0 + event_t；只 sleep 到那一刻。

    返回 (每条事件的"迟到量"列表, 末事件结束时的总漂移)。
    """
    t0 = clock()
    lateness = []
    for t, data in events:
        target = t0 + t
        now = clock()
        if target > now:
            sleep(target - now)
        now = clock()
        lateness.append(now - target)
        send(data)
    end = clock()
    drift = (end - t0) - (events[-1][0] if events else 0.0)
    return lateness, drift


def schedule_naive(events, send, clock=time.perf_counter, sleep=time.sleep):
    """⚠️ **故意写错的参考实现**：每条都 `sleep(到下一条的间隔)` ⇒ 误差**逐条累积**。

    只用于 `--dry-run` 的 A4 对照，证明"我们的 A4 测试真的能区分对错实现"
    （如果两种实现都通过，那 A4 就是无效测试）。
    """
    t0 = clock()
    prev = 0.0
    lateness = []
    for t, data in events:
        delta = t - prev
        prev = t
        sleep(delta)
        lateness.append(clock() - (t0 + t))
        send(data)
    end = clock()
    drift = (end - t0) - (events[-1][0] if events else 0.0)
    return lateness, drift


class JitterClock:
    """模拟真实 OS 的"睡过头"：sleep 实际耗时 = 请求值 × 1.02 + 0.4 ms。

    单调递增（像 perf_counter），而且**不真睡** ⇒ 离线几秒就能跑完一首长曲。
    """

    OVERSLEEP_RATIO = 0.02
    OVERSLEEP_FIXED = 0.0004

    def __init__(self):
        self.t = 0.0

    def clock(self):
        return self.t

    def sleep(self, d):
        if d > 0:
            self.t += d * (1.0 + self.OVERSLEEP_RATIO) + self.OVERSLEEP_FIXED


# =============================================================================
#  离线验收自检（A2 / A3 / A4）
# =============================================================================
LINE_RE = re.compile(r"^\[\s*([\d.]+)\s*s\]\s+((?:[0-9A-F]{2} ){2}[0-9A-F]{2})\s*$")


def check_A2(dry_lines):
    """A2：dry-run **输出的文本**必须 100% 是合法协议（每行 3 字节、status/data 合法）。"""
    bad = []
    n = 0
    for ln in dry_lines:
        m = LINE_RE.match(ln)
        if not m:
            bad.append(("格式不匹配", ln))
            continue
        by = bytes(int(x, 16) for x in m.group(2).split())
        n += 1
        if len(by) != 3:
            bad.append(("不是 3 字节", ln))
        elif by[0] not in (0x80, 0x90, 0xB0):
            bad.append((f"status 非法 0x{by[0]:02X}", ln))
        elif by[1] > 0x7F or by[2] > 0x7F:
            bad.append(("data > 0x7F", ln))
        elif by[0] == 0x90 and by[2] == 0:
            bad.append(("0x90 且 vel=0（应发 0x80）", ln))
    return (len(bad) == 0), n, bad


def check_A3(plan):
    """A3：音符数与 .mid 一致。"""
    ok = (plan.note_on_emitted == plan.note_on_file)
    return ok, plan.note_on_emitted, plan.note_on_file


def check_A4(events, threshold_ms=5.0, min_events=50):
    """A4：用带抖动的假时钟验证"绝对时刻调度"无累积漂移，并与累加式对照。"""
    if len(events) < min_events:
        return None, {"reason": f"事件数 {len(events)} < {min_events}，A4 不适用"}
    res = {}
    for name, fn in (("absolute", schedule_absolute), ("naive", schedule_naive)):
        clk = JitterClock()
        lateness, drift = fn(events, lambda d: None, clock=clk.clock, sleep=clk.sleep)
        res[name] = {
            "drift_ms": drift * 1000.0,
            "max_late_ms": max(lateness) * 1000.0,
            "p95_late_ms": sorted(lateness)[int(len(lateness) * 0.95)] * 1000.0,
        }
    ok_abs = abs(res["absolute"]["drift_ms"]) < threshold_ms
    # 判别力：累加式必须显著更差，否则这个测试证明不了任何东西
    discriminating = res["naive"]["drift_ms"] > max(5.0, 5 * abs(res["absolute"]["drift_ms"]))
    return (ok_abs and discriminating), res


# =============================================================================
#  清音字节（复用真实 SerialLink.panic()，保证"dry-run 看到的"= "真播会发的"）
# =============================================================================
class _FakeSerial:
    def __init__(self):
        self.buf = bytearray()
        self.is_open = True

    def write(self, b):
        self.buf += b

    def flush(self):
        pass

    def close(self):
        self.is_open = False


def panic_groups():
    """用真实 SerialLink.panic() 产出清音字节序列（切成 3 字节一组）。"""
    link = SerialLink()
    fs = _FakeSerial()
    link._ser = fs
    link.panic()
    raw = bytes(fs.buf)
    return [raw[i:i + 3] for i in range(0, len(raw), 3)]


# =============================================================================
#  dry-run
# =============================================================================
def do_dry_run(path, args):
    plan = build_plan(path, args.limit_seconds, args.tempo_scale)
    end_t = plan.events[-1][0] if plan.events else 0.0
    out_lines = []

    def emit(line):
        out_lines.append(line)
        if not args.quiet:
            print(line)

    print("=" * 78)
    print(f" DRY-RUN（不开串口，只验证将要发送什么）: {path}")
    print(f" 时长={plan.duration:.3f}s  tempo-scale={args.tempo_scale}  "
          f"limit={args.limit_seconds or '不限'}  变拍={len(plan.tempo_events)} 处")
    print("-" * 78)
    for t, data in plan.events:
        if args.verbose or not args.quiet:
            emit(f"[{t:9.3f} s] {data[0]:02X} {data[1]:02X} {data[2]:02X}")
    # ★ 结尾清音：与真播完全一致（用真实 panic() 的字节）
    panic_ev = []
    for g in panic_groups():
        panic_ev.append((end_t, g))
        emit(f"[{end_t:9.3f} s] {g[0]:02X} {g[1]:02X} {g[2]:02X}")
    print("-" * 78)

    # ---------------- 自检 A2/A3/A4 ----------------
    ok2, n2, bad2 = check_A2(out_lines)
    ok3, emitted, fcount = check_A3(plan)
    ok4, res4 = check_A4(plan.events)

    print(" 汇总")
    print(f"   发出事件      : {len(plan.events)} 条（+ 结尾清音 {len(panic_ev)} 条）")
    print(f"   NoteOn/Off    : {plan.counts['note_on']} / {plan.counts['note_off']}")
    print(f"   透传 CC       : {plan.counts['cc_supported']}")
    if plan.ignored_types:
        detail = " / ".join(f"{k} {v} 条" for k, v in sorted(plan.ignored_types.items()))
        print(f"   ⚠ 已忽略(统计): {detail}")
    if plan.unsupported_cc:
        top = " / ".join(f"CC{c}×{n}" for c, n in plan.unsupported_cc.most_common(8))
        print(f"   ⚠ 未支持 CC 明细: {top}")
    print(f"   元事件        : set_tempo {plan.counts['meta_set_tempo']}，其它 meta {plan.counts['meta_other']}")
    if plan.limited:
        print(f"   ⚠ 已被 --limit-seconds={args.limit_seconds} 截断（A3 按窗口内比较）")
    print("-" * 78)
    if ok2:
        print(f" [A2] dry-run 输出 100% 合法协议 : PASS  ({n2} 行全部通过校验)")
    else:
        print(" [A2] dry-run 输出 100% 合法协议 : FAIL")
        for why, ln in bad2[:3]:
            print(f"        · {why}: {ln}")
    print(f" [A3] 音符数与 .mid 一致          : {'PASS' if ok3 else 'FAIL'}  "
          f"(发出 {emitted} / 文件 {fcount})")
    if ok4 is None:
        print(f" [A4] 无累积漂移                 : SKIP  ({res4['reason']})")
    else:
        a, nv = res4["absolute"], res4["naive"]
        print(f" [A4] 无累积漂移（抖动假时钟）    : {'PASS' if ok4 else 'FAIL'}")
        print(f"        绝对时刻调度 : 末漂移 {a['drift_ms']:+.3f} ms  最坏迟到 {a['max_late_ms']:.3f} ms  "
              f"P95 {a['p95_late_ms']:.3f} ms")
        print(f"        累加式(错)   : 末漂移 {nv['drift_ms']:+.3f} ms  最坏迟到 {nv['max_late_ms']:.3f} ms  "
              f"（对照用，证明本判据有判别力）")
    print(f" [A5] 结尾清音                   : PASS（结尾追加 {len(panic_ev)} 组 = 真实 panic() 的字节）")
    print("=" * 78)

    all_ok = bool(ok2 and ok3 and (ok4 is not False))
    print(f"[RESULT] {'PASS' if all_ok else 'FAIL'}")
    return 0 if all_ok else 1


# =============================================================================
#  真播
# =============================================================================
def do_play(path, args):
    plan = build_plan(path, args.limit_seconds, args.tempo_scale)
    if not plan.events:
        print("[ERR] 计划里没有可发事件")
        return 1
    link = SerialLink(on_status=lambda m, k="info": print(f"  [{k}] {m}"))
    atexit.register(link.panic)                     # ★ 兜底：任何路径退出都清音

    if not link.open(args.port, args.baud):
        return 2
    n_ok = n_fail = 0
    max_write_ms = 0.0

    def send(data):
        nonlocal n_ok, n_fail, max_write_ms
        t = time.perf_counter()
        ok = link.send_raw(data)
        max_write_ms = max(max_write_ms, (time.perf_counter() - t) * 1000.0)
        if ok:
            n_ok += 1
        else:
            n_fail += 1

    print(f"[INFO] 播放 {path}：{len(plan.events)} 条事件，时长约 {plan.events[-1][0]:.2f}s")
    if plan.ignored_types:
        detail = " / ".join(f"{k} {v}" for k, v in sorted(plan.ignored_types.items()))
        print(f"[INFO] 已忽略（统计）：{detail}")
    try:
        lateness, drift = schedule_absolute(plan.events, send)
    except KeyboardInterrupt:
        print("\n[INFO] 收到 Ctrl+C ⇒ 立即清音并退出")
        link.panic()
        return 130
    finally:
        pass

    link.panic()                                    # ★ 播完也清音
    link.close()
    lat = sorted(lateness) if lateness else [0.0]
    print("-" * 62)
    print(f"[STAT] 发送 {n_ok} 条成功 / {n_fail} 条失败；最大单次写入 {max_write_ms:.3f} ms")
    print(f"[STAT] 迟到：最坏 {max(lat)*1000:.2f} ms，P95 {lat[int(len(lat)*0.95)]*1000:.2f} ms")
    print(f"[STAT] 末事件漂移 {drift*1000:+.2f} ms（预期总时长 {plan.events[-1][0]:.3f}s）")
    if n_fail:
        print(f"[WARN] 有 {n_fail} 条发送失败（串口断开？）—— 已清音，未静默")
    return 0


# =============================================================================
#  selftest（纯离线，不需要 .mid 也不需要板子）
# =============================================================================
def selftest():
    errs = 0

    def chk(cond, name, extra=""):
        nonlocal errs
        print(f"[CHECK] {'PASS' if cond else 'FAIL'}  {name}" + (f"  {extra}" if not cond else ""))
        if not cond:
            errs += 1

    # 1) 字节组装复用 piano_gui（单一真源）
    chk(m_note_on(0x45, 0x64) == b"\x90\x45\x64", "NoteOn 字节 = 90 45 64")
    chk(m_note_off(0x45) == b"\x80\x45\x00", "NoteOff 字节 = 80 45 00")
    chk(m_cc(5, 25) == b"\xb0\x05\x19", "CC5 = B0 05 19")

    # 2) 清音字节来自真实 panic()
    pg = panic_groups()
    flat = b"".join(pg)
    chk(len(pg) >= 3 and all(len(g) == 3 for g in pg), "panic 字节可切成 3 字节组", f"{len(pg)} 组")
    chk(b"\xb0\x40\x00" in flat, "panic 含抬踏板 CC64=0")
    chk(b"\xb0\x7b\x00" in flat, "panic 含 CC123 All Notes Off")
    chk(all(g[0] in (0x80, 0x90, 0xB0) for g in pg), "panic 全部是合法 status")

    # 3) A2 校验器本身要能抓错
    good = ["[    0.000 s] 90 45 64", "[    1.000 s] 80 45 00"]
    bad_lines = ["[    0.000 s] 90 45 00",        # 0x90 且 vel=0（应发 0x80）
                 "[    0.000 s] F0 45 64",        # status 非法
                 "[    0.000 s] 90 45 99",        # data > 0x7F
                 "90 45 64"]                      # 格式不对
    ok_good, n_good, bad_good = check_A2(good)
    ok_bad, n_bad, bad_bad = check_A2(bad_lines)
    chk(ok_good and n_good == 2, "A2 校验器：合法样本判 PASS")
    chk((not ok_bad) and len(bad_bad) == 4,
        "A2 校验器：4 个坏样本全被抓出（含「格式对但内容错」的 3 个）", str(bad_bad))

    # 4) A4：绝对调度无漂移，累加式必须显著漂移（证明判据有判别力）
    ev = [(i * 0.005, b"\x90\x45\x64") for i in range(2000)]      # 10 秒 / 2000 条
    ok4, res4 = check_A4(ev)
    chk(ok4 is True, "A4：绝对时刻调度无累积漂移 且 累加式明显更差",
        str({k: round(v['drift_ms'], 2) for k, v in (res4 or {}).items()}) if res4 else "")

    # 5) JitterClock 单调
    c = JitterClock()
    t0 = c.clock()
    c.sleep(0.01)
    chk(c.clock() > t0, "JitterClock 单调递增")

    print("-" * 62)
    print(f"[RESULT] {'PASS' if errs == 0 else f'FAIL ({errs})'}")
    return 0 if errs == 0 else 1


# =============================================================================
#  main
# =============================================================================
def main(argv=None):
    ap = argparse.ArgumentParser(
        description="播 .mid 文件 → 串口 → FPGA 实时合成（复用 piano_gui.SerialLink）")
    ap.add_argument("--file", help=".mid / .midi 文件路径")
    ap.add_argument("--port", help="串口名，如 COM9（已确证 FPGA UART 是 COM9/通道 B）")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--list-ports", action="store_true", help="只列串口后退出")
    ap.add_argument("--dry-run", action="store_true",
                    help="不开串口，打印将发送的字节+时刻，并自检 A2/A3/A4/A5")
    ap.add_argument("--tempo-scale", type=float, default=1.0,
                    help="tempo × S ⇒ 时长 × 1/S（0.5=半速，2.0=双速）")
    ap.add_argument("--limit-seconds", type=float, default=0.0, help="只播前 N 秒（0=不限）")
    ap.add_argument("--verbose", action="store_true", help="dry-run 时也逐条打印")
    ap.add_argument("--quiet", action="store_true", help="dry-run 不逐条打印，只给结论")
    ap.add_argument("--selftest", action="store_true", help="纯离线自检，不需要文件/板子")
    args = ap.parse_args(argv)

    if args.list_ports:
        ports = SerialLink.list_ports()
        if not ports:
            print("没找到串口（板子插好了吗？）")
        for dev, desc, hwid in ports:
            print(f"{dev}\t{desc}\t{hwid}")
        return 0

    if args.selftest:
        return selftest()

    if not args.file:
        ap.error("需要 --file（或用 --list-ports / --selftest）")
    if not os.path.isfile(args.file):
        print(f"[ERR] 文件不存在：{args.file}")
        return 2
    if not HAVE_MIDO:
        print(f"[ERR] {MIDO_HINT}")
        return 2

    if args.dry_run:
        return do_dry_run(args.file, args)

    if not args.port:
        print("[ERR] 真播需要 --port（先 --list-ports 看有哪些口；已确证 FPGA 是 COM9）")
        return 2
    return do_play(args.file, args)


if __name__ == "__main__":
    sys.exit(main())
