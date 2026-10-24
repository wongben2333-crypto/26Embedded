# -*- coding: utf-8 -*-
"""
把任意字符串渲染成 SSD1963 用的 1bpp 点阵，并生成 Verilog ROM 赋值代码。

用法：
    python gen_logo.py "spark" 60 4

    参数1 = 文字内容
    参数2 = 字号（Arial Black，px）
    参数3 = 硬件放大倍数（必须是 2 的幂：2/4/8，否则 RTL 里要改用除法）

输出：
    _logo_block.v   —— 直接粘进 lcd_test_top.v 替换 logo_rom 那一段
    同时打印 LOGO_* 参数和居中坐标，需要同步更新到 RTL
"""
import sys
from PIL import Image, ImageDraw, ImageFont

FONT = r"C:\Windows\Fonts\ariblk.ttf"      # Arial Black；换字体改这里
SCREEN_W, SCREEN_H = 800, 480


def main():
    text = sys.argv[1] if len(sys.argv) > 1 else "spark"
    size = int(sys.argv[2]) if len(sys.argv) > 2 else 60
    scale = int(sys.argv[3]) if len(sys.argv) > 3 else 4

    assert scale & (scale - 1) == 0, "scale 必须是 2 的幂"

    # 1) 渲染并裁到墨迹边界
    img = Image.new("L", (size * (len(text) + 2), size * 3), 0)
    ImageDraw.Draw(img).text((10, 10), text, font=ImageFont.truetype(FONT, size), fill=255)
    img = img.crop(img.getbbox())
    W, H = img.size

    # 2) 二值化 + 按 32bit 打包（高位在前）
    px = img.load()
    words = (W + 31) // 32
    rom = []
    for y in range(H):
        for w in range(words):
            v = 0
            for b in range(32):
                x = w * 32 + b
                if x < W and px[x, y] > 128:
                    v |= 1 << (31 - b)
            rom.append(v)

    # 3) 生成 Verilog 赋值
    lines = []
    for i in range(0, len(rom), 3):
        parts = [f"logo_rom[{i+k}] = 32'h{v:08X};" for k, v in enumerate(rom[i:i+3])]
        lines.append("        " + " ".join(parts))

    block = f"""    reg [31:0] logo_rom [0:{len(rom)-1}];

    initial begin
{chr(10).join(lines)}
    end
"""
    open("_logo_block.v", "w", encoding="utf-8").write(block)

    dw, dh = W * scale, H * scale
    print(f"点阵      : {W} x {H}")
    print(f"ROM 字数  : {len(rom)}  (每行 {words} 字)")
    print(f"显示尺寸  : {dw} x {dh}")
    print(f"居中起点  : x={ (SCREEN_W-dw)//2 }, y={ (SCREEN_H-dh)//2 }")
    print()
    print("需要同步到 RTL 的参数：")
    print(f"    localparam LOGO_W     = {W};")
    print(f"    localparam LOGO_H     = {H};")
    print(f"    localparam LOGO_WORDS = {words};")
    print(f"    localparam LOGO_SCALE = {scale};")
    print(f"    localparam LOGO_DX = {dw};")
    print(f"    localparam LOGO_DY = {dh};")
    print(f"    // dx = px - { (SCREEN_W-dw)//2 };  dy = py - { (SCREEN_H-dh)//2 };")
    print(f"    // ridx = sy * {words} + sx[7:5];")
    print()
    print("已写出 _logo_block.v，粘进 lcd_test_top.v 替换 logo_rom 段即可。")

    # 预览
    out = Image.new("RGB", (SCREEN_W, SCREEN_H), (6, 12, 28))
    o = out.load()
    sx0, sy0 = (SCREEN_W - dw) // 2, (SCREEN_H - dh) // 2
    for sy in range(H):
        for sxx in range(W):
            if (rom[sy * words + (sxx >> 5)] >> (31 - (sxx & 31))) & 1:
                r = int(255 * sxx / max(W - 1, 1))
                for dy in range(scale):
                    for dx in range(scale):
                        o[sx0 + sxx * scale + dx, sy0 + sy * scale + dy] = (r // 3, 255 - r // 2, 255 - r // 4)
    out.save("_logo_preview.png")
    print("预览图 _logo_preview.png")


if __name__ == "__main__":
    main()
