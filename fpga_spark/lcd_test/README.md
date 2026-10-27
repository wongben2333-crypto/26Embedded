# ATK-MD0700 LCD 测试工程：J14 方案

适用硬件：

- FPGA 底板：Sipeed Tang Mega 138K NEO Dock 31005
- FPGA：GW5AST-138C，封装 GW5AST-LV138PG484AC1/I0
- LCD：正点原子 ATK-MD0700 V2.4
- LCD 控制器：SSD1963
- 分辨率：800 x 480
- 总线：16-bit Intel 8080
- FPGA 系统时钟：50 MHz

当前状态：**J14 LCD 时序已实机验证成功，面向电子乐器工程的基础 UI 已完成综合、布局布线、烧录和实机截图验证。**

本版本默认显示四页音频仪表 UI：演奏波形、声部混音、谐波频谱、效果器/输出。页面使用与嵌赛方案一致的字段：声部数、音色、音量、音频引擎、效果器、I2S/DAC 和琴键/拨弦/特雷门输入。当前 LCD 测试工程中的数值和波形仍为演示数据，接入音频主工程时再替换为真实状态信号。

## 1. 重要的 LCD 排针编号

正点原子手册规定：

```text
P1-1       CS
P1-2       RS
P1-3       WR
P1-4       RD
P1-5       RST
P1-6~P1-21 D0~D15
P1-22      GND
P1-23      TE，不连接
P1-24~25  NC
P1-26~27  GND
P1-28      +5V
P1-29      NC
P1-30      MO
P1-31      PEN
P1-32      NC
P1-33      TCS
P1-34      CLK
```

注意：`D0` 从 `P1-6` 开始，`D15` 是 `P1-21`。`P1-23` 是 TE，不能当作 D15 使用。

## 2. J14 接线表

LCD 数据位采用重排方式，必须按下表连接，不能按 J14 的 SDRAM1 数据名称顺序直接连接。

| LCD P1 | 信号 | Tang Mega J14 丝印 | FPGA 球号 |
|---:|---|---|---|
| 28 | +5V | J14-11 | 电源 |
| 22、26、27 | GND | J14-12 | GND |
| 1 | CS | J14-24 | AB21 |
| 2 | RS | J14-39 | R14 |
| 3 | WR | J14-27 | AB20 |
| 4 | RD | J14-30 | AB18 |
| 5 | RST | J14-32 | Y18 |
| 6 | D0 | J14-19 | V20 |
| 7 | D1 | J14-20 | U20 |
| 8 | D2 | J14-21 | Y22 |
| 9 | D3 | J14-26 | AA20 |
| 10 | D4 | J14-34 | N15 |
| 11 | D5 | J14-36 | U17 |
| 12 | D6 | J14-40 | P14 |
| 13 | D7 | J14-38 | P15 |
| 14 | D8 | J14-18 | N13 |
| 15 | D9 | J14-17 | N14 |
| 16 | D10 | J14-25 | AA21 |
| 17 | D11 | J14-15 | P17 |
| 18 | D12 | J14-14 | W21 |
| 19 | D13 | J14-13 | W22 |
| 20 | D14 | J14-10 | V17 |
| 21 | D15 | J14-23 | AB22 |

### 2.1 不能使用的脚位

- `J14-22` 对应 `Y21`，属于 SSPI 专用球，本工程不使用。
- `J14-35` 被散热片遮挡，本工程不使用。
- `J14-37` 被散热片遮挡，本工程不使用。
- `J14-40` 用作 LCD D6，不能接地。
- J14 与 SDRAM1、DVP 摄像头和 PMOD 复用，使用 LCD 时不要同时连接这些外设。

J14 连接器丝印编号按官方原理图排列：

```text
奇数列       偶数列
  1            2
  3            4
  5            6
  ...          ...
 39           40
```

## 3. 工程文件

```text
lcd_test/
├── rtl/
│   ├── lcd_test_top.v
│   ├── lcd_ui.v              # FPGA 生成的四页基础 UI
│   └── ws2812_drv.v
├── constraints/
│   ├── lcd_test_j13.cst       # J13 方案，保留
│   └── lcd_test_j14.cst       # 当前使用的 J14 约束
├── bitstream/
│   ├── lcd_test_j14_138c.fs
│   ├── lcd_test_j14_138c_verified.fs  # 旧版硬件测试位流
│   └── lcd_ui_j14_138c_verified.fs    # 当前 UI 位流
├── docs/
│   └── LCD接线表-ATK-MD0700-34P_to-J14-40P.md
├── build_j13.py               # J13 方案，保留
├── build_j13.tcl              # J13 方案，保留
├── lcd_test_j13.gprj          # J13 方案，保留
├── build_j14.py
├── burn_lcd_j14.py
└── screenshot_lcd.py
```

J5 相关的构建脚本、工程文件、约束、位流和文档已经删除。

## 4. 编译 J14 工程

在 `lcd_test` 目录执行：

```powershell
python build_j14.py
```

构建脚本调用 Gowin Shell：

```text
D:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe
```

构建成功后，主要输出为：

```text
C:\Users\gjl50\Desktop\FPGA\fpga_spark\lcd_test\bitstream\lcd_ui_j14_138c_verified.fs
```

## 5. 烧录 J14 位流

确认 FPGA、下载器和 LCD 已连接后执行：

```powershell
python burn_lcd_j14.py
```

脚本使用 Gowin Programmer 的 SRAM Program 操作，默认烧录：

```text
bitstream\lcd_ui_j14_138c_verified.fs
```

SRAM 烧录掉电后会丢失，重新上电后需要重新烧录。

## 6. 基础 UI 与控制

FPGA 上电后会初始化 SSD1963，并显示四页 UI。板载按键用于翻页：

| 控件 | FPGA 球号 | 功能 |
|---|---|---|
| `Key_in[0]` | `AB13` | 下一页 |
| `Key_in[1]` | `Y12` | 上一页 |

页面内容：

| 页面 | 内容 |
|---|---|
| PLAY | 活跃声部、音色、音量、音频波形 |
| SPEC | 声部混音柱和动态电平 |
| TEST | 谐波/振荡器测试柱状图 |
| SONG | 效果器输出、进度和播放状态 |

串口默认使用 `COM8`，参数为 `115200 8N1`。串口控制命令：

| 命令 | 功能 |
|---|---|
| `0` | 白屏 |
| `1` | 红屏 |
| `2` | 绿屏 |
| `3` | 蓝屏 |
| `4` | 8 色彩条 |
| `m` | PLAY 页面 |
| `v` | SPEC 页面 |
| `t` | TEST 页面 |
| `g` | SONG 页面 |
| `n` | 下一页 |
| `b` | 上一页 |
| `a` | 恢复 FPGA UI |
| `q` | 读取 200x120 缩略图 |
| `c` | 读取 800x480 RLE 截图 |

`0` 到 `4` 仍然保留为 LCD 纯色和彩条硬件测试；发送 `a` 可返回 UI。

截图程序需要 Python 包 `pyserial` 和 `Pillow`：

```powershell
python screenshot_lcd.py --port COM8 --pattern bars --mode quick --out screenshot\bars.png
```

## 7. 故障排查顺序

1. 确认 LCD `P1-28` 接 `J14-11`，LCD `P1-22/26/27` 接地。
2. 确认 LCD 数据从 `P1-6` 开始，不要把 `P1-7` 当作 D0。
3. 确认 `P1-23` 没有接线。
4. 确认 J14-22、J14-35、J14-37 没有使用。
5. 确认烧录的是 `lcd_ui_j14_138c_verified.fs`，不是旧的 LCD 硬件测试位流。
6. 确认 LCD 背光亮起后等待约 1 秒，再观察测试画面。

详细接线表见：

```text
docs\LCD接线表-ATK-MD0700-34P_to-J14-40P.md
```
