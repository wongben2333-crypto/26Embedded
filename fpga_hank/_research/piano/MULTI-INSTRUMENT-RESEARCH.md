# 多乐器（钢琴 / 电吉他 / 古筝）—— GitHub + 文献调研清单

> 调研人：`piano-tone`　日期：2026-10-06　用途：为 `MULTI-INSTRUMENT-DESIGN.md` 提供依据
>
> ⚠️ **关于许可证的诚实说明（先说清楚）**
> 我这个会话里 **`github.com` 直接抓取失败、PDF 也不支持抓取**（`web_fetch` 报 `fetch failed` / `unsupported content type`），
> 所以**下列仓库的许可证我【没有核实】，不敢写"是 MIT/GPL"**。
> 但这对本设计**不构成风险**，因为：
> **我的设计只采用公开的物理/算法（Karplus-Strong、Jaffe-Smith、拾音器梳状响应），
> 全部自己写 RTL，不复制任何仓库的代码。**
> ⇒ **若要复用任何代码，请先自行核实该仓库许可证**（尤其 GPL 系会传染）。

---

## A. 弦振动物理建模（核心理论，直接决定我们的系数怎么来）

| # | 来源 | 是什么 | 学到什么 / 对我们的用法 |
|---|---|---|---|
| A1 | [Jaffe & Smith 1983, *Extensions of the Karplus-Strong Plucked-String Algorithm*](https://www.semanticscholar.org/paper/Extensions-of-the-Karplus-Strong-Plucked-String-Jaffe-Smith/995470417936f34e4a6f350a8b16eedbdc1b7d28)（270 引用） | 拨弦建模的**奠基论文** | ⭐ **两个关键结论直接对应用户要的"演奏维度"**：<br>① **拨弦位置（pluck position）滤波器**：在第 x 点拨弦 ⇒ 第 n 次谐波幅度 ∝ **sin(nπx/L)**（在 x 处有节点的谐波不被激发）<br>② **拨片/拾音位置（pick position）梳状滤波**：同理作用于输出<br>③ 环形滤波器用一阶低通/全通实现频率相关的衰减 |
| A2 | [Julius Smith, *Physical Audio Signal Processing*（PASP）](https://ccrma.stanford.edu/~jos/pasp05/Bibliography.html) | 数字波导/物理建模的**权威教科书**（CCRMA，在线免费） | 数字波导 = 延迟线 + 环路滤波；**延迟线长度决定基频**，环路滤波决定各次谐波的衰减差。也是"模态合成 vs 波导"两条路线的取舍依据 |
| A3 | [Jaffe & Smith 1995, *Performance Expression in Commuted Waveguide Synthesis*](http://ccrma.stanford.edu/~jos/pdf/JaffeSmith95.pdf) | **交换式**波导合成（commuted synthesis） | 把"激励（拨弦/擦弦）"与"琴体共鸣"**拆成可复用的滤波器**；⇒ **这正好支持我们"共享引擎 + 换系数表"的方案**（而不是例化三份引擎） |
| A4 | [Hiipakka MSc thesis（HUT/DIVA），模态合成](http://www.tml.hut.fi/Research/DIVA/past/publications/1999/hiipakka_mst.pdf) | 模态（加法）合成的实用实现 | 模态合成的单个谐振器递推式 `a1 = −2β·cos(ω0)`：**β 控制衰减、ω0 控制频率** ⇒ 这就是我们现有"6 泛音独立相位累加器 + 包络"的理论形式，**改 β/ω 即可换乐器** |
| A5 | [Karjalainen 等, AES 114th, 弦建模](http://users.spa.aalto.fi/mak/PUB/AES114thKarjalainen.pdf) | 弦与琴体的源-滤波器分解 | 支持"激励 × 弦 × 共鸣"三段式；我们的引擎里分别对应：激励瞬态、泛音包络、混音后 EQ |

## B. 电吉他专属（拾音器 = 音色的关键）

| # | 来源 | 是什么 | 学到什么 |
|---|---|---|---|
| B1 | [实测频谱对比：neck pickup / bridge pickup / 估计的 bridge 信号](https://core.ac.uk/download/pdf/77043463.pdf) | **实测**给出两拾音器位置的频谱差异 | ⭐ **实证确认"梳状零点"模型**：磁拾音器测量的是**某一点的弦速度** ⇒ 第 n 次谐波响应 ∝ **sin(nπ·d/L)**（d = 拾音器到琴桥的距离）<br>⇒ **琴桥拾音器（d 小）谐波平坦明亮；琴颈拾音器（d 大）前几个零点落在低次谐波上 ⇒ 温暖/空洞**<br>**这解释了为什么电吉他换拾音器档位音色差异巨大** —— 也是用户要的"拾音器选择"维度 |
| B2 | [US5731533（双拾音器组合，两信号相乘）](https://patentimages.storage.googleapis.com/1b/02/f7/1da4d7e91c6dee/US5731533.pdf) | 专利：两个拾音器信号组合 | ⚠️ **仅作旁证，不作设计依据**（专利≠设计来源）：说明"多拾音器组合"在频域上是**两个位置响应的组合**。我们采用**串联叠加**（更常见的接线）并明确记录取哪种 |
| B3 | [McGill：*Model of Electric Bass Using Extended Karplus-Strong*](http://www.music.mcgill.ca/~gary/courses/projects/618_2020/Deng/FP_report.pdf) | 扩展 KS 做电贝斯 | 扩展 KS 的工程流程：激励设计 → 环路滤波 → 拾音/位置滤波 → 输出。**与我们引擎的模块划分一一对应** |
| B4 | [jagumiel/Guitar-Pedal-Effects-on-FPGA](https://github.com/jagumiel/Guitar-Pedal-Effects-on-FPGA)（Terasic DE1-SoC，VHDL） | **FPGA 实时吉他效果器**：distortion / overdrive / tremolo / echo / reverb | ⭐ 证明"挂电"链路在 FPGA 上可行、且是**独立后级**。<br>⚠️ **许可证未核实**；⚠️ **按 Lead 分工，过载/箱体/哇音属 `audio_fx`（不是我的写作用域）** ⇒ 我只交付"琴弦+拾音器"模型 |
| B5 | [DISTRHO/Kars](https://github.com/DISTRHO/Kars)（Karplus-Strong 插件） | 开源 KS 实现（C++/DPF） | 用作**算法交叉验证**的参考实现（不是 RTL 来源）。⚠️ DISTRHO 系通常是 GPL 家族，**未核实** |

## C. 古筝专属

| # | 来源 | 是什么 | 学到什么 |
|---|---|---|---|
| C1 | [*Acoustics of the Guzheng: Chinese Plucked Zither*（BioResources）](https://bioresources.cnr.ncsu.edu/wp-content/uploads/2026/04/BioRes_21_2_5306_Sinin_HSTM_Acoustics_Guzheng_Plucked_Zither_25391.pdf) | ⭐ **古筝声学实测研究** | 给出古筝的**频谱结构与衰减特征**（长衰减、木共鸣箱共振）⇒ 我取"衰减比钢琴长、低频有箱体共振"作为系数依据 |
| C2 | [DAGA 2011：*Akustische Charakterisierung der chinesischen Guzheng*](http://pub.dega-akustik.de/DAGA_2011/data/articles/000190.pdf) | 另一份独立的古筝声学表征 | 与 C1 互为**独立佐证**（避免单来源定系数 —— §9 的纪律） |
| C3 | [古筝基本形制/定弦（含 21 弦、五声音阶、雁柱可移）](https://www.thomann.de/cz/thomann_chinese_guzheng_iii.htm) | 乐器形制 | 21 弦、五声音阶定弦、**雁柱（可移动琴码）决定每弦音高** ⇒ **按弦（左手压弦）使张力增大 ⇒ 音高【上滑】，幅度可达半音~大三度** ⇒ 这就是古筝最标志性的维度 |
| C4 | [Cambridge IGCSE 中国音乐导览](https://www.cambridgeinternational.org/Images/697243-2025-teacher-s-guide.pdf) | 中国乐器演奏法背景 | 摇指/刮奏/吟猱等演奏法的音乐功能描述 ⇒ 用于维度取舍（哪些做进引擎、哪些交给演奏法） |

## D. FPGA 上的实现（工程可行性）

| # | 来源 | 是什么 | 学到什么 |
|---|---|---|---|
| D1 | [Sky130 shuttle: `ks_tuning.v` / `ks_dynamics.v`](https://foss-eda-tools.googlesource.com/third_party/shuttle/sky130/mpw-004/slot-027/+/ed1c9f90396ca2f30a511f50f86b08f7796aab5a/verilog/rtl/ks_tuning.v) | ⭐ **真实 Verilog 的 Karplus-Strong**（含调音与动态控制） | KS 在 RTL 里的工程细节：延迟线读写、环路滤波的定点化、调音精度。⚠️ 许可证未核实（Sky130 shuttle 工程多为开源许可，但**必须自行确认**） |
| D2 | [IEEE: *FPGA-based sound synthesis by digital waveguide*](https://ieeexplore.ieee.org/abstract/document/7152258) | 数字波导的 FPGA 实现 | 波导法的资源画像（延迟线用 BSRAM）⇒ **与我们的加法合成路线对比**：波导省乘法器但**必须占 BSRAM 且环路是反馈路径（时序更紧）** |
| D3 | [kazunori279/xls32-fpga-synth](https://github.com/kazunori279/xls32-fpga-synth) | **32 复音 FPGA 合成器**（Google XLS/DSLX，Basys 3） | 多声部架构的分声部/混音组织方式参考。⚠️ 许可证未核实 |
| D4 | [AlexandreSinger/ECE532-Project](https://github.com/AlexandreSinger/ECE532-Project) | 多伦多大学 FPGA 设计课项目 | 音频工程课的验收方式（可借鉴其"逐级可测"思路）。⚠️ 许可证未核实 |
| D5 | [Infineon 社区：*Karplus Strong verilog help*](https://community.infineon.com/t5/PSOC-5-3-1/Karplus-Strong-verilog-help/m-p/221357) | 论坛实战问答 | KS 在 Verilog 里最容易踩的坑（延迟线长度与调音精度、除以二的环路增益） |

---

## E. 调研结论：**为什么我们【不】改用波导/KS，而是继续加法合成 + 换系数**

| 判据 | 波导 / Karplus-Strong | **加法（我们现有结构）** |
|---|---|---|
| 音色真实度（拨弦） | ⭐ 更自然（延迟线=物理弦） | 6 泛音够用；拨弦位置/拾音器梳状**用系数表就能表达** |
| 时序 | 环路是**反馈路径**，单周期收敛要求高 | 现有结构已验证（MODE=1 **0 违例 / +0.009 ns**），**不能再压** |
| 面积 | 每弦一条延迟线（BSRAM）；8 弦 × 2 读口 | 现有 8 声部 × 6 泛音已就位 |
| 与赛题评分 | 物理建模按"并行弦/模态单元"计 | 加法合成按**运算分量**计 ⇒ **现有 48 个加法分量已经是得分项** |
| 改动风险 | 等于**重写引擎** | **只换系数表 + 激励参数**（Lead 明确要求"复用而不是重写"） |

**⇒ 结论：采用"共享加法引擎 + 每乐器系数表 + 装载期算梳状"的方案。**
**⇒ 依据 A3（commuted synthesis）+ A4（模态合成）+ A1（拨弦/拾音位置梳状）三者支撑。**

---

## F. 我**没有**从 GitHub 直接搬的东西（合规声明）
- ❌ 没有复制任何仓库的 Verilog/VHDL/C++ 代码
- ❌ 没有使用任何**录音/采样**（赛题红线）
- ✅ 三个乐器的新系数**全部由 `tools/gen/gen_piano_rom.py` 里的解析公式生成**，公式与参数写进脚本注释
  （与现有 ROM 的做法一致：评审可对照公式复核，不存在"来历不明的音频数据"）
