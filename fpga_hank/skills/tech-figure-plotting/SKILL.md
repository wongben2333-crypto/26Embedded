---
name: tech-figure-plotting
description: >
  科研/技术图表的规划、绘制、修改与检查规范。用于为本项目技术文档出图：配色、
  字号、画幅、线型、标记、导出参数、图型选择、参考文档图型对照，以及本项目
  实测的绘图坑（中文字形缺失、图内文字限 ASCII、300 dpi、图上不要自绘假证据）。
  触发词：画图、配图、绘图、图表、figure、plot、精美、观感、可读性、配色、matplotlib。
license: MIT
metadata:
  version: "1.0"
  synthesized_from:
    - repo: stephenlzc/pythesis-plot (MIT)         角色: 学术出图规格（配色/字号/尺寸/线型/导出）
    - repo: yjz211/vivid-figures-skill (个人非商业)  角色: 三阶段流程（选择→适配→检查）+ 保真原则
    - repo: stephenlzc/... references/chart_types.md 角色: 图型选择
  project_measured:
    - 技术文档-冯若陈-国二.pdf（91 页 / 96 图 / 21 表）
    - 技术报告-钟超炀-国二.pdf（95 页）
    - 技术文档-张杰-国一.pdf（21 页）
---

# 科研/技术图表绘制 SKILL（综合上游 + 本项目实测）

> **上游抓取存档**：
> - `references/upstream-plotting.md`（pythesis `style_guide.md` + vivid `SKILL.md`）
> **本项目图件**：`references/example_figures.py (脚本) 与项目 _research/doc-figures/ (图件)`（脚本 + PNG）

---

## 〇、⭐ 三阶段流程（**顺序不能颠倒**）

> 来源：`vivid-figures-skill`

```
1 选择  → 按【数据 + 表达目的】选图型；先看候选实图再定
2 适配  → 以完整配方为起点，在实际脚本上改数据；⛔ 不为省代码简化视觉结构
3 检查  → 打开实际图件核对：保真度、数据口径、可读性
```
**⛔ 关键纪律（上游原文）**：
> **模板的渐变、透明度层次和关键图形元素应保留，不能为了省代码而随意改成纯色或只留轮廓。**
> **最终对照实图判断，不靠"脚本没报错"认定保真。**

**⇒ 套到本项目**：**图生成后必须 `read_image` 肉眼看过**，不能只看脚本退出码 ✗

---

## 一、⭐⭐ 图型选择（**按数据与目的，不按好看**）

| 数据/目的 | 图型 | 本项目用例 |
|---|---|---|
| 时间序列 / 趋势 | 折线图 | 包络衰减、延迟分布 |
| 分组比较 | 柱状图 | 资源占用、各档权重 |
| 分布 / 离群值 | 箱线图 | 延迟分位数 |
| 相关性 | 散点 + 回归 | 频率误差 |
| 多组同轴对比 | 折线族 / 分组柱 | 三段录音交叉验证 |
| 分类计数 | 堆叠柱 | 测试台通过/失败 |
| **系统结构** | **框图 / 数据通路图**（标注"示意图"）| 系统总体架构 |
| **实测取证** | ⭐ **软件截图 / 实物照片 / 频谱图** | Gowin 报告、ModelSim 波形、32 谱峰、真机照片 |

### ⭐ 参考文档实际的图型分布（**这是本项目该对齐的方向**）
| 图型 | 参考文档是否用 | 本项目现状 |
|---|---|---|
| **实物照片**（板卡/装置） | ✅ 用 | ✗ 缺（图 1.1 占位）|
| **软件截图**（IDE 报告界面） | ✅ 用 | ✗ 缺（图 3.6 占位）|
| **仿真波形截图** | ✅ 用 | ✗ 缺（图 3.7 占位）|
| **频谱 / 时频图** | ✅ 用 | ✗ 缺（图 3.8 占位）|
| **左右声道并排时频图** | ✅ 用（冯若陈 图81/85/86/89/94）| ✗ 缺 |
| 统计数据图（柱/折线） | 较少 | ✅ 我们画得多 |
| 结构框图 | ✅ 用 | ✅ 有 1 张 |

**⇒ 结论：参考文档的图以【实测取证图】为主，统计数据图为辅。本项目应补取证图。**

---

## 二、⭐⭐ 配色（**来源：pythesis `style_guide.md`**）

| 名称 | 色值 | 用途 |
|---|---|---|
| **学术蓝** | `#2E5AAC #5B9BD5 #A5D6F3 #1F4E79 #8FB8E6` | 正式论文 |
| **Nature** | `#E64B35 #4DBBD5 #00A087 #3C5488 #F39B7F` | 论文 |
| **Science** | `#003399 #CC0000 #009900 #FFCC00 #9900CC` | 论文 |
| **IEEE** | `#0066CC #CC0000 #009900 #FF9900 #9900CC` | 论文 |
| **鲜艳** | `#E41A1C #377EB8 #4DAF4A #984EA3 #FF7F00` | 演示、对比 |
| **柔和** | `#FBB4AE #B3CDE3 #CCEBC5 #DECBE4 #FED9A6` | 多组数据（>5）|
| **灰度** | `#000000 #404040 #707070 #A0A0A0 #D0D0D0` | 黑白打印 |
| **暖** | `#D73027 #F46D43 #FDAE61 #FEE090 #FFFFBF` | 对比强调 |
| **冷** | `#4575B4 #74ADD1 #ABD9E9 #E0F3F8 #FFFFBF` | 多组数据 |
| **发散** | `#D73027 #FC8D59 #FEE090 #91BFDB #4575B4` | 正负值/热力图 |
| **色盲友好 5 色** | `#1f77b4 #ff7f0e #2ca02c #d62728 #9467bd` | 通用 |

**⇒ 本项目默认用【学术蓝】或【Nature】**（正式技术文档）

---

## 三、⭐ 字体与字号（**来源：pythesis**）

### ⛔⛔ 本项目特有的大坑（**必须先处理**）
> **微软雅黑（Microsoft YaHei）缺很多字形** —— 实测缺 `⇒`(8658) `✅`(9984) `⚠️`(9888) `µ` `≥` `×` `→`(8594) 等
> **⇒ 图内文字一律只用 ASCII**（`->` `us` `>=` `x`），**否则渲染成方框** ✗

**中文字体优先级**（Windows）：`Microsoft YaHei` → `SimHei` → `SimSun`

| 元素 | 字号 | 说明 |
|---|---|---|
| 图表标题 | **12–14 pt** | 加粗 |
| 坐标轴标签 | **10–12 pt** | 含单位 |
| 刻度标签 | **9–10 pt** | |
| 图例 | **9–10 pt** | |
| 注释文字 | **8–9 pt** | |

```python
plt.rcParams['font.sans-serif'] = ['Microsoft YaHei', 'SimHei']
plt.rcParams['axes.unicode_minus'] = False
plt.rcParams['font.size'] = 11
plt.rcParams['axes.titlesize'] = 12
plt.rcParams['axes.labelsize'] = 11
plt.rcParams['xtick.labelsize'] = 9
plt.rcParams['ytick.labelsize'] = 9
plt.rcParams['legend.fontsize'] = 9
```

---

## 四、⭐ 画幅尺寸（**来源：pythesis**）

| 场景 | 宽 × 高（英寸）| 300 dpi 像素 |
|---|---|---|
| 单栏图 | **3.5 × 2.5–3.0** | 1050×750 |
| 1.5 栏图 | **5.0 × 3.5–4.0** | 1500×1050 |
| **双栏图** | **7.0 × 4.5–5.5** | 2100×1350 |
| 全页图 | 7.0 × 9.0 | 2100×2700 |

**⇒ 黄金比例 1.618:1**，或 4:3、16:9
**⇒ Word 正文插图**：写进文档后按 14–15 cm 宽居中（≈ 双栏图）

---

## 五、⭐ 线条与标记（**来源：pythesis**）

| 项 | 标准 | 强调 | 辅助 |
|---|---|---|---|
| 线宽 | **1.5** | 2.0 | 1.0 |
| 标记大小 | **6** | 8 | — |

**线型**：`-` 实线 ｜ `--` 虚线 ｜ `-.` 点划线 ｜ `:` 点线

### ⭐ 两个提升观感的细节（**我原来没做**）
```python
# ① 空心标记（facecolor 白 + edgecolor 配色）—— 比实心标记精致
ax.plot(x, y, marker='o', markersize=6,
        markerfacecolor='white', markeredgecolor='#2E5AAC', markeredgewidth=1.5)

# ② 标记间隔，避免过密
ax.plot(x, y, marker='o', markevery=10)
```

---

## 六、⭐ 导出（**来源：pythesis**）

```python
plt.savefig('fig.png', bbox_inches='tight', dpi=300,
            facecolor='white', edgecolor='none', pad_inches=0.02)
```

| 参数 | 建议值 |
|---|---|
| `bbox_inches` | **`'tight'`**（去多余白边）|
| `dpi` | **300**（标准）/ 600（期刊投稿）|
| `pad_inches` | **0.02** |
| `facecolor` | `'white'` |
| `transparent` | `False` |

**格式**：Word 用 **PNG** ｜ LaTeX 用 **PDF/EPS** ｜ 可编辑用 SVG ｜ 期刊投稿用 TIFF

---

## 七、⭐⭐ 项目专属：图上不要自绘假证据（**最高纪律**）

> 本项目实证教训：用户明确要求"**跑出来的图片不要自己生成，直接截屏…不要自己绘图，可能自己骗自己**"

| 图的性质 | 允许的做法 |
|---|---|
| **实测数据图** | ✅ 由**真实测量/仿真输出的数据**绘制（脚本可复跑）|
| **示意图**（框图/数据通路/状态机/时序原理） | ✅ 可画，但**必须在图题与图内注明"示意图"** |
| **实测取证图**（频谱、波形、软件报告、实物） | ⛔ **必须真实截图/拍照**，**不得用 matplotlib 重画** |

**⇒ 违反后果**：用绘图软件"重画"真实频谱/波形，会造成**证据与仿真不一致** ✗

### 图内脚注惯例（本项目）
```python
ax.text(0.02, 0.96, '数据源: <文件名>\n1 clk = 20 ns (50 MHz)',
        transform=ax.transAxes, fontsize=7.5, va='top', color='#555555')
```
- 示意图加 `schematic, not measured data`
- 实测图注明数据来源文件名

---

## 八、⭐⭐ 图表可读性检查清单（**12 条**）

```
1  字体清晰可读，中文无方框（图内文字限 ASCII）
2  坐标轴标签完整【含单位】（如「延迟 (us)」而非「延迟」）
3  图例位置合理，不遮挡数据
4  配色协调，符合文档风格（学术蓝/Nature）
5  分辨率 ≥ 300 dpi
6  无多余白边（bbox_inches='tight'）
7  线条粗细适中（1.5 pt 标准）
8  标记清晰可辨（空心 + markevery）
9  标题简洁明了，与图题（Markdown 侧的 `![图 N.M 说明]`）分工：标题讲"画了什么"，图题讲"看出了什么"
10 网格线不干扰数据（alpha 0.2–0.3，虚线）
11 每张图都被正文引用，并说明"从图里看出了什么"
12 ⛔ 实测图未经重画（示意图已注明"示意图"）
```

---

## 九、⭐ 本项目现有图件与改进点

| 图 | 文件 | 现状 | 可改进 |
|---|---|---|---|
| 系统框图 | `fig-system-block.png` | 彩色区块 + 箭头 | 线条统一 1.5pt；配色改学术蓝 |
| 二胡 5 档权重 | `fig-erhu-bandmul.png` | 分组柱状 | ⭐ **注释框压到柱子** ⇒ 移到图外；配色改学术蓝；空心标记 |
| 三段交叉验证 | `fig-erhu-crosscheck.png` | 折线族 | 空心标记 + markevery；配色改 Nature |
| 资源占用 | `fig-resources.png` | 横向柱状 | 加单位、数值标签对齐 |
| 时序迭代 | `fig-timing-iterations.png` | 柱状（正负双色）| 零线加粗；标注违例数 |
| 延迟分布 | `fig-latency.png` | 柱状 | 参考线（5 ms 要求）已加；配色统一 |

### ⭐ 应补的取证图（**参考文档类型**）
| 图 | 内容 | 取法 |
|---|---|---|
| 图 1.1 | 实物照片（板卡+耳机+GUI）| **拍照** |
| 图 3.6 | Gowin 报告界面 | **窗口截图**（能力已验证）|
| 图 3.7 | ModelSim 波形 | **窗口截图**（ModelSim 不能导出图片，只能截图）|
| 图 3.8 | **真板 32 谱峰频谱** | ⭐ **上板录音 + FFT**（赛题必备交付物）|
| 图 3.9 | 上位机界面 | **窗口截图** |

---

## 十、⭐ 可复用代码骨架（**照规范写**）

```python
# -*- coding: utf-8 -*-
"""<图名> -- data from <来源文件>."""
import os, sys
sys.stdout.reconfigure(encoding='utf-8')
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib import font_manager

# --- 中文字体（Windows 优先级）---
for c in [r'C:\Windows\Fonts\msyh.ttc', r'C:\Windows\Fonts\simhei.ttf']:
    if os.path.exists(c):
        font_manager.fontManager.addfont(c)
plt.rcParams['font.sans-serif'] = ['Microsoft YaHei', 'SimHei']
plt.rcParams['axes.unicode_minus'] = False

# --- 规范：字号 ---
plt.rcParams['font.size'] = 11
plt.rcParams['axes.titlesize'] = 12
plt.rcParams['axes.labelsize'] = 11
plt.rcParams['xtick.labelsize'] = 9
plt.rcParams['ytick.labelsize'] = 9
plt.rcParams['legend.fontsize'] = 9

# --- 规范：网格 ---
plt.rcParams['axes.grid'] = True
plt.rcParams['grid.alpha'] = 0.25
plt.rcParams['grid.linestyle'] = '--'
plt.rcParams['axes.axisbelow'] = True

# --- 规范：配色（学术蓝）---
ACADEMIC = ['#2E5AAC', '#5B9BD5', '#A5D6F3', '#1F4E79', '#8FB8E6']
NATURE   = ['#E64B35', '#4DBBD5', '#00A087', '#3C5488', '#F39B7F']

fig, ax = plt.subplots(figsize=(7.0, 4.5))       # 双栏图
# ... 绘图：线宽 1.5，空心标记，markevery ...
ax.set_xlabel('X 轴名 (单位)')
ax.set_ylabel('Y 轴名 (单位)')
ax.set_title('图标题（讲画了什么）')
ax.text(0.02, 0.96, '数据源: <文件>', transform=ax.transAxes,
        fontsize=7.5, va='top', color='#555555')       # 图内脚注

fig.tight_layout()
fig.savefig('fig-xxx.png', bbox_inches='tight', dpi=300,
            facecolor='white', edgecolor='none', pad_inches=0.02)
plt.close(fig)
print('  made fig-xxx.png  %d B' % os.path.getsize('fig-xxx.png'))
```

**⛔ 写完必须 `read_image` 肉眼验证**（不靠脚本退出码）
