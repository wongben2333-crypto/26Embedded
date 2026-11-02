# 本项目 skill 索引

> **用途**：上下文不够时，照下表找到该读哪个 skill，直接 `read` 它的 `SKILL.md`。
> ⚠️ 本机 `dsh-skill-filesystem` 曾报 `inactive` ⇒ **skill 不一定自动加载，直接读文件即可。**
> 路径均为相对本仓库根：`.dsh/skills/<name>/SKILL.md`

---

## 一、写作与排版类（**本轮新建**）

| Skill | 何时用 | 入口 | 自包含 |
|---|---|---|---|
| ⭐ **`zh-academic-writing`** | **写/改中文技术文档、去 AI 味、段落逻辑、标题导语** | [SKILL.md](zh-academic-writing/SKILL.md) | ✅ 5 文件 / 70 KB |
| ⭐ **`docx-editor-cn`** | **Markdown → Word 排版**：三线表、原生公式、SEQ 域编号、字号体系 | [SKILL.md](docx-editor-cn/SKILL.md) | ✅ 3 文件 / 25 KB |
| ⭐ **`tech-figure-plotting`** | **画图**：配色/字号/画幅/线型/标记/导出/图型选择 | [SKILL.md](tech-figure-plotting/SKILL.md) | ✅ 3 文件 / 31 KB |
| `tech-doc-writing` | （**v1，已被 `zh-academic-writing` 取代**）早期综合版 | [SKILL.md](tech-doc-writing/SKILL.md) | ✅ 4 文件 / 193 KB |

## 二、FPGA 工程类（**此前已有**）

| Skill | 何时用 |
|---|---|
| `gowin-flow` | 高云 EDA 命令行全链路构建（综合→布局布线→位流→烧录）、Tcl 脚本、时序排查 |
| `fpga-verify` | 验证与取证门禁：32 谱峰频谱、真实采样率推导、延迟分位数、赛线红线自审、lint/形式验证 |
| `verilog-review` | Verilog/SystemVerilog RTL 审查清单（Gowin 综合器定制）|

---

## 三、各写作 skill 的分工与内部结构

### `zh-academic-writing`（**主用**）
```
SKILL.md                                  12 节：六层漏斗 / 三条边界 / DEAI 五类痕迹 /
                                          AXES 段落模型 / 行文 F / 用词 W / 标点 PN /
                                          保护清单 / 交付协议 / 本项目体裁基准 / 排版 / 工具纪律
references/
  upstream-tuiqiao.md                     「推敲」skill 规则（去 AI 味、W/PN/F/T、保护清单 P1-P17）
  upstream-academic-writing.md            学术写作 skill + DEAI_GUIDE 原文摘录
  upstream-docx-editor-cn.md              中文学术 Word 排版原文
  synthesis-v1.md                         第一版综合（MY-WRITING-SKILL）
```

### `docx-editor-cn`（**Word 排版规格，抓取存档**）
```
SKILL.md            入口（frontmatter 标注上游仓库/路径/抓取方式/日期）
REFERENCE.md        ⭐ 上游原文：页面/字体/三线表/公式 3 列表格/SEQ 域自动编号/
                    11 个已解决问题/docx-js 关键规则/辅助函数
PROJECT-DIFF.md     本项目实测规格 vs 上游规格的差异对照 + 上游更强的三处 + 本项目独有纪律
```
**⇒ 其中「本项目更强的三处」指上游在【原生公式 OMML】【三线表】【SEQ 域自动编号】更强，本项目待升级。**

### `tech-figure-plotting`（**绘图规范**）
```
SKILL.md                     10 节：三阶段流程（选择→适配→检查）/ 图型选择 / 配色 /
                             字体字号 / 画幅 / 线条标记 / 导出 / ⛔ 不得自绘假证据 /
                             可读性 12 条 / 现有图件改进点 / 代码骨架
references/
  upstream-plotting.md        pythesis style_guide.md 全文 + vivid-figures SKILL.md 三阶段流程
  example_figures.py          ⭐ 已按规范重画的 6 张图脚本（可直接改数据复用）
```

---

## 四、抓取来源与许可

| Skill | 上游 | 许可 |
|---|---|---|
| `zh-academic-writing` | `TingYu1769/skills-tuiqiao` ｜ `oceangis/skill_academic-writing-skills` ｜ `Gostyan/docx-skill-4-cn-paper` ｜ `YuanZHAO321/eloquent-science-zh` | MIT / Academic-Use-Only（个人使用）|
| `docx-editor-cn` | `Gostyan/docx-skill-4-cn-paper` | MIT |
| `tech-figure-plotting` | `stephenlzc/pythesis-plot` ｜ `yjz211/vivid-figures-skill` | MIT ｜ 个人非商业（用户已确认仅个人使用、不发布）|

**⇒ 抓取通道（重要）**：
```
github.com 与 raw.githubusercontent.com 曾不可达；
⭐ jsDelivr 可通：https://cdn.jsdelivr.net/gh/<user>/<repo>@<branch>/<path>
⚠️ 但 PowerShell Invoke-WebRequest 走 jsDelivr 报 TLS 握手失败 ⇒ 只能用 web_fetch
⚠️ .mplstyle / .json 等非文本 MIME（application/octet-stream）抓不到
```

---

## 五、原始存档位置（项目内，非 skill 目录）

```
_research/doc-format/
  FORMAT-SPEC.md                      58,108 B   三份往届参考的排版实测规格（623 行）
  FORMAT-SPEC-LEAD.md                  5,114 B   Lead 实测版
  REFERENCE-STYLE-ANALYSIS.md          6,385 B   三份参考的文风与格式分析
  SECTION-STYLE-COMPARISON.md         12,997 B   逐节写作思路与用词对比
  TUIQIAO-RULES.md                    10,556 B   「推敲」规则提炼
  MY-WRITING-SKILL.md                 16,523 B   第一版综合
  FETCH-academic-writing-skills.md    12,988 B   学术写作 skill + DEAI_GUIDE 原文摘录
  FETCH-plotting-skills.md             9,035 B   绘图 skill 原文摘录
  SKILL-docx-editor-cn.md             16,320 B   与 docx-editor-cn/REFERENCE.md 同一份
  WRITING-SKILLS-CATALOG.md            4,978 B   检索到的仓库清单（含待抓 URL）
  _ref_技术文档-张杰-国一.txt           30,418 B   国一全文
  _ref_技术报告-钟超炀-国二.txt         89,622 B   国二全文
  ref-fulltext.txt                   115,102 B   冯若陈国二全文

_research/doc-figures/                图件与脚本（make_figures_v2.py 为当前规范版）
_research/doc-drafts/…                正文 Markdown（ch1..ch4 + appendix）
_research/doc-tools/build_docx.py     Word 生成流水线
```

---

## 六、常用命令

```powershell
$py = "C:\Users\Danny\AppData\Local\Python\pythoncore-3.14-64\python.exe"   # 有 matplotlib + python-docx

# 重画全部图（当前规范版）
& $py "_research\doc-figures\make_figures_v2.py"

# 生成 Word
& $py "_research\doc-tools\build_docx.py" --out "技术文档.docx"
& $py "_research\doc-tools\build_docx.py" --draft <目录> --out x.docx

# 文风扫描
& $py "_research\doc-draft\_scan_deai.py"
```
