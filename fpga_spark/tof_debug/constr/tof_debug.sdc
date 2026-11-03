// 50 MHz System Clock on V22
create_clock -name clk -period 20.000 -waveform {0.000 10.000} [get_ports {clk}]
