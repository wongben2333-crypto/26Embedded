# =============================================================================
#  sim/wave.do —— 【GUI 出波形】入口（_research/fpga-tools/GUI-SIM-GUIDE.md 里
#                 写的那个文件名，之前并不存在，本文件把它补上）
#
#  用法（在 fpga_hank 目录下）：
#     & "F:\Modelsim_10.7\win64\vsim.exe" -gui -do sim\wave.do
#     # 只跑某一个：$env:SIM_TOP="tb_wave_pt8211"  再执行上面那条
#
#  可选顶层：tb_wave_pt8211 / tb_wave_adsr / tb_wave_tonebank / tb_wave_chain
#            不设 SIM_TOP 时默认 tb_wave_chain（交互链路那张图）
#
#  ★ 本文件只是 sim/run_wave.do 的入口壳子 —— 真正的编译/摆波形/run 都在那边，
#    避免同一个逻辑维护两份（两份必然会漂移）。
#  ★ 之所以不从 sim/run.do 走：run.do 是"跑全部 tb + 打印 PASS 统计"，
#    它全文没有 add wave，所以**跑完没有波形**；而且它一旦遇到别人写在
#    sim/tb/ 里的编译错误就会整体退出。run_wave.do 只编译波形图用到的
#    7 个文件，不受影响。
# =============================================================================

set HERE [file dirname [info script]]
puts "\[wave\] wave.do -> source [file join $HERE run_wave.do]"
source [file join $HERE run_wave.do]
