---
name: docx-editor-cn
description: >
  中文学术文档（课程论文、毕业设计、数学建模论文、技术报告）的 Word 排版规范与
  Markdown→docx 转换方法。本目录托管上游开源 skill 的原文存档，并附本项目实测
  规格与上游的差异对照。当需要排版中文 Word 文档、处理三线表、公式居中编号、
  图表 SEQ 自动编号、GB/T 7714 参考文献、页面与字体规格时使用。
license: MIT
metadata:
  role: upstream-archive
  upstream: https://github.com/Gostyan/docx-skill-4-cn-paper
  upstream_path: docx-editor-cn/SKILL.md
  fetched_via: https://cdn.jsdelivr.net/gh/Gostyan/docx-skill-4-cn-paper@main/docx-editor-cn/SKILL.md
  fetched_date: "2026-10-07"
  fetch_note: >
    github.com 与 raw.githubusercontent.com 当日不可达；经 jsDelivr CDN 成功抓取。
    PowerShell 直连 jsDelivr 亦失败（TLS 握手），内容由 web_fetch 获取后落盘。
---

# docx-editor-cn（上游 skill 原文存档）

## 本目录放什么

| 文件 | 内容 | 性质 |
|---|---|---|
| **`REFERENCE.md`** | ⭐ **上游 skill 的原文摘录存档**（页面/字体/三线表/公式/自动编号/11 个已解决问题/关键规则）| **抓取，非自创** |
| **`PROJECT-DIFF.md`** | 本项目实测规格（三份往届获奖作品）与上游规格的**差异对照** | 本项目笔记 |

## 怎么用

1. **要排版规范** ⇒ 读 `REFERENCE.md`
2. **要知道本项目该用哪套数值** ⇒ 读 `PROJECT-DIFF.md`
3. **要让本项目的 Word 流水线升级**（原生公式 / 三线表 / SEQ 域自动编号）⇒ 读 `REFERENCE.md` 的第四、五节

## ⚠️ 上游与本项目的技术栈不同

| | 上游 | 本项目 |
|---|---|---|
| 语言 | **Node.js**（`docx` / `temml` / `fast-xml-parser`）| **Python**（`python-docx`）|
| 公式 | **LaTeX → temml → MathML → Word 原生 OMML** | Unicode 纯文本 |
| 表格 | **三线表**（BorderStyle 逐边设置）| `Table Grid` |
| 编号 | **Word SEQ 域 / 自动编号** | 手写 |

**⇒ 上游在「原生公式」「三线表」「自动编号」三处明显更强；迁移需要引入 Node.js 依赖。**

## 上游许可

MIT（`LICENSE.txt` 见上游仓库）。`REFERENCE.md` 为其文档内容摘录，版权归上游作者。
