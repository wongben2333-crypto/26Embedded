# =============================================================================
#  fpga_hank —— 高云 Gowin 全链路构建脚本
#  赛题：2026 FPGA 创新设计赛道·高云杯·选题二（实时多音色合成电子乐器引擎）
#  板卡：Sipeed Tang Mega 138K   FPGA: GW5AST-LV138PG484AC1/I0
#
#  用法（任一工作目录均可）：
#     & "F:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe" `
#       "C:\Users\Danny\Desktop\FPGA competition\fpga_hank\tools\gowin\build.tcl"
#
#  或走包装脚本：  .\fpga_hank\tools\gowin\build.ps1 [-Stage syn|pnr|all]
#
#  本脚本的每条命令都已在 Gowin V1.9.12.04 + 138K 上实测通过。
#  权威文档：IDE\doc\CN\SUG1220-2.1_Gowin云源软件Tcl命令用户指南.pdf
#
#  ⚠️ 三个实测踩过的坑（改动本文件时务必保留对应处理）：
#    1. -synthesis_tool 只能是小写 gowinsynthesis，其它取值会报
#       "unknown synthesis tool" 并中断整个脚本。
#    2. gw_sh.exe 不会切到 .tcl 所在目录；[pwd] 是调用者 CWD，
#       因此必须用 [info script] 定位工程根。
#    3. .tcl 文件不能带 UTF-8 BOM，否则第一条命令会被解析成
#       invalid command name "??oreach"。
# =============================================================================

# ---------------------------------------------------------------------------
# 0. 可配置项（改这里，不要改下面的流程）
# ---------------------------------------------------------------------------
set PRJ_NAME    fpga_hank
set TOP_MODULE  top
set PART        GW5AST-LV138PG484AC1/I0
set DEVICE_VER  C

# ---------------------------------------------------------------------------
# 1. 路径：必须基于脚本自身位置，不能用 [pwd]
# ---------------------------------------------------------------------------
set TOOLS_DIR [file normalize [file dirname [info script]]]      ;# fpga_hank/tools/gowin
set ROOT      [file normalize [file join $TOOLS_DIR .. ..]]      ;# fpga_hank
set RTL_DIR   [file join $ROOT rtl]
set CONST_DIR [file join $ROOT constr]
set PRJ_DIR   [file join $ROOT eda_proj]

puts "=============================================================="
puts "\[gowin\] project : $PRJ_NAME"
puts "\[gowin\] root    : $ROOT"
puts "\[gowin\] part    : $PART  (device version $DEVICE_VER)"
puts "\[gowin\] top     : $TOP_MODULE"
puts "=============================================================="

# ---------------------------------------------------------------------------
# 2. 收集源文件（按目录，避免手工维护文件清单导致漏文件）
#    注意：Gowin 对文件加入顺序敏感（先叶子后顶层最稳），
#    这里按 common → synth → audio → effects → io → top 的顺序加入。
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
foreach sub {common synth audio effects io} {
    foreach f [collect_v [file join $RTL_DIR $sub]] {
        lappend V_FILES $f
    }
}
# 顶层与 rtl 根下的散装文件最后加入
foreach f [collect_v $RTL_DIR] {
    lappend V_FILES $f
}

set CST_FILE [file join $CONST_DIR "$PRJ_NAME.cst"]
set SDC_FILE [file join $CONST_DIR "$PRJ_NAME.sdc"]

if {[llength $V_FILES] == 0} {
    error "\[gowin\] 没有找到任何 Verilog 源文件，检查 $RTL_DIR"
}

# ---------------------------------------------------------------------------
# 3. 创建工程
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
    puts "\[gowin\] ⚠️  缺少物理约束 $CST_FILE（引脚将不会被约束）"
}
if {[file exists $SDC_FILE]} {
    add_file -type sdc $SDC_FILE
    puts "\[gowin\] + sdc: [file tail $SDC_FILE]"
} else {
    puts "\[gowin\] ⚠️  缺少时序约束 $SDC_FILE —— pnr 会报 WARN(TA1132) 未创建时钟"
}

# ---------------------------------------------------------------------------
# 4. 综合 / 布线选项
# ---------------------------------------------------------------------------
set_option -top_module     $TOP_MODULE
set_option -synthesis_tool gowinsynthesis        ;# ⚠️ 必须小写，见文件头坑 1
set_option -output_base_name $PRJ_NAME
# ⚠️ -verilog_std 的合法值只有 v1995 | v2001 | sysv2017（SUG1220-2.1）。
#    写 sysv2009 会报 "unknown verilog language value" 并中断脚本。
set_option -verilog_std    sysv2017
set_option -show_all_warn  1

# 便于把设计喂给 ModelSim（生成 Verilog 仿真网表）
catch {set_option -gen_verilog_sim_netlist 1}

# ---------------------------------------------------------------------------
# 5. 运行流程（可用 -Stage 从命令行覆盖：见 build.ps1）
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
# 6. 汇总产物与关键告警（构建"看起来成功"不等于成功，见 README）
# ---------------------------------------------------------------------------
set IMPL [file join $PRJ_DIR impl]
puts "--------------------------------------------------------------"
puts "\[gowin\] 产物清单："
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
    # 抽取资源占用段，供人眼快速核对
    if {[regexp {Resource Usage Summary(.*?)(?:=====|I/O Bank)} $txt -> seg]} {
        puts "\[gowin\] --- 资源占用 ---"
        foreach line [split $seg \n] {
            set line [string trim $line]
            if {$line ne ""} { puts "\[gowin\]   $line" }
        }
    }
    # 关键告警检出：这两条意味着约束缺失/时钟走通用布线
    foreach pat {{TA1132} {PR1014}} {
        if {[string first $pat $txt] >= 0} {
            puts "\[gowin\] ⚠️  报告中出现 $pat —— 见 fpga_hank/README.md 的告警说明"
        }
    }
}

run close
puts "\[gowin\] === DONE (stage=$STAGE) ==="
