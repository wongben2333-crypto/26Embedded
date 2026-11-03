# host/ —— 电脑当简易钢琴弹 FPGA

> 用户需求：**鼠标点琴键 / 电脑键盘按键 → 板子（耳机孔）发声**，做一个简易钢琴。

## 数据流

```
 鼠标 / 电脑键盘
        │  (tkinter 事件)
        ▼
   piano_gui.py ──串口 115200 8N1──► FT2232H ──UART──► FPGA
                                                        │
                                     uart_rx.v ──byte──► midi_rx.v ──note/vel──► 合成器
                                                                                │
                                                                          PT8211 I2S
                                                                                │
                                                                            耳机孔 🔊
```

## 运行环境（本机实测，可直接写进交付说明）

| 项 | 值 |
|---|---|
| Python | **3.14.5（64 bit）** |
| Tk / Tcl | **8.6 / 8.6**（`tkinter` 是标准库自带，**不需要 pip 安装**） |
| 第三方包 | **只有 `pyserial`，版本 3.5**（`serial.VERSION = 3.5`） |
| 解释器路径 | `fpga_hank\_tools\venv\Scripts\python.exe` |
| 安装命令 | `fpga_hank\_tools\venv\Scripts\python.exe -m pip install pyserial` |

> 兼容性：代码只用标准库 `tkinter`/`argparse`/`atexit`/`threading` + `pyserial`，
> 没有用到 3.14 专有语法之外的特性；**Python 3.8+ 理论上都能跑**（未逐一实测）。

## 快速开始

```powershell
# 1) 依赖：tkinter 自带；只缺 pyserial
fpga_hank\_tools\venv\Scripts\python.exe -m pip install pyserial

# 2) 看有哪些串口（板子插好后）
fpga_hank\_tools\venv\Scripts\python.exe host\piano_gui.py --list-ports

# 3) 打开钢琴界面
fpga_hank\_tools\venv\Scripts\python.exe host\piano_gui.py
#    指定串口：
fpga_hank\_tools\venv\Scripts\python.exe host\piano_gui.py --port COM8
```

**界面用法**（全中文）：
1. 顶部**串口下拉框**里选 `COM8` 或 `COM9`（哪个是 FPGA 串口见下文"接线"），点**连接**；
2. **鼠标点琴键**发声；**电脑键盘**也能弹（下表）；**松手即停音**；
3. **力度**滑块（1..127）、**八度** Z / X 切换；
4. **`全部停止` 按钮**（顶部一个、调试行一个）/ 关闭窗口 / 窗口失焦 → 都发 **All Notes Off**（不会留挂音）；
5. **调试发送（十六进制）**输入框 + `发送` 按钮 —— **上板联调第一步就用它**：
   输入 `90 45 64` 回车 → 板子应发 A4(440 Hz) 音；`80 45 00` → 停音；`B0 7B 00` → 全部停。
   解析很宽容：`90 45 64`、`0x90,0x45,0x64`、`904564`（连写）、`b0 7b 00`（小写）都行；
   非法输入会红字提示原因，**不会**发出半个字节。旁边还有 `A4 开` / `A4 关` 两个预设按钮。
   > ⚠️ 调试发送**绕过**"正在发声"跟踪（它就是用来发任意字节的）；但 `全部停止`/关窗仍会先发 All Notes Off，一键清干净。
6. **表情维度（赛题拓展②）**：**滑音时间**滑块 + `滑音开关`、**颤音深度**滑块 + `颤音开关`、
   **颤音速度**滑块、**延音踏板**按钮（也可按电脑**空格键**切换）。
   参数通过 **Control Change** 下发，编号与约定见下文「表情维度与 CC 协议」。
   > ⚠️ 这些 CC **需要 RTL 侧解析**才能听到效果；未实现时会被静默忽略，**不影响**原来的发声功能。

| 电脑键盘 | 音 | 电脑键盘 | 音 |
|---|---|---|---|
| `A S D F G H J` | C4 D4 E4 F4 G4 A4 B4 | `W E T Y U` | C#4 D#4 F#4 G#4 A#4 |
| `K L ;` | C5 D5 E5 | `O P` | C#5 D#5 |
| `Z` / `X` | 降/升八度 | `Esc` | 停止并退出 |

## 上板联调步骤（照着做就行，不熟电脑也能做）

> **前提**：Lead 已把 `uart_rx.v`/`midi_rx.v` 集成进 `top.v`，并烧好**电脑控制模式**的位流
> （含串口音符通路）。板子用 USB 连电脑，耳机插**板载 3.5 mm 口**。
> （具体模式参数名/位流名以 Lead 集成为准 —— 电脑端这一侧由我负责。）

| 步骤 | 做什么 | 应该看到 / 听到 | 不对怎么办 |
|---|---|---|---|
| 1 | 确认**位流已烧录**、且处于**电脑控制模式** | 板上 LED 有心跳变化 | 本步不做软件操作；不对就找 Lead 重烧 |
| 2 | 打开界面：`fpga_hank\_tools\venv\Scripts\python.exe host\piano_gui.py` | 出现中文界面（串口下拉 + 琴键） | 报错→见"疑难排查"；确认用的是 `_tools\venv` 里的 python |
| 3 | 在下拉框选 **COM8**；看不清就点**刷新** | 下拉里有 `COM8 \| USB Serial Port` 和 `COM9` | 没有→点"刷新"；仍没有→USB 没插好 |
| 4 | 点**连接** | 状态变绿：`已连接 COM8 @ 115200` | 报"打不开"→该口被占用，改选 **COM9** 再连接 |
| 5 | **先用调试框发 `90 45 64`**（默认已填好，直接回车） | **耳机里听到 A4 = 440 Hz 的持续音** | 没声音→①换另一个口重试（COM8↔COM9）②查耳机 ③见下方三步定位 |
| 6 | 调试框发 `80 45 00`（或点 `A4 关`） | **声音立刻停** | 不停→点「全部停止」 |
| 7 | **鼠标点琴键** | 点哪个响哪个，松开就停 | 同上 |
| 8 | **按电脑键盘** `A S D F G H J` / `W E T Y U` | 每键一个音，按住持续响 | 没反应→先点一下窗口（让它获得焦点）；输入法切英文 |
| 9 | 按 `Z` / `X` 换八度 | 琴键上的音名跟着变 | — |
| 10 | 收工：关窗口，或点「全部停止」 | 声音停止，界面关闭 | 若仍挂音→重开界面点「全部停止」 |
| 11 | **（可选）验证表情 CC**：拉**滑音时间**到 ~25 并勾 `滑音开关`，连弹两个不同音 | 后一个音的音高**平滑滑过去** | 没变化→RTL 还没实现 CC5/65（属正常，见"表情维度"一节） |
| 12 | **（可选）验证踏板**：按**空格**开延音，弹一下松手 | 声音**继续延音**不立刻消失；再按空格抬踏板 → 音放掉 | 没变化→RTL 未实现 CC64；此时"松手即停"仍是正常行为 |

**"没声音"三步定位（按顺序做，别跳）**

1. **先确认串口对不对**：COM8 和 COM9 **各试一次**发 `90 45 64`。换到某个口就响了 ⇒ 那个通道就是 FPGA UART。
2. **再确认板子对不对**：跑一次
   `python _research\pc-link\watch_serial.py --seconds 10`
   （同时听两个口）—— 若**两个口都没数据**，说明位流没在发心跳 / 没在电脑控制模式 ⇒ 找 Lead。
3. **最后确认音高**：A4 应是 **440 Hz**。用手机调音器 App，或仓库里的 `tools/verify/record_audio.py` 验证。

**挂音怎么办**：点「全部停止」（发 `B0 7B 00`）。
另外 **切八度 / 关窗口 / 窗口失焦 / 断开连接** 都会自动清音，正常不会挂。

> 📌 联调小工具：[`_research/pc-link/watch_serial.py`](<_research/pc-link/watch_serial.py>)
> 可**同时监听 COM8+COM9**、毫秒时间戳、HEX+ASCII 双显示、自动判断"哪个通道是 FPGA UART"。
> 例：`python _research\pc-link\watch_serial.py --seconds 15 --send-on both`
> （心跳默认匹配 ASCII **`HANK`**，**每 1 秒发一次** ⇒ 至少听 3 秒；
> `--send-on both` 会让两个口各发一次探测字节 `90 45 64`，看哪个口被原样回显。）

## 协议（与 RTL 严格一致，双方都不要改）

| 含义 | 字节 | 说明 |
|---|---|---|
| NoteOn | `0x90 note vel` | **vel = 0 视为 NoteOff** |
| NoteOff | `0x80 note 0` | |
| All Notes Off | `0xB0 0x7B 0x00` | CC123（**原有能力，不变**） |
| 参数 | 115200 8N1；note 0..127；**A4 = 69 = 440 Hz** | |

### 表情维度与 CC 协议（新增，向后兼容）

**新增只走 Control Change（`0xB0 <cc> <value>`），完全不动原有三条消息** ——
所以即使 RTL 还没实现这些 CC，原有的弹奏/停音/全停**不受影响**（未知 CC 被忽略）。

| 表情维度 | CC | 值域 | 约定（数值→物理量） | 界面控件 |
|---|---|---|---|---|
| 滑音时间 | **5** | 0..127 | `t_glide ≈ v × 4 ms`（0 = 关；25 → 100 ms；127 → 508 ms） | 滑音时间滑块 |
| 滑音开关 | **65** | 0 / 127 | ≤63 关，≥64 开 | 滑音开关 |
| 颤音深度 | **1**（同时发 **77**） | 0..127 | 深度比例，0 = 关 | 颤音深度滑块 |
| 颤音速度 | **76** | 0..127 | `f_lfo ≈ v × 0.1 Hz`（50 → 5.0 Hz；127 → 12.7 Hz） | 颤音速度滑块 |
| 延音踏板 | **64** | 0 / 127 | ≤63 关，≥64 开 | 延音踏板按钮 / **空格** |
| 全部停止（升级） | 64→0, 123, 120, 121 | — | 见下 | 「全部停止」按钮 |

> ⚠️ **两个线性映射（`v×4 ms`、`v×0.1 Hz`）是规范没定义、由我们两边约定的** ——
> **RTL 必须按同一约定实现**，否则滑块上的 "50" 在一侧是 5.0 Hz、另一侧可能是别的值。
> 要改就改 `piano_gui.py` 顶部的 `GLIDE_MS_PER_STEP` / `VIB_HZ_PER_STEP` **并同步本文**。

**「全部停止」为什么是五连发**：`CC64=0`（先抬踏板，否则踩着踏板时可能清不干净）→
`CC123 All Notes Off` → 逐个 `NoteOff` → `CC120 All Sound Off` → `CC121 Reset All Controllers`。
后两条是标准里"与踏板无关地立刻全静音 + 重置全部表情控制器"的手段，**RTL 未实现时被忽略，不影响前三条**。

### Control Change 编号查证（我查了哪里、结论是什么）

**来源**：[MIDI Association 官方 Table 3「Control Change Messages and RPNs」](https://midi.org/midi-1-0-control-change-messages)
（MIDI 1.0 规范附表，状态字节 176–191）。逐条对照官方原文：

| 项 | 官方表原文 | 结论 |
|---|---|---|
| CC 5 = 滑音时间 | `5  Portamento Time` | ✅ **完全正确**（CC 37 是它的 LSB） |
| CC 64 = 延音踏板 | `64  Damper Pedal on/off (Sustain)   ≤63 off, ≥64 on` | ✅ **完全正确**，且**阈值语义**也对 |
| CC 65 = 滑音开关 | `65  Portamento On/Off   ≤63 off, ≥64 on` | ✅ **完全正确** |
| CC 76 = 颤音速度 | `76  Sound Controller 7 (default: Vibrato Rate – see MMA RP-021)` | ✅ **完全正确** |
| CC 1 = 颤音深度 | `1  Modulation Wheel or Lever` | ⚠️ **编号有效但官方名是"调制轮"**；官方表里**专职的 "Vibrato Depth" 是 CC 77**（`Sound Controller 8 (default: Vibrato Depth)`）。用 CC1 作颤音深度是 **GM/合成器的通用惯例**，不是规范文字 |

**据此做的决定**：**CC 1 与 CC 77 同步发送同一个深度值** ——
RTL 实现哪一个都能生效，外部 MIDI 工具的调制轮（CC1）也能直接控制；代价只是拖动滑块时多发 3 字节。

**顺带查到的两条（已用上）**：`CC 120 All Sound Off`、`CC 121 Reset All Controllers`、`CC 123 All Notes Off`
官方表里都标注为 **[Channel Mode Message]**；其中 CC120 **与踏板无关地立刻全静音**，CC121 **一次性重置所有表情控制器** ⇒
比原来只用 CC123 彻底得多，故并入「全部停止」。

## 接线（FPGA 侧引脚，三处官方来源一致）

| 信号 | FPGA 引脚 | 约束 | 出处 |
|---|---|---|---|
| FPGA → PC（`txp`） | **U15** | `IO_TYPE=LVCMOS33 PULL_MODE=UP DRIVE=8 BANK_VCCIO=3.3` | 官方 `tang_mega_138K_pins.cst` L172–173 |
| PC → FPGA（`rxp`） | **V14**（新版 31004+）／ **Y14**（旧版 31002） | 同上 | 同上 L176–177 / 注释掉的 L180–181 |
| 交叉印证 | `uart_tx=U15`、`uart_rx=V14` | — | 官方例程 `ddr_memory_test_uart/src/ddr3_1v4_hs.cst`、`riscv_hdmi/…/riscv_hdmi.cst` |

**PC 侧串口**（本机实测）：
```
COM8 | USB Serial Port (COM8) | USB VID:PID=0403:6010 SER=2025030317A   ← FT2232H 通道 A
COM9 | USB Serial Port (COM9) | USB VID:PID=0403:6010 SER=2025030317B   ← FT2232H 通道 B
```
`programmer_cli.exe --scan` 报：`Target Cable: Gowin USB Cable(FT2CH)`，
并检测到 `GW5AST-138B GW5AST-138C … (One of them)`，ID `0x0001081B`。

### ✅ 已确证（2026-10-05，两个独立实现交叉验证）
| 项 | 结论 | 证据 |
|---|---|---|
| FPGA UART = 哪个通道 | **COM9（通道 B）** | COM9 收到心跳 **`HANK`**；**COM8 全程没有心跳** |
| `rxp` 引脚 | **V14 正确** | 电脑发 `90 45 64`，FPGA 侧收到并回发（回环成立） |
| 双向 | **TX ✅ + RX ✅** | 心跳（TX）+ 回显（RX）都成立 |
| COM8 是什么 | **JTAG 通道**，**会产生伪回显/噪声** | 实测 COM8 收到 `FA 90 FA 45 FA 64`（探针字节之间被插 `FA`），且无心跳 |

> 交叉验证方式：`board-smoke` 用 .NET `SerialPort`（自己的 `serial_probe.ps1`），
> 我用 **pyserial**（`_research/pc-link/watch_serial.py`）各跑一遍，结论一致。
> 原始证据：`_research/pc-link/RERUN-evidence.txt`、`_research/pc-link/NOTES.md` §5/§7。

## GitHub 参考与**学到的点**（用户要求先找现成例程）

| 参考 | 链接 | 学到什么 / 为什么不照抄 |
|---|---|---|
| SourabGarg/Piano-in-Python | https://github.com/SourabGarg/Piano-in-Python | ✅ 学到：tkinter 里"一键一个控件"+ `root.bind(键, 回调)` 的**布局与键位映射**思路（ASDFGHJ=白键、WETYU=黑键，与本项目一致）。❌ 不照抄：①它**只绑 KeyPress、不处理松手 → 会挂音**；②它 `playsound` 播放**预录 WAV**（我们不需要，声音由板子出）；③无复音、无串口、无力度 |
| probonopd/MiniDexed · miditest.py | https://github.com/probonopd/MiniDexed/blob/main/miditest.py | ✅ **三条直接采纳**：①`atexit.register(cleanup_all_notes_off)` —— **进程退出兜底清音**；②NoteOn/NoteOff **成对发送**（`0x90`/`0x80`）；③退出/异常路径显式发 **All Notes Off**。❌ 它用 `python-rtmidi`（原生 MIDI），我们走**串口**，所以只借用法不借库 |
| 检索命中但未采用 | `sherlannn/Virtual_Piano_Using_Hand_Gesture_Recognition`、GitHub topic `virtual-piano-player` | 手势/网页类方案，与本需求（鼠标+键盘+串口）不匹配 |

> 检索词（Lead 指定）：`python virtual piano tkinter`、`python midi keyboard gui`、`pyserial midi`。

## 疑难排查

| 现象 | 处理 |
|---|---|
| 下拉框里没有 COM8/COM9 | 板子/线没插好；点**刷新**；确认设备管理器里是 `USB Serial Port` |
| 点"连接"报"打不开" | 该口被别的程序占用（Gowin Programmer / 另一个串口助手）；换另一个通道试 |
| 连上了但没声音 | ①**优先选 COM9**（已确证是 FPGA UART）；②确认板子已烧**带 uart_rx/midi_rx 的位流**；③`PA_EN` 必须拉低才出声；④耳机插的是板载 3.5mm 口 |
| 有挂音 | 点**全部停止**；或切八度（会自动清音）；关窗口也会清音 |
| 键盘按了没反应 | 焦点要在钢琴窗口上（点一下界面）；输入法切到英文 |

### ⚠️ 三个必须知道的坑（都实测踩过）

1. **只看"发一个字节能收回"会被骗 —— COM8（JTAG 通道）竟然也会"回显"。**
   实测 COM8 收到 `FA 90 FA 45 FA 64`（探针字节之间被插 `FA`），**且 COM8 全程没有心跳**。
   **⇒ 判据优先级：心跳 > 回显 > 仅"有数据"。**（`watch_serial.py` 已按此实现，
   并会显式报出"有数据但没心跳的口 = 伪回显/噪声"。）

2. **心跳 `HANK` 只在【较早那版探针】上实测到**：周期 ≈ 680 ms（86.2 → 766.2 ms）。
   ⚠️ **2026-10-05 15:58 复核时，同一块板在完整 20 s 窗口内【一次 `HANK` 都没有】，
   而回显变成完美 `90 45 64`** ⇒ **探针位流被换过**（新版本修掉了丢字节、但没发心跳）。
   **⇒ 判读方式**：先看心跳；**没有心跳不代表不是 FPGA** ——
   只有 FPGA 能把 `90 45 64` 原样回显 ⇒ **"同口完美回显"是等效可靠的第二判据**。
   监听窗口**至少 3 秒**（心跳版 680 ms 一次，更宽松）。

3. **探针侧丢字节缺陷：早期版本有，新版本已修（实测）。**
   早期：发 `90 45 64` 只收回 `90 64`（`0x45` 被吞，因发送忙无接收缓冲）；
   15:58 复核：**完整收回 `90 45 64`**。与 `host/` 无关；分析见 NOTES §7。

4. **证据文件编码坑**：`Tee-Object` 在 PS 5.1 下写 **UTF-16**，且用**控制台代码页**解码 python 输出
   ⇒ 文件里**中文会乱码，但 ASCII/HEX 完全无损**。
   **⇒ 机器可校验的数据（端口名/时间戳/HEX 字节流）可信；中文标签只作参考。**

## 🎵 `midi_player.py` —— 播 `.mid` 文件让板子演奏（方案 A）

> 把电脑上的 `.mid` 按时间戳变成 MIDI 三字节流 → 串口 → FPGA 实时合成。
> ★ **不需要改任何 RTL**；旋律只存在于电脑上的 `.mid` 文件里，**不进 ROM、不进 bitstream**。
> ★ **复用** `piano_gui.py` 的 `SerialLink` 与协议组装函数（串口代码只有一份，不会两处漂移）。

```powershell
$py = "fpga_hank\_tools\venv\Scripts\python.exe"

& $py host\midi_player.py --list-ports                      # 看串口
& $py host\midi_player.py --file song.mid --dry-run         # ★ 离线验收（不需要板子）
& $py host\midi_player.py --port COM9 --file song.mid       # 真播（FPGA UART = COM9）
& $py host\midi_player.py --port COM9 --file song.mid --tempo-scale 0.5 --limit-seconds 15
& $py host\midi_player.py --selftest                        # 纯离线自检
```

| 参数 | 作用 |
|---|---|
| `--file` | `.mid` 路径（必需） |
| `--port` | 串口名（**COM9**） |
| **`--dry-run`** | **不开串口**，打印"将发送的字节 + 目标时刻"，并自检 **A2/A3/A4/A5** |
| `--tempo-scale S` | `tempo × S` ⇒ **时长 × 1/S**（`0.5`=半速，`2.0`=双速） |
| `--limit-seconds N` | 只播前 N 秒 |
| `--verbose` / `--quiet` | dry-run 逐条打印 / 只给结论 |
| `--selftest` | 纯离线自检（不需要 .mid，也不需要板子） |

**依赖（可选，不破坏"单依赖"承诺）**：需要 **mido**（MIT），但做成**可选依赖** ——
只有 `--file` 时才需要，`--list-ports`/`--selftest` 不需要 ⇒
**`piano_gui.py` 的"只依赖 pyserial"依然成立**。装：`& $py -m pip install mido`（本机已装 1.3.3）。

### 离线验收结果（`--dry-run`，不需要板子）

| 判据 | 结果 |
|---|---|
| **A2** dry-run 输出 100% 合法协议 | ✅ 长文件 **404 行全部通过**（每 3 字节一组、status∈{80,90,B0}、data≤0x7F、**且通道折叠到 ch0**） |
| **A3** 音符数与 `.mid` 一致 | ✅ 发出 **200 / 文件 200** |
| **A4** 无累积漂移 | ✅ 末漂移 **+1.618 ms**（最坏迟到 2.900 ms、P95 2.843 ms）；**对照的"累加式"实现漂移 +456.250 ms** ⇒ 判据**有判别力** |
| **A5** 结尾清音 | ✅ 结尾追加 4 组 = 真实 `SerialLink.panic()` 的字节（`CC64=0 → CC123 → CC120 → CC121`） |
| tempo 数学（**独立手算核对**） | ✅ 曲中 120→240 BPM：变速点落在 **1.000 s**（delta 用**旧** tempo）、变速后 note_off 落在 **1.250 s**（用**新** tempo）；`--tempo-scale 0.5` ⇒ 时长 ×2 |
| 多轨合并 | ✅ 双轨文件合并后时长 1.0 s、两个 note_on 都发出 |
| 忽略统计（不静默） | ✅ 短文件里 弯音×1 + CC74×1 + CC7×1 全部在结尾打印 |

复跑：`& $py _research\pc-link\verify_midi_player.py`（会自生成测试 `.mid` 并做全量断言，exit 0 = 全通过）

### 已知限制（**不是 bug，别当故障查**）
1. ⚠️ **不支持弯音（Pitch Bend）** —— 协议里没有这个端口（要支持须改 RTL 契约）
2. ⚠️ 其它未支持 CC / Aftertouch / Program Change / SysEx **一律忽略**，
   **但会在结尾统计打印**（`⚠ 已忽略(统计): ...`），**绝不静默**
3. ⚠️ 定时精度受 OS 调度影响 —— **这不是实时系统；听感没问题，但不要拿它测延迟**
4. ⚠️ 只支持标准 MIDI 文件（`.mid`/`.midi`）；**不碰 `.wav`/`.mp3`**
5. ⚠️ 同时发声数受 FPGA 复音上限（32）约束，超出由声部分配器丢弃（**设计如此**）
6. ⚠️ dry-run 的 **A4 用的是"带抖动的假时钟"**，证明的是**调度算法本身无累积漂移**；
   **真机上的绝对抖动取决于 OS**（真播会打印实测的最坏迟到 / P95 / 末漂移）

## 🔴🔴 纪律：**板子是【用户的乐器】，不是我们的测试台**

> **2026-10-06 实证事故**：跑 `sweep_notes.py` 逐个发 note 诊断时，**用户正戴着耳机在弹琴**，
> 突然听到板子自己响；更糟的是那一次的 **panic 没发出去**
> （根因：我用 `| Select-Object -First` 截断输出，**杀掉了上游 python** —— AGENTS.md §8.2 的同一个坑），
> 板子上留了挂音，最后由 Lead 手工发全停命令清理。

**三条规则（立即生效，适用于本目录所有会写串口的脚本）**

| # | 规则 | 说明 |
|---|---|---|
| 1 | ⛔ **往板子发 note 前，先在团队里"占用"** | 用户随时可能在弹（**戴着耳机**，我们的测试对他就是噪声） |
| 2 | ⛔ **任何往板子的写入，结束【必须】发 panic** | 不问成败、不问有没有异常 —— 写进 **`finally`** |
| 3 | ⛔ **不要用 `\| Select-Object -First` 截断串口脚本的输出** | 它会**杀掉上游 python** ⇒ `finally` 里的 panic **发不出去** |

**★ 规则 3 的教训**：同一个技术坑（§8.2），上次只是"白跑一次、证据只剩表头"，
这次**直接造成用户可感知的打扰** ⇒ **凡是有副作用的脚本，都要假设"输出会被截断"**，
所以**清理动作绝不能依赖脚本跑到最后一行**。

**`sweep_notes.py` 已按此加固**：
- `finally:` 里**无条件**发深度 panic（`CC64=0 → CC123 → CC120 → CC121` **+ 对 0..127 全发 NoteOff**）
- 支持 `Ctrl+C` 中断后**仍然清音**；panic 发送失败会**红字提示"手工清音或拔电"**
- **`--yes` 确认闸门**：不加 `--yes` 会打印警告并要求**手输 `YES`**（防误跑）
- ⚠️ 声学测量前有**仪器自检**（本机麦克风只返回 ±1 LSB ⇒ 拒绝下判定，避免假阴性）

## 本目录文件的验证状态

| 文件 | 状态 |
|---|---|
| `piano_gui.py` | ✅ `--selftest` **37 项全 PASS**（exit 0；含调试框解析 8 项 + **表情 CC 14 项**）；✅ `--smoke 2500` 真启动界面并正常退出（exit 0）；⚠️ **尚未与真板子做过端到端弹奏**（等位流烧进去） |
| `midi_player.py` | ✅ `--selftest` 11 项全 PASS；✅ 离线验收 **A2/A3/A4/A5 全 PASS + tempo 数学/多轨/通道折叠 全 PASS**（`_research/pc-link/verify_midi_player.py`，exit 0）；⚠️ **尚未上板听过** |
| `requirements.txt` | ✅ 只列 `pyserial==3.5`；`mido` 注明为**可选**（不破坏"单依赖"承诺） |
| `../rtl/io/uart_rx.v`、`../rtl/io/midi_rx.v` | ✅ ModelSim `vlog -sv` 编译 `Errors: 0`；✅ `tb_uart_rx` 16 项检查全 PASS |
| `../sim/tb/tb_uart_rx.v` | ✅ `[RESULT] PASS (all checks passed)`，`Errors: 0` |
| 表情 CC 的 RTL 侧 | ❌ **未实现**（`midi_rx.v` 目前只认 `0x9n/0x8n/0xBn 7B 00`；其它 CC 被忽略）⇒ 需 RTL 侧按上表跟进 |
