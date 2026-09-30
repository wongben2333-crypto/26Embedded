# synthsim 接口契约（CONTRACT.md）—— 冻结版

> 本文件是并行开发的**唯一接口真相**。任何模块实现必须严格匹配下面的签名。
> `params.py` 已被冻结，**禁止修改**（如需新增字段，在各自模块内定义常量，不要动它）。

## 0. 环境与通用约定（所有模块必须遵守）

- Python **3.8.4**；numpy **1.22.3**；scipy **1.10.1**；matplotlib **3.7.5**。
- 每个模块文件首行加 `from __future__ import annotations`。
- **禁止**使用 Python 3.9+ 语法：`list[int]`、`X | Y`、`match`、`functools.cache`、`str.removeprefix`。
  - 类型注解用 `typing.List/Optional/Sequence/Dict`。
- 音频数组统一约定：
  - **浮点音频** `np.ndarray`, `dtype=float64`, 范围 `[-1.0, 1.0]`，shape `(n,)` 单声道。
  - **波表 / 定点音频** 用 `np.ndarray`, `dtype=int64`，有符号。
- 所有模块可独立 `python -m synthsim.<mod>` 自测（`if __name__ == "__main__":` 里跑一个自检并 print 结果）。
- **禁止联网、禁止 pip install**；只用已装库。
- 绘图：`import matplotlib; matplotlib.use("Agg")`，**图内文字一律英文**（避免中文字形缺失乱码）。
- 输出文件一律写到 `E:\26Embedded\sim\out\`（模块内不要硬编码其它路径）。
- 只创建/修改**自己负责的文件**，不要碰别的模块、不要动 `params.py`。

## 1. params.py（已冻结）

```python
@dataclass
class SynthParams:
    sr: int = 48000
    master_clk_hz: int = 100_000_000
    phase_bits: int = 32
    table_size: int = 1024
    table_bits: int = 16
    interp: str = "linear"          # "none" | "linear"
    env_bits: int = 16
    adsr_attack_ms: float = 5.0
    adsr_decay_ms: float = 120.0
    adsr_sustain: float = 0.70
    adsr_release_ms: float = 180.0
    adsr_curve: str = "exp"
    max_voices: int = 32
    voice_gain_shift: int = 5
    saturate: bool = True
    mip_octaves: int = 8
    base_max_harmonics: int = 512
    i2s_fifo_depth: int = 4
    scan_block: int = 1
    test_tones: int = 32
    test_f0_hz: float = 200.0
    test_spacing_hz: float = 200.0
    test_seconds: float = 2.0
    # 属性: nyquist -> sr/2 ; 方法: freq_word(freq_hz)->int, with_sr(sr)->SynthParams

PARAMS_48K = SynthParams(sr=48000)
PARAMS_96K = SynthParams(sr=96000)
DEVICE = {"name":..., "lut":138240, "ff":138240, "dsp":298, "bsram_kb":6120, "pll":12}
```

---

## 2. 振荡器族（Oscillator group）

### wavetable.py
```python
def generate_sine(table_size: int, table_bits: int) -> np.ndarray:
    """单周期正弦，int64，满幅 = 2**(table_bits-1)-1。"""

def generate_bandlimited(kind: str, table_size: int, table_bits: int,
                         max_harmonics: int) -> np.ndarray:
    """kind in {"saw","square","triangle"}；用累加谐波(1/k 或奇次 1/k)带限合成，
    只保留 k<=max_harmonics 的分量，结果归一化到满幅附近后量化成 int64。"""

def build_mipmap(kind: str, table_size: int, table_bits: int,
                 mip_octaves: int, base_max_harmonics: int) -> List[np.ndarray]:
    """返回 mip_octaves 张表，第 k 张的 max_harmonics = max(1, base_max_harmonics>>k)。
    用于按音区选表抗混叠（高音用谐波更少的表）。"""

def select_mip(freq_hz: float, sr: int, mip_octaves: int,
               base_max_harmonics: int) -> int:
    """给定基频，返回应使用的 mip 层号 [0, mip_octaves-1]（越高音层号越大）。
    取满足 max(1, base_max_harmonics>>k)*freq < sr/2 的最小 k，否则 mip_octaves-1。"""

def write_mem(tables: List[np.ndarray], path: str, table_bits: int,
              table_size: int, name: str) -> None:
    """把多张表依次写成扁平 .mem（每行一个十六进制有符号补码值），
    文件头加注释说明层数/每层长度/位宽。"""
```

### dds.py
```python
def freq_to_word(freq_hz: float, sr: int, phase_bits: int) -> int: ...
def midi_to_freq(note: int) -> float: ...          # 69 -> 440.0
def phase_sequence(freq_word: int, n: int, phase_bits: int) -> np.ndarray:
    """返回每个样本**步进前**的相位值(int64)，用于定点对齐，便于 RTL 复现。"""

def lookup(table: np.ndarray, phase: np.ndarray, phase_bits: int,
           interp: str) -> np.ndarray:
    """interp=="none": idx = phase >> (phase_bits - log2(table_size))
       interp=="linear": 在相邻两表项间线性插值（用整数运算模拟 RTL，可用浮点中间量）。
       返回 int64（"none"）或 float64 波形样本（"linear" 归一化后 [-1,1]）。"""

class DDSOsc:
    def __init__(self, table: np.ndarray, sr: int, phase_bits: int,
                 table_bits: int, interp: str = "linear"): ...
    def set_freq(self, freq_hz: float) -> None: ...
    def set_table(self, table: np.ndarray) -> None: ...
    def step(self, n: int) -> np.ndarray:   # float64 in [-1,1]
```

### additive.py
```python
def additive(freq_hz: float, n: int, sr: int,
             amplitudes: Sequence[float],
             phases: Optional[Sequence[float]] = None) -> np.ndarray:
    """len(k) 个正弦分量叠加，第 k 分量频率 = (k+1)*freq_hz，逐样本 float64 [-1,1]。
    自动归一化，避免削波。"""

def additive_voice_bank(freq_hz: float, n: int, sr: int,
                        n_partials: int = 32) -> np.ndarray:
    """默认 1/k 谐波包络的 32 分量加法音色（拓展①路径B 用）。"""
```

### fm.py
```python
def fm(freq_hz: float, n: int, sr: int, mod_ratio: float = 1.0,
       mod_index: float = 1.0, carrier_harmonic: float = 1.0) -> np.ndarray:
    """2-operator FM，逐样本 float64 [-1,1]。"""

def fm_stack(freq_hz: float, n: int, sr: int,
             ratios: Sequence[float], indices: Sequence[float]) -> np.ndarray:
    """多算子串联 FM（ratios/indices 长度 = 算子数），逐样本 float64 [-1,1]。"""
```

### karplus.py
```python
def karplus_strong(freq_hz: float, n: int, sr: int, decay: float = 0.996,
                   excitation: str = "noise", seed: int = 0) -> np.ndarray:
    """经典 Karplus-Strong 拨弦：延迟线长度 ~ sr/freq，噪声/脉冲激励，
    环内一阶低通 + decay 衰减。返回 float64 [-1,1]。"""
```

---

## 3. 声部链（Voice chain group）

### adsr.py
```python
def adsr_envelope(n: int, sr: int, attack_ms: float, decay_ms: float,
                  sustain: float, release_ms: float,
                  note_off_sample: Optional[int] = None,
                  curve: str = "exp") -> np.ndarray:
    """一次性生成整段 ADSR（[0,1] float64）；note_off_sample=None 表示不释放。"""

class ADSREnv:
    def __init__(self, sr: int, attack_ms: float, decay_ms: float,
                 sustain: float, release_ms: float,
                 env_bits: int = 16, curve: str = "exp"): ...
    def note_on(self, velocity: float = 1.0) -> None: ...
    def note_off(self) -> None: ...
    def step(self, n: int) -> np.ndarray:     # float64 [0,1]，n 个样本
    @property
    def active(self) -> bool: ...
    @property
    def level(self) -> float: ...             # 当前包络电平（供 weakest 抢占策略）
```

### voice.py
```python
class Voice:
    def __init__(self, table: np.ndarray, params: "SynthParams",
                 curve: str = "exp"): ...
    def note_on(self, freq_hz: float, velocity: float = 1.0) -> None: ...
    def note_off(self) -> None: ...
    def step(self, n: int) -> np.ndarray:     # float64 [-1,1] = osc * env * velocity
    @property
    def active(self) -> bool: ...
    @property
    def note(self) -> Optional[int]: ...      # 供 note_off/抢占识别，可存 midi note
    @property
    def start_time(self) -> float: ...        # 供 oldest 策略
    @property
    def level(self) -> float: ...             # 供 weakest 策略
```

### allocator.py
```python
class VoiceAllocator:
    def __init__(self, params: "SynthParams", table: np.ndarray,
                 n_voices: Optional[int] = None, policy: str = "oldest"): ...
    def note_on(self, midi_note: int, velocity: float = 1.0) -> int:
        """分配到某声部并返回声部索引。policy in {"oldest","weakest"}。
        声部用尽时按策略抢占。"""
    def note_off(self, midi_note: int) -> None: ...
    def render(self, n: int) -> np.ndarray:   # 混音后 float64 [-1,1]，n 个样本
    def active_count(self) -> int: ...
```

### mixer.py
```python
def mix_sum(signals: Sequence[np.ndarray], shift: int,
            saturate: bool = True) -> np.ndarray:
    """把各声部信号相加；相加前各自 >>shift 提供余量；saturate=True 时硬限幅到 [-1,1]。"""

def soft_clip(x: np.ndarray, drive: float = 1.0) -> np.ndarray: ...
def headroom_dbfs(n_signals: int, shift: int) -> float:
    """估算给定声部数与右移量下最坏情况余量(dBFS)，用于论证不溢出。"""
```

---

## 4. 分析组（Analysis group）

### fixedpoint.py
```python
def quantize(x: np.ndarray, bits: int, signed: bool = True) -> np.ndarray: ...
def snr_db(ref: np.ndarray, test: np.ndarray) -> float: ...
def thd_db(sig: np.ndarray, sr: int, f0: float) -> float: ...
def enob(snr: float) -> float: ...
def sweep_requant(x: np.ndarray, bit_list: Sequence[int]) -> List[Tuple[int, float]]:
    """对 x 逐步低位量化，返回 [(bits, snr_db), ...]，用于画 SNR-bit 曲线。"""
```

### resource_est.py
```python
def estimate_voice(n_voices: int, params: "SynthParams") -> Dict[str, float]:
    """估算单声部与总资源：振荡器(相位累加+查表+插值+包络+乘法)、波表 BSRAM、
    混音加法器、声部分配器 LUT。返回 dict，键含 per_voice_lut/per_voice_dsp/
    total_lut/total_dsp/total_bsram_kb 及占比。"""

def compare_devices(total_lut: float, total_dsp: float,
                    total_bsram_kb: float) -> str:
    """与 DEVICE 对比，返回人类可读的可行性结论字符串。"""
```

### latency.py
```python
def budget(params: "SynthParams") -> List[Tuple[str, float, float]]:
    """全链路延迟预算：[(stage_name, samples, ms), ...]，
    含 传感器扫描/消抖、合成流水线、I2S FIFO、DAC。末尾追加 ("TOTAL", ...)."""

def max_voices_at_sr(sr: int) -> int: ...   # 便于分阶段说明 48k/96k 预算
```

---

## 5. 输出组（Output group）

### effects.py
```python
def delay(x: np.ndarray, sr: int, delay_ms: float, feedback: float,
          mix: float) -> np.ndarray: ...
def chorus(x: np.ndarray, sr: int, depth_ms: float = 3.0, rate_hz: float = 0.6,
           base_ms: float = 20.0, mix: float = 0.5) -> np.ndarray: ...
def reverb_schroeder(x: np.ndarray, sr: int, room: float = 0.7,
                     mix: float = 0.3) -> np.ndarray:
    """4 并联梳状 + 2 串联全通，逐样本 float64 [-1,1]。"""
```

### testmode.py
```python
def synth_test_tones(params: "SynthParams", n_tones: Optional[int] = None,
                     seconds: Optional[float] = None) -> np.ndarray:
    """生成 n_tones 路等间隔频率（f0, f0+spacing, ...）同时发声的测试信号，
    每路一个独立振荡器 + 包络，float64 [-1,1]。"""

def analyze_peaks(x: np.ndarray, sr: int, n_expected: int, f0: float,
                  spacing: float, tol_hz: float = 40.0) -> Dict[str, object]:
    """FFT 找峰，统计落在期望频点 ±tol 内的峰数；返回
    {"detected": int, "expected": int, "ok": bool, "peaks_hz": [...]}。"""

def plot_spectrum(x: np.ndarray, sr: int, path: str, n_expected: int,
                  f0: float, spacing: float) -> None:
    """画 0..(f0+spacing*n_expected+margin) 的幅度谱，(Agg, 英文标签)。
    这是评分规则③「N 个独立谱峰」的现场证据预演图。"""
```

### render.py
```python
def write_wav(path: str, x: np.ndarray, sr: int) -> None:
    """16-bit PCM 单声道 WAV；先做 [-1,1] 限幅与 dither(可选，简单即可)。"""
def load_wav(path: str) -> Tuple[np.ndarray, int]: ...   # 自检用
```

### export_params.py
```python
def export_verilog_header(params: "SynthParams", path: str) -> None:
    """生成 `synth_params.vh`：所有位宽/深度/采样率宏 + 频率字计算说明。"""
def export_wavetables(params: "SynthParams", out_dir: str) -> List[str]:
    """生成 wavetable 的 .mem 文件（调用 wavetable.build_mipmap/write_mem）。"""
```

---

## 6. 集成脚本（scripts/run_all.py —— 由集成阶段统一完成）

必须一次性产出到 `E:\26Embedded\sim\out\`：
- `single_note.wav` / `poly4.wav` / `poly32.wav`（A4=440 与四音和弦、32 音测试）
- `spectrum_single.png` / `spectrum_poly32.png`（含谱峰计数标题）
- `wavetable_mipmap.png`（多层波表时域叠加）
- `adsr.png`（四段包络曲线）
- `fixedpoint_snr.png`（SNR vs 位宽）
- `testmode_32peaks.png` + `testmode_32peaks.wav`（规则③核心证据）
- `synth_params.vh` + `wavetables/*.mem`
- `report.md`：汇总 7 个问题的答案（音高误差 / 抗混叠 / 最小位宽 / 混音余量 / 资源账 / 延迟预算 / 32 峰是否成立），
  并给出 **48k 与 96k 两档**的对比表。

**成功判据**：`python scripts/run_all.py` 退出码 0；`testmode_32peaks` 的 `analyze_peaks` 报 `detected >= 32`。
