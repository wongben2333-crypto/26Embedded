# 触控调试记录（2026-11-02）

## 结论

屏幕触控 RTL 已经集成在最新 fpga_hank 源码中，但板上原先运行的是 2026-10-31 位流；该位流没有本次 2026-11-02 队友提交的 GT911 触控链路。此次用当前源码重新综合、布局布线、生成并烧录了带触控的 138K SRAM 位流。

## 版本指纹

- 器件：GW5AST-138C，JTAG ID 0x0001081B
- User Code：0x1A2B0003
- 位流：MODE3_freeplay_20261102_正式版.fs
- SHA256：C33D34A6899335830A7F86880C8D4A6F0BCD3ABC931D57C0F1E1BFA42F892797
- 烧录方式：SRAM Program，操作码 2，退出码 0
- 烧录时间：2026-11-02 18:24:10

## 触控链路确认

当前源码链路为：

J14 触摸四线 -> top.v -> lcd_subsystem_j14.v -> touch_ft5206_i2c.v -> GT911/FT5x06 I2C -> 触摸坐标/触摸事件 -> LCD UI 与音符总线

综合网表中存在 touch_ft5206_i2c u_touch 实例，并且 tp_scl/tp_sda/tp_int/tp_rst_n 均保留为顶层 I/O。

烧录后从 FPGA UART（COM9，115200 8N1）发送 d 查询得到：

    F08F SFFFFFFFFFF PFF LFF CFFFFFF MFFFFFFFFFFFFFF N0 TG0000,000
    F090 SFFFFFFFFFF PFF LFF CFFFFFF MFFFFFFFFFFFFFF N0 TG0000,000
    F091 SFFFFFFFFFF PFF LFF CFFFFFF MFFFFFFFFFFFFFF N0 TG0000,000

TG 中的 G 表示已探测到 Goodix GT911；0000,000 是当前未触摸状态的坐标。说明 J14 I2C 地址探测与复位链路已经工作。

## 本次构建资源与时序

- Logic：40197 / 138240（30%）
- FF：4882 / 138240（4%）
- BSRAM：125 / 340（37%）
- DSP：105.5 / 298（36%）
- Setup slack：+0.005 ns
- Hold slack：+0.170 ns
- 结论：没有 setup/hold 负违例；setup 裕量很小，后续应保持 50 MHz 约束并避免继续增加长组合路径。

## 上板触控验证步骤

1. 保持当前位流运行，屏幕和 FPGA 共同供电。
2. 等待屏幕初始化完成。
3. 在屏幕顶部四个页面标签、主页音色卡片、底部琴键区各点击一次。
4. 若要看坐标，运行：python fpga_hank/host/touch_live_monitor.py，端口选择 COM9。
5. 观察屏幕准心是否跟随手指，页面是否切换，琴键区是否触发音符。

注意：本记录已验证 GT911 被识别；TG0000,000 只代表采样时没有手指按下，不代表触摸失效。
