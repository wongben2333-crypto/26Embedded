# Build script for LCD test on GW5AST-138C (Commercial C-stepping)
set PRJ_NAME lcd_test_138c
set PART GW5AST-LV138PG484AC1/I0
set DEVICE_VER C

set SCRIPT_DIR [file normalize [file dirname [info script]]]
set RTL_FILE [file join $SCRIPT_DIR "rtl" "lcd_test_top.v"]
set CST_FILE [file join $SCRIPT_DIR "constraints" "lcd_test.cst"]
set PRJ_DIR [file join $SCRIPT_DIR "eda_138c"]

puts "========================================================"
puts "Building LCD test for GW5AST-138C..."
puts "Project dir: $PRJ_DIR"
puts "Part: $PART (Version $DEVICE_VER)"
puts "========================================================"

file mkdir $PRJ_DIR
cd $PRJ_DIR

create_project -name $PRJ_NAME -dir $PRJ_DIR -pn $PART -device_version $DEVICE_VER -force

add_file -type verilog $RTL_FILE
add_file -type cst $CST_FILE

set_option -top_module lcd_test_top
set_option -synthesis_tool gowinsynthesis
set_option -output_base_name $PRJ_NAME
set_option -verilog_std sysv2017
set_option -show_all_warn 1

puts "=== Running Synthesis ==="
run syn

puts "=== Running P&R ==="
run pnr

puts "=== Build Complete ==="
set BITSTREAM [file join $PRJ_DIR $PRJ_NAME "impl" "pnr" "$PRJ_NAME.fs"]
if {[file exists $BITSTREAM]} {
    puts "SUCCESS: Bitstream generated at $BITSTREAM"
    set DST [file join $SCRIPT_DIR "bitstream" "lcd_test_138c.fs"]
    file copy -force $BITSTREAM $DST
    puts "Copied bitstream to $DST"
} else {
    puts "ERROR: Bitstream not found!"
}
exit
