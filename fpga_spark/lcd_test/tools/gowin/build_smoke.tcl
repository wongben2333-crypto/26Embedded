# =============================================================================
#  build_smoke.tcl —— 「分级上板冒烟测试」构建脚本（S0–S6 任选一级）
#
#  用法（任一工作目录均可）：
#     $env:SMOKE_STAGE = "2"          # 0..6；不设则默认 2
#     & "F:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe" `
#       "C:\Users\Danny\Desktop\FPGA competition\fpga_hank\tools\gowin\build_smoke.tcl"
#
#  或走包装脚本一次构建全部 7 级：
#     powershell -NoProfile -ExecutionPolicy Bypass -File `
#       "C:\Users\Danny\Desktop\FPGA competition\fpga_hank\tools\gowin\build_smoke.ps1"
#
#  ★ 本脚本沿用 tools/gowin/build.tcl 已经踩平的坑，改动时务必保留：
#    (1) -synthesis_tool 只能是小写 gowinsynthesis，其它取值报
#        "unknown synthesis tool" 并中断整个脚本。
#    (2) gw_sh.exe 不会切到 .tcl 所在目录 → 必须用 [info script] 定位工程根。
#    (3) .tcl 不能带 UTF-8 BOM，否则首条命令变成 invalid command name "??oreach"。
#    (4) -verilog_std 只接受 v1995 | v2001 | sysv2017。
#
#  ★ 为什么用 -top_module 选级，而不是 -D 宏：
#    本机 gw_sh V1.9.12.04 的 set_option / add_file 都不认识
#    -define / -verilog_define / -compile_macro / -verilog_macro（已逐条实测，
#    见 _smoke-test/probe_opt.tcl 与 REPORT.md）。所以 rtl/smoke_top.v 末尾为
#    每级提供一个薄封装模块 smoke_top_s0 … smoke_top_s6，本脚本只改 -top_module。
#    rtl/smoke_top.v 始终被【原样】综合，没有任何按级生成的副本。
#
#  ★ 产物落在 _smoke-test/eda_s<N>/（不污染 fpga_hank/）。
# =============================================================================

# ---------------------------------------------------------------------------
# 0. 参数
# ---------------------------------------------------------------------------
set TOP_PREFIX smoke_top_s
set PART       GW5AST-LV138PG484AC1/I0
set DEVICE_VER C

set STAGE 2
if {[info exists ::env(SMOKE_STAGE)]} { set STAGE $::env(SMOKE_STAGE) }
if {![string is integer -strict $STAGE] || $STAGE < 0 || $STAGE > 6} {
    error "\[smoke\] SMOKE_STAGE 必须是 0..6 的整数，收到：$STAGE"
}

set PRJ_NAME "$TOP_PREFIX$STAGE"
set TOP_MODULE $PRJ_NAME

# ---------------------------------------------------------------------------
# 1. 路径：必须基于脚本自身位置，不能用 [pwd]
# ---------------------------------------------------------------------------
set TOOLS_DIR [file normalize [file dirname [info script]]]     ;# fpga_hank/tools/gowin
set ROOT      [file normalize [file join $TOOLS_DIR .. ..]]      ;# fpga_hank
set RTL_DIR   [file join $ROOT rtl]
set CONST_DIR [file join $ROOT constr]
set OUT_ROOT  [file normalize [file join $ROOT .. _smoke-test]]  ;# 竞赛根/_smoke-test
set PRJ_DIR   [file join $OUT_ROOT "eda_s$STAGE"]

puts "=============================================================="
puts "\[smoke\] stage   : S$STAGE"
puts "\[smoke\] top     : $TOP_MODULE"
puts "\[smoke\] root    : $ROOT"
puts "\[smoke\] project : $PRJ_DIR"
puts "\[smoke\] part    : $PART  (device version $DEVICE_VER)"
puts "=============================================================="

# ---------------------------------------------------------------------------
# 2. 收集源文件（按目录，避免手工维护清单导致漏文件）
#    与 build.tcl 同序：common → synth → audio → effects → io → rtl 根
#    ★ 唯一区别：跳过 rtl/top.v（生产顶层，冒烟工程不需要，避免多一个顶层候选）
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
foreach sub {common synth audio effects io smoke} {
    foreach f [collect_v [file join $RTL_DIR $sub]] {
        lappend V_FILES $f
    }
}
foreach f [collect_v $RTL_DIR] {
    if {[file tail $f] eq "top.v"} {
        puts "\[smoke\] (跳过 rtl/top.v —— 生产顶层，不参与冒烟工程)"
        continue
    }
    lappend V_FILES $f
}

set CST_FILE [file join $CONST_DIR smoke.cst]
set SDC_FILE [file join $CONST_DIR smoke.sdc]

if {[llength $V_FILES] == 0} { error "\[smoke\] 没有找到任何 Verilog 源文件，检查 $RTL_DIR" }
if {![file exists $CST_FILE]} { error "\[smoke\] 缺少物理约束 $CST_FILE —— 引脚会静默自动摆放，拒绝构建" }

# ---------------------------------------------------------------------------
# 3. 创建工程
# ---------------------------------------------------------------------------
file mkdir $PRJ_DIR
cd $PRJ_DIR
create_project -name $PRJ_NAME -dir $PRJ_DIR -pn $PART -device_version $DEVICE_VER -force

foreach f $V_FILES {
    # ★ 打印【字节数 + 修改时间】：本仓库多个 agent 会同时改 rtl/，
    #   不记录修订号的话，"某级构建通过"过一会儿就说不清是用哪版源码构建的。
    puts [format "\[smoke\] + %-38s %7d B  %s" \
              [file join rtl [file tail [file dirname $f]] [file tail $f]] \
              [file size $f] [clock format [file mtime $f] -format {%Y-%m-%d %H:%M:%S}]]
    add_file -type verilog $f
}
add_file -type cst $CST_FILE
puts "\[smoke\] + cst: [file tail $CST_FILE]"
if {[file exists $SDC_FILE]} {
    add_file -type sdc $SDC_FILE
    puts "\[smoke\] + sdc: [file tail $SDC_FILE]"
} else {
    puts "\[smoke\] ⚠️  缺少时序约束 $SDC_FILE —— pnr 会按 100 MHz 过度约束"
}

# ---------------------------------------------------------------------------
# 4. 综合 / 布线选项（与 build.tcl 逐条对齐）
# ---------------------------------------------------------------------------
set_option -top_module       $TOP_MODULE
set_option -synthesis_tool   gowinsynthesis      ;# ⚠️ 必须小写
set_option -output_base_name $PRJ_NAME
set_option -verilog_std      sysv2017            ;# 只接受 v1995 | v2001 | sysv2017
set_option -show_all_warn    1
catch {set_option -gen_verilog_sim_netlist 1}

# ---------------------------------------------------------------------------
# 5. 跑流程
#    ⚠️ run syn / run pnr 失败时会抛 Tcl 错误并【直接中断脚本】，
#       后面的产物核对与引脚核对全都跑不到 —— 于是"构建失败"看起来像
#       "脚本崩了"。这里用 catch 包住，保证无论成败都走到核对段并打印 PASS/FAIL。
# ---------------------------------------------------------------------------
set syn_ok 1
set pnr_ok 1
puts "\[smoke\] === run syn ==="
if {[catch {run syn} e]} {
    set syn_ok 0
    puts "\[smoke\] ❌ run syn 报错：$e"
}
puts "\[smoke\] === run pnr ==="
if {[catch {run pnr} e]} {
    set pnr_ok 0
    puts "\[smoke\] ❌ run pnr 报错：$e"
}

# ---------------------------------------------------------------------------
# 6. 结果核对
#    "退出码为 0" 不等于成功：必须核对 bitstream 是否产出 + 资源 + 引脚落位。
#    ⚠️ create_project -dir X -name N 的真实工程目录是 X/N（多一层），
#       不是 X —— build.tcl 里 $PRJ_DIR/impl 这种写法在产物核对段是拿不到文件的。
# ---------------------------------------------------------------------------
set IMPL [file join $PRJ_DIR $PRJ_NAME impl]

puts "--------------------------------------------------------------"
puts "\[smoke\] 产物清单："
foreach f [lsort [glob -nocomplain [file join $IMPL gwsynthesis *.vg] \
                                   [file join $IMPL gwsynthesis *_syn.rpt.html] \
                                   [file join $IMPL pnr *.fs] \
                                   [file join $IMPL pnr *.tr.html] \
                                   [file join $IMPL pnr *.rpt.txt] \
                                   [file join $IMPL pnr *.pin.html]]] {
    puts [format "\[smoke\]   %-28s %10d bytes" [file tail $f] [file size $f]]
}

# ---- 6.1 bitstream 是否真的产出 ----
set FS [file join $IMPL pnr "$PRJ_NAME.fs"]
set fs_ok 0
if {[file exists $FS] && [file size $FS] > 0} {
    set fs_ok 1
    puts "\[smoke\] ✅ bitstream: [file tail $FS]  ([file size $FS] bytes)"
} else {
    puts "\[smoke\] ❌ 没有产出 bitstream $FS —— 构建失败"
}

# ---- 6.0 P&R 报错行（会直接点名被拒绝的引脚）----
set RPT [file join $IMPL pnr "$PRJ_NAME.rpt.txt"]
if {[file exists $RPT]} {
    set fh [open $RPT r]
    set errtxt [read $fh]
    close $fh
    set nerr 0
    foreach line [split $errtxt \n] {
        if {[string first "ERROR" $line] >= 0} {
            incr nerr
            puts "\[smoke\]   ERROR行: [string trim $line]"
        }
    }
    puts "\[smoke\] .rpt.txt 中 ERROR 行数 = $nerr"
}

# ---- 6.2 资源占用 ----
set RPT [file join $IMPL pnr "$PRJ_NAME.rpt.txt"]
if {[file exists $RPT]} {
    set fh [open $RPT r]
    set txt [read $fh]
    close $fh
    if {[regexp {Resource Usage Summary(.*?)(?:=====|I/O Bank)} $txt -> seg]} {
        puts "\[smoke\] --- 资源占用（Resource Usage Summary）---"
        foreach line [split $seg \n] {
            set line [string trim $line]
            if {$line ne ""} { puts "\[smoke\]   $line" }
        }
    } else {
        puts "\[smoke\] ⚠️  .rpt.txt 里没找到 Resource Usage Summary 段"
    }
    foreach pat {{TA1132} {PR1014}} {
        if {[string first $pat $txt] >= 0} {
            puts "\[smoke\] ⚠️  报告中出现 $pat"
        }
    }
}

# ---- 6.3 引脚落位（关键：确认 .cst 真的生效，而不是被静默自动摆放）----
proc print_pin_table {path} {
    if {![file exists $path]} {
        puts "\[smoke\] ⚠️  找不到引脚报告 $path"
        return 0
    }
    set fh [open $path r]
    set txt [read $fh]
    close $fh

    # 只取 "Pinout by Port Name" 段落（后面的 All Package Pins 是另一张表）
    # ⚠️ 必须匹配【锚点】<a name="...">，不能匹配裸字符串：
    #    文档顶部目录里有 "Pinout_by_Port_Name" 和 "All_Package_Pins" 两个链接，
    #    用裸字符串会把切割点落到目录上，结果永远解析出 0 个端口。
    set i [string first {<a name="Pinout_by_Port_Name">} $txt]
    if {$i >= 0} { set txt [string range $txt $i end] }
    set j [string first {<a name="All_Package_Pins">} $txt]
    if {$j > 0} { set txt [string range $txt 0 $j] }

    set nport 0
    set nuncon 0
    puts "\[smoke\] --- 引脚落位（Port / Loc.Bank / 是否被.cst约束 / 方向）---"
    # ⚠️ 不能用 [split $txt "<tr>"] 去切行！Tcl 的 split 第二个参数是【字符集合】
    #    而不是分隔字符串 —— 写 "<tr>" 等于"按 < / t / r / > 四个字符中的任意一个切"，
    #    结果整篇 HTML 被切成上千个碎片，一行都拼不出来（本项目实测踩过：
    #    引脚表解析出来永远 0 个端口，而报告里明明是好的）。
    #    正确做法：整段用一个正则一次性抓取"行"这种固定结构。
    set rowre {<td class="label">([^<]+)</td>\s*<td>[^<]*</td>\s*<td>([^<]*)</td>\s*<td>([^<]*)</td>\s*<td>([^<]*)</td>}
    foreach {full p loc cons dir} [regexp -all -inline $rowre $txt] {
        incr nport
        if {$cons ne "Y"} { incr nuncon }
        puts [format "\[smoke\]   %-12s %-12s constrained=%-2s dir=%s" $p $loc $cons $dir]
    }
    puts "\[smoke\]   共 $nport 个端口，其中【未被 .cst 约束】的：$nuncon"
    if {$nport == 0} {
        puts "\[smoke\] ❌ 一个端口都没解析出来 —— 是【解析器坏了】，不是全部合规。请检查 .pin.html 格式"
        return 0
    }
    if {$nuncon > 0} {
        puts "\[smoke\] ❌ 有端口没有被 .cst 约束 —— 引脚是工具自动摆放的，构建看似成功也不能信"
        return 0
    }
    return 1
}

set PIN_OK [print_pin_table [file join $IMPL pnr "$PRJ_NAME.pin.html"]]

# ---- 6.4 结论 ----
puts "--------------------------------------------------------------"
if {$fs_ok && $PIN_OK && $syn_ok && $pnr_ok && $nerr == 0} {
    puts "\[smoke\] === PASS (stage=S$STAGE) ==="
} else {
    puts "\[smoke\] === FAIL (stage=S$STAGE) syn_ok=$syn_ok pnr_ok=$pnr_ok fs_ok=$fs_ok pin_ok=$PIN_OK rpt_errors=$nerr ==="
}

run close
puts "\[smoke\] === DONE (stage=S$STAGE) ==="
