#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""sweep_notes.py —— 逐个音符扫频诊断：**找出"哪个 note 不响"**

🔴🔴 **先读这一段再运行** —— 板子是【用户的乐器】，不是我们的测试台：
  · **跑之前必须先"占用"**：在团队里说一声（用户随时可能在弹，而且**戴着耳机**）
  · **结束必须发 panic**（本脚本已在 `finally` 里**无条件**清音，含异常 / Ctrl+C）
  · **默认要先确认**：不加 `--yes` 会显示警告并要求手输 YES
  ⚠️ 事故记录（2026-10-06）：本脚本第一次跑时被 `| Select-Object -First` **杀掉了上游 python**
     （见 AGENTS.md §8.2），`panic` 没发出去 ⇒ **用户听到板子自己响**（他当时正在弹琴）。
     ⇒ 所以现在：①`finally` 无条件 panic ②`--yes` 确认闸门 ③**不要用管道截断它**。

诊断逻辑：把问题**切成两半**，立刻分清是 GUI 侧还是 FPGA 侧：
  1) **GUI→串口**这一端：直接发 `90 <note> 64`（不经过 GUI 的键位映射）
     ⇒ 若某 note 在这里就不响 ⇒ **不是 GUI 键位的问题**
  2) **FPGA 回声**：带回显功能的位流会回显收到的字节 ⇒ 可验证字节确实到达了 FPGA
  3) **声学**（可选 `--audio`）：麦克风录音测该 note 频点上的幅度 —— 但**必须先过仪器自检**，
     否则"麦克风坏"会被误报成"所有 note 都不响"（**假阴性**，本项目 §9 纪律点名的错误）。

⚠️ 只依赖 `pyserial`（保住 GUI 的承诺）；`sounddevice`/`numpy` 仅用于**可选的**声学测量，
   缺失或不可用时自动降级为「串口+回声」诊断。

用法：
    python sweep_notes.py --port COM9                 # 会先要求确认
    python sweep_notes.py --port COM9 --yes           # 跳过确认（**已显式占用**时用）
    python sweep_notes.py --port COM9 --yes --audio
"""

import argparse
import sys
import time

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

try:
    import serial
    from serial.tools import list_ports
except ImportError:
    print("缺少 pyserial —— 请用 fpga_hank\\_tools\\venv 里的 python 运行")
    sys.exit(2)


def m_note_on(note, vel=100):
    return bytes([0x90, note & 0x7F, max(1, min(127, vel))])


def m_note_off(note):
    return bytes([0x80, note & 0x7F, 0x00])


def m_all_notes_off():
    return bytes([0xB0, 0x7B, 0x00])


def m_deep_panic():
    """★ 最彻底的清音序列（与 Lead 手工清理用的一致）：
    CC64=0 抬踏板 → CC123 All Notes Off → CC120 All Sound Off → CC121 Reset All Ctrls
    → **再对 0..127 全发一遍 NoteOff**（384 B，约 35 ms）。"""
    out = bytearray()
    out += bytes([0xB0, 0x40, 0x00])      # 踏板抬起
    out += m_all_notes_off()              # CC123
    out += bytes([0xB0, 0x78, 0x00])      # CC120
    out += bytes([0xB0, 0x79, 0x00])      # CC121
    for n in range(128):                  # 全音符 NoteOff（双保险）
        out += m_note_off(n)
    return bytes(out)


def parse_range(s):
    parts = s.replace(",", ":").split(":")
    if ".." in s:
        parts = s.split("..")
    lo = int(parts[0])
    hi = int(parts[1]) if len(parts) > 1 else lo
    return lo, hi


def confirm_or_abort(port, lo, hi):
    """默认拦一道：防止误跑打扰正在弹琴的用户。"""
    print("=" * 70)
    print("  ⚠️  本脚本会往【板子】发真实 note —— 板子是**用户的乐器**！")
    print(f"     端口 {port}，将逐个发送 note {lo}..{hi}，**会出声**。")
    print("     跑之前请确认：① 已在团队里'占用'板子 ② 用户现在没在弹。")
    print("=" * 70)
    try:
        ans = input("  确认要发送吗？输入大写 YES 继续：").strip()
    except (EOFError, KeyboardInterrupt):
        print("\n  已取消。")
        return False
    if ans != "YES":
        print("  已取消（未发送任何字节）。")
        return False
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", help="串口名（FPGA UART = COM9）")
    ap.add_argument("--notes", default="48:84", help="note 范围，如 48:84")
    ap.add_argument("--vel", type=int, default=100)
    ap.add_argument("--hold", type=float, default=0.35, help="每个 note 按住秒数")
    ap.add_argument("--audio", action="store_true", help="额外用麦克风测响度（需 numpy+sounddevice）")
    ap.add_argument("--yes", action="store_true", help="跳过交互确认（**只在已显式占用板子时用**）")
    ap.add_argument("--list-ports", action="store_true")
    a = ap.parse_args()

    if a.list_ports or not a.port:
        for p in list_ports.comports():
            print(f"  {p.device}\t{p.description}\t{p.hwid}")
        if not a.port:
            return 0

    lo, hi = parse_range(a.notes)

    if not a.yes and not confirm_or_abort(a.port, lo, hi):
        return 3

    rec = None
    np = None
    if a.audio:
        try:
            import numpy as _np
            import sounddevice as sd
            np = _np
            rec = sd
            print(f"  声学测量：默认输入设备 = {sd.query_devices(kind='input')['name']}")
            # ★★ 仪器自检（2026-10-06 实测踩过）：
            #    本机"数字麦克风阵列"设备**存在且能打开**，但只返回 ±1 LSB（std≈1.5e-5）
            #    ⇒ 若不检查，会把【仪器坏】误报成【所有 note 都不响】—— 假阴性结论。
            probe = np.asarray(rec.rec(int(44100 * 0.5), samplerate=44100,
                                       channels=1, blocking=True), dtype=np.float64).ravel()
            if probe.std() < 1e-3:
                print(f"  ⚠ 麦克风无有效信号（本底 std={probe.std():.2e} ≈ ±1 LSB）")
                print("     ⇒ **声学判定不可用**，自动降级为「串口+回声」诊断。")
                print("     ⚠️ 这不等于「所有音都不响」——是**测量仪器**的问题，不是琴的问题。")
                rec = None
            else:
                print(f"  麦克风本底 std={probe.std():.4f}（可用，开始声学测量）")
        except Exception as e:                                   # noqa: BLE001
            print(f"  ⚠ 声学测量不可用（{e}）⇒ 降级为「串口+回声」诊断")

    try:
        ser = serial.Serial(a.port, 115200, timeout=0.15)
    except Exception as e:                                       # noqa: BLE001
        print(f"  打不开 {a.port}: {e}")
        return 2

    print(f"\n  端口={a.port}  扫描 note {lo}..{hi}（vel={a.vel}，每个 {a.hold}s）")
    print(f"  {'note':>5} {'音名':>5} {'期望Hz':>9} {'回声':>14} {'声学RMS':>9} {'频点幅度':>9}  判定")
    rows = []
    names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    # ★★ 无条件清音：无论正常结束、抛异常，还是 Ctrl+C，`finally` 一定会发 panic。
    #    （事故根源就是"以为会发、其实没发"——见文件头事故记录。）
    try:
        for note in range(lo, hi + 1):
            ser.reset_input_buffer()
            ser.write(m_note_on(note, a.vel))
            ser.flush()

            rms = amp = None
            if rec is not None:
                fs = 44100
                n = int(fs * a.hold)
                data = rec.rec(n, samplerate=fs, channels=1, blocking=True)
                x = np.asarray(data, dtype=np.float64).ravel()
                rms = float(np.sqrt(np.mean(x ** 2)))
                f0 = 440.0 * 2 ** ((note - 69) / 12.0)
                w = np.hanning(len(x))
                t = np.arange(len(x))
                amp = float(abs(np.sum(x * w * np.exp(-2j * np.pi * f0 * t / fs))) / (len(x) / 2.0))
            else:
                time.sleep(a.hold)

            ser.write(m_note_off(note))
            ser.flush()
            time.sleep(0.06)
            echo = ser.read(64)

            if amp is not None:
                verdict = "响" if amp > 50 else ("弱" if amp > 15 else "★不响")
            else:
                verdict = "已发" if echo else "无回声"
            nm = f"{names[note % 12]}{note // 12 - 1}"
            f0s = 440.0 * 2 ** ((note - 69) / 12.0)
            print(f"  {note:>5} {nm:>5} {f0s:>9.2f} {echo.hex(' '):>14} "
                  f"{(f'{rms:.1f}' if rms is not None else '-'):>9} "
                  f"{(f'{amp:.0f}' if amp is not None else '-'):>9}  {verdict}")
            rows.append((note, nm, echo.hex(" "), rms, amp, verdict))
    except KeyboardInterrupt:
        print("\n  ⚠ 被中断 ⇒ 下面立刻发 panic 清音")
    finally:
        # ★ 无条件清理（含异常/中断）。**这是纪律，不是可选项。**
        try:
            ser.write(m_deep_panic())
            ser.flush()
            time.sleep(0.1)
            print("  ✔ 已发深度 panic（CC64=0 → CC123 → CC120 → CC121 + 128×NoteOff）—— 板子已清音")
        except Exception as e:                                   # noqa: BLE001
            print(f"  🔴 panic 发送失败（{e}）—— **请手工清音或拔电**！")
        finally:
            try:
                ser.close()
            except Exception:                                    # noqa: BLE001
                pass

    bad = [r for r in rows if r[5] in ("★不响", "无回声")]
    print(f"\n  小结：共 {len(rows)} 个 note，异常 {len(bad)} 个")
    if bad:
        print("  异常清单：" + ", ".join(f"{n}({nm})" for n, nm, *_ in bad))
    else:
        print("  ⇒ 全部 note 有响应")
    print("  提示：若这里全部正常，而 GUI 里某些键不响 ⇒ **问题在 GUI 的键位映射/状态跟踪**。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
