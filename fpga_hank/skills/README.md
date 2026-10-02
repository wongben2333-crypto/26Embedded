# skills —— 本项目的踩坑知识库

这里放着 `fpga_hank` 开发过程中**自建的 3 个 skill**。
它们记录的不是"知识"，而是**这个项目真实踩过的坑**——每一条都有实测出处。

| Skill | 大小 | 内容 |
|---|---|---|
| `gowin-flow/` | 13.4 KB | 高云 Gowin 命令行全链路规范（综合→P&R→位流→烧录）+ 实测坑位 |
| `verilog-review/` | 9.4 KB | RTL 审查清单 + "波形正常但实际错误"的案例复盘 |
| `fpga-verify/` | 14.1 KB + 22 个附件 | 取证纪律、判据脚本、形式验证模板；`references/traps.md` 22.7 KB |

---

## 为什么值得读

这 3 个 skill 里最值钱的部分是 **`fpga-verify/references/traps.md`**，它记了 **§1–§10** 共十类坑，
每一类都写清了 **现象 / 根因 / 正确做法**。摘几条：

- **§1** `--fs` 漏传参数 → 32 个谱峰**全部**误判 FAIL
- **§2** 谱峰数达标但增益不均 9.74 dB（时分复用 ROM 的地址推进缺陷）
- **§3** **反自欺：判据本身必须先被验证**
- **§6** 证据必须来自**稳定快照**（运行中的文件读出来会自相矛盾）
- **§7** 交付级风险：Gowin 工程**不可移植**（换路径即报 EX5998）
- **§8** ★ 隔离基准**不能**用来"排除嫌疑"（一个被实测推翻的推断）
- **§9** ★★ **五条"看起来对、实际错"的教训**：
  位流哈希不能当修订标识 / 构建必须绑修订号守卫 / 判据脚本自己也会错（假 PASS）/
  ModelSim 不 `log` 则波形库为空 / 位级 VCD 重组必须按时间戳对齐
- **§10** 这五条的共同教训：**"看起来成功"和"看起来失败"都不可信；
  可信的是"把期望值算出来，和实测值逐项对撞"**

---

## 怎么让 DSH 真正加载它们

⚠️ **DSH 的 skill 发现深度【只有一层】**：必须是 `<root>/<name>/SKILL.md`。

**放在 `fpga_hank/skills/` 下不会自动加载** —— 这个目录是给你**阅读**和**装到正确位置**用的。

### 装到你自己的项目里（推荐）

```powershell
# 在你要用它的项目根下建 .dsh\skills\
New-Item -ItemType Directory -Force -Path .dsh\skills

# 把三个 skill 复制进去（注意：复制的是【一级子目录】）
Copy-Item fpga_hank\skills\gowin-flow, `
          fpga_hank\skills\verilog-review, `
          fpga_hank\skills\fpga-verify `
          .dsh\skills\ -Recurse
```

结果应该是：

```
<你的项目>\.dsh\skills\
├─ gowin-flow\SKILL.md
├─ verilog-review\SKILL.md
└─ fpga-verify\SKILL.md
```

### 或装成用户级（所有项目都能用）

```powershell
Copy-Item fpga_hank\skills\gowin-flow, `
          fpga_hank\skills\verilog-review, `
          fpga_hank\skills\fpga-verify `
          "$env:USERPROFILE\.dsh\skills\" -Recurse
```

### 直接读也行

skill 正文就是普通 Markdown，**不依赖任何加载器**。
加载器不生效时，直接 `read .dsh/skills/<name>/SKILL.md` 完全等效。

---

## ⚠️ 两个硬门槛（实测，装第三方 skill 时更要小心）

1. **frontmatter 只认 `name` + `description`**
   （可选 `whenToUse` / `metadata` / `disable-model-invocation` / `user-invocable`）。
   Claude skill 常见的 **`tools:` / `allowed-tools:` DSH 不认**
   ⇒ **整个 skill 会被静默丢弃，而且没有任何诊断信息**。
   本项目的 skill 只用 `name` + `description`，所以是安全的。

2. **发现深度只有一层**（`<root>/<name>/SKILL.md`），**刻意不支持嵌套** `**/SKILL.md`。
   ⇒ 把 skill 放进 `something/skills/` 这类更深的位置**会静默失效**。

---

## 向前兼容约定

如果将来要引入第三方 skill，应保持一个**唯一权威源**，
其他位置的副本必须是**可再生的派生物**（单向：源 → 副本），**禁止反向手改副本**。
