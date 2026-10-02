# =============================================================================
#  sim/make_wlf.do —— 为一个 testbench 生成 .wlf 数据集（用户截屏用）
#
#  为什么需要：用户的最终分工是「我们给一条命令 → 他用 Win+Shift+S 截屏」。
#  ModelSim 的 `-view <file>.wlf` 可以**不重新仿真**直接打开数据集 ⇒ 用户端秒开。
#
#  用法（在 fpga_hank 目录下，一次一个 tb）：
#      $env:SIM_TOP="tb_wave_pt8211"; & "F:\Modelsim_10.7\win64\vsim.exe" -c -do sim\make_wlf.do
#  批量：tools\gowin 无关；用 _smoke-test\make_all_wlf.ps1
#
#  ⚠️ 不要在同一个脚本里循环跑多个 tb：`quit -sim` 在 `-c -do` 上下文里会把
#     整个 vsim 会话结束掉，于是只有第一个 tb 出了 .wlf（本项目实测踩过）。
#
#  ★ `-voptargs=+acc` 必须加：否则 vopt 把内部信号优化掉，用户 add wave 会报 not found。
#  ★ `-wlf` 只指定文件名，**不会自动记录信号**，必须显式 `log`。
#    正好让我们能挑信号：clk 在 351 ms 的 adsr 仿真里要翻转 3500 万次，
#    全记下来 .wlf 会是几百 MB；只记图上要看的就小得多。
# =============================================================================

set MS_HOME F:/Modelsim_10.7
if {[file exists $MS_HOME/modelsim.ini]} { catch {set ::env(MODELSIM) $MS_HOME/modelsim.ini} }
catch {vmap GW5AT $MS_HOME/GW5AT}

set ROOT   [pwd]
set WLFDIR [file join $ROOT sim wlf]
file mkdir $WLFDIR

set TB tb_wave_pt8211
if {[info exists ::env(SIM_TOP)]} { set TB $::env(SIM_TOP) }

if {[file exists work]} { file delete -force work }
vlib work
vmap work work

set SRC {
    rtl/synth/wave_rom.v
    rtl/synth/adsr.v
    rtl/synth/bench_gate.v
    rtl/synth/tone_bank.v
    rtl/audio/pt8211_tx.v
    rtl/smoke/smoke_top.v
    sim/tb/tb_wave.v
}
foreach rel $SRC {
    set f [file join $ROOT $rel]
    if {[catch {eval vlog -sv -work work [list $f]} msg]} {
        puts "\[wlf\] COMPILE-FAIL $rel"; puts $msg; quit -f
    }
}

# 每个 tb 只记"图上看得到的那几根"；clk 只在确实要看时钟沿的图里记
proc log_list {tb} {
    switch -- $tb {
        tb_wave_pt8211   { return {clk reset sl sr bck ws din sample_tick} }
        tb_wave_adsr     { return {rst_n gate level dut/en_div_cnt dut/en_phase} }
        tb_wave_tonebank { return {rst_n sample_tick gate32 env_voice mix16 env_level32 \
                                   u_bank/addr_mux u_bank/samp_cnt u_bank/sum} }
        tb_wave_chain    { return {key key2 dut/key_raw dut/key_db dut/DBG_GATE dut/DBG_AUDIO \
                                   dut/g_mono/env_level dut/g_mono/ph_acc dut/g_mono/mono_gate} }
        tb_wave_bounce   { return {key dut/key_raw dut/key_db dut/press_cnt led} }
        default          { return {} }
    }
}

set wlf [file join $WLFDIR "$TB.wlf"]
file delete -force $wlf
puts "\[wlf\] ==================== $TB ===================="
if {[catch {vsim -c -voptargs=+acc -wlf $wlf work.$TB} msg]} {
    puts "\[wlf\] LOAD-FAIL($TB): $msg"; quit -f
}
set n 0
foreach sig [log_list $TB] {
    if {[catch {log "/$TB/$sig"} msg]} {
        puts "\[wlf\]   log 失败 /$TB/$sig : $msg"
    } else {
        incr n
    }
}
puts "\[wlf\]   已记录 $n 个信号"
run -all
if {[file exists $wlf]} {
    puts "\[wlf\]   -> [file tail $wlf]  ([file size $wlf] bytes)"
} else {
    puts "\[wlf\]   !! 没有生成 $wlf"
}
quit -f
