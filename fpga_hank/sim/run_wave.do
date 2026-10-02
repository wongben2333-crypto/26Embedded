# =============================================================================
#  sim/run_wave.do —— 出「能看的波形」的仿真脚本（波形图专用）
#
#  与 sim/run.do 的区别（为什么另起一个文件）：
#    · run.do 是"一键跑全部 testbench + 打印 PASS 摘要"，它**不含任何 add wave**
#      ⇒ 跑完只有文字，没有波形。
#    · 本文件专门干两件事：**add wave 把关心的信号按 5 个组摆出来** + run 完停在窗口里。
#    · 只编译【波形用得到的那 7 个源文件】+ tb_wave.v，不 glob 整个 sim/tb/
#      ⇒ 别人写在 sim/tb/ 里的坏文件不会连累这里。
#
#  用法（在 fpga_hank 目录下）：
#    & "F:\Modelsim_10.7\win64\vsim.exe" -gui -do sim\run_wave.do
#    $env:SIM_TOP="tb_wave_pt8211"; & "F:\Modelsim_10.7\win64\vsim.exe" -gui -do sim\run_wave.do
#    $env:SIM_TOP="tb_wave_pt8211"; & "F:\Modelsim_10.7\win64\vsim.exe" -c   -do sim\run_wave.do
#
#  可用 SIM_TOP：tb_wave_pt8211 / tb_wave_adsr / tb_wave_tonebank
#                tb_wave_chain  / tb_wave_bounce     （默认 tb_wave_chain）
#
#  ★ 信号按 5 个组摆放（社区通行命名，见 liaison/WAVEFORM-PRESENTATION-SPEC.md §3①）：
#      Clock & Reset / Stimulus / Control / Data / Output
#  ★ 进制按 §3④：时钟使能=二进制；计数/状态=十六进制或无符号十进制；
#     有符号样本（mix16 / level 之外的波形值）=有符号十进制 —— 否则负半周看不懂。
#  ★ 路径含空格（"FPGA competition"）⇒ vlog 参数必须用 [list ...] 包住。
#  ★ add wave 在 -c 模式下没有窗口，所以用 w{} 过程把整段 catch 起来：
#     有窗口就摆波形，没窗口也不报错。
# =============================================================================

set MS_HOME F:/Modelsim_10.7
if {[file exists $MS_HOME/modelsim.ini]} {
    catch {set ::env(MODELSIM) $MS_HOME/modelsim.ini}
}
catch {vmap GW5AT $MS_HOME/GW5AT}

set ROOT [pwd]
puts "\[wave\] root = $ROOT"

set TB tb_wave_chain
if {[info exists ::env(SIM_TOP)]} { set TB $::env(SIM_TOP) }
puts "\[wave\] SIM_TOP = $TB"

if {[file exists work]} { file delete -force work }
vlib work
vmap work work

# ---- 只编译波形图用得到的源文件（显式清单，不 glob）-------------------------
set SRC {
    rtl/synth/wave_rom.v
    rtl/synth/adsr.v
    rtl/synth/bench_gate.v
    rtl/synth/tone_bank.v
    rtl/audio/pt8211_tx.v
    rtl/smoke/smoke_top.v
    sim/tb/tb_wave.v
}
set nerr 0
foreach rel $SRC {
    set f [file join $ROOT $rel]
    if {![file exists $f]} { puts "\[wave\] 缺少 $f"; incr nerr; continue }
    puts "\[wave\] vlog $rel"
    if {[catch {eval vlog -sv -work work [list $f]} msg]} {
        puts "\[wave\] COMPILE-FAIL $rel"
        puts $msg
        incr nerr
    }
}
if {$nerr > 0} {
    puts "\[wave\] ===== 有 $nerr 个源文件编译失败，终止 ====="
    quit -f
}

# ---- 加载顶层 ----------------------------------------------------------------
if {[catch {vsim -work work $TB} msg]} {
    puts "\[wave\] LOAD-FAIL($TB): $msg"
    quit -f
}

# ---- 摆波形（-c 模式没有窗口，catch 掉）-------------------------------------
proc w {args} { catch {eval add wave $args} }

if {$TB eq "tb_wave_pt8211"} {
    w -group "Clock & Reset" -radix binary   /tb_wave_pt8211/clk /tb_wave_pt8211/reset
    w -group "Stimulus"      -radix hex      /tb_wave_pt8211/sl /tb_wave_pt8211/sr
    w -group "Output"        -radix binary   /tb_wave_pt8211/bck
    w -group "Output"        -radix binary   /tb_wave_pt8211/ws
    w -group "Output"        -radix binary   /tb_wave_pt8211/din
    w -group "Output"        -radix binary   /tb_wave_pt8211/sample_tick
    catch {WaveRestoreZoom {10.4 us} {14.0 us}}
} elseif {$TB eq "tb_wave_adsr"} {
    w -group "Clock & Reset" -radix binary   /tb_wave_adsr/clk /tb_wave_adsr/rst_n
    w -group "Stimulus"      -radix binary   /tb_wave_adsr/gate
    w -group "Control"       -radix hex      /tb_wave_adsr/dut/en_div_cnt
    w -group "Control"       -radix hex      /tb_wave_adsr/dut/en_phase
    w -group "Data"          -radix unsigned -height 200 /tb_wave_adsr/level
    catch {WaveRestoreZoom {0 ns} {360 ms}}
} elseif {$TB eq "tb_wave_tonebank"} {
    w -group "Clock & Reset" -radix binary   /tb_wave_tonebank/clk /tb_wave_tonebank/rst_n
    w -group "Stimulus"      -radix binary   /tb_wave_tonebank/sample_tick
    w -group "Stimulus"      -radix binary   /tb_wave_tonebank/gate32
    w -group "Control"       -radix hex      /tb_wave_tonebank/env_voice
    w -group "Data"          -radix signed -height 200 /tb_wave_tonebank/mix16
    w -group "Data"          -radix unsigned -height 120 /tb_wave_tonebank/env_level32
    catch {WaveRestoreZoom {0 ns} {40 us}}
} elseif {$TB eq "tb_wave_chain"} {
    w -group "Clock & Reset" -radix binary   /tb_wave_chain/clk
    w -group "Stimulus"      -radix binary   /tb_wave_chain/key /tb_wave_chain/key2
    w -group "Control"       -radix binary   /tb_wave_chain/dut/key_raw
    w -group "Control"       -radix binary   /tb_wave_chain/dut/key_db
    w -group "Control"       -radix binary   /tb_wave_chain/dut/DBG_GATE
    w -group "Data"          -radix unsigned -height 200 /tb_wave_chain/dut/g_mono/env_level
    w -group "Data"          -radix hex      /tb_wave_chain/dut/g_mono/ph_acc
    w -group "Output"        -radix binary   /tb_wave_chain/dut/DBG_AUDIO
    w -group "Output"        -radix binary   /tb_wave_chain/HP_BCK
    w -group "Output"        -radix binary   /tb_wave_chain/HP_WS
    w -group "Output"        -radix binary   /tb_wave_chain/HP_DIN
    w -group "Output"        -radix binary   /tb_wave_chain/led
    catch {WaveRestoreZoom {14.99 ms} {26.5 ms}}
} elseif {$TB eq "tb_wave_bounce"} {
    w -group "Clock & Reset" -radix binary   /tb_wave_bounce/clk
    w -group "Stimulus"      -radix binary   /tb_wave_bounce/key
    w -group "Control"       -radix binary   /tb_wave_bounce/dut/key_raw
    w -group "Control"       -radix binary   /tb_wave_bounce/dut/key_db
    w -group "Data"          -radix unsigned /tb_wave_bounce/dut/press_cnt
    w -group "Output"        -radix binary   /tb_wave_bounce/led
    catch {WaveRestoreZoom {14.99 ms} {17.0 ms}}
} else {
    w -r /*
}

# ---- 跑完 --------------------------------------------------------------------
run -all

puts "\[wave\] ===== $TB 跑完 ====="
# ⚠️ 不要用 `wave cursor active` 之类去猜"是不是 GUI 模式"：那不是合法命令，
#    会抛错，于是 catch 判成"批处理"→ 直接 quit -f → GUI 窗口一闪就没了。
#    改成由环境变量显式控制：设了 WAVE_KEEP_OPEN 就【不退出】，留着窗口给截图/导出。
if {[info exists ::env(WAVE_KEEP_OPEN)]} {
    catch {wave zoom full}
    puts "\[wave\] GUI 模式：窗口保持打开（WAVE_KEEP_OPEN=1），现在可以截图/导出图像"
} else {
    quit -f
}
