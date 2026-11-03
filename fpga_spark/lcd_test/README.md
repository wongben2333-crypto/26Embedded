# Spark FPGA 实时多音色合成器与 7 寸大屏触控系统 (lcd_test)

> **2026 全国大学生嵌入式芯片与系统设计竞赛（FPGA 创新设计赛道 - 高云半导体）**  
> **器件型号**：`GW5AST-LV138PG484AC1/I0`（`GW5AST-138C`，Tang Mega 138K Dock）  
> **显示交互**：7 寸 800×480 ATK-MD0700 电容触摸屏（SSD1963 16-bit 8080 + Goodix GT911 / FT5206 硬件 I2C）  
> **音频输出**：PT8211 Dual 16-bit DAC（97.656 kHz 物理采样率）

---

## 历史版本归档说明
本工程已完成架构重构与全面升级。原 Spark 历史项目（含早期示波器、FFT 模块、测试激励与历史位流）已完整归档封存：
- **完整归档压缩包**：[`../archive/fpga_spark_lcd_test_backup_20261102.zip`](file:///C:/Users/gjl50/Desktop/FPGA/fpga_spark/archive/fpga_spark_lcd_test_backup_20261102.zip)
- **解压镜像目录**：[`../archive/lcd_test_spark_v1_backup/`](file:///C:/Users/gjl50/Desktop/FPGA/fpga_spark/archive/lcd_test_spark_v1_backup)
- **归档资源清单**：[`../archive/ARCHIVE_MANIFEST.md`](file:///C:/Users/gjl50/Desktop/FPGA/fpga_spark/archive/ARCHIVE_MANIFEST.md)

---

## 核心系统架构

### 1. 音频合成流水线
- **32 复音 TDM 架构**：32 复音 $\times$ 6 泛音 = 192 独立振荡器，单正弦 ROM 4 级流水线时分复用。
- **高保真音频输出**：97.656 kHz 采样率、PT8211 16-bit 立体声无爆音输出。
- **乐器音色库**：
  - **大钢琴 (Grand Piano)**：高次谐波指数衰减与动态触键感度。
  - **原声吉他 (Acoustic Guitar)**：含过载与 4x12 箱体 IIR 滤波。
  - **小提琴 (Violin)**：支持渐进式揉弦（Progressive Vibrato）与 Legato 连音滑音。
  - **二胡 (Erhu)**：纯硬件非线性拉弦共鸣特性。
- **纯硬件 DSP 效果器链**：
  - 立体声 Freeverb 混响（8 梳状滤波 + 4 全通滤波）
  - 立体声合唱 (Chorus) 与乒乓延迟 (Ping-Pong Delay)
  - 动态峰值均衡器 (PEQ4) 与主总线硬限幅器 (Limiter)

### 2. 7 寸大屏 UI 与电容触控
- **纯硬件 16×16 中文字符点阵引擎**（`cn_font.vh`）：无需外部字库芯片，支持多页面中文状态与参数渲染。
- **四页面大屏显示看板**：
  - 页面 0：主控制台看板（32 声道动态电平、实时乐器状态、效果器参数）
  - 页面 1：实时滚动乐谱瀑布流
  - 页面 2：3.0 秒双缓冲无损示波器与 32 通道硬件 FFT 实时频谱仪
  - 页面 3：双通道李萨如图（Lissajous）X-Y 矢量空间分析
- **硬件电容触摸键盘**：
  - GT911 / FT5206 硬件 I2C 轮询控制器（80Hz 刷新率）
  - 屏幕琴键点按、连音滑音（Glissando）、页面选项卡与音色切换

---

## 快速开发与操作指南

### 1. 一键烧录到板载 SRAM
连接 Tang Mega 138K 开发板后直接运行：
```powershell
python burn_lcd_j14.py
# 或使用 PowerShell:
.\program_sram.ps1
```

### 2. 一键编译与布局布线 (gw_sh)
```powershell
python build_j14.py
# 或使用 PowerShell:
.\build.ps1
```

### 3. 在 Gowin EDA 图形界面中打开
- 双击直接打开：[`lcd_test_j14.gprj`](file:///C:/Users/gjl50/Desktop/FPGA/fpga_spark/lcd_test/lcd_test_j14.gprj)

### 4. 运行上位机实时交互控制台
```powershell
cd host
python piano_gui.py --autoconnect
```
