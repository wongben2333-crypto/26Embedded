# =============================================================================
#  sim/wave_key_env.do —— 图④ 交互链路：按键 → 去抖 → gate → 包络 → 出声
#
#  用户用法（fpga_hank 目录下）：
#    & "F:\Modelsim_10.7\win64\vsim.exe" -view "sim\wlf\tb_wave_chain.wlf" -do "sim\wave_key_env.do"
#
#  ★ 打开后应当看到（自上而下）：
#    key（物理按键，低有效）→ key_raw（同步后）→ key_db（去抖后=gate）
#    → env_level（包络爬升）→ DBG_AUDIO（已出声）
#    【按一下 → 包络起来 → 松开 → 落下去】，五级依次响应，没有一级抢跑
#  ★ 数值：去抖窗口 2.621 ms；物理接触 → 出声 = 2.663 ms
# =============================================================================

set TB tb_wave_chain
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

wg "Stimulus" binary   [list /$TB/key /$TB/key2]
wg "Control"  binary   [list /$TB/dut/key_raw /$TB/dut/key_db /$TB/dut/DBG_GATE /$TB/dut/g_mono/mono_gate]
wg "Data"     unsigned [list /$TB/dut/g_mono/env_level] {-format analog-interpolated -min 0 -max 65536 -height 220}
wg "Data"     hex      [list /$TB/dut/g_mono/ph_acc]
wg "Output"   binary   [list /$TB/dut/DBG_AUDIO]
wg "Output"   hex      [list /$TB/led]

catch {configure wave -namecolwidth 200 -valuecolwidth 110 -timelineunits ms}
# 15~125 ms：一次完整的"按下 -> 按住 -> 松开"（松开在 115 ms）
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

# ③ 目标范围：按键过渡 + 2.621 ms 去抖
ztry "zoom range 15.00ms 17.05ms"  {wave zoom range 15.00ms 17.05ms}
ztry "restore zoom"          {WaveRestoreZoom {15.00 ms} {17.05 ms}}
after 500

# ④ 打印当前范围，让 transcript 自证（不靠肉眼看图）
if {[catch {set _r [wave zoom range]} _m]} {
    puts "\[zoom\] 查询当前范围失败: $_m"
} else {
    puts "\[zoom\] 当前时间范围 = $_r   （目标：15.00ms 17.05ms）"
}


puts "\[wave\] ===== 图④ 交互链路已就绪 ====="
puts "\[wave\] 看：key 拉低 ->（两级同步）key_raw ->（2.621 ms 去抖）key_db=gate"
puts "\[wave\]     -> env_level 爬升 -> DBG_AUDIO 置起 = 出声"
puts "\[wave\] 数值：去抖窗口 2.621 ms；物理接触 -> 出声 = 2.663 ms（<=10 ms 达标、<5 ms 达标）"
puts "\[wave\] 想看清那 2.6 ms 的过渡，把时间轴放大到 15.00~17.05 ms"
puts "\[wave\] 现在可以 Win+Shift+S 截图"



# ---- 游标：用官方语法 wave cursor add -time <t> -name <n> -------------------
# （不用 WaveRestoreCursors —— 那是旧式/别名，官方命令参考里 wave 命令族是
#   `wave cursor add|configure|delete|see|active`。见 liaison/MODELSIM-GUIDE.md）
ztry "cursor 15.001ms" {wave cursor add -time 15.001ms -name "物理接触"}
ztry "cursor 17.623ms" {wave cursor add -time 17.623ms -name "去抖完成(+2.621ms)"}
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
