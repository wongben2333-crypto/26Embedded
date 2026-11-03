# -*- coding: utf-8 -*-
"""
gen_cn_font.py -- Generate 16x16 Chinese character font matrix and string functions
for pure RTL LCD UI on Sipeed Tang Mega 138K.
"""
import os
from PIL import Image, ImageFont, ImageDraw

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

font = ImageFont.truetype('C:/Windows/Fonts/simsun.ttc', 14)

out = []
out.append('// =============================================================================')
out.append('//  cn_font.vh -- 16x16 Chinese Character Matrix & String Renderer')
out.append('//  Generated automatically for Tang Mega 138K LCD UI')
out.append('// =============================================================================')
out.append('')
out.append('function cn_font_dot;')
out.append('    input [7:0] id;')
out.append('    input [3:0] col;')
out.append('    input [3:0] row;')
out.append('    reg [15:0] row_bits;')
out.append('    begin')
out.append('        case (id)')

for ch, cid in char_map.items():
    im = Image.new('1', (16, 16), 0)
    draw = ImageDraw.Draw(im)
    draw.text((1, 0), ch, font=font, fill=1)
    out.append(f"            8'd{cid}: case (row) // '{ch}'")
    for y in range(16):
        bits = ''.join(['1' if im.getpixel((x, y)) else '0' for x in range(16)])
        out.append(f"                4'd{y}: row_bits = 16'b{bits};")
    out.append("                default: row_bits = 16'd0;")
    out.append('            endcase')

out.append("            default: row_bits = 16'd0;")
out.append('        endcase')
out.append('        cn_font_dot = row_bits[4\'d15 - col];')
out.append('    end')
out.append('endfunction')
out.append('')

# Function to get char ID for string
out.append('function [7:0] get_cn_char;')
out.append('    input [5:0] str_id;')
out.append('    input [4:0] idx;')
out.append('    begin')
out.append('        case (str_id)')

for sid, s in enumerate(strings):
    cn_in_s = [c for c in s if c in char_map]
    out.append(f"            6'd{sid}: case (idx) // \"{s}\"")
    for idx, c in enumerate(cn_in_s):
        out.append(f"                5'd{idx}: get_cn_char = 8'd{char_map[c]}; // '{c}'")
    out.append("                default: get_cn_char = 8'd255;")
    out.append('            endcase')

out.append("            default: get_cn_char = 8'd255;")
out.append('        endcase')
out.append('    end')
out.append('endfunction')
out.append('')

# Function to get string length (number of Chinese characters)
out.append('function [4:0] get_cn_str_len;')
out.append('    input [5:0] str_id;')
out.append('    begin')
out.append('        case (str_id)')
for sid, s in enumerate(strings):
    cn_in_s = [c for c in s if c in char_map]
    out.append(f"            6'd{sid}: get_cn_str_len = 5'd{len(cn_in_s)};")
out.append("        default: get_cn_str_len = 5'd0;")
out.append('        endcase')
out.append('    end')
out.append('endfunction')
out.append('')

# Function cn_text_pixel
out.append('function cn_text_pixel;')
out.append('    input [5:0] str_id;')
out.append('    input [9:0] curr_x, curr_y;')
out.append('    input [9:0] start_x, start_y;')
out.append('    input [1:0] scale; // 1: 16x16, 2: 32x32')
out.append('    reg [9:0] rx, ry;')
out.append('    reg [4:0] char_idx;')
out.append('    reg [4:0] s_len;')
out.append('    reg [7:0] ch_id;')
out.append('    reg [4:0] c_col;')
out.append('    reg [3:0] c_row;')
out.append('    begin')
out.append("        cn_text_pixel = 1'b0;")
out.append('        s_len = get_cn_str_len(str_id);')
out.append('        if (curr_x >= start_x && curr_y >= start_y) begin')
out.append("            rx = (scale == 2'd2) ? ((curr_x - start_x) >> 1) : (curr_x - start_x);")
out.append("            ry = (scale == 2'd2) ? ((curr_y - start_y) >> 1) : (curr_y - start_y);")
out.append("            if (ry < 10'd16 && rx < ({5'd0, s_len} * 10'd18)) begin")
out.append('                // char width = 16, spacing = 2 -> period = 18')
out.append("                char_idx = (rx * 22'd228) >> 12; // rx / 18")
out.append("                c_col = rx - (char_idx * 10'd18);")
out.append('                c_row = ry[3:0];')
out.append("                if (c_col < 5'd16) begin")
out.append('                    ch_id = get_cn_char(str_id, char_idx);')
out.append("                    if (ch_id != 8'd255) begin")
out.append('                        cn_text_pixel = cn_font_dot(ch_id, c_col[3:0], c_row);')
out.append('                    end')
out.append('                end')
out.append('            end')
out.append('        end')
out.append('    end')
out.append('endfunction')

target_path = os.path.join(os.path.dirname(__file__), 'cn_font.vh')
with open(target_path, 'w', encoding='utf-8') as f:
    f.write('\n'.join(out))

print(f'cn_font.vh written successfully! Total chars: {len(char_map)}, File size: {len("\\n".join(out))} bytes')
