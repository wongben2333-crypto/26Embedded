# 7 寸屏 ATK-MD0700 V2.4（34P）↔ 底板 J13（40P 排针）接线表

> **屏幕**：正点原子 ATK-MD0700 V2.4，7 寸 800×480，**SSD1963** 控制器，34P **2×17 排针**
> **底板**：Sipeed Tang Mega 60K/138K **NEO Dock**（31004 / 31005）
> **依据**：官方手册《高性能 7.0'TFTLCD 电容触摸屏模块》表 2.1.1 + `ATK-MD0700_V2.4.pdf` 第 1 页（P1）+ `Tang_Mega_NEO_Dock-60K_31004_底板原理图.pdf` 第 19 页（J13）+ 官方 `tang_mega_60K/138K_pins.cst`
> **整理日期**：2026-10-21 ｜ **状态**：两侧引脚均已按手册表 + 原理图坐标双向核对，**尚未实物验证**

---

## 0. 更正记录（重要）

| 版本 | 问题 | 现状 |
|---|---|---|
| v1 | 按 J5（0.5mm FPC）写的 | 作废。底板有两个 40P，要用 **J13** |
| v2 | 屏幕 22–34 脚**整体错位 2 个位置**：误把 GND 当 25、5V 当 26、触摸信号当 28/29/31/32 | **本版已修正**。正确是 GND=22/26/27、5V=28、触摸=30/31/33/34 |

> 错因：从原理图按文字坐标反推时，尾部几个网络标签的纵向偏移规律变了，我按"凑满 34 脚"的方式倒推，结果整体前移了两格。
> 现在以**官方手册表 2.1.1 为准**，并已用原理图坐标逐条复核，两者完全一致。

### 底板两个 40P 别搞混

| 连接器 | 类型 | 实际用途 |
|---|---|---|
| J5 | `FPC-40P-0.5MM` 软排线座 | RGB565 / CH569-HSPI 屏口（R0/R1/G0/G1/B0/B1 硬接地）—— 接不了这块 8080 屏 |
| **J13** | `TH_PIN_2x20_2.54mm` 排针 | **SDRAM0 扩展口** —— **用这个** |
| J14 | `TH_PIN_2x20_2.54mm` 排针 | SDRAM1 口，与 DVP_CAM/PMOD 复用 |

---

## 1. 屏幕侧：34P 排针 P1 定义（官方手册表 2.1.1）

| 序号 | 名称 | 说明 |
|:--:|---|---|
| 1 | `NCE` | LCD 片选，**低有效** |
| 2 | `RS` | 命令/数据：**0=命令，1=数据** |
| 3 | `WR` | 写使能，**低有效** |
| 4 | `RD` | 读使能，**低有效** |
| 5 | `RST` | 复位，**低有效** |
| 6–21 | `D0`–`D15` | **双向数据总线**（6=D0，7=D1，…，21=D15） |
| **22** | `GND` | 电源地 |
| 23 | `TE` | 撕裂效应信号（屏→MCU），一般不用 |
| 24 | `NC` | 未连接 |
| 25 | `NC` | 未连接 |
| **26** | `GND` | 电源地 |
| **27** | `GND` | 电源地 |
| **28** | `5V` | **LCD 背光供电（5V）** |
| 29 | `M1` | **未连接**（手册印作 `MI`，实为电阻屏 MISO 位置；电容版不用） |
| **30** | `M0` | **触摸 I2C 数据 SDA**（手册印作 `MO`，实为电阻屏 MOSI 位置） |
| **31** | `PEN` | **触摸中断：0=有触摸，1=无触摸**（低有效） |
| 32 | `NC` | 未连接（原理图上标 `MD_BUSY`，电容版不用） |
| **33** | `TCS` | **触摸复位，低有效** |
| **34** | `CLK` | **触摸 I2C 时钟 SCL** |

> ⚠️ **29/30 的丝印是 `M1` / `M0`（数字 1 和 0），不是字母 `MI` / `MO`。**
> 官方手册里印成 `MI` / `MO` 是字形混淆（I↔1、O↔0）。含义仍是 **MISO / MOSI** 的简写位置：
> 电阻屏版本这两脚是 SPI 的 MISO/MOSI；**电容触摸版本** `M0` 被改作 I2C 的 SDA，`M1` 空置。

> 手册原文把 22/26/27 归为"电源地"，24/25/32 归为"未连接"。
> 模块已自带 **4.7k I2C 上拉**（R13/R15→VCC3.3），FPGA 侧**不要**再加。

---

## 2. 底板 J13：40P 排针定义（SDRAM0 扩展口）

| Pin | 网络 | FPGA | | Pin | 网络 | FPGA |
|:--:|---|:--:|---|:--:|---|:--:|
| 1 | SDRAM0_D0 | **E14** | | 2 | SDRAM0_D1 | **E13** |
| 3 | SDRAM0_D2 | **C15** | | 4 | SDRAM0_D3 | **C14** |
| 5 | SDRAM0_D4 | **B13** | | 6 | SDRAM0_D5 | **C13** |
| 7 | SDRAM0_D6 | **A14** | | 8 | SDRAM0_D7 | **A13** |
| 9 | SDRAM0_D15 | **B16** | | 10 | SDRAM0_D14 | **B15** |
| **11** | **5V_Peripheral** | — | | **12** | **GND** | — |
| 13 | SDRAM0_D13 | **A16** | | 14 | SDRAM0_D12 | **A15** |
| 15 | SDRAM0_D11 | **A20** | | 16 | SDRAM0_D10 | **B20** |
| 17 | SDRAM0_D9 | **A21** | | 18 | SDRAM0_D8 | **B21** |
| 19 | SDRAM0_A12 | **B18** | | 20 | SDRAM0_CLK | **B17** |
| 21 | SDRAM0_A9 | **C17** | | 22 | SDRAM0_A11 | **D17** |
| 23 | SDRAM0_A7 | **A19** | | 24 | SDRAM0_A8 | **A18** |
| 25 | SDRAM0_A5 | **D15** | | 26 | SDRAM0_A6 | **D14** |
| 27 | SDRAM0_~WE | **D16** | | 28 | SDRAM0_A4 | **E16** |
| 29 | SDRAM0_EXIO0 | *cst 无* | | 30 | SDRAM0_EXIO1 | *cst 无* |
| 31 | SDRAM0_~CAS | **E17** | | 32 | SDRAM0_~RAS | **F16** |
| 33 | SDRAM0_~CS | **F19** | | 34 | SDRAM0_BA0 | **F15** |
| 35 | SDRAM0_BA1 | **C20** | | 36 | SDRAM0_A10 | **D20** |
| 37 | SDRAM0_A0 | **D19** | | 38 | SDRAM0_A1 | **E19** |
| 39 | SDRAM0_A2 | **C19** | | 40 | SDRAM0_A3 | **C18** |

> 引脚号来自官方 `.cst` 的 `sdram_*` 段；已交叉验证（`SDRAM0_D0→E14`、`SDRAM0_A0→D19` 与原理图第 7 页 `SOM_BTB1-2` 球位标注一致）。
> 全部 **LVCMOS33 / 3.3V**，与屏幕 IO 电平一致，**不需要电平转换**。
> `EXIO0/EXIO1`（pin29/30）官方 cst 未定义，**不要用**。

---

## 3. 推荐接线表（照这张接）

| 屏幕 34P | 名称 | → | J13 | 网络 | FPGA |
|:--:|---|:--:|:--:|---|:--:|
| 1 | `NCE`（CS） | → | **33** | SDRAM0_~CS | **F19** |
| 2 | `RS`（D/C） | → | **31** | SDRAM0_~CAS | **E17** |
| 3 | `WR` | → | **27** | SDRAM0_~WE | **D16** |
| 4 | `RD` | → | **36** | SDRAM0_A10 | **D20** |
| 5 | `RST` | → | **32** | SDRAM0_~RAS | **F16** |
| 6 | `D0` | → | **1** | SDRAM0_D0 | **E14** |
| 7 | `D1` | → | **2** | SDRAM0_D1 | **E13** |
| 8 | `D2` | → | **3** | SDRAM0_D2 | **C15** |
| 9 | `D3` | → | **4** | SDRAM0_D3 | **C14** |
| 10 | `D4` | → | **5** | SDRAM0_D4 | **B13** |
| 11 | `D5` | → | **6** | SDRAM0_D5 | **C13** |
| 12 | `D6` | → | **7** | SDRAM0_D6 | **A14** |
| 13 | `D7` | → | **8** | SDRAM0_D7 | **A13** |
| 14 | `D8` | → | **18** | SDRAM0_D8 | **B21** |
| 15 | `D9` | → | **17** | SDRAM0_D9 | **A21** |
| 16 | `D10` | → | **16** | SDRAM0_D10 | **B20** |
| 17 | `D11` | → | **15** | SDRAM0_D11 | **A20** |
| 18 | `D12` | → | **14** | SDRAM0_D12 | **A15** |
| 19 | `D13` | → | **13** | SDRAM0_D13 | **A16** |
| 20 | `D14` | → | **10** | SDRAM0_D14 | **B15** |
| 21 | `D15` | → | **9** | SDRAM0_D15 | **B16** |
| **28** | **`5V`** | → | **11** | **5V_Peripheral** | — |
| **22 / 26 / 27** | **`GND`** | → | **12** | GND | — |
| **30** | **`M0`（SDA）** | → | **37** | SDRAM0_A0 | **D19** |
| **34** | **`CLK`（SCL）** | → | **38** | SDRAM0_A1 | **E19** |
| **31** | **`PEN`（INT）** | → | **39** | SDRAM0_A2 | **C19** |
| **33** | **`TCS`（触摸 RST）** | → | **40** | SDRAM0_A3 | **C18** |
| 23 / 24 / 25 / 29 / 32 | `TE` / NC / NC / `M1` / NC | — | 悬空 | — | — |

**占用**：16 数据 + 5 控制 + 4 触摸 = **25 个 IO**，另加 5V、GND 各 1 根。
**富余**：J13 还剩 **A4–A9、A11、A12、BA0、BA1、CLK**（pin 19–26、28、34、35）等 12 个脚，可留给按键 / 编码器 / WS2812。

> ⚠️ **J13 只有 1 根 GND（pin12）**，而屏幕有 **3 个 GND（22/26/27）**。三根并起来接 pin12，**再从板上另找一处 GND 补一根**——16 位并口在 10MHz 级别，地回流不够会出花屏。

---

## 4. 可直接用的 `.cst` 片段

```tcl
//====== LCD 8080 (ATK-MD0700 via Dock J13) ======
IO_LOC  "lcd_db[0]"  E14;
IO_LOC  "lcd_db[1]"  E13;
IO_LOC  "lcd_db[2]"  C15;
IO_LOC  "lcd_db[3]"  C14;
IO_LOC  "lcd_db[4]"  B13;
IO_LOC  "lcd_db[5]"  C13;
IO_LOC  "lcd_db[6]"  A14;
IO_LOC  "lcd_db[7]"  A13;
IO_LOC  "lcd_db[8]"  B21;
IO_LOC  "lcd_db[9]"  A21;
IO_LOC  "lcd_db[10]" B20;
IO_LOC  "lcd_db[11]" A20;
IO_LOC  "lcd_db[12]" A15;
IO_LOC  "lcd_db[13]" A16;
IO_LOC  "lcd_db[14]" B15;
IO_LOC  "lcd_db[15]" B16;

IO_LOC  "lcd_cs"     F19;
IO_LOC  "lcd_rs"     E17;
IO_LOC  "lcd_wr"     D16;
IO_LOC  "lcd_rd"     D20;
IO_LOC  "lcd_rst"    F16;

IO_LOC  "ct_sda"     D19;
IO_LOC  "ct_scl"     E19;
IO_LOC  "ct_int"     C19;
IO_LOC  "ct_rst"     C18;

IO_PORT "lcd_db[0]"  IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=8 BANK_VCCIO=3.3;
IO_PORT "lcd_db[1]"  IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=8 BANK_VCCIO=3.3;
IO_PORT "lcd_db[2]"  IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=8 BANK_VCCIO=3.3;
IO_PORT "lcd_db[3]"  IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=8 BANK_VCCIO=3.3;
IO_PORT "lcd_db[4]"  IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=8 BANK_VCCIO=3.3;
IO_PORT "lcd_db[5]"  IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=8 BANK_VCCIO=3.3;
IO_PORT "lcd_db[6]"  IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=8 BANK_VCCIO=3.3;
IO_PORT "lcd_db[7]"  IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=8 BANK_VCCIO=3.3;
IO_PORT "lcd_db[8]"  IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=8 BANK_VCCIO=3.3;
IO_PORT "lcd_db[9]"  IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=8 BANK_VCCIO=3.3;
IO_PORT "lcd_db[10]" IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=8 BANK_VCCIO=3.3;
IO_PORT "lcd_db[11]" IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=8 BANK_VCCIO=3.3;
IO_PORT "lcd_db[12]" IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=8 BANK_VCCIO=3.3;
IO_PORT "lcd_db[13]" IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=8 BANK_VCCIO=3.3;
IO_PORT "lcd_db[14]" IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=8 BANK_VCCIO=3.3;
IO_PORT "lcd_db[15]" IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=8 BANK_VCCIO=3.3;

IO_PORT "lcd_cs"     IO_TYPE=LVCMOS33 PULL_MODE=UP   DRIVE=8 BANK_VCCIO=3.3;
IO_PORT "lcd_rs"     IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=8 BANK_VCCIO=3.3;
IO_PORT "lcd_wr"     IO_TYPE=LVCMOS33 PULL_MODE=UP   DRIVE=8 BANK_VCCIO=3.3;
IO_PORT "lcd_rd"     IO_TYPE=LVCMOS33 PULL_MODE=UP   DRIVE=8 BANK_VCCIO=3.3;
IO_PORT "lcd_rst"    IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=8 BANK_VCCIO=3.3;

IO_PORT "ct_sda"     IO_TYPE=LVCMOS33 PULL_MODE=UP   DRIVE=8   BANK_VCCIO=3.3;
IO_PORT "ct_scl"     IO_TYPE=LVCMOS33 PULL_MODE=UP   DRIVE=8   BANK_VCCIO=3.3;
IO_PORT "ct_int"     IO_TYPE=LVCMOS33 PULL_MODE=UP   DRIVE=OFF BANK_VCCIO=3.3;
IO_PORT "ct_rst"     IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=8   BANK_VCCIO=3.3;
```

> `lcd_cs` / `lcd_wr` / `lcd_rd` 用 `PULL_MODE=UP`：复位期间与未初始化时保持高（不选中、不写、不读），避免上电瞬间误发命令。

---

## 5. 电源、复位、背光

### 5.1 电源
- 屏幕 `5V`（**pin28**）→ J13 **pin11 `5V_Peripheral`**
- 该 5V 来自板载 SY8105（5V/5A）经 1A 功率开关，驱动这块屏（约 0.3~0.6A）够用
- **不要**接 +3V3；也**不要**用 J13 以外的随机 5V 点

### 5.2 复位
- `RST`（pin5）接 J13 pin32 → `F16`，**FPGA 可控**
- 上电时序：给 5V → 等 ≥10ms → 拉低 `lcd_rst` ≥10µs → 释放 → 等 ≥120ms 再发初始化命令

### 5.3 背光（**最容易误判"屏坏了"**）
- 背光**没有独立引脚**，由 **SSD1963 内部 PWM 寄存器**经 `LCD_BL` 驱动 MP3302 的 EN
- 原理图上 `LCD_BL` 有 **4.7k 下拉到地**，**默认灭**
- ⇒ 初始化里**必须**写：
  ```
  0xBE, 0x05, <亮度 0~255>, 0x01, 0xFF, 0x00, 0x00
  ```
  （取自官方 `atk_md0700_backlight_config()`）

---

## 6. 8080 写时序建议

手册 2.2 节写明：SSD1963 支持 **8/9/12/16 位 8080** 并口。我们走 16 位。

| 参数 | 建议值（50MHz 主时钟） | 说明 |
|---|---|---|
| 一个写周期 | **3~4 clk（60~80 ns）** | SSD1963 `tWC` 约 33ns，留余量 |
| `WR` 低脉宽 | ≥ 2 clk（40 ns） | 数据在 `WR` 上升沿锁存 |
| `CS` | 连续写像素时**保持低** | 显著提速 |
| `RS` | 命令前拉低、数据前拉高，与 `WR` 同拍切换 | 注意 `tCS`/`tAS` 建立时间 |
| 全屏刷新 | 384000 次写 × 60~80 ns ≈ **23~31 ms → 约 32~43 fps** | 800×480 / 16bpp |

**初始化最少几步**（其余照 `atk_md0700_reg_init()` 抄）：
`0xE2` 软复位 → `0xE0` 设 PLL → `0x01` 软复位 → `0xE6` 设像素时钟 → `0x2A/0x2B` 设 800×480 窗口 → `0xB0` 设 16 位 8080/RGB565 → **`0xBE 0x05` 开背光** → `0x29` 开显示

**第一步先做"读 ID"自检**：发 `0xA1` 应返回 `0x0000`，能读到就说明 16 根数据 + CS/RS/RD 全通。

---

## 7. 风险清单

| # | 风险 | 说明 |
|---|---|---|
| 1 | **J13 是 SDRAM0 总线** | 用了这 40 个脚，就不能再挂 SDRAM0 模块。若要做帧缓冲需另想办法 |
| 2 | **J14 与 DVP_CAM/PMOD 复用** | 别为了"留 J13"而换 J14 |
| 3 | **GND 只有 1 根** | 16 位并口建议补一根板级 GND |
| 4 | **数据位序接反** | 屏能亮但颜色错乱 → 先刷纯红/绿/蓝自测 |
| 5 | **背光不亮 ≠ 屏坏** | 90% 是没写 `0xBE 0x05` |
| 6 | **刷新率上限** | 8080 并口做频谱/波形够用，全屏动画会掉帧 |
| 7 | **与音频通路抢时序** | 8080 控制器很轻（几百 LUT），但每帧 384k 次写占大量时钟；建议独立时钟域 + 双缓冲 |

---

## 8. 上电前核对清单

- [ ] 屏幕 `5V` 接的是 **pin28**，不是 pin26（pin26 是 GND，接错会短路 5V）
- [ ] 屏幕 3 个 GND（**22/26/27**）并接 J13 **pin12**，并额外补一根板级 GND
- [ ] D0–D15 与 J13 pin 1–10、13–18 按表一一对应（**最容易错**）
- [ ] 触摸四根：**30(M0)=SDA、31(PEN)=INT、33(TCS)=RST、34(CLK)=SCL**（这四根最易错位）
- [ ] 24 / 25 / 29 / 32 悬空
- [ ] `EX_RD` 接 J13 pin36（或恒接 3.3V）
- [ ] 上电前万用表量 `5V_Peripheral` 对 GND 不短路
- [ ] `.cst` 里没有和 SDRAM / DVP_CAM / PMOD 重复占用同一引脚

---

## 附录 A：另一种"紧凑分配"方案（同样成立）

J13 的 40 个脚其实是 **38 个 3.3V 通用 IO ＋ 1 个 5V ＋ 1 个 GND**（IO 恰好挂着 SDRAM0 的名字），所以**信号怎么分配是自由的**。下面这套把全部 LCD 信号压缩在 **J13 pin 1–28**，留出 29–40 给别的外设，电气上完全成立。

> ⚠️ 注意"3.3V IO"说的是**电平**（`LVCMOS33` / `BANK_VCCIO=3.3`），**不是**"这个脚能当 3.3V 电源用"。
> J13 上的电源脚只有两个：**pin11 = 5V_Peripheral**、**pin12 = GND**。**没有任何 3.3V 电源脚。**

> 与正文方案的区别只是"挑哪几个脚"，**不是对错**。正文方案让数据线在丝印上"名字对得上"（D0 接丝印 D0），查线不易错；本方案线束更集中。

| 信号 | J13 | 屏幕 P1 | J13 实际网络 | FPGA |
|---|:--:|:--:|---|:--:|
| `LCD_CS` | 1 | 1 | SDRAM0_D0 | E14 |
| `LCD_RS` | 2 | 2 | SDRAM0_D1 | E13 |
| `LCD_WR` | 3 | 3 | SDRAM0_D2 | C15 |
| `LCD_RD` | 4 | 4 | SDRAM0_D3 | C14 |
| `LCD_RST` | 5 | 5 | SDRAM0_D4 | B13 |
| `LCD_D0` | 6 | 6 | SDRAM0_D5 | C13 |
| `LCD_D1` | 7 | 7 | SDRAM0_D6 | A14 |
| `LCD_D2` | 8 | 8 | SDRAM0_D7 | A13 |
| `LCD_D3` | 9 | 9 | SDRAM0_D15 | B16 |
| `LCD_D4` | 10 | 10 | SDRAM0_D14 | B15 |
| `LCD_D5` | 13 | 11 | SDRAM0_D13 | A16 |
| `LCD_D6` | 14 | 12 | SDRAM0_D12 | A15 |
| `LCD_D7` | 15 | 13 | SDRAM0_D11 | A20 |
| `LCD_D8` | 16 | 14 | SDRAM0_D10 | B20 |
| `LCD_D9` | 17 | 15 | SDRAM0_D9 | A21 |
| `LCD_D10` | 18 | 16 | SDRAM0_D8 | B21 |
| `LCD_D11` | 19 | 17 | SDRAM0_A12 | B18 |
| `LCD_D12` | 20 | 18 | SDRAM0_CLK | B17 |
| `LCD_D13` | 21 | 19 | SDRAM0_A9 | C17 |
| `LCD_D14` | 22 | 20 | SDRAM0_A11 | D17 |
| `LCD_D15` | 23 | 21 | SDRAM0_A7 | A19 |
| `LCD_TE` | 24 | 23 | SDRAM0_A8 | A18 |
| `TP_SDA` | 25 | 30（丝印 M0） | SDRAM0_A5 | D15 |
| `TP_SCL` | 26 | 34 | SDRAM0_A6 | D14 |
| `TP_INT` | 27 | 31 | SDRAM0_~WE | D16 |
| `TP_RST` | 28 | 33 | SDRAM0_A4 | E16 |
| `VCC_5V` | **11** | 28 | 5V_Peripheral | — |
| `GND` | **12** | 22 / 26 / 27 | GND | — |

```tcl
//====== 紧凑方案（附录 A）======
IO_LOC  "lcd_cs"     E14;
IO_LOC  "lcd_rs"     E13;
IO_LOC  "lcd_wr"     C15;
IO_LOC  "lcd_rd"     C14;
IO_LOC  "lcd_rst"    B13;
IO_LOC  "lcd_db[0]"  C13;
IO_LOC  "lcd_db[1]"  A14;
IO_LOC  "lcd_db[2]"  A13;
IO_LOC  "lcd_db[3]"  B16;
IO_LOC  "lcd_db[4]"  B15;
IO_LOC  "lcd_db[5]"  A16;
IO_LOC  "lcd_db[6]"  A15;
IO_LOC  "lcd_db[7]"  A20;
IO_LOC  "lcd_db[8]"  B20;
IO_LOC  "lcd_db[9]"  A21;
IO_LOC  "lcd_db[10]" B21;
IO_LOC  "lcd_db[11]" B18;
IO_LOC  "lcd_db[12]" B17;
IO_LOC  "lcd_db[13]" C17;
IO_LOC  "lcd_db[14]" D17;
IO_LOC  "lcd_db[15]" A19;
IO_LOC  "lcd_te"     A18;
IO_LOC  "ct_sda"     D15;
IO_LOC  "ct_scl"     D14;
IO_LOC  "ct_int"     D16;
IO_LOC  "ct_rst"     E16;
```

### 🔴 这套方案里有两个**必须避开**的坑

| 误接 | J13 该脚真实身份 | 后果 |
|---|---|---|
| 把 **pin 35** 当 3.3V 电源 | `SDRAM0_BA1`（球位 **C20**，普通 IO） | FPGA 输出高时被外部拉低 → **IO 短路，可能烧脚** |
| 把 **pin 39** 当 GND | `SDRAM0_A2`（球位 **C19**，普通 IO） | FPGA 输出高时直接对地短路 → **同上，风险更大** |

**J13 上只有 pin11（5V）和 pin12（GND）两个电源脚，没有任何 3.3V。**
要点板载 LED，别去找 3.3V 电源脚 —— 直接用 J13 剩余的空闲 IO（如 pin 29–40 中的任意脚）驱动 LED，串 1kΩ 到 GND 即可，还能软件控制亮灭。

**真需要 3.3V 电源时去哪取**：底板 **J8（`PinSocket_Horizontal_2x6P_2.54mm`，PMOD1 座）**

| J8 脚位 | 网络 |
|:--:|---|
| 1 / 2 | **+3V3** |
| 3 / 4 | **GND** |
| 5 / 6 | PMOD1_IO6 / PMOD1_IO7 |
| 7 / 8 | PMOD1_IO4 / PMOD1_IO5 |
| 9 / 10 | PMOD1_IO2 / PMOD1_IO3 |

（J9 为同款 PMOD0 座，脚位一致，上电前用万用表复核一下更稳。）

---

## 9. 🔴 危险引脚清单：连错会烧板

> 判据：**只有"电源/地"接错才会烧**；信号与信号之间接错最多不工作。所以下面按"烧毁风险"排序，而不是按信号重要性。

### 9.1 一级危险：5V 与 GND 相邻，错一格就是直接短路

| 位置 | 相邻关系 | 错法 | 后果 |
|---|---|---|---|
| **J13 pin 11 / pin 12** | **5V_Peripheral 紧挨 GND** | 整体偏一格 | 5V 直接对地。板载 5V 是 SY8105（5A）+ 1A 功率开关，短路电流可达数安，**烧线/烧排针/烧功率开关** |
| **屏幕 P1 pin 26 / 27 / 28** | **GND、GND、5V 三连** | 把 5V 落到 27 或 26 | 同上，且是在屏幕排针上短路 |

**这是最容易犯、后果最重的错**——两个连接器的 5V 都恰好贴着 GND。

> 上电前必做：万用表电阻档量 **J13 pin11 ↔ pin12**，不应接近 0Ω。

### 9.2 二级危险：把 5V 或 GND 当成普通 IO

| 错法 | 后果 |
|---|---|
| 把 **J13 pin 11（5V）** 接到屏幕的数据/控制脚 | **5V 打进 SSD1963 的 3.3V IO**，控制器直接击穿 |
| 把 **J13 pin 35 / pin 39** 当 3.3V 或 GND | 这两脚是 `SDRAM0_BA1`(C20) / `SDRAM0_A2`(C19)，是 **FPGA 输出脚**。输出高时被外部拉低/拉地 → **IO 过流，可能烧脚** |
| 把 GND 接到任意一根**正在输出高电平**的 IO | 同上，输出对地短路 |

**FPGA 的 3.3V 组 IO 耐压上限约 3.6V（VCCIO+0.3V），5V 直接击穿，且不耐 5V 输入。**

### 9.3 三级危险（隐蔽）：屏幕的 5V 脚被 FPGA IO 驱动

- 屏幕 **P1 pin28** 是模块的 **5V 输入**，模块要从这里抽 **0.3~0.6A**（LDO + 背光升压）
- 若误接到某个 FPGA IO（以为是普通信号脚）→ IO 只能给十几 mA，**拉不起来，且长时间过流会烧 IO**
- **判据：P1 pin28 必须且只能来自 J13 pin11**

### 9.4 不会烧、只是不工作的（可以放心排查）

| 错法 | 现象 |
|---|---|
| 数据线 D0–D15 之间互错 | 能点亮，但**颜色错乱**（先刷纯红/绿/蓝定位） |
| CS/RS/WR/RD 互错 | 花屏、不亮、或只显示雪花 |
| 触摸 4 根（30/31/33/34）互错 | 触摸无反应，或 I2C 扫不到地址 |
| TE 没接 | 完全没影响 |

### 9.5 上电前 3 道检查（按顺序做）

1. **断电**，万用表电阻档：`J13 pin11 ↔ pin12` 不短路；`P1 pin28 ↔ P1 pin26` 不短路
2. **断电**，通断档逐根确认：
   - `P1 pin28` ↔ `J13 pin11`（5V）
   - `P1 pin22 / 26 / 27` ↔ `J13 pin12`（GND）
   - 除这 4 根外，**屏幕任何脚都不应通到 J13 pin11 或 pin12**
3. **上电**（先不插屏），万用表量 `J13 pin11` 对地 = **5V ±5%**；确认无误再插屏

### 9.6 两条纪律

- **不要带电插拔**：热插拔时 5V 可能先到、地后到，浪涌会打 IO
- **不要从外部再往 J13 pin11 灌 5V**：那是板子输出的 5V 轨，双电源会打架

- [ ] 第一次上电先只做"读 ID"，不刷图
