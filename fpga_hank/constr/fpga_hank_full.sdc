// =============================================================================
//  fpga_hank.sdc —— 时序约束
//
//  ★ Gowin 的 SDC 解析器【不支持反斜杠续行】：
//      写多行会在 pnr 阶段报 `TA2000 near token '\'` 并失败。
//      每条约束必须写成单独一行。
//  ★ 不写 .sdc 时默认 -global_freq 100.000 MHz，而板上晶振只有 50 MHz
//    （过度约束，可能造成不必要的布线压力）。
//  ★ TA1132（时钟未创建）与 PR1014（时钟走通用布线）【不出现在 .rpt.txt】，
//    只在 console 输出和 impl/pnr/<name>.log 里 —— 检查告警必须看 log。
// =============================================================================

create_clock -name clk -period 20.0 -waveform {0 10.0} [get_ports {clk}]

// 慢速输出：DAC 串行线、LED、8080 屏幕接口与调试串口都是低速外设信号
set_false_path -to [get_ports {HP_BCK HP_WS HP_DIN PA_EN}]
set_false_path -to [get_ports {led[*]}]
set_false_path -to [get_ports {lcd_db[*] lcd_cs lcd_rs lcd_wr lcd_rd lcd_rst ws_dout lcd_uart_tx dbg_key dbg_tx}]

// UI 渲染流水线多周期约束：px/py 在 ph=12 变化，每 20 周期(400ns)递增一次；ui_color 在下一像素 ph=2(10周期后)才采样
set_multicycle_path -to [get_regs {*col_p* *col_nav* *s_yb*}] -setup -end 4
set_multicycle_path -to [get_regs {*col_p* *col_nav* *s_yb*}] -hold -end 3
