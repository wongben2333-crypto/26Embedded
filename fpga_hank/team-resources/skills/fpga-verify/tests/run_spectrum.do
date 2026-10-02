# =============================================================================
#  fpga-verify 自检：用 ModelSim 跑真实 tb_spectrum，产出 dump 供 check_peaks.py 分析
#  用法：& "F:\Modelsim_10.7\win64\vsim.exe" -c -do run_spectrum.do
#  工作目录必须是本文件所在目录（dump 与 work 库都会落在当前目录）
# =============================================================================
set MS_HOME F:/Modelsim_10.7
if {[file exists $MS_HOME/modelsim.ini]} {
    catch {set ::env(MODELSIM) $MS_HOME/modelsim.ini}
}

set ROOT {C:/Users/Danny/Desktop/FPGA competition/fpga_hank}
set HERE [pwd]
puts "\[verify\] pwd  = $HERE"
puts "\[verify\] root = $ROOT"

if {[file exists work]} { file delete -force work }
vlib work
vmap work work

foreach f [lsort [glob -nocomplain "$ROOT/rtl/*/*.v"]] {
    puts "\[verify\] vlog $f"
    if {[catch {eval vlog -sv -work work [list $f]} e]} { puts "VLOG-FAIL $f : $e"; quit -f }
}
puts "\[verify\] vlog $ROOT/sim/tb/tb_spectrum.v"
if {[catch {eval vlog -sv -work work [list "$ROOT/sim/tb/tb_spectrum.v"]} e]} { puts "VLOG-FAIL tb: $e"; quit -f }

puts "\[verify\] vsim tb_spectrum"
vsim -c -work work tb_spectrum
run -all
quit -f
