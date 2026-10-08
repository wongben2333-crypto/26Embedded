"""
==============================================================================
Script: simulate_faded_guitar.py
Description: 基于纯硬件 Karplus-Strong 物理建模算法的原声吉他指弹演奏《Faded》
             严格映射 FPGA 硬件电路逻辑 (对应 karplus_strong_string.v 与 DSP 音效器)
             
             乐曲特性:
             - 原声木吉他指弹 (Fingerstyle Acoustic Guitar) 编配
             - 低音弦稳健根音 (Thumb Bass) + 中音声部细腻琶音 + 高音声部悠扬主旋律
             - 物理琴弦模拟: 16位 LFSR 激励、变长环形移位寄存器、两点滑动平均低通滤波、
               弦长自适应物理衰减与木质箱体共鸣 (Body Resonance)
             - 经典乐章结构:
               * 00:00 ~ 00:16 【前奏 Intro】标志性轻柔分解和弦与主音动机
               * 00:16 ~ 00:38 【主歌 Verse】"You were the shadow to my light..." 叙事性律动
               * 00:38 ~ 01:10 【副歌 Chorus】"Where are you now? ... I'm faded" 饱满高潮指弹
               * 01:10 ~ 01:24 【尾声 Outro】泛音与长延音淡出
==============================================================================
"""

import os
import struct
import wave
import math
import random

FS = 48000
BASE_DIR = os.path.dirname(os.path.abspath(__file__))

# ------------------------------------------------------------------------------
# 1. 纯硬件 Karplus-Strong 原声吉他琴弦物理建模类 (严格映射 karplus_strong_string.v)
# ------------------------------------------------------------------------------
class KarplusStrongGuitarString:
    def __init__(self, max_delay=2048):
        self.max_delay = max_delay
        self.buffer = [0.0] * max_delay
        self.wr_ptr = 0
        self.lfsr = 0xACE1
        self.burst_cnt = 0
        self.injecting = False
        self.string_len = 100
        self.decay = 0.994
        self.prev_sample = 0.0
        self.velocity = 100

    def pluck(self, freq, velocity=100, brightness=0.85):
        # 琴弦长度 N = Fs / freq
        # 物理限制: 最高音到最低音保护
        self.string_len = max(12, min(self.max_delay - 4, int(round(FS / freq))))
        
        # 频率自适应物理阻尼: 高音弦衰减较快，低音弦延音长
        freq_normalized = min(1.0, freq / 1000.0)
        self.decay = 0.9965 - (freq_normalized * 0.008)
        
        self.burst_cnt = self.string_len
        self.injecting = True
        self.velocity = min(127, max(1, velocity))
        self.brightness = brightness

    def step(self):
        # 16-bit Galois LFSR 硬件白噪声发生器 (x^16 + x^14 + x^13 + x^11 + 1)
        bit = ((self.lfsr >> 0) ^ (self.lfsr >> 2) ^ (self.lfsr >> 3) ^ (self.lfsr >> 5)) & 1
        self.lfsr = ((self.lfsr >> 1) | (bit << 15)) & 0xFFFF
        noise = (self.lfsr / 32768.0) - 1.0

        # 读取延迟线历史样本 y[n-N]
        rd_ptr = (self.wr_ptr - self.string_len + self.max_delay) % self.max_delay
        curr_buf_val = self.buffer[rd_ptr]

        if self.injecting:
            # 拨弦激励脉冲注入，受力度动态与拨弦明亮度缩放
            excitation = noise * (self.velocity / 127.0) * (26000.0 * self.brightness)
            new_val = excitation
            self.burst_cnt -= 1
            if self.burst_cnt <= 0:
                self.injecting = False
        else:
            # 纯硬件 Karplus-Strong 低通循环反馈: y[n] = decay * (y[n-N] + y[n-N-1]) / 2
            filtered = 0.5 * (curr_buf_val + self.prev_sample)
            new_val = filtered * self.decay

        self.prev_sample = curr_buf_val
        self.buffer[self.wr_ptr] = new_val
        self.wr_ptr = (self.wr_ptr + 1) % self.max_delay

        return new_val

# ------------------------------------------------------------------------------
# 2. 吉他木质共鸣箱体 (Acoustic Guitar Body Resonator)
# ------------------------------------------------------------------------------
class GuitarBodyResonance:
    def __init__(self):
        # 模拟吉他共鸣箱的主要共振峰: 100Hz (空气腔 Helmholz), 200Hz (面板共振)
        self.y1_a = 0.0
        self.y2_a = 0.0
        self.y1_b = 0.0
        self.y2_b = 0.0

    def process(self, x):
        # 简单二阶低通增强木质暖度
        out_a = x + 0.18 * self.y1_a - 0.08 * self.y2_a
        self.y2_a = self.y1_a
        self.y1_a = out_a

        out_b = x + 0.12 * self.y1_b - 0.05 * self.y2_b
        self.y2_b = self.y1_b
        self.y1_b = out_b

        return x * 0.75 + (out_a + out_b) * 0.25

# ------------------------------------------------------------------------------
# 3. 乐音音高转频率辅助
# ------------------------------------------------------------------------------
NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
NOTE_MAP = {
    "Db": "C#", "Eb": "D#", "Gb": "F#", "Ab": "G#", "Bb": "A#"
}

def get_freq(note_str):
    """支持 'E2', 'F#4', 'Bb3' 等标准记音法"""
    if len(note_str) >= 2 and note_str[1] in ["#", "b"]:
        name = note_str[:2]
        octave = int(note_str[2:])
    else:
        name = note_str[:1]
        octave = int(note_str[1:])
    name = NOTE_MAP.get(name, name)
    semitone = NOTE_NAMES.index(name)
    midi_num = (octave + 1) * 12 + semitone
    return 440.0 * (2.0 ** ((midi_num - 69) / 12.0))

# ------------------------------------------------------------------------------
# 4. 《Faded》吉他指弹全曲编配生成
# ------------------------------------------------------------------------------
def generate_faded_performance():
    BPM = 90.0
    BEAT_SEC = 60.0 / BPM          # 一拍时间约 0.667 秒
    SIXTEENTH = BEAT_SEC / 4.0     # 十六分音符约 0.1667 秒
    BAR_SEC = BEAT_SEC * 4.0       # 一小节时间约 2.667 秒

    print(f"[Guitar-Engine] 正在编配《Faded》吉他指弹演奏...")
    print(f"                调性: E小调 (Em - C - G - D) | 速度: {BPM} BPM | 采样率: {FS}Hz")

    # 乐谱事件列表: (触发采样点, 音符, 力度, 拨弦明亮度)
    events = []

    def add_note(time_sec, note, vel=100, bright=0.85):
        smp = int(round(time_sec * FS))
        events.append((smp, note, vel, bright))

    def play_arpeggio(t_bar, bass_note, n1, n2, n3, bass_vel=115, arp_vel=80):
        """标准 4/4 拍指弹分解和弦律动"""
        # 第 1 拍: 根音 + 分解
        add_note(t_bar + 0.0 * BEAT_SEC, bass_note, bass_vel, 0.95)
        add_note(t_bar + 0.5 * BEAT_SEC, n1, arp_vel, 0.80)
        # 第 2 拍: 分解爬升
        add_note(t_bar + 1.0 * BEAT_SEC, n2, arp_vel + 5, 0.82)
        add_note(t_bar + 1.5 * BEAT_SEC, n3, arp_vel + 10, 0.85)
        # 第 3 拍: 弱根音 / 中音交替
        add_note(t_bar + 2.0 * BEAT_SEC, n1, arp_vel + 5, 0.80)
        add_note(t_bar + 2.5 * BEAT_SEC, n2, arp_vel, 0.78)
        # 第 4 拍: 回落准备
        add_note(t_bar + 3.0 * BEAT_SEC, n3, arp_vel + 8, 0.85)
        add_note(t_bar + 3.5 * BEAT_SEC, n2, arp_vel, 0.78)

    current_time = 0.5 # 0.5秒静音起首

    # ==========================================================================
    # 阶段 1: 【前奏 Intro】(2轮和弦进行 = 8小节, 约 21.3秒)
    # ==========================================================================
    # 和弦: Em -> C -> G -> D
    chords_intro = [
        ("E2", "B3", "E4", "G4"), # Em
        ("C3", "G3", "C4", "E4"), # C
        ("G2", "D4", "G4", "B4"), # G
        ("D3", "A3", "D4", "F#4") # D
    ]

    # 第 1 轮前奏: 纯静谧分解和弦
    for bass, n1, n2, n3 in chords_intro:
        play_arpeggio(current_time, bass, n1, n2, n3, bass_vel=105, arp_vel=75)
        current_time += BAR_SEC

    # 第 2 轮前奏: 分解和弦带入标志性高音动机
    # Em: B4 -> G4 -> E4
    t = current_time
    play_arpeggio(t, "E2", "B3", "E4", "G4", bass_vel=110, arp_vel=75)
    add_note(t + 0.0 * BEAT_SEC, "B4", 112, 0.90)
    add_note(t + 2.0 * BEAT_SEC, "G4", 100, 0.85)
    add_note(t + 3.0 * BEAT_SEC, "E4", 100, 0.85)
    current_time += BAR_SEC

    # C: C5 -> B4 -> G4
    t = current_time
    play_arpeggio(t, "C3", "G3", "C4", "E4", bass_vel=110, arp_vel=75)
    add_note(t + 0.0 * BEAT_SEC, "C5", 115, 0.92)
    add_note(t + 2.0 * BEAT_SEC, "B4", 105, 0.88)
    add_note(t + 3.0 * BEAT_SEC, "G4", 100, 0.85)
    current_time += BAR_SEC

    # G: B4 -> D5 -> B4
    t = current_time
    play_arpeggio(t, "G2", "D4", "G4", "B4", bass_vel=110, arp_vel=75)
    add_note(t + 0.0 * BEAT_SEC, "B4", 112, 0.90)
    add_note(t + 2.0 * BEAT_SEC, "D5", 118, 0.95)
    add_note(t + 3.0 * BEAT_SEC, "B4", 105, 0.88)
    current_time += BAR_SEC

    # D: A4 -> F#4 -> D4
    t = current_time
    play_arpeggio(t, "D3", "A3", "D4", "F#4", bass_vel=110, arp_vel=75)
    add_note(t + 0.0 * BEAT_SEC, "A4", 110, 0.90)
    add_note(t + 2.0 * BEAT_SEC, "F#4", 105, 0.88)
    add_note(t + 3.0 * BEAT_SEC, "D4", 100, 0.85)
    current_time += BAR_SEC

    # ==========================================================================
    # 阶段 2: 【主歌 Verse】(8小节, 叙事性旋律, 约 21.3秒)
    # "You were the shadow to my light, did you feel us?
    #  Another start, you fade away, afraid our aim is out of sight..."
    # ==========================================================================
    # Bar 1 (Em): "You were the sha-dow to my light"
    t = current_time
    play_arpeggio(t, "E2", "B3", "E4", "G4", bass_vel=115, arp_vel=70)
    add_note(t + 0.0 * BEAT_SEC, "E4", 110, 0.88)
    add_note(t + 0.75 * BEAT_SEC, "E4", 105, 0.85)
    add_note(t + 1.25 * BEAT_SEC, "E4", 105, 0.85)
    add_note(t + 2.0 * BEAT_SEC, "E4", 112, 0.90)
    add_note(t + 2.5 * BEAT_SEC, "D4", 100, 0.82)
    add_note(t + 3.0 * BEAT_SEC, "D4", 105, 0.85)
    current_time += BAR_SEC

    # Bar 2 (C): "Did you feel us?"
    t = current_time
    play_arpeggio(t, "C3", "G3", "C4", "E4", bass_vel=115, arp_vel=70)
    add_note(t + 0.0 * BEAT_SEC, "C4", 110, 0.88)
    add_note(t + 1.0 * BEAT_SEC, "C4", 105, 0.85)
    add_note(t + 2.0 * BEAT_SEC, "B3", 108, 0.85)
    add_note(t + 3.0 * BEAT_SEC, "B3", 100, 0.80)
    current_time += BAR_SEC

    # Bar 3 (G): "A-no-ther start, you fade a-way"
    t = current_time
    play_arpeggio(t, "G2", "D4", "G4", "B4", bass_vel=115, arp_vel=70)
    add_note(t + 0.0 * BEAT_SEC, "D4", 110, 0.88)
    add_note(t + 0.75 * BEAT_SEC, "D4", 105, 0.85)
    add_note(t + 1.25 * BEAT_SEC, "D4", 105, 0.85)
    add_note(t + 2.0 * BEAT_SEC, "G4", 115, 0.92)
    add_note(t + 2.75 * BEAT_SEC, "F#4", 108, 0.88)
    add_note(t + 3.25 * BEAT_SEC, "E4", 102, 0.85)
    current_time += BAR_SEC

    # Bar 4 (D): "A-fraid our aim is out of sight"
    t = current_time
    play_arpeggio(t, "D3", "A3", "D4", "F#4", bass_vel=115, arp_vel=70)
    add_note(t + 0.0 * BEAT_SEC, "D4", 110, 0.88)
    add_note(t + 1.0 * BEAT_SEC, "F#4", 108, 0.88)
    add_note(t + 2.0 * BEAT_SEC, "E4", 105, 0.85)
    add_note(t + 3.0 * BEAT_SEC, "D4", 100, 0.80)
    current_time += BAR_SEC

    # Bar 5 (Em): "Wan-na see us, a-live..."
    t = current_time
    play_arpeggio(t, "E2", "B3", "E4", "G4", bass_vel=115, arp_vel=72)
    add_note(t + 0.0 * BEAT_SEC, "E4", 112, 0.90)
    add_note(t + 1.0 * BEAT_SEC, "G4", 115, 0.92)
    add_note(t + 2.0 * BEAT_SEC, "B4", 120, 0.95)
    add_note(t + 3.0 * BEAT_SEC, "A4", 105, 0.88)
    current_time += BAR_SEC

    # Bar 6 (C): "A-live..."
    t = current_time
    play_arpeggio(t, "C3", "G3", "C4", "E4", bass_vel=115, arp_vel=72)
    add_note(t + 0.0 * BEAT_SEC, "G4", 112, 0.90)
    add_note(t + 1.5 * BEAT_SEC, "E4", 105, 0.85)
    add_note(t + 2.5 * BEAT_SEC, "G4", 110, 0.88)
    current_time += BAR_SEC

    # Bar 7 (G): "Where are you now..." (副歌情绪递进预备)
    t = current_time
    play_arpeggio(t, "G2", "D4", "G4", "B4", bass_vel=120, arp_vel=75)
    add_note(t + 0.0 * BEAT_SEC, "B4", 120, 0.95)
    add_note(t + 1.0 * BEAT_SEC, "B4", 115, 0.92)
    add_note(t + 2.0 * BEAT_SEC, "B4", 115, 0.92)
    add_note(t + 3.0 * BEAT_SEC, "G4", 110, 0.88)
    current_time += BAR_SEC

    # Bar 8 (D): "Where are you now..."
    t = current_time
    play_arpeggio(t, "D3", "A3", "D4", "F#4", bass_vel=120, arp_vel=75)
    add_note(t + 0.0 * BEAT_SEC, "B4", 120, 0.95)
    add_note(t + 1.0 * BEAT_SEC, "B4", 115, 0.92)
    add_note(t + 2.0 * BEAT_SEC, "B4", 115, 0.92)
    add_note(t + 3.0 * BEAT_SEC, "A4", 112, 0.90)
    current_time += BAR_SEC

    # ==========================================================================
    # 阶段 3: 【副歌 Chorus】(8小节, 全音域饱满指弹高潮, 约 21.3秒)
    # "Where are you now? Was it all in my fantasy?
    #  Where are you now? Were you only imaginary?
    #  Where are you now? Atlantis, under the sea, under the sea
    #  Where are you now? Another dream, the monsters running wild inside of me
    #  I'm faded, I'm faded..."
    # ==========================================================================
    # Bar 1 (Em): "Where are you now?"
    t = current_time
    play_arpeggio(t, "E2", "B3", "E4", "G4", bass_vel=125, arp_vel=82)
    add_note(t + 0.0 * BEAT_SEC, "B4", 125, 0.96)
    add_note(t + 0.5 * BEAT_SEC, "B4", 118, 0.92)
    add_note(t + 1.0 * BEAT_SEC, "B4", 120, 0.94)
    add_note(t + 1.5 * BEAT_SEC, "G4", 115, 0.90)
    add_note(t + 2.5 * BEAT_SEC, "B4", 120, 0.94)
    add_note(t + 3.25 * BEAT_SEC, "D5", 125, 0.98)
    current_time += BAR_SEC

    # Bar 2 (C): "Where are you now? Was it all in my fantasy?"
    t = current_time
    play_arpeggio(t, "C3", "G3", "C4", "E4", bass_vel=125, arp_vel=82)
    add_note(t + 0.0 * BEAT_SEC, "C5", 125, 0.96)
    add_note(t + 0.75 * BEAT_SEC, "B4", 115, 0.90)
    add_note(t + 1.25 * BEAT_SEC, "A4", 115, 0.90)
    add_note(t + 2.0 * BEAT_SEC, "G4", 118, 0.92)
    add_note(t + 2.75 * BEAT_SEC, "F#4", 112, 0.88)
    add_note(t + 3.25 * BEAT_SEC, "E4", 115, 0.90)
    current_time += BAR_SEC

    # Bar 3 (G): "Where are you now? Were you on-ly i-ma-gi-na-ry?"
    t = current_time
    play_arpeggio(t, "G2", "D4", "G4", "B4", bass_vel=125, arp_vel=82)
    add_note(t + 0.0 * BEAT_SEC, "B4", 125, 0.96)
    add_note(t + 0.5 * BEAT_SEC, "B4", 118, 0.92)
    add_note(t + 1.0 * BEAT_SEC, "B4", 120, 0.94)
    add_note(t + 1.5 * BEAT_SEC, "A4", 115, 0.90)
    add_note(t + 2.0 * BEAT_SEC, "G4", 118, 0.92)
    add_note(t + 2.5 * BEAT_SEC, "F#4", 112, 0.88)
    add_note(t + 3.0 * BEAT_SEC, "E4", 110, 0.88)
    add_note(t + 3.5 * BEAT_SEC, "D4", 108, 0.85)
    current_time += BAR_SEC

    # Bar 4 (D): "Where are you now?"
    t = current_time
    play_arpeggio(t, "D3", "A3", "D4", "F#4", bass_vel=125, arp_vel=82)
    add_note(t + 0.0 * BEAT_SEC, "F#4", 120, 0.94)
    add_note(t + 1.0 * BEAT_SEC, "A4", 122, 0.95)
    add_note(t + 2.0 * BEAT_SEC, "B4", 125, 0.96)
    add_note(t + 3.0 * BEAT_SEC, "D5", 126, 0.98)
    current_time += BAR_SEC

    # Bar 5 (Em): "At-lan-tis, un-der the sea, un-der the sea"
    t = current_time
    play_arpeggio(t, "E2", "B3", "E4", "G4", bass_vel=125, arp_vel=85)
    add_note(t + 0.0 * BEAT_SEC, "E5", 127, 1.0)
    add_note(t + 0.5 * BEAT_SEC, "D5", 120, 0.95)
    add_note(t + 1.0 * BEAT_SEC, "B4", 122, 0.95)
    add_note(t + 1.5 * BEAT_SEC, "A4", 115, 0.90)
    add_note(t + 2.0 * BEAT_SEC, "G4", 118, 0.92)
    add_note(t + 2.5 * BEAT_SEC, "A4", 118, 0.92)
    add_note(t + 3.0 * BEAT_SEC, "B4", 122, 0.95)
    current_time += BAR_SEC

    # Bar 6 (C): "Where are you now? A-no-ther dream..."
    t = current_time
    play_arpeggio(t, "C3", "G3", "C4", "E4", bass_vel=125, arp_vel=85)
    add_note(t + 0.0 * BEAT_SEC, "G4", 120, 0.94)
    add_note(t + 0.75 * BEAT_SEC, "F#4", 115, 0.90)
    add_note(t + 1.25 * BEAT_SEC, "E4", 115, 0.90)
    add_note(t + 2.0 * BEAT_SEC, "G4", 122, 0.95)
    add_note(t + 3.0 * BEAT_SEC, "B4", 125, 0.98)
    current_time += BAR_SEC

    # Bar 7 (G): "The mon-sters run-ning wild in-side of me"
    t = current_time
    play_arpeggio(t, "G2", "D4", "G4", "B4", bass_vel=125, arp_vel=85)
    add_note(t + 0.0 * BEAT_SEC, "D5", 126, 0.98)
    add_note(t + 0.5 * BEAT_SEC, "B4", 120, 0.95)
    add_note(t + 1.0 * BEAT_SEC, "D5", 125, 0.98)
    add_note(t + 1.75 * BEAT_SEC, "E5", 127, 1.0)
    add_note(t + 2.5 * BEAT_SEC, "D5", 120, 0.95)
    add_note(t + 3.25 * BEAT_SEC, "B4", 118, 0.92)
    current_time += BAR_SEC

    # Bar 8 (D): "I'm fa-ded, I'm fa-ded..."
    t = current_time
    play_arpeggio(t, "D3", "A3", "D4", "F#4", bass_vel=125, arp_vel=85)
    add_note(t + 0.0 * BEAT_SEC, "A4", 122, 0.95)
    add_note(t + 0.75 * BEAT_SEC, "D5", 125, 0.98)
    add_note(t + 1.5 * BEAT_SEC, "B4", 122, 0.95)
    add_note(t + 2.25 * BEAT_SEC, "D5", 125, 0.98)
    add_note(t + 3.0 * BEAT_SEC, "B4", 120, 0.94)
    current_time += BAR_SEC

    # ==========================================================================
    # 阶段 4: 【尾声 Outro】(4小节, 自然泛音与减慢淡出, 约 13秒)
    # ==========================================================================
    # 渐慢抒情淡出
    t = current_time
    # Em 和弦琶音 (带九音 F#)
    add_note(t + 0.0, "E2", 110, 0.85)
    add_note(t + 0.25, "B3", 90, 0.80)
    add_note(t + 0.50, "E4", 95, 0.82)
    add_note(t + 0.75, "F#4", 100, 0.85)
    add_note(t + 1.00, "G4", 105, 0.88)
    add_note(t + 1.50, "B4", 110, 0.90)
    add_note(t + 2.00, "E5", 115, 0.92)
    t += BAR_SEC * 1.05

    # Cmaj7 和弦琶音
    add_note(t + 0.0, "C3", 105, 0.85)
    add_note(t + 0.30, "G3", 85, 0.78)
    add_note(t + 0.60, "C4", 90, 0.80)
    add_note(t + 0.90, "E4", 95, 0.82)
    add_note(t + 1.20, "B4", 105, 0.88)
    t += BAR_SEC * 1.1

    # Dsus4 -> D 琶音
    add_note(t + 0.0, "D3", 105, 0.85)
    add_note(t + 0.35, "A3", 85, 0.78)
    add_note(t + 0.70, "D4", 90, 0.80)
    add_note(t + 1.05, "G4", 95, 0.82)
    add_note(t + 1.40, "F#4", 95, 0.82)
    t += BAR_SEC * 1.15

    # 最终 Em 终极和弦延音 (扫弦琶音依次触弦)
    add_note(t + 0.00, "E2", 115, 0.90)
    add_note(t + 0.06, "B2", 105, 0.85)
    add_note(t + 0.12, "E3", 105, 0.85)
    add_note(t + 0.18, "G3", 100, 0.85)
    add_note(t + 0.24, "B3", 105, 0.88)
    add_note(t + 0.30, "E4", 115, 0.92)
    t += 4.5 # 余音袅袅自然衰减

    total_duration = t
    total_samples = int(total_duration * FS)

    print(f"[Guitar-Engine] 乐谱构建完成！总音符事件数: {len(events)} | 总演奏时长: {total_duration:.1f}秒")

    # 构建时间索引字典以实现高效仿真
    event_dict = {}
    for smp, note, vel, bright in events:
        event_dict.setdefault(smp, []).append((note, vel, bright))

    # 实例化 12 根物理琴弦 (可完全容纳复音琶音、低音共振与高音旋律叠音)
    NUM_STRINGS = 12
    strings = [KarplusStrongGuitarString() for _ in range(NUM_STRINGS)]
    string_rr = 0

    # 实例化木质共鸣箱与立体声混响器
    body_fx = GuitarBodyResonance()
    
    # 空间立体声延迟网络 (模拟录音室声学空间与琴弦交叉拾音)
    dly_l = [0.0] * int(FS * 0.027) # 27ms
    dly_r = [0.0] * int(FS * 0.035) # 35ms
    idx_l = 0
    idx_r = 0

    out_l = []
    out_r = []

    print("[Guitar-Engine] 正在运行 Karplus-Strong 纯硬件物理建模循环计算...")
    for n in range(total_samples):
        # 触发当前周期的拨弦事件
        if n in event_dict:
            for note, vel, bright in event_dict[n]:
                freq = get_freq(note)
                strings[string_rr].pluck(freq, velocity=vel, brightness=bright)
                string_rr = (string_rr + 1) % NUM_STRINGS

        # 累加所有琴弦的实时振动输出
        sample_sum = 0.0
        for s in strings:
            sample_sum += s.step()

        # 木质共鸣滤波
        resonant_sample = body_fx.process(sample_sum)

        # 立体声声像与空间反射 (左右声道呈现出高低音弦的不同物理方位)
        del_sample_l = dly_l[idx_l]
        del_sample_r = dly_r[idx_r]

        dly_l[idx_l] = resonant_sample * 0.85
        dly_r[idx_r] = resonant_sample * 0.85
        idx_l = (idx_l + 1) % len(dly_l)
        idx_r = (idx_r + 1) % len(dly_r)

        # 空间混音: 直达声 + 交叉空间早反射
        ch_l = resonant_sample * 0.82 + del_sample_r * 0.22
        ch_r = resonant_sample * 0.82 + del_sample_l * 0.22

        # 饱和限幅到 16-bit PCM 范围 (-32768 ~ 32767)
        val_l = max(-32768, min(32767, int(ch_l)))
        val_r = max(-32768, min(32767, int(ch_r)))

        out_l.append(val_l)
        out_r.append(val_r)

    # 导出至 WAV 文件
    out_dir = os.path.join(BASE_DIR, "..", "临时音频")
    os.makedirs(out_dir, exist_ok=True)
    out_wav_path = os.path.join(out_dir, "faded_guitar_demo.wav")
    print(f"[Guitar-Engine] 仿真完成！正在导出音频文件至: {out_wav_path} ...")
    
    with wave.open(out_wav_path, "wb") as wf:
        wf.setnchannels(2)
        wf.setsampwidth(2)
        wf.setframerate(FS)
        frames = bytearray()
        for l, r in zip(out_l, out_r):
            frames.extend(struct.pack("<hh", l, r))
        wf.writeframes(frames)

    print(f"[SUCCESS] 《Faded》吉他指弹演奏音频成功导出！")
    print(f"          路径: {os.path.abspath(out_wav_path)}")
    print(f"          格式: 48kHz, 16-bit, 双声道立体声")
    print(f"          时长: {total_duration:.1f} 秒")

if __name__ == "__main__":
    generate_faded_performance()
