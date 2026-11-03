# Spark FPGA 实时多音色合成器与 7 寸大屏触控系统 (lcd_test)

> **2026 全国大学生嵌入式芯片与系统设计竞赛（FPGA 创新设计赛道 - 高云半导体）**  
> **器件型号**：`GW5AST-LV138PG484AC1/I0`（`GW5AST-138C`，Tang Mega 138K Dock）  
> **显示交互**：7 寸 800×480 ATK-MD0700 电容触摸屏（SSD1963 16-bit 8080 + Goodix GT911 / FT5206 硬件 I2C）  
> **音频输出**：PT8211 Dual 16-bit DAC（97.656 kHz 物理采样率，3.5mm 耳机 + 板载双声道 2×3W 扬声器功放）  
> **外设阵列**：J13 硬件乐器（13 键键盘 + 6 弦光电吉他 + 激光 ToF 特雷门琴 + 4 路 EC11 正交编码器）  
> **当前状态**：**硬件电阻错焊已修正，SRAM 位流经真机全链路实测验证通过，琴键/光电/ToF/触控协同发声！**

---

## 一、 历史版本归档说明
本工程已完成架构重构与全面升级。原 Spark 历史项目（含早期示波器、FFT 模块、测试激励与历史位流）已完整归档封存：
- **完整归档压缩包**：[`../archive/fpga_spark_lcd_test_backup_20261102.zip`](file:///C:/Users/gjl50/Desktop/FPGA/fpga_spark/archive/fpga_spark_lcd_test_backup_20261102.zip)
- **解压镜像目录**：[`../archive/lcd_test_spark_v1_backup/`](file:///C:/Users/gjl50/Desktop/FPGA/fpga_spark/archive/lcd_test_spark_v1_backup)
- **归档资源清单**：[`../archive/ARCHIVE_MANIFEST.md`](file:///C:/Users/gjl50/Desktop/FPGA/fpga_spark/archive/ARCHIVE_MANIFEST.md)

---

## 二、 核心系统架构与外设矩阵

```mermaid
graph TD
    subgraph 物理输入外设矩阵 (J13 接口)
        K["13 键轻触钢琴键盘<br/>(C4 ~ C5, Pin 1-15)"]
        P["6 路红外对射光电弦<br/>(E2 ~ E4, Pin 16-21)"]
        T["激光 ToF 特雷门琴<br/>(10~70cm, Pin 24/25 & 29/30)"]
        E["4 路 EC11 正交编码器<br/>(触感音量/参数, Pin 22-40)"]
    end

    subgraph 显示与触控交互 (J14 接口)
        LCD["7 寸 800x480 仪器大屏<br/>(SSD1963 16-bit 8080)"]
        TP["电容触摸键盘 & 推子<br/>(GT911 / FT5206 I2C)"]
    end

    subgraph FPGA 纯硬件 DSP 引擎
        MGR["hw_input_mgr 仲裁 & 防抖"]
        TDM["32 复音 TDM32 合成核心<br/>(192 独立振荡器)"]
        FX["纯硬件效果器链<br/>(过载 + 4x12 箱体 + Freeverb + 合唱)"]
        DAC["PT8211 97.65 kHz DAC"]
    end

    K --> MGR
    P --> MGR
    T --> MGR
    E --> MGR
    TP --> MGR
    MGR --> TDM
    TDM --> FX
    FX --> DAC
    FX --> LCD
```

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
  - **页面 0**：主控制台看板（32 声道动态电平、实时乐器状态、效果器参数）
  - **页面 1**：实时滚动乐谱瀑布流与打谱五线谱
  - **页面 2**：3.0 秒双缓冲无损示波器与 32 通道硬件 FFT 实时频谱仪
  - **页面 3**：双通道李萨如图（Lissajous）X-Y 矢量空间分析
- **硬件电容触摸键盘**：
  - GT911 / FT5206 硬件 I2C 轮询控制器（80Hz 刷新率）
  - 屏幕虚拟琴键点按、连音滑音（Glissando）、页面选项卡与音色切换

### 3. J13 外设引脚映射总表
| J13 引脚 | FPGA 球号 | 信号名称 | 对应外设与音乐语义 |
|:---:|:---:|:---:|:---|
| **Pin 1-10** | `E14`..`B15` | `key_hw[0..9]` | 钢琴键 `key1`~`key10`（C4 ~ A4） |
| **Pin 11** | — | **NC** | 底板 5V_Peripheral（悬空） |
| **Pin 12** | — | **GND** | 逻辑地（共地） |
| **Pin 13-15** | `A16`..`A20` | `key_hw[10..12]` | 钢琴键 `key11`~`key13`（A#4 ~ C5） |
| **Pin 16-21** | `B20`..`C17` | `photo_hw[0..5]` | 光电吉他弦 1~6（E2, A2, D3, G3, B3, E4） |
| **Pin 22-23** | `D17`, `A19` | `ec1a`, `ec1b` | 编码器 #1（音量调节） |
| **Pin 24-25** | `A18`, `D15` | `scl_tof`, `sda_tof` | **ToF #1 I2C**（总线 A，特雷门琴） |
| **Pin 26-27** | `D14`, `D16` | `ec2a`, `ec2b` | 编码器 #2 |
| **Pin 28** | `E16` | **NC** | 悬空 |
| **Pin 29-30** | `F14`, `F13` | `scl_tof_b`, `sda_tof_b` | **ToF #2 I2C**（总线 B，特雷门琴备用通道） |
| **Pin 31-36** | `E17`..`D20` | `aux_io[0..5]` | AUX1~6（预留给触屏） |
| **Pin 37-38** | `D19`, `E19` | `ec3a`, `ec3b` | 编码器 #3 |
| **Pin 39-40** | `C19`, `C18` | `ec4a`, `ec4b` | 编码器 #4 |

---

## 三、 快速开发与操作指南

### 1. 一键烧录到板载 SRAM
连接 Tang Mega 138K 开发板后直接运行：
```powershell
python burn_lcd_j14.py
```

### 2. 一键编译与布局布线 (gw_sh)
```powershell
python build_j14.py
```

### 3. 在 Gowin EDA 图形界面中打开
- 双击直接打开：[`lcd_test_j14.gprj`](file:///C:/Users/gjl50/Desktop/FPGA/fpga_spark/lcd_test/lcd_test_j14.gprj)

### 4. 运行上位机实时交互控制台
```powershell
cd host
python piano_gui.py --autoconnect
```

---

## 四、 详细文档指南
完整使用操作、模式切换、音色控制及排障细节，请参阅：  
👉 [**Tang Mega 138K 多模态电子乐器与大屏交互系统使用手册 (USER_MANUAL.md)**](file:///C:/Users/gjl50/Desktop/FPGA/fpga_spark/lcd_test/docs/USER_MANUAL.md)
