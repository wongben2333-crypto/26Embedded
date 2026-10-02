# 诊断运行：编译 tone_bank + pt8211_tx + tb_diag，抓 40 拍流水
set MS_HOME F:/Modelsim_10.7
if {[file exists $MS_HOME/modelsim.ini]} { catch {set ::env(MODELSIM) $MS_HOME/modelsim.ini} }
set ROOT {C:/Users/Danny/Desktop/FPGA competition/fpga_hank}
if {[file exists work]} { file delete -force work }
vlib work
vmap work work
foreach f [lsort [glob -nocomplain "$ROOT/rtl/*/*.v"]] {
    if {[catch {eval vlog -sv -work work [list $f]} e]} { puts "VLOG-FAIL $f : $e"; quit -f }
}
if {[catch {eval vlog -sv -work work [list [pwd]/tb_diag.v]} e]} { puts "VLOG-FAIL tb_diag: $e"; quit -f }
vsim -c -work work tb_diag
run -all
quit -f
