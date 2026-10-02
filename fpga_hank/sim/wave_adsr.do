# =============================================================================
#  sim/wave_adsr.do —— 图② ADSR 包络：起音与释放
#
#  用户用法（fpga_hank 目录下）：
#    & "F:\Modelsim_10.7\win64\vsim.exe" -view "sim\wlf\tb_wave_adsr.wlf" -do "sim\wave_adsr.do"
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
proc wg {title radix sigs} {
    catch {add wave -divider $title}
    catch {eval add wave -radix $radix $sigs} msg
}

wg "Stimulus" binary   [list /$TB/rst_n /$TB/gate]
wg "Control"  hex      [list /$TB/dut/en_div_cnt /$TB/dut/en_phase]
wg "Data"     unsigned [list /$TB/level]

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

# ③ 目标范围：起音 10.49 ms + 衰减 20.97 ms
ztry "zoom range 0ms 35ms"  {wave zoom range 0ms 35ms}
ztry "restore zoom"          {WaveRestoreZoom {0 ms} {35 ms}}
after 500

# ④ 打印当前范围，让 transcript 自证（不靠肉眼看图）
if {[catch {set _r [wave zoom range]} _m]} {
    puts "\[zoom\] 查询当前范围失败: $_m"
} else {
    puts "\[zoom\] 当前时间范围 = $_r   （目标：0ms 35ms）"
}

catch {add wave -group "Data" -radix unsigned -height 200 /$TB/level}

puts "\[wave\] ===== 图② adsr 已就绪 ====="
puts "\[wave\] 看：gate 拉高 -> env_level 斜坡上升（不是垂直=包络真的在动）"
puts "\[wave\]     满幅后有一段下降 = DEC；中间长平台 = sustain（SUS_LEVEL=49152）"
puts "\[wave\]     gate 拉低 -> 长斜坡回落 = release"
puts "\[wave\] 数值：起音 10.49 ms / 衰减 20.97 ms / 释放 62.91 ms"
puts "\[wave\] 若想看清起音段，把时间轴放大到 0~15 ms 即可（工具栏 Zoom）"
puts "\[wave\] 现在可以 Win+Shift+S 截图"
