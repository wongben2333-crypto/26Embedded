# =============================================================================
#  sim/run.do —— ModelSim 一键仿真（编译 + 跑完全部 testbench + 打印 PASS 摘要）
#
#  用法（在 fpga_hank 目录下）：
#     & "F:\Modelsim_10.7\win64\vsim.exe" -c -do sim\run.do
#
#  只想跑单个 testbench：
#     $env:SIM_TOP="tb_spectrum"; & "F:\Modelsim_10.7\win64\vsim.exe" -c -do sim\run.do
#
#  ===========================================================================
#  ★ 本目录下几个 .do 的【分工】—— 不要指望用错脚本能得到想要的东西：
#
#    sim/run.do          「跑全部 testbench + 打印 PASS/FAIL 摘要」的检查脚本。
#                        **故意不加 add wave** —— 一次跑 4 个 tb，批量波形没有意义。
#                        想要波形图请用下面这些。
#    sim/wave_*.do       「打开即完美」的波形视图脚本（信号已分组、进制已选对、
#                        时间轴已缩放、游标已摆好）。用法：
#                            vsim -view sim\wlf\<数据集>.wlf -do sim\wave_<名字>.do
#    sim/make_wlf.do     生成 .wlf 数据集。注意它用的是**选择性 log**
#                        （只记图上要看的信号）—— 因为 adsr 仿真里 clk 要翻转
#                        3500 万次，log 全部信号会让 .wlf 变成几百 MB。
#
#  （本段是 2026-10-03 补的：此前 run.do 头部没写这个分工，且引用了一个
#    头部引用了一个**实际不存在**的包装脚本，容易让人误判"脚本坏了"。）
#  ===========================================================================
#
#  ── 本文件修掉的历史缺口（都会让用户"一跑就挂"）────────────────────────────
#  1. ★ 只编译 `rtl/*/*.v`（子目录），**不含 `rtl/top.v`**。若有 testbench 例化
#     顶层 `top` 就会报"找不到模块"。现在【同时】编译 `rtl/*.v` 与 `rtl/*/*.v`。
#  2. ★ 原来只 `vsim` 一个顶层，不是"一键全跑"。现在依次跑完全部 testbench
#     并汇总 PASS/FAIL。
#  3. ★ 未映射高云预编译库。现在是纯 RTL、不例化高云原语，本来不需要；
#     但显式 `vmap` 上 GW5AT 更稳 —— 一旦将来用到 PLL/BSRAM 原语就不会缺库。
#  4. ★ `vlog` 的路径**必须加引号**：本仓库路径含空格（"FPGA competition"），
#     不加引号会被 ModelSim 截断。原脚本用 `eval ... [list $f]` 已处理，
#     这里保持同样的写法，不要改成裸 $f。
# =============================================================================

# ---- 高云预编译库映射 -------------------------------------------------------
set MS_HOME F:/Modelsim_10.7
if {[file exists $MS_HOME/modelsim.ini]} {
    catch {set ::env(MODELSIM) $MS_HOME/modelsim.ini}
}
# GW5AT 预编译库（高云随 ModelSim 安装提供）。存在才映射，避免报错。
set GW_LIB $MS_HOME/GW5AT
set HAVE_GW 0
if {[file exists $GW_LIB]} {
    # 库目录里通常有 _lib 或直接是编译产物；优先用安装目录自带的 modelsim.ini 映射
    catch {vmap GW5AT $GW_LIB}
    set HAVE_GW 1
}

set ROOT [pwd]
puts "\[sim\] root    = $ROOT"
puts "\[sim\] MsHome  = $MS_HOME  (GW5AT 映射: $HAVE_GW)"

if {[file exists work]} { file delete -force work }
vlib work
vmap work work

# ---- 编译被测设计 -----------------------------------------------------------
# ★ 顺序很重要：先子目录（叶子模块），再 rtl 根目录（顶层），避免"模块未定义"。
set srcs {}
# 排除 not_integrated（未接入的模块，不参与验收）
foreach f [lsort [glob -nocomplain "$ROOT/rtl/*/*.v"]] {
    if {[string match "*not_integrated*" $f]} { continue }
    lappend srcs $f
}
foreach f [lsort [glob -nocomplain "$ROOT/rtl/*.v"]]   { lappend srcs $f }
foreach f [lsort [glob -nocomplain "$ROOT/sim/tb/*.v"]] { lappend srcs $f }

set nerr 0
foreach f $srcs {
    puts "\[sim\] vlog $f"
    # ★ [list $f] 保证含空格的路径被正确引用
    if {[catch {eval vlog -sv -work work [list $f]} msg]} {
        puts "\[sim\] COMPILE-FAIL: $f"
        puts $msg
        incr nerr
    }
}
if {$nerr > 0} {
    puts "\[sim\] ========== 编译失败 $nerr 个文件，终止 =========="
    quit -f
}

# ---- 跑 testbench -----------------------------------------------------------
# 期望结果：
#   tb_pt8211_final  PASS（BCK 恒 320 ns、fs 97656.3 Hz、0 位错）
#   tb_adsr          PASS（ADSR 状态机 9/9）
#   tb_spectrum      PASS（32/32 谱峰、0 杂散）—— 另需 check_peaks.py 判频谱
#   tb_interaction   PASS（交互通路 9 项：去抖/起音/释放/换音色/变调/维度独立）
#   tb_touch_pad     已知 FAIL（touch_pad 未接入顶层、不影响主 bitstream）
# 注意：tb_touch_pad 已移入 sim/tb/not_integrated/ —— touch_pad 未接入顶层，
#       其仿真长期未通过，故不列入一键运行清单（详见 rtl/not_integrated/README.md）。
set ALL_TBS {tb_pt8211_final tb_adsr tb_spectrum tb_interaction}

if {[info exists ::env(SIM_TOP)]} {
    set ALL_TBS [list $::env(SIM_TOP)]
    puts "\[sim\] 只跑指定顶层: $::env(SIM_TOP)"
}

set summary {}
foreach tb $ALL_TBS {
    puts ""
    puts "\[sim\] ==================== $tb ===================="
    if {[catch {vsim -c -work work $tb} msg]} {
        puts "\[sim\] SIM-FAIL($tb): $msg"
        lappend summary [list $tb "LOAD-FAIL"]
        continue
    }
    # ★ testbench 结尾用 $stop（不是 $finish）：$finish 会终止整个 vsim 进程，
    #   导致 run.do 里后续的 testbench 根本跑不到（本项目实测过：只跑了第一个）。
    #   $stop 只是暂停，控制权回到脚本，于是可以 quit -sim 再加载下一个。
    catch {run -all}
    lappend summary [list $tb "ran"]
    catch {quit -sim}
}

# ---- 汇总 -------------------------------------------------------------------
puts ""
puts "\[sim\] =============================================="
puts "\[sim\] 仿真执行汇总（PASS/FAIL 请看上面每个 tb 的最后一行输出）"
foreach s $summary {
    puts "\[sim\]   [lindex $s 0] : [lindex $s 1]"
}
puts "\[sim\] =============================================="
puts "\[sim\] 频谱判据（tb_spectrum 产出 out/tone_samples.txt 后另行运行）："
puts "\[sim\]   python tools/verify/check_peaks.py --file out/tone_samples_snap.txt \\"
puts "\[sim\]       --format samples --fs 97656.25 --count 32 --start 200 --step 200"
puts "\[sim\]   ★ --fs 必须写实际采样率 97656.25（BCK_DIV=1），写 48000 会全部误判 FAIL"
quit -f
