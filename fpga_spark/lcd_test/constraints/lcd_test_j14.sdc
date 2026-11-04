// =============================================================================
//  lcd_test_j14.sdc - 时序约束 (50 MHz 主时钟 + J14 8080 屏幕约束)
// =============================================================================

create_clock -name clk -period 20.0 -waveform {0 10.0} [get_ports {clk}]

// 慢速DAC 音频、LED、8080 屏幕接口源自内部多周期信号
set_false_path -to [get_ports {HP_BCK HP_WS HP_DIN PA_EN}]
set_false_path -to [get_ports {led[*]}]
set_false_path -to [get_ports {lcd_db[*] lcd_cs lcd_rs lcd_wr lcd_rd lcd_rst ws_dout lcd_uart_tx dbg_key dbg_tx}]

// UI 渲染流水线多周期约束: px/py 仅在 ph=12 变化（每 20 个周期 400ns 更新一次），ui_color 仅在 ph=2 锁存
set_multicycle_path -to [get_regs {*col_p* *col_nav*}] -setup -end 4
set_multicycle_path -to [get_regs {*col_p* *col_nav*}] -hold -end 3
