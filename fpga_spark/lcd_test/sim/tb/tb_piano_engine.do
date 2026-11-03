# =============================================================================
#  sim/tb/tb_piano_engine.do —— 钢琴引擎单模块仿真（ModelSim，纯 RTL）
#
#  用法（任意工作目录；脚本自己定位工程根）：
#      $env:PATH="F:\Modelsim_10.7\win64;"+$env:PATH
#      $env:MGLS_LICENSE_FILE='F:\Modelsim_10.7\LICENSE.TXT'
#      vsim -c -do "sim\tb\tb_piano_engine.do"        # 在 fpga_hank 目录下
#
#  ★ 三个刻意的设计：
#    1) 用 [file dirname [info script]] 定位工程根 —— gw_sh/vsim 都不会自动切目录，
#       靠 pwd 会在别的目录下失败（本项目在 Gowin tcl 上踩过同一个坑）。
#    2) 编译库与输出目录都放在系统临时目录（$TEMP/piano_sim）：
#       不碰工程根的 work/（Lead 全工程仿真共用），也不让 out/ 里混进我的文件。
#       tb 只写相对路径 out/piano_*.txt，所以必须 cd 到那里再 vsim。
#    3) 只编译 3 个文件（piano_rom.v / piano_engine.v / tb_piano_engine.v），
#       ⛔ 不跑 gw_sh、不碰顶层 top.v。
# =============================================================================

# ★ 工程根定位：优先用当前目录（与工程既有 sim/run.do 的约定一致），
#   若当前目录不对再从脚本自身路径推断。
#   ⚠️ 不要只信 [info script]：`vsim -do "xxx.do"` 时它可能指向 ModelSim 的
#      pref.tcl 而不是我们的脚本（本机实测过）。
set ROOT [pwd]
if {![file exists [file join $ROOT rtl synth piano_rom.v]]} {
    set s [file normalize [info script]]
    set ROOT [file normalize [file join [file dirname $s] .. ..]]
}
if {![file exists [file join $ROOT rtl synth piano_rom.v]]} {
    puts "\[piano\] 找不到工程根（当前目录 $ROOT）。请在 fpga_hank 目录下运行本脚本。"
    quit -f
}
puts "\[piano\] root   = $ROOT"

if {[info exists ::env(TEMP)]} {
    set TMP [file join $::env(TEMP) piano_sim]
} else {
    set TMP [file join $ROOT _piano_sim]
}
file delete -force $TMP
file mkdir [file join $TMP out]
cd $TMP
file mkdir out
puts "\[piano\] workdir = $TMP"

vlib work
vmap work work

set SRC [list \
    "$ROOT/rtl/synth/piano_rom.v" \
    "$ROOT/rtl/synth/piano_engine.v" \
    "$ROOT/sim/tb/tb_piano_engine.v" ]

foreach f $SRC {
    puts "\[piano\] vlog $f"
    # ★ 路径含空格（"FPGA competition"）⇒ 必须 [list $f] 引起来
    if {[catch {eval vlog -sv -work work [list $f]} msg]} {
        puts "\[piano\] COMPILE-FAIL: $f"
        puts $msg
        quit -f
    }
}

puts "\[piano\] ================ vsim tb_piano_engine ================"
vsim -c -work work tb_piano_engine
run -all
puts "\[piano\] 产物目录：$TMP/out"
quit -f
