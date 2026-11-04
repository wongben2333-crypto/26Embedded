# =============================================================================
#  fpga_spark/lcd_test -- Gowin CLI Build Script (GW5AST-138C + J13 HW + J14 LCD)
# =============================================================================

set PRJ_NAME    lcd_test_j14
set TOP_MODULE  top
set PART        GW5AST-LV138PG484AC1/I0
set DEVICE_VER  C

set TOOLS_DIR [file normalize [file dirname [info script]]]
set ROOT      [file normalize [file join $TOOLS_DIR .. ..]]
set RTL_DIR   [file join $ROOT rtl]
set CONST_DIR [file join $ROOT constraints]
set PRJ_DIR   [file join $ROOT eda_proj]

set MODE 3
set TOPV [file join $RTL_DIR "$TOP_MODULE.v"]
if {[file exists $TOPV]} {
    set fh [open $TOPV r]
    set topTxt [read $fh]
    close $fh
    if {[regexp {parameter\s+integer\s+MODE\s*=\s*([0-9]+)} $topTxt -> mv]} {
        set MODE $mv
    } else {
        puts "\[gowin\] WARN: cannot parse MODE in $TOPV, assuming 3"
    }
}
set USER_CODE [format "1A2B000%X" $MODE]
puts "\[gowin\] MODE=$MODE  user_code=0x$USER_CODE"

puts "=============================================================="
puts "\[gowin\] project : $PRJ_NAME"
puts "\[gowin\] root    : $ROOT"
puts "\[gowin\] part    : $PART  (device version $DEVICE_VER)"
puts "\[gowin\] top     : $TOP_MODULE"
puts "=============================================================="

proc collect_v {dir} {
    set out {}
    if {[file isdirectory $dir]} {
        foreach f [lsort [glob -nocomplain -directory $dir *.v *.sv]] {
            lappend out $f
        }
    }
    return $out
}

set V_FILES {}
foreach sub {common synth audio effects io ui} {
    foreach f [collect_v [file join $RTL_DIR $sub]] {
        lappend V_FILES $f
    }
}
foreach f [collect_v $RTL_DIR] {
    lappend V_FILES $f
}

set CST_FILE [file join $CONST_DIR "lcd_test_j14.cst"]
set SDC_FILE [file join $CONST_DIR "lcd_test_j14.sdc"]

if {[llength $V_FILES] == 0} {
    error "\[gowin\] ERROR: No Verilog files found in $RTL_DIR"
}

set STAGE "all"
if {[info exists ::env(GOWIN_STAGE)]} { set STAGE $::env(GOWIN_STAGE) }

set EXISTING_GPRJ [file join $PRJ_DIR $PRJ_NAME "${PRJ_NAME}.gprj"]
set EXISTING_VG   [file join $PRJ_DIR $PRJ_NAME impl gwsynthesis "${PRJ_NAME}.vg"]

if {$STAGE eq "pnr" && [file exists $EXISTING_GPRJ] && [file exists $EXISTING_VG]} {
    puts "\[gowin\] Reusing existing synthesized netlist: $EXISTING_VG"
    open_project $EXISTING_GPRJ
} else {
    file mkdir $PRJ_DIR
    cd $PRJ_DIR
    create_project -name $PRJ_NAME -dir $PRJ_DIR -pn $PART -device_version $DEVICE_VER -force

    foreach f $V_FILES {
        puts "\[gowin\] + [file join rtl [file tail [file dirname $f]] [file tail $f]]"
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
    } else {
        puts "\[gowin\] WARN: SDC file missing: $SDC_FILE"
    }
}

set_option -top_module       $TOP_MODULE
set_option -synthesis_tool   gowinsynthesis
set_option -output_base_name $PRJ_NAME
set_option -verilog_std      sysv2017
set_option -include_path     [file join $RTL_DIR ui]
set_option -show_all_warn    1

if {[catch {set_option -user_code $USER_CODE} em]} {
    puts "\[gowin\] WARN: set_option -user_code failed: $em (continuing)"
} else {
    puts "\[gowin\] + user_code: 0x$USER_CODE"
}

catch {set_option -gen_verilog_sim_netlist 1}

switch -- $STAGE {
    syn {
        puts "\[gowin\] === run syn ==="
        run syn
    }
    pnr {
        puts "\[gowin\] === run pnr ==="
        run pnr
    }
    default {
        puts "\[gowin\] === run syn ==="
        run syn
        puts "\[gowin\] === run pnr ==="
        run pnr
    }
}

set IMPL [file join $PRJ_DIR $PRJ_NAME impl]
puts "--------------------------------------------------------------"
puts "\[gowin\] Build products:"
foreach f [lsort [glob -nocomplain [file join $IMPL gwsynthesis *.vg] \
                                   [file join $IMPL gwsynthesis *_syn.rpt.html] \
                                   [file join $IMPL pnr *.fs] \
                                   [file join $IMPL pnr *.tr.html] \
                                   [file join $IMPL pnr *.rpt.txt] \
                                   [file join $IMPL pnr *.pin.html]]] {
    puts [format "\[gowin\]   %-24s %10d bytes" [file tail $f] [file size $f]]
}

set RPT [file join $IMPL pnr "$PRJ_NAME.rpt.txt"]
if {[file exists $RPT]} {
    set fh [open $RPT r]
    set txt [read $fh]
    close $fh
    if {[regexp {Resource Usage Summary(.*?)(?:=====|I/O Bank)} $txt -> seg]} {
        puts "\[gowin\] --- Resource Usage Summary ---"
        foreach line [split $seg \n] {
            set line [string trim $line]
            if {$line ne ""} { puts "\[gowin\]   $line" }
        }
    }
}

if {[catch {
    set SRC_FS [file join $IMPL pnr "$PRJ_NAME.fs"]
    if {[file exists $SRC_FS]} {
        # 1. Copy to bitstream/lcd_test_j14.fs (primary target for burn_lcd_j14.py)
        set BIT_DIR [file join $ROOT bitstream]
        file mkdir $BIT_DIR
        set BIT_FS [file join $BIT_DIR "lcd_test_j14.fs"]
        catch {file attributes $BIT_FS -readonly 0}
        file copy -force $SRC_FS $BIT_FS
        puts "\[gowin\] updated: bitstream/lcd_test_j14.fs ([file size $BIT_FS] bytes)"

        # 2. Copy to impl/pnr/lcd_test_j14.fs (Gowin IDE default path)
        set IDE_PNR [file join $ROOT impl pnr]
        file mkdir $IDE_PNR
        set IDE_FS [file join $IDE_PNR "lcd_test_j14.fs"]
        catch {file attributes $IDE_FS -readonly 0}
        file copy -force $SRC_FS $IDE_FS

        # 3. Archive timestamped bitstream in out/bitstream/
        set ARCH_DIR [file join $ROOT out bitstream]
        file mkdir $ARCH_DIR
        switch -- $MODE {
            0 { set MODE_TAG "demo"     }
            1 { set MODE_TAG "pcctrl"   }
            2 { set MODE_TAG "test32"   }
            3 { set MODE_TAG "freeplay" }
            default { set MODE_TAG "mode$MODE" }
        }
        set STAMP [clock format [clock seconds] -format {%Y%m%d-%H%M%S}]
        set BASE  "MODE${MODE}_${MODE_TAG}_${STAMP}"
        set DST_FS [file join $ARCH_DIR "${BASE}.fs"]
        set n 1
        while {[file exists $DST_FS]} {
            incr n
            set DST_FS [file join $ARCH_DIR "${BASE}_b${n}.fs"]
        }
        file copy $SRC_FS $DST_FS
        if {[file exists $DST_FS]} {
            puts "\[gowin\] archived: [file tail $DST_FS] ([file size $DST_FS] bytes)"
            set fh [open "${DST_FS}.usercode" w]
            puts $fh $USER_CODE
            close $fh
        }
    }
} em]} {
    puts "\[gowin\] WARN: bitstream copy/archive warning: $em"
}

run close
puts "\[gowin\] === DONE (stage=$STAGE) ==="
