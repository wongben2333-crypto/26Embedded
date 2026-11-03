// =============================================================================
//  lcd_test_j14.sdc —— 时序约束 (50 MHz 主时钟 + J14 8080 屏幕多周期约束)
// =============================================================================

create_clock -name clk -period 20.0 -waveform {0 10.0} [get_ports {clk}]

// 慢速输出：DAC 串行线、LED、8080 屏幕接口与调试串口都是低速外设信号
set_false_path -to [get_ports {HP_BCK HP_WS HP_DIN PA_EN}]
set_false_path -to [get_ports {led[*]}]
set_false_path -to [get_ports {lcd_db[*] lcd_cs lcd_rs lcd_wr lcd_rd lcd_rst ws_dout lcd_uart_tx dbg_key dbg_tx}]

// UI 渲染流水线多周期约束：px/py 在 ph=12 变化，每 20 周期(400ns)递增一次；ui_color 在下一像素 ph=2(10周期后)才采样
set_multicycle_path -to [get_regs {*col_p* *col_nav* *s_yb*}] -setup -end 4
set_multicycle_path -to [get_regs {*col_p* *col_nav* *s_yb*}] -hold -end 3
