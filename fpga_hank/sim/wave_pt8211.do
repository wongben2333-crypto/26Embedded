# =============================================================================
#  sim/wave_pt8211.do —— 图① PT8211 I2S 位序与声道边界
#
#  用户用法（一条命令，fpga_hank 目录下）：
#    & "F:\Modelsim_10.7\win64\vsim.exe" -view "sim\wlf\tb_wave_pt8211.wlf" -do "sim\wave_pt8211.do"
#
#  也可直接： & "...\vsim.exe" -do "sim\wave_pt8211.do"     （本文件会自己开数据集）
#
#  ★ 打开后应当看到：BCK / WS / DIN 三根线，已放大到【一个左声道半帧】，
#    WS 高 = 左声道、低 = 右声道；DIN 在 BCK 上升沿前稳定。
#  ★ 数值：BCK 周期 = 320.0 ns（BCK_DIV=1，fs = 97656.25 Hz）
# =============================================================================

set TB tb_wave_pt8211
set WLF [file join [pwd] sim wlf "$TB.wlf"]
if {[llength [dataset list]] == 0} {
    if {[file exists $WLF]} { vsim -view $WLF } else {
        puts "\[wave\] 缺少 $WLF —— 请先在 fpga_hank 下运行 sim\\make_wlf.do"; return
    }
}

# 分组加信号；-group 不被支持时自动回退成不加分组（保证窗口里一定有信号）

# 窗口大小给成适合截屏的尺寸（用户是直接 Win+Shift+S 截屏，太宽会截不清）
catch {wm geometry . 1600x900}
proc wg {title radix sigs} {
    catch {add wave -divider $title}
    catch {eval add wave -radix $radix $sigs} msg
}

wg "Clock & Reset" binary   [list /$TB/clk /$TB/reset]
wg "Stimulus"      hex      [list /$TB/sl /$TB/sr]
wg "Output"        binary   [list /$TB/bck /$TB/ws /$TB/din /$TB/sample_tick]

catch {configure wave -namecolwidth 190 -valuecolwidth 90 -timelineunits ns}
# 放大到 11.20~16.50 us = WS 变高后的一个完整左声道半帧（16 个 BCK 周期 = b15..b0）
# ★ 分组默认是【收起】的（窗口里只显示一行组名，看不到波形）。
#   必须显式展开，否则用户打开就是一片空的（本项目实测踩过）。
# ---- 缩放（★ 必须"会说话"：裸 catch 会把失败吞掉，我们就只能靠猜）---------
# 之前写成 `catch {WaveRestoreZoom ...}` 三条全静默 ⇒ 缩放到底有没有生效无从得知，
# 结果交出去的图时间轴停在【全范围】，起音斜坡被压成近乎垂直（本项目实测踩过）。
proc ztry {desc script} {
    if {[catch {uplevel 1 $script} msg]} {
        puts "\[zoom\] $desc -> FAIL: $msg"
    } else {
        puts "\[zoom\] $desc -> ok"
    }
}

# ① 先跑一次 zoom full，确认"缩放这条命令通路"本身可用
ztry "zoom full" {wave zoom full}

# ② 延迟到 GUI 真正就绪后再缩放（-view 模式下 .do 可能早于窗口 ready）
after 2000

# ③ 目标范围：一个左声道半帧（16 个 BCK 周期）
ztry "zoom range 11.20us 16.50us"  {wave zoom range 11.20us 16.50us}
ztry "restore zoom"          {WaveRestoreZoom {11.20 us} {16.50 us}}
after 500

# ④ 打印当前范围，让 transcript 自证（不靠肉眼看图）
if {[catch {set _r [wave zoom range]} _m]} {
    puts "\[zoom\] 查询当前范围失败: $_m"
} else {
    puts "\[zoom\] 当前时间范围 = $_r   （目标：11.20us 16.50us）"
}


puts "\[wave\] ===== 图① pt8211 已就绪 ====="
puts "\[wave\] 看：WS 高=左声道(16bit) / 低=右声道(16bit)；DIN 在 BCK 上升沿采样"
puts "\[wave\] 数值：BCK 周期 = 320.0 ns；十六进制样本 sl=0xAAAA sr=0x5555"
puts "\[wave\] 建议放大到一个 BCK 周期（320 ns）逐位读 b15..b0，可用工具栏 Zoom In"
puts "\[wave\] 现在可以 Win+Shift+S 截图"



# ---- 游标：用官方语法 wave cursor add -time <t> -name <n> -------------------
# （不用 WaveRestoreCursors —— 那是旧式/别名，官方命令参考里 wave 命令族是
#   `wave cursor add|configure|delete|see|active`。见 liaison/MODELSIM-GUIDE.md）
ztry "cursor 11.36us" {wave cursor add -time 11.36us -name "WS高后第1个BCK上升沿"}
ztry "cursor 11.68us" {wave cursor add -time 11.68us -name "再下一个沿(间隔=320ns)"}
ztry "wave refresh" {wave refresh}

# 游标读回：自证 —— 不是"我说放了游标"，而是把工具里的实际值打印出来
set _ncur 0
foreach _ci {1 2 3} {
    if {[catch {set _cv [wave cursor configure $_ci]} _ce]} {
        if {$_ncur > 0} { puts "\[cursor\] cursor$_ci 读回失败: $_ce" }
    } else {
        incr _ncur
        puts "\[cursor\] cursor$_ci = $_cv"
    }
}
puts "\[cursor\] 可用游标数 = $_ncur"

# ---- 最终再打印一次时间范围：放【末尾】才不会被 Transcript 滚动遮住 ----
# 之前把查询放在缩放之后、但后面还有一串 [wave] 输出，于是查询结果被顶出可视区，
# 看截图的人根本看不到缩放到底有没有生效（本项目实测踩过）。
after 300
if {[catch {set _r2 [wave zoom range]} _m2]} {
    puts "\[zoom\] 最终范围查询失败: $_m2"
} else {
    puts "\[zoom\] 最终时间范围 = $_r2"
}
