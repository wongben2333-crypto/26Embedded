"""
==============================================================================
Script: simulate_piano_guitar.py
Description: FPGA 纯硬件钢琴与吉他两种经典乐器音色仿真与音频导出
             严格映射 Verilog 硬件电路：
             1. 原声吉他：Karplus-Strong (K-S) 纯物理建模拨弦算法
                - 16位 LFSR 硬件白噪声注入
                - 片上 BSRAM 环形移位延迟线 (N = Fs / f0)
                - 2点滑动平均低通滤波与弦阻尼衰减反馈回路
             2. 三角钢琴：双琴弦失谐 (Detuned Unisons) + 多谐波时变衰减模型
                - 琴槌微秒级敲击瞬态
                - 高次泛音快衰减、基波长共振
                - 力度动态响应
             
             乐章结构:
             - 00:00 ~ 00:09: 【原声吉他独奏】Karplus-Strong 纯物理建模拨弦 (爱的罗曼史风格分解和弦)
             - 00:09 ~ 00:18: 【大三角钢琴独奏】具有琴槌击弦瞬态与慢衰减共振的三角钢琴
             - 00:18 ~ 00:26: 【琴吉协奏合奏】吉他分解和弦琶音 + 钢琴醇厚和弦与悠扬主旋律
==============================================================================
"""

import os
import struct
import wave
import math
import random

FS = 48000
TOTAL_DURATION = 26.0
TOTAL_SAMPLES = int(FS * TOTAL_DURATION)
BASE_DIR = os.path.dirname(os.path.abspath(__file__))

# ------------------------------------------------------------------------------
# 1. 纯硬件 Karplus-Strong 原声吉他发声单元仿真类 (对应 karplus_strong_string.v)
# ------------------------------------------------------------------------------
class HwGuitarString:
    def __init__(self, max_delay=2048):
        self.max_delay = max_delay
        self.buffer = [0.0] * max_delay
        self.wr_ptr = 0
        self.lfsr = 0xACE1
        self.burst_cnt = 0
        self.injecting = False
        self.string_len = 100
        self.decay = 0.994  # 琴弦物理材质阻尼系数
        self.prev_sample = 0.0

    def pluck(self, freq, velocity=100, decay=0.994):
        # 琴弦长度 N = Fs / freq
        self.string_len = max(10, min(self.max_delay - 2, int(round(FS / freq))))
        self.decay = decay
        self.burst_cnt = self.string_len
        self.injecting = True
        self.velocity = velocity

    def step(self):
        # 16-bit LFSR 白噪声生成
        bit = ((self.lfsr >> 0) ^ (self.lfsr >> 2) ^ (self.lfsr >> 3) ^ (self.lfsr >> 5)) & 1
        self.lfsr = ((self.lfsr >> 1) | (bit << 15)) & 0xFFFF
        noise = (self.lfsr / 32768.0) - 1.0

        rd_ptr = (self.wr_ptr - self.string_len + self.max_delay) % self.max_delay
        curr_buf_val = self.buffer[rd_ptr]

        if self.injecting:
            # 拨弦瞬间注入白噪声脉冲，并受力度缩放
            excitation = noise * (self.velocity / 127.0) * 28000.0
            new_val = excitation
            self.burst_cnt -= 1
            if self.burst_cnt <= 0:
                self.injecting = False
        else:
            # Karplus-Strong 闭环物理低通滤波反馈: y[n] = decay * (y[n-N] + y[n-N-1]) / 2
            filtered = 0.5 * (curr_buf_val + self.prev_sample)
            new_val = filtered * self.decay

        self.prev_sample = curr_buf_val
        self.buffer[self.wr_ptr] = new_val
        self.wr_ptr = (self.wr_ptr + 1) % self.max_delay

        return max(-32768, min(32767, int(new_val)))

# ------------------------------------------------------------------------------
# 2. 纯硬件声学钢琴发声单元仿真类 (对应 piano_voice.v)
# ------------------------------------------------------------------------------
class HwPianoVoice:
    def __init__(self):
        self.phase_f0 = 0.0
        self.phase_f0_detune = 0.0
        self.phase_2f0 = 0.0
        self.phase_3f0 = 0.0
        
        self.env_f0 = 0.0
        self.env_overtone = 0.0
        self.env_hammer = 0.0
        self.gate = False
        self.freq = 440.0
        self.velocity = 100

    def trigger(self, freq, velocity=100):
        self.freq = freq
        self.velocity = velocity
        self.gate = True
        self.env_f0 = 1.0
        self.env_overtone = 1.0 * (velocity / 127.0)
        self.env_hammer = 0.8 * (velocity / 127.0)

    def release(self):
        self.gate = False

    def step(self):
        if self.env_f0 <= 0.0001:
            return 0

        # 相位累加 (双琴弦失谐 detune = 0.12% 产生自然温润共鸣合唱)
        step_f0 = self.freq / FS
        step_f0_d = (self.freq * 1.0015) / FS
        
        self.phase_f0 = (self.phase_f0 + step_f0) % 1.0
        self.phase_f0_detune = (self.phase_f0_detune + step_f0_d) % 1.0
        self.phase_2f0 = (self.phase_2f0 + step_f0 * 2.0) % 1.0
        self.phase_3f0 = (self.phase_3f0 + step_f0 * 3.0) % 1.0

        # 查表正弦分量
        s_f0   = math.sin(self.phase_f0 * 2 * math.pi)
        s_f0_d = math.sin(self.phase_f0_detune * 2 * math.pi)
        s_2f0  = math.sin(self.phase_2f0 * 2 * math.pi)
        s_3f0  = math.sin(self.phase_3f0 * 2 * math.pi)

        # 多级物理包络衰减
        if self.gate:
            self.env_f0 *= 0.99997       # 基频极慢衰减 (~2.5-3.0 秒长共振)
            self.env_overtone *= 0.99988 # 高次泛音中速衰减
            self.env_hammer *= 0.996     # 琴槌击弦瞬态 (~10ms 急速消失)
        else:
            self.env_f0 *= 0.9992        # 释放阻音器落弦
            self.env_overtone *= 0.9985

        # 敲击瞬态噪声
        hammer_click = (random.random() * 2.0 - 1.0) * self.env_hammer * 0.25

        # 谐波混音叠加
        raw = ( (s_f0 + s_f0_d) * 0.45 * self.env_f0 +
                s_2f0 * 0.25 * self.env_overtone +
                s_3f0 * 0.15 * self.env_overtone +
                hammer_click )

        vel_scale = (self.velocity / 127.0) * 24000.0
        sample = int(raw * vel_scale)
        return max(-32768, min(32767, sample))

# ------------------------------------------------------------------------------
# 任意音符频率通用计算器
# ------------------------------------------------------------------------------
NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

def get_freq(name):
    clean = name.strip()
    if clean.endswith("b"):
        base = clean[:-2]
        octave = int(clean[-2])
    elif "#" in clean:
        base = clean[:2]
        octave = int(clean[2:])
    else:
        base = clean[:-1]
        octave = int(clean[-1])
        
    semitone = NOTE_NAMES.index(base)
    midi_num = (octave + 1) * 12 + semitone
    return 440.0 * (2.0 ** ((midi_num - 69) / 12.0))

def generate_performance():
    print(f"[Sim] 正在生成吉他与钢琴两种乐器音色纯硬件仿真对比音频 (时长: {TOTAL_DURATION}秒)...")
    
    # 实例化吉他弦阵列 (6 根虚拟琴弦对应真实吉他 6 弦)
    guitar_strings = [HwGuitarString() for _ in range(6)]
    
    # 实例化钢琴复音声部 (8 个物理复音声部)
    piano_voices = [HwPianoVoice() for _ in range(8)]

    out_l = []
    out_r = []

    # 简单空间立体声延迟缓冲 (Schroeder / Delay)
    dly_buf_l = [0] * int(FS * 0.025) # 25ms 空间反射
    dly_buf_r = [0] * int(FS * 0.033) # 33ms 空间反射
    dly_idx_l = 0
    dly_idx_r = 0

    beat_len = int(FS * 0.25) # 0.25s 拍长

    # 乐谱事件表 (时间帧, 乐器, 音符, 力度)
    # 阶段 1: 0~9 秒 吉他独奏 (经典的 Spanish Romance 风格分解和弦: Em -> Am -> B7 -> Em)
    guitar_events = []
    # 阶段 2: 9~18 秒 钢琴独奏 (理查德·克莱德曼风格温润抒情和弦与晶莹剔透的主题旋律)
    piano_events = []
    # 阶段 3: 18~26 秒 琴吉协奏
    duet_events = []

    # 编排吉他音符 (Em 和弦: 低音 E2 + 高音分解 E4, G4, B4, E5)
    t = 0.0
    em_pattern = [("E2", 110), ("B3", 85), ("E4", 90), ("G4", 95), ("E5", 115), ("G4", 90), ("E4", 90)]
    am_pattern = [("A2", 110), ("C4", 85), ("E4", 90), ("A4", 95), ("C5", 115), ("A4", 90), ("E4", 90)]
    b7_pattern = [("B3", 110), ("D4", 85), ("F4", 90), ("A4", 95), ("B4", 115), ("A4", 90), ("F4", 90)]

    for chord in [em_pattern, am_pattern, b7_pattern, em_pattern]:
        for note, vel in chord:
            guitar_events.append((int(t * FS), note, vel))
            t += 0.28
    
    # 编排钢琴音符 (9.0秒开始)
    t = 9.2
    # 4个和弦乐章: C -> G/B -> Am -> F
    piano_phrases = [
        # C Major 和弦
        [("C3", 110), ("E4", 85), ("G4", 85), ("C5", 115)],
        [("E5", 110)],
        [("D5", 100), ("G4", 80)],
        [("C5", 105)],
        # G Major 和弦
        [("G2", 110), ("D4", 85), ("G4", 85), ("B4", 115)],
        [("D5", 110)],
        [("C5", 100)],
        [("B4", 105)],
        # Am 和弦
        [("A2", 110), ("C4", 85), ("E4", 85), ("A4", 115)],
        [("C5", 110)],
        [("B4", 100)],
        [("A4", 105)],
        # F Major 和弦 -> G7 解决
        [("F2", 110), ("C4", 85), ("F4", 85), ("A4", 115)],
        [("C5", 110)],
        [("D5", 110)],
        [("G4", 115), ("B4", 110), ("D5", 105), ("G5", 120)]
    ]
    for phrase in piano_phrases:
        for note, vel in phrase:
            piano_events.append((int(t * FS), note, vel))
        t += 0.55

    # 编排协奏部分 (18.2秒开始: 吉他弹拨吉他琶音，钢琴弹奏宏大和弦与主音)
    t = 18.2
    for bar in range(4):
        # 吉他琶音
        guitar_events.append((int((t + 0.0) * FS), "E2" if bar % 2 == 0 else "A2", 105))
        guitar_events.append((int((t + 0.25) * FS), "G4", 85))
        guitar_events.append((int((t + 0.5) * FS), "B4", 90))
        guitar_events.append((int((t + 0.75) * FS), "E5", 100))
        guitar_events.append((int((t + 1.0) * FS), "G4", 85))
        guitar_events.append((int((t + 1.25) * FS), "B4", 85))
        guitar_events.append((int((t + 1.5) * FS), "E5", 95))

        # 钢琴和弦重奏与高音旋律
        chord_root = "C3" if bar == 0 else ("G2" if bar == 1 else ("A2" if bar == 2 else "F2"))
        chord_third = "E4" if bar == 0 else ("B3" if bar == 1 else ("C4" if bar == 2 else "A3"))
        chord_fifth = "G4" if bar == 0 else ("D4" if bar == 1 else ("E4" if bar == 2 else "C4"))
        lead_note   = "G5" if bar == 0 else ("D5" if bar == 1 else ("E5" if bar == 2 else "C5"))
        
        piano_events.append((int((t + 0.0) * FS), chord_root, 115))
        piano_events.append((int((t + 0.0) * FS), chord_third, 90))
        piano_events.append((int((t + 0.0) * FS), chord_fifth, 90))
        piano_events.append((int((t + 0.4) * FS), lead_note, 120))
        piano_events.append((int((t + 1.0) * FS), lead_note, 110))
        t += 1.8

    # 转换为查找字典加速
    g_event_dict = {}
    for smp, note, vel in guitar_events:
        g_event_dict.setdefault(smp, []).append((note, vel))

    p_event_dict = {}
    for smp, note, vel in piano_events:
        p_event_dict.setdefault(smp, []).append((note, vel))

    g_string_rr = 0
    p_voice_rr = 0

    for n in range(TOTAL_SAMPLES):
        # 触发吉他事件
        if n in g_event_dict:
            for note, vel in g_event_dict[n]:
                guitar_strings[g_string_rr].pluck(get_freq(note), velocity=vel, decay=0.995)
                g_string_rr = (g_string_rr + 1) % len(guitar_strings)

        # 触发钢琴事件
        if n in p_event_dict:
            for note, vel in p_event_dict[n]:
                piano_voices[p_voice_rr].trigger(get_freq(note), velocity=vel)
                p_voice_rr = (p_voice_rr + 1) % len(piano_voices)

        # 累加吉他所有弦的振动
        g_sum = 0
        for s in guitar_strings:
            g_sum += s.step()

        # 累加钢琴所有声部的发声
        p_sum = 0
        for v in piano_voices:
            p_sum += v.step()

        # 声相混音 (吉他偏左 30%，钢琴偏右 30%，增强双乐器空间立体感)
        mix_l = int(g_sum * 0.9 + p_sum * 0.5)
        mix_r = int(g_sum * 0.5 + p_sum * 0.9)

        # 空间轻度混响反射
        del_l = dly_buf_l[dly_idx_l]
        del_r = dly_buf_r[dly_idx_r]
        dly_buf_l[dly_idx_l] = mix_l
        dly_buf_r[dly_idx_r] = mix_r
        dly_idx_l = (dly_idx_l + 1) % len(dly_buf_l)
        dly_idx_r = (dly_idx_r + 1) % len(dly_buf_r)

        wet_l = int(mix_l * 0.85 + del_r * 0.20)
        wet_r = int(mix_r * 0.85 + del_l * 0.20)

        # 饱和限幅
        sat_l = max(-32768, min(32767, wet_l))
        sat_r = max(-32768, min(32767, wet_r))

        out_l.append(sat_l)
        out_r.append(sat_r)

    # 写入 WAV 文件
    out_dir = os.path.join(BASE_DIR, "..", "临时音频")
    os.makedirs(out_dir, exist_ok=True)
    out_wav_path = os.path.join(out_dir, "fpga_piano_guitar_demo.wav")
    print(f"[Sim] 正在导出高质量音频文件: {out_wav_path} ...")
    with wave.open(out_wav_path, "wb") as wf:
        wf.setnchannels(2)
        wf.setsampwidth(2)
        wf.setframerate(FS)
        frames = bytearray()
        for l, r in zip(out_l, out_r):
            frames.extend(struct.pack("<hh", l, r))
        wf.writeframes(frames)

    print(f"[OK] 钢琴与吉他仿真音频生成成功！已保存至: {os.path.abspath(out_wav_path)}")
    print(f"     采样率: {FS}Hz | 双声道立体声 | 时长: {TOTAL_DURATION}秒")

if __name__ == "__main__":
    generate_performance()
