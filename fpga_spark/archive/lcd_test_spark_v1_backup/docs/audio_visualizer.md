# 实时音频可视化说明

## 数据路径

```text
音源/32 声部 -> FX -> master_vol -> audio_mix -> dac_pcm -> PT8211 DAC
                                                 |
                                                 +-> audio_visualizer
```

`audio_mix` 在每个立体声帧开始时锁存到 `dac_pcm`，整个帧期间保持稳定。`audio_visualizer` 在帧结束节拍采集同一 `dac_pcm`，因此 LCD 分析的是 FPGA 实际串行发送的完整 PCM 帧，包含音源、效果器和主音量的最终结果。

## 一致性保证

每 4096 个 PCM 样本形成一个分析块，FFT 和 VU 由同一个块产生。波形连续保存最近 3 秒的历史，并在接受该分析块最后一个样本的同时截取快照，因此波形右端与 FFT 分析块具有相同的时间终点。结果先写入显示 ping-pong RAM，等 LCD `frame_sync` 到来才同时切换显示 bank，避免一帧内更新撕裂。

## 三秒滚动包络

`rolling_waveform.v` 分别为 P0 的 420 列和 P1 的 758 列持续统计 PCM 绝对峰值，包含 `-32768` 的完整幅度。每列分别对应约 `7.14 ms` 和 `3.96 ms`；时间边界使用整数相位累计，直接按系统时钟与 DAC 分频计算，不把采样率舍入为整数。窗口边缘按一列时间分辨率量化，最后一列包含尚未结束时间桶的当前峰值。

上电后从左向右绘制，有效列之后保持背景与网格；约 3 秒后窗口填满，最旧列从左侧退出，新列从右侧进入。每列从 `中线 - 幅度` 到 `中线 + 幅度` 全部填为青色，两个边缘使用同一个取整后的高度，确保上下逐像素对称。静音显示为已采集区域的中线，停止发声后旧声音仍会保留在最近 3 秒历史中并逐渐移出。

历史环形 RAM 独立于 LCD 和 FFT 持续采集；显示快照使用另一个双缓冲 RAM，在复制期间保护可见帧。冻结只停止显示发布，采集仍继续，恢复后重新显示最近历史。滚动速度受实际 LCD 刷新率限制，不是 60 fps 动画。

## 算法

1. 对采样块去直流。
2. 乘 4096 点 Hann 窗。
3. 执行 12 级 radix-2 FFT，每级缩放 1/2，防止定点溢出。
4. 计算正频率 bin 的实部平方加虚部平方。
5. P1 按对数频带取最大功率，P2 按 32 个 200 Hz 中心频带取最大功率。
6. 使用定点 leading-bit + mantissa 对数近似映射到 0..144 像素。

默认采样率为 `97.65625 kHz`，4096 点 FFT 窗长约 `41.9 ms`，FFT 间隔约 `23.84 Hz`。当前 LCD 每像素使用 20 个 50 MHz 时钟，整屏刷新约 `154 ms`（约 `6.5 fps`，另有控制开销）。波形、频谱和 VU 每帧同时更新一次；波形固定显示 3 秒历史，FFT 使用末尾完整 4096 点窗。

## 控制

- `w`：冻结/恢复可视化。
- MIDI CC28：值 0 冻结，值 1 恢复。
- 波形窗口固定为 3 秒，原 `[` / `]` 与 MIDI CC29 不再切换时基。

## 验证

`tests/test_audio_visualizer.py` 会比较 RTL 与 NumPy 参考模型，并覆盖静音、直流、负满幅、单音、双音、32 音、脉冲、满幅交替和噪声。测试还检查双缓冲、冻结、帧边界发布、VU，以及顶层 DAC 逐位解码和可视化采样的一致性。独立滚动测试覆盖 12.288 秒音频中的 10 个快照，包括空窗口、首列、时间桶闭合、3 秒边界、连续滚动、物理 RAM 回绕、静音移出和复位后不显示旧数据；P0/P1 像素检查覆盖实心填充、上下对称和未采集列留空。

在工程目录执行：

```powershell
python tests/test_audio_visualizer.py
```

需要 NumPy，以及 PATH 中可用的 `iverilog` 和 `vvp`。也可通过 `--iverilog`、`--vvp` 指定可执行文件路径。ROM 和频带映射可用 `python tools/gen_visualizer_tables.py` 重新生成。

2026-10-29 的回归覆盖 10 组 PCM，FFT 与 NumPy 双精度参考相比最大分量误差为 `7.001` 个量化计数；滚动包络的峰值、有效列和时间顺序逐列匹配 NumPy 参考结果。顶层测试还通过连续变化输入下 46 个声道的串行逐位比对，以及已发送 PCM 与可视化采集值的对应检查。

## 实机检查与限制

`tests/verify_visualizer_hardware.py` 复用现有 `screenshot_lcd.py`，依次检查 32 音输出、冻结后静音、恢复后的静音波形/频谱，以及 P2 的 32 个实测频带，并保存 PNG。它需要 pyserial、Pillow 和空闲的板载 UART 端口：

```powershell
python tests/verify_visualizer_hardware.py --port COM8
```

2026-10-29 19:42 生成滚动实心包络位流，随后成功写入开发板 SRAM。COM8 能打开，但本次截图仍未在 8 秒内收到 `IMGC` 报头，没有生成实机 PNG；此前对照仓库原位流也出现过相同的 UART 无响应。因此本次无法确认真实 LCD 画面，开发板保留本次滚动包络位流。构建、回归、截图尝试的日志分别位于 `scratch/rolling_build.log`、`scratch/rolling_tests.log` 和 `scratch/rolling_hardware.log`。待 UART 恢复后可用上面的命令完成实机回归。

同日再次按要求烧录并复测：JTAG 检出 GW5AST-138，SRAM 烧录退出码为 0，用时 29.6 秒；完整算法、滚动和顶层 DAC/像素回归再次通过。实机回归在首张截图等待 `IMGC` 时超时，重新初始化 LCD 后的快速截图也未收到 `IMGQ`。另行空闲监听及直接发送 MIDI CC25 截图请求，串口接收均为 0 字节，仍无法判定实屏显示是否正确。此次日志位于 `scratch/retest_burn.log`、`scratch/retest_algorithms.log`、`scratch/retest_hardware.log` 和 `scratch/retest_uart_probe.log`；这些串口结果不能证明 LCD 本身未显示。

同日用户反馈屏幕未亮后，临时下载 J14 基础点屏位流 `lcd_test_j14_138c_verified.fs`（User Code `0x00007203`）。用户随后确认“程序运行了，显示 spark 了”，证明该基础程序在本次连接下可以点屏；此时 COM8 仍接收 0 字节，不能用串口无回包推断屏幕未运行。随后恢复最新滚动包络位流 `lcd_ui_j14_138c_verified.fs`，下载用时 29.0 秒，回读 User Code 为 `0x00009BEB`。最新 UI 的截图仍在等待 `IMGC` 报头时超时，DTR/RTS 四种组合也均未收到数据；最新 UI 的实屏表现仍待用户确认，未通过完整实机回归。日志位于 `scratch/recovery_lcd_burn.log`、`scratch/recovery_ui_burn.log`、`scratch/recovery_ui_hardware.log` 和 `scratch/recovery_uart_control.log`。烧录脚本已将结果提示改为“SRAM 下载完成”，另行明确提示 LCD 运行状态待验证。

本次布局布线资源占用为 Logic `54754/138240`、BSRAM `112/340`、DSP `121/298`。工程当前没有完整的 SDC 时钟与多周期约束，工具按默认 `100 MHz` 分析，报告最差数据路径约 `109.6 ns`（曲目进度计算到 LCD 数据路径），存在 setup 违例。因此构建/烧录成功不等于已证明整机 `50 MHz` 时序收敛；本次确认范围为 RTL 功能和数值回归，不包含模拟 DAC 输出回采。
