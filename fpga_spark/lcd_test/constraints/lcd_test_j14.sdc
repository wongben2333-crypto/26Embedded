// 50 MHz system oscillator on V22 (20.000 ns period)
create_clock -name sys_clk -period 20.000 -waveform {0 10} [get_ports {sys_clk}]
