# =============================================================================
#  fpga_hank ?? ?? Gowin ???????
#  ???2026 FPGA ?????????????????????????????
#  ???Sipeed Tang Mega 138K   FPGA: GW5AST-LV138PG484AC1/I0
#
#  ?????????????
#     & "F:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe" `
#       "<???>\fpga_hank\tools\gowin\build.tcl"
#  ????? [file dirname [info script]] ????? ? ???????????????
#
#  ?? 2026-10-03 ?????????????? ...\build.ps1????????????
#     ?????????????? gw_sh ???????????
#
#  ??????????? Gowin V1.9.12.04 + 138K ??????
#  ?????IDE\doc\CN\SUG1220-2.1_Gowin????Tcl??????.pdf
#
#  ?? ?????????????????????????
#    1. -synthesis_tool ????? gowinsynthesis???????
#       "unknown synthesis tool" ????????
#    2. gw_sh.exe ???? .tcl ?????[pwd] ???? CWD?
#       ????? [info script] ??????
#    3. .tcl ????? UTF-8 BOM?????????????
#       invalid command name "??oreach"?
# =============================================================================

# ---------------------------------------------------------------------------
# 0. ??????????????????
# ---------------------------------------------------------------------------
set PRJ_NAME    fpga_hank
set TOP_MODULE  top
set PART        GW5AST-LV138PG484AC1/I0
set DEVICE_VER  C

# ---------------------------------------------------------------------------
# 1. ????????????????? [pwd]
# ---------------------------------------------------------------------------
set TOOLS_DIR [file normalize [file dirname [info script]]]      ;# fpga_hank/tools/gowin
set ROOT      [file normalize [file join $TOOLS_DIR .. ..]]      ;# fpga_hank
set RTL_DIR   [file join $ROOT rtl]
set CONST_DIR [file join $ROOT constr]
set PRJ_DIR   [file join $ROOT eda_proj]

# ---------------------------------------------------------------------------
# 1b. Parse MODE from rtl/top.v, then derive the User Code.
#     (Added 2026-10-05, approved by Lead.)
#
# !!! KEEP THIS BLOCK ASCII-ONLY !!!
#   Measured 2026-10-05: Gowin's Tcl reads .tcl as the SYSTEM ANSI code page
#   (GBK on this machine), NOT as UTF-8. A Chinese char's last UTF-8 byte can be
#   >= 0x81, which then acts as a GBK LEAD byte and EATS the following byte --
#   including the 0x0A newline. That merges the next line into the comment and
#   silently comments out real code. This already happened once in this file.
#   => Chinese is only safe in comments that are followed by another comment or
#      a blank line; never immediately before code. Safest: keep additions ASCII.
#
#     user_code rule: 0x1A2B000<MODE>  (last hex digit = mode number)
#     so a bitstream's User Code identifies which MODE it was built from.
#     Official syntax is:  set_option -user_code <default|value>   (SUG1220-2.1)
#     NOT `set_user_code` -- that would abort the whole build.
# ---------------------------------------------------------------------------
set MODE 0
set TOPV [file join $RTL_DIR "$TOP_MODULE.v"]
if {[file exists $TOPV]} {
    set fh [open $TOPV r]
    set topTxt [read $fh]
    close $fh
    if {[regexp {parameter\s+integer\s+MODE\s*=\s*([0-9]+)} $topTxt -> mv]} {
        set MODE $mv
    } else {
        puts "\[gowin\] WARN: cannot parse MODE in $TOPV, assuming 0"
    }
} else {
    puts "\[gowin\] WARN: $TOPV not found, assuming MODE 0"
}
set USER_CODE [format "1A2B000%X" $MODE]
puts "\[gowin\] MODE=$MODE  user_code=0x$USER_CODE"

puts "=============================================================="
puts "\[gowin\] project : $PRJ_NAME"
puts "\[gowin\] root    : $ROOT"
puts "\[gowin\] part    : $PART  (device version $DEVICE_VER)"
puts "\[gowin\] top     : $TOP_MODULE"
puts "=============================================================="

# ---------------------------------------------------------------------------
# 2. ??????????????????????????
#    ???Gowin ????????????????????
#    ??? common ? synth ? audio ? effects ? io ? top ??????
# ---------------------------------------------------------------------------
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
# ??? rtl ???????????
foreach f [collect_v $RTL_DIR] {
    lappend V_FILES $f
}

set CST_FILE [file join $CONST_DIR "fpga_hank_full.cst"]
set SDC_FILE [file join $CONST_DIR "fpga_hank_full.sdc"]

if {[llength $V_FILES] == 0} {
    error "\[gowin\] ?????? Verilog ?????? $RTL_DIR"
}

# ---------------------------------------------------------------------------
# 3. ????
# ---------------------------------------------------------------------------
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
    puts "\[gowin\] ??  ?????? $CST_FILE??????????"
}
if {[file exists $SDC_FILE]} {
    add_file -type sdc $SDC_FILE
    puts "\[gowin\] + sdc: [file tail $SDC_FILE]"
} else {
    puts "\[gowin\] ??  ?????? $SDC_FILE ?? pnr ?? WARN(TA1132) ?????"
}

# ---------------------------------------------------------------------------
# 4. ?? / ????
# ---------------------------------------------------------------------------
set_option -top_module     $TOP_MODULE
set_option -synthesis_tool gowinsynthesis        ;# ?? ?????????? 1
set_option -output_base_name $PRJ_NAME
# ?? -verilog_std ?????? v1995 | v2001 | sysv2017?SUG1220-2.1??
#    ? sysv2009 ?? "unknown verilog language value" ??????
set_option -verilog_std    sysv2017
set_option -include_path   [file join $RTL_DIR ui]
set_option -show_all_warn  1

# Explicit User Code (approved 2026-10-05): turns User Code from a per-build
# random value into a design identifier. Wrapped in catch so a tool version that
# rejects the option can never abort the build.
if {[catch {set_option -user_code $USER_CODE} em]} {
    puts "\[gowin\] WARN: set_option -user_code failed: $em (continuing)"
} else {
    puts "\[gowin\] + user_code: 0x$USER_CODE"
}

# ??????? ModelSim??? Verilog ?????
catch {set_option -gen_verilog_sim_netlist 1}

# ---------------------------------------------------------------------------
# 5. ??????? -Stage ???????? build.ps1?
# ---------------------------------------------------------------------------
set STAGE "all"
if {[info exists ::env(GOWIN_STAGE)]} { set STAGE $::env(GOWIN_STAGE) }

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

# ---------------------------------------------------------------------------
# 6. Summarise products and key warnings (a build that "looks fine" is not proof).
#
#    FIXED 2026-10-05 (measured): the product path is
#        eda_proj\<PRJ_NAME>\impl\...     (Gowin adds a project-named subdir)
#    It used to be eda_proj\impl -- WHICH DOES NOT EXIST. So this whole section
#    (product listing / resource summary / TA1132+PR1014 warning detection)
#    silently printed NOTHING, and `glob -nocomplain` never complained.
# ---------------------------------------------------------------------------
set IMPL [file join $PRJ_DIR $PRJ_NAME impl]
puts "--------------------------------------------------------------"
puts "\[gowin\] ?????"
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
    # ???????????????
    if {[regexp {Resource Usage Summary(.*?)(?:=====|I/O Bank)} $txt -> seg]} {
        puts "\[gowin\] --- ???? ---"
        foreach line [split $seg \n] {
            set line [string trim $line]
            if {$line ne ""} { puts "\[gowin\]   $line" }
        }
    }
    # ?????????????????/???????
    foreach pat {{TA1132} {PR1014}} {
        if {[string first $pat $txt] >= 0} {
            puts "\[gowin\] ??  ????? $pat ?? ? fpga_hank/README.md ?????"
        }
    }
}

# ---------------------------------------------------------------------------
# 7. Auto-archive the bitstream. (Added 2026-10-05, approved by Lead.)
#    Why: the MODE=2 bitstream was once lost because archiving relied on a human.
#    Rules:
#      . target: out/bitstream/MODE<n>_<tag>_<yyyyMMdd-HHmmss>.fs   (ASCII only)
#      . if that name already exists, append _b2/_b3/... -- NEVER overwrite
#      . also write <archive>.usercode for tools/gowin/program.ps1 to record
#    Wrapped in catch: an archiving failure must never affect the build verdict.
# ---------------------------------------------------------------------------
if {[catch {
    set SRC_FS [file join $IMPL pnr "$PRJ_NAME.fs"]
    if {[file exists $SRC_FS]} {
        set ARCH_DIR [file join $ROOT out bitstream]
        file mkdir $ARCH_DIR
        # Archive file names must be ASCII: Gowin's Tcl reads this file as GBK,
        # so a Chinese string literal would land on disk as mojibake
        # (e.g. MODE2_??????_...). Chinese is only safe inside comments.
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
            puts "\[gowin\] archived: [file tail $DST_FS]  ([file size $DST_FS] bytes)"
            set fh [open "${DST_FS}.usercode" w]
            puts $fh $USER_CODE
            close $fh
        } else {
            puts "\[gowin\] WARN: archive target not created: $DST_FS"
        }
    } else {
        puts "\[gowin\] no $PRJ_NAME.fs this run (stage=$STAGE, maybe syn only) -> archive skipped"
    }
} em]} {
    puts "\[gowin\] WARN: auto-archive failed (build result unaffected): $em"
}

run close
puts "\[gowin\] === DONE (stage=$STAGE) ==="

