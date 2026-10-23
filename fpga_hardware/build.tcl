# =============================================================================
#  fpga_hardware / build.tcl -- Tang Mega 60K build (GW5AT-LV60PG484AC1/I0, dev B)
#
#  Self-contained: reads   ./rtl  ./constr   writes  ./eda_proj  ./out
#  MODE is read from rtl/top.v (0=demo, 1=pc-control, 2=32-peak test,
#  3=hardware instrument <- this branch).  The archive name and user_code are
#  derived from MODE.
#
#  ASCII only on purpose: Gowin's Tcl parser reads files as the system ANSI
#  code page (GBK here), so non-ASCII can swallow the following newline.
#  No UTF-8 BOM (a BOM gives "invalid command name").
#
#  Optional override for experiments (e.g. building MODE=1 from a copy):
#      set HANK_RTL_DIR=<dir>   before running
# =============================================================================

set PRJ_NAME   fpga_hardware_60k
set TOP_MODULE top
set PART       GW5AT-LV60PG484AC1/I0
set DEVICE_VER B

set WORK      [file normalize [file dirname [info script]]]
set RTL_DIR   [file join $WORK rtl]
if {[info exists ::env(HANK_RTL_DIR)]} {
    set RTL_DIR [file normalize $::env(HANK_RTL_DIR)]
    puts "\[hw\] RTL override: $RTL_DIR"
}
set CONST_DIR [file join $WORK constr]
set PRJ_DIR   [file join $WORK eda_proj]
set OUT_DIR   [file join $WORK out]

# ---- read MODE from rtl/top.v -------------------------------------------
set MODE 3
set TOPV [file join $RTL_DIR "$TOP_MODULE.v"]
if {[file exists $TOPV]} {
    set fh [open $TOPV r]
    set topTxt [read $fh]
    close $fh
    if {[regexp {parameter\s+integer\s+MODE\s*=\s*([0-9]+)} $topTxt -> mv]} {
        set MODE $mv
    } else {
        puts "\[hw\] WARN: cannot parse MODE, assuming 3"
    }
}
set USER_CODE [format "1A2B000%X" $MODE]
puts "\[hw\] MODE=$MODE  user_code=0x$USER_CODE"
puts "\[hw\] part=$PART  device_version=$DEVICE_VER"

# ---- collect sources -----------------------------------------------------
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
foreach sub {common synth audio effects io} {
    foreach f [collect_v [file join $RTL_DIR $sub]] {
        lappend V_FILES $f
    }
}
foreach f [collect_v $RTL_DIR] {
    lappend V_FILES $f
}
if {[llength $V_FILES] == 0} {
    error "\[hw\] no Verilog sources under $RTL_DIR"
}

set CST_FILE [file join $CONST_DIR "$PRJ_NAME.cst"]
if {![file exists $CST_FILE]} {
    set CST_FILE [file join $CONST_DIR "fpga_hank_60k.cst"]
}
set SDC_FILE [file join $CONST_DIR "fpga_hank_60k.sdc"]

# ---- create project ------------------------------------------------------
file mkdir $PRJ_DIR
cd $PRJ_DIR
create_project -name $PRJ_NAME -dir $PRJ_DIR -pn $PART -device_version $DEVICE_VER -force

foreach f $V_FILES {
    add_file -type verilog $f
}
if {[file exists $CST_FILE]} {
    add_file -type cst $CST_FILE
    puts "\[hw\] + cst: [file tail $CST_FILE]"
} else {
    error "\[hw\] missing cst: $CST_FILE"
}
if {[file exists $SDC_FILE]} {
    add_file -type sdc $SDC_FILE
    puts "\[hw\] + sdc: [file tail $SDC_FILE]"
} else {
    puts "\[hw\] WARN: missing sdc"
}

# ---- options -------------------------------------------------------------
set_option -top_module     $TOP_MODULE
set_option -synthesis_tool gowinsynthesis
set_option -output_base_name $PRJ_NAME
set_option -verilog_std    sysv2017
set_option -show_all_warn  1
# P19 (J9-11) is a dedicated CPU pin on GW5A-60; used by the debug UART.
if {[catch {set_option -use_cpu_as_gpio 1} emcpu]} {
    puts "\[hw\] WARN: use_cpu_as_gpio failed: $emcpu"
}
if {[catch {set_option -user_code $USER_CODE} em]} {
    puts "\[hw\] WARN: user_code failed: $em"
}

# ---- run -----------------------------------------------------------------
set STAGE "all"
if {[info exists ::env(GOWIN_STAGE)]} { set STAGE $::env(GOWIN_STAGE) }
switch -- $STAGE {
    syn { run syn }
    pnr { run pnr }
    default { run syn ; run pnr }
}

# ---- report --------------------------------------------------------------
set IMPL [file join $PRJ_DIR $PRJ_NAME impl]
puts "--------------------------------------------------------------"
foreach f [lsort [glob -nocomplain [file join $IMPL gwsynthesis *.vg] \
                                   [file join $IMPL pnr *.fs] \
                                   [file join $IMPL pnr *.rpt.txt] \
                                   [file join $IMPL pnr *.pin.html]]] {
    puts [format "\[hw\]   %-24s %10d bytes" [file tail $f] [file size $f]]
}

set RPT [file join $IMPL pnr "$PRJ_NAME.rpt.txt"]
if {[file exists $RPT]} {
    set fh [open $RPT r]
    set txt [read $fh]
    close $fh
    if {[regexp {Resource Usage Summary(.*?)(?:=====|I/O Bank)} $txt -> seg]} {
        puts "\[hw\] --- resources ---"
        foreach line [split $seg \n] {
            set line [string trim $line]
            if {$line ne ""} { puts "\[hw\]   $line" }
        }
    }
    foreach pat {{TA1132} {PR1014}} {
        if {[string first $pat $txt] >= 0} {
            puts "\[hw\] WARN: report contains $pat"
        }
    }
}

# ---- timing (setup/hold worst slack) ------------------------------------
set TP [file join $IMPL pnr "$PRJ_NAME.timing_paths"]
if {[file exists $TP]} {
    set fh [open $TP r]
    set tl [split [read $fh] \n]
    close $fh
    puts "\[hw\] --- timing ---"
    for {set i 0} {$i < [llength $tl]} {incr i} {
        set ln [string trim [lindex $tl $i]]
        if {$ln eq "SETUP"} { puts "\[hw\]   SETUP worst slack: [string trim [lindex $tl [expr {$i+1}]]]" }
        if {$ln eq "HOLD"}  { puts "\[hw\]   HOLD  worst slack: [string trim [lindex $tl [expr {$i+1}]]]" }
    }
}

# ---- archive -------------------------------------------------------------
if {[catch {
    set SRC_FS [file join $IMPL pnr "$PRJ_NAME.fs"]
    if {[file exists $SRC_FS]} {
        set ARCH_DIR [file join $OUT_DIR bitstream]
        file mkdir $ARCH_DIR
        switch -- $MODE {
            0 { set MODE_TAG "demo" }
            1 { set MODE_TAG "pcctrl" }
            2 { set MODE_TAG "test32" }
            default { set MODE_TAG "mode$MODE" }
        }
        set STAMP [clock format [clock seconds] -format {%Y%m%d-%H%M%S}]
        set BASE  "MODE${MODE}_${MODE_TAG}_60K_${STAMP}"
        set DST_FS [file join $ARCH_DIR "${BASE}.fs"]
        set n 1
        while {[file exists $DST_FS]} {
            incr n
            set DST_FS [file join $ARCH_DIR "${BASE}_b${n}.fs"]
        }
        file copy $SRC_FS $DST_FS
        puts "\[hw\] archived: [file tail $DST_FS] ([file size $DST_FS] bytes)"
        set fh [open "${DST_FS}.usercode" w]
        puts $fh $USER_CODE
        close $fh
    } else {
        puts "\[hw\] no .fs this run"
    }
} em]} {
    puts "\[hw\] WARN: archive failed: $em"
}

run close
puts "\[hw\] === DONE (stage=$STAGE) ==="
