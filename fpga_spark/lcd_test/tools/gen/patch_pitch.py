# -*- coding: utf-8 -*-
"""patch_pitch.py —— 给 gen_tone_bank.py 的模板加入【运行时半音变调】

赛题基础要求③原文（`_topic2.txt` 第 295 行）：
    「……支持**单音实时变调**、ADSR 包络调控、多声部实时混音……」

本项目的缺口：`tone_bank` 的频率字是 `case` 常量（编译期固定），
**运行时改不了** ⇒ 不满足"实时变调"。

做法：在累加通路上乘一个**运行时**半音系数（Q12 定点，4096 = ×1.0），
     acc[k] <= acc[k] + (freq_word(k) * pitch_coef(pitch_semi) >> 12)

为什么用乘法而不是查表改频率字：
  频率字有 32 个（每路一个），若为 16 个半音档各做一张 32 项表 = 512 项，
  而且"变调"本质是频率等比缩放，用乘法表达最直接、资源也省（1 个 DSP）。

用法：python patch_pitch.py
"""
from __future__ import annotations

import math
import os
import sys

sys.stdout.reconfigure(encoding='utf-8')

HERE = os.path.dirname(os.path.abspath(__file__))
TARGET = os.path.join(HERE, 'gen_tone_bank.py')

# 半音系数表（Q12）
COEFS = {n: round((2 ** (n / 12.0)) * 4096) for n in range(-8, 8)}

FUNC_ANCHOR = '    // ============ ROM 地址 MUX（时分复用一份 ROM）============'

FUNC = '''    // ============ 运行时半音变调系数（Q12 定点）============
    //   系数 = 2^(n/12) × 4096，n = -8..+7 半音，最大量化误差 <0.02%。
    //   用【查表】而不是实时算幂函数：变调档只有 16 个，而 FPGA 上算
    //   2^(n/12) 需要指数/开方单元，代价远高于一张 16 项小表。
    function [15:0] pitch_coef;               // Q12: 4096 = ×1.0
        input signed [3:0] n;
        begin
            case (n)
%PITCHCASES%
            endcase
        end
    endfunction

'''

ACC_OLD = '''                for (k = 0; k < N_VOICES; k = k + 1)
                    if (gate_in[k])
                        acc[k] <= acc[k] + freq_word(k);'''
ACC_NEW = '''                // ★ 变调在此生效：频率字 × 半音系数（Q12）>> 12。
                //   乘法在【累加通路上】，所以 pitch_semi 一改，下一个采样点
                //   就生效 —— 这正是"实时变调"要求的确定性、无等待。
                //   ⚠️ 必须写成 (a*b)>>12 而不能先截断：乘积是全宽再移位，
                //      否则会被截成噪声（本项目在包络乘法上踩过同一个坑）。
                for (k = 0; k < N_VOICES; k = k + 1)
                    if (gate_in[k])
                        acc[k] <= acc[k] + ((freq_word(k) * pitch_coef(pitch_semi)) >> 12);'''


def main():
    src = open(TARGET, encoding='utf-8').read()
    if 'pitch_coef' in src:
        print('已打过补丁（含 pitch_coef），跳过'); return

    assert FUNC_ANCHOR in src, 'ROM 段锚点未匹配'
    # ★ Verilog 负数字面量必须把负号写在尺寸【之前】：`-4'sd8` 合法，
    #   `4'sd-8` 非法（本项目实测报 "Expecting numeric digits"）。
    #   这个坑已经犯过一次（wave_rom 的 16'sd-10278），这里再次踩到，
    #   所以在生成器里就地做对，不靠"记得"。
    def lit(n):
        return ("-4'sd%d" % (-n)) if n < 0 else ("4'sd%d" % n)

    cases = ''.join(
        "                %s: pitch_coef = 16'd%d;   // x%.6f\n" % (lit(n), q, 2 ** (n / 12.0))
        for n, q in sorted(COEFS.items()))
    src = src.replace(FUNC_ANCHOR, FUNC.replace('%PITCHCASES%', cases) + FUNC_ANCHOR, 1)

    if ACC_OLD in src:
        src = src.replace(ACC_OLD, ACC_NEW, 1)
    else:
        # 模板里可能没有 if(gate_in[k]) 的保护，退化为无保护版本
        ACC_OLD2 = '''                for (k = 0; k < N_VOICES; k = k + 1)
                    acc[k] <= acc[k] + freq_word(k);'''
        assert ACC_OLD2 in src, '累加锚点未匹配（两种写法都不在）'
        src = src.replace(ACC_OLD2, ACC_NEW.replace('                    if (gate_in[k])\n', ''), 1)

    open(TARGET, 'w', encoding='utf-8', newline='\n').write(src)
    print('已就地修改:', TARGET)
    print('新增: pitch_coef() 查表 + 累加通路变调')


if __name__ == '__main__':
    main()
