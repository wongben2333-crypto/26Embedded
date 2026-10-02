# team-resources —— 给队友的资料包

> 这一层不是本项目（`fpga_hank`）的工程文件，而是**能直接帮到队友的资料与 Skill**。
> 全部内容都来自本机**实测结论**（Python 3.14.5 + numpy/scipy + ModelSim 10.7 SE-64 +
> Gowin V1.9.12.04 + Tang Mega 138K），凡是未实测的都标了「未验证」。

---

## 1. 这个目录有什么

```
team-resources/
├── README.md                  ← 本文件
├── skills/
│   ├── gowin-flow/            ← 高云 Gowin 命令行全链路构建规范（12 个实测坑）
│   ├── verilog-review/        ← RTL 审查清单（含 5 个"波形正常但实际错误"的实例）
│   └── fpga-verify/           ← 验证与取证门禁（8 个脚本 + 形式验证模板 + 已生成证据图）
└── traps/
    └── 关键坑位速查.md         ← 最致命的 N 条，10 分钟读完，避免踩坑
```

**共 3 个 skill、约 100 KB**（已剔除一次性探测文件 `probe-flat.md`）。
`_research/` 下的整份调研报告**刻意没有收录** —— 体积大、含大量过程性内容；
有价值的结论已经提炼进 `traps/关键坑位速查.md`。

---

## 2. 怎么用（最短路径）

### 2.1 第一次进来：只读一个文件

**`traps/关键坑位速查.md`**。里面是会让队友白干几小时的坑：
Gowin 参数大小写、`.tcl` 的 BOM、`.fs` 大小没有鉴别力、ModelSim `-novopt` 已废弃、
PowerShell 5.1 + AllSigned + UTF-8 BOM 的三重坑……

### 2.2 要动手改 RTL / 跑构建：按角色查 skill

| 你要做的事 | 读哪个 skill | 关键入口 |
|---|---|---|
| 编译工程、写 `gw_sh` Tcl、排查综合/布线/时序错误、生成或烧录 `.fs` | `skills/gowin-flow/SKILL.md` | `run syn` / `run pnr` / `programmer_cli.exe` |
| 检查刚写的 RTL、排查 latch / 多驱动 / 意外推断、准备给评委看的代码 | `skills/verilog-review/SKILL.md` | 按清单顺序走一遍 |
| 出频谱证据、数 32 个谱峰、测延迟 P50/P95/P99、提交前红线自审 | `skills/fpga-verify/SKILL.md` | 见下 2.3 |

### 2.3 要出证据：`fpga-verify` 的脚本

```powershell
# ⚠️ 本机必须带 -ExecutionPolicy Bypass（AllSigned），否则报 "is not digitally signed"
# ⚠️ 含中文的 .ps1 必须存成 UTF-8 with BOM

# 一键自检（内部已带 Bypass）
powershell -NoProfile -ExecutionPolicy Bypass -File .\skills\fpga-verify\tests\run_selfcheck.ps1

# 从 RTL 反推真实采样率（本项目是 48828.125 Hz，不是 48000！）
python .\skills\fpga-verify\scripts\derive_fs.py

# 32 谱峰判定（不传 --fs 会自动推导；退出码 0=PASS / 4=谱峰达标但增益不均 / 1=FAIL / 5=UNSTABLE）
python .\skills\fpga-verify\scripts\spectrum_report.py --file <dump> --format samples --count 32

# 交付可移植性门禁（三态退出码：0/3 正常，1 = 真交付风险）
powershell -NoProfile -ExecutionPolicy Bypass -File .\skills\fpga-verify\scripts\check_portability.ps1
```

**最容易被忽略的一条**：任何频谱/延迟计算前**先跑 `derive_fs.py`**。
`--fs` 漏传会让 32 个峰**全部误判 FAIL**（误差 ≈1.696%），这是实测踩过的坑。

---

## 3. 与 `fpga_hank` 本体的关系

- `fpga_hank/rtl|constr|sim|tools|docs/` = **可以改的工程本体**。
- `team-resources/` = **只读参考资料**。
  里面的 `skills/fpga-verify/scripts/check_peaks.py` 引用了工程内的
  `fpga_hank/tools/verify/check_peaks.py`（工程那份是**唯一事实来源，不要复制修改**）。

---

## 4. 三条会直接影响你脚本的环境事实（先看，别踩）

1. **本机没有 PowerShell 7。** DSH 的 `pwsh` 工具实测就是 **Windows PowerShell 5.1**
   （`$PSVersionTable.PSVersion = 5.1.26100.9444`，`PSEdition = Desktop`）——
   不是"DSH 选了 5.1"，而是 `Get-Command pwsh` 不存在，**没有 7 可选**。
   ⇒ 含中文的 `.ps1` **必须存成 UTF-8 with BOM**。
   ⚠️ 无 BOM 时中文乱码，而**乱码时脚本 exit 0 照常跑完**，拿着错字符串继续工作
   （比较中文标签、匹配中文路径会**静默失配**）—— **"能跑通"绝不等于"结果对"**。

2. **执行策略是 AllSigned。** `powershell -File x.ps1` 和 `& x.ps1` 都会失败（exit 1），
   只有 `powershell -NoProfile -ExecutionPolicy Bypass -File <脚本>` 可用。
   （边界：ExecutionPolicy **只管脚本文件**，不管 `-Command`。）

3. **证据必须来自稳定快照。** 正在被仿真进程写的文件（如 `out/tone_samples.txt`）
   读到"写了一半"的内容会给出**看起来像数据的错误结论**。
   先 `Copy-Item` 成快照再分析；`spectrum_report.py` 已内置 sha256/mtime 前后比对，
   检测到读取期间被改写 → **退出码 5 = UNSTABLE**，明确告诉你"结论无效"。

---

## 5. 维护方式（重要：这里的副本是"派生物"）

`.dsh/skills/` 是这三份 skill 的来源目录，**运维与更新都在那里做**。
`team-resources/skills/` 下的内容是**从它单向派生出来的副本**，目的是让队友拿到仓库后能直接阅读。

**同步命令（单向：源 → 副本）**

```powershell
$src = 'C:\Users\Danny\Desktop\FPGA competition\.dsh\skills'
$dst = '<仓库根>\fpga_hank\team-resources\skills'
robocopy $src $dst /MIR /XF probe-flat.md /XD __pycache__
# robocopy 退出码 0~7 都算成功，>=8 才是真失败（别把它当报错）
```

**维护纪律**

1. **要改内容 → 改 `.dsh/skills/` 下的源**，然后重跑上面的同步命令。
   **不要直接手改副本** —— 手改会让两边分叉，给后续维护制造麻烦。
2. 副本里不写"这里才是权威"之类的措辞：来源永远只有一个。
3. 将来若要把这个路径也纳入 DSH 的 skill 搜索根（`customSkillDirs` 之类），
   那属于**纯追加**的增强：只是多一个搜索根，**源文件一行都不用改**，
   今天已经写好的副本也不会作废。
4. 本会话实测 `skill` 工具对**项目级** skill 加载不了
   （`@deepseek-ai/dsh-skill-filesystem` 状态为 `inactive`），
   所以 **直接 `read` 文件是当前唯一可行的用法** —— 这也是"交付资料包"这条路成立的原因。

---

## 6. 谁维护

由本项目 Lead 与其验证 Agent 维护。内容全部带实测出处；
若你发现某条结论与本机现状不符，**请附原始输出**再改。
文件名/路径相关结论请连同 **RTL hash + 时间戳**一起引用（文件可能正在被改）。
