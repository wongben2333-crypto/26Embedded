# Spark 历史项目归档记录 (Archive Manifest)

- **归档时间**：2026-11-02
- **归档原因**：同步并迁移队友 Hank 最新的 32 复音 TDM 合成器、97.6kHz 高清音频、GT911/FT5206 电容触摸键盘、7寸大屏 UI（含 16×16 中文字符点阵引擎与三段式示波器/频谱分析仪）全新架构。原 Spark 项目（基于 `lcd_test`）完成阶段性开发与验证，现完整归档封存。

---

## 归档目录结构与资源

### 1. 归档包文件
- **完整压缩包**：`fpga_spark_lcd_test_backup_20261102.zip` (~91 MB)
  - 包含全部源代码、约束、测试脚本、仿真波形、文档与已验证位流。
- **解压镜像目录**：`lcd_test_spark_v1_backup/`

### 2. 核心模块与位流指纹
- **位流文件**：
  - `bitstream/lcd_ui_j14_138c_verified.fs`：7寸屏 J14 双缓冲测试位流
  - `bitstream/lcd_test_j14_138c_verified.fs`：含按键交互与波形显示的已验证位流
- **顶层模块**：
  - `rtl/lcd_test_top.v`
- **合成器与效果器**：
  - `rtl/synth/piano_engine.v`、`adsr.v`、`song_player.v`、`tone_bank.v`、`wave_rom.v`
  - `rtl/effects/audio_fx.v`、`guitar_fx.v`、`cab_sim.v`
- **可视化模块**：
  - `rtl/visualizer/audio_visualizer.v`、`rolling_waveform.v`、`fft4096.v`
- **约束文件**：
  - `constraints/lcd_test_j14.cst`（ATK-MD0700 7寸电容屏 J14 引脚分配）
  - `constraints/lcd_test_j14.sdc`（50MHz 时钟约束）
- **上位机与烧录工具**：
  - `fpga_synth_host.py`（上位机 MIDI 与音频控制）
  - `burn_lcd_j14.py`（一键烧录 SRAM）
  - `screenshot_lcd.py`（UART 屏幕回读与截图）

---

## 恢复说明
若需重新回测或提取原 Spark 历史项目的任意模块：
1. 直接在 `archive/lcd_test_spark_v1_backup/` 目录下查看与复制；
2. 或解压 `fpga_spark_lcd_test_backup_20261102.zip` 即可恢复至独立的开发工程。
