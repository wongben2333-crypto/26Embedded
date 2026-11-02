# 抓取存档：科技绘图 skill（上游原文摘录）

> **抓取日期**：2026-10-07
> **抓取通道**：⭐ jsDelivr CDN（`https://cdn.jsdelivr.net/gh/<user>/<repo>@<branch>/<path>`）
> **背景**：当日 `github.com:443` 与 `raw.githubusercontent.com` 均不可达；`web_fetch` 走 jsDelivr 可通，
> 但 `Invoke-WebRequest` 走 jsDelivr 报 TLS 握手失败；`.mplstyle`（无 MIME）因 content-type 为
> `application/octet-stream` 无法抓取。
> ⚠️ **本文件是上游内容摘录，非本项目自创。**

---

## 一、抓到的仓库

| 仓库 | 许可 | 抓到 | 用途 |
|---|---|---|---|
| ⭐ [**stephenlzc/pythesis-plot**](https://github.com/stephenlzc/pythesis-plot) | **MIT** | `README.md` + **`references/style_guide.md` 全文** | ⭐ **学术出图规格**（配色/字号/尺寸/线型/标记/导出）|
| [**yjz211/vivid-figures-skill**](https://github.com/yjz211/vivid-figures-skill) | **个人非商业**（用户确认仅个人使用、不发布）| `README.md` + `SKILL.md` | ⭐ **三阶段流程（选择→适配→检查）+ 保真原则** |

**未抓到（记录备用）**：
```
pythesis-plot/assets/themes/academic.mplstyle    → content-type application/octet-stream
pythesis-plot/assets/themes/nature.mplstyle      → 同上
pythesis-plot/assets/themes/presentation.mplstyle→ 同上
pythesis-plot/references/chart_types.md          → 未抓（可补）
vivid-figures/original/resources/assets/shared-scripts/palettes.json → fetch failed
```
**⇒ 用户决定：`.mplstyle` 由本项目按 `style_guide.md` 的规格自写，内容与上游一致（个人使用）。**

---

## 二、⭐ `pythesis-plot` 的 `style_guide.md`（原文核心）

### 定位（README 原文）
> **Scientific Plotting Skill for Claude Code** — Transform raw data into publication-ready figures with **Nature/Science quality standards**.
> 300 DPI、Journal-Ready Output、多领域支持、时间戳目录 + 可复现代码。
> **工作流**：Data → Analysis → Recommendations → **Confirmation（必需）** → Figures

### 配色方案（原文色值）

| 名称 | 色值 | 适用 |
|---|---|---|
| 学术蓝 Academic | `#2E5AAC #5B9BD5 #A5D6F3 #1F4E79 #8FB8E6` | 正式论文 |
| 鲜艳 Vibrant | `#E41A1C #377EB8 #4DAF4A #984EA3 #FF7F00` | 演示、对比强调 |
| 柔和 Pastel | `#FBB4AE #B3CDE3 #CCEBC5 #DECBE4 #FED9A6` | 多组数据（>5）|
| **Nature** | `#E64B35 #4DBBD5 #00A087 #3C5488 #F39B7F` | 论文 |
| **Science** | `#003399 #CC0000 #009900 #FFCC00 #9900CC` | 论文 |
| **IEEE** | `#0066CC #CC0000 #009900 #FF9900 #9900CC` | 论文 |
| 灰度 Grayscale | `#000000 #404040 #707070 #A0A0A0 #D0D0D0` | 黑白打印 |
| 暖 Warm | `#D73027 #F46D43 #FDAE61 #FEE090 #FFFFBF` | 对比强调 |
| 冷 Cool | `#4575B4 #74ADD1 #ABD9E9 #E0F3F8 #FFFFBF` | 多组数据 |
| 发散 Diverging | `#D73027 #FC8D59 #FEE090 #91BFDB #4575B4` | 正负值对比/热力图 |
| 色盲友好 3/4/5 色 | `#1f77b4 #ff7f0e #2ca02c [#d62728 #9467bd]` | ColorBrewer |

**配色使用建议（原文）**：正式论文→academic/grayscale｜演示→vibrant/nature｜黑白打印→grayscale｜多组（>5）→pastel/cool｜对比强调→vibrant/warm｜相关性热力图→diverging

### 字体规范（原文）
- **中文字体**：Windows `SimHei`（首选）/ `Microsoft YaHei`；macOS `Heiti TC`/`PingFang TC`；Linux `WenQuanYi Micro Hei`/`Noto Sans CJK SC`
- **字号**：图表标题 **12–14 pt 加粗** ｜ 坐标轴标签 **10–12** ｜ 刻度 **9–10** ｜ 图例 **9–10** ｜ 注释 **8–9**

```python
plt.rcParams['font.sans-serif'] = ['SimHei', 'DejaVu Sans']
plt.rcParams['axes.unicode_minus'] = False
plt.rcParams['font.size'] = 11
plt.rcParams['axes.titlesize'] = 12
plt.rcParams['axes.labelsize'] = 11
plt.rcParams['xtick.labelsize'] = 9
plt.rcParams['ytick.labelsize'] = 9
plt.rcParams['legend.fontsize'] = 9
```

### 图表尺寸（原文）
| 场景 | 宽 × 高（英寸）| 300 dpi 像素 |
|---|---|---|
| 单栏 | 3.5 × 2.5–3.0 | 1050×750 |
| 1.5 栏 | 5.0 × 3.5–4.0 | 1500×1050 |
| 双栏 | 7.0 × 4.5–5.5 | 2100×1350 |
| 全页 | 7.0 × 9.0 | 2100×2700 |

**黄金比例 1.618:1**，或 4:3、16:9

### 线条与标记（原文）
```
linewidth : 1.5 标准 / 2.0 强调 / 1.0 辅助
linestyle : - 实线 / -- 虚线 / -. 点划线 / : 点线
markersize: 6 标准 / 8 强调
标记选择  : o 一般 / s 分类 / ^ 峰值 / D 关键 / * 特殊 / + 误差
markevery : 每 n 点显示一个标记（避免过密）
```
**⭐ 空心标记写法（原文）**：
```python
ax.plot(x, y, marker='o', markersize=6,
        markerfacecolor='white', markeredgecolor='#2E5AAC', markeredgewidth=1.5)
```

### 导出（原文）
| 格式 | 场景 |
|---|---|
| PDF | LaTeX 论文（矢量）|
| EPS | LaTeX（兼容性好）|
| **PNG** | **Word/PPT（位图，透明背景）** |
| SVG | 网页编辑 |
| TIFF | 期刊投稿（600 dpi）|

```python
plt.savefig('figure.png', bbox_inches='tight', dpi=300,
            facecolor='white', edgecolor='none')
```
| 参数 | 建议 |
|---|---|
| `bbox_inches` | `'tight'` |
| `dpi` | 300 标准 / 600 高质量 |
| `pad_inches` | `0.02` |
| `facecolor` | `'white'` |
| `transparent` | `False` |

### ⭐ 样式检查清单（原文 10 条）
```
□ 字体清晰可读，中文正常显示      □ 坐标轴标签完整（含单位）
□ 图例位置合理，不遮挡数据        □ 配色协调，符合论文风格
□ 分辨率足够（≥300dpi）           □ 无多余白边
□ 线条粗细适中                    □ 标记清晰可辨
□ 标题简洁明了                    □ 网格线不干扰数据阅读
```

### 支持的图型（README）
折线图（时间序列）｜柱状图（分组比较）｜箱线图（分布/离群）｜散点+回归（相关）｜热力图（相关矩阵）｜**Dashboard（多面板）**

---

## 三、⭐ `vivid-figures-skill`（用户确认仅个人使用）

### 定位（README 原文）
> 把数据交给 AI，让它帮你选图、画图、检查，再交付**图片和绘图源码**。
> 适合论文、数学建模和实验报告。内含 **143 个图表配方与 3 套完整组合模板**，
> **七套配色**和自定义颜色，可生成 PNG、PDF 及可继续修改的绘图代码。

**允许**：个人使用｜**禁止**：商业使用、二次开发后发布（用户已确认仅个人使用、不发布）

### ⭐⭐ `SKILL.md`：三阶段流程（原文）

**1. 选择**
> 尚未指定模板时读取「数据与模板选择」与「设计目标」，**按数据与目的检索卡片、查看候选实图**。
> 用户指定模板、修图或换色时沿用选择，直接进入适配。

**2. 适配**
> 读取「源码底稿与保真」，用工具将选定的完整源码写成工作脚本，**在这个实际文件上修改**。
> 读取所选卡片及预览、执行环境、数据图执行、配色和尺寸预计算。

**3. 检查**
> 用来源底稿比较当前源码，再按「检查与修复」**打开实际图件**，核对模板特点、数据口径与可读性。
> **差异提示不是视觉通过结论**，必要适配不必为消除提示改回演示数据。

### ⭐ 保真原则（README 原文，**最重要**）
> **Skill 明确要求先读取完整配方，以配方代码为起点适配数据。**
> **模板的渐变、透明度层次和关键图形元素应保留，不能为了省代码而随意改成纯色或只留轮廓。**
> 修图优先调整**位置、间距和尺寸**。
> **最终对照实图判断，不靠"脚本没报错"认定保真。**

### ⭐ 数据真实性约束（README 原文，**与本项目纪律一致**）
> **数据不支持某种元素时，AI 应说明调整原因。**
> **例如，没有重复试验或区间数据，就不能凭空补一条置信带。**

### 七套配色（名称）
珊瑚青绿·7色 ｜ 橄榄杏棕·7色（默认）｜ 蓝粉浅彩·5色 ｜ 蓝天绿地·8色 ｜ 柔绿森林·8色 ｜ 粉彩少女·8色 ｜ 海洋清风·8色

### 其他能力
Draw.io/TikZ ｜ HTML/Mermaid ｜ 科学场景插图 ｜ 3D 曲面/轨迹/地图/工程图 ｜ 流程图/技术路线图

---

## 四、本项目已落地的综合成果

**⇒ 综合成 skill**：`.dsh/skills/tech-figure-plotting/SKILL.md`
**⇒ 本项目实测补充**：
| 补充点 | 内容 |
|---|---|
| ⛔ **中文字形坑** | 微软雅黑缺 `⇒ ✅ ⚠️ µ ≥ × →` 等 ⇒ **图内文字限 ASCII** |
| ⛔ **不得自绘假证据** | 实测取证图必须真实截图/拍照；示意图必须注明"示意图" |
| ✅ **生成后必须 `read_image` 肉眼验证** | 不靠脚本退出码（上游"不靠脚本没报错认定保真"的同义）|
| ✅ **图题与图内标题分工** | 图题（`![图 N.M 说明]`）讲"看出了什么"；图内标题讲"画了什么" |
| ✅ **图内脚注标注数据源** | `数据源: <文件名>` |
| ✅ **参考文档图型对照** | 参考文档以**取证图为主**（照片/截图/频谱/波形），统计数据图为辅 |
