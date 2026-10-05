#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""piano_gui.py —— 电脑当简易钢琴弹 FPGA（鼠标 + 电脑键盘 → 串口 MIDI → 板子发声）

数据流： 鼠标/键盘 → 本程序 → 串口(115200 8N1) → FPGA uart_rx.v → midi_rx.v → 合成器 → 耳机孔

★ 协议（与 RTL 侧严格一致，不要改）
    NoteOn : 0x90 note vel      （vel = 0 视为 NoteOff）
    NoteOff: 0x80 note 0
    AllOff : 0xB0 0x7B 0x00     （CC123 All Notes Off）
    Control Change（表情维度，本文件新增；编号已按官方 Table 3 查证）：
        CC 5   Portamento Time     滑音时间 0..127（0=关；约定 t ≈ v*4 ms）
        CC 65  Portamento On/Off   滑音开关 0/127（≤63 关，≥64 开）
        CC 1   Modulation Wheel    颤音深度 0..127（MIDI 通用惯例作颤音深度）
        CC 77  Sound Controller 8  规范里的 Vibrato Depth —— 与 CC1 同步发送，RTL 实现任一个都行
        CC 76  Sound Controller 7  颤音速度 0..127（约定 f ≈ v*0.1 Hz）
        CC 64  Damper Pedal        延音踏板 0/127（≤63 关，≥64 开）
        CC 120/121/123             All Sound Off / Reset All Controllers / All Notes Off（清音三连）
    note 0..127，A4 = 69 = 440 Hz
    ⚠️ 查证来源与理由见 host/README.md 的「Control Change 编号查证」一节。

★ 只做「琴键 + 状态」，**不画任何声音波形**（按用户要求）。

用法：
    python piano_gui.py                  # 正常启动（自动列出串口）
    python piano_gui.py --port COM8      # 指定串口
    python piano_gui.py --list-ports     # 只列串口
    python piano_gui.py --selftest       # 不开界面，自检协议组装/音高换算/键位表
    python piano_gui.py --smoke 2000     # 启动界面，2 秒后自动关闭（用于验证能起来）

键盘布局（默认，可改 KEYMAP）：
    白键： A S D F G H J K L ;           → C4 D4 E4 F4 G4 A4 B4 C5 D5 E5
    黑键： W E   T Y U   O P             → C#4 D#4  F#4 G#4 A#4  C#5 D#5
    八度： Z 降八度 / X 升八度            （每次 ±12 个半音）
    其它： ESC 或关闭窗口 = 全部停止后退出
"""

from __future__ import annotations

import argparse
import atexit
import sys
import threading
import time

# ---------------------------------------------------------------- 协议常量
NOTE_ON = 0x90
NOTE_OFF = 0x80
CC = 0xB0
CC_ALL_NOTES_OFF = 0x7B          # CC123

# ---- MIDI Control Change 编号 -------------------------------------------------
#  ★ 已按 **MIDI Association 官方 Table 3「Control Change Messages」** 逐条查证
#    （https://midi.org/midi-1-0-control-change-messages），结论见 host/README.md。
#  官方原表里的功能名：
#    CC 1  Modulation Wheel or Lever           —— 通用惯例用它当"颤音深度"（GM 行为）
#    CC 5  Portamento Time                     —— 滑音时间
#    CC 64 Damper Pedal on/off (Sustain)       —— ≤63 off, ≥64 on
#    CC 65 Portamento On/Off                   —— ≤63 off, ≥64 on
#    CC 76 Sound Controller 7 (Vibrato Rate)   —— MMA RP-021 规定默认含义
#    CC 77 Sound Controller 8 (Vibrato Depth)  —— MMA RP-021 规定默认含义（规范里的"颤音深度"）
#    CC 120/121/123 是【通道模式消息】：All Sound Off / Reset All Controllers / All Notes Off
CC_MOD_WHEEL        = 1
CC_PORTAMENTO_TIME  = 5
CC_SUSTAIN          = 64
CC_PORTAMENTO_ON    = 65
CC_VIBRATO_RATE     = 76
CC_VIBRATO_DEPTH_SC = 77
CC_ALL_SOUND_OFF    = 120
CC_RESET_ALL_CTRL   = 121

# ---- 数值 → 物理量 的约定映射（★ RTL 侧必须按同一约定实现，否则两边对不上）----
GLIDE_MS_PER_STEP = 4.0      # 滑音时间： t_glide ≈ v × 4 ms   （v=25 → 100 ms，v=127 → 508 ms）
VIB_HZ_PER_STEP = 0.1        # 颤音速度： f_lfo   ≈ v × 0.1 Hz（v=50 → 5.0 Hz，v=127 → 12.7 Hz）

A4_NOTE = 69
A4_FREQ = 440.0

# ---------------------------------------------------------------- 键盘布局
# 白键（按电脑键盘从左到右的顺序）与黑键
WHITE_KEYS = [  # (电脑按键, 相对 C4 的半音数, 键面文字)
    ("a", 0, "C4"), ("s", 2, "D4"), ("d", 4, "E4"), ("f", 5, "F4"),
    ("g", 7, "G4"), ("h", 9, "A4"), ("j", 11, "B4"), ("k", 12, "C5"),
    ("l", 14, "D5"), (";", 16, "E5"),
]
BLACK_KEYS = [
    ("w", 1, "C#4"), ("e", 3, "D#4"), ("t", 6, "F#4"),
    ("y", 8, "G#4"), ("u", 10, "A#4"), ("o", 13, "C#5"), ("p", 15, "D#5"),
]

DEFAULT_OCTAVE = 4                  # C4 = MIDI 60
OCTAVE_MIN, OCTAVE_MAX = 0, 8


def note_to_freq(note: int) -> float:
    """MIDI 音号 → 频率（Hz）。A4=69=440Hz。"""
    return A4_FREQ * (2.0 ** ((note - A4_NOTE) / 12.0))


def m_note_on(note: int, vel: int, ch: int = 0) -> bytes:
    return bytes([NOTE_ON | (ch & 0x0F), note & 0x7F, max(1, min(127, vel))])


def m_note_off(note: int, ch: int = 0) -> bytes:
    return bytes([NOTE_OFF | (ch & 0x0F), note & 0x7F, 0x00])


def m_vel0_as_off(note: int, ch: int = 0) -> bytes:
    """按协议：NoteOn + vel=0 也等价于 NoteOff（用于验证 RTL 这条分支）。"""
    return bytes([NOTE_ON | (ch & 0x0F), note & 0x7F, 0x00])


def m_all_notes_off(ch: int = 0) -> bytes:
    return bytes([CC | (ch & 0x0F), CC_ALL_NOTES_OFF, 0x00])


def m_cc(cc: int, val: int, ch: int = 0) -> bytes:
    """Control Change：0xB0 <cc> <value>（value 自动夹到 0..127）。"""
    return bytes([CC | (ch & 0x0F), cc & 0x7F, max(0, min(127, val))])


def m_onoff(cc: int, on: bool, ch: int = 0) -> bytes:
    """开关型 CC（踏板/滑音开关）：0 = 关，127 = 开（规范阈值 ≤63 关 / ≥64 开）。"""
    return m_cc(cc, 127 if on else 0, ch)


def glide_ms(v: int) -> int:
    """滑音时间 值 → 毫秒（约定 t = v × 4 ms）。"""
    return int(round(max(0, min(127, v)) * GLIDE_MS_PER_STEP))


def vib_hz(v: int) -> float:
    """颤音速度 值 → LFO 频率 Hz（约定 f = v × 0.1 Hz）。"""
    return round(max(0, min(127, v)) * VIB_HZ_PER_STEP, 1)


def parse_hex_bytes(text: str):
    """调试框解析：把十六进制串转成 bytes。

    接受：`90 45 64`、`0x90,0x45,0x64`、`904564`（偶数位连写）、`b0 7b 00`、`1 2 3`。
    返回 (data, err)：成功时 err 为 None。
    """
    if not text or not text.strip():
        return b"", "请先输入十六进制字节，例如 90 45 64"
    cleaned = text.replace("0x", " ").replace("0X", " ").replace(",", " ").replace(";", " ")
    out = bytearray()
    for tok in cleaned.split():
        if len(tok) <= 2:
            parts = [tok]
        elif len(tok) % 2 == 0:
            parts = [tok[i:i + 2] for i in range(0, len(tok), 2)]
        else:
            return b"", f"'{tok}' 长度不对（1~2 位，或偶数位的连续字节）"
        for p in parts:
            try:
                v = int(p, 16)
            except ValueError:
                return b"", f"'{p}' 不是合法十六进制"
            if not (0 <= v <= 255):
                return b"", f"'{p}' 超出 0..255"
            out.append(v)
    if len(out) > 64:
        return b"", "一次最多发 64 字节"
    return bytes(out), None


# ---------------------------------------------------------------- 串口层
class SerialLink:
    """串口连接的薄封装：线程安全发送 + 挂音保护。"""

    def __init__(self, on_status=None):
        self._ser = None
        self._lock = threading.Lock()
        self._active = set()            # 当前按下的音符（用于"不能留挂音"）
        self._on_status = on_status or (lambda msg, kind="info": None)
        self.sent = 0
        # 表情参数（CC 下发的当前值；连接成功后 resend_all_params() 会重发一遍）
        self.params = {
            "glide_time": 0,            # CC5   滑音时间 0..127
            "glide_on": False,          # CC65  滑音开关
            "vib_depth": 0,             # CC1/77 颤音深度
            "vib_rate": 50,             # CC76  颤音速度（50 → 5.0 Hz）
            "sustain": False,           # CC64  延音踏板
        }

    # ---- 枚举 ----
    @staticmethod
    def list_ports():
        try:
            from serial.tools import list_ports
        except ImportError:
            return []
        out = []
        for p in list_ports.comports():
            out.append((p.device, p.description or "", p.hwid or ""))
        return out

    # ---- 连接 ----
    def open(self, port: str, baud: int = 115200):
        try:
            import serial
        except ImportError:
            self._on_status("缺少 pyserial：请先安装 pyserial", "err")
            return False
        self.close(silent=True)
        try:
            self._ser = serial.Serial(port, baudrate=baud, bytesize=8,
                                      parity="N", stopbits=1, timeout=0, write_timeout=0.5)
            time.sleep(0.05)
            self._on_status(f"已连接 {port} @ {baud}", "ok")
            # 连上先清一次音，避免板子上有残留发声
            self.all_notes_off()
            return True
        except Exception as e:                      # noqa: BLE001
            self._ser = None
            self._on_status(f"打不开 {port}：{e}", "err")
            return False

    def close(self, silent: bool = False):
        if self._ser is not None:
            try:
                self.panic()                        # ★ 断开前必须【彻底】清音（含抬踏板）
                time.sleep(0.05)
            except Exception:                       # noqa: BLE001
                pass
            try:
                self._ser.close()
            except Exception:                       # noqa: BLE001
                pass
            self._ser = None
            self._active.clear()
            if not silent:
                self._on_status("已断开", "info")

    @property
    def connected(self) -> bool:
        return self._ser is not None and getattr(self._ser, "is_open", False)

    # ---- 发送 ----
    def _write(self, data: bytes):
        if not self.connected:
            return False
        try:
            with self._lock:
                self._ser.write(data)
                self._ser.flush()
                self.sent += len(data)
            return True
        except Exception as e:                      # noqa: BLE001
            self._on_status(f"发送失败：{e}", "err")
            self.close(silent=True)
            return False

    def note_on(self, note: int, vel: int):
        note = max(0, min(127, int(note)))
        if note in self._active:                    # 防重复 NoteOn（键盘自动重复）
            return
        if self._write(m_note_on(note, vel)):
            self._active.add(note)

    def note_off(self, note: int):
        note = max(0, min(127, int(note)))
        if note not in self._active:                # 没按下就不必发
            return
        if self._write(m_note_off(note)):
            self._active.discard(note)

    def all_notes_off(self):
        """协议内的 All Notes Off（0xB0 0x7B 0x00）。"""
        self._write(m_all_notes_off())
        self._active.clear()

    def panic(self):
        """兜底清音（**顺序很重要**）：
        ① 先抬踏板 CC64=0 —— 踏板踩着时 All Notes Off 可能不静音（延音还在生效）；
        ② All Notes Off CC123（协议内、RTL 已支持的那条）；
        ③ 对每个曾按下的音各发一次 NoteOff；
        ④ All Sound Off CC120 + Reset All Controllers CC121 —— 标准里最彻底的"立刻全静音 +
           重置全部表情控制器"；RTL 未实现时会被忽略，不影响前三条（前向兼容）。
        """
        self._write(m_onoff(CC_SUSTAIN, False))
        self._write(m_all_notes_off())
        for n in list(self._active):
            self._write(m_note_off(n))
        self._write(m_cc(CC_ALL_SOUND_OFF, 0))
        self._write(m_cc(CC_RESET_ALL_CTRL, 0))
        self._active.clear()
        self.params["sustain"] = False

    # ---- 表情参数下发（CC）--------------------------------------------------
    def set_glide_time(self, v: int):
        v = max(0, min(127, int(v)))
        self.params["glide_time"] = v
        self._write(m_cc(CC_PORTAMENTO_TIME, v))

    def set_glide_on(self, on: bool):
        self.params["glide_on"] = bool(on)
        self._write(m_onoff(CC_PORTAMENTO_ON, on))

    def set_vibrato_depth(self, v: int):
        v = max(0, min(127, int(v)))
        self.params["vib_depth"] = v
        # CC1（通用惯例）与 CC77（规范原文的 Vibrato Depth）**同步发送**：
        # RTL 实现任意一个都能生效，降低两边对不齐的风险。
        self._write(m_cc(CC_MOD_WHEEL, v))
        self._write(m_cc(CC_VIBRATO_DEPTH_SC, v))

    def set_vibrato_rate(self, v: int):
        v = max(0, min(127, int(v)))
        self.params["vib_rate"] = v
        self._write(m_cc(CC_VIBRATO_RATE, v))

    def set_sustain(self, on: bool):
        self.params["sustain"] = bool(on)
        self._write(m_onoff(CC_SUSTAIN, on))
        if not on:
            # ★ 踏板抬起时补发一次 All Notes Off：把"踩踏板期间松开的音"一次性放掉。
            #   标准做法是接收端自己维护"等踏板抬起再放音"，但 RTL 可能简化实现；
            #   这里补一条最保险，RTL 若已正确实现，多这一条也是幂等的。
            self._write(m_all_notes_off())

    def resend_all_params(self):
        """连接成功后把界面上当前的表情参数全部重发一遍，保证板子状态与界面一致。"""
        p = self.params
        self.set_glide_time(p["glide_time"])
        self.set_glide_on(p["glide_on"])
        self.set_vibrato_depth(p["vib_depth"])
        self.set_vibrato_rate(p["vib_rate"])
        self._write(m_onoff(CC_SUSTAIN, p["sustain"]))   # 只发踏板状态，不触发上面的补发

    def send_raw(self, data: bytes):
        """调试用：直接发送原始字节（不经 note 跟踪）。

        注意：绕过 _active 记录，所以用原始字节开的音不会出现在"正在发声"里；
        但 panic()/close() 都会先发 All Notes Off，仍能一键清干净。
        """
        return self._write(data)

    def active_notes(self):
        return sorted(self._active)


# ---------------------------------------------------------------- 界面
class PianoGUI:
    WK_W, WK_H = 46, 210            # 白键宽/高
    BK_W, BK_H = 28, 130            # 黑键宽/高
    BG = "#1b1b1f"

    def __init__(self, root, link: SerialLink, args):
        import tkinter as tk
        from tkinter import ttk

        self.tk = tk
        self.root = root
        self.link = link
        self.args = args
        self.octave = DEFAULT_OCTAVE
        self.velocity = 100
        self._down_by_key = {}      # 电脑按键 → note（防自动重复）
        self._rect_to_note = []     # (x0,y0,x1,y1,note,is_black)
        # ★ Tk 的 scale.set() 会触发 -command 回调，而回调里要用到尚未创建的控件
        #   （如 glide_lbl）⇒ 用 _ready 门闸，构造期间一律忽略回调。
        self._ready = False

        root.title("FPGA 简易钢琴 —— 电脑控制板子发声（115200 8N1 / MIDI）")
        root.configure(bg=self.BG)
        try:
            root.option_add("*Font", ("Microsoft YaHei", 10))
        except Exception:           # noqa: BLE001
            pass

        # ---------------- 顶部：串口条 ----------------
        top = tk.Frame(root, bg=self.BG)
        top.pack(fill="x", padx=10, pady=(10, 4))

        tk.Label(top, text="串口：", bg=self.BG, fg="#e8e8e8").pack(side="left")
        self.port_var = tk.StringVar()
        self.combo = ttk.Combobox(top, textvariable=self.port_var, width=34, state="readonly")
        self.combo.pack(side="left", padx=4)

        tk.Button(top, text="刷新", width=6, command=self.refresh_ports).pack(side="left", padx=2)
        self.btn_conn = tk.Button(top, text="连接", width=6, command=self.do_connect)
        self.btn_conn.pack(side="left", padx=2)
        tk.Button(top, text="断开", width=6, command=self.do_disconnect).pack(side="left", padx=2)
        tk.Button(top, text="全部停止", width=10, bg="#a33", fg="white",
                  command=self.do_panic).pack(side="left", padx=8)

        self.status = tk.Label(top, text="未连接", bg=self.BG, fg="#ffb84d")
        self.status.pack(side="left", padx=10)

        # ---------------- 第二行：力度 / 八度 ----------------
        row2 = tk.Frame(root, bg=self.BG)
        row2.pack(fill="x", padx=10, pady=2)

        tk.Label(row2, text="力度：", bg=self.BG, fg="#e8e8e8").pack(side="left")
        self.vel_scale = tk.Scale(row2, from_=1, to=127, orient="horizontal", length=180,
                                  bg=self.BG, fg="#e8e8e8", highlightthickness=0,
                                  command=self.on_vel)
        self.vel_scale.set(self.velocity)
        self.vel_scale.pack(side="left", padx=(0, 14))

        tk.Label(row2, text="八度：", bg=self.BG, fg="#e8e8e8").pack(side="left")
        tk.Button(row2, text="－ (Z)", width=8, command=lambda: self.shift_octave(-1)).pack(side="left")
        self.oct_lbl = tk.Label(row2, text="C4", bg=self.BG, fg="#7fd1ff", width=4)
        self.oct_lbl.pack(side="left")
        tk.Button(row2, text="＋ (X)", width=8, command=lambda: self.shift_octave(+1)).pack(side="left")

        self.info = tk.Label(row2, text="当前无音符", bg=self.BG, fg="#9ad", anchor="e")
        self.info.pack(side="right")

        # ---------------- 第三行：调试用【发送原始字节】 ----------------
        # 上板联调第一步就用它：手动发 90 45 64 看有没有声音。
        row3 = tk.Frame(root, bg=self.BG)
        row3.pack(fill="x", padx=10, pady=(4, 2))

        tk.Label(row3, text="调试发送(十六进制)：", bg=self.BG, fg="#e8e8e8").pack(side="left")
        self.raw_var = tk.StringVar(value="90 45 64")
        self.raw_entry = tk.Entry(row3, textvariable=self.raw_var, width=26,
                                  font=("Consolas", 10))
        self.raw_entry.pack(side="left", padx=4)
        self.raw_entry.bind("<Return>", lambda e: self.do_send_raw())
        tk.Button(row3, text="发送", width=6, command=self.do_send_raw).pack(side="left", padx=2)
        tk.Button(row3, text="A4 开", width=7,
                  command=lambda: self.send_preset("90 45 64")).pack(side="left", padx=2)
        tk.Button(row3, text="A4 关", width=7,
                  command=lambda: self.send_preset("80 45 00")).pack(side="left", padx=2)
        tk.Button(row3, text="全部停止", width=9, bg="#a33", fg="white",
                  command=self.do_panic).pack(side="left", padx=6)
        self.raw_info = tk.Label(row3, text="（点“发送”或按回车）", bg=self.BG, fg="#9ad")
        self.raw_info.pack(side="left", padx=8)

        # ---------------- 第四/五行：表情维度（赛题拓展②）----------------
        #  力度(已有) + 滑音(CC5/CC65) + 颤音深度(CC1&77) + 颤音速度(CC76) + 延音踏板(CC64)
        #  ⚠️ 这些 CC 需要 RTL 侧解析后才能听到效果；RTL 未实现时它们会被静默忽略，
        #     不影响原有的 NoteOn/NoteOff/AllNotesOff 功能（前向兼容）。
        row4 = tk.Frame(root, bg=self.BG)
        row4.pack(fill="x", padx=10, pady=(2, 1))

        tk.Label(row4, text="滑音时间：", bg=self.BG, fg="#e8e8e8").pack(side="left")
        self.glide_scale = tk.Scale(row4, from_=0, to=127, orient="horizontal", length=110,
                                    bg=self.BG, fg="#e8e8e8", highlightthickness=0,
                                    command=self.on_glide)
        self.glide_scale.set(0)
        self.glide_scale.pack(side="left")
        self.glide_lbl = tk.Label(row4, text="关", bg=self.BG, fg="#7fd1ff", width=8)
        self.glide_lbl.pack(side="left")

        self.glide_on = tk.BooleanVar(value=False)
        tk.Checkbutton(row4, text="滑音开关", variable=self.glide_on, command=self.on_glide_sw,
                       bg=self.BG, fg="#e8e8e8", selectcolor="#333",
                       activebackground=self.BG, activeforeground="#e8e8e8").pack(side="left", padx=(2, 14))

        tk.Label(row4, text="颤音深度：", bg=self.BG, fg="#e8e8e8").pack(side="left")
        self.vib_scale = tk.Scale(row4, from_=0, to=127, orient="horizontal", length=110,
                                  bg=self.BG, fg="#e8e8e8", highlightthickness=0,
                                  command=self.on_vib_depth)
        self.vib_scale.set(0)
        self.vib_scale.pack(side="left")
        self.vib_on = tk.BooleanVar(value=False)
        tk.Checkbutton(row4, text="颤音开关", variable=self.vib_on, command=self.on_vib_sw,
                       bg=self.BG, fg="#e8e8e8", selectcolor="#333",
                       activebackground=self.BG, activeforeground="#e8e8e8").pack(side="left", padx=(2, 0))

        row5 = tk.Frame(root, bg=self.BG)
        row5.pack(fill="x", padx=10, pady=(1, 2))

        tk.Label(row5, text="颤音速度：", bg=self.BG, fg="#e8e8e8").pack(side="left")
        self.vrate_scale = tk.Scale(row5, from_=0, to=127, orient="horizontal", length=130,
                                    bg=self.BG, fg="#e8e8e8", highlightthickness=0,
                                    command=self.on_vib_rate)
        self.vrate_scale.set(50)                    # 50 → 5.0 Hz（默认）
        self.vrate_scale.pack(side="left")
        self.vrate_lbl = tk.Label(row5, text="5.0 Hz", bg=self.BG, fg="#7fd1ff", width=7)
        self.vrate_lbl.pack(side="left")

        self.sus_btn = tk.Button(row5, text="延音踏板 (空格)", width=16, bg="#333", fg="white",
                                 command=self.toggle_sustain)
        self.sus_btn.pack(side="left", padx=(12, 0))

        self.expr_info = tk.Label(row5, text="滑音 关 · 颤音 关 · 踏板 关",
                                  bg=self.BG, fg="#9ad", anchor="e")
        self.expr_info.pack(side="right")

        # ---------------- 钢琴画布 ----------------
        self.canvas = tk.Canvas(root, width=10, height=self.WK_H + 30,
                                bg=self.BG, highlightthickness=0)
        self.canvas.pack(padx=10, pady=6)
        self.canvas.bind("<ButtonPress-1>", self.on_press)
        self.canvas.bind("<ButtonRelease-1>", self.on_release)
        self.canvas.bind("<B1-Motion>", self.on_drag)

        # ---------------- 底部说明 ----------------
        tip = ("鼠标点琴键 · 电脑键盘：A S D F G H J K L ; = 白键，W E T Y U O P = 黑键；"
               "Z / X = 降/升八度；空格 = 延音踏板开/关。松手即停音，关窗自动全部停止。")
        tk.Label(root, text=tip, bg=self.BG, fg="#aaa", justify="center").pack(pady=(0, 10))

        # 键盘事件
        root.bind("<KeyPress>", self.on_key_press)
        root.bind("<KeyRelease>", self.on_key_release)
        root.bind("<space>", self.on_space)                     # 空格 = 延音踏板
        root.bind("<FocusOut>", lambda e: self.do_panic())      # 失焦也清音
        root.protocol("WM_DELETE_WINDOW", self.on_close)

        self.refresh_ports()
        if args.port:
            self.port_var.set(args.port)
        self.draw_keys()
        self._ready = True                          # 控件齐了，表情回调可以生效了
        self.root.after(120, self.auto_connect_if_requested)
        if args.smoke:
            self.root.after(int(args.smoke), self.on_close)     # 自检用：N ms 后自动退出

    # ------------------------------------------------ 画琴键
    def draw_keys(self):
        c = self.canvas
        c.delete("all")
        self._rect_to_note = []
        octv = self.octave
        base = 12 * (octv + 1)                       # C(octv) 的 MIDI 号

        n_white = len(WHITE_KEYS)
        width = n_white * self.WK_W
        c.configure(width=width + 2, height=self.WK_H + 30)

        # 白键
        for i, (kb, semi, name) in enumerate(WHITE_KEYS):
            note = base + semi
            x0 = i * self.WK_W + 1
            y0 = 1
            x1 = x0 + self.WK_W - 2
            y1 = self.WK_H
            c.create_rectangle(x0, y0, x1, y1, fill="#fafafa", outline="#333", width=2)
            c.create_text((x0 + x1) / 2, y1 - 26, text=name, fill="#222",
                          font=("Microsoft YaHei", 9, "bold"))
            c.create_text((x0 + x1) / 2, y1 - 10, text=kb.upper(), fill="#666",
                          font=("Microsoft YaHei", 8))
            self._rect_to_note.append((x0, y0, x1, y1, note, False))

        # 黑键（画在白键之上 → 命中测试要先查黑键）
        for kb, semi, name in BLACK_KEYS:
            note = base + semi
            # 找到它位于哪两个白键之间
            left_white = max(i for i, (_, s, _) in enumerate(WHITE_KEYS) if s < semi)
            xc = (left_white + 1) * self.WK_W
            x0 = xc - self.BK_W / 2
            y0 = 1
            x1 = xc + self.BK_W / 2
            y1 = self.BK_H
            c.create_rectangle(x0, y0, x1, y1, fill="#111", outline="#000", width=2)
            c.create_text((x0 + x1) / 2, y1 - 22, text=name, fill="#eee",
                          font=("Microsoft YaHei", 8, "bold"))
            c.create_text((x0 + x1) / 2, y1 - 8, text=kb.upper(), fill="#bbb",
                          font=("Microsoft YaHei", 8))
            self._rect_to_note.append((x0, y0, x1, y1, note, True))

    def note_at(self, x, y):
        for (x0, y0, x1, y1, note, is_black) in self._rect_to_note:
            if is_black and x0 <= x <= x1 and y0 <= y <= y1:
                return note
        for (x0, y0, x1, y1, note, is_black) in self._rect_to_note:
            if (not is_black) and x0 <= x <= x1 and y0 <= y <= y1:
                return note
        return None

    # ------------------------------------------------ 鼠标
    def on_press(self, ev):
        n = self.note_at(ev.x, ev.y)
        if n is not None:
            self.link.note_on(n, self.velocity)
            self.update_info()

    def on_release(self, ev):
        n = self.note_at(ev.x, ev.y)
        if n is not None:
            self.link.note_off(n)
        else:
            self.link.all_notes_off()          # 移出琴键范围松手 → 兜底清音
        self.update_info()

    def on_drag(self, ev):
        n = self.note_at(ev.x, ev.y)
        if n is not None:
            self.link.note_on(n, self.velocity)
            self.update_info()

    # ------------------------------------------------ 电脑键盘
    def on_key_press(self, ev):
        k = (ev.keysym or "").lower()
        if k == "escape":
            self.on_close()
            return
        if k == "z":
            self.shift_octave(-1)
            return
        if k == "x":
            self.shift_octave(+1)
            return
        if k in self._down_by_key:              # 自动重复 → 忽略
            return
        note = self.key_to_note(k)
        if note is not None:
            self._down_by_key[k] = note
            self.link.note_on(note, self.velocity)
            self.update_info()

    def on_key_release(self, ev):
        k = (ev.keysym or "").lower()
        note = self._down_by_key.pop(k, None)
        if note is not None:
            self.link.note_off(note)
            self.update_info()

    def key_to_note(self, k):
        base = 12 * (self.octave + 1)
        for kb, semi, _ in WHITE_KEYS + BLACK_KEYS:
            if kb == k:
                return base + semi
        return None

    # ------------------------------------------------ 其它
    def shift_octave(self, d):
        new = self.octave + d
        if OCTAVE_MIN <= new <= OCTAVE_MAX:
            self.link.all_notes_off()
            self._down_by_key.clear()
            self.octave = new
            self.oct_lbl.config(text=f"C{self.octave}")
            self.draw_keys()
            self.update_info()

    def on_vel(self, v):
        self.velocity = int(float(v))

    def update_info(self):
        act = self.link.active_notes()
        if act:
            names = ", ".join(f"{n}({note_to_freq(n):.0f}Hz)" for n in act[:6])
            if len(act) > 6:
                names += f" … 共{len(act)}个"
            self.info.config(text=f"正在发声：{names}")
        else:
            self.info.config(text="当前无音符")

    def set_status(self, msg, kind="info"):
        color = {"ok": "#5ed46a", "err": "#ff6b6b", "info": "#ffb84d"}.get(kind, "#ffb84d")
        self.status.config(text=msg, fg=color)
        self.update_info()

    def refresh_ports(self):
        ports = SerialLink.list_ports()
        items = [f"{dev}  |  {desc}" for dev, desc, _ in ports]
        self.combo["values"] = items
        if items and not self.port_var.get():
            self.port_var.set(items[0])
        if not items:
            self.set_status("没找到串口（板子插好了吗？）", "err")

    def _chosen_port(self):
        v = self.port_var.get()
        return v.split("|")[0].strip() if v else ""

    def do_connect(self):
        p = self._chosen_port()
        if not p:
            self.set_status("请先选择串口", "err")
            return
        if self.link.open(p):
            self.btn_conn.config(text="已连接")
            # ★ 连上后把界面上当前的表情参数重发一遍，保证板子状态与界面一致
            self.link.resend_all_params()
            self._paint_sustain()
            self.update_expr_info()

    def do_disconnect(self):
        self.link.close()
        self.btn_conn.config(text="连接")

    def do_panic(self):
        self.link.panic()
        self._down_by_key.clear()
        if getattr(self, "_ready", False):
            self._paint_sustain()           # panic 会把踏板抬起来，界面要同步
            self.update_expr_info()
        self.update_info()

    # ---- 调试：发送原始字节 ----
    def do_send_raw(self):
        data, err = parse_hex_bytes(self.raw_var.get())
        if err:
            self.raw_info.config(text=f"× {err}", fg="#ff6b6b")
            return
        if not self.link.connected:
            self.raw_info.config(text="× 还没连接串口", fg="#ff6b6b")
            return
        ok = self.link.send_raw(data)
        if ok:
            hexs = " ".join(f"{b:02X}" for b in data)
            self.raw_info.config(text=f"已发送 {len(data)} 字节: {hexs}", fg="#5ed46a")
        else:
            self.raw_info.config(text="× 发送失败（串口可能已断开）", fg="#ff6b6b")

    def send_preset(self, text: str):
        self.raw_var.set(text)
        self.do_send_raw()

    # ---- 表情维度（滑音 / 颤音 / 延音踏板）----
    def on_glide(self, v):
        if not getattr(self, "_ready", False):
            return
        v = int(float(v))
        self.link.set_glide_time(v)
        self.glide_lbl.config(text=("关" if v == 0 else f"{glide_ms(v)} ms"))
        self.update_expr_info()

    def on_glide_sw(self):
        if not getattr(self, "_ready", False):
            return
        self.link.set_glide_on(self.glide_on.get())
        self.update_expr_info()

    def on_vib_depth(self, v):
        if not getattr(self, "_ready", False):
            return
        v = int(float(v))
        # 开关没开时一律下发 0（=关闭颤音），避免"滑到 100 但没开开关"的困惑
        self.link.set_vibrato_depth(v if self.vib_on.get() else 0)
        self.update_expr_info()

    def on_vib_sw(self):
        if not getattr(self, "_ready", False):
            return
        v = int(float(self.vib_scale.get()))
        self.link.set_vibrato_depth(v if self.vib_on.get() else 0)
        self.update_expr_info()

    def on_vib_rate(self, v):
        if not getattr(self, "_ready", False):
            return
        v = int(float(v))
        self.link.set_vibrato_rate(v)
        self.vrate_lbl.config(text=f"{vib_hz(v)} Hz")
        self.update_expr_info()

    def toggle_sustain(self):
        if not getattr(self, "_ready", False):
            return
        on = not self.link.params["sustain"]
        self.link.set_sustain(on)
        self._paint_sustain()
        self.update_expr_info()

    def on_space(self, _ev=None):
        """空格 = 延音踏板开关（return "break" 防止空格顺带触发聚焦按钮）。"""
        self.toggle_sustain()
        return "break"

    def _paint_sustain(self):
        on = self.link.params["sustain"]
        self.sus_btn.config(text=("延音踏板：开 (空格)" if on else "延音踏板 (空格)"),
                            bg=("#2f7d4f" if on else "#333"))

    def update_expr_info(self):
        p = self.link.params
        self.expr_info.config(
            text=(f"滑音 {glide_ms(p['glide_time'])}ms/{'开' if p['glide_on'] else '关'} · "
                  f"颤音深度 {p['vib_depth']} @ {vib_hz(p['vib_rate'])}Hz · "
                  f"踏板 {'开' if p['sustain'] else '关'}"))

    def auto_connect_if_requested(self):
        if self.args.autoconnect:
            self.do_connect()

    def on_close(self):
        try:
            self.link.close(silent=True)        # 内部已先发 AllNotesOff
            self.link.panic()
        except Exception:                       # noqa: BLE001
            pass
        try:
            self.root.destroy()
        except Exception:                       # noqa: BLE001
            pass


# ---------------------------------------------------------------- 自检
def selftest() -> int:
    print("=== piano_gui.py 自检（不需要界面/串口）===")
    errs = 0

    def chk(cond, name, extra=""):
        nonlocal errs
        if cond:
            print(f"[CHECK] PASS  {name}")
        else:
            print(f"[CHECK] FAIL  {name}  {extra}")
            errs += 1

    # 1. 音高换算
    chk(abs(note_to_freq(69) - 440.0) < 1e-9, "A4(69) = 440 Hz")
    chk(abs(note_to_freq(60) - 261.6255653) < 0.01, "C4(60) ≈ 261.63 Hz")
    chk(abs(note_to_freq(81) - 880.0) < 1e-9, "A5(81) = 880 Hz（高八度）")

    # 2. MIDI 消息组装（与 RTL/协议一致）
    chk(m_note_on(0x45, 0x64) == b"\x90\x45\x64", "NoteOn 字节 = 90 45 64")
    chk(m_note_off(0x45) == b"\x80\x45\x00", "NoteOff 字节 = 80 45 00")
    chk(m_vel0_as_off(0x45) == b"\x90\x45\x00", "vel=0 的 NoteOn = 90 45 00（RTL 要当 NoteOff）")
    chk(m_all_notes_off() == b"\xb0\x7b\x00", "AllNotesOff 字节 = B0 7B 00")
    chk(m_note_on(0x45, 200)[2] == 127, "力度上限被夹到 127")
    chk(m_note_on(0x45, 0)[2] == 1, "note_on 力度下限被夹到 1（0 会变成 NoteOff！）")

    # 3. 键位表
    base = 12 * (DEFAULT_OCTAVE + 1)
    whites = [base + s for _, s, _ in WHITE_KEYS]
    blacks = [base + s for _, s, _ in BLACK_KEYS]
    chk(whites == [60, 62, 64, 65, 67, 69, 71, 72, 74, 76], "白键音号 = C4..E5")
    chk(blacks == [61, 63, 66, 68, 70, 73, 75], "黑键音号 = C#4..D#5")
    chk(len(set(whites + blacks)) == len(whites) + len(blacks), "白/黑键无重复")
    allkb = [k for k, _, _ in WHITE_KEYS + BLACK_KEYS]
    chk(len(set(allkb)) == len(allkb), "电脑按键无冲突")
    chk(all(0 <= n <= 127 for n in whites + blacks), "所有音号在 0..127")

    # 3b. 调试框的十六进制解析
    chk(parse_hex_bytes("90 45 64")[0] == b"\x90\x45\x64", "调试框: '90 45 64'")
    chk(parse_hex_bytes("0x90,0x45,0x64")[0] == b"\x90\x45\x64", "调试框: '0x90,0x45,0x64'")
    chk(parse_hex_bytes("904564")[0] == b"\x90\x45\x64", "调试框: 连写 '904564'")
    chk(parse_hex_bytes("b0 7b 00")[0] == b"\xb0\x7b\x00", "调试框: 小写 'b0 7b 00'")
    chk(parse_hex_bytes("1 2 3")[0] == b"\x01\x02\x03", "调试框: 1~2 位都接受")
    chk(parse_hex_bytes("")[1] is not None, "调试框: 空输入被拒绝（有提示）")
    chk(parse_hex_bytes("zz")[1] is not None, "调试框: 非法字符被拒绝")
    chk(parse_hex_bytes("9 045")[1] is not None, "调试框: 奇数长 token 被拒绝")

    # 3c. 表情维度（拓展②）：CC 编号与字节组装（编号按 MIDI 官方 Table 3 查证）
    chk(m_cc(1, 64) == b"\xb0\x01\x40", "CC1  颤音深度 = B0 01 40")
    chk(m_cc(5, 25) == b"\xb0\x05\x19", "CC5  滑音时间 = B0 05 19")
    chk(m_cc(76, 50) == b"\xb0\x4c\x32", "CC76 颤音速度 = B0 4C 32")
    chk(m_cc(77, 64) == b"\xb0\x4d\x40", "CC77 颤音深度(SC8) = B0 4D 40")
    chk(m_onoff(64, True) == b"\xb0\x40\x7f" and m_onoff(64, False) == b"\xb0\x40\x00",
        "CC64 延音踏板 开=7F/关=00")
    chk(m_onoff(65, True) == b"\xb0\x41\x7f", "CC65 滑音开关 开=7F")
    chk(m_cc(5, 999)[2] == 127 and m_cc(5, -5)[2] == 0, "CC 数值夹到 0..127")

    # 3d. 数值→物理量 的约定映射（RTL 必须按同一约定实现）
    chk(glide_ms(0) == 0 and glide_ms(25) == 100 and glide_ms(127) == 508,
        "滑音映射 t=v*4ms (0/100/508)")
    chk(vib_hz(50) == 5.0 and vib_hz(127) == 12.7 and vib_hz(0) == 0.0,
        "颤音映射 f=v*0.1Hz (0/5.0/12.7)")

    # 3e. SerialLink 真正下发的字节与顺序（用假串口捕获，不碰真端口）
    class _FakeSer:
        def __init__(self):
            self.buf = bytearray()
            self.is_open = True

        def write(self, b):
            self.buf += b

        def flush(self):
            pass

        def close(self):
            self.is_open = False

    lk = SerialLink()
    fs = _FakeSer()
    lk._ser = fs
    lk.note_on(69, 100)
    lk.set_sustain(True)
    lk.set_glide_time(25)
    lk.set_vibrato_depth(64)          # 应同时发 CC1 与 CC77
    lk.set_vibrato_rate(50)
    chk(bytes(fs.buf) == (b"\x90\x45\x64" + b"\xb0\x40\x7f" + b"\xb0\x05\x19"
                          + b"\xb0\x01\x40" + b"\xb0\x4d\x40" + b"\xb0\x4c\x32"),
        "表情参数下发顺序与字节全对（含 CC1+CC77 同步）")

    fs.buf.clear()
    lk.panic()
    pb = bytes(fs.buf)
    chk(pb[:3] == b"\xb0\x40\x00", "panic 第 1 条先抬踏板 CC64=0（否则可能不静音）")
    chk(b"\xb0\x7b\x00" in pb, "panic 含 All Notes Off（CC123）")
    chk(pb.endswith(b"\xb0\x78\x00\xb0\x79\x00"),
        "panic 末尾 All Sound Off(CC120) + Reset All Ctrls(CC121)")
    chk(lk.params["sustain"] is False, "panic 后踏板状态归位（界面也要同步）")

    # 4. 串口枚举（不需要插板子；没串口也不算失败）
    ports = SerialLink.list_ports()
    print(f"[INFO] 本机串口 {len(ports)} 个：" + ", ".join(d for d, _, _ in ports))

    # 5. SerialLink 未连接时的安全性（不得抛异常）
    link = SerialLink()
    try:
        link.note_on(60, 100)
        link.note_off(60)
        link.all_notes_off()
        link.panic()
        link.send_raw(b"\x90\x45\x64")
        chk(True, "未连接时发送调用不抛异常（安全降级）")
    except Exception as e:                      # noqa: BLE001
        chk(False, "未连接时发送调用不抛异常", str(e))

    print("=" * 60)
    print("[RESULT] PASS  (全部检查通过)" if errs == 0 else f"[RESULT] FAIL ({errs} 项未通过)")
    return 0 if errs == 0 else 1


# ---------------------------------------------------------------- main
def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="FPGA 简易钢琴（电脑 → 串口 MIDI → 板子发声）")
    ap.add_argument("--port", default="", help="串口名，如 COM8")
    ap.add_argument("--autoconnect", action="store_true", help="启动后自动连接 --port")
    ap.add_argument("--list-ports", action="store_true", help="只列出串口后退出")
    ap.add_argument("--selftest", action="store_true", help="不开界面，自检协议/键位/音高")
    ap.add_argument("--smoke", type=int, default=0, help="启动界面 N 毫秒后自动关闭（验证能起来）")
    args = ap.parse_args(argv)

    if args.list_ports:
        for dev, desc, hwid in SerialLink.list_ports():
            print(f"{dev}\t{desc}\t{hwid}")
        return 0
    if args.selftest:
        return selftest()

    try:
        import tkinter as tk
    except ImportError as e:                    # noqa: BLE001
        print(f"[ERR] 没有 tkinter：{e}")
        return 2

    print("[INFO] 启动 FPGA 简易钢琴界面…")
    print(f"[INFO] 串口 {len(SerialLink.list_ports())} 个；协议 115200 8N1 / MIDI 3 字节")
    root = tk.Tk()
    link = SerialLink()
    app = PianoGUI(root, link, args)
    link._on_status = app.set_status              # 状态回调接到界面上
    atexit.register(link.panic)                   # ★ 进程退出兜底清音（学自 MiniDexed miditest.py）
    print("[INFO] 界面已创建：串口下拉框 + 琴键画布 + 力度/八度；等待操作…")
    try:
        root.mainloop()
    except KeyboardInterrupt:
        pass
    finally:
        link.panic()
    print("[INFO] 已退出（已发送 All Notes Off，不会留挂音）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
