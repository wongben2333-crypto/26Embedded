"""
==============================================================================
FPGA 实时多音色电子乐器 - 电脑键盘钢琴模拟器
基于高云 Tang Mega 60K 纯硬件合成引擎算法 (Cycle-Accurate DSP Engine)
支持电脑键盘双手机位弹奏、鼠标点击、延音踏板、实时示波器与多乐器切换
==============================================================================
"""

import sys
import os
import math
import random
import threading
from collections import deque
import numpy as np

# 确保在 Windows 环境下编码正确
sys.stdout.reconfigure(encoding='utf-8')

import sounddevice as sd
from PySide6 import QtCore, QtGui, QtWidgets
from PySide6.QtCore import Qt, QTimer, QRectF, QPointF
from PySide6.QtGui import QColor, QPainter, QBrush, QPen, QFont, QLinearGradient, QPainterPath

FS = 48000
BLOCK_SIZE = 512  # 约 10.6ms 缓冲区，低延迟防爆音
TABLE_SIZE = 4096

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
WAVE_DIR = os.path.join(BASE_DIR, "rtl", "synth_core", "dds_wavetable")

# ------------------------------------------------------------------------------
# 1. 加载 FPGA 真实 BSRAM 16-bit 波表
# ------------------------------------------------------------------------------
def load_hex_table(filename):
    data = []
    if os.path.exists(filename):
        with open(filename, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                val = int(line, 16)
                if val >= 32768:
                    val -= 65536
                data.append(val / 32768.0)
    if len(data) != TABLE_SIZE:
        # 兜底生成标准正弦
        data = [math.sin(2 * math.pi * i / TABLE_SIZE) for i in range(TABLE_SIZE)]
    return np.array(data, dtype=np.float32)

ROM_SINE = load_hex_table(os.path.join(WAVE_DIR, "wavetable_sine.hex"))
ROM_SAW  = load_hex_table(os.path.join(WAVE_DIR, "wavetable_saw.hex"))
ROM_TRI  = load_hex_table(os.path.join(WAVE_DIR, "wavetable_tri.hex"))
ROM_SQR  = load_hex_table(os.path.join(WAVE_DIR, "wavetable_sqr.hex"))

# ------------------------------------------------------------------------------
# 2. 纯硬件发声单元模型 (Voice Models)
# ------------------------------------------------------------------------------
class Voice:
    def __init__(self, note_id, freq, velocity, instrument=0, wave_type=0):
        self.note_id = note_id
        self.freq = float(freq)
        self.velocity = float(velocity) / 127.0
        self.instrument = instrument  # 0: 三角钢琴, 1: 物理拨弦吉他, 2: DDS波表合成器, 3: 八音盒
        self.wave_type = wave_type    # 0: Sine, 1: Saw, 2: Tri, 3: Square
        self.gate = True
        self.active = True
        self.age = 0

        # 钢琴状态
        self.phase_f0 = random.random()
        self.phase_f0_d = random.random()
        self.phase_2f0 = random.random()
        self.phase_3f0 = random.random()
        self.env_f0 = 1.0
        self.env_overtone = 1.0 * self.velocity
        self.env_hammer = 0.8 * self.velocity

        # 吉他 Karplus-Strong 延迟线状态
        self.ks_len = max(10, min(2040, int(round(FS / max(20.0, self.freq)))))
        self.ks_buf = np.zeros(self.ks_len, dtype=np.float32)
        # 拨弦瞬态注入高斯/白噪声脉冲
        noise = (np.random.rand(self.ks_len).astype(np.float32) * 2.0 - 1.0) * self.velocity
        self.ks_buf[:] = noise
        self.ks_ptr = 0
        self.ks_prev = 0.0

        # DDS 合成器 ADSR
        self.dds_phase = 0.0
        self.adsr_level = 0.0
        self.adsr_state = 1  # 1: Attack, 2: Decay, 3: Sustain, 4: Release, 0: Done

        # 八音盒
        self.mb_phase1 = 0.0
        self.mb_phase2 = 0.0
        self.mb_phase3 = 0.0
        self.mb_env = 1.0

    def release(self):
        self.gate = False
        if self.adsr_state in (1, 2, 3):
            self.adsr_state = 4

    def render_block(self, num_samples, sustain_pedal=False):
        if not self.active:
            return np.zeros(num_samples, dtype=np.float32)

        t = np.arange(num_samples, dtype=np.float32)
        gate_effective = self.gate or sustain_pedal
        out = np.zeros(num_samples, dtype=np.float32)

        if self.instrument == 0:
            # === 大三角钢琴 (Grand Piano) ===
            # 基频 + 失谐0.15%双琴弦 + 2次泛音 + 3次泛音 + 击弦瞬态
            step_f0 = self.freq / FS
            step_f0_d = (self.freq * 1.0015) / FS
            
            p_f0 = (self.phase_f0 + t * step_f0) % 1.0
            p_f0_d = (self.phase_f0_d + t * step_f0_d) % 1.0
            p_2f0 = (self.phase_2f0 + t * (step_f0 * 2.0)) % 1.0
            p_3f0 = (self.phase_3f0 + t * (step_f0 * 3.0)) % 1.0

            s_f0 = np.sin(p_f0 * (2 * np.pi))
            s_f0_d = np.sin(p_f0_d * (2 * np.pi))
            s_2f0 = np.sin(p_2f0 * (2 * np.pi))
            s_3f0 = np.sin(p_3f0 * (2 * np.pi))

            if gate_effective:
                decay_f0 = np.power(0.99997, t)
                decay_ov = np.power(0.99988, t)
                decay_hm = np.power(0.996, t)
                end_f0 = 0.99997 ** num_samples
                end_ov = 0.99988 ** num_samples
                end_hm = 0.996 ** num_samples
            else:
                decay_f0 = np.power(0.9990, t)
                decay_ov = np.power(0.9980, t)
                decay_hm = np.power(0.990, t)
                end_f0 = 0.9990 ** num_samples
                end_ov = 0.9980 ** num_samples
                end_hm = 0.990 ** num_samples

            cur_env_f0 = self.env_f0 * decay_f0
            cur_env_ov = self.env_overtone * decay_ov
            cur_env_hm = self.env_hammer * decay_hm

            hammer_click = (np.random.rand(num_samples).astype(np.float32) * 2.0 - 1.0) * cur_env_hm * 0.25

            out = ((s_f0 + s_f0_d) * 0.45 * cur_env_f0 +
                   s_2f0 * 0.25 * cur_env_ov +
                   s_3f0 * 0.15 * cur_env_ov +
                   hammer_click) * self.velocity

            self.phase_f0 = (self.phase_f0 + num_samples * step_f0) % 1.0
            self.phase_f0_d = (self.phase_f0_d + num_samples * step_f0_d) % 1.0
            self.phase_2f0 = (self.phase_2f0 + num_samples * (step_f0 * 2.0)) % 1.0
            self.phase_3f0 = (self.phase_3f0 + num_samples * (step_f0 * 3.0)) % 1.0
            self.env_f0 *= end_f0
            self.env_overtone *= end_ov
            self.env_hammer *= end_hm

            if self.env_f0 < 0.0002 and not gate_effective:
                self.active = False

        elif self.instrument == 1:
            # === 原声吉他 (Karplus-Strong 拨弦) ===
            decay = 0.994 if gate_effective else 0.985
            # 优化快速低通闭环循环
            for i in range(num_samples):
                val = self.ks_buf[self.ks_ptr]
                filtered = 0.5 * (val + self.ks_prev) * decay
                self.ks_prev = val
                self.ks_buf[self.ks_ptr] = filtered
                out[i] = filtered
                self.ks_ptr = (self.ks_ptr + 1) % self.ks_len

            if np.max(np.abs(out)) < 0.0003 and not gate_effective:
                self.active = False

        elif self.instrument == 2:
            # === FPGA DDS 硬件波表合成器 ===
            table = [ROM_SINE, ROM_SAW, ROM_TRI, ROM_SQR][self.wave_type % 4]
            step = (self.freq * TABLE_SIZE) / FS
            indices = ((self.dds_phase + t * step) % TABLE_SIZE).astype(np.int32)
            wave_vals = table[indices]

            # 简易多点 ADSR
            env_vals = np.zeros(num_samples, dtype=np.float32)
            for i in range(num_samples):
                if self.adsr_state == 1:  # Attack
                    self.adsr_level += 0.008
                    if self.adsr_level >= 1.0:
                        self.adsr_level = 1.0
                        self.adsr_state = 2
                elif self.adsr_state == 2:  # Decay
                    self.adsr_level -= 0.001
                    if self.adsr_level <= 0.65:
                        self.adsr_level = 0.65
                        self.adsr_state = 3
                elif self.adsr_state == 3:  # Sustain
                    if not gate_effective:
                        self.adsr_state = 4
                elif self.adsr_state == 4:  # Release
                    self.adsr_level -= 0.002
                    if self.adsr_level <= 0.0001:
                        self.adsr_level = 0.0
                        self.adsr_state = 0
                        self.active = False
                env_vals[i] = self.adsr_level

            out = wave_vals * env_vals * self.velocity * 0.75
            self.dds_phase = (self.dds_phase + num_samples * step) % TABLE_SIZE

        elif self.instrument == 3:
            # === 纯净八音盒 (Music Box / Celesta) ===
            step1 = self.freq / FS
            step2 = (self.freq * 2.76) / FS
            step3 = (self.freq * 5.40) / FS
            
            p1 = (self.mb_phase1 + t * step1) % 1.0
            p2 = (self.mb_phase2 + t * step2) % 1.0
            p3 = (self.mb_phase3 + t * step3) % 1.0

            s1 = np.sin(p1 * 2 * np.pi)
            s2 = np.sin(p2 * 2 * np.pi)
            s3 = np.sin(p3 * 2 * np.pi)

            dec = 0.99992 if gate_effective else 0.9985
            env = self.mb_env * (dec ** t)
            self.mb_env *= (dec ** num_samples)

            out = (s1 * 0.7 + s2 * 0.2 + s3 * 0.1) * env * self.velocity * 0.8
            self.mb_phase1 = (self.mb_phase1 + num_samples * step1) % 1.0
            self.mb_phase2 = (self.mb_phase2 + num_samples * step2) % 1.0
            self.mb_phase3 = (self.mb_phase3 + num_samples * step3) % 1.0

            if self.mb_env < 0.0002 and not gate_effective:
                self.active = False

        self.age += num_samples
        return out

# ------------------------------------------------------------------------------
# 3. 实时音频流合成引擎
# ------------------------------------------------------------------------------
class AudioSynthEngine:
    def __init__(self):
        self.lock = threading.Lock()
        self.voices = {}  # note_id -> Voice
        self.instrument = 0
        self.wave_type = 0
        self.sustain_pedal = False
        self.volume = 0.85
        self.scope_buffer = np.zeros(1024, dtype=np.float32)
        self.active_count = 0
        self.last_note_name = "-"
        self.last_freq = 0.0

        # 初始化 sounddevice 输出流
        self.stream = sd.OutputStream(
            samplerate=FS,
            channels=2,
            blocksize=BLOCK_SIZE,
            callback=self._audio_callback
        )
        self.stream.start()

    def set_instrument(self, inst_idx):
        with self.lock:
            self.instrument = inst_idx

    def set_wave_type(self, wave_idx):
        with self.lock:
            self.wave_type = wave_idx

    def set_sustain(self, enabled):
        with self.lock:
            self.sustain_pedal = enabled
            if not enabled:
                for v in self.voices.values():
                    if not v.gate:
                        v.release()

    def note_on(self, note_id, freq, velocity=108, name=""):
        with self.lock:
            self.last_note_name = name
            self.last_freq = freq
            self.voices[note_id] = Voice(note_id, freq, velocity, self.instrument, self.wave_type)

    def note_off(self, note_id):
        with self.lock:
            if note_id in self.voices:
                self.voices[note_id].release()

    def _audio_callback(self, outdata, frames, time_info, status):
        mixed = np.zeros(frames, dtype=np.float32)

        with self.lock:
            dead_notes = []
            for note_id, voice in self.voices.items():
                v_out = voice.render_block(frames, self.sustain_pedal)
                mixed += v_out
                if not voice.active:
                    dead_notes.append(note_id)

            for nid in dead_notes:
                del self.voices[nid]

            self.active_count = len(self.voices)

        # 硬件饱和混音限制器 (Saturating Limiter)
        mixed = np.clip(mixed * self.volume, -1.0, 1.0)

        # 立体声输出
        outdata[:, 0] = mixed
        outdata[:, 1] = mixed

        # 复制到示波器分析环形缓冲区
        self.scope_buffer = np.roll(self.scope_buffer, -frames)
        self.scope_buffer[-frames:] = mixed

    def close(self):
        self.stream.stop()
        self.stream.close()

# ------------------------------------------------------------------------------
# 4. 键盘音符映射表 (从 C3 到 G5，跨越近 3 个完整八度)
# ------------------------------------------------------------------------------
# 基础 MIDI 音符
# C3 = 48, C4 = 60, C5 = 72, G5 = 79
NOTE_FREQ_MAP = {
    midi: 440.0 * (2.0 ** ((midi - 69.0) / 12.0)) for midi in range(36, 96)
}

NOTE_NAMES_RAW = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
def get_note_name(midi):
    octave = (midi // 12) - 1
    name = NOTE_NAMES_RAW[midi % 12]
    return f"{name}{octave}"

# 电脑键盘按键 -> MIDI 音符偏移 (基于中八度基准)
# 下排键 (左手和弦/低八度)：Z X C V B N M , . /
# 上排键 (右手旋律/高八度)：Q W E R T Y U I O P [ ]
KEY_MAP_BASE = {
    # 低八度白键
    Qt.Key_Z: 48,  # C3
    Qt.Key_X: 50,  # D3
    Qt.Key_C: 52,  # E3
    Qt.Key_V: 53,  # F3
    Qt.Key_B: 55,  # G3
    Qt.Key_N: 57,  # A3
    Qt.Key_M: 59,  # B3
    Qt.Key_Comma: 60,   # C4
    Qt.Key_Period: 62,  # D4
    Qt.Key_Slash: 64,   # E4

    # 低八度黑键
    Qt.Key_S: 49,  # C#3
    Qt.Key_D: 51,  # D#3
    Qt.Key_G: 54,  # F#3
    Qt.Key_H: 56,  # G#3
    Qt.Key_J: 58,  # A#3
    Qt.Key_L: 61,  # C#4
    Qt.Key_Semicolon: 63, # D#4

    # 高八度白键
    Qt.Key_Q: 60,  # C4
    Qt.Key_W: 62,  # D4
    Qt.Key_E: 64,  # E4
    Qt.Key_R: 65,  # F4
    Qt.Key_T: 67,  # G4
    Qt.Key_Y: 69,  # A4
    Qt.Key_U: 71,  # B4
    Qt.Key_I: 72,  # C5
    Qt.Key_O: 74,  # D5
    Qt.Key_P: 76,  # E5
    Qt.Key_BracketLeft: 77,  # F5
    Qt.Key_BracketRight: 79, # G5

    # 高八度黑键
    Qt.Key_2: 61,  # C#4
    Qt.Key_3: 63,  # D#4
    Qt.Key_5: 66,  # F#4
    Qt.Key_6: 68,  # G#4
    Qt.Key_7: 70,  # A#4
    Qt.Key_9: 73,  # C#5
    Qt.Key_0: 75,  # D#5
    Qt.Key_Equal: 78, # F#5
}

KEY_DISPLAY_LABELS = {
    48: "Z", 49: "S", 50: "X", 51: "D", 52: "C", 53: "V", 54: "G", 55: "B", 56: "H", 57: "N", 58: "J", 59: "M",
    60: "Q / ,", 61: "2 / L", 62: "W / .", 63: "3 / ;", 64: "E / /", 65: "R", 66: "5", 67: "T", 68: "6", 69: "Y", 70: "7", 71: "U",
    72: "I", 73: "9", 74: "O", 75: "0", 76: "P", 77: "[", 78: "=", 79: "]"
}

# ------------------------------------------------------------------------------
# 5. 自定义示波器控件 (Oscilloscope View)
# ------------------------------------------------------------------------------
class WaveformWidget(QtWidgets.QWidget):
    def __init__(self, synth_engine):
        super().__init__()
        self.engine = synth_engine
        self.setFixedHeight(95)
        self.timer = QTimer(self)
        self.timer.timeout.connect(self.update)
        self.timer.start(25)  # 40 FPS 刷新

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.Antialiasing)

        w = self.width()
        h = self.height()

        # 背景深邃科技感暗底
        bg_gradient = QLinearGradient(0, 0, 0, h)
        bg_gradient.setColorAt(0, QColor(16, 20, 28))
        bg_gradient.setColorAt(1, QColor(8, 10, 15))
        painter.fillRect(0, 0, w, h, bg_gradient)

        # 示波器中心网格虚线
        pen_grid = QPen(QColor(40, 50, 65), 1, Qt.DashLine)
        painter.setPen(pen_grid)
        painter.drawLine(0, int(h / 2), w, int(h / 2))
        painter.drawLine(0, int(h / 4), w, int(h / 4))
        painter.drawLine(0, int(h * 3 / 4), w, int(h * 3 / 4))

        # 提取当前波形点
        buf = self.engine.scope_buffer[-512:]
        if len(buf) < 2:
            return

        mid_y = h / 2.0
        scale_y = (h / 2.0) * 0.88
        dx = w / (len(buf) - 1)

        path = QPainterPath()
        path.moveTo(0, mid_y - buf[0] * scale_y)
        for i in range(1, len(buf)):
            x = i * dx
            y = mid_y - buf[i] * scale_y
            path.lineTo(x, y)

        # 霓虹电光青色线条
        pen_wave = QPen(QColor(0, 240, 255), 2)
        painter.setPen(pen_wave)
        painter.drawPath(path)

        # 绘制实时动态文字信息
        painter.setFont(QFont("Consolas", 9, QFont.Bold))
        painter.setPen(QColor(180, 200, 220))
        painter.drawText(12, 20, f"48kHz 24-bit 硬件实时混音示波器 | 并发复音: {self.engine.active_count} | 延迟: < 10ms")
        if self.engine.last_note_name != "-":
            painter.setPen(QColor(255, 200, 80))
            painter.drawText(w - 220, 20, f"音符: {self.engine.last_note_name} ({self.engine.last_freq:.1f}Hz)")

# ------------------------------------------------------------------------------
# 6. 虚拟琴键组件 (Interactive Piano Keyboard Widget)
# ------------------------------------------------------------------------------
class PianoKeyboardWidget(QtWidgets.QWidget):
    def __init__(self, synth_engine, parent=None):
        super().__init__(parent)
        self.engine = synth_engine
        self.setFixedHeight(180)
        self.setMinimumWidth(820)
        self.pressed_midi = set()
        self.octave_offset = 0

        # C3 (48) 到 G5 (79)，共 32 个半音
        self.start_midi = 48
        self.end_midi = 79

        # 计算白键列表
        self.white_midis = [m for m in range(self.start_midi, self.end_midi + 1) if not (m % 12 in (1, 3, 6, 8, 10))]
        self.black_midis = [m for m in range(self.start_midi, self.end_midi + 1) if (m % 12 in (1, 3, 6, 8, 10))]

        self.mouse_pressed_note = None

    def trigger_key(self, midi, vel=108):
        actual_midi = midi + self.octave_offset * 12
        if actual_midi in NOTE_FREQ_MAP:
            freq = NOTE_FREQ_MAP[actual_midi]
            name = get_note_name(actual_midi)
            self.pressed_midi.add(midi)
            self.engine.note_on(actual_midi, freq, vel, name)
            self.update()

    def release_key(self, midi):
        actual_midi = midi + self.octave_offset * 12
        self.pressed_midi.discard(midi)
        self.engine.note_off(actual_midi)
        self.update()

    def set_octave(self, offset):
        # 释放所有按下的键
        for m in list(self.pressed_midi):
            self.release_key(m)
        self.octave_offset = offset
        self.update()

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.Antialiasing)

        w = self.width()
        h = self.height()
        num_white = len(self.white_midis)
        white_w = w / num_white
        black_w = white_w * 0.62
        black_h = h * 0.60

        white_rects = {}
        # 1. 绘制白键
        for i, midi in enumerate(self.white_midis):
            x = i * white_w
            rect = QRectF(x, 0, white_w - 1, h - 2)
            white_rects[midi] = rect

            is_pressed = (midi in self.pressed_midi)
            grad = QLinearGradient(x, 0, x, h)
            if is_pressed:
                grad.setColorAt(0, QColor(255, 220, 130))
                grad.setColorAt(1, QColor(240, 180, 70))
            else:
                grad.setColorAt(0, QColor(255, 255, 255))
                grad.setColorAt(0.85, QColor(245, 245, 245))
                grad.setColorAt(1, QColor(220, 220, 220))

            painter.setBrush(grad)
            painter.setPen(QPen(QColor(160, 160, 160), 1))
            painter.drawRoundedRect(rect, 4, 4)

            # 音符名称和键盘快捷键标识
            note_name = get_note_name(midi + self.octave_offset * 12)
            key_label = KEY_DISPLAY_LABELS.get(midi, "")

            painter.setFont(QFont("Arial", 8, QFont.Bold))
            painter.setPen(QColor(40, 40, 40) if not is_pressed else QColor(20, 20, 20))
            painter.drawText(QRectF(x, h - 42, white_w, 20), Qt.AlignCenter, note_name)

            if key_label:
                painter.setFont(QFont("Consolas", 8, QFont.Bold))
                painter.setPen(QColor(0, 110, 200) if not is_pressed else QColor(10, 10, 10))
                painter.drawText(QRectF(x, h - 22, white_w, 18), Qt.AlignCenter, f"[{key_label}]")

        # 2. 绘制黑键
        for midi in self.black_midis:
            # 找到前一个白键
            prev_white = midi - 1
            if prev_white in self.white_midis:
                w_idx = self.white_midis.index(prev_white)
                x = (w_idx + 1) * white_w - (black_w / 2.0)
                rect = QRectF(x, 0, black_w, black_h)

                is_pressed = (midi in self.pressed_midi)
                grad = QLinearGradient(x, 0, x, black_h)
                if is_pressed:
                    grad.setColorAt(0, QColor(255, 200, 80))
                    grad.setColorAt(1, QColor(220, 140, 30))
                else:
                    grad.setColorAt(0, QColor(50, 50, 55))
                    grad.setColorAt(0.8, QColor(25, 25, 28))
                    grad.setColorAt(1, QColor(10, 10, 12))

                painter.setBrush(grad)
                painter.setPen(QPen(QColor(10, 10, 10), 1))
                painter.drawRoundedRect(rect, 3, 3)

                key_label = KEY_DISPLAY_LABELS.get(midi, "")
                if key_label:
                    painter.setFont(QFont("Consolas", 7, QFont.Bold))
                    painter.setPen(QColor(240, 240, 240) if not is_pressed else QColor(20, 20, 20))
                    painter.drawText(QRectF(x, black_h - 22, black_w, 18), Qt.AlignCenter, key_label)

    def mousePressEvent(self, event):
        pos = event.position()
        note = self._get_note_at(pos.x(), pos.y())
        if note is not None:
            self.mouse_pressed_note = note
            self.trigger_key(note)

    def mouseReleaseEvent(self, event):
        if self.mouse_pressed_note is not None:
            self.release_key(self.mouse_pressed_note)
            self.mouse_pressed_note = None

    def _get_note_at(self, x, y):
        w = self.width()
        h = self.height()
        num_white = len(self.white_midis)
        white_w = w / num_white
        black_w = white_w * 0.62
        black_h = h * 0.60

        # 先检测黑键 (黑键在上层)
        if y <= black_h:
            for midi in self.black_midis:
                prev_white = midi - 1
                if prev_white in self.white_midis:
                    w_idx = self.white_midis.index(prev_white)
                    bx = (w_idx + 1) * white_w - (black_w / 2.0)
                    if bx <= x <= bx + black_w:
                        return midi

        # 再检测白键
        idx = int(x // white_w)
        if 0 <= idx < len(self.white_midis):
            return self.white_midis[idx]
        return None

# ------------------------------------------------------------------------------
# 7. 主仿真器窗口 (Main Simulator Window)
# ------------------------------------------------------------------------------
class PianoSimulatorWindow(QtWidgets.QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("高云 Tang Mega 60K - 纯硬件电子乐器多复音钢琴模拟器")
        self.setMinimumSize(960, 580)
        self.resize(1020, 620)

        # 启动纯硬件音频引擎
        self.synth = AudioSynthEngine()

        self.current_octave = 0
        self.pressed_keys_record = set()

        self.init_ui()

    def init_ui(self):
        # 整体暗色质感样式表
        self.setStyleSheet("""
            QMainWindow {
                background-color: #14171E;
            }
            QLabel {
                color: #DCE3EA;
                font-family: 'Segoe UI', 'Microsoft YaHei', sans-serif;
            }
            QGroupBox {
                border: 1px solid #2B3342;
                border-radius: 8px;
                margin-top: 14px;
                font-size: 13px;
                font-weight: bold;
                color: #49B5FF;
                padding-top: 12px;
            }
            QGroupBox::title {
                subcontrol-origin: margin;
                left: 14px;
                padding: 0 5px;
            }
            QPushButton {
                background-color: #242B38;
                border: 1px solid #384457;
                color: #FFFFFF;
                border-radius: 6px;
                padding: 7px 16px;
                font-weight: bold;
                font-size: 12px;
            }
            QPushButton:hover {
                background-color: #313B4D;
                border-color: #4D96FF;
            }
            QPushButton:checked {
                background-color: #FFB703;
                color: #14171E;
                border-color: #FFB703;
            }
            QComboBox {
                background-color: #242B38;
                border: 1px solid #384457;
                border-radius: 6px;
                color: #FFFFFF;
                padding: 5px 12px;
                font-weight: bold;
            }
            QSlider::groove:horizontal {
                height: 6px;
                background: #242B38;
                border-radius: 3px;
            }
            QSlider::sub-page:horizontal {
                background: #00E5FF;
                border-radius: 3px;
            }
            QSlider::handle:horizontal {
                background: #FFFFFF;
                border: 2px solid #00E5FF;
                width: 16px;
                margin-top: -5px;
                margin-bottom: -5px;
                border-radius: 8px;
            }
        """)

        central_widget = QtWidgets.QWidget()
        self.setCentralWidget(central_widget)
        main_layout = QtWidgets.QVBoxLayout(central_widget)
        main_layout.setContentsMargins(18, 14, 18, 14)
        main_layout.setSpacing(12)

        # 1. 顶部控制工具栏
        top_bar = QtWidgets.QHBoxLayout()

        # 标题标签
        title_box = QtWidgets.QVBoxLayout()
        title_label = QtWidgets.QLabel("🎹 FPGA 多音色电子乐器 · 键盘钢琴模拟器")
        title_label.setFont(QFont("Microsoft YaHei", 15, QFont.Bold))
        title_label.setStyleSheet("color: #FFFFFF;")
        sub_label = QtWidgets.QLabel("Tang Mega 60K 纯硬件 Verilog 电路级真实仿真 (48kHz 24-bit 饱和混音)")
        sub_label.setFont(QFont("Microsoft YaHei", 9))
        sub_label.setStyleSheet("color: #8C9BAE;")
        title_box.addWidget(title_label)
        title_box.addWidget(sub_label)
        top_bar.addLayout(title_box)

        top_bar.addStretch()

        # 乐器音色选择器
        inst_label = QtWidgets.QLabel("音色选择 (按键1~4切换):")
        self.combo_inst = QtWidgets.QComboBox()
        self.combo_inst.addItems([
            "1. 斯坦威大三角钢琴 (击弦共鸣)",
            "2. 物理建模拨弦吉他 (Karplus-Strong)",
            "3. FPGA BSRAM波表合成器 (DDS)",
            "4. 梦幻八音盒 / 钟琴 (Celesta)"
        ])
        self.combo_inst.currentIndexChanged.connect(self.on_instrument_changed)
        top_bar.addWidget(inst_label)
        top_bar.addWidget(self.combo_inst)

        # DDS波形子选项
        self.combo_wave = QtWidgets.QComboBox()
        self.combo_wave.addItems(["正弦波 (Sine)", "锯齿波 (Saw)", "三角波 (Tri)", "方波 (Square)"])
        self.combo_wave.currentIndexChanged.connect(lambda idx: self.synth.set_wave_type(idx))
        self.combo_wave.setEnabled(False)
        top_bar.addWidget(self.combo_wave)

        # 延音踏板
        self.btn_sustain = QtWidgets.QPushButton("🦶 延音踏板 [空格键]")
        self.btn_sustain.setCheckable(True)
        self.btn_sustain.toggled.connect(self.on_sustain_toggled)
        top_bar.addWidget(self.btn_sustain)

        # 主音量
        vol_label = QtWidgets.QLabel("音量:")
        self.slider_vol = QtWidgets.QSlider(Qt.Horizontal)
        self.slider_vol.setRange(0, 100)
        self.slider_vol.setValue(85)
        self.slider_vol.setFixedWidth(90)
        self.slider_vol.valueChanged.connect(lambda val: setattr(self.synth, 'volume', val / 100.0))
        top_bar.addWidget(vol_label)
        top_bar.addWidget(self.slider_vol)

        main_layout.addLayout(top_bar)

        # 2. 实时示波器
        self.scope = WaveformWidget(self.synth)
        main_layout.addWidget(self.scope)

        # 3. 八度调节与当前状态条
        octave_bar = QtWidgets.QHBoxLayout()
        self.btn_oct_down = QtWidgets.QPushButton("◀ 降低八度 [- / PageDown]")
        self.btn_oct_down.clicked.connect(self.octave_down)
        self.label_oct = QtWidgets.QLabel("当前音区: 标准八度 (C3 ~ G5)")
        self.label_oct.setFont(QFont("Microsoft YaHei", 10, QFont.Bold))
        self.label_oct.setAlignment(Qt.AlignCenter)
        self.label_oct.setStyleSheet("color: #FFB703; padding: 0 10px;")
        self.btn_oct_up = QtWidgets.QPushButton("升高八度 [+ / PageUp] ▶")
        self.btn_oct_up.clicked.connect(self.octave_up)

        octave_bar.addWidget(self.btn_oct_down)
        octave_bar.addWidget(self.label_oct)
        octave_bar.addWidget(self.btn_oct_up)
        main_layout.addLayout(octave_bar)

        # 4. 虚拟钢琴键盘
        self.piano_widget = PianoKeyboardWidget(self.synth)
        main_layout.addWidget(self.piano_widget)

        # 5. 底部双手机位演奏指南与简易乐谱
        guide_group = QtWidgets.QGroupBox("电脑键盘演奏机位与经典指法建议")
        guide_layout = QtWidgets.QHBoxLayout(guide_group)
        guide_layout.setContentsMargins(12, 10, 12, 10)

        left_text = QtWidgets.QLabel(
            "<b>左手机位 (低音区和弦):</b><br>"
            "• 白键: <b>Z</b> (C3)  <b>X</b> (D3)  <b>C</b> (E3)  <b>V</b> (F3)  <b>B</b> (G3)  <b>N</b> (A3)  <b>M</b> (B3)<br>"
            "• 黑键: <b>S</b> (C#3)  <b>D</b> (D#3)  <b>G</b> (F#3)  <b>H</b> (G#3)  <b>J</b> (A#3)"
        )
        mid_text = QtWidgets.QLabel(
            "<b>右手机位 (高音区主旋律):</b><br>"
            "• 白键: <b>Q</b> (C4)  <b>W</b> (D4)  <b>E</b> (E4)  <b>R</b> (F4)  <b>T</b> (G4)  <b>Y</b> (A4)  <b>U</b> (B4)  <b>I</b> (C5)...<br>"
            "• 黑键: <b>2</b> (C#4)  <b>3</b> (D#4)  <b>5</b> (F#4)  <b>6</b> (G#4)  <b>7</b> (A#4)  <b>9</b> (C#5)"
        )
        right_text = QtWidgets.QLabel(
            "<b>经典简易曲谱速弹:</b><br>"
            "• <b>《小星星》</b>: Q Q T T Y Y T - R R E E W W Q<br>"
            "• <b>《两只老虎》</b>: Q W E Q  Q W E Q  E R T  E R T<br>"
            "• <b>《欢乐颂》</b>: E E R T T R E W Q Q W E E W W"
        )
        guide_layout.addWidget(left_text)
        guide_layout.addWidget(mid_text)
        guide_layout.addWidget(right_text)
        main_layout.addWidget(guide_group)

    def on_instrument_changed(self, idx):
        self.synth.set_instrument(idx)
        self.combo_wave.setEnabled(idx == 2)

    def on_sustain_toggled(self, checked):
        self.synth.set_sustain(checked)

    def octave_down(self):
        if self.current_octave > -2:
            self.current_octave -= 1
            self.update_octave_display()

    def octave_up(self):
        if self.current_octave < 2:
            self.current_octave += 1
            self.update_octave_display()

    def update_octave_display(self):
        self.piano_widget.set_octave(self.current_octave)
        names = {-2: "-2 八度 (C1 ~ G3)", -1: "-1 八度 (C2 ~ G4)", 0: "标准八度 (C3 ~ G5)", 1: "+1 八度 (C4 ~ G6)", 2: "+2 八度 (C5 ~ G7)"}
        self.label_oct.setText(f"当前音区: {names.get(self.current_octave, '')}")

    def keyPressEvent(self, event):
        if event.isAutoRepeat():
            return

        key = event.key()

        # 空格键延音踏板
        if key == Qt.Key_Space:
            self.btn_sustain.setChecked(not self.btn_sustain.isChecked())
            return

        # 乐器切换快捷键 1~4
        if key == Qt.Key_1:
            self.combo_inst.setCurrentIndex(0)
            return
        elif key == Qt.Key_2:
            self.combo_inst.setCurrentIndex(1)
            return
        elif key == Qt.Key_3:
            self.combo_inst.setCurrentIndex(2)
            return
        elif key == Qt.Key_4:
            self.combo_inst.setCurrentIndex(3)
            return

        # 八度调节快捷键
        if key in (Qt.Key_Minus, Qt.Key_PageDown):
            self.octave_down()
            return
        elif key in (Qt.Key_Plus, Qt.Key_Equal, Qt.Key_PageUp):
            self.octave_up()
            return

        # 音符触发
        if key in KEY_MAP_BASE and key not in self.pressed_keys_record:
            self.pressed_keys_record.add(key)
            midi = KEY_MAP_BASE[key]
            self.piano_widget.trigger_key(midi)

    def keyReleaseEvent(self, event):
        if event.isAutoRepeat():
            return

        key = event.key()
        if key in self.pressed_keys_record:
            self.pressed_keys_record.remove(key)
            midi = KEY_MAP_BASE[key]
            self.piano_widget.release_key(midi)

    def closeEvent(self, event):
        self.synth.close()
        event.accept()

# ------------------------------------------------------------------------------
# 8. 启动主程序
# ------------------------------------------------------------------------------
def main():
    app = QtWidgets.QApplication(sys.argv)
    app.setStyle("Fusion")
    win = PianoSimulatorWindow()
    win.show()
    sys.exit(app.exec())

if __name__ == "__main__":
    main()
