# -*- coding: utf-8 -*-
"""patch_pitch_width.py —— 修变调乘法的【高位截断】bug

★ 踩坑实录（2026-10-03，本项目自己造成的回归）
  变调最初写成：
      acc[k] <= acc[k] + ((freq_word(k) * pitch_coef(pitch_semi)) >> 12);
  看似正确，实则 **Verilog 按两个操作数的最大位宽计算乘积** ——
  freq_word 是 32 位、pitch_coef 是 16 位，乘积只有 32 位；
  而 freq_word 最大 562949953、乘 4096 需要 **44 位** ⇒ 高位被截断，
  相位增量变成垃圾，输出又弱又乱。

  实测后果：32 谱峰判据从 32/32 掉到 **0/32**，
  导出数据 min=-1184 max=3343 std=1300、直流偏置严重。

  ⚠️ 这与本项目在**包络乘法**上踩过的是同一个坑：
     "乘积必须在全宽网络上形成，再移位"，不能先截断。

★ 修法：把乘法放进一个函数，内部用 48 位中间量，
  这样乘积在全宽（48 位）上形成，再取 [43:12] 得到 32 位增量。

用法：python patch_pitch_width.py
"""
from __future__ import annotations

import os
import sys

sys.stdout.reconfigure(encoding='utf-8')

HERE = os.path.dirname(os.path.abspath(__file__))
TARGET = os.path.join(HERE, 'gen_tone_bank.py')

BAD_LINE = '                        acc[k] <= acc[k] + ((freq_word(k) * pitch_coef(pitch_semi)) >> 12);'
GOOD_LINE = '                        acc[k] <= acc[k] + pitch_inc(k, pitch_semi);'

FUNC = '''    // ============ 变调增量：在全宽 48 位上做乘法，再取 [43:12] ============
    // ★ 为什么必须这样写（本项目真实回归，详见 tools/gen/patch_pitch_width.py）：
    //   若直接写 (freq_word(k) * pitch_coef(pitch_semi)) >> 12，
    //   Verilog 会按两个操作数的最大位宽（32 位）算乘积 —— 而
    //   freq_word 最大 562949953、乘 4096 需要 44 位 ⇒ **高位被截断**，
    //   相位增量变成垃圾，输出又弱又乱（实测 32 谱峰判据从 32/32 掉到 0/32）。
    //   把乘法放进函数、内部用 reg [47:0] 承接，乘积就在全宽上形成。
    //   ⚠️ 与包络乘法是同一个坑："乘积在全宽形成后再移位"。
    function [31:0] pitch_inc;
        input integer      k;
        input signed [3:0] n;
        reg   [47:0]       p;
        begin
            p = {16'd0, freq_word(k)} * {16'd0, pitch_coef(n)};
            pitch_inc = p[43:12];
        end
    endfunction

'''

ANCHOR = '    // ============ ROM 地址 MUX（时分复用一份 ROM）============'


def main():
    src = open(TARGET, encoding='utf-8').read()

    if 'function [31:0] pitch_inc' in src:
        print('已打过本补丁（含 pitch_inc），跳过'); return

    assert BAD_LINE in src, '待修的累加行未找到（可能已被改过）'
    src = src.replace(BAD_LINE, GOOD_LINE, 1)

    assert ANCHOR in src, 'ROM 段锚点未匹配'
    src = src.replace(ANCHOR, FUNC + ANCHOR, 1)

    open(TARGET, 'w', encoding='utf-8', newline='\n').write(src)
    print('已就地修改:', TARGET)
    print('  · 累加行改为调用 pitch_inc(k, pitch_semi)')
    print('  · 新增 48 位全宽乘法函数 pitch_inc')


if __name__ == '__main__':
    main()
