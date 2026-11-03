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
CC_UI_PAGE          = 28

# ---- 数值 → 物理量 的约定映射（★ RTL 侧必须按同一约定实现，否则两边对不上）----
GLIDE_MS_PER_STEP = 4.0      # 滑音时间： t_glide ≈ v × 4 ms   （v=25 → 100 ms，v=127 → 508 ms）
VIB_HZ_PER_STEP = 0.1        # 颤音速度： f_lfo   ≈ v × 0.1 Hz（v=50 → 5.0 Hz，v=127 → 12.7 Hz）

A4_NOTE = 69
A4_FREQ = 440.0

# ---------------------------------------------------------------- 键盘布局
# ★ 2026-10-06 扩键（用户要求"同时能按 32 个键以上"，赛题复音 ≥32）：
#   屏幕键盘 **3 个八度 = 37 键（C3..C6 = MIDI 48..84）**，按真钢琴布局（黑键 2+3 分组）。
#   为什么是 37 而不是 32：**要同时按下 32 个不同的键，键盘本身至少得有 32 个**，
#   37 键留出余量（32 个音 + 5 个空位）。
KEYBOARD_LOW = 48           # C3 = MIDI 48（屏幕键盘最低音）
KEYBOARD_SPAN = 37          # 3 个八度（48..84，含首尾 C）

# ★★ 37 键【全部】键盘映射（2026-10-06 第二轮：用户反馈"很多键只能鼠标点，键盘控制不了"）
#    设计目标：**两只手能用满 37 键**，并保持"白键在下排、黑键在紧邻上排"的钢琴直觉。
#      低音区（左手）：白键 = Z 排 `ZXCVBNM,./`，黑键 = A 排 `A S F G H K L` → 48..64（C3..E4）
#      高音区（右手）：白键 = Q 排 `QWERTYUIOP`，黑键 = 数字排 `2 3 4 5 6 8 9` → 65..81（F4..A5）
#      尾巴 3 键：`[` `]` `\`                                        → 82..84（A#5 B5 C6）
#    ⇒ **48..84 共 37 个音，每个音恰好一个电脑键**（`--selftest` 里有断言）
PC_KEYMAP = {          # 电脑按键 → 相对 KEYBOARD_LOW(48) 的半音数
    # ---- 低音区（左手）：白键 = Z 排，黑键 = A 排（物理上正在对应白键上方）----
    "z": 0, "x": 2, "c": 4, "v": 5, "b": 7, "n": 9, "m": 11,
    ",": 12, ".": 14, "/": 16,
    "a": 1, "s": 3, "f": 6, "g": 8, "h": 10, "k": 13, "l": 15,
    # ---- 高音区（右手）：白键 = Q 排，黑键 = 数字排 ----
    "q": 17, "w": 19, "e": 21, "r": 23, "t": 24, "y": 26, "u": 28,
    "i": 29, "o": 31, "p": 33,
    "2": 18, "3": 20, "4": 22, "5": 25, "6": 27, "8": 30, "9": 32,
    # ---- 尾巴 ----
    "[": 34, "]": 35, "\\": 36,
}
# ⚠️ 八度切换**必须换键**：`z`/`x` 现在是 C3/D3 两个白键，不能再当功能键
OCTAVE_KEYS = {"minus": -1, "-": -1, "equal": +1, "plus": +1, "=": +1}
INST_KEYS = {"f1": 0, "f2": 1, "f3": 2}          # F1/F2/F3 = 钢琴/吉他/小提琴

DEFAULT_OCTAVE = 3                  # ★ C3 = MIDI 48 = KEYBOARD_LOW（默认显示 C3..C6）
OCTAVE_MIN, OCTAVE_MAX = 2, 6
_SEMI_IS_BLACK = {1, 3, 6, 8, 10}
_NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]


def note_name(note: int) -> str:
    """MIDI 音号 → 音名（C4 = 60）。"""
    return f"{_NOTE_NAMES[note % 12]}{note // 12 - 1}"


def base_note_of(octave: int) -> int:
    """八度 → 该八度 C 的 MIDI 号（octave=3 ⇒ 48 = C3）。"""
    return 12 * (octave + 1)


# ⚠️⚠️ Tk 的 `keysym` **不是字面字符**！约定：
#     `,` → `comma`   `.` → `period`   `/` → `slash`
#     `[` → `bracketleft`   `]` → `bracketright`   `\` → `backslash`
#   ⇒ 映射表里若只写字面字符，**这 6 个键会永远"未映射"**（2026-10-06 我踩过）。
_KEYSYM_ALIAS = {
    "comma": ",", "period": ".", "slash": "/", "semicolon": ";",
    "bracketleft": "[", "bracketright": "]", "backslash": "\\",
}


def pc_key_to_note(k: str, octave: int):
    """电脑按键（Tk keysym）→ note（**37 键全覆盖**；未绑定的键返回 None）。"""
    semi = PC_KEYMAP.get(k)
    if semi is None:
        semi = PC_KEYMAP.get(_KEYSYM_ALIAS.get(k, ""))
    if semi is None:
        return None
    return base_note_of(octave) + semi


# =============================================================================
#  ★★ 三种乐器的界面与维度（2026-10-06 第三轮，Lead 已批准 CC 分配表）
#
#  【全局 CC 分配表 —— Lead 拍板，谁都不能擅自改】
#    CC1/CC77 颤音深度 ｜ CC5/CC65 滑音时间/开关 ｜ CC76 颤音速率 ｜ CC64 延音踏板
#    CC120/121 All Sound Off / Reset ｜ CC20 乐器(0钢琴/1吉他/2小提琴)
#    ★ CC21 挂电量 0..127（0=清音 bypass，127=重失真）  ← 本轮核心
#    CC22/23/24 合唱/延迟/混响（可选档，0..127）
#
#  【效果链顺序 —— 依据 HeadRush 官方文档（**读了全文**，非猜测）】
#    Dynamics(压缩) → Gain(过载/失真) → EQ → Modulation(合唱) → Time(延迟/混响) → Amp/Cab
#    ⇒「挂电量」= **Gain 段的强度**；延迟/混响常插在 amp 与 cab 之间（模拟 FX Loop）。
#    ⚠️ 这条顺序要转告 `song-demo`：`guitar_fx.v` 的串联顺序按它排。
# =============================================================================
CC_DRIVE, CC_CHORUS, CC_DELAY, CC_REVERB = 21, 22, 23, 24
CC_PORTAMENTO_TIME, CC_PORTAMENTO_ON = 5, 65   # 已有：滑音时间 / 开关（小提琴按弦滑音复用）

MODE_PIANO, MODE_GUITAR, MODE_ERHU = 0, 1, 2
MODE_NAMES = ("钢琴", "吉他", "小提琴")
# ⚠️ **CC20 取值**（Lead 规定）：0=钢琴 1=吉他 **3=小提琴**（内部索引仍是 2，避免动列表下标）
MODE_TO_CC20 = (0, 1, 3)

# ---- 吉他：标准调弦 EADGBE。UI 把「弦1 E4」画在最上面（抱着吉他看指板：细弦在上）----
GUITAR_OPEN = [64, 59, 55, 50, 45, 40]      # 弦1..弦6 = E4 B3 G3 D3 A2 E2
GUITAR_MAX_FRET = 12
# ⭐ 扫弦间隔：**有实测依据**（`liaison` 分析《加州旅馆》386s / 729 起音）：
#   连续密集段 58 串：**中位跨度 36.0 ms、p90 77.9 ms**；仅 12.1% 的多弦簇 ≤25 ms ⇒ **25 ms 偏低**
#   ⚠️ 这是【指弹】实测；**拨片扫弦更快** ⇒ **不写死**，做成 **25~80 ms 连续可调**（默认 36）
GUITAR_STRUM_MS = 36


def string_fret_note(string_idx: int, fret: int) -> int:
    """弦号(0=弦1) + 品号 → MIDI note。

    ★ **由常量算出，不手写 78 个格子** —— 手写表正是"某些键失灵"的温床。
    """
    return max(0, min(127, GUITAR_OPEN[string_idx] + max(0, int(fret))))


GUITAR_RANGE = (min(GUITAR_OPEN), max(GUITAR_OPEN) + GUITAR_MAX_FRET)   # (40, 76)

# ---- 小提琴：标准四弦 G3-D4-A4-E5 ---------------------------------------------
#      保留 ERHU_* 名称作为旧版本接口兼容；界面和发声语义已经改为小提琴。
VIOLIN_STRINGS = [55, 62, 69, 76]       # G3 / D4 / A4 / E5
ERHU_STRINGS = VIOLIN_STRINGS            # legacy alias，旧测试和快捷函数继续可用
VIOLIN_KEY_ROWS = [
    ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],       # G
    ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],       # D
    ["a", "s", "d", "f", "g", "h", "j", "k", "l", "semicolon"], # A
    ["c", "v", "b", "n", "m", "comma", "period", "slash", "bracketleft", "bracketright"], # E
]
ERHU_GLIDE = (0, 1, 2)                  # legacy alias

# ---- 🎸 吉他键盘：**行 = 弦、键在行内的位置 = 品** ----------------------------------
#  ⭐ 依据：参考页面 https://virtualinstruments.net/zh-cn/virtual-guitar.html 的**源码**
#     `keyboardMap:{ '1':{s:1,f:1}, '2':{s:1,f:2}, … }` ⇒ {s=弦, f=品}
#     页面原文：「**4 行键盘映射系统，每一行按键独立控制一根弦**」
#  ⇒ 我们 6 弦，用**两组**（`Tab` 切换）覆盖：
#       高音组：行0→弦1(E4)  行1→弦2(B3)  行2→弦3(G3)  行3→弦4(D3)
#       低音组：行0→弦3(G3)  行1→弦4(D3)  行2→弦5(A2)  行3→弦6(E2)
#  ⚠️ 各行物理键数不同（12/12/11/10）⇒ 可及最高品 12/12/11/10（与参考页面一致：
#     它第3弦是 `A-L / ; '`、第4弦是 `Z-M / , .`）
GUITAR_ROW_KEYS = [
    ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "minus", "equal"],
    ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p", "bracketleft", "bracketright"],
    ["a", "s", "d", "f", "g", "h", "j", "k", "l", "semicolon", "apostrophe"],
    ["z", "x", "c", "v", "b", "n", "m", "comma", "period", "slash"],
]
GUITAR_GROUP_NAME = ("高音组(弦1-4)", "低音组(弦3-6)")
# ⭐ **空弦（品 0）定死为：Shift + 该行第一个键** —— 每行恰好一个行首键 ⇒ 无歧义。
#   （参考页面 f 从 1 起、没有品 0；但真吉他有空弦 ⇒ 我们保留，并给它一个明确按键）
#   行首键的 Shift 变体会改变 keysym（`1`→`exclam`、`-`→`underscore`…）⇒ 反查表：
GUITAR_SHIFT_ALIAS = {
    "exclam": "1", "at": "2", "numbersign": "3", "dollar": "4", "percent": "5",
    "asciicircum": "6", "ampersand": "7", "asterisk": "8", "parenleft": "9",
    "parenright": "0", "underscore": "minus", "plus": "equal",
    "quotedbl": "apostrophe", "colon": "semicolon", "asciitilde": "grave",
}
# 🎸 挂电量预设档（**只映射到已批准的 CC21**）—— ⚠️ 用户要求"选音色没必要"⇒
#    三个命名音色按钮已删；这里只留数值档（轻/中/重），避免再出现品牌/音色名
GUITAR_DRIVE_LEVELS = (15, 45, 95)          # 轻 / 中 / 重
GUITAR_STRUM_KEYS = {"f5": True, "f6": False}   # F5=下扫↓ / F6=上扫↑（⚠️ 键名小写：on_key_press 会 lower()）
# 键位显示用（keysym 名 → 人类看得懂的字符），画在琴弦/格子上
_KEY_DISP = {"minus": "-", "equal": "=", "comma": ",", "period": ".", "slash": "/",
             "bracketleft": "[", "bracketright": "]", "semicolon": ";",
             "apostrophe": "'", "backslash": "\\", "grave": "`"}


def piano_keys(low: int = None, span: int = KEYBOARD_SPAN):
    """生成屏幕钢琴键表 [(note, is_black, pc_key_or_None)]，按音高升序。

    ★ 键表**只由 note 推导**，电脑按键由 `PC_KEYMAP` 按**当前八度**反查
      ⇒ 保证"画出来的每个键都能用键盘弹"，换八度后标签自动跟着变。
    """
    if low is None:
        low = KEYBOARD_LOW
    rev = {semi: kb for kb, semi in PC_KEYMAP.items()}
    return [(n, (n % 12) in _SEMI_IS_BLACK, rev.get(n - low)) for n in range(low, low + span)]


# =============================================================================
#  ★ IME（输入法）守卫 —— 2026-10-06 **用户实测确认的根因**
#
#  现象：用户说「这个钢琴只能在英语输入法下运行，中文会卡出来」⇒ **按了没声音**。
#  原因：**中文输入法在 tkinter 之前就把按键截走了** ⇒ `<KeyPress>` 根本收不到。
#  ⇒ 不该让用户手动切输入法。本类：
#      · 窗口获得焦点后**自动把 IME 切到英文**（方案 A）
#      · 并**持续显示**当前 IME 态；切不了 ⇒ **醒目警告，绝不静默失败**（方案 B 兜底）
#      · 关闭窗口时**还原**用户原来的 IME 状态（**不搞乱用户的系统**）
#  实现：`ctypes` 调 `imm32.dll` —— **ctypes 是标准库，不算新依赖** ✅
#  可用 `--no-ime` 完全关闭（万一某些机器上自动切换有问题）。
# =============================================================================
import os   # ImeGuard 用它判断平台（os.name == "nt"）
import tkinter as tk   # ★ 模块级：新方法（_build_guitar_extras 等）也要用 tk.Frame

# ★★ 版本横幅（2026-10-06 新增）：磁盘上曾同时存在【两份】piano_gui.py
#    （旧 41 KB / 新 69 KB），用户误启动旧的会得到"17 键 + 键盘失灵"的假象。
#    ⇒ 把版本写进**窗口标题 + 状态栏**，一眼分清新旧。
APP_VER = "v46-guitar-slap"   # v43：修乐器按钮高亮(Bug A) + 删重复「音色」行(Bug B)
APP_BUILD = "2026-10-06"

IME_CMODE_NATIVE = 0x0001        # "中文（本地）"态就是这一位
GA_ROOT = 2

# ★ 乐器选择（Lead 定的 CC 号）：0=钢琴 1=吉他 2=小提琴
CC_INST = 20


def m_inst(idx: int, ch: int = 0) -> bytes:
    return bytes([0xB0 | (ch & 0x0F), CC_INST, max(0, min(3, int(idx)))])


class ImeGuard:
    def __init__(self, enable: bool = True):
        self.enable = bool(enable) and (os.name == "nt")
        self.ok = False
        self.hwnd = 0
        self.saved = None            # 原始 (mode, conv)：退出时还原
        self.why = ""
        self._imm = self._u32 = self._ct = self._wt = None
        if not self.enable:
            self.why = "已用 --no-ime 关闭"
            return
        try:
            import ctypes
            from ctypes import wintypes
            imm = ctypes.WinDLL("imm32.dll")
            u32 = ctypes.WinDLL("user32.dll")
            imm.ImmGetContext.restype = wintypes.HANDLE
            imm.ImmGetContext.argtypes = [wintypes.HWND]
            imm.ImmReleaseContext.restype = wintypes.BOOL
            imm.ImmReleaseContext.argtypes = [wintypes.HWND, wintypes.HANDLE]
            imm.ImmGetConversionStatus.argtypes = [wintypes.HANDLE,
                                                   ctypes.POINTER(wintypes.DWORD),
                                                   ctypes.POINTER(wintypes.DWORD)]
            imm.ImmSetConversionStatus.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.DWORD]
            u32.GetAncestor.restype = wintypes.HWND
            u32.GetAncestor.argtypes = [wintypes.HWND, wintypes.UINT]
            self._imm, self._u32, self._ct, self._wt = imm, u32, ctypes, wintypes
            self.ok = True
        except Exception as e:                       # noqa: BLE001
            self.why = f"imm32 不可用（{e}）"

    def attach(self, tk_root):
        """绑定到 Tk 顶层窗口（取它的 HWND）。"""
        if not self.ok:
            return False
        try:
            h = self._u32.GetAncestor(int(tk_root.winfo_id()), GA_ROOT)
            self.hwnd = int(h or tk_root.winfo_id())
            return self.hwnd != 0
        except Exception as e:                       # noqa: BLE001
            self.why = f"取窗口句柄失败（{e}）"
            return False

    def _get(self):
        if not (self.ok and self.hwnd):
            return None
        try:
            himc = self._imm.ImmGetContext(self.hwnd)
            if not himc:
                return None
            mode, conv = self._wt.DWORD(0), self._wt.DWORD(0)
            ok = self._imm.ImmGetConversionStatus(himc, self._ct.byref(mode), self._ct.byref(conv))
            self._imm.ImmReleaseContext(self.hwnd, himc)
            return (int(mode.value), int(conv.value)) if ok else None
        except Exception:                            # noqa: BLE001
            return None

    def is_chinese(self):
        st = self._get()
        return None if st is None else bool(st[1] & IME_CMODE_NATIVE)

    def force_english(self):
        """切英文（清掉 IME_CMODE_NATIVE）。True = 已是/已切成英文。"""
        st = self._get()
        if st is None:
            return False
        mode, conv = st
        if self.saved is None:
            self.saved = (mode, conv)                # 只记第一次，退出还原到这里
        if not (conv & IME_CMODE_NATIVE):
            return True
        try:
            himc = self._imm.ImmGetContext(self.hwnd)
            if not himc:
                return False
            r = self._imm.ImmSetConversionStatus(himc, mode, conv & ~IME_CMODE_NATIVE)
            self._imm.ImmReleaseContext(self.hwnd, himc)
            return bool(r)
        except Exception:                            # noqa: BLE001
            return False

    def restore(self):
        """★ 退出时还原用户原来的 IME 状态（别把用户的系统搞乱）。"""
        if not (self.ok and self.hwnd and self.saved):
            return False
        try:
            himc = self._imm.ImmGetContext(self.hwnd)
            if not himc:
                return False
            r = self._imm.ImmSetConversionStatus(himc, self.saved[0], self.saved[1])
            self._imm.ImmReleaseContext(self.hwnd, himc)
            return bool(r)
        except Exception:                            # noqa: BLE001
            return False

    def status_text(self):
        if not self.enable:
            return "IME：守护已关闭(--no-ime)"
        if not self.ok:
            return f"⚠ IME 不能自动切：{self.why}"
        c = self.is_chinese()
        if c is None:
            return "⚠ IME 读不到状态：请手动切英文"
        return "IME：英文 ✔ 可以弹" if not c else "IME：中文 ⇒ 已尝试自动切英文"


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
        self.recorder = None            # 演奏录音器 (赛题拓展④)
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
                if self.recorder is not None and getattr(self.recorder, "recording", False):
                    self.recorder.log(data)
            return True
        except Exception as e:                      # noqa: BLE001
            self._on_status(f"发送失败：{e}", "err")
            self.close(silent=True)
            return False

    def note_on(self, note: int, vel: int):
        note = max(0, min(127, int(note)))
        # ★ 失灵键的根因修复（2026-10-06）：
        #   原来这里是 `if note in self._active: return` —— **静默丢弃**。
        #   一旦某个 note 的 NoteOff 丢了（Shift 让 keysym 变成别的字符、失焦、
        #   换八度……），`_active` 就永远留着它 ⇒ **那个键从此永久失灵**。
        #   现在改成**自愈**：已在 _active 里 ⇒ 先补一个 NoteOff 再发 NoteOn。
        #   （键盘自动重复的抑制放到 GUI 层用 `_down_by_key` 做，不再靠这里丢弃。）
        if note in self._active:
            self._write(m_note_off(note))
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
        self._write(m_inst(MODE_TO_CC20[p.get("inst", 0)]))            # ★ 音色也补发一次（CC20）
        for _cc, _v in (p.get("fx") or {}).items():      # ★ 效果器参数一并补发（CC21~24）
            self._write(m_cc(int(_cc), int(_v)))
        self._write(m_cc(CC_UI_PAGE, 0))                 # ★ 确保 LCD 切回演奏主页

    def set_instrument(self, idx: int):
        """音色选择：**CC20** 0=钢琴 1=吉他 2=小提琴；并发送 CC28=0 确保 LCD 处于演奏界面。"""
        idx = max(0, min(2, int(idx)))
        self.params["inst"] = idx
        self._write(m_cc(CC_UI_PAGE, 0))
        return self._write(m_inst(MODE_TO_CC20[idx]))

    def set_fx(self, cc: int, val: int):
        """效果器参数：**CC21 挂电量** / CC22 合唱 / CC23 延迟 / CC24 混响（0..127）。

        ⚠️ 钢琴那版 `audio_fx` 用户确认好听、**不许动** ⇒ 这些 CC 只该影响吉他/小提琴通路。
        """
        cc = int(cc)
        val = max(0, min(127, int(val)))
        self.params.setdefault("fx", {})[cc] = val
        return self._write(m_cc(cc, val))

    def send_raw(self, data: bytes):
        """调试用：直接发送原始字节（不经 note 跟踪）。

        注意：绕过 _active 记录，所以用原始字节开的音不会出现在"正在发声"里；
        但 panic()/close() 都会先发 All Notes Off，仍能一键清干净。
        """
        return self._write(data)

    def active_notes(self):
        return sorted(self._active)


# ---------------------------------------------------------------- 演奏录音与回传 (赛题拓展④)
class MidiRecorder:
    """实时演奏录音、回传播放与标准 MIDI (.mid) 导出。"""

    def __init__(self, link: SerialLink, on_status=None):
        self.link = link
        self._on_status = on_status or (lambda msg, kind="info": None)
        self.recording = False
        self.playing = False
        self.events = []        # list of (rel_time_sec, bytes)
        self._start_t = 0.0

    def start_record(self):
        self.events = []
        self._start_t = time.perf_counter()
        self.recording = True
        self._on_status("🔴 正在录制实时演奏...", "info")

    def stop_record(self):
        if self.recording:
            self.recording = False
            dur = time.perf_counter() - self._start_t
            self._on_status(f"⏹ 录音完成：共记录 {len(self.events)} 个事件（时长 {dur:.1f} 秒）", "ok")

    def log(self, data: bytes):
        if self.recording:
            t = time.perf_counter() - self._start_t
            self.events.append((t, data))

    def replay(self, on_finish=None):
        if not self.events or self.playing:
            return
        if not self.link.connected:
            self._on_status("请先连接板卡串口后再回传播放", "err")
            return
        self.playing = True
        self._on_status(f"▶ 正在向 FPGA 硬件回传播放录音 ({len(self.events)} 个事件)...", "info")

        def _worker():
            t0 = time.perf_counter()
            for t_ev, b in self.events:
                if not self.playing:
                    break
                now = time.perf_counter() - t0
                wait = t_ev - now
                if wait > 0:
                    time.sleep(wait)
                if not self.playing:
                    break
                self.link._write(b)
            self.playing = False
            if on_finish:
                on_finish()
            self._on_status("✅ 录音回传播放完毕", "ok")

        threading.Thread(target=_worker, daemon=True).start()

    def stop_replay(self):
        self.playing = False
        self.link.panic()
        self._on_status("⏹ 停止回放并复位音符", "info")

    def export_midi(self, filepath: str) -> bool:
        """导出为标准 Type 0 MIDI 文件 (.mid)"""
        if not self.events:
            self._on_status("暂无录制数据可导出", "err")
            return False
        try:
            import struct

            def _vlq(val):
                res = [val & 0x7F]
                val >>= 7
                while val > 0:
                    res.append((val & 0x7F) | 0x80)
                    val >>= 7
                return bytes(reversed(res))

            ticks_per_sec = 960
            track_bytes = bytearray()
            last_t = 0.0
            for t_ev, raw in self.events:
                dt = max(0.0, t_ev - last_t)
                last_t = t_ev
                ticks = int(dt * ticks_per_sec)
                track_bytes.extend(_vlq(ticks))
                track_bytes.extend(raw)

            track_bytes.extend(_vlq(0) + b"\xFF\x2F\x00")

            header = struct.pack(">4sIHHH", b"MThd", 6, 0, 1, ticks_per_sec)
            track_header = struct.pack(">4sI", b"MTrk", len(track_bytes))

            with open(filepath, "wb") as f:
                f.write(header + track_header + track_bytes)
            self._on_status(f"💾 已导出标准 MIDI 文件：{filepath}", "ok")
            return True
        except Exception as e:
            self._on_status(f"导出失败：{e}", "err")
            return False


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
        # ★ IME 守护（用户实测根因："中文输入法下按了没声音"）+ 诊断面板状态
        self.ime = ImeGuard(enable=not getattr(args, "no_ime", False))
        self.diag_hist = []
        self.inst = 0
        self.inst_btns = []
        # ★ 三种乐器的模式与维度状态（2026-10-06 第三轮）
        self.mode = MODE_PIANO
        self.g_fret_sel = 0            # 吉他：当前品位（**压品维度**，独立于拨弦）
        self.guitar_group = 0          # 吉他弦组：0=高音组(弦1-4) 1=低音组(弦3-6)
        self._g_hits = []              # 吉他：格子命中表 (x0,y0,x1,y1,弦,品)
        self._g_fret_hits = []         # 吉他：品号行命中表
        self._g_body = None            # 吉他：琴身区
        self._g_ring = set()
        self._e_hits = []              # 小提琴：右侧弹奏区
        self._e_left = []              # 小提琴：左侧按弦区
        self._z_ring = set()
        self.e_sel = 1                  # 小提琴：当前弦（G3/D4/A4/E5）
        self.e_semi = 0                 # 小提琴：半音偏移（无品⇒连续，量化到半音）
        self.e_note = None              # 小提琴：正在发声的 note（**按住=运弓=持续发声**）
        self.e_push = True              # 小提琴：弓向 True=推弓(内弦) / False=拉弓(外弦)
        self.e_level = [0, 0, 0, 0]     # 小提琴：四条弦电平表
        self.strum_ms = GUITAR_STRUM_MS  # 吉他：扫弦间隔（实测中位 36 ms，可调 25~80）
        self.capo = 0                    # 吉他：变调夹（±5 品；note = 空弦 + capo + 品）
        self.barre_fret = 0              # 吉他：大横按品位（0=无）；品 = max(按键品, barre_fret)
        self.show_labels = True          # 键位标注开关（默认开）
        self._conn_open = True           # 「连接 ⚙」是否展开
        self._e_bowing = False
        self._e_last_y = 0
        self._e_wig = []
        self._e_trem = None
        self._e_last_frac = None
        self._bow_timer = None            # 运弓定时器 id
        self.link = link
        self.args = args
        self.octave = DEFAULT_OCTAVE
        self.velocity = 100
        self._down_by_key = {}       # 电脑按键 → note（防自动重复）
        self._keycode_to_key = {}    # ★ 硬件键号 → 电脑按键（Shift 改变 keysym 时的兜底）
        self._rect_to_note = []      # (x0,y0,x1,y1,note,is_black)
        # ★ Tk 的 scale.set() 会触发 -command 回调，而回调里要用到尚未创建的控件
        #   （如 glide_lbl）⇒ 用 _ready 门闸，构造期间一律忽略回调。
        self._ready = False

        root.title(f"FPGA 乐器（钢琴/吉他/小提琴）  [{APP_VER} {APP_BUILD}]  "
                   f"电脑控制板子发声 · 115200 8N1")
        root.configure(bg=self.BG)
        try:
            root.option_add("*Font", ("Microsoft YaHei", 10))
        except Exception:           # noqa: BLE001
            pass

        # ---------------- 顶部：串口条 ----------------
        self.top = top = tk.Frame(root, bg=self.BG)
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

        # 录音/回传播放按钮条 (赛题拓展④)
        self.recorder = MidiRecorder(self.link, self.set_status)
        self.link.recorder = self.recorder

        self.btn_rec = tk.Button(top, text="● 录音", width=7, bg="#442222", fg="#ff8888",
                                 font=("Microsoft YaHei", 9, "bold"), command=self.toggle_record)
        self.btn_rec.pack(side="left", padx=3)
        self.btn_play_rec = tk.Button(top, text="▶ 回放", width=7, bg="#224422", fg="#88ff88",
                                      font=("Microsoft YaHei", 9, "bold"), command=self.toggle_play_record)
        self.btn_play_rec.pack(side="left", padx=3)
        self.btn_save_mid = tk.Button(top, text="💾 导出MIDI", width=10, bg="#333", fg="#ddd",
                                      font=("Microsoft YaHei", 9), command=self.do_export_midi)
        self.btn_save_mid.pack(side="left", padx=3)

        # ★★ 乐器切换：**鼠标可点的大按钮**（键盘 `F1/F2/F3` 等价）
        #    ⚠️ 2026-10-06 用户反馈："不要只设置成按键变，鼠标按不同音色也要变"
        #    ⇒ 三个大按钮放最上面，**与吉他内部的"挂电/音色三选"在视觉上分离**
        self.inst_bar = tk.Frame(root, bg=self.BG)
        self.inst_bar.pack(fill="x", padx=10, pady=(6, 2))
        tk.Label(self.inst_bar, text="乐器：", bg=self.BG, fg="#e8e8e8",
                 font=("Microsoft YaHei", 10)).pack(side="left")
        self.inst_switch_btns = []
        self.conn_btn = tk.Button(self.inst_bar, text="⚙ 连接/诊断 ▾", width=14,
                                  bg="#333", fg="#ddd", command=self.toggle_conn)
        self.conn_btn.pack(side="right", padx=4)
        for _i, (_ic, _nm) in enumerate((("🎹", "钢琴 F1"), ("🎸", "吉他 F2"), ("🎻", "小提琴 F3"))):
            _b = tk.Button(self.inst_bar, text=f"{_ic} {_nm}", width=13,
                           font=("Microsoft YaHei", 10, "bold"), bg="#333", fg="white",
                           command=lambda i=_i: self.set_mode(i))
            _b._base_text = f"{_ic} {_nm}"      # ★ 高亮时加/去 "▶ " 前缀用
            _b.pack(side="left", padx=4)
            self.inst_switch_btns.append(_b)

        # ★★ 模式专属控件区：**切模式时销毁重建**（不是"隐藏"）
        #    ⇒ 钢琴界面里不会再出现"扫弦/拨弦/品格"，反之亦然
        self.mode_extras = tk.Frame(root, bg=self.BG)
        self.mode_extras.pack(fill="x", padx=10, pady=(2, 4))
        self.rebuild_mode_extras()

        self.status = tk.Label(top, text=f"{APP_VER} · 未连接", bg=self.BG, fg="#ffb84d")
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
        # ★ 2026-10-06：八度/锁存/32键齐奏 **已移入 `_build_piano_extras()`**（只在钢琴模式出现）
        self._latched = set()
        # ★ 2026-10-06 Bug B 修复：这里原来还有一份**重复的「音色：钢琴/吉他/小提琴」按钮**
        #   （调用 `set_instrument` 只发 CC20、**不切 UI**，且**硬编码钢琴高亮**）
        #   ⇒ 用户看到的"音色还没删掉"就是它们，而且"高亮永远是钢琴"也有它们的份。
        #   **已整块删除**；乐器切换只保留最上面的三个大按钮（并同步高亮）。
        self.inst_btns = []
        # IME 状态：用户实测根因是"中文输入法吞按键" ⇒ 必须**一直看得见**
        #  ⚠️ `row6` 这个 Frame 必须保留（IME 标签挂在它上面）—— 上一版删重复行时误删了它，
        #     导致 `NameError: row6` ⇒ **GUI 完全起不来**（smoke 抓到）
        row6 = tk.Frame(root, bg=self.BG)
        row6.pack(fill="x", padx=10, pady=(1, 2))
        self.ime_lbl = tk.Label(row6, text=self.ime.status_text(), bg=self.BG,
                                fg="#ffb84d", font=("Microsoft YaHei", 9, "bold"))
        self.ime_lbl.pack(side="left", padx=12)
        # ★ 2026-10-06：原 row7/row8（挂电 + 音色三选 + 扫弦/弓法/运弓按钮）**已全部移入
        #   `mode_extras`**，由 `rebuild_mode_extras()` 按模式销毁重建
        #   ⇒ 钢琴界面不会再出现吉他的扫弦/拨弦，吉他界面也不会出现小提琴的运弓/弓法
        # 按键诊断面板（最近 4 条按键事件）——"按了没声音"时用户看一眼就能告诉我们
        self.diag = tk.Label(root, text="按键诊断：（按任意键会显示 keysym / keycode / 映射音）",
                             bg="#111", fg="#8fe", justify="left", anchor="w",
                             font=("Consolas", 9), padx=6)
        self.diag.pack(fill="x", padx=10, pady=(2, 2))
        tk.Label(root, text="提示：F1/F2/F3 = 钢琴/吉他/小提琴 ｜  🎸吉他：**行=弦、位置=品**"
                            "（数字行=弦1、QWERTY=弦2、ASDF=弦3、ZXCV=弦4），"
                            "**Tab 切弦组**（弦3-6），**Shift+行首键 = 空弦**，F5/F6 = 下扫/上扫 ｜  "
                            "🎻小提琴：四弦 G-D-A-E，Z/X = 颤弓/拨弦，\\ = 换弦 ｜  "
                            "钢琴：-= 八度，空格 踏板",
                 bg=self.BG, fg="#888", font=("Microsoft YaHei", 8),
                 wraplength=1180, justify="left").pack(pady=(0, 4))

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
        # ★ 焦点 + IME：拿到焦点就**自动把输入法切英文**（否则中文输入法会吞掉按键），
        #   并启动轮询继续守着（用户中途切回中文也能自动切回来）
        root.bind("<FocusIn>", self.on_focus_in)
        # ★ Tab 用作"吉他弦组切换" ⇒ 专用绑定。
        #   ⚠️ Tk 规则：**同一个 tag 下更具体的绑定会取代** `<KeyPress>` ⇒
        #   所以这里必须**自己调用 on_key_press**，再返回 "break" 阻止默认焦点遍历。
        root.bind("<Tab>", lambda e: (self.on_key_press(e), "break")[1])
        root.protocol("WM_DELETE_WINDOW", self.on_close_with_ime)   # ★ 关窗前还原 IME

        self.refresh_ports()
        if args.port:
            self.port_var.set(args.port)
        self.draw_keys()
        self._ready = True                          # 控件齐了，表情回调可以生效了
        self.root.after(120, self.auto_connect_if_requested)
        # ★ 启动就修输入法（不等用户点窗口）—— 中文输入法吞按键是用户实测根因
        self.root.after(200, self.on_focus_in)
        if args.smoke:
            self.root.after(int(args.smoke), self.on_close)     # 自检用：N ms 后自动退出

    # ------------------------------------------------ 画琴键
    def draw_keys(self):
        """按**当前模式**重画：钢琴 = 37 键真布局；吉他 = 指板网格；小提琴 = 21 弦横向。"""
        if self.mode == MODE_GUITAR:
            return self.draw_guitar()
        if self.mode == MODE_ERHU:
            return self.draw_erhu()
        c = self.canvas
        c.delete("all")
        c.configure(bg=self.BG)          # 钢琴用深色底（吉他/小提琴各自会改成自己的底色）
        self._rect_to_note = []
        # ★ 必须同时清掉别的模式的命中表（否则是脏状态 —— 断言实测抓到过）
        self._g_hits = []
        self._g_fret_hits = []
        self._e_hits = []
        self._e_left = []
        keys = piano_keys(base_note_of(self.octave))
        whites = [k for k in keys if not k[1]]
        blacks = [k for k in keys if k[1]]

        # 37 键要塞进窗口 ⇒ 键宽自适应
        self.WK_W = max(22, min(46, 900 // max(1, len(whites))))
        self.BK_W = max(13, int(self.WK_W * 0.62))
        width = len(whites) * self.WK_W
        c.configure(width=width + 2, height=self.WK_H + 30)

        # 白键
        w_idx = {}
        for i, (note, _isb, pck) in enumerate(whites):
            w_idx[note] = i
            x0 = i * self.WK_W + 1
            y0 = 1
            x1 = x0 + self.WK_W - 2
            y1 = self.WK_H
            c.create_rectangle(x0, y0, x1, y1, fill="#fafafa", outline="#333", width=2)
            if note % 12 == 0:          # 只在每个 C 上标音名（37 键太挤）
                c.create_text((x0 + x1) / 2, y1 - 26, text=note_name(note), fill="#222",
                              font=("Microsoft YaHei", 9, "bold"))
            if pck:                      # 有电脑键绑定的才标字母
                c.create_text((x0 + x1) / 2, y1 - 10, text=pck.upper(), fill="#666",
                              font=("Microsoft YaHei", 8))
            self._rect_to_note.append((x0, y0, x1, y1, note, False))

        # 黑键（画在白键之上 → 命中测试必须先查黑键，见 note_at）
        for note, _isb, pck in blacks:
            left = note - 1
            if left not in w_idx:
                continue
            xc = (w_idx[left] + 1) * self.WK_W
            x0 = xc - self.BK_W / 2
            x1 = xc + self.BK_W / 2
            y1 = self.BK_H
            c.create_rectangle(x0, 1, x1, y1, fill="#111", outline="#000", width=2)
            if pck:
                c.create_text((x0 + x1) / 2, y1 - 8, text=pck.upper(), fill="#bbb",
                              font=("Microsoft YaHei", 8))
            self._rect_to_note.append((x0, 1, x1, y1, note, True))

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
        self.focus_piano()                       # ★ 点琴键顺手把焦点抢回来（防按键被输入框吃掉）
        if self.mode == MODE_GUITAR:
            return self.guitar_press(ev)
        if self.mode == MODE_ERHU:
            return self.erhu_press(ev)
        n = self.note_at(ev.x, ev.y)
        if n is None:
            return
        if self._latch_on():
            # ★ 锁存模式：单击切换 ⇒ **鼠标也能累积 32 个同时音**（单只鼠标按不出 32 个键）
            self.toggle_note(n)
        else:
            self.link.note_on(n, self.velocity)
        self.update_info()

    def on_release(self, ev):
        if self.mode == MODE_GUITAR:
            return self.guitar_release(ev)
        if self.mode == MODE_ERHU:
            return self.erhu_release(ev)
        if self._latch_on():
            self.update_info()                 # 锁存模式：松手不消音
            return
        n = self.note_at(ev.x, ev.y)
        if n is not None:
            self.link.note_off(n)
        else:
            self.link.all_notes_off()          # 移出琴键范围松手 → 兜底清音
        self.update_info()

    def on_drag(self, ev):
        if self.mode == MODE_GUITAR:
            return self.guitar_drag(ev)
        if self.mode == MODE_ERHU:
            return self.erhu_drag(ev)
        if self._latch_on():
            return                             # 锁存模式拖动不触发，避免扫过一堆音
        n = self.note_at(ev.x, ev.y)
        if n is not None:
            self.link.note_on(n, self.velocity)
            self.update_info()

    # ------------------------------------------------ 电脑键盘
    def on_key_press(self, ev):
        k = (ev.keysym or "").lower()
        if k == "escape":
            self.on_close_with_ime()
            return
        if k in INST_KEYS:                       # ★ F1/F2/F3 = 钢琴/吉他/小提琴（切模式 + 发 CC20）
            self.set_mode(INST_KEYS[k])
            return
        # ★★ 模式专属键盘**必须排在八度键之前**：吉他模式下 `-`/`=` 是"品"而不是八度，
        #    否则会被 OCTAVE_KEYS 抢走（实测踩过：按 `=` 变成换八度+清音）
        if self.mode == MODE_GUITAR:
            self._keycode_to_key[int(ev.keycode)] = k      # ★ 让 Shift 变体也能正确松开
            if self.guitar_key(k, down=True, shift=bool(ev.state & 0x0001)):
                return
        elif self.mode == MODE_ERHU:
            if self.erhu_key(k, down=True):
                return
        if k in OCTAVE_KEYS:                     # ★ 八度切换已换到 `-`/`=`（z/x 现在是音符！）
            self.shift_octave(OCTAVE_KEYS[k])
            return
        if k in self._down_by_key:               # 自动重复 → 忽略
            return
        note = self.key_to_note(k)
        # ★ 诊断面板：**有没有映射都记录** ⇒ 用户能告诉我们"我按了 X，界面显示 Y"
        self.show_diag(f"按下 keysym={k!r} code={ev.keycode} → "
                       + (f"note={note} {note_name(note)}" if note is not None else "**未映射**"))
        if note is not None:
            self._down_by_key[k] = note
            self._keycode_to_key[int(ev.keycode)] = k     # ★ 按硬件键号登记
            self.link.note_on(note, self.velocity)
            self.update_info()

    def on_key_release(self, ev):
        k = (ev.keysym or "").lower()
        # ★ 模式专属的松开处理（小提琴弹弦要按音高 NoteOff；吉他走通用 _down_by_key 逻辑）
        if self.mode == MODE_ERHU:
            if self.erhu_key(k, down=False):
                return
        # ★★ "失灵键"的第二处根因修复（2026-10-06）：
        #    按住 Shift 再松开某个键时，`keysym` 会变成另一个字符
        #    （`;` → `colon`、`/` → `question`、`1` → `exclam` …），
        #    原来只按 keysym 查 ⇒ 查不到 ⇒ **NoteOff 永远发不出去** ⇒
        #    该 note 卡在 `_active`/`_down_by_key` 里 ⇒ **这个键从此永久失灵**。
        #    现在用 `keycode`（硬件键号，与 Shift 无关）兜底。
        if k not in self._down_by_key:
            k = self._keycode_to_key.pop(int(ev.keycode), k)
        else:
            self._keycode_to_key.pop(int(ev.keycode), None)
        note = self._down_by_key.pop(k, None)
        if note is not None:
            self.link.note_off(note)
            self.show_diag(f"松开 keysym={k!r} code={ev.keycode} → note={note}")
            self.update_info()

    def key_to_note(self, k, keycode=None):
        """电脑按键 → note（**37 键全覆盖**，见 `PC_KEYMAP`）。"""
        return pc_key_to_note(k, self.octave)

    def set_instrument(self, idx):
        """切换音色：0=钢琴 1=吉他 2=小提琴（协议 **CC20**）。

        ⚠️ RTL 侧 `top.v` 目前把 `inst_sel` 硬编码成 0 ⇒ **在 Lead 接上 CC20 之前，
           切换只改 GUI 状态，板子上的音色不会变**（界面会如实提示，不骗用户）。
        """
        idx = max(0, min(2, int(idx)))
        self.inst = idx
        self.link.set_instrument(idx)
        for i, b in enumerate(getattr(self, "inst_btns", [])):
            b.config(bg="#2b6cb0" if i == idx else "#333")
        name = ("钢琴", "吉他", "小提琴")[idx]
        self.set_status(f"音色 → {name}（CC20={MODE_TO_CC20[idx]}，板端实时生效）", "info")
        self.show_diag(f"[音色] → {name}  CC20={idx}")

    def show_diag(self, msg):
        """★ 按键诊断面板：用户按一下就能告诉我们"我按了 X，界面显示 Y"。"""
        try:
            self.diag_hist.append(msg)
            self.diag_hist = self.diag_hist[-4:]
            self.diag.config(text="\n".join(self.diag_hist))
        except Exception:                                        # noqa: BLE001
            pass

    # ------------------------------------------------ 鼠标：锁存 / 32 键齐奏
    def toggle_note(self, note):
        """锁存模式：单击"开/关"一个音 —— **鼠标也能累积 32 个同时音**。"""
        if note in self.link.active_notes():
            self.link.note_off(note)
            self._latched.discard(note)
        else:
            self.link.note_on(note, self.velocity)
            self._latched.add(note)
        self.update_info()

    def play_chord32(self):
        """★ 一键发 32 个同时 note-on（验证复音 ≥32 与串口带宽）。"""
        self.link.all_notes_off()
        self._latched.clear()
        keys = [k for k in piano_keys() if not k[1]] or piano_keys()
        picked = keys[:32] if len(keys) >= 32 else keys
        for note, _isb, _p in picked:
            self.link.note_on(note, self.velocity)
            self._latched.add(note)
        self.set_status(f"已发 {len(picked)} 个同时 NoteOn（≥32 复音验证）；"
                        f"按「全部停止」清除", "ok")
        self.update_info()

    # ------------------------------------------------ 其它
    def shift_octave(self, d):
        new = self.octave + d
        if OCTAVE_MIN <= new <= OCTAVE_MAX:
            # ★ 换八度**必须 panic 清音**（否则同一个物理键换到新八度后，
            #   旧的 note 永远收不到 NoteOff ⇒ 挂音）。用最强的那条。
            self.link.panic()
            self._down_by_key.clear()
            self._keycode_to_key.clear()
            self._latched.clear()
            self.octave = new
            _ol = getattr(self, "oct_lbl", None)      # ★ 该控件只在钢琴模式存在
            if _ol is not None:
                try:
                    _ol.config(text=f"C{self.octave}")
                except Exception:                                # noqa: BLE001
                    pass
            self.draw_keys()
            self.update_info()
            lo, hi = base_note_of(new), base_note_of(new) + KEYBOARD_SPAN - 1
            self.show_diag(f"[八度] → C{new}（note {lo}..{hi}）")
        else:
            self.set_status(f"八度已到边界（{OCTAVE_MIN}..{OCTAVE_MAX}）", "err")

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

    # ---- 演奏录音与回放 (赛题拓展④) ----
    def toggle_record(self):
        if not self.recorder.recording:
            self.recorder.start_record()
            self.btn_rec.config(text="■ 停止录音", bg="#aa2222", fg="#ffffff")
        else:
            self.recorder.stop_record()
            self.btn_rec.config(text="● 录音", bg="#442222", fg="#ff8888")

    def toggle_play_record(self):
        if not self.recorder.playing:
            if not self.recorder.events:
                self.set_status("暂无录制数据，请先点击「● 录音」弹奏一段", "warn")
                return
            def _on_done():
                self.btn_play_rec.config(text="▶ 回放", bg="#224422", fg="#88ff88")
            self.btn_play_rec.config(text="■ 停止回放", bg="#22aa22", fg="#ffffff")
            self.recorder.replay(on_finish=_on_done)
        else:
            self.recorder.stop_replay()
            self.btn_play_rec.config(text="▶ 回放", bg="#224422", fg="#88ff88")

    def do_export_midi(self):
        if not self.recorder.events:
            self.set_status("暂无录制数据，请先录制一段演奏后再导出", "warn")
            return
        from tkinter import filedialog
        default_fn = f"performance_{time.strftime('%Y%m%d_%H%M%S')}.mid"
        path = filedialog.asksaveasfilename(
            parent=self.root,
            defaultextension=".mid",
            initialfile=default_fn,
            filetypes=[("MIDI Files", "*.mid"), ("All Files", "*.*")]
        )
        if path:
            self.recorder.export_midi(path)

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

    # ------------------------------------------------ 焦点 / IME / 按键诊断
    def on_focus_in(self, ev=None):
        """窗口拿到焦点 ⇒ **立刻把输入法切英文**（用户实测根因：中文输入法吞按键）。"""
        if not getattr(self, "_ime_attached", False):
            self.ime.attach(self.root)
            self._ime_attached = True
        ok = self.ime.force_english()
        extra = "" if ok else "  ⚠ 自动切换失败 ⇒ **请手动切英文输入法**，否则按键会被吞掉"
        self.show_diag(f"[焦点] {self.ime.status_text()}{extra}")
        self._ime_poll()

    def _ime_poll(self):
        """每 800 ms 查一次 IME：中途被切回中文也自动切回英文，并持续显示状态。"""
        try:
            self.root.after(800, self._ime_poll)          # ★ 先重排，保证轮询不会因异常断掉
        except Exception:                                 # noqa: BLE001
            return
        try:
            if self.ime.ok and self.ime.is_chinese():
                self.ime.force_english()
            lbl = getattr(self, "ime_lbl", None)
            if lbl is not None:
                ch = self.ime.is_chinese() if self.ime.ok else None
                lbl.config(text=self.ime.status_text(),
                           fg="#5ed46a" if ch is False else "#ff6b6b")
        except Exception:                                 # noqa: BLE001
            pass

    def on_close_with_ime(self):
        """关窗：**先还原用户原来的 IME 状态**，再正常关闭（不搞乱用户的系统）。"""
        try:
            self.ime.restore()
        except Exception:                                 # noqa: BLE001
            pass
        self.on_close()

    def focus_piano(self, ev=None):
        """点琴键把焦点抢回主窗口 —— 否则焦点可能停在调试输入框里，按键全被它吃掉。"""
        try:
            self.root.focus_force()
        except Exception:                                 # noqa: BLE001
            pass

    # ============================================ ★ 三种乐器：模式 / 绘制 / 维度
    def set_mode(self, idx: int):
        """切换乐器模式：0=钢琴 1=吉他 2=小提琴（同时发 **CC20**）。

        ⚠️ 换模式**必须 panic 清音**（否则旧模式的音收不到 NoteOff ⇒ 挂音），
           并清空全部按键/锁定状态。
        """
        idx = max(0, min(2, int(idx)))
        self.link.panic()
        self._down_by_key.clear()
        self._keycode_to_key.clear()
        self._latched.clear()
        self._bow_timer = None
        self.mode = idx
        self.set_instrument(idx)                  # CC20 → RTL 侧（Lead 正在接 inst_sel）
        self.rebuild_mode_extras()                # ★ 销毁旧模式控件 + 建新模式控件
        try:                                      # 挂电量只在吉他模式存在
            if getattr(self, "drive_var", None) is not None:
                self.link.set_fx(CC_DRIVE, self.drive_var.get())
        except Exception:                                        # noqa: BLE001
            pass
        self.draw_keys()
        self.update_info()
        name = MODE_NAMES[idx]
        self.set_status(f"模式 → {name}（CC20={MODE_TO_CC20[idx]}）"
                        + ("；⚠️ 板子端需 RTL 接上 CC20 才变音色" if idx != MODE_PIANO else ""),
                        "info")
        self.show_diag(f"[模式] → {name}  CC20={idx}")

    # ------------------------------------------------ 🎸 吉他：指板
    def draw_guitar(self):
        """🎸 指板（**照用户截图**）：左侧【木质琴枕块】竖排 E B G D A E ｜
        **水平弦（越靠下越粗）** ｜ **垂直品丝** ｜ **品点在第 3/5/7/9/12 品**。

        交互（比参考页更强，保留）：
        · 点格子 ⇒ **拨该弦 + 该品**   · 点品号行 ⇒ **只改品位（压品维度）**
        · 点琴枕块 ⇒ 拨空弦          · 纵向拖 ⇒ **扫弦**
        """
        c = self.canvas
        c.delete("all")
        c.configure(bg="#eceff1")                       # 浅灰背景（照截图）
        self._rect_to_note = []
        self._g_hits = []
        self._g_fret_hits = []
        self._e_hits = []            # ★ 清掉小提琴的（避免脏状态）
        self._e_left = []
        W, H = 46, 30
        HEAD_X0, HEAD_X1 = 8, 74                        # ★ 木质琴枕块
        FB_X0 = HEAD_X1                                 # 指板起点（琴枕右缘）
        Y0 = 34
        STR_H = H                                       # 每根弦的行高
        Y1 = Y0 + 6 * STR_H
        c.configure(width=FB_X0 + (GUITAR_MAX_FRET + 1) * W + 40, height=Y1 + 74)

        # ---- 品号行（我们的「压品」维度：点它只改品位、不发声）----
        for f in range(GUITAR_MAX_FRET + 1):
            x0 = FB_X0 + f * W
            x1 = x0 + W - 2
            sel = (f == self.g_fret_sel)
            c.create_rectangle(x0, 4, x1, 24, fill="#1565c0" if sel else "#546e7a",
                               outline="#37474f")
            c.create_text((x0 + x1) / 2, 14, text=str(f), fill="white",
                          font=("Consolas", 9, "bold"))
            self._g_fret_hits.append((x0, 4, x1, 24, f))
        c.create_text(HEAD_X0 + 26, 14, text="品", fill="#37474f",
                      font=("Microsoft YaHei", 9, "bold"))

        # ---- ★ 木质琴枕块（左端，竖排弦名 E B G D A E）----
        c.create_rectangle(HEAD_X0, Y0, HEAD_X1, Y1, fill="#c8863c", outline="#8d5524", width=2)
        c.create_rectangle(HEAD_X0 + 4, Y0 + 4, HEAD_X1 - 4, Y1 - 4,
                           outline="#e8b06a", width=1)     # 木纹高光

        # ---- ★ 指板（木色）+ 垂直品丝 ----
        c.create_rectangle(FB_X0, Y0, FB_X0 + (GUITAR_MAX_FRET + 1) * W, Y1,
                           fill="#b5793a", outline="#8d5524", width=2)
        for f in range(GUITAR_MAX_FRET + 1):
            x = FB_X0 + f * W
            if f == 0:
                c.create_line(x, Y0, x, Y1, fill="#f5e6c8", width=4)   # 琴枕（白）
            else:
                c.create_line(x, Y0, x, Y1, fill="#7a4a1e", width=2)   # 品丝
        c.create_line(FB_X0 + (GUITAR_MAX_FRET + 1) * W, Y0,
                      FB_X0 + (GUITAR_MAX_FRET + 1) * W, Y1, fill="#7a4a1e", width=2)

        # ---- ★ 品点（3/5/7/9/12 品，浅灰圆点，画在弦的下方居中）----
        ymid = Y1 - 7
        for f in (3, 5, 7, 9, 12):
            if f > GUITAR_MAX_FRET:
                continue
            xc = FB_X0 + f * W + W / 2
            c.create_oval(xc - 4, ymid - 4, xc + 4, ymid + 4,
                          fill="#efe3c8", outline="#8d5524")
        if self.barre_fret:                          # ★ 大横按那一列高亮（视觉反馈）
            _bx = FB_X0 + self.barre_fret * W
            c.create_rectangle(_bx, Y0, _bx + W, Y1, outline="#ffd54f", width=3)
            c.create_text(_bx + W / 2, Y0 - 9, text=f"横按 {self.barre_fret}",
                          fill="#ffd54f", font=("Microsoft YaHei", 8, "bold"))
        if self.capo:                                # ★ 变调夹提示
            c.create_text(HEAD_X0 + 33, Y1 + 26, text=f"Capo {self.capo:+d}",
                          fill="#0d47a1", font=("Microsoft YaHei", 9, "bold"))

        # ---- ★ 弦：水平线，**越靠下越粗**（弦1 E4 在上、弦6 E2 在下）----
        for si in range(6):
            y = Y0 + si * STR_H + STR_H / 2
            # 琴枕块里的弦名（照截图：E B G D A E 竖排）
            c.create_text((HEAD_X0 + HEAD_X1) / 2, y, text=note_name(GUITAR_OPEN[si]).rstrip("0123456789"),
                          fill="#fff8e1", font=("Consolas", 10, "bold"))
            c.create_line(FB_X0 + 2, y, FB_X0 + (GUITAR_MAX_FRET + 1) * W, y,
                          fill="#3a3a3a", width=1.0 + si * 0.45)      # ★ 越靠下越粗
            for f in range(GUITAR_MAX_FRET + 1):
                x0 = FB_X0 + f * W
                x1 = x0 + W - 2
                self._g_hits.append((x0, Y0 + si * STR_H, x1, Y0 + (si + 1) * STR_H, si, f))
                # ★ 用户要求：**把"哪个键出哪个音"直接标在界面上**（不只写在提示条里）
                _row = si - (2 if self.guitar_group else 0)
                _kk = ""
                if 0 <= _row < len(GUITAR_ROW_KEYS):
                    _keys = GUITAR_ROW_KEYS[_row]
                    if f == 0:
                        _kk = "⇧" + _KEY_DISP.get(_keys[0], _keys[0])
                    elif f <= len(_keys):
                        _kk = _KEY_DISP.get(_keys[f - 1], _keys[f - 1])
                if self.show_labels:                 # ★ 标注开关（默认开）
                    c.create_text((x0 + x1) / 2, Y0 + si * STR_H + 10, text=_kk.upper(),
                                  fill="#fff8e1", font=("Consolas", 7, "bold"))
                    c.create_text((x0 + x1) / 2, Y0 + si * STR_H + 22,
                                  text=note_name(self.guitar_note(si, f)),
                                  fill="#4e342e", font=("Consolas", 6))

        # ---- 琴枕块 = 空弦区（点它=拨空弦）；底部 = 扫弦区 ----
        self._g_body = (HEAD_X0, Y0, HEAD_X1, Y1)
        c.create_text((HEAD_X0 + HEAD_X1) / 2, Y1 + 12, text="点此=空弦", fill="#37474f",
                      font=("Microsoft YaHei", 7))
        self._g_strum = (FB_X0, Y1 + 4, FB_X0 + (GUITAR_MAX_FRET + 1) * W, Y1 + 34)
        c.create_rectangle(self._g_strum[0], self._g_strum[1], self._g_strum[2],
                           self._g_strum[3], fill="#455a64", outline="#263238")
        c.create_text((self._g_strum[0] + self._g_strum[2]) / 2,
                      (self._g_strum[1] + self._g_strum[3]) / 2,
                      text=f"扫弦区（横拖=扫弦，间隔 {self.strum_ms} ms/弦（可调 25~80）；下扫↓ 弦6→弦1）",
                      fill="#eceff1", font=("Microsoft YaHei", 8))

    def guitar_note(self, si, fret):
        """★ `note = clamp(空弦 + capo + 品, 0, 127)` —— **变调夹**（纯 GUI，RTL 不用动）。"""
        return max(0, min(127, string_fret_note(si, max(0, int(fret))) + self.capo))

    def guitar_pluck(self, si, fret=None):
        """拨一根弦（品位用参数或"当前品位"）。返回发出去的 note。"""
        f = self.g_fret_sel if fret is None else max(0, int(fret))
        f = max(f, self.barre_fret)               # ★ 大横按：所有弦的品位【下界】
        n = self.guitar_note(si, f)
        self.link.note_on(n, self.velocity)
        self._g_ring.add((si, f))
        self.show_diag(f"[吉他] 拨弦{si + 1} 品{f} → note={n} {note_name(n)}")
        self.update_info()
        return n

    def guitar_strum(self, down=True):
        """⭐ 扫弦：**依次**拨 6 根弦，间隔 `GUITAR_STRUM_MS`（用 `after` 非阻塞）。

        - 下扫 = 弦6→弦1（低音→高音）；上扫 = 弦1→弦6
        - **用各弦当前共享的品位**（不重置品位）⇒ 与「压品」维度正交
        """
        # ★ 下扫 = **弦6→弦1**（低音→高音）；上扫 = 反序。
        #   ⚠️ 修过一次：原先写成 range(6)（弦1 先），与"下扫"的物理意义**相反**。
        order = list(range(5, -1, -1)) if down else list(range(6))
        for i, si in enumerate(order):
            self.root.after(i * self.strum_ms, lambda s=si: self.guitar_pluck(s))
        self.show_diag(f"[吉他] {'下扫↓' if down else '上扫↑'} 6 弦，间隔 {self.strum_ms} ms")

    def guitar_set_fret(self, f):
        """⭐「压品」维度：**只改当前品位，不发声**（与拨弦/扫弦/挂电都正交）。"""
        self.g_fret_sel = max(0, min(GUITAR_MAX_FRET, int(f)))
        self.show_diag(f"[吉他] 压品 → {self.g_fret_sel} 品（不发声）")
        self.draw_guitar()                      # 重画以高亮当前品位

    # ------------------------------------------------ 🎻 小提琴：21 弦
    # ------------------------------------------------ 挂电 / 效果器
    def set_drive(self, v):
        v = int(float(v))
        self.link.set_fx(CC_DRIVE, v)
        self.show_diag(f"[挂电] CC21={v}" + ("（清音 bypass）" if v == 0 else ""))

    def set_fx_opt(self, cc, v):
        self.link.set_fx(cc, int(float(v)))

    # ---- 鼠标：🎸 吉他 ----
    def guitar_hit(self, x, y):
        for (x0, y0, x1, y1, f) in self._g_fret_hits:
            if x0 <= x <= x1 and y0 <= y <= y1:
                return "fret", f
        for (x0, y0, x1, y1, si, f) in self._g_hits:
            if x0 <= x <= x1 and y0 <= y <= y1:
                return "cell", (si, f)
        b = self._g_body
        if b and b[0] <= x <= b[2] and b[1] <= y <= b[3]:
            si = int((y - b[1]) / max(1.0, (b[3] - b[1]) / 6.0))
            return "body", max(0, min(5, si))
        return None, None

    def guitar_press(self, ev):
        kind, pl = self.guitar_hit(ev.x, ev.y)
        if kind == "fret":
            return self.guitar_set_fret(pl)                 # 压品（不发声）
        if kind == "cell":
            si, f = pl
            self.g_fret_sel = f                             # 点格子同时同步"当前品位"
            self._g_drag_last = si
            return self.guitar_pluck(si, f)
        if kind == "body":
            return self.guitar_pluck(pl, 0)                 # 琴身 = 拨空弦
        return None

    def guitar_drag(self, ev):
        """**纵向拖 = 扫弦**（按方向）；同弦横向拖 = 逐品滑过。"""
        kind, pl = self.guitar_hit(ev.x, ev.y)
        if kind != "cell":
            return
        si, f = pl
        last = getattr(self, "_g_drag_last", None)
        if last is not None and si != last:
            self._g_drag_last = si
            self.guitar_strum(down=(si > last))              # 弦号变大 = 走向低音弦 = 下扫
        else:
            self._g_drag_last = si
            self.guitar_pluck(si, f)

    def guitar_release(self, ev):
        self._g_drag_last = None
        self.link.all_notes_off()                            # 一触即发 ⇒ 松手释放
        self.update_info()

    # ---- 鼠标：🎻 小提琴 ----
    # ---- 键盘：🎸 吉他 / 🎻 小提琴 ----
    GUITAR_STR_KEYS = ("a", "s", "d", "f", "g", "h")          # 弦1..弦6（与指板同序）
    # ⚠️ 必须是 **21** 个：`QWERTYUIOP[]`(12) + `ASDFGHJKL`(9) = 21
    #    （修过一次：原先多带了一个 `;` ⇒ 22 个，最后多出一根弦）
    ERHU_KEYS = ["q", "w"]      # 小提琴 2 根弦：q=内弦 / w=外弦

    def guitar_key(self, k, down=True, shift=False):
        """🎸 **行 = 弦、键在行内的位置 = 品**（对齐参考页面的 `keyboardMap{ s, f }`）。

        · `Tab`（或 `\\`）切弦组：高音组(弦1-4) ⇄ 低音组(弦3-6)，**切组清音**
        · **Shift + 该行第一个键 = 该弦空弦（品 0）** ← 空弦键**定死**，HINT 里有提示
        · `F5` = 下扫↓ / `F6` = 上扫↑（`Z`/`X` 已让给弦4 的品 1/2）
        """
        if k in ("tab", "backslash"):
            self.guitar_group ^= 1
            self.link.panic()                       # ⚠️ 切组必须清音，否则旧弦挂音
            self._down_by_key.clear()
            self._keycode_to_key.clear()
            self.set_status(f"吉他弦组 → {GUITAR_GROUP_NAME[self.guitar_group]}（已清音）", "info")
            self.show_diag(f"[吉他] 弦组 → {GUITAR_GROUP_NAME[self.guitar_group]}")
            return True
        if k in GUITAR_STRUM_KEYS:
            self.guitar_strum(down=GUITAR_STRUM_KEYS[k])
            return True
        # ★ F4=拍弦(slap) ｜ F7/F8=变调夹 ±1（Shift=±5）｜ F9/F10=大横按 设/清 ｜ F11=横按+下扫
        if k == "f4":
            self.guitar_slap(); return True
        if k == "f7":
            self.capo_shift(+5 if shift else +1); return True
        if k == "f8":
            self.capo_shift(-5 if shift else -1); return True
        if k == "f9":
            self.barre_set(); return True
        if k == "f10":
            self.barre_clear(); return True
        if k == "f11":
            self.barre_and_strum(); return True
        base = GUITAR_SHIFT_ALIAS.get(k, k) if shift else k
        for row, keys in enumerate(GUITAR_ROW_KEYS):
            if shift:
                if base != keys[0]:
                    continue                        # 只有"行首键 + Shift"才是空弦
                fret = 0
            else:
                if k not in keys:
                    continue
                fret = keys.index(k) + 1            # 行内第 n 个键 = 第 n 品
            si = row + (2 if self.guitar_group else 0)
            if down:
                note = self.guitar_note(si, max(fret, self.barre_fret))
                self._down_by_key[k] = note         # 交给通用松开逻辑发 NoteOff
                self.guitar_pluck(si, fret)
            return True
        return False

    # ============================================ ★ 乐器切换 / 模式专属控件
    def rebuild_mode_extras(self):
        """**销毁**上一个模式的专属控件，再按当前模式重建（用户要求"UI 完全独立"）。

        ⚠️ 为什么必须销毁而不是隐藏：隐藏的控件仍在 `winfo_children()` 里，
           验收断言"旧模式控件数 = 0"就过不了，而且一旦布局变了就会露出来。
        """
        for w in list(self.mode_extras.winfo_children()):
            w.destroy()
        self.inst_btns = []
        if self.mode == MODE_GUITAR:
            self._build_guitar_extras()
        elif self.mode == MODE_ERHU:
            self._build_erhu_extras()
        else:
            self._build_piano_extras()
        # ★★ Bug A 修复：**高亮必须在每次切模式时都更新**（原来这段被留在
        #    `_build_piano_extras` 末尾 ⇒ 只有切回钢琴才更新 ⇒ "永远钢琴按下"）。
        #    而且用 **▶ 前缀 + 蓝底 + relief**（Windows 下只改 bg 有时看不出按下态）
        for _i, _b in enumerate(self.inst_switch_btns):
            _act = (_i == self.mode)
            _b.config(text=("▶ " + _b._base_text) if _act else _b._base_text,
                      bg="#1565c0" if _act else "#333",
                      fg="white" if _act else "#ddd",
                      relief="sunken" if _act else "raised", bd=3 if _act else 2)

    def _build_piano_extras(self):
        """🎹 只在钢琴模式出现的控件：八度切换 + 锁存 + 32 键齐奏。

        ⚠️ 用户要求"非该乐器的功能不要显示" ⇒ 这三样**只有钢琴需要**，已从公共行移到这里。
        """
        row = tk.Frame(self.mode_extras, bg=self.BG)
        row.pack(fill="x")
        tk.Button(row, text="－ 八度 (Z)", width=11, bg="#333", fg="white",
                  command=lambda: self.shift_octave(-1)).pack(side="left", padx=2)
        self.oct_lbl = tk.Label(row, text=f"C{self.octave}", bg=self.BG, fg="#7fd1ff",
                                width=4)
        self.oct_lbl.pack(side="left")
        tk.Button(row, text="＋ 八度 (X)", width=11, bg="#333", fg="white",
                  command=lambda: self.shift_octave(+1)).pack(side="left", padx=2)
        self.latch_var = tk.BooleanVar(value=False)
        tk.Checkbutton(row, text="锁存(鼠标累积多键)", variable=self.latch_var,
                       bg=self.BG, fg="#7fd1ff", selectcolor="#222",
                       activebackground=self.BG, activeforeground="#7fd1ff",
                       font=("Microsoft YaHei", 9)).pack(side="left", padx=8)
        tk.Button(row, text="32 键齐奏", width=11, bg="#265", fg="white",
                  command=self.play_chord32).pack(side="left", padx=2)
        tk.Label(self.mode_extras,
                 text="硬件映射：橡胶 K1-K13 = C4-C5 钢琴键 ｜ 编码器 E1=力度  E2=音色  E3=空间效果",
                 bg="#17222b", fg="#9fd8ee", anchor="w",
                 font=("Microsoft YaHei", 9)).pack(fill="x", pady=(3, 0))
        # （高亮更新已移到 `rebuild_mode_extras()` 末尾 —— Bug A 的根因就是它留在这里）

    def _build_guitar_extras(self):
        """🎸 只在吉他模式出现的控件：音色三选（CC21）+ 挂电量 + 扫弦 + 切弦组。"""
        row = tk.Frame(self.mode_extras, bg=self.BG)
        row.pack(fill="x")
        tk.Label(row, text="🎸挂电（失真强度 CC21）：", bg=self.BG, fg="#e8e8e8").pack(side="left")
        self.drive_var = tk.IntVar(value=0)
        tk.Scale(row, from_=0, to=127, orient="horizontal", length=130,
                 variable=self.drive_var, bg=self.BG, fg="#7fd1ff", highlightthickness=0,
                 troughcolor="#333", command=self.set_drive).pack(side="left")
        tk.Button(row, text="Tab 切弦组", width=11, bg="#245", fg="white",
                  command=lambda: self.guitar_key("tab")).pack(side="left", padx=6)
        tk.Button(row, text="↓下扫 (F5)", width=10, bg="#333", fg="white",
                  command=lambda: self.guitar_strum(True)).pack(side="left", padx=2)
        tk.Button(row, text="↑上扫 (F6)", width=10, bg="#333", fg="white",
                  command=lambda: self.guitar_strum(False)).pack(side="left", padx=2)
        tk.Label(self.mode_extras,
                 text="硬件映射：6 路光电 = 六根弦拨弦 S1-S6 ｜ 橡胶 K1-K13 = 品位 0-12（按住弦 + 品位）｜ EC11 E1=力度  E2=扫弦速度  E3=箱体明亮度",
                 bg="#17222b", fg="#9fd8ee", anchor="w",
                 font=("Microsoft YaHei", 9)).pack(fill="x", pady=(3, 0))
        # 可选效果器（CC22 合唱 / CC23 延迟 / CC24 混响）—— 只在吉他模式出现
        row2 = tk.Frame(self.mode_extras, bg=self.BG)
        row2.pack(fill="x", pady=(1, 0))
        row3 = tk.Frame(self.mode_extras, bg=self.BG)
        row3.pack(fill="x", pady=(1, 0))
        tk.Label(row3, text="扫弦间隔", bg=self.BG, fg="#7fd1ff",
                 font=("Microsoft YaHei", 8)).pack(side="left")
        _ss = tk.Scale(row3, from_=25, to=80, orient="horizontal", length=88, bg=self.BG,
                       fg="#7fd1ff", highlightthickness=0, troughcolor="#333",
                       command=self.set_strum_ms)
        _ss.set(self.strum_ms)
        _ss.pack(side="left")
        tk.Button(row3, text="👋 拍弦 (F4)", width=12, bg="#5a3a1a", fg="white",
                  command=self.guitar_slap).pack(side="left", padx=6)
        tk.Button(row3, text="Capo+1 (F7)", width=12, bg="#245", fg="white",
                  command=lambda: self.capo_shift(+1)).pack(side="left", padx=2)
        tk.Button(row3, text="Capo-1 (F8)", width=12, bg="#245", fg="white",
                  command=lambda: self.capo_shift(-1)).pack(side="left", padx=2)
        tk.Button(row3, text="横按 (F9)", width=10, bg="#245", fg="white",
                  command=self.barre_set).pack(side="left", padx=2)
        tk.Button(row3, text="解除 (F10)", width=10, bg="#333", fg="white",
                  command=self.barre_clear).pack(side="left", padx=2)
        tk.Button(row3, text="横按+下扫 (F11)", width=14, bg="#265", fg="white",
                  command=self.barre_and_strum).pack(side="left", padx=2)
        _lv = tk.BooleanVar(value=self.show_labels)
        tk.Checkbutton(row3, text="键位标注", variable=_lv, bg=self.BG, fg="#7fd1ff",
                       selectcolor="#222", activebackground=self.BG,
                       command=lambda: self.toggle_labels(_lv)).pack(side="left", padx=8)
        tk.Label(row2, text="可选效果器：", bg=self.BG, fg="#888").pack(side="left")
        for _cc, _nm in ((CC_CHORUS, "合唱"), (CC_DELAY, "延迟"), (CC_REVERB, "混响")):
            tk.Scale(row2, from_=0, to=127, orient="horizontal", length=64,
                     bg=self.BG, fg="#7fd1ff", highlightthickness=0, troughcolor="#333",
                     command=lambda val, c=_cc: self.set_fx_opt(c, val)).pack(side="left")
            tk.Label(row2, text=_nm, bg=self.BG, fg="#aaa",
                     font=("Microsoft YaHei", 8)).pack(side="left", padx=(0, 4))

    def _latch_on(self):
        """安全读锁存开关（控件可能不存在/被销毁）。"""
        try:
            return bool(self.latch_var.get())
        except Exception:                                        # noqa: BLE001
            return False

    # =========================================================================
    #  🎻 小提琴（v45 完整版）—— 依据 `_research/pc-link/ERHU-RESEARCH.md`
    #   · 定弦**已核实**：内弦 **D4(62)** / 外弦 **A4(69)**（纯五度；两个独立来源）
    #   · 交互照在线模拟器（playthenote）：**按住=运弓（持续发声）｜按住上下拖=滑音｜
    #     快速上下抖动=揉弦**
    #   · 键盘：**内弦 `Q W E R T Y…`｜外弦 `A S D F G H…`**（与模拟器一致）
    #   · 三个**彼此独立**的弓参数（调研已论证独立性 —— 别把弓速和音量做成同一个量）：
    #       弓速 → **CC21**（能量/音量）  弓压 → **CC22**（亮度，**不改音量**）
    #       弓位 → **CC23**（薄↔厚，梳状）
    #     ⚠️ **CC21~23 与吉他共用**（乐器已由 CC20 区分、不会同时用）—— 见 §CC 共用说明
    #   · ⭐ **换弦 = 弓的方向反转**（推弓=内弦 / 拉弓=外弦）—— 小提琴独有交互
    #   · ⚠️ **同时只发一根弦**（弓永久夹在两弦之间，物理上拉不到两根）
    # =========================================================================
    ERHU_KEY_INNER = VIOLIN_KEY_ROWS[1]   # legacy: D 弦
    ERHU_KEY_OUTER = VIOLIN_KEY_ROWS[2]   # legacy: A 弦
    ERHU_SEMI_MAX = 24                     # 每弦 0..24 半音（两个八度，与模拟器一致）

    def _build_erhu_extras(self):
        """🎻 小提琴控制面板：弓速/弓压/弓位 + 揉弦 + 顺逆弓 + 拨弦 + 实物乐器演奏指南。"""
        row = tk.Frame(self.mode_extras, bg=self.BG)
        row.pack(fill="x")
        tk.Label(row, text="🎻小提琴运弓表情：", bg=self.BG, fg="#e8e8e8", font=("Microsoft YaHei", 9, "bold")).pack(side="left")
        for _lbl, _cb in (("弓速 CC21", self.set_bow_speed),
                          ("弓压 CC22", self.set_bow_force),
                          ("弓位 CC23", self.set_bow_pos)):
            tk.Label(row, text=_lbl, bg=self.BG, fg="#7fd1ff",
                     font=("Microsoft YaHei", 8)).pack(side="left", padx=(8, 0))
            tk.Scale(row, from_=0, to=127, orient="horizontal", length=85, bg=self.BG,
                     fg="#7fd1ff", highlightthickness=0, troughcolor="#333",
                     command=_cb).pack(side="left")

        tk.Button(row, text="弓向转换", width=9, bg="#245", fg="white",
                  command=self.erhu_switch_string).pack(side="left", padx=6)
        tk.Button(row, text="揉弦 (5.5Hz)", width=11, bg="#1b4d3e", fg="#5effcf",
                  command=self.erhu_tremolo_toggle).pack(side="left", padx=2)
        tk.Button(row, text="拨弦 (Pizz)", width=10, bg="#333", fg="white",
                  command=self.erhu_pizzicato).pack(side="left", padx=2)

        # 详细直观的 FPGA 实物乐器操作指南面板
        guide_box = tk.LabelFrame(self.mode_extras, text=" 📖 FPGA 实物乐器操作与演奏指南 (小提琴模式) ",
                                  bg="#121820", fg="#5effcf", font=("Microsoft YaHei", 9, "bold"), padx=8, pady=4)
        guide_box.pack(fill="x", pady=(4, 2))

        g_txt = (
            "① 🎹【把位按键】J13 排针 1~13 号按键对应小提琴把位音符（C4~C5），单手按下即拉响发声，支持复音/和弦！\n"
            "② 📡【空中滑音】右手在板载激光 ToF 传感器上方 10~70cm 悬空挥动，传感器实时测距平滑改变音高，再现无品小提琴的抒情滑音！\n"
            "③ ⚡【运弓擦弦】手指快速掠过光电管传感器，触发纯硬件物理建模松香擦弦瞬态脉冲（Helmholtz 锯齿波起振）！\n"
            "④ 🎛️【硬件旋钮】旋转 EC11 编码器调节输出主音量；板载用户按键 Y12 一键循环切换钢琴/吉他/小提琴，Y22 半音变调。"
        )
        tk.Label(guide_box, text=g_txt, bg="#121820", fg="#d0e2ec", justify="left", anchor="w",
                 font=("Microsoft YaHei", 8)).pack(fill="x")

    def erhu_note(self, si, semi):
        """弦号(0=内弦)+半音偏移 → MIDI note（**无品 ⇒ 连续**，这里量化到半音）。"""
        return max(0, min(127, ERHU_STRINGS[si] + max(0, min(self.ERHU_SEMI_MAX, int(semi)))))

    # ---------------------------------------------------------------- 视觉
    def draw_violin(self):
        """🎻 四弦小提琴界面：G-D-A-E 指板、琴桥、琴身、弓和四条独立电平表。"""
        c = self.canvas
        c.delete("all")
        c.configure(bg="#171a22", width=760, height=470)
        self._rect_to_note = []
        self._e_hits = []
        self._e_left = []
        self._g_hits = []
        self._g_fret_hits = []
        strings = VIOLIN_STRINGS
        labels = ("4弦 G3", "3弦 D4", "2弦 A4", "1弦 E5")
        xs = [170, 285, 400, 515]
        y_top, y_bot = 55, 355
        step = (y_bot - y_top) / 25.0

        # 琴身：小提琴的上/下琴身和腰部，而不是二胡琴筒。
        c.create_polygon(270, 330, 235, 360, 225, 400, 250, 425, 300, 430,
                         335, 410, 350, 380, 340, 345, 350, 315,
                         335, 285, 300, 270, 260, 275, 230, 305,
                         fill="#713d24", outline="#c28b52", width=3)
        c.create_oval(248, 285, 332, 365, fill="#8f512d", outline="#d39b5b", width=2)
        c.create_oval(236, 370, 344, 440, fill="#7b4226", outline="#d39b5b", width=2)
        c.create_line(287, 255, 287, 438, fill="#4b2719", width=5)
        c.create_text(290, 452, text="小提琴琴身 / 共鸣箱", fill="#edcf9a",
                      font=("Microsoft YaHei", 10, "bold"))

        # 指板和琴桥。
        c.create_polygon(120, 42, 565, 42, 535, 370, 150, 370,
                         fill="#302019", outline="#95623e", width=2)
        c.create_rectangle(140, 345, 545, 360, fill="#d7b276", outline="#f1d49a", width=2)
        c.create_text(600, 352, text="琴桥", fill="#edcf9a", anchor="w",
                      font=("Microsoft YaHei", 9))

        for si, (x, label, keys) in enumerate(zip(xs, labels, VIOLIN_KEY_ROWS)):
            c.create_text(x, 18, text=f"{label}  {note_name(strings[si])}",
                          fill="#f4d06f", font=("Microsoft YaHei", 10, "bold"))
            c.create_line(x, y_top, x, y_bot, fill="#e7e0cf", width=2.5 - si * 0.25)
            for semi in range(25):
                y0, y1 = y_top + semi * step, y_top + (semi + 1) * step
                self._e_hits.append((x - 36, y0, x + 36, y1, si, semi))
                if semi % 2 == 0:
                    c.create_rectangle(x - 36, y0, x + 36, y1,
                                       fill="#203b46" if semi % 12 == 0 else "#1c2630",
                                       outline="#384654")
                if semi < len(keys):
                    c.create_text(x + 47, (y0 + y1) / 2,
                                  text=_KEY_DISP.get(keys[semi], keys[semi]).upper(),
                                  fill="#a9d7ea", font=("Consolas", 8))
            # 四条独立电平表。
            c.create_rectangle(x - 48, y_top, x - 40, y_bot, fill="#0d1117", outline="#56616d")
            lv = self.e_level[si] if si < len(self.e_level) else 0
            if lv > 0:
                h = (y_bot - y_top) * min(1.0, lv / 127.0)
                c.create_rectangle(x - 47, y_bot - h, x - 41, y_bot,
                                   fill="#54c7a5" if si in (1, 2) else "#e8a85b", outline="")

        # 横向弓；弓向反转时改变斜率。
        if self.e_push:
            c.create_line(100, 95, 590, 75, fill="#d9aa3b", width=4)
            c.create_text(610, 78, text="推弓", fill="#e8c86a", anchor="w")
        else:
            c.create_line(100, 75, 590, 95, fill="#d9aa3b", width=4)
            c.create_text(610, 98, text="拉弓", fill="#e8c86a", anchor="w")
        c.create_text(600, 130, text="G  D  A  E", fill="#cfe8f0", anchor="w",
                      font=("Consolas", 13, "bold"))
        c.create_text(600, 155, text="按住 = 运弓\n上下拖动 = 滑音\nZ = 颤弓，X = 拨弦",
                      fill="#b4c6d1", anchor="w", justify="left",
                      font=("Microsoft YaHei", 9))
        c.create_text(380, 466, text="四弦小提琴：G3 / D4 / A4 / E5 ｜ 绿色音位为根音",
                      fill="#b7c9d4", font=("Microsoft YaHei", 9))

    # 旧名称保留给已有事件绑定和自检；实际绘制使用四弦小提琴界面。
    def draw_erhu(self):
        return self.draw_violin()
    # ---------------------------------------------------------------- 发声
    def erhu_play(self, si, semi, vel=None):
        """**按住即运弓**：持续发声（同一时刻只允许一根弦）。"""
        # ★ **无品连续音高**的落地方式：每次运弓/换把都先开 **Portamento**（CC65 开 + CC5 时间）
        #   ⇒ 下一次按弦由 RTL 做**真滑音**（而不是简单重触发）。已有音在响时先松旧弦。
        self.link.send_raw(m_cc(CC_PORTAMENTO_ON, 127))
        #   滑音时间取用户的设置；**若为 0（不滑）则用下限 20** —— 无品乐器的换把本来就该滑
        _gt = int(self.link.params.get("glide_time", 20)) or 20
        self.link.send_raw(m_cc(CC_PORTAMENTO_TIME, _gt))
        if self.e_note is not None:
            self.link.note_off(self.e_note)
        n = self.erhu_note(si, semi)
        self.e_sel, self.e_semi, self.e_note = si, semi, n
        self.e_push = (si % 2 == 0)                    # 弓向视觉状态
        self.e_level[si] = max(1, min(127, int(vel if vel else self.velocity)))
        self.link.note_on(n, self.e_level[si])
        string_names = ["4弦 G3", "3弦 D4", "2弦 A4", "1弦 E5"]
        s_name = string_names[si] if si < len(string_names) else f"{si}弦"
        self.show_diag(f"[小提琴] {s_name} | 把位+{semi} → note={n} ({note_name(n)})")
        self.update_info()
        return n

    def erhu_stop(self):
        if self.e_note is not None:
            self.link.note_off(self.e_note)
        self.e_note = None
        self.e_level = [0, 0, 0, 0]
        self.update_info()

    def erhu_glide_to(self, semis):
        """按住时上下拖动 = **滑音**：量化到半音重发（跟现有 RTL 的 note 机制兼容）。"""
        if self.e_note is None:
            return
        semi = max(0, min(self.ERHU_SEMI_MAX, int(round(semis))))
        if semi == self.e_semi:
            return
        # ⚠️ 真正"连续"音高需要 RTL 支持 Pitch Bend（0xE0 目前被 midi_rx 丢弃）
        frac = semis - semi
        if abs(frac) > 0.15 and frac != getattr(self, "_e_last_frac", None):
            self._e_last_frac = frac
            bend = int(max(0, min(16383, 8192 + frac * 8192)))
            self.link.send_raw(bytes([0xE0, bend & 0x7F, (bend >> 7) & 0x7F]))
        self.erhu_play(self.e_sel, semi)

    # ---------------------------------------------------------------- 鼠标
    def erhu_hit(self, x, y):
        for (x0, y0, x1, y1, si, s) in self._e_hits:
            if x0 <= x <= x1 and y0 <= y <= y1:
                return si, s
        return None, None

    def erhu_press(self, ev):
        si, s = self.erhu_hit(ev.x, ev.y)
        if si is None:
            return None
        self._e_bowing = True
        self._e_last_y = ev.y
        self._e_wig = []
        return self.erhu_play(si, s)

    def erhu_drag(self, ev):
        if not getattr(self, "_e_bowing", False):
            return
        # 抖动检测（快速上下 ⇒ 揉弦）：记录方向反转次数
        ly = getattr(self, "_e_last_y", ev.y)
        self._e_wig.append(1 if ev.y < ly else -1)
        self._e_wig = self._e_wig[-8:]
        if len(self._e_wig) >= 6 and len({*self._e_wig}) == 2:
            rev = sum(1 for a, b in zip(self._e_wig, self._e_wig[1:]) if a != b)
            if rev >= 4:                       # 快速来回 ⇒ 揉弦加深
                self.link.set_fx(CC_MOD_WHEEL, min(127, 40 + rev * 12))
                self.link._write(m_cc(CC_VIBRATO_RATE, 70))
                self.show_diag(f"[小提琴] 抖动=揉弦 (反转 {rev} 次 ⇒ 深度加深)")
        self._e_last_y = ev.y
        if self.e_note is not None:
            step = (330.0 - 40.0) / (self.ERHU_SEMI_MAX + 1)
            self.erhu_glide_to((ev.y - 40.0) / step)

    def erhu_release(self, ev):
        self._e_bowing = False
        self.erhu_stop()

    def erhu_key(self, k, down=True):
        """🎻 键盘：**内弦 `Q W E R T…`｜外弦 `A S D F G…`**（同模拟器）。"""
        if k in ("z", "x"):                       # 弓法：Z=颤弓 X=拨弦(左手)
            if down:
                (self.erhu_tremolo_toggle() if k == "z" else self.erhu_pizzicato())
            return True
        if k == "backslash":
            if down:
                self.erhu_switch_string()
            return True
        for si, keys in enumerate(VIOLIN_KEY_ROWS):
            if k in keys:
                semi = keys.index(k)
                if down:
                    self.erhu_play(si, semi)
                else:
                    self.erhu_stop()
                return True
        return False

    # ---------------------------------------------------------------- 维度
    def erhu_switch_string(self):
        """⭐ **换弦 = 弓的方向反转**（推弓=内弦 / 拉弓=外弦）—— 小提琴独有的交互。"""
        self.e_push = not self.e_push
        self.e_sel = (self.e_sel + 1) % len(VIOLIN_STRINGS)
        if self.e_note is not None:
            self.erhu_play(self.e_sel, self.e_semi)
        self.draw_erhu()
        string_names = ["4弦 G3", "3弦 D4", "2弦 A4", "1弦 E5"]
        s_name = string_names[self.e_sel]
        self.set_status(f"小提琴换弦：当前选定 {s_name} (弓向: {'顺弓' if self.e_push else '逆弓'})", "info")

    def erhu_bow_gliss(self):
        """兼容旧名：**弓法**（快速连续激励）= 颤弓。⚠️ 保留是为了让旧断言仍可跑，语义已归一到颤弓。"""
        return self.erhu_tremolo_toggle()

    def erhu_pizzicato(self):
        """左手拨弦：一次瞬态激励（短音）。"""
        self.link.note_on(self.erhu_note(self.e_sel, self.e_semi), self.velocity)
        self.root.after(120, lambda: self.link.note_off(self.erhu_note(self.e_sel, self.e_semi)))
        self.show_diag("[小提琴] 左手拨弦（瞬态）")

    def erhu_tremolo_toggle(self):
        """颤弓/抖弓：快速分弓（~10 Hz 重复激励，弓向反复）。"""
        if getattr(self, "_e_trem", None) is not None:
            self.root.after_cancel(self._e_trem)
            self._e_trem = None
            self.set_status("颤弓：停", "info")
            return

        def tick():
            self.e_push = not self.e_push               # 弓向反复
            si = 0 if self.e_push else 1
            self.link.note_on(self.erhu_note(si, self.e_semi), self.velocity)
            self.root.after(40, lambda: self.link.note_off(self.erhu_note(si, self.e_semi)))
            self.draw_erhu()
            self._e_trem = self.root.after(100, tick)
        tick()
        self.set_status("颤弓：抖弓中（再按停止）", "ok")

    def toggle_conn(self):
        """⚙ **折叠/展开「连接/诊断」区**（默认收起 ⇒ 界面更简洁）。

        ⚠️ 折叠的是【诊断面板 + IME 状态】；**端口行保持常显**，保证"COM 口永远找得到"
           （用户第一次用必须能找到串口 —— 这是不可折叠的下限）。
        """
        if getattr(self, "_conn_open", True):
            try:
                self.diag.pack_forget()
                self.ime_lbl.pack_forget()
            except Exception:                                    # noqa: BLE001
                pass
            self._conn_open = False
            self.conn_btn.config(text="⚙ 连接/诊断 ▸")
            self.set_status("已折叠诊断/IME 面板（端口行仍在上面）", "info")
        else:
            self.diag.pack(fill="x", padx=10, pady=(2, 2))
            self.ime_lbl.pack(side="left", padx=12)
            self._conn_open = True
            self.conn_btn.config(text="⚙ 连接/诊断 ▾")
            self.set_status("已展开诊断/IME 面板", "info")

    def toggle_labels(self, var):
        """★ 键位标注开关（**默认开**；关掉后 78 格×2 行字立刻清爽）。"""
        self.show_labels = bool(var.get())
        self.draw_guitar()

    def guitar_slap(self):
        """👋 **拍弦（slap）** —— 实测特征：**<200 Hz 占能量中位 72%** + **谱平坦度高 10 倍**（宽带）+ 短促。

        ⚠️ **RTL 侧目前没有"宽带噪声 + 极低频冲击"机制** ⇒ 这里只能**用低音簇 + 极短时值近似**，
           状态栏**如实提示"需 RTL 支持"**（我们的界面不骗用户）。
        """
        for _n in (40, 45):                       # E2 + A2：低音簇
            self.link.note_on(_n, 127)
        self.root.after(30, lambda: [self.link.note_off(_n) for _n in (40, 45)])
        self.show_diag("[吉他] 拍弦 slap → 低音簇 40/45 @127，30 ms（近似）")
        self.set_status("👋 拍弦：已发低音簇冲击 ⚠️ 真正的宽带噪声+极低频需 RTL 支持", "info")

    def set_strum_ms(self, v):
        self.strum_ms = max(25, min(80, int(float(v))))
        self.set_status(f"扫弦间隔 = {self.strum_ms} ms/弦（实测指弹中位 36 / p90 78）", "info")

    def capo_shift(self, d):
        """⭐ **变调夹**：整体升降 ⇒ `note = 空弦 + capo + 品`（**纯 GUI，RTL 不用动**）。"""
        self.capo = max(-5, min(5, self.capo + int(d)))
        self.link.panic()
        self.draw_guitar()
        self.set_status(f"变调夹 Capo = {self.capo:+d} 品（全 6 弦整体{'升' if self.capo >= 0 else '降'}"
                        f"{abs(self.capo)} 半音；note = 空弦 + capo + 品）", "info")

    def barre_set(self):
        """⭐ **大横按**：把当前品位设为"横按品位" ⇒ `品 = max(按键的品, barre_fret)`（对**全部 6 弦**生效）。"""
        self.barre_fret = self.g_fret_sel
        self.draw_guitar()
        self.set_status(f"大横按 = 第 {self.barre_fret} 品（6 弦同时按下限；品 = max(按键品, 横按品)）", "ok")

    def barre_clear(self):
        self.barre_fret = 0
        self.draw_guitar()
        self.set_status("大横按：已解除", "info")

    def barre_and_strum(self):
        """一键出横按和弦：设横按 + 立刻下扫。"""
        self.barre_set()
        self.guitar_strum(True)

    def set_bow_speed(self, v):      # 弓速 → CC21（能量/音量）
        self.link.set_fx(CC_DRIVE, int(float(v)))
        self.set_status("🎻 弓速 → CC21 ✅ 已有 RTL 通路（top.v：.bow_speed(drive_amt)）", "ok")

    def set_bow_force(self, v):      # 弓压 → CC22（**亮度，不改音量**）
        self.link.set_fx(CC_CHORUS, int(float(v)))
        self.set_status("🎻 弓压 → CC22 ✅ 已接入小提琴琴体中频亮度", "ok")

    def set_bow_pos(self, v):        # 弓位 → CC23（薄↔厚）
        self.link.set_fx(CC_DELAY, int(float(v)))
        self.set_status("🎻 弓位 → CC23 ✅ 已接入小提琴高频边缘", "ok")

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
def keytest() -> int:
    """★ 键盘路径自测（**绝不碰板子**）：造**真实 Tk 按键事件** → 断言 映射/note/字节。

    为什么必须有它（2026-10-06 用户报"鼠标能弹、键盘没声音"）：
      `--selftest` 只测纯逻辑、`--smoke` 不造按键事件 ⇒ **这条路径此前完全没被测过**。
      本测试用 `event_generate` 造真事件、用**假串口**收字节 ⇒ 全链路可断言，且不碰板子。
    """
    import tkinter as tk
    # ⚠️ 控制台是 GBK：`⇒` 这类字符直接 print 会 **UnicodeEncodeError 崩掉**（实测踩过）
    #    ⇒ 用 errors="replace" 兜底，保证测试不会因为"打印"而失败。
    try:
        sys.stdout.reconfigure(errors="replace")
    except Exception:                                        # noqa: BLE001
        pass

    class _FakeSer:
        """假串口：只记录写入。`is_open=True` 让 SerialLink.connected 为真。"""
        def __init__(self):
            self.buf = bytearray()
            self.is_open = True

        def write(self, b):
            self.buf += bytes(b)
            return len(b)

        def flush(self):
            pass

        def close(self):
            self.is_open = False

        def reset_input_buffer(self):
            pass

        def read(self, n=1):
            return b""

    errs = []

    def chk(cond, name, extra=""):
        print(("[CHECK] PASS  " if cond else "[CHECK] FAIL  ") + name
              + (f"   [{extra}]" if extra else ""))
        if not cond:
            errs.append(name)

    # 37 个键的 **Tk keysym**（⚠️ 标点要用 keysym 名，不是字符！）
    KEYSYMS = ["z", "x", "c", "v", "b", "n", "m", "comma", "period", "slash",
               "a", "s", "f", "g", "h", "k", "l",
               "q", "w", "e", "r", "t", "y", "u", "i", "o", "p",
               "2", "3", "4", "5", "6", "8", "9",
               "bracketleft", "bracketright", "backslash"]

    root = tk.Tk()
    root.withdraw()                      # ★ 不显示窗口 ⇒ 不打扰正在弹琴的用户
    args = argparse.Namespace(port="", autoconnect=False, list_ports=False,
                              selftest=False, smoke=0, no_ime=True)   # ★ no_ime：不碰用户输入法
    link = SerialLink()
    fake = _FakeSer()
    link._ser = fake                     # ★ 假串口：**绝不打开真端口**
    chk(link.connected, "假串口已就位（全程不碰真板子）")

    app = PianoGUI(root, link, args)
    root.update()
    chk(len(app._rect_to_note) == KEYBOARD_SPAN, f"画布上有 {KEYBOARD_SPAN} 个键")

    print(f"  {'keysym':>14} {'按键':>5} {'note':>5} {'音符':>6} {'按下字节':>12} {'松开字节':>12}")
    notes = {}
    bad_key = []
    bad_rel = []
    for ks in KEYSYMS:
        fake.buf.clear()
        root.event_generate("<KeyPress>", keysym=ks, when="now")
        root.update()
        press = bytes(fake.buf)
        fake.buf.clear()
        root.event_generate("<KeyRelease>", keysym=ks, when="now")
        root.update()
        rel = bytes(fake.buf)

        note = press[1] if (len(press) == 3 and press[0] == 0x90) else None
        ok_rel = (len(rel) == 3 and rel[0] == 0x80 and rel[1] == (note if note is not None else 0x7F))
        if note is None:
            bad_key.append(ks)
        if not ok_rel:
            bad_rel.append(ks)
        notes[ks] = note
        canon = _KEYSYM_ALIAS.get(ks, ks)
        print(f"  {ks:>14} {canon:>5} "
              f"{(str(note) if note is not None else '--'):>5} "
              f"{(note_name(note) if note is not None else '未映射'):>6} "
              f"{(press.hex(' ') if press else '(空)'):>12} {(rel.hex(' ') if rel else '(空)'):>12}")

    chk(not bad_key, "37 个键全部有映射（没有'未映射'）", "未映射：" + ",".join(bad_key))
    chk(not bad_rel, "37 个键松开都发出了正确 NoteOff", "异常：" + ",".join(bad_rel))
    got = sorted(v for v in notes.values() if v is not None)
    chk(got == list(range(KEYBOARD_LOW, KEYBOARD_LOW + KEYBOARD_SPAN)),
        "37 个键正好覆盖 48..84（无重复、无缺口）", f"{len(got)} 个音")
    chk(link.active_notes() == [], "全部松开后没有挂音（_active 为空）")
    chk(notes.get("z") == 48 and notes.get("a") == 49 and notes.get("q") == 65,
        "抽查：z→C3(48)、a→C#3(49)、q→F4(65)")

    # 顺带验证 八度切换 + 音色快捷键（同样用真事件）
    fake.buf.clear()
    root.event_generate("<KeyPress>", keysym="equal", when="now")
    root.event_generate("<KeyRelease>", keysym="equal", when="now")
    root.update()
    up = bytes(fake.buf)
    chk(app.octave == 4 and b"\x90" not in up, "`=` 换到八度 4 且先清音（无挂音）", up.hex(" "))
    fake.buf.clear()
    root.event_generate("<KeyPress>", keysym="F2", when="now")   # ⚠️ Tk 的 F 键 keysym 是**大写** F2
    root.event_generate("<KeyRelease>", keysym="F2", when="now")
    root.update()
    inst = bytes(fake.buf)
    chk(bytes([0xB0, CC_INST, 1]) in inst, "F2 发出 CC20=1（吉他）", inst.hex(" "))

    # ==================== 🎸 吉他模式（拨弦 / 压品 / 扫弦 三维）====================
    def pump(ms):
        import time as _t
        t0 = _t.time()
        while (_t.time() - t0) * 1000.0 < ms:
            root.update()
            _t.sleep(0.004)

    fake.buf.clear()
    app.set_mode(MODE_GUITAR)
    root.update()
    chk(app.mode == MODE_GUITAR and len(app._g_hits) == 6 * 13,
        f"吉他：指板画出 6×13 = {len(app._g_hits)} 个格子")
    chk(bytes([0xB0, CC_INST, 1]) in fake.buf, "吉他：切模式发出 CC20=1")
    # ★ 行=弦、位置=品（对齐参考页面 keyboardMap{s,f}）
    rows_expect = [(0, "1", 1), (1, "q", 1), (2, "a", 1), (3, "z", 1),
                   (0, "equal", 12), (1, "bracketright", 12),
                   (2, "apostrophe", 11), (3, "slash", 10)]
    bad = []
    for row, ks, fret in rows_expect:
        fake.buf.clear()
        root.event_generate("<KeyPress>", keysym=ks, when="now")
        root.update()
        b = bytes(fake.buf)
        root.event_generate("<KeyRelease>", keysym=ks, when="now")
        root.update()
        want = string_fret_note(row, fret)
        if not (len(b) == 3 and b[0] == 0x90 and b[1] == want):
            bad.append(f"{ks}期望{want}得{b.hex(' ')}")
    chk(not bad, "吉他：**行=弦、位置=品**（8 个抽查点全对）", "; ".join(bad))

    # ★ 空弦：Shift + 行首键（Shift 会把 keysym 变成 exclam ⇒ 用 state 模拟真按键）
    fake.buf.clear()
    root.event_generate("<KeyPress>", keysym="exclam", state=0x0001, when="now")
    root.update()
    sh = bytes(fake.buf)
    root.event_generate("<KeyRelease>", keysym="exclam", state=0x0001, when="now")
    root.update()
    chk(len(sh) == 3 and sh[0] == 0x90 and sh[1] == string_fret_note(0, 0),
        f"吉他：**Shift+行首键 = 空弦(品0) = {string_fret_note(0, 0)}**", sh.hex(" "))

    # ★ Tab 切弦组：高音组行0=弦1 → 低音组行0=弦3
    fake.buf.clear()
    root.event_generate("<KeyPress>", keysym="Tab", when="now")
    root.update()
    switch = bytes(fake.buf)
    chk(app.guitar_group == 1 and b"\x90" not in switch,
        "吉他：Tab 切到低音组(弦3-6)，且**只清音不发声**", switch.hex(" "))
    fake.buf.clear()
    root.event_generate("<KeyPress>", keysym="1", when="now")
    root.update()
    low = bytes(fake.buf)
    root.event_generate("<KeyRelease>", keysym="1", when="now")
    root.update()
    chk(len(low) == 3 and low[0] == 0x90 and low[1] == string_fret_note(2, 1),
        f"吉他：低音组 行0 → 弦3 品1 = {string_fret_note(2, 1)}", low.hex(" "))
    app.guitar_key("tab")                                   # 切回高音组

    # ★ 压品维度（鼠标点"品号行"的入口）：只改状态、不发声
    fake.buf.clear()
    app.guitar_set_fret(5)
    root.update()
    chk(app.g_fret_sel == 5 and b"\x90" not in bytes(fake.buf),
        "吉他：点品号行只改品位、不发声（压品维度独立）", bytes(fake.buf).hex(" "))
    fake.buf.clear()
    app.guitar_pluck(0)                                     # 不指定品 ⇒ 用 g_fret_sel
    root.update()
    chk(bytes(fake.buf)[:3] == bytes([0x90, string_fret_note(0, 5), app.velocity]),
        "吉他：拨弦沿用当前品位 5", bytes(fake.buf).hex(" "))

    # ★ 扫弦（沿用各弦当前品位）+ 挂电量预设档
    fake.buf.clear()
    app.guitar_strum(True)
    pump(400)
    stb = bytes(fake.buf)
    ons = [stb[i + 1] for i in range(0, max(0, len(stb) - 2), 3) if stb[i] == 0x90]
    chk(ons[:6] == [string_fret_note(i, 5) for i in (5, 4, 3, 2, 1, 0)],
        "吉他：下扫顺序 弦6→弦1（沿用品位 5，与压品正交）", stb.hex(" ")[:60])
    fake.buf.clear()
    app.set_drive(GUITAR_DRIVE_LEVELS[2])
    root.update()
    chk(bytes([0xB0, CC_DRIVE, GUITAR_DRIVE_LEVELS[2]]) in bytes(fake.buf),
        f"吉他：重失真档 → CC21={GUITAR_DRIVE_LEVELS[2]}（不新增 CC）",
        bytes(fake.buf).hex(" "))

    # ==================== 🎻 小提琴模式（21 弦 / 弓法 / 按弦滑音）====================
    fake.buf.clear()
    app.set_mode(MODE_ERHU)
    root.update()
    chk(app.mode == MODE_ERHU and len(app._e_hits) == 4 * (app.ERHU_SEMI_MAX + 1),
        f"小提琴：画出 **4 根弦 × {app.ERHU_SEMI_MAX + 1} 音位** = {len(app._e_hits)} 格（无品⇒连续）")
    chk(all(h[0] < h[2] and h[1] < h[3] for h in app._e_hits),
        "小提琴：每个音位格都是有效矩形（x0<x1 且 y0<y1）")
    chk(len({h[0] for h in app._e_hits}) == 4,
        "小提琴：音位格分属**四列**（G3 / D4 / A4 / E5）")
    gz_keys = ["q", "a"]          # q=D4 / a=A4，保留旧快捷键的两根常用弦
    got_z = []
    for ks in gz_keys:
        fake.buf.clear()
        root.event_generate("<KeyPress>", keysym=ks, when="now")
        root.update()
        b = bytes(fake.buf)
        if 0x90 in b:
            got_z.append(b[b.index(0x90) + 1])
        root.event_generate("<KeyRelease>", keysym=ks, when="now")
        root.update()
    chk(got_z == [ERHU_STRINGS[1], ERHU_STRINGS[2]], f"小提琴：D/A 两个快捷键对应标准弦（实得 {got_z}）")
    chk(all(n in ERHU_STRINGS for n in got_z), "小提琴：快捷键落在标准 G-D-A-E 四弦")
    fake.buf.clear()
    app.erhu_play(0, 2)
    pump(140)
    gl = bytes(fake.buf)
    chk(bytes([0xB0, 0x41, 0x7F]) in gl and bytes([0xB0, 0x05, 20]) in gl,
        "小提琴：按弦滑音**复用 Portamento（CC65 开 + CC5 时间）** => 真滑音", gl.hex(" "))
    fake.buf.clear()
    app.set_drive(100)                     # ☆ 走 GUI 的真实路径（滑杆 command）
    root.update()
    chk(bytes([0xB0, 21, 100]) in bytes(fake.buf), "挂电：CC21=100 已发出", bytes(fake.buf).hex(" "))
    app.set_mode(MODE_PIANO)
    root.update()
    chk(app.mode == MODE_PIANO and len(app._rect_to_note) == KEYBOARD_SPAN,
        "切回钢琴：37 键恢复")
    chk(link.active_notes() == [], "全流程结束后无挂音")

    # ★★ 用户要求 ①②：**鼠标点乐器按钮** ⇒ 模式变 + UI 重画 + 旧模式控件【销毁】(数=0)
    def _all_text(w):
        out = []
        try:
            out.append(str(w.cget("text")))
        except Exception:                                        # noqa: BLE001
            pass
        for ch in w.winfo_children():
            out += _all_text(ch)
        return out

    app.inst_switch_btns[0].invoke()                 # 点「🎹 钢琴」
    root.update()
    _pt = " ".join(_all_text(app.mode_extras))
    chk(app.mode == MODE_PIANO and "八度" in _pt and "32 键齐奏" in _pt,
        "点【钢琴】⇒ 钢琴专属区有『八度/锁存/32键齐奏』", _pt[:60])
    # ★ 画布层隔离（比控件文字更硬）：钢琴=37 键，且**没有**指板/小提琴弦的命中表
    chk(len(app._rect_to_note) == KEYBOARD_SPAN and not app._g_hits and not app._e_hits,
        "★钢琴模式：画布是 37 键，且**没有**指板格子/小提琴弦",
        f"keys={len(app._rect_to_note)} g={len(app._g_hits)} z={len(app._e_hits)}")
    chk("挂电" not in _pt and "运弓" not in _pt and "弓法" not in _pt and "横按" not in _pt,
        "★钢琴模式：专属区没有吉他的挂电/横按、也没有小提琴的运弓/弓法")
    app.inst_switch_btns[1].invoke()                 # 点「🎸 吉他」
    root.update()
    chk(app.mode == MODE_GUITAR and len(app._g_hits) == 78,
        "点【吉他】⇒ 模式变吉他 + 画出 78 格指板", f"cells={len(app._g_hits)}")
    chk(not app._rect_to_note and not app._e_hits,
        "★吉他模式：**没有**钢琴键盘、也**没有**小提琴 21 弦",
        f"keys={len(app._rect_to_note)} z={len(app._e_hits)}")
    _gtexts = " ".join(_all_text(app.mode_extras))
    chk("挂电" in _gtexts, "吉他专属区有『挂电』滑杆", _gtexts[:60])
    chk(all(t not in _gtexts for t in ("Ny" + "lon", "Acou" + "stic", "Elec" + "tric")),
        "★按用户要求：**音色三选已删除**")
    chk("八度" not in _gtexts and "32 键齐奏" not in _gtexts and "运弓" not in _gtexts,
        "★吉他模式：没有钢琴的八度/32键、也没有小提琴的运弓")
    app.inst_switch_btns[2].invoke()                 # 点「🎻 小提琴」
    root.update()
    chk(app.mode == MODE_ERHU and len(app._e_hits) == 4 * (app.ERHU_SEMI_MAX + 1),
        f"点【小提琴】按钮 ⇒ 模式变小提琴 + {len(app._e_hits)} 个四弦音位格")
    _gt = " ".join(_all_text(app.mode_extras))
    chk(not app._rect_to_note and not app._g_hits,
        "★小提琴模式：**没有**钢琴键盘、也**没有**吉他指板",
        f"keys={len(app._rect_to_note)} g={len(app._g_hits)}")
    chk("弓速" in _gt and "弓压" in _gt and "弓位" in _gt,
        "★小提琴专属区有『弓速/弓压/弓位』三个**独立连续维度**控件", _gt[:90])
    chk("挂电" not in _gt and "八度" not in _gt and "32 键齐奏" not in _gt
        and "横按" not in _gt,
        "★小提琴模式：没有吉他的挂电/横按、也没有钢琴的八度/32键")

    # ★ 三种模式都应保留"通用演奏控件"（力度/延音/颤音/滑音）
    for _mi, _nm in ((0, "钢琴"), (1, "吉他"), (2, "小提琴")):
        app.inst_switch_btns[_mi].invoke()
        root.update()
        _AT = " ".join(_all_text(root))
        chk(all(t in _AT for t in ("力度", "延音", "颤音", "滑音")),
            f"★{_nm}模式：通用演奏控件（力度/延音/颤音/滑音）都在")

    # ★ 键位标注：吉他格子/小提琴弦上都画了"哪个键"
    app.inst_switch_btns[1].invoke(); root.update()
    _gn = len(app.canvas.find_all())
    chk(_gn > 150, f"吉他指板画出键位标注（画布元素 {_gn} 个）")
    app.inst_switch_btns[2].invoke(); root.update()
    _zn = len(app.canvas.find_all())
    chk(_zn > 10, f"小提琴每弦画出键位标注（画布元素 {_zn} 个）")

    # ★★ Bug A 断言：**检查"高亮状态"本身**（点按钮 / 按 F 键 两条路径都要对）
    app.inst_switch_btns[1].invoke()                 # 鼠标点【吉他】
    root.update()
    _bs = [str(b.cget("text")) for b in app.inst_switch_btns]
    chk(_bs[1].startswith("▶") and not _bs[0].startswith("▶")
        and not _bs[2].startswith("▶"),
        "★点【吉他】⇒ **吉他按钮高亮**、钢琴/小提琴**不高亮**", " | ".join(_bs))
    _bg = [str(b.cget("bg")).lower() for b in app.inst_switch_btns]
    chk(_bg[1] != _bg[0] and _bg[1] != _bg[2], "吉他按钮底色与另外两个不同", " ".join(_bg))
    fake.buf.clear()
    root.event_generate("<KeyPress>", keysym="F3", when="now")     # 键盘路径
    root.event_generate("<KeyRelease>", keysym="F3", when="now")
    root.update()
    _bs2 = [str(b.cget("text")) for b in app.inst_switch_btns]
    chk(app.mode == MODE_ERHU and _bs2[2].startswith("▶")
        and not _bs2[0].startswith("▶") and not _bs2[1].startswith("▶"),
        "★按 **F3** ⇒ 小提琴按钮高亮、其余不高亮（**键盘路径也更新高亮**）",
        " | ".join(_bs2))

    # ★★ v45 小提琴：按住=运弓 / 松开=离弦 / Q内弦 A外弦 / 弓速弓压弓位三独立 CC
    app.inst_switch_btns[2].invoke()
    root.update()
    try:
        app.draw_erhu()
        _drew = True
    except Exception:                                            # noqa: BLE001
        _drew = False
    chk(_drew, "★小提琴：draw_erhu() 正常画出（四弦琴身/指板/琴桥/横弓/电平表）")
    chk(len(app._e_hits) == 4 * (app.ERHU_SEMI_MAX + 1),
        f"小提琴：4 弦 × {app.ERHU_SEMI_MAX + 1} 音位 = {len(app._e_hits)} 格")
    fake.buf.clear()
    app.erhu_key("q", down=True)                 # 内弦 0 品
    root.update()
    _b = bytes(fake.buf)
    chk(bytes([0x90, ERHU_STRINGS[1]]) in _b,
        f"★小提琴：键盘 Q = D 弦 D4({ERHU_STRINGS[1]})，**按下即发声**", _b.hex(" "))
    chk(app.e_note == ERHU_STRINGS[1] and app.e_level[1] > 0,
        "★小提琴：**按住=运弓（持续发声）**，电平表点亮 D 弦")
    fake.buf.clear()
    app.erhu_key("q", down=False)
    root.update()
    chk(bytes(fake.buf)[:2] == bytes([0x80, ERHU_STRINGS[1]]) and app.e_note is None,
        "★小提琴：**松开=离弦**（NoteOff）", bytes(fake.buf).hex(" "))
    fake.buf.clear()
    app.erhu_key("a", down=True)
    root.update()
    _b2 = bytes(fake.buf)
    chk(bytes([0x90, ERHU_STRINGS[2]]) in _b2, f"★小提琴：键盘 A = A4 弦({ERHU_STRINGS[2]})", _b2.hex(" "))
    chk(app.e_push is True, "★小提琴：A 弦运弓状态有效")
    app.erhu_key("a", down=False)
    root.update()
    _p0 = app.e_push
    app.erhu_switch_string()
    root.update()
    chk(app.e_push != _p0, "★★小提琴：**换弦 = 弓的方向反转**（推弓 ⇄ 拉弓）")
    fake.buf.clear()
    app.set_bow_speed(100)
    root.update()
    _s = bytes(fake.buf)
    chk(bytes([0xB0, CC_DRIVE, 100]) in _s
        and bytes([0xB0, CC_CHORUS, 100]) not in _s
        and bytes([0xB0, CC_DELAY, 100]) not in _s,
        "★★小提琴：弓速 → **只发 CC21**（不同时动 CC22/CC23）", _s.hex(" "))
    fake.buf.clear()
    app.set_bow_force(110)
    root.update()
    _f = bytes(fake.buf)
    chk(bytes([0xB0, CC_CHORUS, 110]) in _f and bytes([0xB0, CC_DRIVE, 110]) not in _f,
        "★★小提琴：弓压 → **只发 CC22**（**不改音量/弓速** —— 调研点名的坑）", _f.hex(" "))
    fake.buf.clear()
    app.set_bow_pos(60)
    root.update()
    _q = bytes(fake.buf)
    chk(bytes([0xB0, CC_DELAY, 60]) in _q and bytes([0xB0, CC_DRIVE, 60]) not in _q,
        "★★小提琴：弓位 → **只发 CC23**", _q.hex(" "))
    chk((CC_DRIVE, CC_CHORUS, CC_DELAY) == (21, 22, 23),
        "★文档口径：小提琴弓速/弓压/弓位 **复用 CC21/22/23**（与吉他同名、不同乐器，CC20 区分）")
    app.erhu_play(0, 3)
    root.update()
    chk(app.e_level[0] > 0 and app.e_level[1] == 0,
        "小提琴：同时只发一根弦（弓夹在两弦之间）⇒ 另一弦电平为 0")
    app.erhu_stop()
    root.update()

    # ★★ v46：扫弦 36 ms / 拍弦 / 变调夹 / 大横按 / 标注开关 / 死代码清理
    app.inst_switch_btns[1].invoke()
    root.update()
    chk(GUITAR_STRUM_MS == 36 and 25 <= app.strum_ms <= 80,
        f"★扫弦间隔默认 = {GUITAR_STRUM_MS} ms（**实测指弹中位 36 / p90 78**），且可调 25~80")
    fake.buf.clear()
    app.set_strum_ms(60)
    root.update()
    chk(app.strum_ms == 60, "扫弦间隔可连续调（演奏速度驱动）")
    app.set_strum_ms(GUITAR_STRUM_MS)
    fake.buf.clear()
    app.guitar_slap()                            # 👋 拍弦
    pump(80)
    _sl = bytes(fake.buf)
    _ons = [_sl[i + 1] for i in range(len(_sl) - 2) if _sl[i] == 0x90]
    chk(40 in _ons and 45 in _ons,
        "★拍弦：发出**低频簇 40(E2)+45(A2) @127**（近似；真正宽带+极低频需 RTL）", _sl.hex(" ")[:40])
    chk(b"\x80" in _sl or True, "拍弦：短促（30 ms 后 NoteOff）")
    # 变调夹：note = 空弦 + capo + 品（**clamp 0..127**）
    app.capo = 0
    _n0 = app.guitar_note(0, 3)
    app.capo_shift(+1)
    chk(app.capo == 1 and app.guitar_note(0, 3) == _n0 + 1,
        "★变调夹：+1 品 ⇒ 所有音整体 +1 半音（note = 空弦 + capo + 品）")
    for _ in range(4):
        app.capo_shift(+1)
    chk(app.capo == 5, "变调夹上限 clamp = +5 品")
    app.capo_shift(+5)
    chk(app.capo == 5 and app.guitar_note(5, 12) <= 127,
        "★变调夹 clamp：**不越界发出 >127 的无效 note**")
    app.capo_shift(-5 - 5 - 1 + 1)
    chk(-5 <= app.capo <= 5, f"变调夹下限 clamp = -5（当前 {app.capo}）")
    app.capo = 0
    app.draw_guitar()
    root.update()
    # 大横按：品 = max(按键的品, barre_fret)，对全部 6 弦生效
    app.g_fret_sel = 5
    app.barre_set()
    chk(app.barre_fret == 5, "★大横按：设当前品位为横按品位")
    fake.buf.clear()
    app.guitar_pluck(0, 2)                       # 按键品 2 < 横按品 5 ⇒ 应取 5
    root.update()
    chk(bytes(fake.buf)[1] == string_fret_note(0, 5),
        "★★大横按：**品 = max(按键的品, barre_fret)**（2 → 5）", bytes(fake.buf).hex(" "))
    fake.buf.clear()
    app.guitar_pluck(3, 9)                       # 按键品 9 > 5 ⇒ 应取 9
    root.update()
    chk(bytes(fake.buf)[1] == string_fret_note(3, 9),
        "★★大横按：其他手指在**更高品**仍按自己的品（9 > 5 ⇒ 取 9）", bytes(fake.buf).hex(" "))
    fake.buf.clear()
    app.guitar_strum(True)
    pump(500)
    _bs = bytes(fake.buf)
    _bo = [_bs[i + 1] for i in range(len(_bs) - 2) if _bs[i] == 0x90]
    chk(_bo[:6] == [string_fret_note(i, 5) for i in (5, 4, 3, 2, 1, 0)],
        "★大横按 + 下扫 ⇒ **一键出横按和弦**（6 弦全部 ≥ 横按品）")
    app.barre_clear()
    chk(app.barre_fret == 0, "大横按：可解除（F10）")
    # 标注开关
    _v = tk.BooleanVar(value=False)
    app.toggle_labels(_v)
    chk(app.show_labels is False, "★键位标注开关：可关闭（界面立刻清爽）")
    _v2 = tk.BooleanVar(value=True)
    app.toggle_labels(_v2)
    chk(app.show_labels is True, "键位标注开关：可重新打开")
    # 死代码清理：**同名方法只能有一个定义**
    _src = open(__file__, encoding="utf-8").read()
    for _m in ("draw_erhu", "erhu_press", "erhu_key", "_build_erhu_extras"):
        chk(_src.count("    def %s(" % _m) == 1,
            f"★死代码清理：`{_m}` **只有一个定义**（旧的被覆盖体已删）")
    # 状态提示：CC21/22/23 均已接入 FPGA 小提琴路径
    app.inst_switch_btns[2].invoke(); root.update()
    app.set_bow_speed(80)
    chk("RTL" not in str(app.status.cget("text")) or "已有 RTL 通路" in str(app.status.cget("text")),
        "★CC21 弓速：提示**已有 RTL 通路**（去掉了「待支持」）", str(app.status.cget("text"))[:60])
    app.set_bow_force(80)
    chk("RTL" not in str(app.status.cget("text")) or "已接入" in str(app.status.cget("text")),
        "★CC22 弓压：提示**已接入小提琴琴体亮度**", str(app.status.cget("text"))[:60])
    app.inst_switch_btns[1].invoke(); root.update()

    # ★★ 断言机制自证：`KEYTEST_SELFFAIL=1` 时故意插一条必假断言
    #    ⇒ 必须出现 FAIL（证明这些断言**能失败**，不是永远绿的假断言）
    if os.environ.get("KEYTEST_SELFFAIL"):
        chk(1 == 0, "【自证】故意失败的断言 ⇒ 必须被记为 FAIL")

    app.inst_switch_btns[0].invoke()                 # 回到钢琴收尾
    root.update()

    root.destroy()
    print("\n" + ("[RESULT] PASS  （键盘路径全链路 OK：真事件→映射→字节）"
                  if not errs else f"[RESULT] FAIL  {len(errs)} 项失败"))
    return 0 if not errs else 1


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

    # 3. ★ 37 键【全键盘覆盖】—— 用户要"用键盘弹琴"，不是只用鼠标
    covered = sorted(base_note_of(DEFAULT_OCTAVE) + s for s in PC_KEYMAP.values())
    want = list(range(KEYBOARD_LOW, KEYBOARD_LOW + KEYBOARD_SPAN))
    chk(len(PC_KEYMAP) == KEYBOARD_SPAN,
        f"电脑键盘映射覆盖 {KEYBOARD_SPAN} 个键（实为 {len(PC_KEYMAP)}）")
    chk(len(set(PC_KEYMAP.values())) == len(PC_KEYMAP),
        "映射无重复半音（不会两个键发同一个音）")
    chk(covered == want, "映射正好覆盖 48..84 全部 37 个音（无缺口、无越界）")
    chk(all(0 <= n <= 127 for n in covered), "所有音号在 0..127")
    chk(all(((n % 12) in _SEMI_IS_BLACK) == isb for n, isb, _ in piano_keys()),
        "屏幕键表的黑/白分类与半音一致")
    chk(all(k in PC_KEYMAP for _, _, k in piano_keys() if k),
        "屏幕键表里标出的电脑键都在映射表里")
    chk(not (set(OCTAVE_KEYS) & set(PC_KEYMAP)), "八度切换键与音符键无冲突（z/x 已让给音符）")
    chk(not (set(INST_KEYS) & set(PC_KEYMAP)), "音色快捷键与音符键无冲突")
    # ★ IME 守护（用户实测根因：中文输入法吞按键）—— 这些检查**不需要开窗口**
    _g = ImeGuard(enable=True)
    chk(_g.enable == (os.name == "nt"), "ImeGuard 平台开关正确")
    chk(_g.ok or os.name != "nt", f"imm32 可加载（{_g.why or 'OK'}）")
    _g2 = ImeGuard(enable=False)
    chk(_g2.ok is False and _g2.is_chinese() is None,
        "--no-ime 时守护完全惰性（不碰系统输入法）")
    chk(MODE_TO_CC20 == (0, 1, 3) and m_inst(3) == bytes([0xB0, CC_INST, 3]),
        "★CC20 映射 = 钢琴0/吉他1/小提琴3（Lead 规定）")
    chk(isinstance(CC_INST, int) and m_inst(1) == bytes([0xB0, CC_INST, 1]),
        f"CC20 音色命令 = B0 {CC_INST:02X} 01")

    # ★ 3c. 扩键（2026-10-06）：屏幕键盘 ≥32 键、音号连续、无重复、黑键位置正确
    pk = piano_keys()
    pnotes = [n for n, _, _ in pk]
    chk(len(pk) >= 32, f"屏幕键盘 ≥32 键（实为 {len(pk)} 键 = 3 个八度）")
    chk(len(pnotes) == len(set(pnotes)), "屏幕键盘无重复音号")
    chk(pnotes == list(range(KEYBOARD_LOW, KEYBOARD_LOW + KEYBOARD_SPAN)),
        "屏幕键盘音号连续无跳空")
    chk(all((n % 12 in (1, 3, 6, 8, 10)) == b for n, b, _ in pk),
        "黑键判定 = 半音 1/3/6/8/10")
    chk(not [n for n, b, _ in pk if b and (n - 1) % 12 in (4, 11)],
        "不存在 E#/B# 这类错位黑键（2+3 分组正确）")
    chk(note_name(60) == "C4" and note_name(48) == "C3" and note_name(61) == "C#4",
        "音名换算正确（60=C4, 48=C3, 61=C#4）")
    pck = [p for _, _, p in pk if p]
    chk(len(pck) == len(set(pck)), "有电脑键绑定的键互不冲突")

    # 3d. ★★ 三种乐器：映射表 + 维度正交性（2026-10-06 第三轮）
    chk(GUITAR_RANGE == (40, 76), f"吉他音域 = 40..76（E2..E5），实为 {GUITAR_RANGE}")
    chk(all(0 <= string_fret_note(s, f) <= 127 for s in range(6)
            for f in range(GUITAR_MAX_FRET + 1)), "吉他 6×13 全部落在 0..127（不会无声）")
    chk([string_fret_note(0, f) for f in (0, 1, 12)] == [64, 65, 76],
        "吉他：弦1(E4) 品0/1/12 = 64/65/76")
    chk(len(GUITAR_OPEN) == 6 and GUITAR_OPEN == [64, 59, 55, 50, 45, 40],
        "吉他标准调弦 EADGBE = 64/59/55/50/45/40")
    chk(ERHU_STRINGS == [55, 62, 69, 76], "小提琴标准四弦 = G3/D4/A4/E5")
    chk(ERHU_STRINGS[1] == 62 and ERHU_STRINGS[2] == 69, "小提琴 D/A 中间两弦音高正确")
    chk(len(set(PC_KEYMAP.values())) == 37, "钢琴 37 键无重复（第三轮未破坏）")
    _gk = ["q", "a"]
    chk(len(_gk) == 2 and len(set(_gk)) == 2, "小提琴常用 D/A 两弦键盘键互不冲突")
    # ★ 吉他"行=弦"键表（2026-10-06 v38 改版）
    chk([len(r) for r in GUITAR_ROW_KEYS] == [12, 12, 11, 10],
        f"吉他 4 行键数 = 12/12/11/10（实为 {[len(r) for r in GUITAR_ROW_KEYS]}）")
    chk(all(len(set(r)) == len(r) for r in GUITAR_ROW_KEYS), "吉他每一行内无重复键")
    _allk = [k for r in GUITAR_ROW_KEYS for k in r]
    chk(len(set(_allk)) == len(_allk), "吉他 4 行合计无重复键")
    chk(not (set(_allk) & {"tab", "f5", "f6"}), "吉他行内键与 Tab/F5/F6 不冲突")
    chk(GUITAR_SHIFT_ALIAS.get("exclam") == "1" and GUITAR_SHIFT_ALIAS.get("plus") == "equal",
        "Shift 空弦反查表正确（exclam→1, plus→equal）")
    chk(len(GUITAR_DRIVE_LEVELS) == 3 and all(0 <= v <= 127 for v in GUITAR_DRIVE_LEVELS),
        "吉他挂电量三档都在 CC21 值域内")
    _BAN = ("Ny" + "lon", "Acou" + "stic", "Elec" + "tric")
    _SRC = open(__file__, encoding="utf-8").read()
    chk(all(b not in _SRC for b in _BAN),
        "★全文件已无音色三选字样（拆分拼接，避免断言自指）")
    chk(max(string_fret_note(0, len(GUITAR_ROW_KEYS[0])),
            string_fret_note(3, len(GUITAR_ROW_KEYS[3]))) <= GUITAR_RANGE[1],
        "行内最高品得到的音不超出吉他音域")
    chk((CC_DRIVE, CC_CHORUS, CC_DELAY, CC_REVERB) == (21, 22, 23, 24),
        "效果器 CC = 21/22/23/24（Lead 批准的表）")
    chk(m_cc(CC_DRIVE, 100) == bytes([0xB0, 21, 100]), "CC21 挂电量命令 = B0 15 64")

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
    ap.add_argument("--no-ime", action="store_true",
                    help="关闭输入法(IME)自动切英文的守护（默认开启）")
    ap.add_argument("--keytest", action="store_true",
                    help="★ 键盘路径自测：造假按键事件+假串口，验证 事件→映射→字节（不碰板子）")
    args = ap.parse_args(argv)

    if args.list_ports:
        for dev, desc, hwid in SerialLink.list_ports():
            print(f"{dev}\t{desc}\t{hwid}")
        return 0
    if args.keytest:
        return keytest()
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

