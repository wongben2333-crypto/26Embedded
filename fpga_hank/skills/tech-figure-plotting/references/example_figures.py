# -*- coding: utf-8 -*-
"""Redraw all data figures per tech-figure-plotting skill.

Style source: pythesis-plot references/style_guide.md (30-char specs)
  - palette   : Academic blue / Nature
  - font size : title 12-14 bold, axis label 10-12, tick 9-10, legend 9-10, annot 8-9
  - figure    : double-column 7.0 x 4.5 (golden-ratio-ish), single 3.5 x 2.5
  - line      : lw 1.5 std / 2.0 emph / 1.0 aux
  - marker    : hollow (facecolor white + edgecolor color), markersize 6, markevery
  - export    : bbox_inches tight, dpi 300, pad_inches 0.02, facecolor white
Project rules (this repo):
  - figure text ASCII ONLY (Microsoft YaHei lacks many glyphs)
  - every figure gets a data-source footnote
"""
import os, sys
sys.stdout.reconfigure(encoding='utf-8')
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib import font_manager

OUT = r'C:\Users\Danny\Desktop\FPGA competition\_research\doc-figures'
os.makedirs(OUT, exist_ok=True)

# ---------- font ----------
for c in [r'C:\Windows\Fonts\msyh.ttc', r'C:\Windows\Fonts\simhei.ttf']:
    if os.path.exists(c):
        font_manager.fontManager.addfont(c)
plt.rcParams['font.sans-serif'] = ['Microsoft YaHei', 'SimHei']
plt.rcParams['axes.unicode_minus'] = False
plt.rcParams.update({
    'font.size': 11,
    'axes.titlesize': 12.5,
    'axes.labelsize': 11,
    'xtick.labelsize': 9.5,
    'ytick.labelsize': 9.5,
    'legend.fontsize': 9.5,
    'axes.grid': True,
    'grid.alpha': 0.22,
    'grid.linestyle': '--',
    'grid.linewidth': 0.7,
    'axes.axisbelow': True,
    'axes.edgecolor': '#555555',
    'axes.linewidth': 0.9,
    'figure.dpi': 300,
    'savefig.dpi': 300,
    'legend.frameon': False,
})

ACADEMIC = ['#2E5AAC', '#5B9BD5', '#A5D6F3', '#1F4E79', '#8FB8E6']
FIVE = ['#2E5AAC', '#00A087', '#E64B35', '#3C5488', '#F39B7F']   # contrast for 5 series
NATURE = ['#E64B35', '#4DBBD5', '#00A087', '#3C5488', '#F39B7F']
GREEN, RED = '#00A087', '#E64B35'
GREY = '#777777'

made = []


def save(fig, name):
    p = os.path.join(OUT, name)
    fig.tight_layout()
    fig.savefig(p, bbox_inches='tight', pad_inches=0.02, dpi=300,
                facecolor='white', edgecolor='none')
    plt.close(fig)
    made.append((name, os.path.getsize(p)))
    print('  %-32s %9d B' % (name, os.path.getsize(p)))


def src(ax, text, y=0.98):
    ax.text(0.015, y, text, transform=ax.transAxes, fontsize=8,
            va='top', ha='left', color=GREY, linespacing=1.5)


# ============================================================
# 1. 二胡 5 档权重（分组柱状）—— 注释移到图外，避免压柱
# ============================================================
BAND = [
    ('D4', (0.5430, 2.2337, 0.9270, 0.9789, 0.7491, 0.5683)),
    ('F4', (2.4182, 1.2812, 0.7595, 0.8722, 0.4957, 0.1731)),
    ('A4', (2.9624, 0.9762, 0.8605, 0.9428, 0.1488, 0.1094)),
    ('C5', (3.3609, 1.1660, 0.8982, 0.2678, 0.1348, 0.1723)),
    ('D5', (3.3586, 1.2813, 0.8546, 0.1280, 0.1918, 0.1857)),
]
x = range(6)
w = 0.155
fig, ax = plt.subplots(figsize=(7.0, 4.3))
for i, (nm, tup) in enumerate(BAND):
    ax.bar([v + (i - 2) * w for v in x], tup, width=w, label=nm,
           color=FIVE[i], edgecolor='#333333', linewidth=0.5, zorder=3)
ax.set_xticks(list(x))
ax.set_xticklabels(['H1', 'H2', 'H3', 'H4', 'H5', 'H6'])
ax.set_xlabel('Harmonic index')
ax.set_ylabel('Relative gain (row mean = 1.000)')
ax.set_title('Erhu harmonic weight table (5 bands)')
ax.set_ylim(0, 3.9)
ax.legend(ncol=5, loc='upper center', bbox_to_anchor=(0.5, -0.13), handlelength=1.2)
src(ax, 'Source: tools/gen/gen_piano_rom.py (BAND_MUL table)')
save(fig, 'fig-erhu-bandmul.png')

# ============================================================
# 2. 三段录音交叉验证（折线族，空心标记）
# ============================================================
bands = ['397 Hz', '550 Hz', '1.6 kHz', '2.5 kHz', '3.5-5 kHz']
series = [
    ('Saima (176 kbps)',   [25.1, 24.5, 12.6, -9.3, -12.7], 'o'),
    ('Liangzhu (132 kbps)', [9.9, 11.9, 4.8, -21.5, -22.4], 's'),
    ('Ruoshui (159 kbps)', [20.1, 23.2, 13.1, -11.5, -13.1], '^'),
]
xx = range(len(bands))
fig, ax = plt.subplots(figsize=(7.0, 4.0))
for i, (nm, ys, mk) in enumerate(series):
    ax.plot(xx, ys, marker=mk, markersize=6, linewidth=1.5, label=nm,
            color=NATURE[i], markerfacecolor='white',
            markeredgecolor=NATURE[i], markeredgewidth=1.5, zorder=3)
ax.axhline(0, color=GREY, lw=1.0, zorder=2)
ax.set_xticks(list(xx))
ax.set_xticklabels(bands)
ax.set_xlabel('Frequency band')
ax.set_ylabel('Level per Hz relative to 1 kHz (dB)')
ax.set_title('Spectrum cross-check, three erhu recordings')
ax.legend(loc='lower left')
src(ax, 'Source: _research/pc-link/ERHU-CROSSCHECK.md', y=0.16)
save(fig, 'fig-erhu-crosscheck.png')

# ============================================================
# 3. 资源占用（横向柱状，标签右对齐）
# ============================================================
res = [('Logic (LUT+ALU)', 31728, 138240), ('Register (FF)', 10576, 139095),
       ('BSRAM (block)', 70, 340), ('DSP (18x18)', 104.5, 298)]
fig, ax = plt.subplots(figsize=(7.0, 3.4))
names = [r[0] for r in res]
pct = [r[1] / r[2] * 100 for r in res]
bars = ax.barh(names, pct, color=ACADEMIC[0], height=0.5,
               edgecolor='#333333', linewidth=0.5, zorder=3)
for b, p, r in zip(bars, pct, res):
    v = ('%.0f' % r[1]) if r[1] >= 100 else ('%.1f' % r[1])
    ax.text(p + 0.8, b.get_y() + b.get_height() / 2,
            '%.1f%%   (%s / %s)' % (p, v, r[2]),
            va='center', fontsize=9)
ax.set_xlim(0, 78)
ax.set_xlabel('Utilisation (%)')
ax.set_title('Resource usage (current bitstream, 0 violations)')
ax.invert_yaxis()
src(ax, 'Source: evidence/fpga_hank_MODE1_H4_rpt.txt', y=0.99)
save(fig, 'fig-resources.png')

# ============================================================
# 4. 各阶段时序（正负柱状，零线加粗）
# ============================================================
STAGES = [
    ('8 voices\n(pipeline)', 0.186, 0),
    ('20 voices\n(attempt)', -6.774, 13203),
    ('one-hot\nallocator', 0.055, 0),
    ('erhu drive', -1.499, 431),
    ('outsweep\n(1st try)', -4.919, 754),
]
fig, ax = plt.subplots(figsize=(7.0, 4.2))
labels = [s[0] for s in STAGES]
slacks = [s[1] for s in STAGES]
cols = [GREEN if s >= 0 else RED for s in slacks]
bars = ax.bar(labels, slacks, color=cols, width=0.55,
              edgecolor='#333333', linewidth=0.5, zorder=3)
for b, s in zip(bars, STAGES):
    y = b.get_height()
    txt = '%.3f ns' % s[1] + ('\n%d viol.' % s[2] if s[2] else '\n0 viol.')
    ax.text(b.get_x() + b.get_width() / 2, y + (0.2 if y >= 0 else -0.35),
            txt, ha='center', va='bottom' if y >= 0 else 'top', fontsize=8.5)
ax.axhline(0, color='#333333', lw=1.4, zorder=4)
ax.set_ylabel('Worst slack (ns)')
ax.set_ylim(-8.6, 2.0)
ax.set_title('Timing across design iterations')
ax.text(0.99, 0.03, 'green = timing closed   red = violations present',
        transform=ax.transAxes, fontsize=8, ha='right', color=GREY)
src(ax, 'Source: evidence/fpga_hank_MODE1_*.tr.txt', y=0.99)
save(fig, 'fig-timing-iterations.png')

# ============================================================
# 5. 延迟分布（柱状 + 指标线）
# ============================================================
CLK_NS = 20.0
pts = [('min', 516), ('P50', 772), ('P95', 1001), ('P99', 1021), ('max', 1027)]
us = [p[1] * CLK_NS / 1000.0 for p in pts]
fig, ax = plt.subplots(figsize=(7.0, 4.0))
cols = [ACADEMIC[0], ACADEMIC[0], ACADEMIC[1], ACADEMIC[1], ACADEMIC[3]]
bars = ax.bar([p[0] for p in pts], us, color=cols, width=0.55,
              edgecolor='#333333', linewidth=0.5, zorder=3)
for b, v, p in zip(bars, us, pts):
    ax.text(b.get_x() + b.get_width() / 2, v + 0.25,
            '%.2f us\n(%d clk)' % (v, p[1]), ha='center', va='bottom', fontsize=8.5)
ax.set_ylabel('note-on to first output sample (us)')
ax.set_title('Engine-internal latency distribution (measured)')
ax.set_ylim(0, 24.5)
ax.axhline(5.0, color=RED, lw=1.2, ls='--', zorder=2)
ax.text(4.4, 5.15, 'extension target 5 ms', fontsize=8, color=RED,
        va='bottom', ha='right')
src(ax, 'Source: evidence/latency_report.txt\n1 clk = 20 ns (50 MHz)', y=0.97)
save(fig, 'fig-latency.png')

# ============================================================
# 6. 完成情况（横向堆叠计数）
# ============================================================
CATS = [('Fully met', 5), ('Partially met', 3), ('Not done', 2)]
fig, ax = plt.subplots(figsize=(7.0, 2.6))
left = 0
cols = [GREEN, '#F39B7F', RED]
for (nm, v), c in zip(CATS, cols):
    ax.barh(['Requirements'], [v], left=left, color=c, height=0.45,
            edgecolor='white', linewidth=1.2, label=nm, zorder=3)
    if v:
        ax.text(left + v / 2, 0, str(v), ha='center', va='center',
                color='white', fontsize=10, fontweight='bold')
    left += v
ax.set_xlim(0, 10)
ax.set_xlabel('Number of requirements')
ax.set_title('Requirement completion (detail in section 3.1)')
ax.legend(ncol=3, loc='upper center', bbox_to_anchor=(0.5, -0.42), handlelength=1.2)
ax.grid(axis='y', visible=False)
src(ax, 'Source: section 3.1 of this document', y=0.99)
save(fig, 'fig-completion.png')

print()
print('  %d figures -> %s' % (len(made), OUT))
