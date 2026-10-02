# ModelSim 真窗口波形图（工具原图，非脚本绘制）

> **本目录里的 PNG 是 ModelSim 自己的窗口画面**，不是我们脚本渲染的。
> 采集链：真仿真 → `.wlf` 数据集 → `vsim -gui -view <wlf> -do <do>` 打开工具窗口
> → `PrintWindow` 抓窗口自身（**不受遮挡**）→ 两项像素自检通过才算成功。
> 采集脚本：`_smoke-test/cap_window.ps1`。
>
> ⚠️ 早期 **matplotlib 脚本渲染**的图已被用户否决，**不在本目录**：
> 我自己的 5 张已移到 `_smoke-test/matplotlib-drafts/`；
> 另一位 teammate 的 4 张中文命名图仍在 `../`（不是我的文件，未动，待 Lead 处置）。

| # | 文件 | X 轴范围 | 在证什么 |
|---|---|---|---|
| 1 | `1_pt8211_位序与声道边界.png` | 11.20–16.50 µs（一个左声道半帧） | I2S 位序与左右声道边界正确 |
| 2 | `2_ADSR_起音与衰减.png` | 0–35 ms | 起音 10.49 ms 是**斜坡不是垂直**；随后衰减 20.97 ms |
| 2b | `2b_ADSR_释放段.png` | 195–275 ms | 释放 62.91 ms 也是斜坡（慢慢落下去） |
| 3 | `3_tone_bank_32路混音.png` | 0–40 µs（≈4 个采样点） | `sample_tick` 周期 + `addr_mux` 0→31 轮询 + `mix16` 起伏 |
| 4 | `4_按键到出声_因果链.png` | 15.00–17.05 ms | `key_raw` 先动 → `key_db` 滞后 2.621 ms → gate → env_level |
| 5 | `5_按键去抖_抖动边界用例.png` | 14.95–17.05 ms | 抖动 16 次通断，去抖后**只认 1 次** |

## ⚠️ ADSR 为什么拆成两张

一张图同时显示"起音 10.49 ms"和"释放 62.91 ms"是做不到的：
整个包络跨 0→262.9 ms，若压进一张图，**10.49 ms 只占 4% 宽 ⇒ 斜坡被压成近乎垂直线**，
恰好把最想证明的那一点证没了。所以按"**一张图只讲一件事**"拆成
`2`（起音+衰减，0–35 ms）与 `2b`（释放，195–275 ms）。

## 缩放是怎么验证生效的（**不靠肉眼看图猜**）

前几版 `.do` 把缩放写成 `catch {WaveRestoreZoom ...}`，**失败被静默吞掉**，
交出去的图时间轴停在全范围而没人知道。现在改成：

1. **`ztry` 包装**：每条缩放命令的结果都打印 `[zoom] ... -> ok / FAIL: 原因`；
2. **`after 2000` 延迟**：等 GUI 真正就绪再缩放（`-view` 模式下 `.do` 可能早于窗口 ready）；
3. **末尾打印时间范围**：`puts "\[zoom\] 最终时间范围 = $_r2"`，
   放在**文件末尾**，这样不会被后面的 `[wave]` 输出顶出 Transcript 可视区；
4. **独立复核**：截图上 Wave 面板右下角的状态条会显示当前范围，
   例如 pt8211 那张显示 **`11200 ns to 16217082 ps`**，与目标 11.20–16.50 µs 一致 ⇒ 缩放确实生效。

> 说明：Objects 面板标题栏里的 `33191000 ps` 是**数据集结束时间**，不是缩放范围，别混淆。

## 关于 `key` 的极性（评审可能问，这里说清）

**没有矛盾**：`fpga_hank.cst` 里 `PULL_MODE=UP` + 板上按键接地 ⇒ **按下 = 0（低有效）**。
测试台里 `reg key = 1'b1;` 表示**上电默认未按下**，`key = 1'b0;` 才是"按下"。
所以因果链那张图在 `t = 0`（还没按）时读到 `key = 1'h1` **正是对的**；
按键发生在 **15 ms**，图的时间轴是 15.00–17.05 ms，能看到 `key` 在窗口左端拉低。

## 为什么第 4 张的 DUT 是 `smoke_top` 而不是 `top`

**有意为之**：按键 → 两级同步 → 2.621 ms 去抖 → gate → ADSR → 出声 这条链
正是在 `rtl/smoke/smoke_top.v` 里实现的（`STAGE=6`），它才是**真实交互通路**；
`rtl/top.v` 的 gate 来自 `bench_gate`（测试用假按键），**没有真实按键通路**。
所以链路因果只能用 `smoke_top` 举证。

## 复现

```powershell
cd "C:\Users\Danny\Desktop\FPGA competition\fpga_hank"

# 1) 生成 .wlf（已生成好，在 sim\wlf\；重跑约 1 分钟）
foreach ($t in "tb_wave_pt8211","tb_wave_adsr","tb_wave_tonebank","tb_wave_chain","tb_wave_bounce") {
  $env:SIM_TOP=$t; & "F:\Modelsim_10.7\win64\vsim.exe" -c -do sim\make_wlf.do
}
Remove-Item Env:\SIM_TOP

# 2) 打开窗口（一条命令一张图）
& "F:\Modelsim_10.7\win64\vsim.exe" -gui -view "sim\wlf\tb_wave_pt8211.wlf" -do "sim\wave_pt8211.do"

# 3) 自动截图（带自检 + 抓取重试）
powershell -NoProfile -ExecutionPolicy Bypass -File "..\_smoke-test\cap_window.ps1" `
  -Wlf "sim\wlf\tb_wave_pt8211.wlf" -Do "sim\wave_pt8211.do" `
  -Out "docs\waveforms\real\1_pt8211_位序与声道边界.png"
```

## 采集脚本的两项自检

`cap_window.ps1` 抓完图做像素级检查并打印 `self-check: menuTop=.. greenRight=..`：

1. **`menuTop`**（判据 > 60）：顶部菜单/工具栏要有彩色像素 ⇒ 抓到的确实是 ModelSim 窗口；
2. **`greenRight`**（判据 > 200）：右半波形区要有绿色波形像素 ⇒ 专抓"分组被收起导致波形区一片灰"。

另加**抓取重试**：进程句柄可能失效（实测出现过 `GetWindowRect failed`），脚本会重查句柄最多 6 次。

## 已实测的坑（写 `.do` 的人必看）

> **纪律**：ModelSim 命令**先查本机官方手册再写**，不要猜 ——
> `F:\Modelsim_10.7\docs\htmldocs\modelsim_se_ref\topics\*.html`（纯文本可直接搜），
> 或 `docs\cmd_help\cmd_help.txt`；见 `liaison/MODELSIM-GUIDE.md`。

1. **`add wave -group` 的分组默认【收起】** ⇒ 打开只有一行组名、波形区一片灰。
   改用 **`add wave -divider <标题>`**：标题照样有、永不收起。
   （官方也有 `-expand <signal>` 可展开 `-group`，但"打开就要看见波形"用 divider 最稳。）
2. **`wave expand` 存在但不生效**（两次截图逐字节相同），别依赖它。
3. **全屏 `CopyFromScreen` 抓 GUI 会被别的窗口遮挡** ⇒ 必须用 `PrintWindow(hwnd, hdc, 2)`。
4. **裸 `catch` 包缩放 ⇒ 失败静默** ⇒ 必须打印每条命令的结果 + 末尾打印最终范围。
5. `vsim -do <file>` **不接收位置参数**，参数要用环境变量传。
6. **缩放/游标官方语法**（已在 `.do` 里采用）：
   `wave zoom range <start> <end>`、`wave refresh`、
   `wave cursor add -time <t> -name <n>`（**不要用旧式的 `WaveRestoreCursors`**）。
7. **⚠️ 采集脚本绝不能按进程名清场**：早期版本开头写
   `Get-Process vsim,vish,vsimk | Stop-Process -Force` 当"清理残留"，
   结果**把别人正在跑的仿真杀了**（症状：仿真总在相近样本数处
   `Fatal: Exiting VSIM license process`）。现在 `cap_window.ps1`：
   **发现已有 vsim 就直接中止（exit 4）**，收尾**只停自己启动的那些 PID**
   （用启动前的 PID 快照做差集），要强制才加 `-AllowKill`。
8. **★ 位宽 > 1 的信号默认 `-format literal`（一个"装着数值的方框"）⇒ 模拟量画不出斜坡！**
   `env_level` / `mix` 这类模拟量必须显式指定：
   ```tcl
   add wave -format analog-interpolated -min 0 -max 65536 -radix unsigned /tb_wave_adsr/dut/level
   ```
   官方 `-format` 取值：`literal`(默认,方框) / `logic` / `analog-step` /
   **`analog-interpolated`(两值之间连斜线)** / `analog-backstep`。
   **这条是本项目最有价值的显示坑**：改之前 ADSR 图里包络显示成"一串方框"，
   看起来像"包络没在动"；改之后**起音斜坡一眼可见**。
   也就是说 —— **同一份数据，显示格式选错，会把最想证明的结论证没了**。
   有符号样本（`mix`）用 `-format analog-interpolated -radix signed`。

## 采集自检结果（六张全过，脚本自己打印）

| 图 | `menuTop`(判据>60) | `greenRight`(判据>200) | 结论 |
|---|---|---|---|
| 1 pt8211 | 112 | 1376 | PASS |
| 2 ADSR 起音与衰减 | 112 | 1216 | PASS |
| 2b ADSR 释放段 | 112 | 1220 | PASS |
| 3 tone_bank | 112 | 1526 | PASS |
| 4 因果链 | 112 | **453**（修好前 119 = FAIL） | PASS |
| 5 按键去抖 | 112 | 332 | PASS |

缩放/游标的**自证**（打印在 Transcript，不靠肉眼看图）：
- `[zoom] zoom range 0ms 35ms -> ok`、`[zoom] 最终时间范围 = {0 ps} {31886120996 ps}`
- `[cursor] cursor3 = {-color default} {-lock 0} ... {-time 10.49 ms}`、`[cursor] 可用游标数 = 3`
- 图上同时显示游标读数：ADSR 两张是 **`10.49 ms`**（起音爬满）；
  pt8211 那张是两个游标 **`11360 ns` / `11680 ns`，工具自己显示差值 `320 ns`**（就是 BCK 周期）。

## 修订基线（这批图/位流对应哪一版 RTL）

`sim/wlf/*.wlf` 重生成于 **2026-10-03 01:43:57–01:44:30**，**晚于**当天 01:41:26 那次 RTL 改动
（`adsr.v` / `pt8211_tx.v` / `top.v`），**与 git `c125bc8` 的冻结基线一致**：

| 文件 | SHA256(前12) |
|---|---|
| `rtl/smoke/smoke_top.v` | `5A57D0CE5CD0` |
| `rtl/synth/adsr.v` | `6CD7AAEF22E6` |
| `rtl/synth/tone_bank.v` | `DA35AF9D4935` |
| `rtl/synth/wave_rom.v` | `CF94D5FAA85F` |
| `rtl/synth/bench_gate.v` | `3CA7C435C464` |
| `rtl/audio/pt8211_tx.v` | `B039B9A68665` |

> ⚠️ 图上的 BCK 占空比是 **12.5%（高 40 ns）** —— 这是 `pt8211_tx.v` **修 `tH` 之后**的波形。
> 更早那批图是 6.25%（高 20 ns，**低于 PT8211 的 `tH ≥ 25 ns`**），**已作废并重采**。
> ⇒ 这张图同时也能用来核对"tH 修复是否生效"。

## 数值口径（**必须带配置**，两套都对）

算法（liaison 修正后的准确表述）：
> **时长 = 行程 ÷ (65536 >> SH) × EN_DIV × 20 ns**
> · 起音行程 = **65536** ⇒ 步数恰为 `2^SH`（"`2^SH` 步"**只在起音成立**）
> · 衰减行程 = **65536 − 49152 = 16384**（**不是 `2^SH`**）
> · 释放行程 = **49152**（从 sustain 起）**或 65536**（从满幅起）⇒ **释放有两个值**

| 配置 | 起音 | 衰减 | 释放（从 sustain） |
|---|---|---|---|
| **生产 `rtl/top.v`**（EN_DIV=512, ATK/DEC_SH=10, REL_SH=13） | 10.48576 ms | **2.62144 ms** | 62.91456 ms |
| **本组图的 `tb_wave.v`**（EN_DIV=64, ATK_SH=13, DEC/REL_SH=16） | 10.48576 ms | **20.97152 ms** | 62.91456 ms |

⇒ **本 README 与图注里写的"衰减 20.97 ms"是【测试台配置】的值，不是生产值。** 引用时必须标配置。
（`top.v` L187 / `adsr.v` L45 原先写"释放 8192 步 ≈ 83.9 ms"是把"从满幅释放"当成了唯一值；
**从 sustain 释放是 6144 步 = 62.914 ms**。）

其他量（与配置无关）：
- 去抖 **2.621 ms**（`DB_MAX = 2^17−1` ⇒ 131 072 clk × 20 ns）
- 物理接触→出声 **2.663 ms**；BCK 周期 **320.0 ns**；fs **97 656.25 Hz**（一帧 10.24 µs）

> ⚠️ 早期脚本图注里写过"衰减 **19.89 ms**"——那是**按"电平跌破 50000"这个阈值**量出来的，
> 不是衰减到保持电平（49152）的时间。**正确值 20.97 ms（测试台配置）**。窗口截图不含我写的数字。

## `-wlf` 生成的正确认识（**更正 liaison 原先的两条**）

liaison 原报"嵌套 `vsim` 不生效""含空格绝对路径被拆开"两条，**经我这边实测推翻了**，他也已认：

| 说法 | 正确结论 |
|---|---|
| 嵌套 `vsim -c -do` 里再起 `vsim -c -wlf` | ✅ **可行** —— `sim/make_wlf.do` 就是这个结构，5 个 `.wlf` 都用 `wlfman info/items` 核过 |
| `-wlf` 传含空格的绝对路径 | ✅ **不是问题** —— **Tcl 变量替换不做词分割**，`$WLF` 传给 `vsim` 仍是单个参数 |
| **不给 `log`，`-wlf` 出的是空库** | ✅ **唯一真因** —— 文件在、里面没信号 |
| `log -r /*` vs 挑信号 | ⭐ **挑信号更对**：`log -r /*` 会把 350 ms 的 `clk`（≈3500 万次跳变）全记进去 ⇒ wlf 数百 MB（liaison 那份 ADSR VCD 转出来 **413 MB**）。**按图挑 5–9 个信号 ⇒ 49–311 KB。** |

⇒ **`sim/make_wlf.do` 用的是"挑信号"方案**（`log /tb_xxx/sig`），这是刻意选择，不是省事。
