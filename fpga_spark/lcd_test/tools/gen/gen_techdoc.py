# -*- coding: utf-8 -*-
"""gen_techdoc.py —— 生成《技术文档》Word 文档

结构学习自往届国二作品《声之形》技术文档（91 页）：
    一、设计概述      1.1 设计目的 / 1.2 应用领域 / 1.3 主要技术特点 / 1.4 关键性能指标 / 1.5 主要创新点
    二、系统组成及功能说明   2.1 整体介绍 / 2.2 各模块介绍
    三、完成情况及性能参数   3.1 完成情况 / 3.2 性能参数
    四、作品总结

★ 关键坑（内置 office skill 明确提示）：中文字体必须显式设置
  run 的 `w:eastAsia`，否则中文会回退成默认字体、在别人机器上变样。

用法：
    python gen_techdoc.py            # 写入 fpga_hank/docs/技术文档.docx
"""
from __future__ import annotations

import os
import sys

sys.stdout.reconfigure(encoding='utf-8')

try:
    from docx import Document
    from docx.shared import Pt, RGBColor, Cm
    from docx.enum.text import WD_ALIGN_PARAGRAPH
    from docx.enum.table import WD_TABLE_ALIGNMENT
    from docx.oxml.ns import qn
    from docx.oxml import OxmlElement
except ImportError as e:
    print('缺少 python-docx:', e)
    print('请用 load_workspace_dependencies 提供的 Python，或 pip install python-docx')
    sys.exit(1)

CN = '微软雅黑'
MONO = 'Consolas'
BLUE = (0x1F, 0x3B, 0x73)
BLUE2 = (0x2E, 0x5A, 0x9E)


def style_run(run, size=10.5, bold=False, color=None, mono=False):
    """设置字体；中文必须显式设 w:eastAsia，否则跨机器会变样。"""
    run.font.name = MONO if mono else CN
    run.font.size = Pt(size)
    run.font.bold = bold
    if color:
        run.font.color.rgb = RGBColor(*color)
    rpr = run._element.get_or_add_rPr()
    rf = rpr.find(qn('w:rFonts'))
    if rf is None:
        rf = OxmlElement('w:rFonts')
        rpr.append(rf)
    rf.set(qn('w:eastAsia'), CN)


def H(doc, level, text):
    p = doc.add_heading(level=level)
    r = p.add_run(text)
    style_run(r, size={1: 16, 2: 13.5, 3: 11.5}.get(level, 11),
              bold=True, color=BLUE if level <= 2 else BLUE2)
    return p


def PARA(doc, text, size=10.5, bold=False, indent=True):
    p = doc.add_paragraph()
    if indent:
        p.paragraph_format.first_line_indent = Cm(0.74)
    r = p.add_run(text)
    style_run(r, size=size, bold=bold)
    return p


def CODE(doc, text):
    p = doc.add_paragraph()
    p.paragraph_format.left_indent = Cm(0.6)
    p.paragraph_format.space_after = Pt(2)
    r = p.add_run(text)
    style_run(r, size=9, mono=True, color=(0x33, 0x33, 0x33))
    return p


def BULLET(doc, text):
    p = doc.add_paragraph(style='List Bullet')
    r = p.add_run(text)
    style_run(r, size=10.5)
    return p


# A4 页面尺寸（cm）。python-docx 默认模板是 US Letter，中文文档惯例是 A4。
A4_W_CM, A4_H_CM = 21.0, 29.7


def TABLE(doc, headers, rows, widths=None):
    t = doc.add_table(rows=1, cols=len(headers))
    t.style = 'Light Grid Accent 1'
    t.alignment = WD_TABLE_ALIGNMENT.CENTER
    for i, h in enumerate(headers):
        c = t.rows[0].cells[i]
        c.text = ''
        r = c.paragraphs[0].add_run(h)
        style_run(r, size=10, bold=True)
    for row in rows:
        cells = t.add_row().cells
        for i, v in enumerate(row):
            cells[i].text = ''
            r = cells[i].paragraphs[0].add_run(str(v))
            style_run(r, size=9.5)
    if widths:
        # ★ 自动缩放：合计宽度不得超过可用宽度，否则打印时会被裁切/挤压。
        #   这样以后新增表格不必手算，也不会溢出。
        avail_cm = A4_W_CM - 2.6 * 2          # 左右各 2.6 cm
        total = float(sum(widths))
        if total > avail_cm:
            k = (avail_cm * 0.98) / total
            widths = [w * k for w in widths]
            print('   [TABLE] 宽度合计 %.2f cm > 可用 %.2f cm，按 %.4f 缩放'
                  % (total, avail_cm, k))
        for i, w in enumerate(widths):
            for row in t.rows:
                row.cells[i].width = Cm(w)
    return t


def adsr_times(clk_hz=50_000_000.0):
    """★ 从 rtl/top.v 的【实际例化参数】实算 ADSR 各段时长。

    为什么必须实算而不是手写：
      本项目建设期曾把 EN_DIV=8 / ATK_SH=8 的包络注释成「≈42 ms」，
      实际只有 40.96 µs（2 个采样点），差 1000 倍，而该错数一度被写进
      要提交的技术文档。根因是当时 en_div_cnt 只有 8 位、EN_DIV 上限 255。
      现在文档数值一律由代码算出，杜绝再错。
    """
    import re as _re
    here = os.path.dirname(os.path.abspath(__file__))
    topv = os.path.normpath(os.path.join(here, '..', '..', 'rtl', 'top.v'))
    if not os.path.exists(topv):
        return None
    txt = open(topv, encoding='utf-8').read()
    m = _re.search(r'adsr\s*#\s*\((.*?)\)\s*u_adsr', txt, _re.S)
    if not m:
        return None
    body = m.group(1)

    def get(name, default):
        mm = _re.search(r'\.' + name + r'\s*\(\s*(\d+)\s*\)', body)
        return int(mm.group(1)) if mm else default

    en_div = get('EN_DIV', 512)
    atk_sh = get('ATK_SH', 10)
    dec_sh = get('DEC_SH', 10)
    rel_sh = get('REL_SH', 13)
    sus    = get('SUS_LEVEL', 49152)

    step_s = en_div / clk_hz                      # 每个速率步进的秒数
    # ★ 步数推导（对齐 rtl/synth/adsr.v 的实际逻辑）：
    #   ATK_INC = (1<<16) >> ATK_SH 就是【每步的增量】，
    #   而 atk_next = cur + ATK_INC，所以从 0 爬到满幅 65536 需要
    #       65536 / ATK_INC = 65536 / (65536>>SH) = 1<<SH 步。
    #   ⚠️ 不要写成 (1<<16)>>SH —— 那是【增量】不是【步数】，
    #      会把时长算小 2^SH 倍（本函数初版就犯了这个错）。
    atk_steps = (1 << atk_sh)
    # ★ 衰减步数：从【满幅 65536】降到【保持电平 sus】，降幅 = 65536 - sus；
    #   每步降 DEC_INC = (1<<16) >> DEC_SH。
    #   曾错写成 (1<<dec_sh)（那是 1024 步 → 10.49 ms），
    #   与 tb_adsr 实测的 "DEC → SUS（131072 拍 = 2.62 ms）" 不符。
    #   这条错一直藏在交付文档里，直到有人把 VCD 提取出来量才发现 —— 
    #   说明"手算/手写时长"这类错极难靠肉眼发现。
    dec_inc   = (1 << 16) >> dec_sh
    dec_steps = int((65536 - sus) / dec_inc) if dec_inc else 0
    rel_inc   = (1 << 16) >> rel_sh               # 释放每步下降量
    rel_steps = int(sus / rel_inc) if rel_inc else 0

    return {
        'EN_DIV': en_div, 'ATK_SH': atk_sh, 'DEC_SH': dec_sh, 'REL_SH': rel_sh,
        'step_us': step_s * 1e6,
        'atk_ms': atk_steps * step_s * 1e3,
        'dec_ms': dec_steps * step_s * 1e3,
        'rel_ms': rel_steps * step_s * 1e3,
        'atk_steps': atk_steps, 'dec_steps': dec_steps, 'rel_steps': rel_steps,
    }


def main():
    doc = Document()
    # 页面设置
    for s in doc.sections:
        # ★ 页面尺寸必须显式设为 A4：python-docx 的默认模板是 US Letter
        #   （215.9 x 279.4 mm），而中文竞赛文档的惯例是 A4（210 x 297 mm）。
        #   已核实往届国二模板 `技术文档-冯若陈-国二.pdf` 的 MediaBox = A4。
        #   ⚠️ 不设不会报错，但打印/转 PDF 时页面尺寸与预期不符。
        s.page_width = Cm(A4_W_CM)
        s.page_height = Cm(A4_H_CM)
        s.top_margin = Cm(2.2)
        s.bottom_margin = Cm(2.2)
        s.left_margin = Cm(2.6)
        s.right_margin = Cm(2.6)

    # ==================== 封面 ====================
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r = p.add_run('\n\n\n第九届（2026）全国大学生嵌入式芯片与系统设计竞赛')
    style_run(r, size=14, bold=True, color=BLUE)
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r = p.add_run('FPGA 创新设计赛道 · 高云半导体命题')
    style_run(r, size=13, bold=True, color=BLUE)

    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r = p.add_run('\n技 术 文 档')
    style_run(r, size=26, bold=True, color=BLUE)

    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r = p.add_run('\n选题二：基于 FPGA 的实时多音色合成电子乐器引擎')
    style_run(r, size=15, bold=True)

    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r = p.add_run('\n\n平台：Sipeed Tang Mega 138K（GW5AST-LV138PG484AC1/I0）')
    style_run(r, size=11)
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r = p.add_run('工具链：高云 Gowin EDA V1.9.12.04')
    style_run(r, size=11)

    doc.add_page_break()

    # ==================== 一、设计概述 ====================
    H(doc, 1, '一、设计概述')

    H(doc, 2, '1.1 设计目的')
    PARA(doc, '本作品面向「基于 FPGA 的实时多音色合成电子乐器引擎」赛题，目标是'
              '用纯硬件逻辑（HDL）实现一台可实时演奏的多音色电子乐器：'
              '演奏者的动作被传感器采集，合成引擎逐样本、逐声部实时生成音频，'
              '经 I2S 接口送往板载 DAC 解码发声，全过程不依赖任何软件串行运算、'
              '不播放任何预录音频。')
    PARA(doc, '赛题的核心评分依据是「同时活跃可闻独立振荡器总数 × 实际音频输出采样率」。'
              '因此本设计把「尽可能多地并行堆叠真实振荡器」作为架构主线，'
              '而不是把单个振荡器做复杂。')

    H(doc, 2, '1.2 应用领域')
    BULLET(doc, '电子乐器与音乐教育设备：低延迟是演奏体验的核心指标，FPGA 的确定性延迟远优于软件方案。')
    BULLET(doc, '嵌入式音频前端：可作为通用多声部合成 IP，供 SoC 集成。')
    BULLET(doc, '实时信号生成与测试设备：多路并行正弦/任意波形发生。')

    H(doc, 2, '1.3 主要技术特点')
    BULLET(doc, '全 HDL 实现：从振荡器、包络、混音到 I2S 发送全部由硬件逻辑完成，无软核参与合成。')
    BULLET(doc, '32 路独立振荡器并行：每路具备独立的 32 位相位累加器、独立频率字与独立 ADSR 包络，'
                '满足赛题「振荡器三要素缺一不可」的统计规则。')
    BULLET(doc, '单时钟域设计：整条音频通路只用一个 50 MHz 时钟，'
                '刻意不使用分频得到的位时钟去驱动逻辑 —— 那会引入未约束的跨时钟域，'
                '偶发漏采样会让相位累加器错位，听感是「音不准」而非「咔哒声」，极难定位。')
    BULLET(doc, '时分复用波表：32 路在一个采样周期内轮流查询同一份波形 ROM，'
                '在 1024 拍预算内完成 32 次查表并累加，既避开 BSRAM 端口冲突，'
                '又保证每个采样点都是真实的 32 路求和（而非轮流出声）。')
    BULLET(doc, '多音色：4 张带限波形表共用一份 ROM，以地址高位选择音色，运行时可切换。')

    H(doc, 2, '1.4 关键性能指标')
    TABLE(doc,
          ['指标', '本设计实测值', '赛题要求'],
          [
              ['复音数（独立振荡器）', '32 路', '基础 ≥4，拓展① ≥32'],
              ['音频输出采样率', '97 656.25 Hz（96 kHz 模式，已验证）', '未规定，作为评分乘数'],
              ['吞吐量（振荡器数 × 采样率）', '约 3.13 × 10⁶（32 × 97656）', '评分公式核心项'],
              ['I2S 位时钟 BCK', '3.125 MHz（占芯片 20 MHz 上限的 15.6%）', '芯片上限 20 MHz'],
              ['ADSR 包络', '四段（起音/衰减/保持/释放），逐路独立', '基础要求'],
              ['多音色', '4 种（正弦 / 带限锯齿 / 方波 / 三角波）', '拓展② ≥2 种'],
              ['频谱谱峰验证', '32/32 命中，0 杂散，离散度 0.77 dB', '必备交付物'],
              ['逻辑资源占用', '5832 / 138 240 LUT（4%）', '—'],
              ['寄存器占用', '1699 / 139 095 FF（1%）', '—'],
              ['DSP 占用', '58 / 298（另注：变调乘法写在 32 路循环内被复制 32 份；资源充裕故保留，已在代码注释记录权衡）', '—'],
              ['BSRAM 占用', '1 / 340', '—'],
          ],
          widths=[5.0, 6.5, 4.5])

    H(doc, 2, '1.5 主要创新点')
    BULLET(doc, '把「测试模式」与「演奏模式」显式分离。ADSR 门控必然调制音频、产生边带、'
                '把谱峰抹开（实测演奏波形只命中 6/32）。因此测试模式下让 32 路全部'
                '按住并进入 sustain，电平恒定，谱峰才干净 —— 这正是赛题要求的取证状态。')
    BULLET(doc, '「整数分频 + 频率字补偿」替代分数分频。采样率取 48 828.125 Hz（非 48 kHz），'
                '音准通过按【实际】采样率折算频率字来保证，误差为 0；'
                '彻底规避了分数分频抖动灌入音频的问题（参考实现亦采用此思路）。')
    BULLET(doc, '以客观资源变化证明功能真的接入了通路：包络接入前后 DSP 由 0 变 1、'
                '换用多音色 ROM 后 BSRAM 由 2 块降为 1 块。'
                '这比「代码里写了」更有说服力 —— 未使用的逻辑会被综合器优化掉。')

    doc.add_page_break()

    # ==================== 二、系统组成及功能说明 ====================
    H(doc, 1, '二、系统组成及功能说明')

    H(doc, 2, '2.1 整体介绍')
    PARA(doc, '系统采用单时钟域、逐样本流水的数据通路：')
    CODE(doc, 'bench_gate ──gate[32]──► adsr ──level_rd──► tone_bank ──mix──► pt8211_tx ──► PT8211 DAC')
    CODE(doc, '     ▲                     ▲                   │')
    CODE(doc, '     │                     └── env_voice ◄──────┘')
    CODE(doc, '     └── 真实演奏模式下换成「电容触摸/光电/压力 → 按键扫描 → 声部分配器」')
    PARA(doc, '各模块职责：')
    TABLE(doc,
          ['模块', '文件', '职责'],
          [
              ['顶层', 'rtl/top.v', '时钟/复位、连接各模块、音色选择、状态 LED'],
              ['测试演奏产生器', 'rtl/synth/bench_gate.v', '测试模式下提供 gate（含 TEST_MODE 开关）'],
              ['包络发生器', 'rtl/synth/adsr.v', '32 路并行 ADSR，电平敏感 gate'],
              ['振荡器组', 'rtl/synth/tone_bank.v', '32 路独立相位累加器 + 时分复用查表 + 混音'],
              ['波形 ROM', 'rtl/synth/wave_rom.v', '4 张带限波形表，共用一份 ROM'],
              ['I2S 发送器', 'rtl/audio/pt8211_tx.v', 'PT8211 LSB-justified 立体声串行发送'],
              ['触摸检测', 'rtl/io/touch_pad.v', 'RC 充放电时间测量（未接入，见 3.1）'],
          ],
          widths=[3.2, 4.6, 8.2])

    H(doc, 2, '2.2 各模块介绍')

    H(doc, 3, '2.2.1 振荡器组 tone_bank（核心）')
    PARA(doc, '赛题规定一个「振荡器」必须同时具备独立相位累加器、频率调控与包络控制。'
              '本模块以 32 个独立 32 位寄存器数组 acc[0..31] 实现相位累加器，'
              '每路对应一个独立频率字，包络电平由 adsr 逐路提供。')
    PARA(doc, '每个采样周期（fs = 48 828.125 Hz，即 1024 个 clk）的执行流程：')
    CODE(doc, 'samp_cnt = 0      : 32 路相位累加器并行更新；地址 MUX 指向第 0 路')
    CODE(doc, 'samp_cnt = 1..32  : 每拍 ROM 返回一路波形值，经本路包络缩放后累加')
    CODE(doc, 'samp_cnt = 33     : 饱和限幅 + 预缩放 → mix_out')
    PARA(doc, '波形地址为 {音色[1:0], 相位[31:24]}，因此 4 张表共用一份 ROM，'
              '只需一个地址多路选择器即可切换音色。')

    H(doc, 3, '2.2.2 ADSR 包络发生器 adsr')
    PARA(doc, '32 路并行推进（而非时分走查）：50 MHz 下每采样点有 1024 拍预算，'
              '各路做一次 17 位加减完全放得下，且并行推进没有「扫描索引对齐」问题。')
    PARA(doc, '—★ 接口语义：gate 是【电平】而非脉冲。按键按住时 gate 持续为高，'
              '起音后进入衰减与保持；松开时 gate 变低，按释放斜率下降，降到 0 才回收声部。'
              '（开发中曾把 gate 当单拍脉冲，导致释放只发生一拍、电平停在保持值不动。）')
    # ★ 各段时长【实算】自 rtl/top.v 的实际例化参数，绝不手写。
    #   本项目建设期曾把 EN_DIV=8/ATK_SH=8 的包络注释成"≈42 ms"，
    #   实际只有 40.96 µs（2 个采样点），差 1000 倍，且该错数一度
    #   进了这份要提交的文档。现在一律由 adsr_times() 从代码算出。
    _t = adsr_times()
    if _t is None:
        raise SystemExit('ERROR: 无法从 rtl/top.v 解析 adsr 参数，拒绝生成带估算值的文档')
    TABLE(doc,
          ['阶段', '行为', '本设计实测时长'],
          [
              ['Attack', '电平从 0 线性爬升到满幅',
               '约 %.1f ms（2^%d 步 × %.2f µs）' % (_t['atk_ms'], _t['ATK_SH'], _t['step_us'])],
              ['Decay', '从满幅降到 sustain 电平',
               '约 %.1f ms（%d 步 × %.2f µs）' % (_t['dec_ms'], _t['dec_steps'], _t['step_us'])],
              ['Sustain', '保持 sustain 电平（75% 满幅）不变', '持续到松开按键'],
              ['Release', '从当前电平降到 0 并回 IDLE',
               '约 %.1f ms（%d 步 × %.2f µs）' % (_t['rel_ms'], _t['rel_steps'], _t['step_us'])],
          ],
          widths=[2.6, 7.0, 6.4])
    PARA(doc, '各段时长由公式「步数 × EN_DIV ÷ 50 MHz」实算得出，'
              '其中 EN_DIV = %d（每步 %.2f µs）。'
              '本表数值由生成脚本从 RTL 参数自动计算，与代码保证一致。'
              % (_t['EN_DIV'], _t['step_us']))
    PARA(doc, '⚠️ 开发中的一条实测教训值得记录：初版把 en_div_cnt 定为 8 位，'
              '导致 EN_DIV 上限只有 255，包络最快也只能到毫秒级以下，'
              '起音实测仅 40.96 µs（相当于 2 个采样点），耳朵完全听不出 ADSR ——'
              '而注释里却写着「≈42 ms」。这属于「参数范围被位宽悄悄限死」的缺陷：'
              '代码能编译、仿真断言全过（断言只查状态转移、不查时长），'
              '只有把时长算出来才会暴露。现已把位宽参数化为 DIV_W，'
              '并让文档数值一律由代码实算。')

    H(doc, 3, '2.2.3 I2S 发送器 pt8211_tx')
    PARA(doc, '板载 PT8211 为 LSB-justified（日系）格式 DAC，其数据手册三条关键事实决定了本模块的实现：')
    BULLET(doc, 'DIN 在 BCK 的上升沿被移入输入寄存器 → DIN 必须在上升沿之前稳定。')
    BULLET(doc, 'WS 为低时数据进右声道寄存器，为高时进左声道。')
    BULLET(doc, '16 bit 二进制补码、MSB 先出、LSB-justified。')
    PARA(doc, '因此 DIN 与 WS 都在 BCK 的下降段更新，给 DAC 留下整整半个位周期（约 320 ns）的建立时间。'
              '一个立体声帧 = 32 个 BCK 周期 = 左 16 位 + 右 16 位；'
              '一个 BCK 周期 = 16 个 clk 相位 × BCK_DIV 个 clk。取 BCK_DIV=1（96 kHz 模式）：')
    CODE(doc, 'BCK = 50 MHz / (1 × 16) = 3.125 MHz')
    CODE(doc, 'fs  = 3.125 MHz / 32    = 97 656.25 Hz')

    H(doc, 3, '2.2.4 波形 ROM wave_rom（多音色）')
    PARA(doc, '4 张 256 项、16 bit 有符号的波形表，按谐波系数合成后归一化：')
    TABLE(doc,
          ['表号', '音色', '谐波结构', 'RMS'],
          [
              ['0', '纯正弦', '仅基波', '23170'],
              ['1', '带限锯齿', '1/n 幅度，1~5 次谐波', '12276'],
              ['2', '方波', '1/n 幅度，奇次 1~9 次谐波', '14105'],
              ['3', '三角波', '1/n² 幅度，奇次 1~9 次谐波', '19713'],
          ],
          widths=[1.8, 3.6, 7.6, 3.0])
    PARA(doc, '带限是必需的：不做带限的锯齿/方波含无限谐波，在高音区会产生严重混叠，'
              '听感是「金属味杂音」，频谱上还会长出测试模式不希望的谱峰。')

    H(doc, 3, '2.2.5 两种工作模式')
    TABLE(doc,
          ['模式', '开关', 'gate', '音色', '用途'],
          [
              ['测试模式', 'TEST_MODE = 1', '32 路恒按住', '锁定表 0（纯正弦）', '频谱取证'],
              ['演奏模式', 'TEST_MODE = 0', '由交互逻辑驱动', '可切换', '实时演奏'],
          ],
          widths=[2.4, 3.0, 3.2, 3.6, 3.8])
    PARA(doc, '测试模式必须锁定纯正弦表：若使用含谐波的表，每一路会产生多个谱峰，'
              '「N 路 → N 个谱峰」的判据会被误判为杂散。')

    doc.add_page_break()

    # ==================== 三、完成情况及性能参数 ====================
    H(doc, 1, '三、完成情况及性能参数')

    H(doc, 2, '3.1 完成情况')
    TABLE(doc,
          ['模块 / 要求', '状态', '验证方式与实测结论'],
          [
              ['高云 Gowin 全链路命令行构建', '已完成',
               '综合→布局布线→bitstream 生成成功（84.2 秒）；12 个引脚全部按 .cst 分配、全部 constrained=Y；时序零违例'],
              ['PT8211 I2S 发送器', '已完成',
               '仿真逐位解码：0 位错；96 kHz 下 BCK 恒 320 ns，时序零违例'],
              ['32 复音测试模式 + 频谱取证', '已完成',
               '32/32 独立谱峰、0 杂散、电平离散度 0.77 dB（赛题必备交付物）'],
              ['ADSR 包络', '已完成',
               '9/9 断言通过，并已接入数据通路（资源中 DSP 由 0 变 1 佐证）'],
              ['单音实时变调（基础要求③）', '已完成', '新增 pitch_semi 运行时半音变调（-8~+7）；实测 32 个谱峰整体移动 2^(7/12) 倍，平均相对误差 0.014%'],
              ['多音色（4 种）', '已完成',
               '4 张表共用一份 ROM，运行时可切换；综合后 BSRAM 由 2 降为 1'],
              ['电容触摸检测', '未通过验证',
               '仿真仍有 3 处失败；未接入顶层、无引脚约束，不影响当前 bitstream'],
              ['多维交互检测（基础要求①）', '已完成',
               'tb_interaction.v 9 项全 PASS（去抖/起音/释放/换音色/变调/维度独立性）；'
               '引脚 AB13/Y12/Y22 全 constrained=Y'],
              ['烧录链路（bitstream 被工具接受）', '已完成',
               'programmer_cli --svfcreate 成功解析本 bitstream 并生成标准 JTAG 向量文件：'
               '9 258 660 B / 65 694 行，文件头提取 Device ID = h0001081B；不需板子即可验证'],
              ['整机上板实测', '未完成', '尚未在真实开发板上运行'],
              ['硬件效果器 / ≥3 维表情 / 可视化', '未开始', '拓展②③，视时间推进'],
          ],
          widths=[5.0, 2.4, 8.6])

    H(doc, 2, '3.2 性能参数')
    PARA(doc, '以下资源数据来自高云 Gowin V1.9.12.04 的实际布局布线报告'
              '（eda_proj/fpga_hank/impl/pnr/fpga_hank.rpt.txt）。')
    TABLE(doc,
          ['资源项', '占用', '总量', '利用率'],
          [
              ['Logic（LUT/ALU）', '5832', '138 240', '4%'],
              ['Register（FF）', '1699', '139 095', '1%'],
              ['DSP（18×18 乘法器）', '1', '298', '<1%'],
              ['BSRAM', '1', '340', '<1%'],
              ['I/O Port', '12', '297', '4%'],
              ['CLS', '2864', '69 120', '4%'],
          ],
          widths=[4.6, 2.6, 2.6, 2.6])
    PARA(doc, '资源占用远低于器件容量（LUT 仅 4%），为后续加入效果器、可视化等功能留出了充足余量。')

    PARA(doc, '⚠️ 关于 ADSR 时长，本项目存在【两套配置】，数字不同但都正确，'
              '此处必须说明以免误读：')

    TABLE(doc,
          ['配置', '参数（EN_DIV / ATK_SH / DEC_SH / REL_SH）', '起音', '衰减', '释放'],
          [
              ['生产配置（rtl/top.v）', '512 / 10 / 10 / 13',
               '10.49 ms', '2.62 ms', '62.91 ms'],
              ['波形取证配置（sim/tb/tb_wave.v）', '64 / 13 / 16 / 16',
               '10.49 ms', '20.97 ms', '62.91 ms'],
          ],
          widths=[5.2, 4.6, 2.0, 2.0, 2.2])

    PARA(doc, '两套配置的差异是为了不同的目的：波形取证时把包络放慢，'
              '才能在屏幕上看清起音/衰减/释放的斜坡形状（2.6 ms 的衰减在整屏时间轴上'
              '只有几个像素）；而生产配置的包络更接近乐器的手感。'
              '**本文档第 3.2 节所列均为【生产配置】的数值。**')

    H(doc, 3, '3.2.1 PT8211 时序合规性（逐项对照原厂手册）')

    PARA(doc, '音频链路能不能出声，不只取决于逻辑对不对，还取决于时序是否满足 DAC 的'
              '电气规格。本项目把原厂手册（PTC V1.7）AC 特性表里的每一项都提取出来，'
              '与设计逐项对照 —— 这项检查发现了一个【用波形截图完全看不出来】的规格偏差。')

    TABLE(doc,
          ['参数', '含义', '手册限值', '本设计实测', '结论'],
          [
              ['Fbck', 'BCK 位时钟频率', '≤ 18.4 MHz', '3.125 MHz', 'OK（占 17%）'],
              ['Fws', 'WS 字时钟频率', '≤ 384 kHz', '97.656 kHz', 'OK（占 25%）'],
              ['tH', 'BCK 高电平时间', '≥ 25 ns', '40 ns', 'OK（余量 60%）'],
              ['tR / tF', 'DAC 上升/下降时间', '≤ 20 ns',
               'DAC 自身 I/O 特性', '不受 FPGA 控制'],
          ],
          widths=[2.0, 3.6, 2.8, 3.2, 3.4])

    PARA(doc, '上表三项均由 tb_pt8211_final.v 在每次仿真时自动检查并打印，'
              '避免"改一处引入超规格"。')

    PARA(doc, '⚠️ 其中 tH 这一项是【修过的】：初版实现里 BCK 高电平只有 1 个时钟相位 = 20 ns，'
              '比手册最小值 25 ns 短 20%。由于 DIN 是在 BCK 的上升沿被锁存，'
              '高电平过短可能让 DAC 来不及可靠锁存 —— 也就是说，'
              '这【直接关系到上板第一次能不能出声】。'
              '它在波形截图上完全看不出来：肉眼只看到"有个高电平"，'
              '必须把时间真的量出来（20 ns vs 25 ns）才会暴露。'
              '修法是把高电平从 1 个相位加宽到 2 个（40 ns）；'
              '因为 BCK 周期仍是 16 个相位，所以【采样率完全不变】，修改零性能代价。')

    H(doc, 3, '3.2.2 频谱取证数据（赛题必备交付物）')
    PARA(doc, '测试模式下输出 32 路均匀分布的不同频率（200 Hz 起、间隔 200 Hz，共 200~6400 Hz），'
              '对 65 536 个采样点做 FFT 分析（Blackman-Harris 窗，频率分辨率 0.745 Hz）：')
    TABLE(doc,
          ['判据', '门限', '实测', '结论'],
          [
              ['期望谱峰命中', '32/32', '32/32', '通过'],
              ['最大频率误差', '≤ ±2 Hz', '0.37 Hz', '通过'],
              ['未预期谱峰（杂散）', '0 个', '0 个', '通过'],
              ['各路电平离散度', '—', '0.77 dB', '通过'],
              ['每路可闻（电平）', '≥ −40 dBc', '最低 −0.82 dBc', '通过'],
          ],
          widths=[5.4, 3.0, 3.4, 2.4])
    PARA(doc, '该结果由独立工具 check_peaks.py 判定（exit 0），'
              '并用 Goertzel 算法对 200 / 6200 / 6400 Hz 三点做了独立复核，结论一致。')

    doc.add_page_break()

    # ==================== 三之四、验证方法与证据 ====================
    H(doc, 2, '3.3 验证方法与证据')

    PARA(doc, '本节说明我们【怎么知道设计是对的】。之所以单独成节，是因为在硬件可编程领域，'
              '"代码能编译""波形看起来正常"都【不是】正确性的证据 —— 本项目在开发过程中'
              '反复验证了这一点。')

    H(doc, 3, '3.3.1 三条验证纪律')

    BULLET(doc, '用客观量代替主观观感。波形"看起来对"不算数：'
                'PT8211 发送器曾连续 6 个版本在波形上"看着正常"，实际都是错的'
                '（相位停滞、声道错位、位宽少一位等）。最终改用【纯黑盒逐位解码】——'
                '只看 bck/ws/din 三根线，把串行数据解出来与激励逐一比对，'
                '得到"0 位错"的结论。')
    BULLET(doc, '用独立算法交叉验证。频谱判据由 check_peaks.py 用 FFT + Blackman 窗实现，'
                '另用 Goertzel 算法（一种完全不同的频率检测方法）对若干谱峰做了复核，'
                '两种方法结论一致。')
    BULLET(doc, '用客观资源变化证明功能真的接入了通路。'
                '"代码里写了"不等于"在数据通路上生效" —— 未使用的逻辑会被综合器优化掉。'
                '本项目的两个实例：包络接入前后 DSP 由 0 变 1；'
                '换用多音色 ROM 后 BSRAM 由 2 块降为 1 块。'
                '这类资源变化比"代码里写了"有说服力得多。')

    H(doc, 3, '3.3.2 证据的可追溯性')

    PARA(doc, '仿真产物是"活文件"—— 运行期间会被重写。若在写入过程中读取，'
              '会得到自相矛盾的结论（本项目实测：同一文件先后读出 6.83 dB 与 '
              '13/32 两种结果）。因此建立了如下取证纪律：')

    TABLE(doc,
          ['纪律', '做法', '为什么'],
          [
              ['先快照再分析', '复制到独立文件后再分析，绝不对运行中的文件取数',
               '避免读到半写状态'],
              ['记录指纹', '每个证据文件记录字节数 + mtime + SHA256',
               'RTL 一改，旧证据就作废；没有指纹就无法判断证据对应哪版代码'],
              ['判据独立成脚本', 'check_peaks.py / check_pitch_shift.py 与设计解耦',
               '判据自己也会错 —— 本项目就修过两次判据（--fs 默认值、整数网格）'],
              ['结论附原始输出', '任何"通过"都附退出码与关键数字',
               '避免"看起来成功"'],
          ],
          widths=[3.0, 6.4, 5.6])

    H(doc, 3, '3.3.3 被验证过程抓出的真实缺陷（举例）')

    PARA(doc, '下面几个缺陷都是"编译无错、波形看着正常"但实际错误的情况，'
              '全部是靠上述纪律发现的：')

    TABLE(doc,
          ['缺陷', '症状', '怎么发现的'],
          [
              ['32 路只有 31 个谱峰',
               '6400 Hz 那一路永远缺失',
               'FFT 命中数比期望少 1；根因是地址 MUX 只走到倒数第二路'],
              ['200 Hz 电平高 9.74 dB',
               '某一路被查表 3 次而非 1 次（20log10(3)=9.54 dB，与实测吻合）',
               '按路统计查表次数，做直方图'],
              ['87 个谐波杂散',
               '32 路求和后溢出被限幅，产生大量奇次谐波',
               '看未预期谱峰计数；根因是混音缩放系数取得过小'],
              ['ADSR 听不出包络',
               '起音实测仅 40.96 µs（= 2 个采样点），而注释写"≈42 ms"',
               '把时长按公式实算，发现与注释差 1000 倍；根因是计数器位宽限死了分频上限'],
              ['32 谱峰判据突然全 FAIL',
               '信号幅值从 ±18000 掉到 ±1200，直流偏置严重',
               '对比 min/max/std 的数据形态；根因是新加的变调乘法高位被截断'
               '（32 位容纳不下 44 位乘积）'],
              ['BCK 高电平低于 DAC 手册最小值',
               'BCK 高电平实测 20 ns，而 PT8211 手册对高电平时间 tH 要求 ≥25 ns；'
               'DIN 在 BCK 上升沿被锁存，高电平过短可能锁存失败 ⇒ 上板可能没声音',
               '把 BCK 高电平时间【量出来】才发现（20 vs 25 ns）。'
               '波形截图上完全看不出来 —— 肉眼只看到"有个高电平"。'
               '已改为占 2 个相位 = 40 ns，周期与采样率不变；'
               '并把"高电平 ≥ 手册 tH"固化进 tb_pt8211_final 的判据'],
          ],
          widths=[3.4, 6.6, 5.0])

    PARA(doc, '这些缺陷的共同点：**它们都不影响编译，也不影响"波形看起来对不对"**。'
              '只有把"期望值"算出来、和实测值逐项比对，才会暴露。'
              '这也是我们把验证方法单独成节的原因。')

    H(doc, 3, '3.3.4 基础要求①（多维交互）的功能验证')

    PARA(doc, '在写完交互逻辑之后，我们一度只有"编译通过 + 12 个引脚全部 constrained=Y"'
              '作为该项要求的证据。但那只证明【接线对了】，不证明【功能对了】——'
              '按键按下究竟有没有让 gate 变高、包络有没有真的起音、换音色有没有生效，'
              '都还没有验证过。对一项【基础要求】来说这是不够的。')

    PARA(doc, '为此新增 tb_interaction.v。它把顶层用 TEST_MODE=0（演奏模式）例化，'
              '从而真正测到"按键 → 两级同步 → 去抖 → gate → ADSR 包络"这条通路。'
              '（原先 TEST_MODE 是文件级 localparam、测试台无法覆盖，'
              '已改为模块参数——默认值不变，正式构建行为不受影响。）')

    TABLE(doc,
          ['#', '验证内容', '实测结果'],
          [
              ['1', '复位后应静音', 'gate=0、包络电平=0'],
              ['2', '抖动用例：key 快速通断 10 次（每次远短于去抖窗）',
               '去抖后状态不变 —— 去抖生效'],
              ['3', '按住 key', 'gate 变为全 1、去抖后 key_db=1'],
              ['4', '包络起音', '电平 25 280 → 55 808（递增）'],
              ['5', '按住 key 期间按 key2 换音色',
               '音色号 +1，且 gate 仍为全 1'],
              ['6', '按住 key 期间按第三键变调',
               'pitch_semi 由 0 变 +1，且 gate 仍为全 1'],
              ['7', '松开 key', 'gate 归 0'],
              ['8', '包络释放', '电平 49 120 → 39 744（递减）'],
              ['9', '连按 4 下切换键', '音色号 1→2→3→0，回到起点（4 档循环）'],
          ],
          widths=[1.2, 7.0, 6.8])

    PARA(doc, '其中第 5、6 项是"独立可控维度"的关键证据：'
              '**在按住发声的过程中换音色或变调，gate 不受任何影响** ——'
              '说明三个维度互不干扰，是真正独立的控制通道，'
              '而不是"同一个开关的不同写法"。')


    H(doc, 3, '3.3.5 一键复现')

    PARA(doc, '全部验证步骤已收敛成一个脚本，任何人可复现：')
    CODE(doc, 'powershell -NoProfile -ExecutionPolicy Bypass -File tools\\verify\\run_acceptance.ps1')
    PARA(doc, '该脚本依次执行：前置检查 → 构建 → 全部仿真 → 32 谱峰判据 → 变调判据 '
              '→ 波形数据集核对 → 交付物清单，并打印 PASS/FAIL 汇总。'
              '最近一次完整运行结果：构建 74.8 秒、12 引脚全部 constrained、时序零违例；'
              '32 谱峰判据 exit 0；变调判据 exit 0。')

    doc.add_page_break()

    # ==================== 四、作品总结 ====================
    H(doc, 1, '四、作品总结')

    H(doc, 2, '4.1 已完成的工作')
    BULLET(doc, '打通高云 Gowin EDA 的全链路命令行构建流程（综合→布局布线→码流生成→烧录工具链），'
                '并记录了工具链的若干实测坑位（见附录）。构建实测 74.8 秒，'
                '12 个引脚全部按约束分配，时序零违例。')
    BULLET(doc, '实现并验证 PT8211 I2S 发送器：逐位解码 0 位错，BCK 上升沿间隔恒 320 ns，'
                'fs = 97 656.25 Hz（96 kHz 档，评分乘数较 48 kHz 翻倍）。')
    BULLET(doc, '实现 32 路独立振荡器组（每路独立相位累加器 + 独立频率字 + 独立包络）、'
                '逐路 ADSR 包络、4 音色波表与混音限幅，'
                '并通过频谱取证证明「32 路 → 32 个独立谱峰」。')
    BULLET(doc, '实现多维交互检测（基础要求①）：两个板载按键（AB13/Y12）'
                '分别作演奏触发与音色切换，另用 PMOD 排针外接第三个按键作半音变调 —— '
                '属赛题要求的"自研交互形态"（未使用现成键盘）。'
                '两键均做两级同步 + 2.621 ms 去抖。')
    BULLET(doc, '实现单音实时变调（基础要求③）：运行时半音变调（-8~+7 半音），'
                '实测 32 个谱峰整体移动 2^(7/12) 倍，平均相对误差 0.014%。')
    BULLET(doc, '建立了一套可复现的验证方法（见 3.3 节）：逐位解码、直方图统计、'
                '绝对电平测量、FFT 谱峰判据、资源变化佐证；'
                '并收敛成一键验收脚本 run_acceptance.ps1。')

    H(doc, 2, '4.2 后续工作')
    BULLET(doc, '【唯一的主要缺口】在真实开发板上完成上板验证：'
                '烧录 bitstream、确认发声、并采集真板频谱证据（赛题要求现场取证）。'
                '烧录工具链与脚本已就绪（tools/gowin/program.ps1），'
                '经实测支持本板器件 GW5AST-138C，但"实际烧录"必须上板才能确认。')
    BULLET(doc, '把测试模式的频谱证据从"仿真导出"升级为"真板录音 + 同一套判据复核"，'
                '以便现场演示时直接给出可听可看的证据。')
    BULLET(doc, '电容触摸检测模块（rtl/io/touch_pad.v）当前仿真未通过，'
                '且未接入顶层、无引脚约束，不影响主 bitstream；'
                '若后续要把它作为第 4 个交互维度，需先修好其仿真。')
    BULLET(doc, '拓展项：硬件效果器（混响/延迟/合唱）、≥3 维表情（力度/滑音/颤音）、'
                '低延迟可视化。当前资源余量充足（LUT 仅用 4%、BSRAM 1/340），具备实现条件。')
    BULLET(doc, '补充设计框图、流程图、实物照片与演示视频。')

    H(doc, 2, '4.3 附录：开发中记录的关键坑位（部分）')
    TABLE(doc,
          ['编号', '坑位', '后果与对策'],
          [
              ['1', 'gw_sh 的 -synthesis_tool 只接受小写 gowinsynthesis',
               '大写会报 unknown synthesis tool 并中断脚本；官方 PDF 示例即为此坑'],
              ['2', '.tcl 文件带 UTF-8 BOM',
               '首条命令被解析为 invalid command name "??oreach"'],
              ['3', 'Verilog 负数字面量写法',
               '必须写 -16\'sd10278，写 16\'sd-10278 是非法语法'],
              ['4', 'Python str.format 与 Verilog 花括号冲突',
               '代码生成器必须用自定义占位符替换，不能用 format'],
              ['5', '顶层悬空输出导致模块被优化掉',
               'Gowin 报 NL0002 swept in optimizing，功能静默消失'],
              ['6', '混音缩放系数取得过小',
               '32 路求和溢出被限幅，产生 87 个谐波杂散'],
              ['7', '每声部数组只能有一个写语句',
               '从多处写会被推断成双口 RAM 并报莫名的写模式错误'],
          ],
          widths=[1.4, 6.0, 8.6])

    # ==================== 保存 ====================
    here = os.path.dirname(os.path.abspath(__file__))
    # 脚本在 tools/gen/ 下 → 上三级才到 fpga_hank/，再进 docs/
    outdir = os.path.normpath(os.path.join(here, '..', '..', 'docs'))
    os.makedirs(outdir, exist_ok=True)
    dst = os.path.join(outdir, '技术文档.docx')
    doc.save(dst)
    print('已生成:', dst)
    print('大小: %.1f KB' % (os.path.getsize(dst) / 1024))
    print('段落数: %d  表格数: %d' % (len(doc.paragraphs), len(doc.tables)))


if __name__ == '__main__':
    main()
