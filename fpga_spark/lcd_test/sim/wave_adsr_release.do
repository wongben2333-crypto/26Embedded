# =============================================================================
#  sim/wave_adsr_release.do —— 图②b ADSR 释放段（单独一张：慢慢落下去）
#
#  用户用法（fpga_hank 目录下）：
#    & "F:\Modelsim_10.7\win64\vsim.exe" -view "sim\wlf\tb_wave_adsr.wlf" -do "sim\wave_adsr_release.do"
#
#  ★ 打开后应当看到：gate 拉高后 env_level 不是垂直上升而是斜坡；
#    中间一段平的就是 sustain；gate 拉低后又是一个长斜坡落回 0。
#  ★ 数值（EN_DIV=64, ATK_SH=13, DEC/REL_SH=16, clk=50 MHz）：
#      起音 = (65536 >> (16-13)) 步 × 64 拍 ÷ 50 MHz = 10.49 ms
#      衰减 = 16384 步 × 64 拍 ÷ 50 MHz = 20.97 ms
#      释放 = 49152 步 × 64 拍 ÷ 50 MHz = 62.91 ms
# =============================================================================

set TB tb_wave_adsr
set WLF [file join [pwd] sim wlf "$TB.wlf"]
if {[llength [dataset list]] == 0} {
    if {[file exists $WLF]} { vsim -view $WLF } else {
        puts "\[wave\] 缺少 $WLF —— 请先在 fpga_hank 下运行 sim\\make_wlf.do"; return
    }
}


# 窗口大小给成适合截屏的尺寸（用户是直接 Win+Shift+S 截屏，太宽会截不清）
catch {wm geometry . 1600x900}
proc wg {title radix sigs {extra {}}} {
    catch {add wave -divider $title}
    if {[catch {eval add wave -radix $radix $extra $sigs} msg]} {
        catch {eval add wave -radix $radix $sigs} msg2
    }
}

wg "Stimulus" binary   [list /$TB/rst_n /$TB/gate]
wg "Control"  hex      [list /$TB/dut/en_div_cnt /$TB/dut/en_phase]
wg "Data"     unsigned [list /$TB/level] {-format analog-interpolated -min 0 -max 65536 -height 220}

catch {configure wave -namecolwidth 190 -valuecolwidth 110 -timelineunits ms}
# 0~290 ms：三段都看得见（起音斜坡 ~10.5 ms、保持平台、释放斜坡 ~62.9 ms）
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

# ③ 目标范围：释放段：62.91 ms 斜坡
ztry "zoom range 195ms 275ms"  {wave zoom range 195ms 275ms}
ztry "restore zoom"          {WaveRestoreZoom {195 ms} {275 ms}}
after 500

# ④ 打印当前范围，让 transcript 自证（不靠肉眼看图）
if {[catch {set _r [wave zoom range]} _m]} {
    puts "\[zoom\] 查询当前范围失败: $_m"
} else {
    puts "\[zoom\] 当前时间范围 = $_r   （目标：195ms 275ms）"
}

catch {add wave -group "Data" -radix unsigned -height 200 /$TB/level}

puts "\[wave\] ===== 图②b adsr 释放段 已就绪 ====="
puts "\[wave\] 看：gate 已经拉低，env_level 从 49152 一路缓降到 0"
puts "\[wave\]     这段斜坡的持续时间就是 release 时间常数"
puts "\[wave\]     62.91 ms 不是垂直落下 —— 说明释放是按斜率走的"
puts "\[wave\] 数值：起音 10.49 ms / 衰减 20.97 ms / 释放 62.91 ms"
puts "\[wave\] 若想看清起音段，把时间轴放大到 0~15 ms 即可（工具栏 Zoom）"
puts "\[wave\] 现在可以 Win+Shift+S 截图"



# ---- 游标：用官方语法 wave cursor add -time <t> -name <n> -------------------
# （不用 WaveRestoreCursors —— 那是旧式/别名，官方命令参考里 wave 命令族是
#   `wave cursor add|configure|delete|see|active`。见 liaison/MODELSIM-GUIDE.md）
ztry "cursor 200ms" {wave cursor add -time 200ms -name "gate拉低(释放开始)"}
ztry "cursor 262.91ms" {wave cursor add -time 262.91ms -name "释放归零"}
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
