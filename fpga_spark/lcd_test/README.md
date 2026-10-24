# ATK-MD0700 (SSD1963) 7 寸 RGB LCD 屏幕使用与驱动说明

> **适用硬件**：Sipeed **Tang Mega 138K NEO Dock**（31005）+ 正点原子 **ATK-MD0700 V2.4**（7 寸 800×480，SSD1963 控制器，16-bit 8080 并口）  
> **最后更新**：2026-10-23  
> **当前状态**：✅ **已点亮并稳定运行**，默认显示 **"spark" Logo，逐字母配色**（s 青 / p 绿 / a 黄 / r 橙 / k 品红，深蓝渐变背景），支持板载串口实时回读 SSD1963 寄存器与显存状态。
>
> 画面效果预览见 [`docs_spark_preview.png`](docs_spark_preview.png)。

---

## 1. 硬件配置与连接

| 项目 | 型号 / 参数 | 说明 |
|---|---|---|
| **FPGA 底板** | Sipeed **Tang Mega 138K NEO Dock** (31005) | 核心板器件：`GW5AST-LV138PG484AC1/I0`（即 **GW5AST-138C**，封装 PBGA484A） |
| **系统时钟** | `50 MHz` (`V22`) | 板载晶振输入，约束为 `LVCMOS33` |
| **屏幕模块** | 正点原子 **ATK-MD0700 V2.4** | 7.0 寸 800×480 RGB TFT，内置 **SSD1963** 控制器 + **MP3302DJ** 背光升压芯片 |
| **连接接口** | 底板 **J13**（2×20 排针，SDRAM0 扩展口）↔ 屏幕 **P1**（2×17 排针） | 20 cm 杜邦线直连 |
| **供电方式** | 底板 `J13 Pin 11 (5V)` + `Pin 12 (GND)`（或外部独立 5V 共地） | ⚠️ 若使用单根杜邦线从 J13 取 5V，背光占空比建议设为 `0x18`~`0x30` 以免线损压降过大；若用外部 5V 供电，请拔掉 J13 Pin 11 防止两路 5V 互灌 |
| **板载状态灯** | **WS2812B-2020 (`U15`)**，球位 **`J16`** | 位于底板正面右下角，随当前显示帧颜色同步指示状态 |
| **板载调试串口** | `FPGA_UART.TX` = 球位 **`U15`**（直连 BL616 `IO27_RX`） | 通过底板 **USB2 (J7)** 接口在电脑端枚举为双串口（通常为 `COM8`，`115200 8N1`） |

---

## 2. 完整引脚接线表（J13 ↔ 屏幕 P1 ↔ FPGA 球位）

| FPGA 端口名 | 功能说明 | FPGA 球位 | 底板 J13 脚号 | 屏幕 P1 脚号 | 屏幕丝印 | I/O 约束 (`LVCMOS33`) |
|---|---|---|---|---|---|---|
| `lcd_cs` | 8080 片选（低有效） | `E14` | Pin 1 | Pin 1 | `CS` | `PULL_MODE=UP DRIVE=4` |
| `lcd_rs` | 命令/数据选择（`0`=命令，`1`=数据） | `E13` | Pin 2 | Pin 2 | `RS` | `PULL_MODE=NONE DRIVE=4` |
| `lcd_wr` | 8080 写脉冲（上升沿锁存） | `C15` | Pin 3 | Pin 3 | `WR` | `PULL_MODE=UP DRIVE=4` |
| `lcd_rd` | 8080 读脉冲（低电平驱动） | `C14` | Pin 4 | Pin 4 | `RD` | `PULL_MODE=UP DRIVE=4` |
| `lcd_rst` | 硬件复位（低有效） | `B13` | Pin 5 | Pin 5 | `RST` | `PULL_MODE=UP DRIVE=16` |
| `lcd_db[0]` | 数据总线 Bit 0 (`B0` / 命令 Bit 0) | `C13` | Pin 6 | Pin 6 | `D0` | `PULL_MODE=UP DRIVE=4` |
| `lcd_db[1]` | 数据总线 Bit 1 (`B1` / 命令 Bit 1) | `A14` | Pin 7 | Pin 7 | `D1` | `PULL_MODE=UP DRIVE=4` |
| `lcd_db[2]` | 数据总线 Bit 2 (`B2` / 命令 Bit 2) | `A13` | Pin 8 | Pin 8 | `D2` | `PULL_MODE=UP DRIVE=4` |
| `lcd_db[3]` | 数据总线 Bit 3 (`B3` / 命令 Bit 3) | `B16` | Pin 9 | Pin 9 | `D3` | `PULL_MODE=UP DRIVE=4` |
| `lcd_db[4]` | 数据总线 Bit 4 (`B4` / 命令 Bit 4) | `B15` | Pin 10 | Pin 10 | `D4` | `PULL_MODE=UP DRIVE=4` |
| — | **+5V 电源** | `5V` | **Pin 11** | **Pin 28** | `5V` | 电源正极 |
| — | **数字地** | `GND` | **Pin 12** | **Pin 22/26/27** | `GND` | 必须可靠共地 |
| `lcd_db[5]` | 数据总线 Bit 5 (`G0` / 命令 Bit 5) | `A16` | Pin 13 | Pin 11 | `D5` | `PULL_MODE=UP DRIVE=4` |
| `lcd_db[6]` | 数据总线 Bit 6 (`G1` / 命令 Bit 6) | `A15` | Pin 14 | Pin 12 | `D6` | `PULL_MODE=UP DRIVE=4` |
| `lcd_db[7]` | 数据总线 Bit 7 (`G2` / 命令 Bit 7) | `A20` | Pin 15 | Pin 13 | `D7` | `PULL_MODE=UP DRIVE=4` |
| `lcd_db[8]` | 数据总线 Bit 8 (`G3`) | `B20` | Pin 16 | Pin 14 | `D8` | `PULL_MODE=UP DRIVE=4` |
| `lcd_db[9]` | 数据总线 Bit 9 (`G4`) | `A21` | Pin 17 | Pin 15 | `D9` | `PULL_MODE=UP DRIVE=4` |
| `lcd_db[10]` | 数据总线 Bit 10 (`G5`) | `B21` | Pin 18 | Pin 16 | `D10` | `PULL_MODE=UP DRIVE=4` |
| `lcd_db[11]` | 数据总线 Bit 11 (`R0`) | `B18` | Pin 19 | Pin 17 | `D11` | `PULL_MODE=UP DRIVE=4` |
| `lcd_db[12]` | 数据总线 Bit 12 (`R1`) | `B17` | Pin 20 | Pin 18 | `D12` | `PULL_MODE=UP DRIVE=4` |
| `lcd_db[13]` | 数据总线 Bit 13 (`R2`) | `C17` | Pin 21 | Pin 19 | `D13` | `PULL_MODE=UP DRIVE=4` |
| `lcd_db[14]` | 数据总线 Bit 14 (`R3`) | `D17` | Pin 22 | Pin 20 | `D14` | `PULL_MODE=UP DRIVE=4` |
| `lcd_db[15]` | 数据总线 Bit 15 (`R4`) | `A19` | Pin 23 | Pin 21 | `D15` | `PULL_MODE=UP DRIVE=4` |
| *(触摸/扩展)* | `TE` / `SDA(M0)` / `SCL(CLK)` / `INT(PEN)` / `TCS` | `A18`/`D15`/`D14`/`D16`/`E16` | Pin 24–28 | Pin 23/30/34/31/33 | — | 显示驱动无需连接 |

> **信号完整性注意**：屏幕模块上 `P1 Pin 5 (RST)` 仅串联 10Ω 电阻直连 SSD1963 `Pin 127 (RESET#)`，无板载滤波电容，且排针位置紧邻高频翻转的 `WR (Pin 3)`、`RD (Pin 4)` 与 `D0 (Pin 6)`。因此在 `lcd_test.cst` 中将 `lcd_rst` 设为强驱动 `DRIVE=16`，其余总线信号设为柔和驱动 `DRIVE=4`，可彻底避免杜邦线串扰触发意外硬件复位。

---

## 3. 快速上手：编译、烧录与串口诊断

### 3.1 目录结构

```text
lcd_test/
├── rtl/
│   ├── lcd_test_top.v       # 顶层模块：8080 总线引擎、SSD1963 初始化/刷帧/回读 ROM、UART 诊断器
│   └── ws2812_drv.v         # 板载 WS2812B 状态灯驱动
├── constraints/
│   └── lcd_test.cst         # 引脚与驱动强度约束（GW5AST-138C）
├── bitstream/
│   └── lcd_test_138c.fs     # 最新生成的比特流文件（烧录此文件）
├── build.py                 # 命令行一键综合与布局布线脚本
├── burn_lcd.py              # 命令行一键烧录脚本
└── read_diag.py             # PC 端串口诊断数据读取脚本
```

### 3.2 编译生成比特流

```powershell
python build.py
```

- 脚本会自动调用 `D:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe`。
- 由于 `gw_sh` 不支持含中文的工程路径，`build.py` 会自动将源码同步到 `C:\lcd_build` 编译，再将产物拷回 `bitstream/lcd_test_138c.fs` 与 `impl/pnr/`。
- **注意**：`gw_sh.exe` 在生成完比特流退出进程时偶发返回退出码 `3221226505` (`0xC0000409`)，只要 `bitstream/lcd_test_138c.fs` 时间戳已更新且提示 `[OK]` 即表示编译成功。

### 3.3 烧录比特流

#### 方式 A：使用 Gowin Programmer GUI（推荐）
1. 打开 Gowin Programmer，点击 **Cable Setting**：
   - Cable 选择 `Gowin USB Cable (WINUSB)`
   - Frequency 选择 `0.75MHz` 或 `2.5MHz`
   - **必须勾选 `using ftd2xx driver`**
2. 确认列表中的 **Device** 列为 **`GW5AST-138C`**（⚠️ 切勿误选 `GW5AST-138B`，否则虽能走完进度条但引脚映射不生效）。
3. Operation 选择 **SRAM Program**（不要选带 Verify 的模式），FS File 选择：
   `C:\Users\gjl50\Desktop\FPGA\fpga_spark\lcd_test\bitstream\lcd_test_138c.fs`
4. 点击 **Program/Configure**，烧录完成后屏幕即刻点亮并开始“白 → 红 → 绿 → 蓝”四色循环。

#### 方式 B：命令行脚本烧录
```powershell
python burn_lcd.py
```

### 3.4 读取板载串口诊断日志

每刷完一帧，FPGA 会自动通过 8080 总线回读 SSD1963 内部状态寄存器与 `(0,0)` 处显存像素，并通过 `U15` 引脚（板载 BL616 调试串口，波特率 `115200`）发送到电脑：

```powershell
python read_diag.py COM8 3.0
```

正常输出示例：
```text
F4F S:01576101FF P:0C L:04 I:03 A:00 M:2000031F01DF00 C:0553F6 W:01180100000000 R:FFFFFFFFFFFF N:0
F50 S:01576101FF P:0C L:04 I:03 A:00 M:2000031F01DF00 C:0553F6 W:01180100000000 R:FD00FD00FD00 N:1
F60 S:01576101FF P:0C L:04 I:03 A:00 M:2000031F01DF00 C:0553F6 W:01180100000000 R:3FE03FE03FE0 N:2
```

各字段含义对照表：

| 字段 | 对应 SSD1963 命令 | 正常期望值 | 物理含义 |
|---|---|---|---|
| `Fxx` | — | `00`..`FF` 递增 | 当前帧计数器（每 16 帧切换一次颜色） |
| `S:` | `0xA1 (read_ddb)` | `01576101FF` | 5 字节设备描述符，第 3 字节 **`61`** 为 ATK-MD0700 产品 ID |
| `P:` | `0x0A (get_power_mode)` | `0C` | `bit[3]=1` (Normal Mode)，`bit[2]=1` (Display ON) |
| `L:` | `0xE4 (get_pll_status)` | `04` | `bit[2]=1` 表示内部 100MHz PLL 已稳定锁定 |
| `I:` | `0xF1 (get_pixel_data_interface)` | `03` | `011b` = 16-bit RGB565 并口模式 |
| `A:` | `0x0B (get_address_mode)` | `00` | 从左到右、从上到下横屏扫描，RGB 顺序 |
| `M:` | `0xB1 (get_lcd_mode)` | `2000031F01DF00` | 24-bit TFT 面板，分辨率 `799 (0x031F)` × `479 (0x01DF)` |
| `C:` | `0xE7 (get_lshift_freq)` | `0553F6` | 像素时钟分频值，对应 **33.3 MHz** `LCD_DCLK` |
| `W:` | `0xBF (get_pwm_conf)` | `01180100000000` | 背光 PWM 配置：`PWMF=0x01`，占空比 `0x18`，Host 控制使能 |
| `R:` | `0x2E (read_memory_start)` | 3 个 16-bit 像素字 | 从显存 `(0,0)` 实测读回的 3 个像素值 |
| `N:` | — | `0`/`1`/`2`/`3` | 当前帧写入的颜色编号（`0`=白，`1`=红，`2`=绿，`3`=蓝） |

---

## 4. SSD1963 驱动核心时序与避坑指南（移植必读）

若将本驱动移植到其他 FPGA 工程，请务必遵守以下已由实测验证的寄存器规范：

### 4.1 命令与数据的总线位宽规则
- **所有命令码（`RS=0`）与寄存器参数（`RS=1`）只走低 8 位 `D[7:0]`**（高 8 位 `D[15:8]` 置 0）。
- **只有 `0x2C (write_memory_start)` / `0x3C` 之后的像素数据才使用完整的 16 位 `D[15:0]`（RGB565）**，以及 `0x2E (read_memory_start)` 读显存时返回 16 位像素。

### 4.2 关键坑点 1：像素时钟 `0xE6 (set_lshift_freq)` 的 20 位掩码陷阱
- 根据 `SSD1963_DS_V1.1.pdf` 第 76 页，`LCDC_FPR` 为 **20 位**（`[19:0]`），第 1 个参数只有低 4 位 `bit[3:0]` 有效，计算公式为：
  $$f_{\text{PCLK}} = f_{\text{PLL}} \times \frac{\text{LCDC\_FPR} + 1}{2^{20}}$$
- ⚠️ **切勿照搬正点原子 STM32 例程中的 `0x2F, 0xFF, 0xFF`**：由于 `0x2F` 的低 4 位是 `0xF`，SSD1963 实际将其解析为 `0xFFFFF`，导致像素时钟等于 100% 的 PLL 频率（**100 MHz**），远超 7 寸屏 33MHz 上限，且占满内部单端口显存带宽导致 `0x2C` 写像素失败（画面出现满屏雪花或条纹）。
- **正确参数**：当 `PLL = 100 MHz`（`0xE2: 0x1D, 0x02, 0x04`）时，800×480@60Hz（总周期 1056×525）所需 `33.3 MHz` 像素时钟对应的 `LCDC_FPR = 349174 = 0x0553F6`，应写入：
  ```text
  CMD 0xE6 -> DAT 0x05, DAT 0x53, DAT 0xF6
  ```

### 4.3 关键坑点 2：电源状态 `0x0A (get_power_mode)` 的返回值
- 当按正点原子流程使用 `0xB8 (0x03, 0x01)` + `0xBA (0x01)` 将 `GPIO0` 配置为普通 GPIO 输出高电平（控制面板 `DISP` 脚）且未发送 `0x11` 时，SSD1963 正常显示状态下 `0x0A` 读回值为 **`0x0C`**（`bit[3]=1` Normal Mode，`bit[2]=1` Display ON，而 `bit[4]=0`）。
- 若在状态机中做掉线自检，应检查 **`bit[2] == 1` (`Display ON`)** 或 **`0xE4` 的 `bit[2] == 1` (`PLL Locked`)**，切勿把 `bit[4] == 0` 误判为芯片复位，否则会导致每帧反复触发 `0x01` 软复位引起屏幕闪烁。

### 4.4 关键坑点 3：背光 `0xBE (set_pwm_conf)` 占空比调节
- 模块背光由 SSD1963 的 `PWM (Pin 51)` 引脚经分压电阻驱动 `MP3302DJ` 升压芯片的 `EN (Pin 4)`。
- 命令格式为 6 个参数：
  ```text
  CMD 0xBE -> DAT PWMF(0x01), DAT DUTY(0x18~0xFE), DAT 0x01(使能且由Host控制), DAT 0x00, DAT 0x00, DAT 0x00
  ```
- 修改 [`rtl/lcd_test_top.v`](file:///C:/Users/gjl50/Desktop/FPGA/fpga_spark/lcd_test/rtl/lcd_test_top.v) 中 `8'd49: rom_q = `D(8'h18);` 的数值即可调节背光亮度（`0x00` 全灭，`0x18` 柔和省电适合单根杜邦线供电，`0x80`~`0xFE` 高亮需确保 5V 供电线足够粗短或外接独立 5V）。

---

## 5. 标准初始化与刷帧指令序列速查

### 5.1 初始化序列（对应 [`lcd_test_top.v`](file:///C:/Users/gjl50/Desktop/FPGA/fpga_spark/lcd_test/rtl/lcd_test_top.v) `SEG_INIT`）

| 步骤 | 命令 (`RS=0`) | 参数序列 (`RS=1`) | 关键延时 / 作用 |
|---|---|---|---|
| 1 | 硬件复位 | `lcd_rst = 0` (20ms) → `1` (40ms) | 硬件上电复位 |
| 2 | `0xE2` | `0x1D, 0x02, 0x04` | 后置延时 **1ms**；配置 PLL 倍频 M=29, N=2 (`10MHz × 30 / 3 = 100MHz`) |
| 3 | `0xE0` | `0x01` | 后置延时 **10ms**；启动 PLL |
| 4 | `0xE0` | `0x03` | 后置延时 **12ms**；锁定 PLL 并切换系统时钟源为 PLL |
| 5 | `0x01` | *(无参数)* | 后置延时 **10ms**；软件复位（不重置 `0xE0`~`0xE5`） |
| 6 | `0xE6` | `0x05, 0x53, 0xF6` | 设置像素时钟 `LCD_DCLK = 33.3 MHz` |
| 7 | `0xB0` | `0x20, 0x00, 0x03, 0x1F, 0x01, 0xDF, 0x00` | 24-bit TFT 模式，分辨率 `800×480` (`799, 479`) |
| 8 | `0xB4` | `0x04, 0x1F, 0x00, 0x2E, 0x00, 0x00, 0x00, 0x00` | 水平总周期 `HT=1055`，水平前沿 `HPS=46` |
| 9 | `0xB6` | `0x02, 0x0C, 0x00, 0x17, 0x16, 0x00, 0x00` | 垂直总周期 `VT=524`，垂直前沿 `VPS=23` |
| 10 | `0xF0` | `0x03` | 设置 8080 主机像素数据接口为 **16-bit RGB565** |
| 11 | `0x29` | *(无参数)* | 开启显示输出 (`set_display_on`) |
| 12 | `0xD0` | `0x00` | 关闭 DBC 动态背光控制 |
| 13 | `0xBE` | `0x01, 0x18, 0x01, 0x00, 0x00, 0x00` | 开启背光 PWM（高频 `PWMF=1`，占空比 `0x18`） |
| 14 | `0xB8` | `0x03, 0x01` | 配置 `GPIO0`/`GPIO1` 为 Host 控制的普通推挽输出 |
| 15 | `0xBA` | `0x01` | 拉高 `GPIO0 = 1`（使能液晶面板正常扫描） |
| 16 | `0x36` | `0x00` | 设置显存扫描方向：横屏从左到右、从上到下 |

### 5.2 单帧刷新序列（对应 [`lcd_test_top.v`](file:///C:/Users/gjl50/Desktop/FPGA/fpga_spark/lcd_test/rtl/lcd_test_top.v) `SEG_FRAME` + `M_PIX`）

```text
1. CMD 0x2A -> DAT 0x00, 0x00, 0x03, 0x1F   // 设置列地址范围 0 .. 799
2. CMD 0x2B -> DAT 0x00, 0x00, 0x01, 0xDF   // 设置页(行)地址范围 0 .. 479
3. CMD 0x2C                                 // 开始写显存 (write_memory_start)
4. 连续写入 800 × 480 = 384,000 个 16-bit RGB565 像素字 (RS = 1)
```

---

## 6. 硬件排查与踩坑记录（血泪版）

> 这些坑在调试期逐个踩过，记下来避免重复。**每条都有实测依据。**

### 6.1 CS 必须每条命令后拉高 —— 对齐正点原子 GPIO 例程

正点原子 **GPIO 版**（`atk_md0700_gpio_write_cmd`）的写法：

```c
RS(0); CS(0); DATA(cmd); WR(0); WR(1); CS(1);   // ← 每次写完 CS 拉高
```

FPGA 里要在写周期的最后一个相位 `lcd_cs <= 1'b1`。**整帧刷像素时 CS 可保持低**，只在命令之间脉冲。

> 早期版本 CS 全程拉低，屏幕始终不亮；改成脉冲式后才正常。

### 6.2 「WS2812 变绿 = 初始化成功」是错的

状态机是"发完就走"，**不检查任何回执**。即使 16 根数据线全断，灯照样变绿。
**唯一可信的判据是回读**（`0xA1` 读 PID / 第 3.4 节的 UART 日志）。

### 6.3 延时竞态：所有延时曾被静默跳过

```verilog
wire delay_done = (delay_cnt == 24'd0);   // ✗ 装载发生在下一拍
```

进入等待状态的第一拍 `delay_cnt` 仍是 0 → 立即退出。后果：RST 低电平只有 1 拍、PLL 的 10ms/12ms 锁定延时全丢。
修法：加 `delay_armed` 标志，`delay_done = delay_armed && (delay_cnt == 24'd0)`。

### 6.4 背光不亮时不要调数据

LCD 是"快门"不是发光体，**背光不亮时数据再对也看不见**。先解决背光。

背光链路的硬件排查法（模块上有测试点）：

| 测试点 | 正常值 | 含义 |
|---|---|---|
| `5V` / `3.3V` | 5.0 / 3.3V | 输入与 IO 电源 |
| `10.4V` | ≈10.4V | 面板 AVDD（TPS61040，EN 直接接 VCC5，常开） |
| `16V` / `-7V` | ≈16V / ≈−7V | VGH / VGL |
| **`200mV`** | **背光亮 ≈200mV，灭 ≈0V** | **背光恒流反馈（R9 2Ω × 100mA），最直接的判据** |

MP3302：EN 开启阈值仅 **0.6V**、绝对最大 6.5V，EN 兼作单线调光（>1.5V 全亮）。

### 6.5 双 5V 并联会互灌

屏幕用外接 5V 时，**必须拔掉 J13 pin11（5V_Peripheral）**。两路 5V 并联，电压高的那路会倒灌进底板的功率开关。
共地是必须的，但 5V 只能留一路。

### 6.6 器件型号必须精确到版本号

`.gprj` 曾是 `GW5AST-138B`，实际板子是 **138C**。SRAM 烧录无校验，**型号错了不报错，但引脚行为不对**。

### 6.7 其他构建环境坑

| 坑 | 现象 | 解法 |
|---|---|---|
| **中文路径** | `gw_sh` 报 `ERROR (SP0002) Corrupted project file`，路径显示成 `Desktop/??/` | `build.py` 自动镜像到 `C:/lcd_build` |
| **gw_sh 退出崩溃** | 退出码 `3221226505`（`0xC0000409`） | 只看 `.fs` 时间戳，不看退出码 |
| 原地构建自我拷贝 | `WinError 32` 文件被占用 | `prepare()` 里判断 `work != SRC` 才 copy |
| Programmer 的 ftd2xx | 不勾 `using ftd2xx driver` 烧不进去 | **必须勾选**（别按"FTDI 专用"想当然） |
| 位流被覆盖 | `impl/pnr/lcd_test.fs` 每次构建覆盖 | 验证通过的版本要归档 |

---

## 7. 引脚表的三份交叉验证来源

第 2 节的接线表由以下三份**独立**资料交叉确认，可以放心使用：

1. `ATK-MD0700模块使用说明_V1.3.pdf` 第 1 章 —— 9 张不同开发板的接线表，模块侧引脚顺序完全一致
2. `ATK-MD0700模块用户手册_V1.2.pdf` 表 2.1.1 —— 34P 引脚定义（`M1`/`M0` 在此表中印作 `MI`/`MO`，实为数字 1/0）
3. 模块丝印实测 + 底板 `tang_mega_138K_pins.cst` 球位定义

模块侧引脚顺序（1→34）：

```text
NCE RS WR RD RST D0..D15 GND NC NC NC GND GND V5 MI MO PEN NC TCS CLK
 1   2  3  4  5   6..21  22 23 24 25  26 27 28 29 30 31 32  33  34
```

> 触摸四根**不连续**：`M0`=pin30(SDA)、`PEN`=pin31(INT)、`TCS`=pin33(RST)、`CLK`=pin34(SCL)，中间夹着 pin32(NC)，最容易接错。

---

## 8. 参考文件

```text
../docs/LCD接线图.html                                    # 可打印接线图（含丝印球位）
../docs/LCD接线表-ATK-MD0700-34P_to_J13-40P.md             # 完整引脚定义 + 危险引脚清单
../docs/底板接口位置图.html                                 # 底板各连接器位置
../../Tang_Mega_60K_138K硬件资料/01_原理图_Schematics/      # 底板原理图
../../Tang_Mega_60K_138K硬件资料/06_Sipeed官方例程/         # Sipeed 官方例程（40P RGB 屏，本模块不适用）

桌面/文件/2026电赛/【正点原子】7寸TFT LCD…（新资料）/
├── 1，原理图/ATK-MD0700_V2.4.pdf                          # 背光/电源电路
├── 2，程序源码/…（GPIO）/…/atk_md0700_gpio.c               # ★ 位翻转参考（CS 脉冲）
├── 2，程序源码/…（FMC&FSMC）/…/atk_md0700.c                # ★ 官方初始化序列
├── 4，参考资料/SSD1963_DS_V1.1.pdf                        # ★ 寄存器语义以此为准
├── 4，参考资料/MP3302_r0.98.pdf                           # 背光升压
├── ATK-MD0700模块使用说明_V1.3.pdf                         # ★ 9 张接线表
└── ATK-MD0700模块用户手册_V1.2.pdf
```

---

## 9. 下一步可做

- [ ] 背光调亮：`8'd49` 的 `0x18` → `0xFF`（需确认 5V 供电线够粗，或继续用外接 5V）
- [ ] 恢复彩条/渐变图案（当前纯色轮换仅作通路验证）
- [ ] 触摸（GT911 / FT5x26，I2C）：`M0`=SDA、`CLK`=SCL、`PEN`=INT、`TCS`=RST，模块已带 4.7k 上拉，FPGA 侧不要再加
- [ ] 归档验证通过的位流，避免被下次构建覆盖


---

## 10. 当前画面："spark" Logo

### 10.1 效果

- 背景：深蓝渐变（`py[8:6]` 查表，8 段，上下对称，顶部/底部为纯黑形成letterbox）
- 文字：`spark`，**Arial Black 60px** 渲染后二值化，点阵 **183 × 55**，硬件 **4 倍**放大 → 屏幕 **732 × 220**，居中于 `(34, 130)`
- 文字颜色：按 `sx[7:5]` 查表做**横向渐变** —— 青 `0x07FF` → 蓝紫 `0x2C1F` → 品红 `0xF81F`

### 10.2 实现方式

字模存在 `logo_rom[0:329]`（330 个 32bit 字 = 55 行 × 6 字），`initial` 块赋值，综合成分布式 ROM（约 1700 LUT）。

像素到字模的映射：

```verilog
wire [10:0] dx = px - 11'd34;                 // 越界时无符号回绕成大数，自动排除
wire [10:0] dy = py - 11'd130;
wire        in_logo = (dx < 732) && (dy < 220);

wire [7:0]  sx = dx[9:2];                     // /4，0..182
wire [7:0]  sy = dy[9:2];                     // /4，0..54
wire [8:0]  ridx = sy * 6 + {6'd0, sx[7:5]};  // 行 × 6 + 字号
wire [31:0] lword = logo_rom[ridx];
wire        lon  = lword[5'd31 - sx[4:0]];    // 高位在前
```

> **为什么缩放用 4**：4 是 2 的幂，`dx[9:2]` 直接取位即可，不需要除法器。若改成 5 或 6，需要引入常数除法，会多消耗上百个 LUT。

### 10.3 换字 / 换 Logo

改 `tools/` 下生成脚本里的字符串和字号，重新生成 `logo_rom` 的 330 条赋值替换即可。要点：

1. 渲染后**裁剪到墨迹边界**（`img.crop(img.getbbox())`）
2. 二值化阈值 128
3. 每行按 32bit 打包，**高位在前**（`v |= 1 << (31-b)`）
4. 同步更新 `LOGO_W` / `LOGO_H` / `LOGO_DX` / `LOGO_DY` 和居中坐标

### 10.4 WS2812 状态灯（当前版本）

| 灯色 | 含义 |
|---|---|
| 暗红常亮 | 初始化中 |
| 亮绿 / 暗绿 交替（约 1s） | 初始化完成，帧循环在跑 |

---

## 11. 备份

`../lcd_test_backup_20261023/` —— 点亮验证通过时的完整快照（含可烧位流 `lcd_test_138c_WORKING_1023-1131.fs`、RTL、约束、脚本、README）。

改动前若需要回退，直接从这个目录拷回。


---

## 12. 硬件显存截图功能（SSD1963 `0x2E` 回读 → UART → PC PNG）

为了在不占用 FPGA 内部 BRAM 的前提下把屏幕上**真实显示的图像**回传给电脑，[`rtl/lcd_test_top.v`](file:///C:/Users/gjl50/Desktop/FPGA/fpga_spark/lcd_test/rtl/lcd_test_top.v) 内置了硬件显存回读引擎，配合上位机脚本 [`screenshot_lcd.py`](file:///C:/Users/gjl50/Desktop/FPGA/fpga_spark/lcd_test/screenshot_lcd.py) 即可一键保存为 `.png` 图片。

### 12.1 硬件原理

1. **零 BRAM 开销**：SSD1963 内部自带 1215 KB 显存（GRAM），且 8080 总线为全静态异步接口。
2. **回读流程**：
   - 电脑通过板载 USB-UART（`COM8`，`115200 8N1`，FPGA 引脚 `uart_rx = V14`、`uart_tx = U15`）发送截图命令。
   - FPGA 在当前帧结束后，向 SSD1963 发送 `0x2A`（列地址 `0..799`）、`0x2B`（行地址 `0..479`）与 `0x2E`（`read_memory_start`）。
   - 随后保持 `CS#=0, RS=1`，将 `lcd_db[15:0]` 切换为高阻输入（`db_oe=0`），每发起一次 `RD#` 低脉冲即从 SSD1963 显存中读出一个 16-bit RGB565 像素，并在串口发送期间暂停下一个 `RD#` 脉冲。

### 12.2 串口指令表（115200 8N1）

| 串口发送字符 | 功能说明 |
|---|---|
| `'q'` / `'Q'` | **快速截图（推荐，默认）**：从 SSD1963 显存回读全屏并按 `4×4` 抽样为 `200×120` 原始 RGB565 流（固定 `48,000` 字节，耗时约 **4.2 秒**，上位机还原为 `800×480` PNG） |
| `'c'` / `'C'` | **全分辨率无损 RLE 截图**：从 SSD1963 显存回读完整 `800×480` 像素并做硬件游程编码（`[count, hi, lo]`） |
| `'0'` / `'1'` / `'2'` / `'3'` | 将屏幕锁定为纯色：**白 (`0`) / 红 (`1`) / 绿 (`2`) / 蓝 (`3`)** |
| `'4'` | 将屏幕锁定为 **8 色彩条 + 4px 白边框** 标准测试图 |
| `'a'` / `'A'` | 恢复白 → 红 → 绿 → 蓝自动循环切换 |

### 12.3 使用方法

在命令行运行 [`screenshot_lcd.py`](file:///C:/Users/gjl50/Desktop/FPGA/fpga_spark/lcd_test/screenshot_lcd.py)：

```powershell
# 1. 直接截取当前屏幕画面并保存为 screenshot.png（约 4.2 秒）
python screenshot_lcd.py

# 2. 先切换屏幕为“8色彩条+白边框”测试图，再截图保存为 bars.png
python screenshot_lcd.py --pattern bars --out bars.png

# 3. 使用 800x480 全分辨率 RLE 模式截图
python screenshot_lcd.py --mode rle --out screenshot_full.png

# 4. 恢复屏幕自动四色轮换
python screenshot_lcd.py --pattern auto --no-capture
```
