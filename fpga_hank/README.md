# fpga_hank —— 给队友的说明

> **2026 FPGA 创新设计赛道·高云杯·选题二：基于 FPGA 的实时多音色合成电子乐器引擎**
> 板卡：**Sipeed Tang Mega 138K Dock** ｜ FPGA：`GW5AST-LV138PG484AC1/I0`（device `GW5AST-138C`）

**这份文档是给队友（`fpga_ben` / `fpga_spark`）看的** —— 讲清**我们做了什么、怎么跑起来、哪些已验证、哪些还没做**。
（给评委的材料是 `docs/技术文档.docx` 与本文末尾的「附录 A」。）

---

## 0. 三分钟上手

> ### 🔴 队友先看这一条：**有两样东西不在库里，你必须自己生成**
> 我按纪律用双判据实测过（`git check-ignore --no-index` + `git ls-files -o --exclude-standard`）：
>
> | 东西 | 实测 | ⇒ 你要做什么 |
> |---|---|---|
> | **`out/bitstream/*.fs`**（位流，361 MB 的 `out/` **整目录被 gitignore**，`git ls-files fpga_hank/out/` = **0**） | 🔴 **不在库里** | **自己构建**（见下面 ①）—— 本文档提到的位流文件名，**你得构建出来才有** |
> | **`_tools/venv/`**（电脑端 Python 环境） | 🔴 **不在库里** | **自己建 venv**（见下面 ⓪） |
> | **`eda_proj/`**（Gowin 工程与产物） | 🔴 不在库里 | 构建时自动生成 |
> | `rtl/**/*.v`、`host/*.py`、`tools/**`、`constr/**`、`docs/**` | ✅ **在库里** | 直接可用 |
>
> ⚠️ **所以：本文档里所有 `out/bitstream/xxx.fs` 的路径，都是"你构建之后才会存在"的路径。**

```powershell
cd fpga_hank

# ⓪ 建电脑端环境（只需一次）
python -m venv _tools\venv
.\_tools\venv\Scripts\python.exe -m pip install -r host\requirements.txt   # 只需 pyserial

# ① 构建（改 rtl/top.v 第 40 行的 MODE 参数可以切模式，见 §2）
& "F:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe" "tools\gowin\build.tcl"

# ② 烧录（用 -Mode sram：脚本内部走操作码 2 "SRAM Program"，不带 Verify）
#    ⚠️ 别用操作码 4（Program **and Verify**）——本板回读校验通路不可用，会**误报 Verify failed**
powershell -NoProfile -ExecutionPolicy Bypass -File tools\gowin\program.ps1 -Mode sram -Fs out\bitstream\MODE1_电脑控制.fs

# ③ 一键验收（构建 + 全部仿真 + 全部判据 + 交付物清单）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify\run_acceptance.ps1
```

---

## 1. 当前状态：**真板已验证清单**

> ⚠️ **每个"已验证"都带指纹**（`User Code` / 文件名 / 时间）。**没有指纹的结论不要当已验证。**

| 模式 / 链路 | 真板结果 | **`User Code`** | **证据强度** |
|---|---|---|---|
| **MODE=2 测试模式** | ✅ **32/32 谱峰**（赛题必备交付物） | **`0x0000BB21`** | ⚠️ **产物已丢失**（那份 `.fs` 没归档） |
| **MODE=0 演示模式（放歌）** | ✅ 真板放歌成功；**用户确认 4 首公有领域曲目旋律正确** | **`0x0000C7B0`** | ⚠️ **凭证不足**（无逐次烧录日志） |
| **MODE=1 电脑钢琴** | ✅ 真板**验证成功**（用电脑弹琴出声） | **`0x0000F2CB`** | ✅ **日志实测** |
| **串口链路** | ✅ **COM9** / 引脚 **`rxp = V14`** / **双向通**（两个独立实现交叉验证） | `0x00003907` | ✅ 日志留档 |

> ### ⭐ 完整指纹表已落盘：**[docs/BITSTREAM-FINGERPRINTS.md](docs/BITSTREAM-FINGERPRINTS.md)**
> 含每个位流的 **大小 / 构建时间 / `sha256`(前16) / `User Code` / 烧录时间 / 真板结果 / 证据强度**，
> 以及**三条必须一起读的说明**（① 产物丢失 ② 凭证不足 ③ **`User Code` 是逐次构建的随机量，不是设计标识**）。
>
> ⚠️ **该表放在 `docs/` 而不是 `out/`** —— 因为 **`out/` 整目录被 gitignore，放那里的记录队友看不到**（实测双判据确认）。
> **⇒ 以后每次烧板，务必更新那张表**（AGENTS.md §8.1 纪律）。

**⚠️ 三个模式都有同一类"已知问题"**（不影响功能，但要心里有数）：见 §7。

---

## 2. ⭐ 三个模式怎么用（**队友最需要的一节**）

> ### 🔴 先看这条：**`docs/` 下有两份文档已过期，别照它们做**
> 实测核实（2026-10-05；两份都是 **10-03 02:04** 的旧版本）：
>
> | 过期文档 | 它写的（**错的**） | 现在实际是 |
> |---|---|---|
> | `docs/预先构建的位流.md` | `TEST_MODE = 0/1` | **`MODE = 0/1/2`** |
> | **`docs/上电操作卡-正式交付.md`** ⚠️ | 同上，**而且它指向的位流文件名磁盘上根本不存在** | 见下表 |
>
> **实测它引用的文件名全部不存在**：`fpga_hank_TESTMODE0_演奏模式.fs`、`fpga_hank_TESTMODE1_测试模式.fs`、
> `out\bitstream\fpga_hank.fs` ⇒ **照它走会一路找不到文件，还会去找一个已经不存在的参数 `TEST_MODE`。**
>
> **⇒ 以【本节】为准。** 那两份需其作者更新（已报 Lead）。

> 🔴 **位流文件名里的编号 = `rtl/top.v` 的 `MODE` 参数值**。
> （**以前两套编号不一致导致烧错位流**，现已统一；旧位流统一加了 `OLD_` 前缀。）

| MODE | 位流文件 | 怎么操作 | 应该听到什么 |
|---|---|---|---|
| **0** | `out/bitstream/MODE0_演示模式_放歌.fs` | **按键1**（`AB13`）= 播放/停止；**按键2**（`Y12`）= 切歌 | **音乐**（小星星 → 欢乐颂 → 铃儿响叮当 → 致爱丽丝 → …） |
| **1** | `out/bitstream/MODE1_电脑控制.fs` | 电脑跑 `host/piano_gui.py`（见 §3） | **弹琴声**（鼠标点 / 键盘弹） |
| **2** | ⚠️ **`MODE2_*.fs` 目前不存在**（待补） | 无需按键（**恒发声**） | **32 路正弦同时响 = 一片"嗡嗡"声** |

> ⚠️ **特别提醒**：**MODE=2 的"嗡嗡声"不是故障** —— 那就是赛题要求的取证声
> （32 个正弦同时响，频谱里能数出 32 根独立谱峰）。**用户第一次听到它时以为板子坏了，其实就是这个。**
> ⇒ **现存的测试模式位流只有 `OLD_TESTMODE1_测试模式.fs`（旧编号，14:30）**，**还没按新编号重建**。

### 2.1 ⭐ 怎么自己构建出位流（**含怎么改 MODE**）

> **位流不进仓库是有意的**（单份 34~40 MB × 多份，且 P&R 非确定性）。**⇒ 你必须自己构建。**
> 上面 §0 的警告框说的"文件不存在"，指的就是这个 —— 下面是完整步骤。

```powershell
cd fpga_hank

# ① 改模式：编辑 rtl/top.v 第 40 行
#      parameter integer MODE = 0;   # 0=演示放歌  1=电脑钢琴  2=32峰测试
#    （MODE 是【编译期参数】，不是运行期切换 —— 每个模式一份独立位流，
#      不需要的通路会被优化掉，所以 3 个模式必须分 3 次构建）

# ② 构建（约 35 秒 ~ 4 分钟，取决于模式）
& "F:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe" "tools\gowin\build.tcl"

# ③ 产物在这里（★ 每次构建都会覆盖同名文件！）
#      eda_proj\fpga_hank\impl\pnr\fpga_hank.fs

# ④ ★★ 立刻归档，否则下次构建就把它覆盖了（MODE=2 的位流就是这么丢的）
Copy-Item eda_proj\fpga_hank\impl\pnr\fpga_hank.fs `
          "out\bitstream\MODE1_电脑控制.fs" -Force

# ⑤ ★ 把指纹追加进 docs\BITSTREAM-FINGERPRINTS.md（大小 / sha256 / User Code / 时间）
(Get-Item out\bitstream\MODE1_电脑控制.fs) | Select-Object Name,Length,LastWriteTime
(Get-FileHash out\bitstream\MODE1_电脑控制.fs -Algorithm SHA256).Hash.Substring(0,16)

# ⑥ 烧录（必须 op 2），烧录输出里会打印 User Code ⇒ 把它回填进指纹表
powershell -NoProfile -ExecutionPolicy Bypass -File tools\gowin\program.ps1 -Mode sram `
  -Fs out\bitstream\MODE1_电脑控制.fs
```

> 🔴 **第 ④ 步是最容易忘、后果最严重的一步。**
> 工程里的 `impl/pnr/fpga_hank.fs` **每次构建都被覆盖**，而**没有自动化归档脚本**（实测 `tools/` 下没有）。
> **MODE=2（赛题必备交付物）的位流就是这么丢的** —— 现在只剩一个 `User Code`，**文件没了**。详见 [docs/BITSTREAM-FINGERPRINTS.md](docs/BITSTREAM-FINGERPRINTS.md) §2.1。

---

## 3. 电脑钢琴怎么跑（**刚验证成功，写详细**）

```powershell
# 1. 先烧 MODE=1 位流
powershell -NoProfile -ExecutionPolicy Bypass -File tools\gowin\program.ps1 -Mode sram -Fs out\bitstream\MODE1_电脑控制.fs

# 2. 在 fpga_hank 目录下运行电脑端（用工程自带的 venv，别用系统 python）
.\_tools\venv\Scripts\python.exe host\piano_gui.py

# 3. 界面里：串口选 COM9 → 点「连接」
# 4. 调试框（原样发十六进制字节）：发 "90 45 64" → 应听到 A4 = 440 Hz
# 5. 鼠标点琴键；或键盘：ASDFGHJ = 白键，WETYU = 黑键
```

- 电脑端**只做 UI 与参数下发**（发 MIDI 三字节），**绝不参与音频合成**（赛题规定 CPU/软件只能做 UI/参数配置）
- 自检：`.\_tools\venv\Scripts\python.exe host\piano_gui.py --selftest` ⇒ **37 项全 PASS**
- 协议（`host/` 与 RTL 必须一致，**单方改动即为 bug**）：
  ```
  NoteOn : 0x90 note vel      （vel = 0 视为 NoteOff）
  NoteOff: 0x80 note vel
  AllOff : 0xB0 0x7B 0x00     （CC123，实现为连续 128 拍 off_valid）
  表情：CC5 滑音时间 / CC65 滑音开关 / CC1·CC77 颤音深度 / CC76 颤音速率 / CC64 延音踏板
  ```

---

## 4. MIDI 文件播放（放任意曲子）

```powershell
.\_tools\venv\Scripts\python.exe host\midi_player.py --port COM9 --file 你的.mid
# 离线自检（不开串口，只打印"将要发的字节 + 时刻"）：
.\_tools\venv\Scripts\python.exe host\midi_player.py --file 你的.mid --dry-run
```

**原理**：电脑读 `.mid` → 按时间戳发 MIDI 三字节 → 串口 → `uart_rx` → `midi_rx` → **FPGA 实时合成**。
⇒ **旋律只存在于电脑上的 `.mid`，不进 RTL/ROM/位流** ⇒ 交付物天然干净，且**换歌零成本**（不用重新综合）。

---

## 5. 工具链速查

| 用途 | 命令 / 路径 |
|---|---|
| **构建** | `F:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe` + `tools\gowin\build.tcl` |
| **烧录** | `tools\gowin\program.ps1 -Mode sram`（默认值；SRAM 易失、不动 Flash）。⚠️ **脚本没有 `-Op` 参数**；`op 2` 是它**内部**传给 CLI 的（`sram`→2 / `flash`→9）。**别用 `op 4`**（Program **and Verify**）—— 本板回读校验通路不可用，会**误报 Verify failed**（实测位流其实已写入） |
| **一键验收** | `tools\verify\run_acceptance.ps1`（`-Quick` 只复核证据；退出码 0=全 PASS） |
| **真板录音取证** | `tools\verify\record_audio.py --sec 10 --out out/record/mic1.wav`（**从麦克风录**） |
| **32 谱峰判据** | `tools\verify\check_peaks.py --fs 97656.25 --count 32 --start 200 --step 200` |
| **仿真** | `F:\Modelsim_10.7\win64\vsim.exe -c -do sim\run.do` |
| **电脑端 venv** | `.\_tools\venv\Scripts\python.exe`（⚠️ **不在库里，需自己建**，见 §0 ⓪；**不要**用系统 python） |
| **构建产物** | `eda_proj/fpga_hank/impl/pnr/fpga_hank.fs`（+ `.rpt.txt` 资源 / `.tr.html` 时序 / `.pin.html` 引脚）⚠️ **`eda_proj/` 与 `out/` 均被 gitignore，构建后才存在** |

---

## 6. 目录结构

```
fpga_hank/
├── rtl/
│   ├── top.v                    ★ 顶层（MODE 参数在这里）
│   ├── synth/                   合成引擎
│   │   ├── tone_bank.v          32 路独立振荡器 + 时分查表 + 混音
│   │   ├── wave_rom.v           4 张音色波表（1024 项 case 常量表，非录音）
│   │   ├── adsr.v               ADSR 包络
│   │   ├── bench_gate.v         测试模式用的"32 路恒按住"
│   │   ├── piano_engine.v       ★ 钢琴音色引擎（62 KB）
│   │   ├── piano_rom.v          钢琴波表（生成产物，**必须入库**）
│   │   ├── song_player.v        放歌状态机（按键1/2）
│   │   └── song_rom.v           曲目 ROM（存"乐谱"= 音符号+时值，**不是 PCM**）
│   ├── effects/                 ★ 硬件效果器（**仅仿真验证过**）
│   │   └── audio_fx.v / fx_comb.v / fx_allpass.v / fx_echo.v / fx_chorus.v
│   ├── audio/pt8211_tx.v        PT8211 I2S 发送器
│   ├── io/                      片外输入链路（只产出"音符事件"，不产生声音）
│   │   ├── uart_rx.v            115200 8N1，中点采样
│   │   └── midi_rx.v            标准 MIDI 3 字节解析
│   ├── smoke/smoke_top.v        分级冒烟顶层（S0–S6，独立于 top.v）
│   └── not_integrated/          未接入顶层（touch_pad.v / sine_rom.v）
├── host/                        ★ 电脑端（Python，只做 UI 与参数下发）
│   ├── piano_gui.py             虚拟钢琴（鼠标+键盘）
│   └── midi_player.py           播放 .mid 文件
├── constr/                      fpga_hank.cst（引脚）/ fpga_hank.sdc（时序）/ smoke.*
├── sim/                         run.do + tb/（各模块 testbench）+ wlf/ + wave_*.do
├── tools/
│   ├── gowin/                   build.tcl / program.ps1
│   ├── verify/                  run_acceptance.ps1 / check_peaks.py / record_audio.py
│   └── gen/                     波表与曲目 ROM 生成器（gen_wave_rom.py / gen_song_rom.py 等）
├── docs/                        技术文档、证据、波形图、上板指南
├── eda_proj/                    Gowin 工程与构建产物（git 忽略）
└── out/                         bitstream/ + record/（真板录音）
```

---

## 7. 🔴 已知问题 / 未完成（**如实写 —— 队友最需要的是这一节**）

| # | 问题 | 现状 |
|---|---|---|
| **1** | **MODE=1 时序违例 `−4.67 ns`（4159 条路径）** | ⚠️ **功能实测正常**（真板能弹），但**最好加多周期路径约束**。分析见 `_research/piano/TIMING-MODE1.md`；根因是**声部分配器的串行链**，`piano-tone` 已修一版但**违例没清**。⚠️ **MODE=0 的最差路径 slack 也只有 `+0.010 ns`/20 ns（擦线过）** |
| **2** | **MODE=2 位流：原证据版已丢失，已重建** | ✅ **重建版已归档**：`MODE2_测试模式_32谱峰.fs`（**34,840,489 B / `68F7FFD22A9B1B18` / 18:37:18**；资源 Logic 4160 (3%) / Reg 1602 / BSRAM 1 / DSP 58；**时序 0 setup / 0 hold**）。⚠️ **原来那份（`User Code 0x0000BB21`）产物已丢失** —— 当次构建没归档、被后续构建覆盖。**两者不是同一份文件**（P&R 非确定性），**但 MODE=2 的 RTL 未变 ⇒ 功能等价**。详见 [docs/BITSTREAM-FINGERPRINTS.md](docs/BITSTREAM-FINGERPRINTS.md) |
| **3** | **Faded 旋律待定** | ⚠️ 队里的吉他编配那段**是"伴奏不是旋律"**（92% 和弦音）；**下载的 MIDI 用户一听就否定了"不是这首歌"**；现在改用**用户提供的原曲谱面**（`Faded.pdf`）**逐像素读谱**，**副歌从第几小节开始仍待用户确认**（该谱无歌词） |
| **4** | **效果器 / 表情只做过仿真** | `rtl/effects/*` 与滑音/颤音/延音**未做端到端上板联调** |
| **5** | **电容触摸检测 FAIL** | 仿真未过、**未接入顶层、无引脚**，不影响位流 |
| **6** | `_smoke-test/` 有 ~981 MB 构建产物 | 已被 gitignore，**不用管**（但也别删，里面有取证日志） |

### ✅ 已批准、**待实现**的三条脚本改进（`Lead` 2026-10-05 批准，已派给 `git-vscode`）

> ⚠️ **这三条【还没实现】** —— 写在这里是为了让队友知道"问题已被承认、修法已定"，
> **也为了让下一个人不要把"已批准"误读成"已完成"。**

| # | 改进 | 解决什么 | 状态 |
|---|---|---|---|
| **1** | **`build.tcl` 加自动归档**：构建后按 `MODE` 把 `.fs` 自动复制成 `out/bitstream/MODE<n>_<名字>_<时间戳>.fs` | **`MODE=2` 丢位流就是这么发生的**（人工归档必然会忘） | ⏳ **待实现** |
| **2** | **`program.ps1` 落盘烧录日志**：每次烧录追加 `时间 + .fs + 大小 + sha256 + User Code` 一个文件 | **"凭证不足"的唯一解法**（现在的 `User Code` 只散落在对话里） | ⏳ **待实现** |
| **3** | **显式设 `user_code`**（`set_user_code`，按模式给固定值） | 让 `User Code` 成为**真正的设计标识**，而不是**逐次构建的随机量** | ⏳ **待实现** |

**⇒ 在第 1 条实现之前，请务必【手动归档】**（见 §2.1 第 ④ 步）。

### ⚠️ **本项目第 4 类同源事故：证据强度不足**（值得全队记住）

> 我们曾用「**音阶 7/7 吻合 + 和弦进行模式相同 + 两个来源速度都是 90 BPM**」这套**三重宏观印证**，
> 判定一份下载的 MIDI 是《Faded》—— **结果用户一听就否定了。**
>
> **⇒ 结论：宏观特征（调性 / 和弦进行 / 速度）足以判断"像不像"，但【不足以确证一首歌】。**
> **⇒ 认歌的最终判据是人耳。**

**归属与责任**：结论由 `liaison` 提出、**由 `Lead` 批准**，**两边都把"三重宏观印证"当成了"确证"**。
**⇒ 这是本项目第 4 类同源事故**（前 3 类见 `AGENTS.md` §8.1 与 `_gitignore`/`_verify-flow` 的相关记录）：

| # | 事故 | 缺陷本质 |
|---|---|---|
| 1 | `board-smoke` 的"假成功" | **产物没绑本次构建** |
| 2 | `pc-link` 的"两次不一致" | **观测没绑位流版本** |
| 3 | `flow-verifier` 的 `pa_*.txt` 过期 | **证据没绑源码版本** |
| **4** | **本条：把"宏观像"当成"确证是"** | **证据【强度】不足** |

**⇒ 三条补救已落地**：
1. **本 README 与 `docs/BITSTREAM-FINGERPRINTS.md` 都加了「证据强度」列**（`日志实测` / `凭证不足` / `产物已丢失`）
2. **凡"已验证"必须写清是【仿真】还是【真板】**，真板还要带 `User Code`
3. **宏观印证只能升级为"候选"，不能升级为"确证"** —— 需要人耳/逐音比对才能确证

---

## 8. ⚠️ 关键坑清单（队友一定会踩）

### 硬件 / 引脚
1. **`rxp`（`V14`）引脚不能带 `DRIVE=8`** —— 布局器报 `CT1108`。`txp`(`U15`) 可以带。
2. **`U21` / `P19` / `Y21` 在 device version C 上是 CPU/SSPI 专用脚**，不可作普通 IO（`PR2017` + `PR2028`）。官方 `dock.cst` 把 `U21` 当 LED 是 **138B** 的写法，**不能搬到 138C**。
3. **`F4` 不要用**：在 1.5V bank（LVCMOS15），混进全 LVCMOS33 会多一处失败可能。
4. **`Y22` 在两份 `.cst` 里角色不同**：`constr/fpga_hank.cst` 里是 `key_pitch`（**输入**，第 3 维变调）；`constr/smoke.cst` 里是 `DBG_KEY`（**输出**，延迟打标）。**分属不同 bitstream，不是笔误**。
5. **供电**：12V DC 或 **USB3.0 + DEBUG-USB 双路 5V**。**单口 USB 会掉电重启**（灯灭又依次亮）。**长按 `PWR` 2 秒才开机**。

### Gowin 工具链
6. **`-synthesis_tool` 只能写小写 `gowinsynthesis`**，其它写法报 `unknown synthesis tool` 并**中断整个脚本**（不是警告）。
7. **`gw_sh.exe` 不会切到 `.tcl` 所在目录**，必须用 `[file dirname [info script]]` 定位工程根。
8. **`.tcl` 不能带 UTF-8 BOM**，否则首条命令变成 `invalid command name "??oreach"`。
9. **器件型号必须精确匹配**：part `GW5AST-LV138PG484AC1/I0`、封装 `PBG484A`、device version 按板上实际选 B/C。**型号写错不报错，但烧录后引脚行为不对。**
10. **`ROM_PARALLEL` 必须显式传 1**（`top.v` 现在写 `.ROM_PARALLEL(1)`，`tone_bank.v` 默认值也已改成 1）⇒ **默认 32 会例化 32 份 ROM 导致综合卡死**。

### RTL / 仿真
11. **`32'd1 << FRAC_BITS` 当 `FRAC_BITS ≥ 32` 时等于 0**（分数分频的小数补偿会彻底失效）。
12. **不要引入"影子寄存器"**（`new_ph <= ph+1; ph <= new_ph;`）—— 会构成串行延迟链，寄存器每周期只前进半格并最终停滞。
13. **不要在同一个 `always` 里用两个并列 `if` 给同一寄存器赋值** —— 条件重叠时"最后一次赋值生效"，极易卡死。
14. **位序/半帧边界类错误"看波形完全正常"** ⇒ 唯一可靠办法是**按 BCK 上升沿逐位解码 DIN** 再比对期望样本（`tb_pt8211_final.v` 就是这么做的，抓出过 5 个"波形正常"的错误实现）。
15. **不接端口得到的是 `Z` 不是 `X`** ⇒ 症状是**"音符被静音"**，不是 X 传播。查"没声音"时别只盯着 X。
16. **ModelSim 优化后读 DUT 内部寄存器可能与实际不符** ⇒ 调试优先做**纯黑盒验证**（只看输出端口）。
17. **ModelSim 10.7 起 `-novopt` 已废弃**，加上会 `Error loading design`。
18. **不要用 PowerShell `Set-Content -Encoding UTF8` 改带中文的 `.v`/`.tcl`** —— 会加 BOM 破坏编码，`vlog` 报 `unexpected non-printable character ... '0xef'`。**统一用无 BOM UTF-8。**
19. **ModelSim 不是单席位**（许可证允许并发；**"单席位"是错的旧说法**）⇒ 纪律是**各用独立的 `work/` 库与输出目录**；**⛔ 不准 `Stop-Process` 杀别人的仿真**。

### 工程纪律
20. **构建产物的判据必须绑"本次构建"** —— 只看 `.fs` 在不在，会**烧到旧位流**。本项目已栽过多次。
21. **文件是否被 git 忽略，必须双判据实测**：`git check-ignore --no-index`（看退出码）+ `git ls-files -o --exclude-standard`。**禁止只看 `.gitignore` 规则文本**（`waveforms/*.png` 不跨 `/`、对否定规则 `check-ignore -v` 也返回 0、不带 `--no-index` 会误判"规则没生效"—— 三个坑都踩过）。

---

## 9. 数据通路与"32 个振荡器"怎么证明

```
按键 AB13 ─┐
按键 Y12  ─┼─► 同步+去抖(2.621 ms) ─► gate[32] ─► adsr ─► tone_bank ─► audio_fx ─► pt8211_tx ─► PT8211 DAC
按键 Y22  ─┘        │                    ▲          │            ▲
 (变调)             │                    │          │            │
                    └── pitch_semi ──────┘   env_voice ┘      效果器
MODE=1: 电脑 → uart_rx → midi_rx ──► 同一套 gate/音符总线
MODE=0: song_rom(乐谱) ──► song_player ──► 同一套
MODE=2: gate 由 bench_gate 提供（32 路恒按住），音色锁纯正弦表
```

- **32 路 ×（独立相位累加器 + 独立频率字 + 独立包络） = 32 个完整振荡器**
  （赛题《振荡器统计规则》三要素**缺一不可**）
- `ROM_PARALLEL=1`（32 路共用一份 ROM 时分查表）**不影响该认定** —— 统计的是**振荡器实例**，不是 ROM 实例
- 全 HDL、**逐样本逐声部**实时合成，**无任何预录 PCM / 音频样本 ROM**（赛题红线）

---

## 10. 硬件事实（已核对权威资料，勿凭记忆）

```
clk        V22      50 MHz 板载有源晶振
led[0..3]  T18 R18 R17 P16      板载 LED，低有效（V13 无灯珠；U21 是 CPU/SSPI 专用脚）
HP_BCK     Y17      PT8211 I2S 位时钟
HP_WS      AB17     PT8211 I2S 字选（高=左，低=右）
HP_DIN     AA16     PT8211 I2S 数据
PA_EN      AB16     功放使能，低有效（必须拉低才出声）
key        AB13     板载用户按键 Key_in[0]（LVCMOS33/上拉，按下=0）
key2       Y12      板载用户按键 Key_in[1]（LVCMOS33/上拉，按下=0）
key_pitch  Y22      PMOD 排针【外接】按键（LVCMOS33/上拉，按下=0）
```

- **资源**：138 240 LUT4 / 138 240 FF / 6120 Kb BSRAM（340 块）/ 298 个 18×18 乘法器 / 12 PLL
- **音频**：`fs = clk/(BCK_DIV×512)`；`BCK_DIV=1` ⇒ **`fs = 97 656.25 Hz`、`BCK = 3.125 MHz`（周期 320 ns、高 40 ns）**
- TMDS/HDMI 差分对：`tmds_d_p_0[0]=J14,H14`、`[1]=J15,H15`、`[2]=K17,J17`、`tmds_clk_p_0=G15,G16`，`IO_TYPE=LVCMOS33D`

---

## 11. 赛题要点提醒（详见仓库根 `AGENTS.md`）

- 评分公式：**同时活跃可闻独立振荡器总数 × 实际音频输出采样率**（唯一乘数项）
- 「一个振荡器」必须同时有 **独立相位累加器 + 频率调控 + 包络控制**；单波表查表**只算 1 个**
- 🚫 **严禁播放预录 PCM / 预置推流 / 整段录音**（现场频谱 + RTL 审查双重验证）
- 必备交付物：**测试模式**输出 N 路不同频率 → 频谱能数出 N 个独立谱峰
- 作品提交截止 **2026-11-04 18:00**；工程冻结 **2026-10-14**

---

# 附录 A：代码审查指引（给评委）

赛题要求「RTL 代码要经得起评委对照审查（无音频样本 ROM、无 SD 卡读 WAV）」。下面给出**每项该看哪里、预期看到什么**。

### A.1 红线：没有预录 PCM / 音频样本

| 查什么 | 怎么看 | 预期结果 |
|---|---|---|
| 有没有加载音频样本 | 搜 `$readmemh` / `$readmemb` | RTL 里**没有真正用它加载音频**（`wave_rom.v` 注释里出现过，是在说明**为什么不用**） |
| 有没有样本数据文件 | 看仓库有无 `.wav` / `.mp3` / `.pcm` / `.mif` / `.hex` / `.coe` | **一个都没有**（`out/record/` 是**录音取证**的输出，不是合成输入） |
| 有没有 SD 卡 / 文件系统 | 搜 `sd_` / `spi` / `fat` / `file` | **没有** |

**波的来源**：`rtl/synth/wave_rom.v` 是一张 **1024 项常量表**（`case` 语句），由**三角函数与傅里叶级数计算生成**，不是录音：
`table0` 正弦（32767·sin(2πi/256)，误差 ≤1 LSB）、`table1` saw5 / `table2` square9 / `table3` tri9（**带限**波形）。

### A.2 红线：≥2 个独立可控维度

看 `rtl/top.v` 的输入与它们**独立**的作用：

| 维度 | 引脚 | 作用 |
|---|---|---|
| `key` | `AB13` | 按住 = 发声 |
| `key2` | `Y12` | 每按一下换音色（4 档循环） |
| `key_pitch` | `Y22`（**PMOD 外接，自研**） | 每按一下升 1 个半音 |

**独立性怎么证**：`sim/tb/tb_interaction.v` 的第 5、6 项是**在按住 `key` 发声的过程中**去按 `key2` / `key_pitch`，检查 `gate` **不受影响** ⇒ 三个维度互不干扰。

### A.3 红线：32 个完整振荡器（不是 1 个波表查表）

看 `rtl/synth/tone_bank.v` —— **32 路各自独立**的：
- `reg [31:0] acc [0:31]` ⇒ **独立相位累加器**（32 个）
- `pitch_inc(k, pitch_semi)` ⇒ **每路独立频率字**
- `env_level[k]` 来自 `adsr` ⇒ **每路独立包络**

三者**缺一不可**。

### A.4 逐样本、逐声部运算

`tone_bank` / `adsr` / `pt8211_tx` 都在 `always @(posedge clk)` 里做**定点逐拍运算**；没有"状态机式一次算一段"，也没有 CPU/软核参与音频通路（`top.v` 里**没有任何 AE350 相关实例**）。

### A.5 证据怎么复核

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify\run_acceptance.ps1
```

- **正式证据**：[32谱峰-取证报告.md](docs/evidence/32谱峰-取证报告.md)（含 SHA256 指纹与一次回归的完整复盘）
- **波形图**：`docs/waveforms/real/` 下 6 张，**全部是 ModelSim 真窗口截图**（本项目**明确禁止自绘图**）

---

# 附录 B：方法论 —— 位流的 SHA256 **不能**当修订标识

实测发现：**同一份 RTL、连续构建两次，`.fs` 的 SHA256 不同**（大小/资源/时序完全相同）。
⇒ **高云的时序驱动 P&R 是非确定性的**（布局/布线在不同运行间有合法差异）。

**三个必须记住的结论**：
1. **不能用 `.fs` 的哈希判断"两个位流是不是同一版设计"** —— 哈希不同**不代表**设计不同。
2. **判断修订要哈希【RTL 源码】**，不是位流。
3. **"重建后哈希不一致"不是构建失败** —— 看**大小 + 资源占用 + 时序违例**三者是否一致。

> 📌 **正确的"版本指纹"格式**（AGENTS.md §8.1 定为纪律）：
> **【时间 + `.fs` 文件名 + `User Code` + 资源占用】**
> —— 缺了 `User Code`，就无法区分"设备不稳定"与"位流换了"。
