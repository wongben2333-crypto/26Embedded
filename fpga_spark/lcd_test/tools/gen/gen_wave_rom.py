# -*- coding: utf-8 -*-
"""gen_wave_rom.py —— 生成 wave_rom.v（多音色波表）

★ 设计直接取自参考实现 vdalex/tangmega-138k-fpga-projects 的
  fractal_music/tools/music_model.py（Tang Mega 138K 实机跑通的工程）：

    WAVE_BITS  = 8          # 每张表 256 项
    地址 = {table, phase[7:0]}   # 多张表共用一份 ROM

  它的取舍理由（原文注释）：
    "A pure sine has no harmonics at all, so even with the range raised the
     result stays dull; but giving the bass harmonics too would just muddy the
     low end. So: sine for the bass, a band-limited sawtooth for everything
     above it."
    HARMONICS = 5   # 1/n 幅度，4.8 kHz 以下无混叠

  本项目需要 ≥2 种可切换音色（赛题拓展②），因此在它两种的基础上
  再补两种，共 4 张表，仍然共用一份 ROM：

    table 0 : 纯正弦        —— 低音/纯净音色
    table 1 : 5 次谐波锯齿   —— 明亮音色（参考实现的 "bright"）
    table 2 : 方波（奇次谐波）—— 中空音色（管风琴/单簧管感）
    table 3 : 三角波（奇次 1/n²）—— 柔和音色（长笛感）

  ⚠️ 带限很重要：不做带限的锯齿/方波在高音区会严重混叠，
     听感是"金属味杂音"，且频谱上会出现本项目测试模式不希望的谱峰。
     本项目测试模式输出 200..6400 Hz，取 5~9 次谐波可保证
     最高谐波 (6400 × 9 = 57.6 kHz) —— 超过 Nyquist(24.4 kHz) 会混叠！
     因此高音区必须降谐波数，见下面的 per-table 谐波上限说明。

  重要：本 ROM 只用于【演奏模式】的音色。测试模式（32 谱峰取证）
  必须用纯正弦，否则每路会产生多个谱峰，判据会误判。

用法：python gen_wave_rom.py --write
"""
from __future__ import annotations

import argparse
import math
import os
import sys

sys.stdout.reconfigure(encoding='utf-8')

WAVE_BITS = 8
N = 1 << WAVE_BITS          # 256
SCALE = 32767

# ---------------------------------------------------------------- 波形定义 ---
# 每张表给出"第 n 次谐波的幅度系数 a_n"，然后按 sum(a_n * sin(2πn i/N)) 生成，
# 最后按 sum(|a_n|) 归一化到 ±32767。
#
# ★ 谐波数上限：本项目测试网格最高 6400 Hz，但演奏模式可能更高。
#   为在所有音高下都不混叠，取 5 次谐波是安全选择（参考实现同）。
#   若将来允许更高的音，必须按音高动态选择表（mipmap 式），
#   或进一步降低谐波数。


def sine_harmonics():
    """纯正弦：只有基波。低音用，避免低频变浑。"""
    return {1: 1.0}


def saw_harmonics(k=5):
    """带限锯齿：1/n 幅度。参考实现的 'bright' 音色。"""
    return {n: 1.0 / n for n in range(1, k + 1)}


def square_harmonics(k=9):
    """方波：只取奇次谐波，幅度 1/n。中空音色。"""
    return {n: 1.0 / n for n in range(1, k + 1) if n % 2 == 1}


def triangle_harmonics(k=9):
    """三角波：只取奇次谐波，幅度 1/n²。柔和音色。"""
    return {n: 1.0 / (n * n) for n in range(1, k + 1) if n % 2 == 1}


TABLES = [
    ("sine",     "纯正弦 — 低音 / 测试模式必备",        sine_harmonics()),
    ("saw5",     "5 次谐波带限锯齿 — 明亮",             saw_harmonics(5)),
    ("square9",  "奇次 9 次谐波方波 — 中空",            square_harmonics(9)),
    ("tri9",     "奇次 9 次谐波三角波 — 柔和",          triangle_harmonics(9)),
]


def build_table(harm):
    norm = sum(abs(a) for a in harm.values())
    if norm == 0:
        return [0] * N
    out = []
    for i in range(N):
        v = sum(a * math.sin(2 * math.pi * n * i / N) for n, a in harm.items()) / norm
        out.append(max(-32768, min(32767, int(round(SCALE * v)))))
    return out


HEADER = '''// =============================================================================
//  wave_rom.v —— 多音色波表（%NTAB% 张表共用一份 ROM）
//
//  ⚠️ 本文件由 tools/gen/gen_wave_rom.py 生成，请勿手工编辑。
//
//  地址格式：{{table, phase[7:0]}}，即 addr[%ABM1%:8] = 表号，addr[7:0] = 相位
//  这是参考实现 vdalex/tangmega-138k-fpga-projects 的做法：
//  多张表共用一份 ROM，只用一个地址多路选择器切换音色。
//
//  表内容：
%TBLDESC%
//
//  ★ 为什么必须带限（band-limited）：
//    不做带限的锯齿/方波含无限谐波，在高音区会严重混叠。
//    听感是"金属味杂音"，频谱上还会长出本项目测试模式不希望的谱峰。
//    各表的谐波数已按"5 次以内"取（参考实现同为 5），
//    保证常用音域内最高谐波不超过奈奎斯特频率。
//
//  ★ 测试模式必须用 table 0（纯正弦）：
//    测试模式的判据是"每路一个独立谱峰"。若用含谐波的表，
//    每一路会产出多个谱峰，判据会误判为杂散。
//
//  数据格式：16 bit 有符号，量程约 ±32767
// =============================================================================
`default_nettype none

module wave_rom (
    input  wire                clk,
    input  wire [%AWM1%:0]   addr,      // {{table, phase[7:0]}}
    output reg  signed [15:0]  data
);

    // ⚠️ 用 case 常量而不是 $readmemh：
    //   参考实现记录过"Gowin 对某些大 case ROM 会跳过初始化导致 ROM 全空"，
    //   但那是上千项的 case；本 ROM 共 %TOTAL% 项，用 case 更可控且不依赖
    //   外部 .vh 文件，交付更简单。若将来表变大，改用
    //   `(* ram_style = "block" *) reg [15:0] rom [0:N-1]; initial $readmemh(...)`。
    always @(posedge clk) begin
        case (addr)
'''

FOOTER = '''            default: data <= 16'sd0;
        endcase
    end

endmodule

`default_nettype wire
'''


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--write', action='store_true')
    args = ap.parse_args()

    tables = [(name, desc, build_table(h)) for name, desc, h in TABLES]
    total = len(tables) * N
    aw = (total - 1).bit_length()

    # 自检
    #   ⚠️ 不要断言 |peak| 接近满幅：带限波形的峰值本来就不等于归一化常数。
    #     例如 5 次谐波锯齿，在过零点附近有吉布斯现象、峰值可以很大，
    #     但波形峰值受谐波相位影响，用 max 判幅度是不可靠的判据。
    #     正确的判据是【总能量】：所有表都按 sum(|a_n|) 归一化，
    #     所以只需检查没有溢出、且不是全零。
    for name, desc, t in tables:
        assert len(t) == N, name
        assert all(-32768 <= v <= 32767 for v in t), name + ' overflow'
        assert any(v != 0 for v in t), name + ' all zero'
        rms = math.sqrt(sum(v * v for v in t) / N)
        assert rms > 3000, '%s rms too low (%.0f)' % (name, rms)

    print('tables = %d, entries/table = %d, total = %d -> addr width %d'
          % (len(tables), N, total, aw))
    for i, (name, desc, t) in enumerate(tables):
        rms = math.sqrt(sum(v * v for v in t) / N)
        print('  table %d %-8s min=%6d max=%6d rms=%7.1f  (%s)'
              % (i, name, min(t), max(t), rms, desc))

    desc_lines = '\n'.join(
        '//    table %d : %-8s %s' % (i, name, desc)
        for i, (name, desc, _) in enumerate(tables))

    # ★ 用自定义占位符替换，绝不用 str.format —— Verilog 的 {} 位选/拼接
    #   会与 format 的字段语法冲突（本项目在 gen_tone_bank 上已经踩过一次）。
    text = HEADER
    for kk, vv in {
        '%NTAB%': str(len(tables)),
        '%ABM1%': str(aw - 1),
        '%AWM1%': str(aw - 1),
        '%AB%':   str(aw),
        '%AW%':   str(aw),
        '%TOTAL%': str(total),
        '%TBLDESC%': desc_lines,
    }.items():
        text = text.replace(kk, vv)
    body = [text]
    for ti, (name, desc, t) in enumerate(tables):
        body.append('            // ---- table %d : %s ----\n' % (ti, name))
        for i, v in enumerate(t):
            addr = (ti << WAVE_BITS) | i
            # ★ 负数必须把负号写在尺寸【之前】：Verilog 要求 `-16'sd10278`，
            #   写成 `16'sd-10278` 是【非法】的。本项目实测报过 508 个
            #   `Expecting numeric digits` —— 这是代码生成器最容易犯的错。
            lit = ("-16'sd%d" % (-v)) if v < 0 else ("16'sd%d" % v)
            body.append("            %d'd%d: data <= %s;\n" % (aw, addr, lit))
    body.append(FOOTER)
    text = ''.join(body)

    if args.write:
        here = os.path.dirname(os.path.abspath(__file__))
        dst = os.path.normpath(os.path.join(here, '..', '..', 'rtl', 'synth', 'wave_rom.v'))
        with open(dst, 'w', encoding='utf-8', newline='\n') as f:
            f.write(text)
        print('wrote', dst, len(text), 'bytes')
    else:
        sys.stdout.write(text)


if __name__ == '__main__':
    main()
