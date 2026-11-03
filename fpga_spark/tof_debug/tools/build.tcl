# =============================================================================
#  build.tcl -- Gowin CLI Build Script for Tang Mega 138K ToF Debug Project
# =============================================================================

set PRJ_NAME    tof_debug
set TOP_MODULE  tof_debug_top
set PART        GW5AST-LV138PG484AC1/I0
set DEVICE_VER  C

set TOOLS_DIR [file normalize [file dirname [info script]]]
set ROOT      [file normalize [file join $TOOLS_DIR ..]]
set RTL_DIR   [file join $ROOT rtl]
set CONST_DIR [file join $ROOT constr]
set PRJ_DIR   [file join $ROOT eda_proj]

puts "=============================================================="
puts "\[gowin\] project : $PRJ_NAME"
puts "\[gowin\] root    : $ROOT"
puts "\[gowin\] part    : $PART  (device version $DEVICE_VER)"
puts "\[gowin\] top     : $TOP_MODULE"
puts "=============================================================="

set V_FILES {}
foreach f [lsort [glob -nocomplain -directory $RTL_DIR *.v *.sv]] {
    lappend V_FILES $f
}

set CST_FILE [file join $CONST_DIR "tof_debug.cst"]
set SDC_FILE [file join $CONST_DIR "tof_debug.sdc"]

if {[llength $V_FILES] == 0} {
    error "\[gowin\] ERROR: No Verilog files found in $RTL_DIR"
}

file mkdir $PRJ_DIR
cd $PRJ_DIR
create_project -name $PRJ_NAME -dir $PRJ_DIR -pn $PART -device_version $DEVICE_VER -force

foreach f $V_FILES {
    puts "\[gowin\] + verilog: [file tail $f]"
    add_file -type verilog $f
}

if {[file exists $CST_FILE]} {
    add_file -type cst $CST_FILE
    puts "\[gowin\] + cst: [file tail $CST_FILE]"
} else {
    error "\[gowin\] ERROR: Constraint file missing: $CST_FILE"
}

if {[file exists $SDC_FILE]} {
    add_file -type sdc $SDC_FILE
    puts "\[gowin\] + sdc: [file tail $SDC_FILE]"
}

set_option -top_module       $TOP_MODULE
set_option -synthesis_tool   gowinsynthesis
set_option -output_base_name $PRJ_NAME
set_option -verilog_std      sysv2017
set_option -show_all_warn    1

puts "\[gowin\] === run syn ==="
run syn

puts "\[gowin\] === run pnr ==="
run pnr

set IMPL [file join $PRJ_DIR $PRJ_NAME impl]
set SRC_FS [file join $IMPL pnr "$PRJ_NAME.fs"]
if {[file exists $SRC_FS]} {
    set BIT_DIR [file join $ROOT bitstream]
    file mkdir $BIT_DIR
    set BIT_FS [file join $BIT_DIR "$PRJ_NAME.fs"]
    file copy -force $SRC_FS $BIT_FS
    puts "\[gowin\] SUCCESS: Generated bitstream -> $BIT_FS ([file size $BIT_FS] bytes)"
} else {
    puts "\[gowin\] ERROR: Bitstream not generated!"
}

run close
puts "\[gowin\] === DONE ==="
