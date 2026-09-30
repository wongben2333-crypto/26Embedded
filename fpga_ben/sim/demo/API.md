# 音色演示 Demo —— 接口契约（冻结版）

> 目标：本地浏览器演示「前期算法模拟」的实时合成效果，三种简单音色：**管风琴 organ / 八音盒 musicbox / 电钢琴 epiano**。
> 架构：**Python 后端（复用 `synthsim` 黄金模型）+ 纯静态前端**。后端逐请求渲染一段音频为 WAV，前端解码并用 WebAudio 播放（多音自然叠加成和弦）。
> 环境：Python 3.8.4 / numpy 1.22.3 / scipy 1.10.1。**后端只用标准库 + 已装库，禁止 pip install、禁止联网。**

## 0. 文件分工

| 文件 | 负责人 | 说明 |
|---|---|---|
| `synthsim/instruments.py` | 后端 | 三种音色的合成算法 + 统一的 `render_*` API |
| `demo/server.py` | 后端 | 纯标准库 HTTP 服务（`http.server`），提供页面与音频接口 |
| `demo/index.html` | 前端 | 单文件页面（内联 CSS/JS），无外部 CDN |
| `demo/README.md` | 后端 | 运行说明 |

所有路径基于 `E:\26Embedded\sim\`。运行：`python demo\server.py`（默认端口 8000），浏览器打开 `http://localhost:8000`。

---

## 1. 音色模块 API（`synthsim/instruments.py`）

必须严格实现（供 server 与自检调用）：

```python
# 音色清单（顺序即界面展示顺序）
INSTRUMENTS = [
    {"id": "organ",    "name": "管风琴 Organ",     "desc": "..."},
    {"id": "musicbox", "name": "八音盒 Music Box", "desc": "..."},
    {"id": "epiano",   "name": "电钢琴 E-Piano",   "desc": "..."},
]

def render_note(name: str, freq_hz: float, seconds: float,
                sr: int = 48000, velocity: float = 1.0) -> np.ndarray:
    """渲染单个音，返回 float64 [-1,1]，shape=(int(seconds*sr),)。"""

def render_midi(name: str, midi: int, seconds: float,
                sr: int = 48000, velocity: float = 1.0) -> np.ndarray:
    """按 MIDI 音号渲染（midi_to_freq）。"""

def render_chord(name: str, midis: Sequence[int], seconds: float,
                 sr: int = 48000, velocity: float = 1.0) -> np.ndarray:
    """和弦：各音分别渲染后相加，整体限幅到 [-1,1]。"""
```

**音色定义要求（简单但要能听出来）**
- `organ` 管风琴：稳态谐波叠加（drawbar 近似），如谐波 `[1,2,3,4,6,8]`、幅度 `[1,.7,.5,.35,.2,.12]`；快起音（~5ms）、长保持、~60ms 释放；可加极轻微颤音。
- `musicbox` 八音盒：少量**非谐**分量（如比率 `[1.0, 2.0, 2.76, 5.4, 8.93]`，幅度递减），每分量**指数衰减**且高次衰减更快；起音 ~1ms；总体约 1.2–1.5s 衰减到静音。
- `epiano` 电钢琴：**FM**（优先复用 `synthsim.fm.fm` 或遵循同样结构），载波比率 1.0、调制比率 ≈1.0（可叠一个 14.0 的"tine"亮层），**调制指数随时间快速衰减**；包络为"快起→衰减→较短保持"；可轻叠 `synthsim.effects.chorus` 增厚。

**复用与规范**
- 复用 `synthsim.params`（默认 sr=48000）、`synthsim.dds.midi_to_freq`、`synthsim.fm`、`synthsim.effects`；不要重复造已有的轮子。
- Python 3.8 兼容（`from __future__ import annotations`，typing.List/Sequence，无 3.9+ 语法）。
- 输出一律 float64、[-1,1]、单声道；最终限幅。
- 文件末尾 `if __name__ == "__main__":` 自检：三种音色各渲染 1.0s@48k，打印长度/峰值/RMS、以及**谱峰/基频**（可用 numpy FFT），并断言峰值 ≤ 1.0。自检必须退出码 0。

---

## 2. HTTP 接口（`demo/server.py`）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/` | 返回 `demo/index.html`（`text/html; charset=utf-8`） |
| GET | `/api/instruments` | JSON：`{"ok":true, "instruments": INSTRUMENTS}` |
| GET | `/api/note?instrument=organ&midi=60&velocity=0.8&seconds=1.5` | 返回 **16-bit PCM 单声道 WAV**，`Content-Type: audio/wav` |
| GET | `/api/chord?instrument=organ&midis=60,64,67&velocity=0.8&seconds=1.5` | 和弦 WAV，同上 |
| GET | `/api/health` | `{"ok":true, "sr":48000, "instruments":[...ids...]}` |

**参数与默认值**：`instrument` 默认 `organ`；`midi` 默认 60；`velocity` 默认 0.8（范围 0–1）；`seconds` 默认 1.5（上限 5）；`midis` 逗号分隔 1–16 个。
**错误处理**：未知音色 / 非法参数 → HTTP 400 + JSON `{"ok":false,"error":"..."}`；内部异常 → 500。
**其他**：加 `Access-Control-Allow-Origin: *`；日志打印请求行与耗时；`--port` 命令行参数（默认 8000）；支持 `--open` 用 `webbrowser` 自动打开；WAV 用 `scipy.io.wavfile` 写入内存（`io.BytesIO`）或自写 WAV 头，皆是 float→int16 限幅。
**只允许用**：`http.server`、`urllib.parse`、`json`、`io`、`argparse`、`webbrowser`、`numpy`、`scipy` + 本项目 `synthsim`。**不要引入 Flask/FastAPI 等需安装的框架。**

---

## 3. 前端（`demo/index.html`）

**单文件、离线可用（不得引用任何外部 CDN/字体）。**

**必须包含**
1. **标题区**：说明这是「高云选题二 · 波形合成演示」。
2. **音色选择**：3 个按钮（管风琴 / 八音盒 / 电钢琴），从 `/api/instruments` 拉取，当前音色高亮。
3. **力度滑块**：0–1，实时显示数值。
4. **钢琴键盘**：至少 **2 个八度**（建议 C3–B4，即 MIDI 48–71），可**鼠标点击**与**电脑键盘**（如 `A W S E D F T G Y H U J K`）触发；按下高亮。
5. **发声逻辑**：触发 → `fetch('/api/note?instrument=...&midi=...&velocity=...&seconds=1.5')` → `arrayBuffer` → `AudioContext.decodeAudioData` → `BufferSource.start()`。**允许同时多个音叠加成和弦**。首次交互需 `AudioContext.resume()`。
6. **实时可视化**：`AnalyserNode` → `<canvas>` 画**波形或频谱**（二选一即可），随声音跳动。
7. **状态与延迟**：显示后端返回耗时（`performance.now()` 计 fetch 往返）、最近触发音名（C4/A4…）。
8. **容错**：后端离线时在页面顶部显示醒目提示（例如「后端未启动：请先运行 python demo\server.py」）。

**风格**：深色、现代、干净；CJK 中文标签正常显示；响应式（窄屏不崩）。

---

## 4. 验收判据

1. `python -m synthsim.instruments` 自检退出 0，三种音色峰值 ≤1.0 且频谱合理。
2. `python demo\server.py` 启动无异常；`GET /api/health` 返回 200 JSON。
3. `GET /api/note?instrument=epiano&midi=69&velocity=0.9&seconds=1.5` 返回可播放的 WAV（`audio/wav`，PCM16）。
4. 浏览器打开 `http://localhost:8000`：能选音色、能弹键盘发声、能同时按出和弦、能看可视化。
5. 无 pip 安装、无外部网络依赖。
