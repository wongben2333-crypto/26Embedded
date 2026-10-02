# -*- coding: utf-8 -*-
"""gen_sine_quarters.py —— 生成 sine_rom.v 的第一象限查找表

为什么只存 1/4 波：
    正弦有 4 重对称性，只存第一象限（256 项）即可通过符号与镜像还原整周期。
    这让 LUT 占用减少 4 倍，且因为用组合 case 推断成分布式 ROM，
    可以被多路振荡器同时读（避开 BSRAM 端口冲突）。

数据格式：
    16 bit 有符号，满量程 ±32767
    val[i] = round(32767 * sin(pi/2 * i / 256))，i = 0..255
    因此 val[0] = 0，val[255] = 32765（≈ +满量程，不是 32767，因为 i/256 不到 π/2 终点）

⚠️ 不要手写这些系数 —— 手工写极易超出 16 位范围（本项目第一版就把 36030 写了进去，
   超过 +32767 会溢出）。必须用本脚本生成。

用法：
    python gen_sine_quarters.py            # 打印到 stdout
    python gen_sine_quarters.py --write    # 直接写入 rtl/synth/sine_rom.v
"""
from __future__ import annotations

import argparse
import math
import os
import sys

sys.stdout.reconfigure(encoding='utf-8')

DEPTH = 256
FULL_SCALE = 32767

HEADER = '''// =============================================================================
//  sine_rom.v —— 正弦查找表（第一象限 + 组合镜像，供多路振荡器时分复用）
//
//  ⚠️ 本文件由 tools/gen/gen_sine_quarters.py 生成，请勿手工编辑。
//     手工写系数极易超出 16 bit 有符号范围（曾有版本写入 36030，溢出）。
//
//  只存第一象限 256 项，其余象限用符号与镜像推导：
//      addr[9:8] = 0 -> +q[addr[7:0]]                第一象限
//      addr[9:8] = 1 -> +q[255 - addr[7:0]]          第二象限（镜像）
//      addr[9:8] = 2 -> -q[addr[7:0]]                第三象限
//      addr[9:8] = 3 -> -q[255 - addr[7:0]]          第四象限（镜像）
//
//  用组合 case 实现 => 综合成分布式 LUT ROM，可被多路同时读。
//  （赛题规定单个波表查表只算 1 个振荡器，且 BSRAM 多端口会串行化 —— 见 tone_bank.v）
//
//  格式：16 bit 有符号，量程 ±32767
//        q[i] = round(32767 * sin(pi/2 * i / 256))
// =============================================================================
`default_nettype none

module sine_rom (
    input  wire        clk,
    input  wire [9:0]  addr,
    output reg  signed [15:0] val
);

    // ⚠️ sine_q 必须先声明再使用（Verilog 不允许先用后声明）
    wire signed [15:0] sine_q [0:255];

    always @(posedge clk) begin
        case (addr[9:8])
            2'd0: val <=  sine_q[addr[7:0]];
            2'd1: val <=  sine_q[10'd255 - addr[7:0]];
            2'd2: val <= -sine_q[addr[7:0]];
            2'd3: val <= -sine_q[10'd255 - addr[7:0]];
        endcase
    end
'''

FOOTER = '''
endmodule

`default_nettype wire
'''


def build_table():
    tbl = []
    for i in range(DEPTH):
        v = int(round(FULL_SCALE * math.sin(math.pi / 2.0 * i / DEPTH)))
        # 夹紧到 16 bit 有符号范围，防止浮点边界溢出
        v = max(-32768, min(32767, v))
        tbl.append(v)
    return tbl


def render(tbl):
    lines = [HEADER]
    for i, v in enumerate(tbl):
        lines.append('    assign sine_q[%3d] = 16\'sd%d;\n' % (i, v))
    lines.append(FOOTER)
    return ''.join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--write', action='store_true',
                    help='直接写入 rtl/synth/sine_rom.v')
    args = ap.parse_args()

    tbl = build_table()

    # 自检：必须严格单调递增且不溢出
    assert tbl[0] == 0, tbl[0]
    assert all(-32768 <= v <= 32767 for v in tbl), 'overflow'
    assert all(tbl[i] < tbl[i + 1] for i in range(DEPTH - 1)), 'not monotonic'
    print('self-check OK: q[0]=%d q[%d]=%d max=%d min=%d' %
          (tbl[0], DEPTH - 1, tbl[-1], max(tbl), min(tbl)))

    text = render(tbl)

    if args.write:
        here = os.path.dirname(os.path.abspath(__file__))
        dst = os.path.normpath(os.path.join(here, '..', '..', 'rtl', 'synth', 'sine_rom.v'))
        with open(dst, 'w', encoding='utf-8', newline='\n') as f:
            f.write(text)
        print('wrote', dst, len(text), 'bytes')
    else:
        sys.stdout.write(text)


if __name__ == '__main__':
    main()
