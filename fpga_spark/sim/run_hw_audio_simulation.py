"""
==============================================================================
Script: run_hw_audio_simulation.py
Description: 纯硬件 FPGA 综合引擎精确时钟周期级 (Cycle-Accurate) 仿真器
             严格映射 Verilog RTL 硬件电路实现：
             1. 32-bit 相位累加器与 4096点 BSRAM 波表查找
             2. 5状态硬件数字 ADSR 包络发生器状态机
             3. 硬件定点数乘法器与位截断 (raw_wave * env >> 16)
             4. 8路独立声部并发与纯硬件饱和混音器 (Saturating Mixer)
             5. 硬件 LFO 颤音发生器与乐章状态机
             
             最终生成 48kHz 16-bit 高保真立体声 WAV 文件供试听验证！
==============================================================================
"""

import os
import struct
import wave
import math

TABLE_SIZE = 4096
FS = 48000       # 48kHz 音频采样率
DURATION = 16.0  # 仿真生成 16 秒完整演奏乐章
TOTAL_SAMPLES = int(FS * DURATION)

# 1. 加载与 Verilog 完全一致的片上 BSRAM 波表
def load_hex_table(filename):
    data = []
    with open(filename, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            val = int(line, 16)
            if val >= 32768:
                val -= 65536
            data.append(val)
    return data

BASE_DIR = os.path.dirname(__file__)
WAVE_DIR = os.path.join(BASE_DIR, "..", "rtl", "synth_core", "dds_wavetable")

print("正在装载与 FPGA BSRAM 一致的 16-bit 波表数据...")
ROM_SINE = load_hex_table(os.path.join(WAVE_DIR, "wavetable_sine.hex"))
ROM_SAW  = load_hex_table(os.path.join(WAVE_DIR, "wavetable_saw.hex"))
ROM_TRI  = load_hex_table(os.path.join(WAVE_DIR, "wavetable_tri.hex"))
ROM_SQR  = load_hex_table(os.path.join(WAVE_DIR, "wavetable_sqr.hex"))
ROM_TABLES = [ROM_SINE, ROM_SAW, ROM_TRI, ROM_SQR]

# 2. 硬件 ADSR 仿真类 (严格对应 adsr_envelope.v)
class HwAdsrEnvelope:
    IDLE = 0
    ATTACK = 1
    DECAY = 2
    SUSTAIN = 3
    RELEASE = 4

    def __init__(self, attack_rate=800, decay_rate=120, sustain_level=38000, release_rate=200):
        self.state = self.IDLE
        self.env_out = 0
        self.attack_rate = attack_rate
        self.decay_rate = decay_rate
        self.sustain_level = sustain_level
        self.release_rate = release_rate

    def step(self, gate):
        # 状态转移
        if self.state == self.IDLE:
            if gate:
                self.state = self.ATTACK
        elif self.state == self.ATTACK:
            if not gate:
                self.state = self.RELEASE
            elif self.env_out >= 65535 - self.attack_rate:
                self.state = self.DECAY
        elif self.state == self.DECAY:
            if not gate:
                self.state = self.RELEASE
            elif self.env_out <= self.sustain_level or self.env_out <= self.decay_rate:
                self.state = self.SUSTAIN
        elif self.state == self.SUSTAIN:
            if not gate:
                self.state = self.RELEASE
        elif self.state == self.RELEASE:
            if gate:
                self.state = self.ATTACK
            elif self.env_out <= self.release_rate:
                self.state = self.IDLE

        # 包络计算 (逐周期定点累加)
        if self.state == self.IDLE:
            self.env_out = 0
        elif self.state == self.ATTACK:
            self.env_out = min(65535, self.env_out + self.attack_rate)
        elif self.state == self.DECAY:
            if self.env_out <= self.sustain_level + self.decay_rate:
                self.env_out = self.sustain_level
            else:
                self.env_out -= self.decay_rate
        elif self.state == self.SUSTAIN:
            self.env_out = self.sustain_level
        elif self.state == self.RELEASE:
            if self.env_out <= self.release_rate:
                self.env_out = 0
            else:
                self.env_out -= self.release_rate

        return self.env_out

# 3. 单个独立物理发声单元 (严格对应 voice_unit.v)
class HwVoiceUnit:
    def __init__(self, attack_rate=800, decay_rate=120, sustain_level=38000, release_rate=200):
        self.phase_acc = 0
        self.adsr = HwAdsrEnvelope(attack_rate, decay_rate, sustain_level, release_rate)

    def step(self, gate, freq_step, freq_mod, wave_sel, velocity):
        # 1. 相位累加器 (32位模运算)
        eff_step = (freq_step + freq_mod) & 0xFFFFFFFF
        self.phase_acc = (self.phase_acc + eff_step) & 0xFFFFFFFF

        # 2. 查表地址 (高 12 位)
        lut_addr = (self.phase_acc >> 20) & 0xFFF
        raw_wave = ROM_TABLES[wave_sel][lut_addr]

        # 3. 硬件 ADSR 包络计算
        env_gain = self.adsr.step(gate)

        # 4. 硬件定点数乘法器级联
        # Step 1: 乘以包络 (16-bit signed * 16-bit unsigned >> 16)
        env_scaled = (raw_wave * env_gain) >> 16

        # Step 2: 乘以力度系数 (0~127 映射为 64~127)
        vel_gain = 0 if velocity == 0 else (64 + (velocity >> 1))
        sample_out = (env_scaled * vel_gain) >> 7

        return max(-32768, min(32767, sample_out))

# 4. 频率控制字计算函数
def note_to_step(freq):
    return int(round(freq * (1 << 32) / FS))

FREQ_C2 = 65.41
FREQ_G2 = 98.00
FREQ_A2 = 110.00
FREQ_F2 = 87.31

FREQ_C4 = 261.63
FREQ_D4 = 293.66
FREQ_E4 = 329.63
FREQ_F4 = 349.23
FREQ_G4 = 392.00
FREQ_A4 = 440.00
FREQ_B4 = 493.88
FREQ_C5 = 523.25
FREQ_D5 = 587.33
FREQ_E5 = 659.25
FREQ_G5 = 783.99

STEP_C2 = note_to_step(FREQ_C2)
STEP_G2 = note_to_step(FREQ_G2)
STEP_A2 = note_to_step(FREQ_A2)
STEP_F2 = note_to_step(FREQ_F2)

STEP_C4 = note_to_step(FREQ_C4)
STEP_D4 = note_to_step(FREQ_D4)
STEP_E4 = note_to_step(FREQ_E4)
STEP_F4 = note_to_step(FREQ_F4)
STEP_G4 = note_to_step(FREQ_G4)
STEP_A4 = note_to_step(FREQ_A4)
STEP_B4 = note_to_step(FREQ_B4)
STEP_C5 = note_to_step(FREQ_C5)
STEP_D5 = note_to_step(FREQ_D5)
STEP_E5 = note_to_step(FREQ_E5)
STEP_G5 = note_to_step(FREQ_G5)

def run_simulation():
    print(f"正在进行 FPGA 硬件音频引擎逐样本仿真 (采样率: {FS}Hz, 总时长: {DURATION}秒)...")
    
    # 实例化 8 个硬件声部
    voices = [
        HwVoiceUnit(attack_rate=400, decay_rate=80, sustain_level=55000, release_rate=200),  # Voice 0: Bass
        HwVoiceUnit(attack_rate=600, decay_rate=120, sustain_level=36000, release_rate=300), # Voice 1: Chord Root
        HwVoiceUnit(attack_rate=600, decay_rate=120, sustain_level=36000, release_rate=300), # Voice 2: Chord Third
        HwVoiceUnit(attack_rate=600, decay_rate=120, sustain_level=36000, release_rate=300), # Voice 3: Chord Fifth
        HwVoiceUnit(attack_rate=300, decay_rate=200, sustain_level=42000, release_rate=500), # Voice 4: Melody Lead
        HwVoiceUnit(attack_rate=300, decay_rate=200, sustain_level=42000, release_rate=500), # Voice 5: Arpeggio
        HwVoiceUnit(attack_rate=300, decay_rate=200, sustain_level=42000, release_rate=500), # Voice 6: Spare
        HwVoiceUnit(attack_rate=300, decay_rate=200, sustain_level=42000, release_rate=500), # Voice 7: Spare
    ]

    out_pcm_left = []
    out_pcm_right = []

    # 简易简单混响梳状滤波器与空间反射延迟缓冲 (纯硬件拓扑)
    rev_buf_l = [0] * 1800
    rev_buf_r = [0] * 2250
    rev_idx_l = 0
    rev_idx_r = 0

    beat_len = int(FS * 0.25) # 16分音符长度 = 0.25s (120 BPM)

    for n in range(TOTAL_SAMPLES):
        step_idx = n // beat_len
        measure_4 = (step_idx // 16) % 4  # 4小节和弦循环 (C -> G -> Am -> F)
        sub_step = step_idx % 16

        # 硬件 LFO 颤音 (5.5Hz 调制主旋律)
        lfo_phase = (n * 5.5 / FS) * 2 * math.pi
        vibrato_mod = int(math.sin(lfo_phase) * 60000)

        # 声部控制参数
        gates = [0] * 8
        freq_steps = [0] * 8
        wave_sels = [0] * 8
        velocities = [0] * 8

        # 和弦与贝斯配置
        if measure_4 == 0:  # C Major (C - E - G)
            freq_steps[0] = STEP_C2; wave_sels[0] = 2; velocities[0] = 115 # Triangle Bass
            freq_steps[1] = STEP_C4; wave_sels[1] = 0; velocities[1] = 85  # Sine Chord
            freq_steps[2] = STEP_E4; wave_sels[2] = 0; velocities[2] = 80
            freq_steps[3] = STEP_G4; wave_sels[3] = 0; velocities[3] = 80
        elif measure_4 == 1: # G Major (G - B - D)
            freq_steps[0] = STEP_G2; wave_sels[0] = 2; velocities[0] = 115
            freq_steps[1] = STEP_G4; wave_sels[1] = 1; velocities[1] = 85  # Sawtooth Chord
            freq_steps[2] = STEP_B4; wave_sels[2] = 1; velocities[2] = 80
            freq_steps[3] = STEP_D5; wave_sels[3] = 1; velocities[3] = 80
        elif measure_4 == 2: # A Minor (A - C - E)
            freq_steps[0] = STEP_A2; wave_sels[0] = 2; velocities[0] = 115
            freq_steps[1] = STEP_A4; wave_sels[1] = 0; velocities[1] = 85
            freq_steps[2] = STEP_C5; wave_sels[2] = 0; velocities[2] = 80
            freq_steps[3] = STEP_E5; wave_sels[3] = 0; velocities[3] = 80
        else:                # F Major (F - A - C)
            freq_steps[0] = STEP_F2; wave_sels[0] = 2; velocities[0] = 115
            freq_steps[1] = STEP_F4; wave_sels[1] = 3; velocities[1] = 85  # Square Chord
            freq_steps[2] = STEP_A4; wave_sels[2] = 3; velocities[2] = 80
            freq_steps[3] = STEP_C5; wave_sels[3] = 3; velocities[3] = 80

        # 和弦与贝斯保持持续发声 (仅在第15小拍短暂断音断连)
        gate_chord = 1 if (sub_step != 15) else 0
        gates[0] = gate_chord
        gates[1] = gate_chord
        gates[2] = gate_chord
        gates[3] = gate_chord

        # 声部 4: 主旋律 (Sawtooth + 颤音)
        lead_melody_notes = [
            STEP_C5, STEP_E5, STEP_G5, STEP_E5, 
            STEP_D5, STEP_G4, STEP_B4, STEP_C5,
            STEP_E5, STEP_G5, STEP_A4, STEP_C5,
            STEP_F4, STEP_A4, STEP_C5, STEP_E5
        ]
        freq_steps[4] = lead_melody_notes[sub_step]
        wave_sels[4] = 1  # 锯齿波 Lead
        velocities[4] = 120
        gates[4] = 1 if ((n % beat_len) < int(beat_len * 0.82)) else 0 # 留出释放空隙

        # 声部 5: 快速 8 分音符琶音 (Triangle / Sine)
        arp_notes = [STEP_C4, STEP_G4, STEP_C5, STEP_G4]
        freq_steps[5] = arp_notes[(sub_step * 2) % 4]
        wave_sels[5] = 2  # 三角波琶音
        velocities[5] = 75
        gates[5] = 1 if ((n % (beat_len // 2)) < int((beat_len // 2) * 0.75)) else 0

        # 执行各声部计算
        v0 = voices[0].step(gates[0], freq_steps[0], 0, wave_sels[0], velocities[0])
        v1 = voices[1].step(gates[1], freq_steps[1], 0, wave_sels[1], velocities[1])
        v2 = voices[2].step(gates[2], freq_steps[2], 0, wave_sels[2], velocities[2])
        v3 = voices[3].step(gates[3], freq_steps[3], 0, wave_sels[3], velocities[3])
        v4 = voices[4].step(gates[4], freq_steps[4], vibrato_mod, wave_sels[4], velocities[4])
        v5 = voices[5].step(gates[5], freq_steps[5], 0, wave_sels[5], velocities[5])

        # 硬件多路立体声混音器 (带声相位置空间分配)
        mix_raw_l = int(v0 * 0.8 + v1 * 0.7 + v2 * 0.4 + v4 * 0.85 + v5 * 0.6)
        mix_raw_r = int(v0 * 0.8 + v2 * 0.4 + v3 * 0.7 + v4 * 0.85 + v5 * 0.4)

        # 纯硬件空间延迟与混响反馈 (Schroeder Delay Network 近似)
        delayed_l = rev_buf_l[rev_idx_l]
        delayed_r = rev_buf_r[rev_idx_r]
        rev_buf_l[rev_idx_l] = max(-32768, min(32767, int(mix_raw_l + delayed_l * 0.35)))
        rev_buf_r[rev_idx_r] = max(-32768, min(32767, int(mix_raw_r + delayed_r * 0.35)))
        rev_idx_l = (rev_idx_l + 1) % len(rev_buf_l)
        rev_idx_r = (rev_idx_r + 1) % len(rev_buf_r)

        wet_mix_l = int(mix_raw_l * 0.85 + delayed_r * 0.22)
        wet_mix_r = int(mix_raw_r * 0.85 + delayed_l * 0.22)

        # 硬件饱和限制器 (Saturator)
        sat_l = max(-32768, min(32767, wet_mix_l))
        sat_r = max(-32768, min(32767, wet_mix_r))

        out_pcm_left.append(sat_l)
        out_pcm_right.append(sat_r)

    # 导出为 16-bit 48kHz 标准立体声 WAV 文件
    out_dir = os.path.join(BASE_DIR, "..", "临时音频")
    os.makedirs(out_dir, exist_ok=True)
    out_wav_path = os.path.join(out_dir, "fpga_synth_demo.wav")
    print(f"正在写入 WAV 音频文件: {out_wav_path} ...")
    with wave.open(out_wav_path, "wb") as wf:
        wf.setnchannels(2)      # 双声道立体声
        wf.setsampwidth(2)      # 16-bit (2字节)
        wf.setframerate(FS)     # 48000 Hz
        
        frames = bytearray()
        for l, r in zip(out_pcm_left, out_pcm_right):
            frames.extend(struct.pack("<hh", l, r))
        wf.writeframes(frames)

    print(f"[OK] Audio generated successfully! Saved to: {os.path.abspath(out_wav_path)}")
    print(f"     Sample Rate: {FS}Hz | Channels: Stereo | Bit Depth: 16-bit PCM | Duration: {DURATION}s")

if __name__ == "__main__":
    run_simulation()
