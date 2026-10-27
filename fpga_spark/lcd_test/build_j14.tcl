set root [file dirname [info script]]
cd $root
open_project lcd_test_j14.gprj
set_option -top_module lcd_test_top
set_option -synthesis_tool gowinsynthesis
set_option -output_base_name lcd_test_j14
set_option -verilog_std sysv2017
set_option -show_all_warn 1
run all
exit
