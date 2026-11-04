# -*- coding: utf-8 -*-
"""
preview_ui_image.py -- Accurate offline renderer for lcd_ui.v
Renders the complete 800x480 frame for each instrument (Piano, Guitar, Violin, Erhu)
and saves preview PNGs to visually inspect Chinese fonts and UI layout.
"""
import os
import re
from PIL import Image, ImageDraw

def load_font_matrix(vh_path):
    with open(vh_path, 'r', encoding='utf-8', errors='ignore') as f:
        vh = f.read()

    dot_matrix = {}
    cur_id = None
    for line in vh.split('\n'):
        m = re.search(r"8'd(\d+):\s*case\s*\(row\)", line)
        if m:
            cur_id = int(m.group(1))
            dot_matrix[cur_id] = {}
            continue
        if cur_id is not None:
            m2 = re.search(r"4'd(\d+):\s*row_bits\s*=\s*16'b([01]+);", line)
            if m2:
                row = int(m2.group(1))
                bits = m2.group(2)
                dot_matrix[cur_id][row] = bits
            elif "endcase" in line and cur_id is not None:
                if len(dot_matrix[cur_id]) == 16:
                    cur_id = None
    return dot_matrix

# Strings matching gen_cn_font.py
strings = [
    "演奏", "示波", "谱峰", "曲目",                           # 0..3
    "纯硬件实时合成",                                         # 4
    "32复音 192独立振荡器",                                    # 5
    "48kHz音频采样 延迟2.1ms",                                 # 6
    "施坦威九尺大钢琴",                                         # 7
    "全单原声木吉他",                                           # 8
    "高保真抒情小提琴",                                         # 9
    "直通", "立体延迟", "空间合唱", "音乐厅混响",                 # 10..13
    "实时音频示波器",                                         # 14
    "左声道输出", "右声道输出",                                 # 15..16
    "立体声峰值电平",                                         # 17
    "硬件包络ADSR曲线",                                       # 18
    "施坦威三角钢琴键盘",                                       # 19
    "全单原声木吉他指板",                                       # 20
    "抒情小提琴指板琴弓",                                       # 21
    "32路独立物理振荡器频谱验证",                               # 22
    "乐曲伴奏与滚动乐谱",                                       # 23
    "控制发声总延迟2.1ms",                                     # 24
    "全国赛指标延迟小于10ms",                                   # 25
    "空弦", "一把位", "二把位", "三把位", "四把位",             # 26..30
    "主音量",                                                 # 31
    "运弓", "揉弦", "拨弦", "滑音",                             # 32..35
    "弦槌敲击毛毡响应",                                         # 36
    "物理建模弦振动",                                           # 37
    "亥姆霍兹粘滑锯齿波",                                       # 38
    "传统民族二胡",                                           # 39
    "民族二胡内外双弦",                                         # 40
    "琴弓内夹蟒皮共鸣",                                         # 41
    "低音G弦", "次中D弦", "中音A弦", "高音E弦",                 # 42..45
    "内弦D4", "外弦A4",                                       # 46..47
    "千斤", "琴筒", "触屏", "拉弓", "推弓"                      # 48..52
]

char_map = {}
for s in strings:
    for c in s:
        if '\u4e00' <= c <= '\u9fa5' and c not in char_map:
            char_map[c] = len(char_map)

def render_cn_string(img, dot_matrix, str_id, start_x, start_y, color=(255, 255, 255)):
    s = strings[str_id]
    cn_in_s = [c for c in s if c in char_map]
    draw = ImageDraw.Draw(img)
    for idx, c in enumerate(cn_in_s):
        cid = char_map[c]
        cx = start_x + idx * 18
        cy = start_y
        if cid in dot_matrix:
            for row in range(16):
                bits = dot_matrix[cid].get(row, "0"*16)
                for col in range(16):
                    if bits[col] == '1':
                        img.putpixel((cx + col, cy + row), color)

def render_ui_preview(timbre_sel, dot_matrix, out_path):
    img = Image.new('RGB', (800, 480), (10, 14, 26)) # Dark obsidian navy
    draw = ImageDraw.Draw(img)

    # Colors
    c_cyan = (0, 229, 255)
    c_amber = (255, 179, 0)
    c_green = (0, 230, 118)
    c_white = (255, 255, 255)
    c_gray = (144, 164, 174)
    c_border = (26, 54, 93)
    c_card_bg = (15, 23, 42)

    # 1. Top Navbar (y: 0..38)
    draw.rectangle([0, 0, 799, 38], fill=(13, 17, 30), outline=(26, 54, 93))
    # Title: FPGA 实时多音色合成电子乐器引擎
    draw.text((16, 12), "FPGA REALTIME INSTRUMENT 138K", fill=c_cyan)
    # Tabs
    render_cn_string(img, dot_matrix, 0, 218, 10, c_cyan)  # 演奏
    draw.line([218, 32, 218+36, 32], fill=c_cyan, width=2)
    render_cn_string(img, dot_matrix, 1, 368, 10, c_gray)  # 示波
    render_cn_string(img, dot_matrix, 2, 518, 10, c_gray)  # 谱峰
    render_cn_string(img, dot_matrix, 3, 668, 10, c_gray)  # 曲目
    draw.text((728, 12), "97.656k", fill=c_green)

    # 2. Three Cards (y: 44..104)
    # Card 1: 纯硬件实时合成 (x: 20..260)
    draw.rectangle([20, 44, 260, 104], fill=c_card_bg, outline=c_cyan)
    render_cn_string(img, dot_matrix, 4, 30, 50, c_cyan)   # 纯硬件实时合成
    render_cn_string(img, dot_matrix, 5, 30, 68, c_white)  # 32复音 192独立振荡器
    render_cn_string(img, dot_matrix, 6, 30, 86, c_gray)   # 48kHz音频采样 延迟2.1ms

    # Card 2: 音色选择 (x: 278..522)
    draw.rectangle([278, 44, 522, 104], fill=c_card_bg, outline=c_green)
    timbre_str_id = 7 if timbre_sel == 0 else (8 if timbre_sel == 1 else (9 if timbre_sel == 2 else 39))
    render_cn_string(img, dot_matrix, timbre_str_id, 286, 56, c_green)
    render_cn_string(img, dot_matrix, 31, 286, 84, c_white) # 主音量
    # Volume bar
    draw.rectangle([350, 85, 510, 93], fill=(20, 30, 50), outline=c_border)
    draw.rectangle([352, 87, 470, 91], fill=c_cyan)

    # Card 3: 硬件效果器 (x: 540..778)
    draw.rectangle([540, 44, 778, 104], fill=c_card_bg, outline=c_amber)
    render_cn_string(img, dot_matrix, 10, 542, 56, c_amber) # 直通
    render_cn_string(img, dot_matrix, 24, 542, 86, c_gray)  # 控制发声总延迟2.1ms

    # 3. Oscilloscope & ADSR Box (Bottom-Left x: 20..440, y: 114..468)
    draw.rectangle([20, 114, 440, 468], fill=c_card_bg, outline=c_border)
    render_cn_string(img, dot_matrix, 14, 32, 122, c_white) # 实时音频示波器
    draw.text((348, 122), "3.85 MILLI", fill=c_cyan)
    # Scope Grid
    for gx in range(50, 430, 38):
        draw.line([gx, 140, gx, 460], fill=(20, 35, 60))
    for gy in range(160, 460, 38):
        draw.line([30, gy, 430, gy], fill=(20, 35, 60))
    draw.line([30, 300, 430, 300], fill=(30, 70, 120), width=1)
    # Sine Wave
    import math
    pts = []
    for x in range(30, 430):
        y = int(300 + 110 * math.sin((x - 30) * 0.04) * math.cos((x - 30) * 0.01))
        pts.append((x, y))
    draw.line(pts, fill=c_cyan, width=2)

    # 4. Top-Right Spectrum & Level (x: 456..778, y: 114..265)
    draw.rectangle([456, 114, 778, 192], fill=c_card_bg, outline=c_border)
    render_cn_string(img, dot_matrix, 17, 468, 122, c_white) # 立体声峰值电平
    render_cn_string(img, dot_matrix, 15, 468, 142, c_gray)  # 左声道输出
    render_cn_string(img, dot_matrix, 16, 468, 160, c_gray)  # 右声道输出
    # 32 Peaks
    draw.rectangle([486, 142, 666, 154], fill=c_cyan)
    draw.rectangle([486, 160, 666, 172], fill=c_cyan)
    draw.text((470, 178), "-48dB     -24dB     -12dB      -6dB       0dB", fill=c_gray)

    # 5. Bottom-Right Dynamic Instrument Panel (x: 456..778, y: 270..468)
    draw.rectangle([456, 270, 778, 468], fill=c_card_bg, outline=c_cyan)

    if timbre_sel == 0:
        # Piano Mode
        render_cn_string(img, dot_matrix, 19, 468, 290, c_green)
        # Keyboard (x: 460..773, y: 322..458)
        # 7 White keys
        for i in range(7):
            wx = 460 + i * 45
            draw.rectangle([wx, 322, wx + 43, 458], fill=(240, 245, 250), outline=c_border)
        # Black keys
        for bx in [492, 537, 627, 672, 717]:
            draw.rectangle([bx, 322, bx + 24, 402], fill=(20, 25, 35), outline=c_border)
        # Active key (Middle C glowing)
        draw.rectangle([460, 322, 503, 458], fill=c_cyan, outline=c_white)

    elif timbre_sel == 1:
        # Guitar Mode
        render_cn_string(img, dot_matrix, 20, 468, 290, c_green)
        # Fretboard (x: 460..774, y: 320..462)
        draw.rectangle([460, 320, 774, 462], fill=(45, 25, 20), outline=c_border)
        draw.rectangle([466, 320, 469, 462], fill=c_white) # Nut
        # Frets
        for fx in [525, 585, 645, 705, 765]:
            draw.line([fx, 320, fx, 462], fill=(200, 210, 220), width=2)
        # Strings
        for sy in [336, 358, 380, 402, 424, 446]:
            draw.line([466, sy, 774, sy], fill=(220, 200, 160), width=1)
        # Strum aura

    elif timbre_sel == 2:
        # Violin Mode (Clear positions & strings!)
        render_cn_string(img, dot_matrix, 21, 468, 290, c_green)
        # Position Labels at y=320: 空弦, 一把位, 二把位, 三把位, 运弓
        render_cn_string(img, dot_matrix, 26, 470, 320, c_cyan)  # 空弦
        render_cn_string(img, dot_matrix, 27, 530, 320, c_cyan)  # 一把位
        render_cn_string(img, dot_matrix, 28, 590, 320, c_cyan)  # 二把位
        render_cn_string(img, dot_matrix, 29, 650, 320, c_cyan)  # 三把位
        render_cn_string(img, dot_matrix, 32, 716, 320, c_amber) # 运弓
        # Fingerboard (Ebony dark)
        draw.rectangle([466, 332, 715, 450], fill=(12, 16, 24), outline=c_border)
        # Fret markers / position lines
        for px in [525, 585, 645, 700]:
            draw.line([px, 332, px, 450], fill=(60, 80, 110), width=1)
        # 4 Strings
        draw.line([466, 348, 715, 348], fill=(210, 180, 140), width=3) # G3 (Gold)
        draw.line([466, 378, 715, 378], fill=(220, 230, 240), width=2) # D4 (Silver)
        draw.line([466, 408, 715, 408], fill=(245, 245, 255), width=2) # A4 (Steel)
        draw.line([466, 438, 715, 438], fill=(255, 240, 200), width=1) # E5 (Bright Gold)
        # String Labels on left
        draw.text((470, 340), "G3", fill=(210, 180, 140))
        draw.text((470, 370), "D4", fill=(220, 230, 240))
        draw.text((470, 400), "A4", fill=(245, 245, 255))
        draw.text((470, 430), "E5", fill=(255, 240, 200))
        # Bridge at x=725
        draw.rectangle([725, 326, 731, 456], fill=(180, 120, 60))
        # Bow hair and stick at x=720
        draw.line([720, 320, 720, 462], fill=c_white, width=2)
        draw.line([722, 320, 722, 462], fill=(160, 90, 40), width=2)
        # Active finger stop on A4 1st position (B4 = 71)

    elif timbre_sel == 3:
        # Erhu Mode (二胡)
        render_cn_string(img, dot_matrix, 40, 468, 290, c_green)
        # Labels at y=320: 千斤, 一把位, 二把位, 三把位, 琴筒
        render_cn_string(img, dot_matrix, 48, 468, 320, c_cyan)  # 千斤
        render_cn_string(img, dot_matrix, 27, 530, 320, c_cyan)  # 一把位
        render_cn_string(img, dot_matrix, 28, 590, 320, c_cyan)  # 二把位
        render_cn_string(img, dot_matrix, 29, 650, 320, c_cyan)  # 三把位
        render_cn_string(img, dot_matrix, 49, 716, 320, c_amber) # 琴筒
        # Rosewood Neck (紫檀)
        draw.rectangle([466, 386, 700, 396], fill=(60, 25, 20))
        # Qianjin (千斤)
        draw.rectangle([466, 365, 470, 415], fill=c_white)
        # Position divider marks
        for px in [525, 585, 645]:
            draw.line([px, 384, px, 398], fill=c_amber, width=2)
        # Inner string (D4) and Outer string (A4)
        draw.line([466, 368, 730, 368], fill=(210, 180, 140), width=2) # 内弦
        draw.line([466, 414, 730, 414], fill=(240, 245, 255), width=2) # 外弦
        render_cn_string(img, dot_matrix, 46, 472, 350, (210, 180, 140)) # 内弦D4
        render_cn_string(img, dot_matrix, 47, 472, 420, (240, 245, 255)) # 外弦A4
        # Resonator Drum (Hexagonal Python skin)
        draw.rectangle([704, 340, 768, 442], fill=(80, 50, 30), outline=(220, 200, 160))
        # Python skin scale pattern
        for sy in range(350, 435, 12):
            for sx in range(710, 760, 12):
                draw.rectangle([sx, sy, sx+4, sy+4], fill=(130, 90, 40))
        # Bamboo bow passing between strings
        draw.line([700, 345, 700, 437], fill=c_white, width=2) # Bow hair
        draw.line([703, 345, 703, 437], fill=(180, 140, 60), width=3) # Bamboo stick
        # Active vibration glow
        draw.ellipse([540, 360, 560, 376], fill=c_amber, outline=c_white)

    # 6. Touch ripple cursor (demonstrating touch interaction)
    tx, ty = 550, 408
    draw.ellipse([tx-8, ty-8, tx+8, ty+8], outline=c_cyan, width=2)
    draw.line([tx-12, ty, tx+12, ty], fill=c_cyan)
    draw.line([tx, ty-12, tx, ty+12], fill=c_cyan)
    draw.point([tx, ty], fill=c_white)

    img.save(out_path)
    print(f"Generated UI Preview: {out_path}")

def main():
    vh_path = os.path.join(os.path.dirname(__file__), '..', '..', 'rtl', 'ui', 'cn_font.vh')
    dot_matrix = load_font_matrix(vh_path)
    print("Loaded characters for preview:", len(dot_matrix))

    out_dir = os.path.join(os.path.dirname(__file__), '..', '..', 'docs', 'ui_previews')
    os.makedirs(out_dir, exist_ok=True)

    names = ["piano", "guitar", "violin", "erhu"]
    for timbre_sel in range(4):
        p = os.path.join(out_dir, f"ui_preview_{timbre_sel}_{names[timbre_sel]}.png")
        render_ui_preview(timbre_sel, dot_matrix, p)

if __name__ == '__main__':
    main()
