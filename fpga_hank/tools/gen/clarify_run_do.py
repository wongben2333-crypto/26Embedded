# -*- coding: utf-8 -*-
"""clarify_run_do.py —— 说清 sim 目录下各 .do 的分工，并修一处幽灵引用

★ 背景（有人（liaison）报"run.do 里 add wave 计数 = 0，用它永远出不了波形"）：
  实测后确认这【不是缺陷，是分工】：
    · sim/run.do        —— 「跑全部 testbench + 打印 PASS/FAIL 摘要」的检查脚本
                           （**故意不加 add wave**：批量跑 4 个 tb，波形没有意义）
    · sim/wave_*.do     —— 「打开即完美」的波形视图脚本，各有 2~4 个 add wave
    · sim/make_wlf.do   —— 生成 .wlf 数据集（选择性 log，注释里写明了为什么不用 log -r /*）
  问题只在于 run.do 的头部【没有把这个分工说清楚】，容易被误认为"它应该出波形"。
  另外它引用了一个**不存在**的脚本 tools/verify/run_sim.ps1（幽灵引用）。
"""
from __future__ import annotations

import io
import os
import sys

sys.stdout.reconfigure(encoding='utf-8')

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
P = os.path.join(ROOT, 'sim', 'run.do')

c = io.open(P, encoding='utf-8').read()

# ---------- 1) 头部加分工说明，并去掉幽灵引用 ----------
old = """#  用法（在 fpga_hank 目录下，二选一）：
#     & "F:\\Modelsim_10.7\\win64\\vsim.exe" -c -do sim\\run.do
#     powershell -NoProfile -ExecutionPolicy Bypass -File tools\\verify\\run_sim.ps1
#
#  只想跑单个 testbench：
#     $env:SIM_TOP="tb_spectrum"; & "F:\\Modelsim_10.7\\win64\\vsim.exe" -c -do sim\\run.do"""

new = """#  用法（在 fpga_hank 目录下）：
#     & "F:\\Modelsim_10.7\\win64\\vsim.exe" -c -do sim\\run.do
#
#  只想跑单个 testbench：
#     $env:SIM_TOP="tb_spectrum"; & "F:\\Modelsim_10.7\\win64\\vsim.exe" -c -do sim\\run.do
#
#  ===========================================================================
#  ★ 本目录下几个 .do 的【分工】—— 不要指望用错脚本能得到想要的东西：
#
#    sim/run.do          「跑全部 testbench + 打印 PASS/FAIL 摘要」的检查脚本。
#                        **故意不加 add wave** —— 一次跑 4 个 tb，批量波形没有意义。
#                        想要波形图请用下面这些。
#    sim/wave_*.do       「打开即完美」的波形视图脚本（信号已分组、进制已选对、
#                        时间轴已缩放、游标已摆好）。用法：
#                            vsim -view sim\\wlf\\<数据集>.wlf -do sim\\wave_<名字>.do
#    sim/make_wlf.do     生成 .wlf 数据集。注意它用的是**选择性 log**
#                        （只记图上要看的信号）—— 因为 adsr 仿真里 clk 要翻转
#                        3500 万次，log 全部信号会让 .wlf 变成几百 MB。
#
#  （本段是 2026-10-03 补的：此前 run.do 头部没写这个分工，且引用了一个
#    实际不存在的脚本 tools/verify/run_sim.ps1，容易让人误判"脚本坏了"。）
#  ==========================================================================="""

if old in c:
    c = c.replace(old, new, 1)
    print('OK run.do 头部已加分工说明、去掉幽灵引用')
else:
    # 退一步：只替换幽灵引用那行
    old2 = "#     powershell -NoProfile -ExecutionPolicy Bypass -File tools\\verify\\run_sim.ps1\n"
    if old2 in c:
        c = c.replace(old2, "#     （原此处引用 tools\\verify\\run_sim.ps1，该文件实际不存在，已删）\n", 1)
        print('OK 已删除幽灵引用（头部结构与预期不同，仅做最小修正）')
    else:
        print('!! 锚点未匹配，实际头部：')
        print('\n'.join(c.split('\n')[:14]))

io.open(P, 'w', encoding='utf-8', newline='\n').write(c)
