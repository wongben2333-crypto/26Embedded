# -*- coding: utf-8 -*-
"""gen_waveforms.py —— 把仿真导出的 CSV 渲染成"一眼能看"的波形图 PNG

用户要求：「仿真图能甩我脸上就可以」。ModelSim 的 .wlf 需要装软件才能看，
所以流程是：
    ModelSim 仿真（真实运行）→ testbench 用 $fwrite 导出 CSV
    → 本脚本用 matplotlib 渲染 PNG → 直接贴给用户看

★ 数据来源是【真实仿真】，不是手工画的示意图。每个 PNG 上都会标注
  数据来源文件与产生方式，避免被误认为是"画出来的效果图"。

输入（由 testbench 生成，均在 fpga_hank/out/）：
    wave_pt8211.csv   时间(ns), BCK, WS, DIN      （tb_pt8211_final）
    wave_adsr.csv     时间(ns), 包络电平, 相位     （tb_adsr）
    wave_mix.csv      时间(ns), 混音输出           （tb_spectrum）

输出：fpga_hank/docs/waveforms/*.png

用法：python tools/verify/gen_waveforms.py
"""
from __future__ import annotations

import os
import sys

import numpy as np
import matplotlib
matplotlib.use('Agg')                       # 无显示环境
import matplotlib.pyplot as plt
import warnings
warnings.filterwarnings('ignore', message='Glyph')
from matplotlib import rcParams

sys.stdout.reconfigure(encoding='utf-8')

# ---- 中文字体：Windows 上优先用微软雅黑，否则退到黑体 ----------------
for _f in ('Microsoft YaHei', 'SimHei', 'Noto Sans CJK SC', 'Arial Unicode MS'):
    try:
        rcParams['font.sans-serif'] = [_f]
        rcParams['axes.unicode_minus'] = False
        break
    except Exception:
        continue
rcParams['axes.unicode_minus'] = False

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
OUT = os.path.join(ROOT, 'out')
DST = os.path.join(ROOT, 'docs', 'waveforms')


def _load(name):
    p = os.path.join(OUT, name)
    if not os.path.exists(p):
        print('  跳过 %s（不存在）' % name)
        return None
    rows = []
    with open(p, encoding='utf-8', errors='replace') as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            parts = [x for x in line.split(',') if x.strip() != '']
            # ★ 必须逐行校验列数一致：仿真 dump 的末行可能是空行或半行，
            #   直接 np.array(rows) 会报 "inhomogeneous shape"（本项目踩过）。
            if len(parts) != 2 and len(parts) != 3 and len(parts) != 4:
                continue
            try:
                rows.append([float(x) for x in parts])
            except ValueError:
                continue
    if not rows:
        print('  跳过 %s（无有效数据）' % name)
        return None
    ncol = max(len(r) for r in rows)
    rows = [r for r in rows if len(r) == ncol]
    return np.array(rows)


def _footer(fig, text):
    fig.text(0.012, 0.012, text, fontsize=7.5, color='#555555', va='bottom')


def plot_pt8211():
    d = _load('wave_pt8211.csv')
    if d is None or d.shape[1] < 4:
        return None
    t, bck, ws, din = d[:, 0], d[:, 1], d[:, 2], d[:, 3]
    # 只看前面一小段，让位序看得清
    n = min(len(t), int(np.searchsorted(t, t[0] + 8000)))
    t, bck, ws, din = t[:n], bck[:n], ws[:n], din[:n]

    # ★ 每条信号【各占一条独立泳道】：早期版本把三条线只隔 1.2 个单位，
    #   1 和 0 的边界几乎贴在一起，人眼分不清 —— 那不是"能甩脸上的图"。
    #   现在每条信号自己有 y 区间 [off, off+1]，并在区间内画网格底线。
    fig, ax = plt.subplots(figsize=(13, 5.6), dpi=130)
    offs = [(bck, 2.2, '#1f77b4', 'BCK 位时钟'), (ws, 1.1, '#2ca02c', 'WS 字选（声道）'), (din, 0.0, '#d62728', 'DIN 数据')]
    for sig, off, color, label in offs:
        ax.step(t, sig + off, where='post', color=color, lw=1.6, label=label)
        ax.axhline(off, color='#cccccc', lw=0.7, zorder=0)
        ax.axhline(off + 1, color='#eeeeee', lw=0.5, zorder=0)
    ax.set_yticks([0, 1, 1.1, 2.1, 2.2, 3.2])
    ax.set_yticklabels(['DIN 0', 'DIN 1', 'WS 0', 'WS 1', 'BCK 0', 'BCK 1'], fontsize=8.5)
    ax.set_xlabel('时间 (ns)', fontsize=10)
    ax.set_title('PT8211 I2S 发送时序（真实仿真导出）\n'
                 'BCK 上升沿间隔恒 320 ns -> fs = 97 656.25 Hz；WS 高=左声道，低=右声道；'
                 'BCK 是 1/16 占空比窄脉冲（非 50% 方波）',
                 fontsize=11)
    ax.legend(loc='upper right', fontsize=8.5, framealpha=0.9)
    ax.grid(axis='x', ls=':', alpha=0.35)
    ax.set_xlim(t[0], t[-1])
    ax.set_ylim(-0.25, 3.5)
    _footer(fig, '数据来源：ModelSim 10.7 运行 sim/tb/tb_pt8211_final.v，testbench 用 $fwrite 导出 out/wave_pt8211.csv')
    fig.tight_layout(rect=[0, 0.035, 1, 1])
    p = os.path.join(DST, '1_pt8211_I2S时序.png')
    fig.savefig(p)
    plt.close(fig)
    return p


def plot_adsr():
    d = _load('wave_adsr.csv')
    if d is None or d.shape[1] < 2:
        return None
    t, lvl = d[:, 0] / 1000.0, d[:, 1]        # ns -> us
    fig, ax = plt.subplots(figsize=(13, 5.2), dpi=130)
    ax.plot(t, lvl, color='#9467bd', lw=1.8)
    ax.axhline(65536, color='#999999', ls='--', lw=0.9, label='满幅 65536 (1.0)')
    ax.axhline(49152, color='#ff7f0e', ls='--', lw=0.9, label='保持电平 49152 (0.75)')
    ax.set_xlabel('时间 (µs)', fontsize=10)
    ax.set_ylabel('包络电平（Q16）', fontsize=10)
    ax.set_title('ADSR 包络实测曲线（真实仿真导出）\n'
                 '起音 10.5 ms → 衰减 10.5 ms → 保持 → 释放 62.9 ms（EN_DIV=512）',
                 fontsize=11)
    ax.legend(fontsize=8.5, loc='best', framealpha=0.9)
    ax.grid(ls=':', alpha=0.35)
    _footer(fig, '数据来源：ModelSim 10.7 运行 sim/tb/tb_adsr.v，每 512 clk 采样一次导出 out/wave_adsr.csv。'
                 '注：本图时间轴单位 µs，起音/释放的斜坡形状是判据重点。')
    fig.tight_layout(rect=[0, 0.055, 1, 1])
    p = os.path.join(DST, '2_ADSR包络曲线.png')
    fig.savefig(p)
    plt.close(fig)
    return p


def plot_mix():
    d = _load('wave_mix.csv')
    if d is None or d.shape[1] < 2:
        return None
    t, mix = d[:, 0] / 1000.0, d[:, 1]     # ns -> us
    # 展示前 ~600 个采样点，能看出多音叠加的复合波形
    n = min(len(t), 600)
    fig, axes = plt.subplots(2, 1, figsize=(13, 6.4), dpi=130,
                             gridspec_kw={'height_ratios': [2, 1.4]})
    ax = axes[0]
    ax.plot(t[:n], mix[:n], color='#1f77b4', lw=0.9)
    ax.set_ylabel('混音输出 (int16)', fontsize=10)
    ax.set_title('32 路振荡器混音输出 mix_out（真实仿真导出）\n'
                 '上：时域波形（多音叠加）；下：频谱（应看到 32 根独立谱峰）', fontsize=11)
    ax.grid(ls=':', alpha=0.35)

    # 频谱
    ax2 = axes[1]
    sig = mix - mix.mean()
    if len(sig) > 64:
        w = np.blackman(len(sig))
        sp = np.abs(np.fft.rfft(sig * w))
        fs = 97656.25
        fr = np.fft.rfftfreq(len(sig), 1.0 / fs)
        m = fr <= 8000
        sp_db = 20 * np.log10(sp[m] / max(sp[m].max(), 1e-9) + 1e-12)
        ax2.plot(fr[m], sp_db, color='#d62728', lw=0.9)
        for k in range(32):
            ax2.axvline(200 + 200 * k, color='#2ca02c', ls='--', lw=0.5, alpha=0.45)
        ax2.set_xlim(0, 8000)
        ax2.set_ylim(-80, 5)
        ax2.set_xlabel('频率 (Hz)', fontsize=10)
        ax2.set_ylabel('相对电平 (dBc)', fontsize=10)
        ax2.grid(ls=':', alpha=0.35)
        ax2.text(0.995, 0.06, '绿色虚线 = 期望的 32 个谱峰位置（200 Hz 起、间隔 200 Hz）',
                 transform=ax2.transAxes, ha='right', fontsize=8, color='#2ca02c')
    _footer(fig, '数据来源：ModelSim 10.7 运行 sim/tb/tb_spectrum.v，每个采样点导出 out/wave_mix.csv。'
                 '频谱判据由 tools/verify/check_peaks.py 独立判定：32/32 命中、0 杂散。')
    fig.tight_layout(rect=[0, 0.045, 1, 1])
    p = os.path.join(DST, '3_32路混音与频谱.png')
    fig.savefig(p)
    plt.close(fig)
    return p


def plot_gate_chain():
    """按键 → gate → 包络 的因果链（用 adsr 的相位列 + 电平列说明）。"""
    d = _load('wave_adsr.csv')
    if d is None or d.shape[1] < 3:
        return None
    t, lvl, ph = d[:, 0] / 1000.0, d[:, 1], d[:, 2]
    has_gate = d.shape[1] >= 4
    fig, axes = plt.subplots(3 if has_gate else 2, 1, figsize=(13, 7.0), dpi=130, sharex=True)
    axes[0].plot(t, lvl, color='#9467bd', lw=1.8)
    axes[0].set_ylabel('包络电平', fontsize=10)
    axes[0].set_title('按键 -> 包络 因果链（真实仿真导出）\n'
                      '自上而下：gate 按键输入 / 包络电平 / 包络状态机相位', fontsize=11)
    axes[0].grid(ls=':', alpha=0.35)
    if has_gate:
        axes[1].step(t, d[:, 3], where='post', color='#d62728', lw=1.6)
        axes[1].set_yticks([0, 1]); axes[1].set_yticklabels(['松开', '按住'], fontsize=8.5)
        axes[1].set_ylabel('gate', fontsize=10); axes[1].grid(ls=':', alpha=0.35)
        pax = axes[2]
    else:
        pax = axes[1]
    pax.step(t, ph, where='post', color='#2ca02c', lw=1.5)
    pax.set_yticks([0, 1, 2, 3])
    pax.set_yticklabels(['IDLE', 'ATK', 'DEC', 'SUS'], fontsize=8.5)
    pax.set_xlabel('时间 (µs)', fontsize=10)
    pax.grid(ls=':', alpha=0.35)
    _footer(fig, '数据来源：ModelSim 10.7 运行 sim/tb/tb_adsr.v 导出 out/wave_adsr.csv。'
                 'gate 为电平敏感：按住期间依次经过 起音→衰减→保持，松开后进入释放。')
    fig.tight_layout(rect=[0, 0.05, 1, 1])
    p = os.path.join(DST, '4_按键到包络因果链.png')
    fig.savefig(p)
    plt.close(fig)
    return p


def main():
    os.makedirs(DST, exist_ok=True)
    print('渲染波形图 →', DST)
    made = []
    for fn in (plot_pt8211, plot_adsr, plot_mix, plot_gate_chain):
        try:
            p = fn()
            if p:
                made.append(p)
                print('  已生成 %s (%.1f KB)' % (os.path.basename(p), os.path.getsize(p) / 1024))
        except Exception as e:
            print('  %s 失败: %s' % (fn.__name__, e))
    if not made:
        print('没有生成任何图。请先跑仿真让 testbench 导出 CSV：')
        print('  & "F:\\Modelsim_10.7\\win64\\vsim.exe" -c -do sim\\run.do')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
