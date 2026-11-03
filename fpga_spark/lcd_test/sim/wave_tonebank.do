# =============================================================================
#  sim/wave_tonebank.do —— 图③ tone_bank 32 路：分时查表 + 混音输出
#
#  用户用法（fpga_hank 目录下）：
#    & "F:\Modelsim_10.7\win64\vsim.exe" -view "sim\wlf\tb_wave_tonebank.wlf" -do "sim\wave_tonebank.do"
#
#  ★ 打开后应当看到：
#    · sample_tick 每 512 个 clk 一个脉冲（= 一个采样点，fs = 97656.25 Hz）
#    · addr_mux 在每个采样点内 0→31 走一遍（32 路【恰好各查表一次】）
#    · mix16 是 32 路叠加后的混音样本（有符号，负半周也看得见）
#  ★ 数值：每个采样点 = 512 clk = 10.24 µs
# =============================================================================

set TB tb_wave_tonebank
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

wg "Clock & Reset" binary   [list /$TB/rst_n]
wg "Stimulus"      binary   [list /$TB/sample_tick /$TB/gate32]
wg "Control"       hex      [list /$TB/u_bank/addr_mux /$TB/u_bank/samp_cnt /$TB/env_voice]
wg "Data"          signed   [list /$TB/mix16] {-format analog-interpolated -height 220}
wg "Data"          unsigned [list /$TB/env_level32] {-format analog-interpolated -min 0 -max 65536 -height 140}
wg "Data"          signed   [list /$TB/u_bank/sum] {-format analog-interpolated -height 140}

catch {configure wave -namecolwidth 190 -valuecolwidth 110 -timelineunits us}
# 放大到 0~120 us ≈ 11 个采样点：既能看到 addr_mux 走完 0..31（分时查表），
# 也能看到 mix16 每个采样点更新一次
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

# ③ 目标范围：约 4 个采样点（每点 10.24 us）
ztry "zoom range 0us 40us"  {wave zoom range 0us 40us}
ztry "restore zoom"          {WaveRestoreZoom {0 us} {40 us}}
after 500

# ④ 打印当前范围，让 transcript 自证（不靠肉眼看图）
if {[catch {set _r [wave zoom range]} _m]} {
    puts "\[zoom\] 查询当前范围失败: $_m"
} else {
    puts "\[zoom\] 当前时间范围 = $_r   （目标：0us 40us）"
}


puts "\[wave\] ===== 图③ tone_bank 已就绪 ====="
puts "\[wave\] 看：addr_mux 在一个采样点内 0->31 扫一遍 = 32 路【每路恰好查表一次】"
puts "\[wave\]     mix16 每 512 clk（10.24 us）更新一次 = 一个混音样本"
puts "\[wave\] 数值：fs = 97656.25 Hz；32 路 = 200/400/.../6400 Hz，间隔 200 Hz"
puts "\[wave\] 注意：时域波形看不出「几个频率」，要数 32 个谱峰请看频谱图"
puts "\[wave\] 现在可以 Win+Shift+S 截图"



# ---- 游标：用官方语法 wave cursor add -time <t> -name <n> -------------------
# （不用 WaveRestoreCursors —— 那是旧式/别名，官方命令参考里 wave 命令族是
#   `wave cursor add|configure|delete|see|active`。见 liaison/MODELSIM-GUIDE.md）
ztry "cursor 0us" {wave cursor add -time 0us -name "采样点起点"}
ztry "cursor 10.24us" {wave cursor add -time 10.24us -name "下一个采样点"}
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
