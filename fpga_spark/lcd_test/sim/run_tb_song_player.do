# =============================================================================
#  sim/run_tb_song_player.do —— song_player（演示模式播放器）单模块验证脚本
#
#  用法 A（推荐，在 fpga_hank 目录下）：
#      $env:PATH="F:\Modelsim_10.7\win64;"+$env:PATH
#      $env:MGLS_LICENSE_FILE='F:\Modelsim_10.7\LICENSE.TXT'
#      vsim -c -do sim\run_tb_song_player.do
#
#  用法 B（不想让 ModelSim 往仓库目录写 transcript/work 时）：
#      $env:SONG_TB_ROOT = (Resolve-Path fpga_hank).Path
#      cd $env:TEMP ; vsim -c -do <abs>\fpga_hank\sim\run_tb_song_player.do
#
#  ===========================================================================
#  ★ 为什么单独一个 .do、单独一个库目录
#  ===========================================================================
#  1. `sim/run.do` 是"跑全部 testbench"的总脚本，它**故意先 `file delete -force work`**
#     做全量重编译。本脚本只跑 song_player 一个 DUT，**绝不该去动 sim/work** ——
#     ModelSim 是【单席位许可证】，队友可能正在用同一个 work 库跑别的 tb，
#     删库会让对方直接失败。所以本脚本把库建到系统临时目录。
#  2. 本脚本只编译三个文件（song_rom.v / song_player.v / tb_song_player.v），
#     不碰顶层 top.v，也不跑 gw_sh（那会和 Lead 的整机构建抢资源）。
#  3. ⚠️ ModelSim 单席位：同时只允许一个 vsim。跑之前先确认没有别的 vsim 在跑。
# =============================================================================

set MS_HOME F:/Modelsim_10.7
if {[file exists $MS_HOME/modelsim.ini]} {
    catch {set ::env(MODELSIM) $MS_HOME/modelsim.ini}
}

# 工程根：优先用环境变量 SONG_TB_ROOT（用法 B），否则用当前工作目录（用法 A）
if {[info exists ::env(SONG_TB_ROOT)]} {
    set ROOT $::env(SONG_TB_ROOT)
} else {
    set ROOT [pwd]
}
if {![file exists "$ROOT/rtl/synth/song_player.v"]} {
    puts "\[song-tb\] ERROR: 在 $ROOT 下找不到 rtl/synth/song_player.v"
    puts "\[song-tb\]        请设 SONG_TB_ROOT 或在 fpga_hank 目录下运行"
    quit -f
}

# 库目录放系统临时目录：不污染仓库，也不和别人的 sim/work 抢
if {[info exists ::env(TEMP)]} {
    set WORK [file join $::env(TEMP) song_tb_work]
} else {
    set WORK [file join $ROOT sim work_song_player]
}
puts "\[song-tb\] root = $ROOT"
puts "\[song-tb\] work = $WORK"

if {[file exists $WORK]} { file delete -force $WORK }
vlib $WORK
vmap work $WORK

# 编译：被例化的模块在前
set srcs [list \
    "$ROOT/rtl/synth/song_rom.v" \
    "$ROOT/rtl/synth/song_player.v" \
    "$ROOT/sim/tb/tb_song_player.v" ]

set nerr 0
foreach f $srcs {
    puts "\[song-tb\] vlog $f"
    # ★ 路径含空格（"FPGA competition"），必须用 [list $f] 引用
    if {[catch {eval vlog -sv -work work [list $f]} msg]} {
        puts "\[song-tb\] COMPILE-FAIL: $f"
        puts $msg
        incr nerr
    }
}
if {$nerr > 0} {
    puts "\[song-tb\] ========== 编译失败 $nerr 个文件，终止 =========="
    quit -f
}

puts "\[song-tb\] ==================== tb_song_player ===================="
vsim -c -work work tb_song_player
catch {run -all}
# testbench 用 $stop 收尾（不是 $finish）：$stop 把控制权还给脚本，
# 这样本脚本还能打印一句"跑完了"，然后干净退出。
puts "\[song-tb\] ==================== run done ===================="
quit -f
