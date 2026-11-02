# probe_io.tcl -- 最小 P&R 探针（不产出可烧写的正式位流，只判引脚可约束性）
set ROOT [file dirname [info script]]
cd $ROOT
set PRJ   "probe_io"
set PART  "GW5AST-LV138PG484AC1/I0"
set DVER  "C"

create_project -name $PRJ -dir $ROOT -pn $PART -device_version $DVER -force
add_file -type verilog [file join $ROOT probe_io.v]
add_file -type cst     [file join $ROOT probe_io.cst]
set_option -top_module $PRJ
set_option -synthesis_tool gowinsynthesis
set_option -output_base_name $PRJ
set_option -verilog_std sysv2017
set_option -show_all_warn 1

set syn_ok 1
set pnr_ok 1
puts "=== run syn ==="
if {[catch {run syn} e]} { set syn_ok 0; puts "SYN_FAIL: $e" }
puts "=== run pnr ==="
if {[catch {run pnr} e]} { set pnr_ok 0; puts "PNR_FAIL: $e" }
puts "RESULT syn_ok=$syn_ok pnr_ok=$pnr_ok"

set IMPL [file join $ROOT $PRJ "impl"]
foreach f [lsort [glob -nocomplain [file join $IMPL pnr *.fs] [file join $IMPL pnr *.pin.html] [file join $IMPL pnr *.rpt.txt]]] {
    puts "OUT [file tail $f] [file size $f]"
}
exit 0