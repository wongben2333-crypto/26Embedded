# docx-editor-cn —— 中文学术文档排版 Skill（**抓取自 GitHub，原文存档**）

> **来源**：<https://github.com/Gostyan/docx-skill-4-cn-paper>（MIT）
> **抓取路径**：`https://cdn.jsdelivr.net/gh/Gostyan/docx-skill-4-cn-paper@main/docx-editor-cn/SKILL.md`
> **抓取方式**：jsDelivr CDN（github.com 与 raw.githubusercontent.com 当时均不可达）
> **抓取日期**：2026-10-07
> ⚠️ **本文件是上游 skill 的原文摘录存档，不是本项目自创。** 用于排版规范参考。

---

## 定位

> 用于 AI Agent 按照规定格式编辑 Word 文档或将 Markdown 转换为 docx。
> 适用文档：中文课程论文；中文毕业设计论文；中文数学建模论文 ……

**依赖**：
```bash
npm install docx temml fast-xml-parser      # 必需（Node.js）
# 可选：Python 3.x、LibreOffice、Pandoc (≥2.0，LaTeX→OMML 需要)
```

---

## 一、⭐ 页面设置（**原文规格**）

```javascript
sections: [{
  properties: {
    page: {
      size: { width: 11906, height: 16838 },              // A4，单位 DXA
      margin: { top: 1418, right: 1418, bottom: 1418, left: 1418 }  // 2.5cm = 1418 DXA
    }
  }
}]
```

| 项 | 值 |
|---|---|
| 纸张 | **A4 = 11906 × 16838 DXA** |
| 页边距 | **上下左右各 2.5 cm = 1418 DXA** |
| **内容宽度** | **9070 DXA** |
| 单位换算 | **1440 DXA = 1 inch ｜ 567 DXA = 1 cm** |

---

## 二、⭐⭐ 字体与字号（**原文规格，与往届参考文档不同**）

| 元素 | 中文字体 | 英文/数字/公式字体 | 字号 |
|---|---|---|---|
| **正文** | **宋体 SimSun** | **Cambria Math**（Times New Roman 亦可）| **12pt（小四）→ `size: 24`** |
| **一级标题** | **黑体 SimHei** | Cambria Math | **16pt（三号）→ `size: 32`** |
| **二级标题** | 黑体 SimHei | Cambria Math | **14pt（四号）→ `size: 28`** |
| **三级标题** | 黑体 SimHei | Cambria Math | **12pt（小四）→ `size: 24`** |
| **图/表标题** | **宋体 SimSun** | Cambria Math | **11pt → `size: 22`** |

⚠️ **字号用"半点"单位**（`size: 24` = 12pt）。

### 段落
| 项 | 值 |
|---|---|
| **首行缩进** | **2 字符 = `firstLine: 480` DXA** |
| **行距** | **默认单倍**（`line: 240, lineRule: AUTO`）<br>备选：固定 20pt（`line: 400, EXACT`）或 1.5 倍（`line: 360, AUTO`）|
| **段前/段后** | **0 pt** |
| 一级标题行距 | 1.2 倍（`line: 288`）|
| 二级标题行距 | 1.5 倍（`line: 360`）|
| 三级标题行距 | 1.1 倍（`line: 264`）|
| 图题间距 | 前 0.5 行（`before: 120`）、后 3pt（`after: 60`）|

### ⚠️⭐ 字体必须用对象形式（**否则中文 fallback**）
```javascript
// ✅ 对：三个槽分开设
font: { ascii: 'Cambria Math', eastAsia: 'SimHei', hAnsi: 'Cambria Math' }

// ❌ 错：字符串只设 ASCII 槽，中文会掉回 Normal 字体
font: 'SimHei'
```

---

## 三、⭐⭐ 三线表（**中文论文强制**）

```
┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓  ← 顶线 1.5pt（size: 12）
┃   表头1    │    表头2      ┃
┠─────────────────────────────┨  ← 栏目线 0.75pt（size: 6）
┃   数据1    │    数据2      ┃
┃   数据3    │    数据4      ┃     （无竖线、无其他横线）
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛  ← 底线 1.5pt（size: 12）
```

```javascript
const THICK = { style: BorderStyle.SINGLE, size: 12, color: '000000' };  // 1.5pt
const THIN  = { style: BorderStyle.SINGLE, size: 6,  color: '000000' };  // 0.75pt
const NONE  = { style: BorderStyle.NONE,   size: 0,  color: 'FFFFFF' };

// 表头行
cellOf(h, colWidths[i], { top: THICK, bottom: THIN, left: NONE, right: NONE }, true)
// 数据行：除最后一行底线外全 NONE
cellOf(cell, colWidths[i], { top: NONE, bottom: isLastRow ? THICK : NONE, left: NONE, right: NONE })
```

**关键规则**：
- **内容宽 = 9070 DXA**；`columnWidths` **必须精确加总为 9070**
- **必须用 `WidthType.DXA`**，⛔ 不要 `WidthType.PERCENTAGE`（Google Docs 会坏）
- **表格宽 = columnWidths 之和**；每个 cell 的 `width` 也要匹配
- **表题在表【上】**，且**取消首行缩进**（`indent: { firstLine: 0 }`）
- 表头单元格**不要填色**
- 加 cell 内边距：`margins: { top: 80, bottom: 80, left: 120, right: 120 }`
- 表格底纹用 `ShadingType.CLEAR`，⛔ 不要 SOLID

---

## 四、⭐⭐ 公式排版（**3 列无边框表格法**）

### 布局（A4，内容宽 9070 DXA）
```
┌──────────┬──────────────────────────┬──────────┐
│ 1cm 留白 │   公式（居中）            │   (n)    │
│ 567 DXA  │        7936 DXA          │ 567 DXA  │
└──────────┴──────────────────────────┴──────────┘
   全表无边框；单倍行距
```

### ⚠️ 两个必踩的坑
1. **必须把 `insideHorizontal` 与 `insideVertical` 也设为 NONE** —— 只设四条外边不够，表格内部线仍会显示 ✗
2. **三个单元格都要加 `verticalAlign: VerticalAlign.CENTER`** —— 否则公式与编号不在同一基线上 ✗

```javascript
const noBorders = {
  top: NONE, bottom: NONE, left: NONE, right: NONE,
  insideHorizontal: NONE,   // CRITICAL
  insideVertical: NONE,     // CRITICAL
};
// 每个 TableCell 都加：verticalAlign: VerticalAlign.CENTER
```

### ⭐⭐ LaTeX → Word **原生公式**（本项目最需要的能力）
```
LaTeX 字符串 ──temml──► MathML ──mathml-to-docx──► Word OMML 公式
```
```javascript
const temml = require('temml');
const { mathmlToDocxChildren } = require('./mathml-to-docx');

function latexToMath(latex) {
  const mathml = temml.renderToString(latex, { displayMode: true, throwOnError: false });
  const children = mathmlToDocxChildren(mathml);
  if (children && children.length) return new Math({ children });
  return new Math({ children: [new MathRun(latex)] });   // 兜底
}
```

**MathML → OMML 映射**：`mfrac`→MathFraction ｜ `msub`→MathSubScript ｜ `msup`→MathSuperScript ｜ `msubsup`→MathSubSuperScript ｜ `msqrt`/`mroot`→MathRadical ｜ `munderover`+∑→MathSum ｜ +∫→MathIntegral ｜ `mtable`→MathMatrix

> ⚠️ **原文明确**：`never use plain $$ LaTeX in the final docx`

### 行内公式
按**斜体纯文本**书写；行内公式检测用**严格正则**（见 Issue 7）

---

## 五、⭐⭐ 标题与题注的自动编号

### 标题
| 层级 | 编号方式 |
|---|---|
| **一级** | **中文数字写在文本里**（`一、引言`、`二、方法`）—— 用 `h1Chinese()` |
| **二级** | **Word 自动编号**，`章节.序`（1.1、2.4）—— 用 per-chapter `sections_c{N}` 引用 |
| **三级** | **Word 自动编号**，`章节.节.序`（1.1.1）|

```javascript
let _chapter = 0;
function h1Chinese(text) { _chapter++; return new Paragraph({ heading: HEADING_1, indent:{firstLine:0}, children:[new TextRun(text)] }); }
function h2(text) { return new Paragraph({ heading: HEADING_2, numbering:{ reference:`sections_c${_chapter}`, level:0 }, indent:{firstLine:0}, children:[new TextRun(text)] }); }
function h3(text) { return new Paragraph({ heading: HEADING_3, numbering:{ reference:`sections_c${_chapter}`, level:1 }, indent:{firstLine:0}, children:[new TextRun(text)] }); }
```

### ⛔⭐ 关键警告
> **NEVER use `LevelFormat.CHINESE_COUNTING` for H1 in a multi-level config** —— `%1` 在 H2 文本里会展开成"二"，导致 **`二.4`** 而不是 `2.4`。
> **每一级都用 `LevelFormat.DECIMAL`。**

### 题注（**用 Word SEQ 域**）
```javascript
figCaption('系统架构图')     // → "图 1-1  系统架构图"（SEQ figure_c1）
tableCaption('符号说明')     // → "表 1-1  符号说明"（SEQ table_c1）
```
**⇒ 只传描述文字，⛔ 不要手写 "图 3-1 " 前缀**，SEQ 域会自动编号。
**⇒ 从 Markdown 转换时用 `stripCaptionNumber()` 清掉手写编号。**

---

## 六、其它规格

### 目录
```javascript
new TableOfContents("目录", { hyperlink: true, headingStyleRange: "1-3" })
// 标题段落必须带 heading: HeadingLevel.HEADING_X（应用覆盖样式，含 outlineLevel）
```
**⇒ 覆盖内建样式，样式 ID 必须精确用 `"Heading1"` / `"Heading2"` 等**
**⇒ 必须含 `outlineLevel`**（H1=0、H2=1…）

### 页脚
```javascript
// 「第 X 页 共 Y 页」
children: [ new TextRun("第 "),
            new TextRun({ children: [PageNumber.CURRENT] }),
            new TextRun(" 页  共 "),
            new TextRun({ children: [PageNumber.TOTAL_PAGES] }),
            new TextRun(" 页") ]
```

### 参考文献（GB/T 7714-2015）
样式：`indent: { left: 480, hanging: 480 }`
| 类型 | 标 | 格式 |
|---|---|---|
| 期刊 | [J] | 作者. 题名[J]. 刊名, 年, 卷(期): 起止页. |
| 专著 | [M] | 作者. 书名[M]. 出版地: 出版者, 出版年: 起止页. |
| 学位论文 | [D] | 作者. 题名[D]. 保存地: 保存单位, 年份. |
| 会议 | [C] | 作者. 题名[C]//会议名. 出版地: 出版者, 年: 起止页. |
| 网络 | [EB/OL] | 作者. 题名[EB/OL]. (发布日期)[引用日期]. URL. |

**引用上标**：检测 `[\d+]` ⇒ `superScript: true`

### 列表（⛔ 绝不用 Unicode 圆点）
```javascript
// ❌ 错：手工插 • 字符
new Paragraph({ children: [new TextRun("• Item")] })
// ✅ 对：用 numbering config + LevelFormat.BULLET
```

### 图片
```javascript
new ImageRun({
  type: "png",                     // 必填
  data: fs.readFileSync("image.png"),
  transformation: { width: 200, height: 150 },
  altText: { title: "T", description: "D", name: "N" }   // 三个都必填
})
```

### 分页
```javascript
new Paragraph({ children: [new PageBreak()] })      // PageBreak 必须在 Paragraph 里
new Paragraph({ pageBreakBefore: true, children: [...] })
```

---

## 七、⭐ 它在生产中解决的 11 个问题（**原文清单**）

| # | 问题 | 解决 |
|---|---|---|
| **1** | 三线表中间横线可见 | 数据行 borders 全设 `NONE` |
| **2** | 公式表格边框可见 | **`insideH`/`insideV` 也设 `NONE`** |
| **3** | 标题编号不同步 | 改用 Word 原生自动编号 + per-chapter 引用 |
| **4** | 标题里英文仍是宋体 | 混合字体 `{ascii, eastAsia, hAnsi}` |
| **5** | 行间公式没用公式编辑器 | `temml` → `mathmlToDocxChildren` |
| **6** | 主标题英文宋体 | 标题字体混合配置 |
| **7** | 行内公式匹配过激 | 严格正则**排除纯数字与单词** |
| **8** | 引用未上标 | 检测 `[n]` 设 `superScript` |
| **10** | 缺分页符 | `pageBreak()` 函数 |
| **11** | 公式表格单元格未垂直居中 | 三个 cell 都加 `verticalAlign: CENTER` |

### Issue 7 的严格正则（**行内公式只匹配真数学内容**）
```javascript
function containsMath(text) {
  if (/[αβγδεζηθικλμνξπρστυφχψωΓΔΘΛΞΠΣΦΨΩ]/.test(text)) return true;      // 希腊字母
  if (/[₀₁₂₃₄₅₆₇₈₉ₙₓᵢₜₛ⁰¹²³⁴⁵⁶⁷⁸⁹ⁿⁱ]/.test(text)) return true;            // 上下标
  if (/[∞∑∏∫≤≥≠≈→←↔∈∉⊂⊃∀∃∧∨×÷±∓·…⋯′″⟨⟩]/.test(text)) return true;        // 运算符
  if (/[A-Z]\*/.test(text)) return true;                                    // 星号变量
  if (/\$[^$]+\$/.test(text)) return true;                                  // 显式 LaTeX
  return false;
}
// 不匹配：纯数字 1992、英文词 Agent/Watkins、普通括号 (optional)
```

---

## 八、⛔ docx-js 关键规则（**原文**）

- **显式设页面尺寸** —— 中文用 A4 + 2.5cm 边距
- **横向：传纵向尺寸** —— docx-js 内部会交换 width/height
- **⛔ 绝不用 `\n`** —— 用独立 Paragraph
- **⛔ 绝不用 Unicode 圆点** —— 用 `LevelFormat.BULLET`
- **PageBreak 必须在 Paragraph 里**
- **ImageRun 必须带 `type`**
- **标题编号：H1 中文数字写文本，H2/H3 用 per-chapter 自动编号；⛔ 多级配置里绝不用 `CHINESE_COUNTING`**
- **题注不要手写编号** —— SEQ 域自动生成
- **表格必须三线表** —— 顶/底 1.5pt、表头下 0.75pt、其余 NONE、表头不填色
- **表题无首行缩进**
- **行间公式用 3 列表格** —— 绝不在最终 docx 里留 `$$` LaTeX
- **表格宽用 DXA**，⛔ 不用百分比；**columnWidths 与 cell width 都要设且一致**；**必须精确加总**
- **加 cell 内边距**；底纹用 `ShadingType.CLEAR`
- **TOC 用 `heading: HeadingLevel.HEADING_X`**（同时获得目录识别与自定义格式）
- **覆盖内建样式，ID 精确**；**字体用 `{ascii, eastAsia, hAnsi}` 对象形式**
- **必须含 `outlineLevel`**（TOC 需要）

---

## 九、辅助函数（`scripts/new_doc.js`）

```javascript
h1Manual('一、引言')      // 中文数字编号
h1Chinese('一、引言')     // 同上（推荐）
h1('研究背景')            // → 1 研究背景
h2('问题定义')            // → 1.1 问题定义
h3('数学模型')            // → 1.1.1 数学模型
body('Q-learning 由 Watkins 提出[1]')   // [1] 自动转上标
formula('E = mc^2', 1)    // 居中公式 + 编号 (1)
tableCaption('表 1-1 符号说明')
threeLineTable(['符号','说明'], [['α','学习率'],['γ','折扣因子']], [1800, 7270])
figCaption('图 1-1 系统架构')
ref('Watkins C J C H. Q-learning[J]. Machine Learning, 1992.')
blank() / pageBreak()
stripH1Number('一、引言')          // → 引言
stripH2Number('1.1 研究背景')     // → 研究背景
stripCaptionNumber('图 3-1 系统') // → 系统
```

---

## 十、与本项目现有流水线的**差距对照**（供改进参考）

| 项 | 上游 skill | **本项目现状** | 差距 |
|---|---|---|---|
| **公式** | ⭐ **LaTeX → Word 原生 OMML**（temml + MathML）| 降级成 **Unicode 纯文本** | ✗ **它是真公式，我的是文本** |
| **公式布局** | 3 列无边框表格 | 双制表位 | 两者皆可，它的更稳 |
| **表格** | ⭐ **三线表**（顶/底 1.5pt + 表头线 0.75pt）| `Table Grid` 全网格 | ✗ 学术论文用三线表 |
| **一级标题** | **16pt** | 14pt | 字号体系不同 |
| **二/三级** | 14pt / 12pt | 12pt / 12pt | 同上 |
| **图表题** | **11pt 宋体** | 10.5pt 黑体 | 字号与字体都不同 |
| **行距** | 默认**单倍** | 1.5 倍 | 可配置 |
| **西文/公式字体** | **Cambria Math** | Times New Roman | 它另有考虑 |
| **图表编号** | ⭐ Word **SEQ 域**自动 | 手写编号 | ✗ 手写的改了内容就错 |
| **标题编号** | ⭐ Word 自动编号 | 手写 | 同上 |
| **引用上标** | ✅ 自动 | 未实现 | |
| **技术栈** | **Node.js**（docx-js）| **Python**（python-docx）| 不同栈 |

**⇒ 结论：上游 skill 在【公式为原生 OMML】【三线表】【SEQ 域自动编号】三处明显优于本项目现有流水线。**

---

## 十一、可参考的同类仓库（**尚未抓取**）

| 仓库 | 说明 | 抓取 URL（jsDelivr） |
|---|---|---|
| [**oceangis/skill_academic-writing-skills**](https://github.com/oceangis/skill_academic-writing-skills) | 学术论文**后期排版精修、格式校验与深度润色** | `https://cdn.jsdelivr.net/gh/oceangis/skill_academic-writing-skills@main/README.md` |
| [kgraph57/paper-writer-skill](https://github.com/kgraph57/paper-writer-skill) | IMRAD 工作流、文献矩阵、图表 | `https://cdn.jsdelivr.net/gh/kgraph57/paper-writer-skill@main/README.md` |
| [Fishman-free/PAPER-SKILL](https://github.com/Fishman-free/PAPER-SKILL) | 论文 skill | `https://cdn.jsdelivr.net/gh/Fishman-free/PAPER-SKILL@main/README.md` |
| [BZDmathclub/bzd-math-modeling-skills](https://github.com/BZDmathclub/bzd-math-modeling-skills) | 数学建模竞赛 | `https://cdn.jsdelivr.net/gh/BZDmathclub/bzd-math-modeling-skills@main/README.md` |

> ⭐ **jsDelivr 是可行通道**：`https://cdn.jsdelivr.net/gh/<user>/<repo>@<branch>/<path>`
> （github.com 与 raw.githubusercontent.com 在某些时段不可达时，用它可通）
