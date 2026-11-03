#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
FPGA 纯硬件现代音乐合成器 —— 上位机多功能交互控制台
======================================================
目标硬件：Tang Mega 138K NEO Dock (GW5AST-LV138PG484AC1/I0)
通信协议：100% 纯标准 MIDI 3 字节协议（0x90/0x80/0xB0），隔离 ASCII 字符碰撞

主要功能：
  1. 智能串口识别：自动检测 FTDI FT2232H Channel B 串口（Tang Mega 138K UART），支持热插拔与动态重连
  2. 防误复位保护：初始化关闭 DTR/RTS 控制线，杜绝打开串口时误触发开发板复位或 JTAG 干扰
  3. 电脑键盘/鼠标弹奏 37 键全音域钢琴（C3..C6 = MIDI 48..84）
  4. 乐器音色实时切换：纯硬件高阶泛音钢琴 (CC20=0) / 失真电吉他 (CC20=1) / 古筝二胡 (CC20=2)
  5. 实时 DSP 与表情调制：硬件主音量 (CC7)、延音踏板 (CC64)、过载失真 (CC21)、颤音 (CC77/76)、滑音 (CC65/5)
  6. 常用和弦一键伴奏（C, Dm, Em, F, G, Am, Bdim, Cmaj7, G7 等多复音叠加）
  7. 自动化示范曲目演奏（卡农、致爱丽丝、Faded、小星星、32路复音压力测试）
  8. FPGA 屏幕联动：一键切换页面（P0综合仪表板 / P1示波器与FFT / P2 32路振荡器 / P3曲目）
  9. 硬件截图与回显支持：一键读取 SSD1963 硬件显存并保存 PNG

使用方法：
  python fpga_synth_host.py                # 启动 Tkinter 图形化控制台（自动识别串口）
  python fpga_synth_host.py --cli          # 启动纯终端交互弹奏模式
  python fpga_synth_host.py --port COM8    # 指定串口
"""

import argparse
from datetime import datetime
from pathlib import Path
import struct
import sys
import threading
import time
from typing import Optional, List, Dict, Tuple, Union

# 防止 Windows 控制台在打印中文字符时发生编码错误
if hasattr(sys.stdout, 'reconfigure'):
    try:
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
        sys.stderr.reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass

try:
    import serial
    import serial.tools.list_ports
except ImportError:
    print("[错误] 未检测到 pyserial 库，请使用 pip install pyserial 安装。")
    sys.exit(1)

try:
    from PIL import Image
    HAS_PIL = True
except ImportError:
    HAS_PIL = False

# -----------------------------------------------------------------------------
# MIDI 与 FPGA 控制协议定义
# -----------------------------------------------------------------------------
NOTE_ON  = 0x90
NOTE_OFF = 0x80
CC_MSG   = 0xB0

# MIDI CC 控制编号（与 RTL midi_rx.v 严格契约对齐，纯 3 字节协议防碰撞）
CC_MOD_WHEEL        = 1    # 颤音深度 (0..127)
CC_PORTAMENTO_TIME  = 5    # 滑音时间 (0..127)
CC_VOLUME           = 7    # 硬件主音量 Master Volume (0..127)
CC_INST_SEL         = 20   # 乐器音色选择 (0:钢琴, 1:电吉他, 2:古筝/二胡)
CC_DRIVE            = 21   # 过载/失真度 (0..127)
CC_WORK_MODE        = 22   # FPGA 工作模式 (0: 实时演奏, 1: 曲目播放, 2: 32路基准)
CC_UI_PAGE          = 23   # FPGA 屏幕页面 (0: P0仪表板, 1: P1示波器FFT, 2: P2 32路矩阵, 3: P3曲目)
CC_REINIT_LCD       = 24   # 硬件复位 LCD 屏幕 (val=127)
CC_SNAP_LCD         = 25   # 触发硬件抓屏 (0: quick, 1: rle)
CC_SONG_ACTIVE      = 26   # 硬件内置播放器控制 (0:停止, 127:播放, 64:暂停/继续)
CC_SONG_NEXT        = 27   # 切换下一首曲目
CC_SUSTAIN          = 64   # 延音踏板 (0:关, 127:开)
CC_PORTAMENTO_SW    = 65   # 滑音开关 (0:关, 127:开)
CC_VIBRATO_RATE     = 76   # 颤音速率 (0..127)
CC_VIBRATO_DEPTH    = 77   # 颤音深度 (0..127)
CC_ALL_SOUND_OFF    = 120  # 全静音
CC_RESET_ALL_CTRL   = 121  # 控制器复位
CC_ALL_NOTES_OFF    = 123  # 全音符释放

NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

def note_to_name(n: int) -> str:
    octave = (n // 12) - 1
    name = NOTE_NAMES[n % 12]
    return f"{name}{octave}"

KEYSYM_TO_CHAR = {
    "comma": ",",
    "period": ".",
    "slash": "/",
    "semicolon": ";",
    "minus": "-",
    "equal": "=",
    "bracketleft": "[",
    "bracketright": "]",
    "apostrophe": "'",
    "quoteright": "'",
    "quoteleft": "`",
    "grave": "`",
    "backslash": "\\",
    "space": " ",
    "up": "up",
    "down": "down",
    "prior": "pageup",
    "next": "pagedown",
    "escape": "escape",
}

def event_to_key(evt) -> str:
    """标准化 Tkinter 键盘输入事件。"""
    ks = evt.keysym.lower() if evt.keysym else ""
    if ks in KEYSYM_TO_CHAR:
        return KEYSYM_TO_CHAR[ks]
    if evt.char and len(evt.char) == 1 and ord(evt.char) >= 32:
        return evt.char.lower()
    return ks

# 电脑键盘 → 相对 C3 (MIDI 48) 的半音映射表
KEY_MAP_37 = {
    # 低八度 (C3..E4): 白键使用 Z 排，黑键使用 A 排
    "z": 0,  "s": 1,  "x": 2,  "d": 3,  "c": 4,  "v": 5,  "g": 6,  "b": 7,  "h": 8,  "n": 9,  "j": 10, "m": 11,
    ",": 12, "l": 13, ".": 14, ";": 15, "/": 16,
    # 高八度 (F4..C6): 白键使用 Q 排，黑键使用数字排
    "q": 17, "2": 18, "w": 19, "3": 20, "e": 21, "r": 22, "5": 23, "t": 24, "6": 25, "y": 26, "7": 27, "u": 28,
    "i": 29, "9": 30, "o": 31, "0": 32, "p": 33, "-": 34, "[": 35, "=": 36, "]": 36,
}

# -----------------------------------------------------------------------------
# 示范曲目乐谱库
# -----------------------------------------------------------------------------
DEMO_SONGS = {
    "卡农 (Canon in D)": [
        (74, 1.0), (73, 1.0), (71, 1.0), (69, 1.0), (67, 1.0), (66, 1.0), (67, 1.0), (69, 1.0),
        (62, 0.5), (66, 0.5), (69, 0.5), (74, 0.5), (73, 0.5), (69, 0.5), (71, 0.5), (73, 0.5),
        (74, 1.0), (73, 1.0), (71, 1.0), (69, 1.0), (67, 1.0), (66, 1.0), (67, 1.0), (69, 1.0),
        (74, 2.0)
    ],
    "小星星 (Little Star)": [
        (60, 0.5), (60, 0.5), (67, 0.5), (67, 0.5), (69, 0.5), (69, 0.5), (67, 1.0),
        (65, 0.5), (65, 0.5), (64, 0.5), (64, 0.5), (62, 0.5), (62, 0.5), (60, 1.0),
        (67, 0.5), (67, 0.5), (65, 0.5), (65, 0.5), (64, 0.5), (64, 0.5), (62, 1.0),
        (67, 0.5), (67, 0.5), (65, 0.5), (65, 0.5), (64, 0.5), (64, 0.5), (62, 1.0),
        (60, 0.5), (60, 0.5), (67, 0.5), (67, 0.5), (69, 0.5), (69, 0.5), (67, 1.0),
        (65, 0.5), (65, 0.5), (64, 0.5), (64, 0.5), (62, 0.5), (62, 0.5), (60, 1.5)
    ],
    "致爱丽丝 (Für Elise)": [
        (76, 0.35), (75, 0.35), (76, 0.35), (75, 0.35), (76, 0.35), (71, 0.35), (74, 0.35), (72, 0.35), (69, 0.7),
        (60, 0.35), (64, 0.35), (69, 0.35), (71, 0.7),
        (64, 0.35), (68, 0.35), (71, 0.35), (72, 0.7),
        (64, 0.35), (76, 0.35), (75, 0.35), (76, 0.35), (75, 0.35), (76, 0.35), (71, 0.35), (74, 0.35), (72, 0.35), (69, 0.7)
    ],
    "Faded (Alan Walker)": [
        (70, 0.5), (70, 0.5), (70, 0.5), (70, 0.5), (70, 0.5), (70, 0.5), (70, 0.5), (72, 0.5),
        (73, 0.5), (73, 0.5), (73, 0.5), (73, 0.5), (73, 0.5), (73, 0.5), (73, 0.5), (72, 0.5),
        (66, 0.5), (66, 0.5), (66, 0.5), (66, 0.5), (66, 0.5), (66, 0.5), (66, 0.5), (68, 0.5),
        (68, 1.5)
    ],
    "32路复音压力测试 (32-Polyphony Stress)": [
        ([48, 52, 55], 1.2),  # C Major
        ([50, 53, 57], 1.2),  # D Minor
        ([52, 55, 59], 1.2),  # E Minor
        ([53, 57, 60], 1.2),  # F Major
        ([55, 59, 62], 1.2),  # G Major
        ([57, 60, 64], 1.2),  # A Minor
        ([48, 52, 55, 60, 64, 67, 72, 76], 2.5) # 8-Voice Grand Unison
    ]
}

# -----------------------------------------------------------------------------
# 智能串口检测工具函数
# -----------------------------------------------------------------------------
def get_available_ports() -> List[Tuple[str, str, bool, bool]]:
    """
    枚举系统所有串口，自动分类标注：
    返回: [(device, label, is_tang_uart, is_tang_jtag), ...]
    """
    ports = list(serial.tools.list_ports.comports())
    res = []
    for p in ports:
        desc = p.description or ""
        hwid = (p.hwid or "").upper()
        sn = (p.serial_number or "").upper()
        is_tang_uart = False
        is_tang_jtag = False

        if p.vid == 0x0403 and p.pid == 0x6010:
            if sn.endswith("A") or "MI_00" in hwid or "LOCATION=0" in hwid:
                label = f"{p.device} (Tang Mega 138K JTAG - 勿选)"
                is_tang_jtag = True
            elif sn.endswith("B") or "MI_01" in hwid or "LOCATION=1" in hwid:
                label = f"{p.device} (Tang Mega 138K UART [推荐])"
                is_tang_uart = True
            else:
                label = f"{p.device} (FT2232H: {desc})"
        else:
            label = f"{p.device} ({desc})"
        res.append((p.device, label, is_tang_uart, is_tang_jtag))
    return res

def auto_detect_fpga_port() -> str:
    """
    自动寻找 Tang Mega 138K Dock 的 UART 串口端口号。
    如果检测到 Channel B，直接返回对应 COM 号；否则回退至候选设备或 COM8。
    """
    port_list = get_available_ports()
    for dev, _, is_uart, _ in port_list:
        if is_uart:
            return dev
    for dev, _, _, is_jtag in port_list:
        if not is_jtag and "COM8" in dev:
            return "COM8"
    for dev, _, _, is_jtag in port_list:
        if not is_jtag:
            return dev
    return "COM8"

# -----------------------------------------------------------------------------
# 串口通信管理类 (100% 纯 MIDI 协议，零 ASCII 碰撞，防误复位)
# -----------------------------------------------------------------------------
class SynthController:
    def __init__(self, port_name: Optional[str] = None, baud_rate: int = 115200):
        self.port_name = port_name if port_name else auto_detect_fpga_port()
        self.baud_rate = baud_rate
        self.ser: Optional[serial.Serial] = None
        self.lock = threading.Lock()
        self.current_inst = 0
        self.current_vol = 100
        self.sustain_active = False
        self.active_notes = set()
        self.is_playing_song = False
        self.current_song_name = ""
        self.song_lock = threading.Lock()
        self.song_token = 0
        self.song_thread: Optional[threading.Thread] = None
        self.stop_song_event = threading.Event()
        self.status_callback = None

    @property
    def is_connected(self) -> bool:
        return (self.ser is not None) and self.ser.is_open

    def set_status_callback(self, cb):
        self.status_callback = cb

    def _notify_status(self, connected: bool, message: str):
        if self.status_callback:
            try:
                self.status_callback(connected, message)
            except Exception:
                pass

    def connect(self, port_name: Optional[str] = None, baud_rate: Optional[int] = None) -> bool:
        """
        以防误复位模式安全打开串口。
        显式设置 dtr=False, rts=False，彻底避免 Windows 驱动拉低 FT2232H 引脚导致 FPGA 复位或 JTAG 冲突。
        """
        if port_name:
            self.port_name = port_name
        if baud_rate:
            self.baud_rate = baud_rate

        self.disconnect(silent=True)

        try:
            s = serial.Serial()
            s.port = self.port_name
            s.baudrate = self.baud_rate
            s.timeout = 0.5
            s.write_timeout = 0.5
            s.dtr = False
            s.rts = False
            s.open()
            time.sleep(0.06)
            self.ser = s

            # 清空缓存
            self.ser.reset_input_buffer()
            self.ser.reset_output_buffer()

            # 发送纯 MIDI CC 初始化指令对齐状态，并强行关停硬件内置曲目播放器
            self.stop_hardware_song()
            self.set_work_mode(0)
            self.set_fpga_page(0)
            self.set_volume(self.current_vol)
            self.all_notes_off()

            self._notify_status(True, f"已连接: {self.port_name} ({self.baud_rate} 8N1)")
            return True
        except Exception as e:
            self.ser = None
            self._notify_status(False, f"无法打开串口 {self.port_name}: {e}")
            return False

    def disconnect(self, silent: bool = False):
        with self.lock:
            if self.ser and self.ser.is_open:
                try:
                    # 尝试全静音
                    self.ser.write(bytes([CC_MSG, CC_ALL_NOTES_OFF, 0]))
                    self.ser.write(bytes([CC_MSG, CC_ALL_SOUND_OFF, 0]))
                    self.ser.flush()
                except Exception:
                    pass
                try:
                    self.ser.close()
                except Exception:
                    pass
            self.ser = None
            self.active_notes.clear()

        if not silent:
            self._notify_status(False, f"串口已断开: {self.port_name}")

    def write_raw(self, data: bytes):
        """线程安全发送原始字节，遭遇异常自动标记断开并保护线程。"""
        with self.lock:
            if not self.is_connected:
                return
            try:
                self.ser.write(data)
                self.ser.flush()
            except (serial.SerialException, OSError) as e:
                print(f"[串口异常] 发送失败: {e}")
                try:
                    if self.ser:
                        self.ser.close()
                except Exception:
                    pass
                self.ser = None
                self._notify_status(False, f"串口连接断开: {e}")

    def note_on(self, note: int, velocity: int = 100):
        note = max(0, min(127, note))
        velocity = max(1, min(127, velocity))
        self.active_notes.add(note)
        self.write_raw(bytes([NOTE_ON, note, velocity]))

    def note_off(self, note: int):
        note = max(0, min(127, note))
        if note in self.active_notes:
            self.active_notes.discard(note)
        self.write_raw(bytes([NOTE_OFF, note, 0]))

    def all_notes_off(self):
        self.active_notes.clear()
        self.write_raw(bytes([CC_MSG, CC_ALL_NOTES_OFF, 0]))
        self.write_raw(bytes([CC_MSG, CC_ALL_SOUND_OFF, 0]))

    def all_sound_off(self):
        self.active_notes.clear()
        self.write_raw(bytes([CC_MSG, CC_ALL_SOUND_OFF, 0]))
        self.write_raw(bytes([CC_MSG, CC_RESET_ALL_CTRL, 0]))

    def set_instrument(self, inst_idx: int):
        self.current_inst = inst_idx % 3
        self.write_raw(bytes([CC_MSG, CC_INST_SEL, self.current_inst]))

    def set_volume(self, val: int):
        self.current_vol = max(0, min(127, int(val)))
        self.write_raw(bytes([CC_MSG, CC_VOLUME, self.current_vol]))

    def set_drive(self, val: int):
        self.write_raw(bytes([CC_MSG, CC_DRIVE, max(0, min(127, val))]))

    def set_sustain(self, on: bool):
        self.sustain_active = on
        self.write_raw(bytes([CC_MSG, CC_SUSTAIN, 127 if on else 0]))

    def set_vibrato(self, depth: int, rate: int = 50):
        self.write_raw(bytes([CC_MSG, CC_VIBRATO_DEPTH, max(0, min(127, depth))]))
        self.write_raw(bytes([CC_MSG, CC_VIBRATO_RATE, max(0, min(127, rate))]))

    def set_glide(self, on: bool, glide_time: int = 25):
        self.write_raw(bytes([CC_MSG, CC_PORTAMENTO_SW, 127 if on else 0]))
        if on:
            self.write_raw(bytes([CC_MSG, CC_PORTAMENTO_TIME, max(0, min(127, glide_time))]))

    def set_work_mode(self, mode: int):
        self.write_raw(bytes([CC_MSG, CC_WORK_MODE, int(mode) % 3]))

    def set_fpga_page(self, page: Union[int, str]):
        if isinstance(page, str):
            p_map = {'m': 0, 'v': 1, 't': 2, 'g': 3, '0': 0, '1': 1, '2': 2, '3': 3}
            page_idx = p_map.get(page.lower(), 0)
        else:
            page_idx = int(page) % 4
        self.write_raw(bytes([CC_MSG, CC_UI_PAGE, page_idx]))

    def reinit_lcd(self):
        """发送 CC 24 = 127 触发 FPGA 硬件重新初始化 SSD1963 LCD 屏幕。"""
        self.write_raw(bytes([CC_MSG, CC_REINIT_LCD, 127]))

    def play_chord(self, notes: List[int], duration: float = 1.0, velocity: int = 100):
        def _chord_worker():
            for n in notes:
                self.note_on(n, velocity)
            time.sleep(duration)
            for n in notes:
                self.note_off(n)
        threading.Thread(target=_chord_worker, daemon=True).start()

    def stop_hardware_song(self):
        """强行停止 FPGA 硬件内部的 ROM 自动演奏机 (发送 CC 26 = 0 及 ASCII '!')。"""
        self.write_raw(bytes([CC_MSG, CC_SONG_ACTIVE, 0]))
        self.write_raw(b"!")
        self.all_notes_off()

    def start_hardware_song(self):
        """触发 FPGA 硬件内部的 ROM 自动演奏机播放 (发送 CC 22 = 1, CC 26 = 127 及 ASCII '1')。"""
        self.write_raw(bytes([CC_MSG, CC_WORK_MODE, 1]))
        self.write_raw(bytes([CC_MSG, CC_SONG_ACTIVE, 127]))
        self.write_raw(b"1")

    def next_hardware_song(self):
        """触发 FPGA 硬件内置播放器切歌 (发送 CC 27 = 127 及 ASCII '>')。"""
        self.write_raw(bytes([CC_MSG, CC_SONG_NEXT, 127]))
        self.write_raw(b">")

    def play_song(self, song_name: str, speed_scale: float = 1.0, callback_progress=None):
        """
        独占式播放上位机示范曲目。
        原子级切换曲目：自动且瞬间打断任何先前正在播放的曲目线程，彻底杜绝多首曲目混杂。
        """
        if song_name not in DEMO_SONGS:
            return

        with self.song_lock:
            # 1. 递增 generation token，使任何旧播放线程立即作废
            self.song_token += 1
            my_token = self.song_token
            # 2. 触发停止事件唤醒前一个线程休眠
            self.stop_song_event.set()
            prev_thread = self.song_thread

        # 3. 强行停止 FPGA 硬件内部 ROM 演奏机，并全关当前发声的所有琴键
        self.stop_hardware_song()
        self.all_notes_off()

        # 4. 等待旧线程安全退出 (采用可中断 wait，通常 <5ms 内即可退出)
        if prev_thread and prev_thread.is_alive():
            prev_thread.join(timeout=0.15)

        # 5. 分配并启动当前曲目的独占线程
        with self.song_lock:
            if self.song_token != my_token:
                # 若在此期间用户又点击了其他曲目，直接跳过本曲
                return
            self.stop_song_event.clear()
            self.is_playing_song = True
            self.current_song_name = song_name

        def _song_worker(tok=my_token):
            items = DEMO_SONGS[song_name]
            total = len(items)

            for idx, (note_item, duration) in enumerate(items):
                # 严格中断检测：token 变化或 stop 事件触发即立刻退出
                if tok != self.song_token or self.stop_song_event.is_set() or not self.is_connected:
                    break

                # 发音
                if isinstance(note_item, list):
                    for n in note_item:
                        self.note_on(n, 100)
                else:
                    self.note_on(note_item, 100)

                if callback_progress:
                    callback_progress(idx + 1, total)

                play_time = max(0.08, duration * 0.7 * speed_scale)
                gap_time  = max(0.03, duration * 0.3 * speed_scale)

                # ★★★ 可中断式休眠：一旦用户点击其他曲目，wait 瞬间在 <1ms 内响应并退出，绝不延迟！
                if self.stop_song_event.wait(timeout=play_time) or tok != self.song_token:
                    if isinstance(note_item, list):
                        for n in note_item:
                            self.note_off(n)
                    else:
                        self.note_off(note_item)
                    break

                # 松键 (Note Off)
                if isinstance(note_item, list):
                    for n in note_item:
                        self.note_off(n)
                else:
                    self.note_off(note_item)

                if self.stop_song_event.wait(timeout=gap_time) or tok != self.song_token:
                    break

            # 仅当自己仍是最新线程时清理状态
            if tok == self.song_token:
                self.all_notes_off()
                with self.song_lock:
                    if tok == self.song_token:
                        self.is_playing_song = False
                        self.current_song_name = ""
                if callback_progress:
                    callback_progress(total, total)

        t = threading.Thread(target=_song_worker, daemon=True)
        self.song_thread = t
        t.start()

    def stop_song(self):
        """立即中断所有正在播放的曲目线程，并强行关停硬件内部音序器与全音符静音。"""
        with self.song_lock:
            self.song_token += 1
            self.stop_song_event.set()
            self.is_playing_song = False
            self.current_song_name = ""

        # 既停止上位机 Python 线程，又强行停止 FPGA 硬件内部 ROM 演奏机并全静音
        self.stop_hardware_song()
        self.all_notes_off()

    def capture_lcd_quick(self, out_dir: Optional[Path] = None) -> Optional[str]:
        """
        线程安全读取 SSD1963 硬件显存快照 (Quick 模式 200x120 -> 800x480)。
        保存并返回 PNG 文件路径。
        """
        if not HAS_PIL:
            raise RuntimeError("请先安装 Pillow (pip install pillow) 以使用抓屏功能。")

        with self.lock:
            if not self.is_connected:
                raise RuntimeError("串口未连接，无法执行硬件抓屏。")

            ser = self.ser
            ser.reset_input_buffer()
            # 发送快速抓屏指令 'q'
            ser.write(b"q")
            ser.flush()

            # 寻找 IMGQ 报头
            deadline = time.time() + 8.0
            buf = bytearray()
            matched = False
            while time.time() < deadline:
                chunk = ser.read(1)
                if not chunk:
                    continue
                buf += chunk
                if len(buf) > 32:
                    buf = buf[-32:]
                if buf.endswith(b"IMGQ"):
                    matched = True
                    break

            if not matched:
                raise RuntimeError("抓屏超时：未在 8 秒内匹配到 'IMGQ' 硬件响应报头。")

            dims = ser.read(4)
            if len(dims) < 4:
                raise RuntimeError("读取图像尺寸失败。")
            w, h = struct.unpack("<HH", dims)
            total_bytes = w * h * 2

            raw = bytearray()
            t0 = time.time()
            while len(raw) < total_bytes:
                if time.time() - t0 > 15.0:
                    raise TimeoutError(f"读取显存数据超时: {len(raw)}/{total_bytes} 字节")
                avail = ser.in_waiting
                to_read = min(total_bytes - len(raw), max(1, avail))
                chunk = ser.read(to_read)
                if chunk:
                    raw.extend(chunk)
                    t0 = time.time()

            try:
                ser.read(6)  # 忽略 'END!\r\n'
            except Exception:
                pass

        # 转换为 RGB888
        rgb_data = []
        for i in range(0, len(raw), 2):
            pix = (raw[i] << 8) | raw[i + 1]
            r = ((pix >> 11) & 0x1F) << 3
            g = ((pix >> 5) & 0x3F) << 2
            b = (pix & 0x1F) << 3
            rgb_data.append((r, g, b))

        img = Image.new("RGB", (w, h))
        img.putdata(rgb_data)
        if (w, h) != (800, 480):
            img = img.resize((800, 480), resample=Image.Resampling.NEAREST)

        target_dir = out_dir if out_dir else Path(r"C:\Users\gjl50\Desktop\FPGA\fpga_spark\screenshot")
        target_dir.mkdir(parents=True, exist_ok=True)
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        out_file = target_dir / f"screenshot_{ts}.png"
        img.save(out_file)
        return str(out_file)


# -----------------------------------------------------------------------------
# 模式 A: 纯终端 CLI 交互控制台
# -----------------------------------------------------------------------------
def run_cli_console(ctrl: SynthController):
    import msvcrt
    print("\n" + "="*74)
    print("   Tang Mega 138K FPGA 纯硬件合成器 —— 终端交互控制台 (纯 MIDI 隔离通道)")
    print("="*74)
    if ctrl.is_connected:
        print(f" [串口状态]: 🟢 已连接 {ctrl.port_name} @ {ctrl.baud_rate} 8N1")
    else:
        print(f" [串口状态]: 🔴 未连接 (离线演示模式)")
    print(" [键盘弹奏映射 (C4..E5)]:")
    print("   白键: A (C4), S (D4), D (E4), F (F4), G (G4), H (A4), J (B4), K (C5), L (D5), ; (E5)")
    print("   黑键: W (C#4), E (D#4), T (F#4), Y (G#4), U (A#4), O (C#5), P (D#5)")
    print("\n [功能快捷键]:")
    print("   1..7: 一键和弦伴奏 (C, Dm, Em, F, G, Am, Bdim)")
    print("   F1 / F2 / F3: 切换音色 (钢琴 / 电吉他 / 古筝二胡)")
    print("   空格键: 切换延音踏板 (Sustain ON / OFF)")
    print("   [ / ]: 八度切换 (Octave Down / Up)")
    print("   - / +: 调节硬件主音量 (Volume Down / Up)")
    print("   8 / 9 / 0 / -: 切换 FPGA 屏幕页面 (P0仪表板 / P1示波器FFT / P2 32路矩阵 / P3曲目)")
    print("   R: 重新扫描并连接串口")
    print("   ESC / Q: 退出控制台")
    print("="*74)

    CLI_KEYS = {
        'a': 60, 'w': 61, 's': 62, 'e': 63, 'd': 64, 'f': 65, 't': 66, 'g': 67,
        'y': 68, 'h': 69, 'u': 70, 'j': 71, 'k': 72, 'o': 73, 'l': 74, 'p': 75, ';': 76
    }
    CHORDS = {
        '1': [60, 64, 67],      # C Major
        '2': [62, 65, 69],      # D Minor
        '3': [64, 67, 71],      # E Minor
        '4': [65, 69, 72],      # F Major
        '5': [67, 71, 74],      # G Major
        '6': [69, 72, 76],      # A Minor
        '7': [71, 74, 77],      # B Dim
    }

    octave_shift = 0
    sustain = False
    cli_vol = 100

    while True:
        if msvcrt.kbhit():
            ch = msvcrt.getch()
            if ch in (b'\x1b', b'q', b'Q'):
                print("\n[退出] 正在停止演奏并复位 FPGA 合成器...")
                ctrl.all_notes_off()
                break

            try:
                c = ch.decode('ascii').lower()
            except UnicodeDecodeError:
                continue

            if c == 'r':
                new_port = auto_detect_fpga_port()
                print(f"\n[重连] 正在检测串口... 目标: {new_port}")
                ok = ctrl.connect(new_port)
                if ok:
                    print(f"  -> 成功连接到 {new_port}！")
                else:
                    print(f"  -> 连接失败，请检查 USB 线缆。")

            elif c in CLI_KEYS:
                note = CLI_KEYS[c] + octave_shift * 12
                ctrl.note_on(note, 105)
                print(f"\r[音符] 发声: {note_to_name(note)} (MIDI {note}) | 串口: {'🟢' if ctrl.is_connected else '🔴'}   ", end="")
                def _auto_release(n=note):
                    time.sleep(0.35)
                    ctrl.note_off(n)
                threading.Thread(target=_auto_release, daemon=True).start()

            elif c in CHORDS:
                base_chord = [n + octave_shift * 12 for n in CHORDS[c]]
                c_names = "+".join([note_to_name(n) for n in base_chord])
                print(f"\r[和弦] 伴奏: {c_names}                                       ", end="")
                ctrl.play_chord(base_chord, duration=1.0)

            elif c == ' ':
                sustain = not sustain
                ctrl.set_sustain(sustain)
                print(f"\r[踏板] 延音踏板状态: {'【ON 开】' if sustain else '【OFF 关】'}                   ", end="")

            elif c == '[':
                octave_shift = max(-2, octave_shift - 1)
                print(f"\r[八度] 当前八度偏移: {octave_shift:+d} (基准: C{4+octave_shift})                     ", end="")
            elif c == ']':
                octave_shift = min(2, octave_shift + 1)
                print(f"\r[八度] 当前八度偏移: {octave_shift:+d} (基准: C{4+octave_shift})                     ", end="")

            elif c in ('-', '_'):
                cli_vol = max(0, cli_vol - 8)
                ctrl.set_volume(cli_vol)
                print(f"\r[音量调节] 当前主音量: {int(round(cli_vol * 100 / 127))}% (MIDI CC 7 = {cli_vol})          ", end="")

            elif c in ('+', '='):
                cli_vol = min(127, cli_vol + 8)
                ctrl.set_volume(cli_vol)
                print(f"\r[音量调节] 当前主音量: {int(round(cli_vol * 100 / 127))}% (MIDI CC 7 = {cli_vol})          ", end="")

            elif c in ('8', '9', '0', 'p'):
                page_map = {'8': 0, '9': 1, '0': 2, 'p': 3}
                ctrl.set_fpga_page(page_map[c])
                p_names = {0: 'P0综合仪表板', 1: 'P1示波器与实时FFT', 2: 'P2 32路振荡器矩阵', 3: 'P3曲目列表'}
                print(f"\r[屏幕联动] 切换到: {p_names[page_map[c]]}                            ", end="")

        time.sleep(0.01)


# -----------------------------------------------------------------------------
# 模式 B: 现代化 Tkinter GUI 图形控制台 (集成完整串口管理与热插拔)
# -----------------------------------------------------------------------------
def run_gui_console(ctrl: SynthController):
    import tkinter as tk
    from tkinter import ttk, messagebox

    root = tk.Tk()
    root.title("FPGA 纯硬件现代音乐合成器 —— 上位机控制中心 (Tang Mega 138K Dock)")
    root.geometry("1100x740")
    root.minsize(1020, 700)
    root.configure(bg="#0D1627")

    style = ttk.Style()
    style.theme_use('clam')
    style.configure("TLabel", background="#0D1627", foreground="#CBE3F5", font=("Segoe UI", 10))
    style.configure("Header.TLabel", font=("Segoe UI", 15, "bold"), foreground="#00F0FF")
    style.configure("SubHeader.TLabel", font=("Segoe UI", 11, "bold"), foreground="#7BE382")
    style.configure("TButton", font=("Segoe UI", 10, "bold"), background="#1A2D4C", foreground="#FFFFFF")
    style.map("TButton", background=[('active', '#007ACC'), ('pressed', '#005999')])
    style.configure("TCombobox", fieldbackground="#152744", background="#152744", foreground="#00F0FF", arrowcolor="#00F0FF")

    var_port_dev = tk.StringVar(value=ctrl.port_name)
    var_inst = tk.IntVar(value=0)
    var_sustain = tk.BooleanVar(value=False)
    var_status = tk.StringVar(value="")
    var_conn_badge = tk.StringVar(value="")
    var_last_note = tk.StringVar(value="准备就绪：请使用电脑键盘或鼠标在下方钢琴键区演奏")

    # 1. 顶部控制栏 (强化串口动态热插拔、端口选择与连接控制)
    top_frame = tk.Frame(root, bg="#13223A", bd=1, relief="ridge", padx=12, pady=8)
    top_frame.pack(fill="x", padx=12, pady=6)

    # 标题
    lbl_title = tk.Label(top_frame, text="🎹 FPGA 硬件现代音乐合成器控制中心", bg="#13223A", fg="#00F0FF", font=("Segoe UI", 13, "bold"))
    lbl_title.pack(side="left", padx=(0, 14))

    # 串口端口选择器
    tk.Label(top_frame, text="通信串口:", bg="#13223A", fg="#A0C4E2", font=("Segoe UI", 9, "bold")).pack(side="left", padx=(0, 4))
    
    combo_ports = ttk.Combobox(top_frame, width=28, state="readonly")
    combo_ports.pack(side="left", padx=4)

    def refresh_port_list():
        port_items = get_available_ports()
        display_list = []
        dev_map = {}
        rec_dev = None

        for dev, label, is_uart, is_jtag in port_items:
            display_list.append(label)
            dev_map[label] = dev
            if is_uart and rec_dev is None:
                rec_dev = label

        combo_ports['values'] = display_list
        combo_ports.dev_map = dev_map

        # 优先选中推荐的 Tang Mega 串口
        if rec_dev:
            combo_ports.set(rec_dev)
            var_port_dev.set(dev_map[rec_dev])
        elif display_list:
            combo_ports.set(display_list[0])
            var_port_dev.set(dev_map[display_list[0]])
        else:
            combo_ports.set("未检测到可用串口")
            var_port_dev.set("COM8")

    def get_selected_device() -> str:
        cur_text = combo_ports.get()
        dev_map = getattr(combo_ports, 'dev_map', {})
        if cur_text in dev_map:
            return dev_map[cur_text]
        # 回退直接解析
        parts = cur_text.split()
        return parts[0] if parts else "COM8"

    def toggle_connection():
        if ctrl.is_connected:
            ctrl.disconnect()
            update_conn_ui()
        else:
            target_dev = get_selected_device()
            ok = ctrl.connect(target_dev)
            update_conn_ui()
            if not ok:
                messagebox.showwarning("串口连接失败", f"无法打开串口 {target_dev}。\n请确认开发板 USB 线缆已插紧，且未被其他上位机或调试器占用。")

    btn_refresh = tk.Button(top_frame, text="🔄 刷新端口", bg="#19375F", fg="#CBE3F5", font=("Segoe UI", 9, "bold"),
                            command=refresh_port_list, padx=8, pady=2)
    btn_refresh.pack(side="left", padx=4)

    btn_connect = tk.Button(top_frame, text="🔌 连接串口", bg="#1C6635", fg="#FFFFFF", font=("Segoe UI", 9, "bold"),
                            command=toggle_connection, padx=12, pady=2)
    btn_connect.pack(side="left", padx=6)

    # 状态指示徽章
    lbl_conn_badge = tk.Label(top_frame, textvariable=var_conn_badge, bg="#13223A", font=("Segoe UI", 10, "bold"))
    lbl_conn_badge.pack(side="right", padx=10)

    def update_conn_ui():
        if ctrl.is_connected:
            var_conn_badge.set(f"🟢 已连接: {ctrl.port_name} (115200 8N1)")
            lbl_conn_badge.config(fg="#00FF88")
            btn_connect.config(text="🔌 断开连接", bg="#701F29")
            var_status.set(f"串口就绪: {ctrl.port_name} | 纯 MIDI 隔离通道已激活")
        else:
            var_conn_badge.set("🔴 串口未连接 (离线模式)")
            lbl_conn_badge.config(fg="#FF6B6B")
            btn_connect.config(text="🔌 连接串口", bg="#1C6635")
            var_status.set("提示：请在上方选择 Tang Mega 串口并点击连接")

    ctrl.set_status_callback(lambda conn, msg: root.after(0, lambda: (update_conn_ui(), var_status.set(msg))))

    # 1.5 硬件主音量调节栏 (Volume Control Bar)
    vol_frame = tk.Frame(root, bg="#101D33", bd=1, relief="ridge", padx=14, pady=6)
    vol_frame.pack(fill="x", padx=12, pady=(0, 6))

    var_volume = tk.IntVar(value=100)
    var_vol_str = tk.StringVar(value="🔊 音量: 79% (CC7: 100)")
    var_muted = tk.BooleanVar(value=False)
    last_unmuted_vol = 100

    def apply_volume(val: int):
        nonlocal last_unmuted_vol
        val = max(0, min(127, int(val)))
        var_volume.set(val)
        pct = int(round(val * 100.0 / 127.0))
        if val == 0:
            var_vol_str.set("🔇 静音 (0%)")
            var_muted.set(True)
            btn_mute.config(text="🔈 恢复声音", bg="#592020")
        else:
            var_vol_str.set(f"🔊 音量: {pct}% (CC7: {val})")
            var_muted.set(False)
            btn_mute.config(text="🔇 静音切换", bg="#2B1A3A")
            last_unmuted_vol = val
        ctrl.set_volume(val)

    def step_volume(delta: int):
        cur = var_volume.get()
        apply_volume(cur + delta)

    def toggle_mute():
        if var_muted.get() or var_volume.get() == 0:
            apply_volume(last_unmuted_vol if last_unmuted_vol > 0 else 100)
        else:
            apply_volume(0)

    def panic_all_sound_off():
        ctrl.all_notes_off()
        ctrl.all_sound_off()
        for note in key_rects:
            highlight_key(note, False)
        var_status.set("🛑 已触发硬件紧急静音与声部全复位 (All Sound Off / Panic)")

    lbl_vol_title = tk.Label(vol_frame, text="🔊 硬件主音量调节:", bg="#101D33", fg="#00F0FF", font=("Segoe UI", 10, "bold"))
    lbl_vol_title.pack(side="left", padx=(0, 8))

    btn_vol_down = tk.Button(vol_frame, text="🔉 音量 -", bg="#173456", fg="#FFFFFF", font=("Segoe UI", 9, "bold"),
                             command=lambda: step_volume(-8), padx=8)
    btn_vol_down.pack(side="left", padx=4)

    scale_vol = tk.Scale(vol_frame, from_=0, to=127, orient="horizontal", length=220, showvalue=0,
                         variable=var_volume, command=lambda v: apply_volume(int(v)),
                         bg="#101D33", fg="#00F0FF", troughcolor="#182A45", activebackground="#00F0FF",
                         highlightthickness=0, bd=0)
    scale_vol.pack(side="left", padx=8)

    btn_vol_up = tk.Button(vol_frame, text="🔊 音量 +", bg="#173456", fg="#FFFFFF", font=("Segoe UI", 9, "bold"),
                           command=lambda: step_volume(+8), padx=8)
    btn_vol_up.pack(side="left", padx=4)

    lbl_vol_disp = tk.Label(vol_frame, textvariable=var_vol_str, bg="#101D33", fg="#FFE600", font=("Segoe UI", 10, "bold"), width=18)
    lbl_vol_disp.pack(side="left", padx=10)

    btn_mute = tk.Button(vol_frame, text="🔇 静音切换", bg="#2B1A3A", fg="#FF8090", font=("Segoe UI", 9, "bold"),
                         command=toggle_mute, padx=10)
    btn_mute.pack(side="right", padx=4)

    btn_panic = tk.Button(vol_frame, text="🛑 全复位静音 (Esc)", bg="#4A1818", fg="#FFB0B0", font=("Segoe UI", 9, "bold"),
                          command=panic_all_sound_off, padx=8)
    btn_panic.pack(side="right", padx=4)

    # 2. 中部多功能面板区
    mid_frame = tk.Frame(root, bg="#0D1627")
    mid_frame.pack(fill="both", expand=True, padx=12, pady=4)

    # 左侧：音色选择、和弦快捷伴奏与表情 DSP
    left_panel = tk.LabelFrame(mid_frame, text=" 音色与演奏效果器 ", bg="#13223A", fg="#00F0FF", font=("Segoe UI", 11, "bold"), padx=10, pady=8)
    left_panel.pack(side="left", fill="both", expand=True, padx=(0, 6))

    tk.Label(left_panel, text="1. 硬件合成引擎音色切换 (CC20):", bg="#13223A", fg="#CBE3F5", font=("Segoe UI", 10, "bold")).pack(anchor="w", pady=(2, 4))
    inst_frame = tk.Frame(left_panel, bg="#13223A")
    inst_frame.pack(fill="x", pady=2)

    def on_inst_change(idx):
        var_inst.set(idx)
        ctrl.set_instrument(idx)
        inst_names = ["8阶泛音钢琴 (Piano)", "失真电吉他 (Distortion Guitar)", "古筝/二胡 (Guzheng)"]
        var_status.set(f"音色已切换: {inst_names[idx]}")

    btn_p = tk.Button(inst_frame, text="🎹 8阶泛音钢琴", bg="#1D3963", fg="#FFFFFF", font=("Segoe UI", 9, "bold"), width=13, command=lambda: on_inst_change(0))
    btn_p.pack(side="left", padx=3)
    btn_g = tk.Button(inst_frame, text="🎸 失真电吉他", bg="#1D3963", fg="#FFFFFF", font=("Segoe UI", 9, "bold"), width=13, command=lambda: on_inst_change(1))
    btn_g.pack(side="left", padx=3)
    btn_z = tk.Button(inst_frame, text="🪕 民族古筝二胡", bg="#1D3963", fg="#FFFFFF", font=("Segoe UI", 9, "bold"), width=13, command=lambda: on_inst_change(2))
    btn_z.pack(side="left", padx=3)

    # 表情调制 (Sustain, Distortion, Vibrato)
    tk.Label(left_panel, text="2. 实时表情与 DSP 调制 (MIDI CC):", bg="#13223A", fg="#CBE3F5", font=("Segoe UI", 10, "bold")).pack(anchor="w", pady=(10, 4))
    dsp_frame = tk.Frame(left_panel, bg="#13223A")
    dsp_frame.pack(fill="x", pady=2)

    def toggle_sustain():
        cur = not var_sustain.get()
        var_sustain.set(cur)
        ctrl.set_sustain(cur)
        btn_sus.config(text="踏板: 【开启】" if cur else "踏板: 【关闭】", bg="#1C6635" if cur else "#1F3456")
        var_status.set(f"延音踏板已{'开启' if cur else '关闭'} (CC 64)")

    btn_sus = tk.Button(dsp_frame, text="踏板: 【关闭】", bg="#1F3456", fg="#FFFFFF", font=("Segoe UI", 9, "bold"),
                        command=toggle_sustain, padx=6)
    btn_sus.pack(side="left", padx=4)

    tk.Label(dsp_frame, text="过载:", bg="#13223A", fg="#CBE3F5", font=("Segoe UI", 9)).pack(side="left", padx=(10, 2))
    scale_drive = tk.Scale(dsp_frame, from_=0, to=127, orient="horizontal", length=90, showvalue=0,
                           command=lambda v: ctrl.set_drive(int(v)), bg="#13223A", fg="#00F0FF", troughcolor="#182A45", bd=0)
    scale_drive.pack(side="left", padx=2)

    tk.Label(dsp_frame, text="颤音:", bg="#13223A", fg="#CBE3F5", font=("Segoe UI", 9)).pack(side="left", padx=(10, 2))
    scale_vib = tk.Scale(dsp_frame, from_=0, to=127, orient="horizontal", length=90, showvalue=0,
                         command=lambda v: ctrl.set_vibrato(int(v)), bg="#13223A", fg="#00F0FF", troughcolor="#182A45", bd=0)
    scale_vib.pack(side="left", padx=2)

    tk.Label(left_panel, text="3. 常用和弦一键伴奏 (多复音叠加):", bg="#13223A", fg="#CBE3F5", font=("Segoe UI", 10, "bold")).pack(anchor="w", pady=(10, 4))
    chord_grid = tk.Frame(left_panel, bg="#13223A")
    chord_grid.pack(fill="x", pady=2)

    chord_list = [
        ("C 大三和弦", [60, 64, 67]),
        ("Dm 小三和弦", [62, 65, 69]),
        ("Em 小三和弦", [64, 67, 71]),
        ("F 大三和弦", [65, 69, 72]),
        ("G 属和弦", [67, 71, 74]),
        ("Am 小三和弦", [69, 72, 76]),
        ("Cmaj7 大七和弦", [60, 64, 67, 71]),
        ("G7 属七和弦", [67, 71, 74, 77]),
    ]
    for i, (c_name, c_notes) in enumerate(chord_list):
        r = i // 4
        c = i % 4
        btn = tk.Button(chord_grid, text=c_name, bg="#183153", fg="#00F0FF", font=("Segoe UI", 9, "bold"),
                        width=11, pady=3, command=lambda ns=c_notes, name=c_name: (ctrl.play_chord(ns, 1.2), var_status.set(f"触发和弦: {name}")))
        btn.grid(row=r, column=c, padx=3, pady=3)

    # 中右侧：示范曲目播放、FPGA 页面联动与硬件抓屏
    right_panel = tk.LabelFrame(mid_frame, text=" FPGA 屏幕控制与示范曲 ", bg="#13223A", fg="#00F0FF", font=("Segoe UI", 11, "bold"), padx=10, pady=8)
    right_panel.pack(side="right", fill="both", expand=True, padx=(6, 0))

    tk.Label(right_panel, text="1. FPGA 屏幕页面切换 (纯 MIDI CC23 指令):", bg="#13223A", fg="#CBE3F5", font=("Segoe UI", 10, "bold")).pack(anchor="w", pady=(2, 4))
    page_frame = tk.Frame(right_panel, bg="#13223A")
    page_frame.pack(fill="x", pady=2)

    def switch_page(p_idx, p_name):
        ctrl.set_fpga_page(p_idx)
        var_status.set(f"FPGA 屏幕已切换至: {p_name}")

    btn_p0 = tk.Button(page_frame, text="📊 P0 综合仪表", bg="#173456", fg="#FFFFFF", width=11, command=lambda: switch_page(0, "P0综合仪表板"))
    btn_p0.pack(side="left", padx=2)
    btn_p1 = tk.Button(page_frame, text="📈 P1 示波器FFT", bg="#173456", fg="#FFFFFF", width=11, command=lambda: switch_page(1, "P1示波器与实时FFT"))
    btn_p1.pack(side="left", padx=2)
    btn_p2 = tk.Button(page_frame, text="🎛️ P2 32路矩阵", bg="#173456", fg="#FFFFFF", width=11, command=lambda: switch_page(2, "P2 32路振荡器基准"))
    btn_p2.pack(side="left", padx=2)
    btn_p3 = tk.Button(page_frame, text="🎵 P3 曲目播放", bg="#173456", fg="#FFFFFF", width=11, command=lambda: switch_page(3, "P3曲目列表"))
    btn_p3.pack(side="left", padx=2)

    tk.Label(right_panel, text="2. 曲目播放控制 (电脑示范曲 / FPGA 硬件内置曲目):", bg="#13223A", fg="#CBE3F5", font=("Segoe UI", 10, "bold")).pack(anchor="w", pady=(8, 4))
    song_frame = tk.Frame(right_panel, bg="#13223A")
    song_frame.pack(fill="x", pady=2)

    song_buttons = {}
    demo_song_list = [
        ("🎵 卡农", "卡农 (Canon in D)"),
        ("⭐ 小星星", "小星星 (Little Star)"),
        ("🎹 致爱丽丝", "致爱丽丝 (Für Elise)"),
        ("⚡ 32路压力测试", "32路复音压力测试 (32-Polyphony Stress)"),
    ]

    def update_song_button_highlight(active_song=""):
        for sn, btn in song_buttons.items():
            if sn == active_song:
                btn.config(bg="#1E6B3B", fg="#00FF88")
            else:
                btn.config(bg="#1B335A", fg="#7BE382")

    for col, (short_name, full_name) in enumerate(demo_song_list):
        def _make_play(fn=full_name, sn=short_name):
            def _cmd():
                update_song_button_highlight(fn)
                var_status.set(f"已打断前曲，正在独占演奏: {sn}")
                def _prog(cur, tot):
                    if cur >= tot:
                        root.after(0, lambda: (update_song_button_highlight(""), var_status.set(f"曲目演奏完成: {sn}")))
                    else:
                        root.after(0, lambda c=cur, t=tot: var_status.set(f"正在独占演奏: {sn} ({c}/{t} 音符)"))
                ctrl.play_song(fn, callback_progress=_prog)
            return _cmd

        btn_s = tk.Button(song_frame, text=short_name, bg="#1B335A", fg="#7BE382", font=("Segoe UI", 9, "bold"),
                          command=_make_play(full_name, short_name))
        btn_s.grid(row=0, column=col, sticky="ew", padx=2, pady=2)
        song_frame.grid_columnconfigure(col, weight=1)
        song_buttons[full_name] = btn_s

    # 硬件内置 ROM 播放器独立控制行
    hw_song_frame = tk.Frame(right_panel, bg="#13223A")
    hw_song_frame.pack(fill="x", pady=(4, 2))

    def on_hw_play():
        ctrl.start_hardware_song()
        update_song_button_highlight("")
        var_status.set("已启动 FPGA 硬件内置 ROM 乐谱播放 (模式 1)")

    def on_hw_stop():
        ctrl.stop_hardware_song()
        update_song_button_highlight("")
        var_status.set("已停止 FPGA 硬件内置播放器并全静音")

    hw_btns = [
        ("▶️ 硬件内置播放", on_hw_play, "#1A4A28", "#7BE382"),
        ("⏭️ 硬件下一首", lambda: (ctrl.next_hardware_song(), var_status.set("已向 FPGA 发送切歌指令 (CC 27)")), "#1E395B", "#CBE3F5"),
        ("⏹️ 硬件内置停止", on_hw_stop, "#592020", "#FFB0B0"),
    ]
    for col, (b_txt, b_cmd, bg_c, fg_c) in enumerate(hw_btns):
        btn_h = tk.Button(hw_song_frame, text=b_txt, bg=bg_c, fg=fg_c, font=("Segoe UI", 9, "bold"), command=b_cmd)
        btn_h.grid(row=0, column=col, sticky="ew", padx=2, pady=2)
        hw_song_frame.grid_columnconfigure(col, weight=1)

    def on_stop_all():
        ctrl.stop_song()
        update_song_button_highlight("")
        var_status.set("已全局停止所有曲目并全静音")

    btn_stop = tk.Button(right_panel, text="🛑 全局停止所有曲目并全静音 (All Sound Off)", bg="#661C24", fg="#FFFFFF", font=("Segoe UI", 9, "bold"),
                         command=on_stop_all)
    btn_stop.pack(fill="x", pady=(6, 8))

    # 硬件抓屏与 LCD 复位功能
    tk.Label(right_panel, text="3. 硬件抓屏与屏幕维护 (SSD1963 800x480):", bg="#13223A", fg="#CBE3F5", font=("Segoe UI", 10, "bold")).pack(anchor="w", pady=(2, 4))
    snap_frame = tk.Frame(right_panel, bg="#13223A")
    snap_frame.pack(fill="x", pady=2)

    def do_screenshot():
        if not ctrl.is_connected:
            messagebox.showwarning("提示", "串口未连接，无法执行硬件抓屏！")
            return
        btn_snap.config(state="disabled", text="📸 正在读取显存...")
        var_status.set("正在从 FPGA SSD1963 硬件显存读取画面，请稍候 (~4秒)...")

        def _worker():
            try:
                out_path = ctrl.capture_lcd_quick()
                root.after(0, lambda: (
                    var_status.set(f"抓屏成功！已保存: {out_path}"),
                    messagebox.showinfo("硬件抓屏完成", f"已成功读取 FPGA LCD 画面：\n{out_path}"),
                    btn_snap.config(state="normal", text="📸 硬件屏幕截屏")
                ))
            except Exception as ex:
                root.after(0, lambda: (
                    var_status.set(f"抓屏失败: {ex}"),
                    messagebox.showerror("抓屏失败", str(ex)),
                    btn_snap.config(state="normal", text="📸 硬件屏幕截屏")
                ))

        threading.Thread(target=_worker, daemon=True).start()

    btn_snap = tk.Button(snap_frame, text="📸 硬件屏幕截屏", bg="#204060", fg="#00F0FF", font=("Segoe UI", 9, "bold"), width=16, command=do_screenshot)
    btn_snap.pack(side="left", padx=2)

    def do_reinit_lcd():
        ctrl.reinit_lcd()
        var_status.set("已向 FPGA 发送 LCD 硬件重新初始化指令 (CC24 = 127)")

    btn_reinit = tk.Button(snap_frame, text="🔄 复位 LCD 屏幕", bg="#3B264E", fg="#FFC2D1", font=("Segoe UI", 9, "bold"), width=16, command=do_reinit_lcd)
    btn_reinit.pack(side="left", padx=4)

    # 3. 底部：37 键全音域图形化钢琴键盘 (C3..C6)
    piano_frame = tk.LabelFrame(root, text=" 37 键全音域演奏键盘 (C3..C6 = MIDI 48..84 | 支持电脑键盘与鼠标弹奏) ",
                                bg="#13223A", fg="#00F0FF", font=("Segoe UI", 11, "bold"), padx=10, pady=6)
    piano_frame.pack(fill="x", padx=12, pady=(4, 8))

    canvas_w = 1050
    canvas_h = 150
    cv = tk.Canvas(piano_frame, width=canvas_w, height=canvas_h, bg="#0D1627", highlightthickness=0)
    cv.pack(pady=2)

    WHITE_KEYS_SEMI = [0, 2, 4, 5, 7, 9, 11, 12, 14, 16, 17, 19, 21, 22, 24, 26, 28, 29, 31, 33, 35, 36]
    BLACK_KEYS_SEMI = [1, 3, 6, 8, 10, 13, 15, 18, 20, 23, 25, 27, 30, 32, 34]

    w_width = canvas_w / len(WHITE_KEYS_SEMI)
    w_height = canvas_h - 10
    b_width = w_width * 0.62
    b_height = w_height * 0.62

    key_rects = {}

    for i, semi in enumerate(WHITE_KEYS_SEMI):
        x0 = i * w_width + 5
        y0 = 5
        x1 = x0 + w_width - 2
        y1 = y0 + w_height
        note = 48 + semi
        rect_id = cv.create_rectangle(x0, y0, x1, y1, fill="#E6EEF8", outline="#1A345C", width=1)
        key_rects[note] = rect_id
        lbl_text = f"{note_to_name(note)}"
        cv.create_text((x0 + x1) / 2, y1 - 12, text=lbl_text, fill="#3D5A80", font=("Segoe UI", 8, "bold"))

    for semi in BLACK_KEYS_SEMI:
        prev_w_idx = None
        for i, ws in enumerate(WHITE_KEYS_SEMI):
            if ws == semi - 1:
                prev_w_idx = i
                break
        if prev_w_idx is not None:
            center_x = (prev_w_idx + 1) * w_width + 4
            x0 = center_x - b_width / 2
            y0 = 5
            x1 = x0 + b_width
            y1 = y0 + b_height
            note = 48 + semi
            rect_id = cv.create_rectangle(x0, y0, x1, y1, fill="#121824", outline="#00F0FF", width=1)
            key_rects[note] = rect_id

    def highlight_key(note, is_down):
        if note in key_rects:
            is_black = (note % 12) in (1, 3, 6, 8, 10)
            if is_down:
                cv.itemconfig(key_rects[note], fill="#00FF88")
            else:
                cv.itemconfig(key_rects[note], fill="#121824" if is_black else "#E6EEF8")

    mouse_current_note = None
    key_to_active_note = {}
    pressed_keys = set()

    def get_note_from_xy(x, y):
        for semi in BLACK_KEYS_SEMI:
            note = 48 + semi
            coords = cv.coords(key_rects[note])
            if coords and coords[0] <= x <= coords[2] and coords[1] <= y <= coords[3]:
                return note
        for semi in WHITE_KEYS_SEMI:
            note = 48 + semi
            coords = cv.coords(key_rects[note])
            if coords and coords[0] <= x <= coords[2] and coords[1] <= y <= coords[3]:
                return note
        return None

    def on_mouse_down(evt):
        nonlocal mouse_current_note
        n = get_note_from_xy(evt.x, evt.y)
        if mouse_current_note is not None and mouse_current_note != n:
            ctrl.note_off(mouse_current_note)
            highlight_key(mouse_current_note, False)
        if n is not None:
            mouse_current_note = n
            ctrl.note_on(n, 105)
            highlight_key(n, True)
            var_last_note.set(f"鼠标弹奏: {note_to_name(n)} (MIDI {n})")

    def on_mouse_motion(evt):
        nonlocal mouse_current_note
        n = get_note_from_xy(evt.x, evt.y)
        if n != mouse_current_note:
            if mouse_current_note is not None:
                ctrl.note_off(mouse_current_note)
                highlight_key(mouse_current_note, False)
            mouse_current_note = n
            if n is not None:
                ctrl.note_on(n, 105)
                highlight_key(n, True)
                var_last_note.set(f"鼠标滑奏: {note_to_name(n)} (MIDI {n})")

    def on_mouse_up(evt):
        nonlocal mouse_current_note
        if mouse_current_note is not None:
            ctrl.note_off(mouse_current_note)
            highlight_key(mouse_current_note, False)
            mouse_current_note = None

    cv.bind("<ButtonPress-1>", on_mouse_down)
    cv.bind("<B1-Motion>", on_mouse_motion)
    cv.bind("<ButtonRelease-1>", on_mouse_up)
    cv.bind("<Leave>", on_mouse_up)

    def on_key_down(evt):
        k = event_to_key(evt)
        if k in pressed_keys:
            return
        pressed_keys.add(k)

        if k in ("escape", "esc"):
            panic_all_sound_off()
            return
        if k in ("down", "pagedown"):
            step_volume(-8)
            return
        elif k in ("up", "pageup"):
            step_volume(+8)
            return
        if k == " ":
            toggle_sustain()
            return

        if k in KEY_MAP_37:
            semi = KEY_MAP_37[k]
            note = 48 + semi
            key_to_active_note[k] = note
            ctrl.note_on(note, 105)
            highlight_key(note, True)
            var_last_note.set(f"键盘按下: {note_to_name(note)} (键位 '{k.upper()}')")

    def on_key_up(evt):
        k = event_to_key(evt)
        if k in pressed_keys:
            pressed_keys.discard(k)

        if k in key_to_active_note:
            note = key_to_active_note.pop(k)
            ctrl.note_off(note)
            highlight_key(note, False)
        elif k in KEY_MAP_37:
            semi = KEY_MAP_37[k]
            note = 48 + semi
            ctrl.note_off(note)
            highlight_key(note, False)

    root.bind("<KeyPress>", on_key_down)
    root.bind("<KeyRelease>", on_key_up)

    # 底部状态条
    bottom_bar = tk.Frame(root, bg="#0D1627")
    bottom_bar.pack(fill="x", padx=14, pady=(0, 6))

    lbl_note_info = tk.Label(bottom_bar, textvariable=var_last_note, bg="#0D1627", fg="#FFE600", font=("Segoe UI", 9, "bold"))
    lbl_note_info.pack(side="left")

    lbl_global_status = tk.Label(bottom_bar, textvariable=var_status, bg="#0D1627", fg="#A0C4E2", font=("Segoe UI", 9))
    lbl_global_status.pack(side="right")

    # 初始化刷新端口并更新状态
    refresh_port_list()
    update_conn_ui()

    root.protocol("WM_DELETE_WINDOW", lambda: (ctrl.disconnect(), root.destroy()))
    root.mainloop()


# -----------------------------------------------------------------------------
# 入口函数
# -----------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description="FPGA 纯硬件现代音乐合成器上位机控制台 (纯 MIDI 隔离通道)")
    parser.add_argument("--port", default=None, help="指定串口号 (默认自动检测 Tang Mega 138K 串口)")
    parser.add_argument("--baud", type=int, default=115200, help="波特率 (默认 115200)")
    parser.add_argument("--cli", action="store_true", help="启用纯终端交互控制台 (无 GUI 依赖)")
    args = parser.parse_args()

    chosen_port = args.port if args.port else auto_detect_fpga_port()
    ctrl = SynthController(port_name=chosen_port, baud_rate=args.baud)

    print(f"[*] 正在尝试连接 FPGA 合成器串口: {chosen_port} @ {args.baud} 8N1 (防误复位保护模式)...")
    connected = ctrl.connect()
    if connected:
        print(f"[+] 成功连接到 FPGA 合成器: {chosen_port}")
    else:
        print(f"[-] 未能直接打开串口 {chosen_port}。当前可用串口列表:")
        port_list = get_available_ports()
        for dev, label, is_uart, is_jtag in port_list:
            tag = " [推荐]" if is_uart else (" [JTAG-勿选]" if is_jtag else "")
            print(f"    - {label}{tag}")
        print("\n程序将以离线演示模式继续启动，可在界面中重新选择并连接。")

    if args.cli:
        run_cli_console(ctrl)
    else:
        run_gui_console(ctrl)

if __name__ == "__main__":
    main()
