# 138K 表情控制版交付记录

日期：2026-10-31

本次只更新 `fpga_hank/`，其它队友目录不动。

## 代码变化

- `piano_engine_tdm32.v`：颤音 LFO、CC5/CC65 滑音真正进入相位增量。
- `instrument_body_fx.v`：钢琴/吉他/小提琴三档琴体 EQ；小提琴 CC22 弓压影响中频亮度，CC23 弓位影响高频边缘。
- `piano_rom.v`：五段音区泛音表。
- `top.v`：运行期来源切换和三种交互保持不变。
- `host/piano_gui.py`：小提琴 UI 改为 G-D-A-E 四弦指板，四弦、琴桥、琴身和横弓显示；自检 PASS。

## Gowin 证据

- 器件：`GW5AST-LV138PG484AC1/I0`
- setup/hold：`0/0`
- Fmax：`56.360 MHz`
- Logic：`8597/138240`
- FF：`2740/138240`
- BSRAM：`68/340`
- DSP：`45.5/298`
- User Code：`0x1A2B0003`
- 位流：`MODE3_138K_EXPRESSION_20261031.fs`
- SHA256：`FFE14DB83530EF6858700C3A248C95323B52BD845E1E56527E5ED106CA8FEAFA`

## 上板状态

2026-10-31 11:18 烧录时 JTAG 暂未识别，programmer_cli 退出码 50；重新插好 JTAG 后，用 `tools/gowin/program.ps1 -Mode sram` 下载交付位流。位流文件保存在本地交付包，不提交到 Git。
