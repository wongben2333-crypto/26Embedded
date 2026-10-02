# ModelSim 真窗口波形图（工具原图，非脚本绘制）

> **本目录里的 PNG 是 ModelSim 自己的窗口画面**，不是我们脚本渲染的。
> 采集方式：跑真仿真 → 存 `.wlf` 数据集 → 用 `vsim -gui -view <wlf> -do <do>` 打开工具窗口
> → 用 `PrintWindow` 抓 Window 自身（**所以不会被别的窗口遮挡**）。
> 采集脚本：`_smoke-test/cap_window.ps1`（含两项自检，见文末）。
>
> ⚠️ 早期那批 **matplotlib 脚本渲染**的图已被用户否决，**不在本目录**：
> 我自己的 5 张已移到 `_smoke-test/matplotlib-drafts/`；
> 另一位 teammate 的 4 张中文命名图仍在 `../`（不是我的文件，未动，待 Lead 处置）。

| # | 文件 | 在证什么 |
|---|---|---|
| 1 | `1_pt8211_位序与声道边界.png` | I2S 位序与左右声道边界正确 |
| 2 | `2_ADSR_起音与释放.png` | 包络按斜率升降，不是瞬时开关 |
| 3 | `3_tone_bank_32路混音.png` | 32 路【分时查表】+ 实时混音输出 |
| 4 | `4_按键到出声_因果链.png` | 按键 → 同步 → 去抖 → gate → 包络 → 出声 |
| 5 | `5_按键去抖_抖动边界用例.png` | 抖动 16 次通断，去抖后只认 1 次 |

## 怎么复现（在 `fpga_hank` 目录下）

**第一步：生成 `.wlf` 数据集**（已经生成好，在 `sim/wlf/`；重跑一遍约 1 分钟）

```powershell
foreach ($t in "tb_wave_pt8211","tb_wave_adsr","tb_wave_tonebank","tb_wave_chain","tb_wave_bounce") {
  $env:SIM_TOP=$t; & "F:\Modelsim_10.7\win64\vsim.exe" -c -do sim\make_wlf.do
}
Remove-Item Env:\SIM_TOP
```

**第二步：打开窗口看一眼**（一条命令一个图；这就是"工具原图"的来源）

```powershell
& "F:\Modelsim_10.7\win64\vsim.exe" -gui -view "sim\wlf\tb_wave_pt8211.wlf"   -do "sim\wave_pt8211.do"
& "F:\Modelsim_10.7\win64\vsim.exe" -gui -view "sim\wlf\tb_wave_adsr.wlf"     -do "sim\wave_adsr.do"
& "F:\Modelsim_10.7\win64\vsim.exe" -gui -view "sim\wlf\tb_wave_tonebank.wlf" -do "sim\wave_tonebank.do"
& "F:\Modelsim_10.7\win64\vsim.exe" -gui -view "sim\wlf\tb_wave_chain.wlf"    -do "sim\wave_key_env.do"
& "F:\Modelsim_10.7\win64\vsim.exe" -gui -view "sim\wlf\tb_wave_bounce.wlf"   -do "sim\wave_debounce.do"
```

**第三步：截图**（可选，本目录的图就是这么来的）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "..\..\..\_smoke-test\cap_window.ps1" `
  -Wlf "sim\wlf\tb_wave_pt8211.wlf" -Do "sim\wave_pt8211.do" `
  -Out "fpga_hank\docs\waveforms\real\1_pt8211_位序与声道边界.png"
```

## 采集脚本的两项自检（防止再出废图）

`cap_window.ps1` 抓完图会自己做像素级检查，并打印 `self-check: menuTop=.. greenRight=..`：

1. **`menuTop`** —— 顶部菜单/工具栏区域要有足够多的彩色像素
   （ModelSim 菜单栏 + 图标）。太低 ⇒ 抓到的不是 ModelSim 窗口。（判据 > 60）
2. **`greenRight`** —— **右半部分是波形区，必须有绿色波形像素**。
   这一条专门抓"分组被收起导致波形区一片灰"那个坑。（判据 > 200）

⇒ 只有两项都过才算采集成功。

## 两个已验证的坑（写 `.do` 的人必看）

1. **`add wave -group` 建出来的分组默认是【收起】的** —— 用户/我们看到的就是一行组名 + 一片灰的波形区。
   已实测截图确认。**改用 `add wave -divider <标题>`**：标题照样有，但永不收起，打开就有波形。
2. **`wave expand` 在 GUI 里存在但没能展开分组**（两次截图逐字节相同 = 完全没生效），不要依赖它。

## 数值口径（一处更正）

- 起音 **10.49 ms**（8192 步 × 64 拍 ÷ 50 MHz）
- 衰减 **20.97 ms**（16384 步 × 64 拍 ÷ 50 MHz = 1 048 576 clk）
- 释放 **62.91 ms**（49152 步 × 64 拍 ÷ 50 MHz = 3 145 728 clk）
- 去抖 **2.621 ms**；物理接触→出声 **2.663 ms**；BCK **320.0 ns**；fs **97 656.25 Hz**（一帧 10.24 µs）

> ⚠️ 早期脚本图注里写过"衰减 **19.89 ms**"——那是**按"电平跌破 50000"这个阈值**量出来的，
> 不是衰减到保持电平（49152）的时间。**正确值 20.97 ms**。本目录的窗口截图不受影响
> （窗口里是原始波形，不含我写的数字）。引用时请用 20.97 ms。
