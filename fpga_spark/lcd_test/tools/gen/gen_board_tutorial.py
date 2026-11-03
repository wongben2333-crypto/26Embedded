# -*- coding: utf-8 -*-
r"""gen_board_tutorial.py —— 生成《Tang Mega 138K 保姆级上手指南》Word 文档

★ 事实来源（全部本机实测或官方资料，不臆造）：
  · 板卡/器件/资源          —— AGENTS.md §2（已核对官方 .cst 与器件库）
  · 引脚                    —— constr/fpga_hank.cst 实跑 P&R 逐个验证（12 个全 constrained=Y）
  · 供电/开机               —— docs/上板验证指南.md §2
  · 烧录命令                —— tools/gowin/program.ps1（参数取自 programmer_cli --help 实测）
  · 驱动路径                —— 实测存在 Programmer\driver\GowinUSBCableDriverV5_for_win7+.exe
  · LED 含义                —— rtl/top.v L295–316 实际驱动代码
  · 位流与资源              —— 本机两次真实构建的 .rpt.txt
  · PT8211 时序             —— 原厂 PTC V1.7 AC Characteristics（提取文本）
"""
from __future__ import annotations

import os
import sys

from docx import Document
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Cm, Pt, RGBColor

sys.stdout.reconfigure(encoding='utf-8')

CN = '微软雅黑'
MONO = 'Consolas'
BLUE = (0x1F, 0x3B, 0x73)
BLUE2 = (0x2E, 0x5C, 0x9A)
RED = (0xC0, 0x30, 0x20)
GREEN = (0x1E, 0x7A, 0x35)

A4_W_CM, A4_H_CM = 21.0, 29.7


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


def PARA(doc, text, size=10.5, bold=False, indent=True, color=None):
    p = doc.add_paragraph()
    p.paragraph_format.space_after = Pt(4)
    p.paragraph_format.line_spacing = 1.25
    if indent:
        p.paragraph_format.first_line_indent = Pt(21)
    r = p.add_run(text)
    style_run(r, size=size, bold=bold, color=color)
    return p


def BULLET(doc, text, size=10.5):
    p = doc.add_paragraph(style='List Bullet')
    p.paragraph_format.space_after = Pt(2)
    r = p.add_run(text)
    style_run(r, size=size)
    return p


def NUM(doc, text, size=10.5):
    p = doc.add_paragraph(style='List Number')
    p.paragraph_format.space_after = Pt(2)
    r = p.add_run(text)
    style_run(r, size=size)
    return p


def CODE(doc, text):
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(4)
    p.paragraph_format.space_after = Pt(6)
    p.paragraph_format.left_indent = Pt(12)
    r = p.add_run(text)
    style_run(r, size=9, mono=True)
    return p


def NOTE(doc, text, color=RED):
    p = doc.add_paragraph()
    p.paragraph_format.space_after = Pt(4)
    p.paragraph_format.left_indent = Pt(12)
    r = p.add_run(text)
    style_run(r, size=10, bold=True, color=color)
    return p


def TABLE(doc, headers, rows, widths=None):
    t = doc.add_table(rows=1, cols=len(headers))
    t.style = 'Light Grid Accent 1'
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
        avail = A4_W_CM - 2.6 * 2
        total = float(sum(widths))
        if total > avail:
            k = (avail * 0.98) / total
            widths = [w * k for w in widths]
        for i, w in enumerate(widths):
            for row in t.rows:
                row.cells[i].width = Cm(w)
    return t


def main():
    doc = Document()
    for s in doc.sections:
        s.page_width = Cm(A4_W_CM)
        s.page_height = Cm(A4_H_CM)
        s.top_margin = Cm(2.2)
        s.bottom_margin = Cm(2.2)
        s.left_margin = Cm(2.6)
        s.right_margin = Cm(2.6)

    # ============================== 封面 ==============================
    for _ in range(4):
        doc.add_paragraph()
    p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r = p.add_run('Tang Mega 138K 开发板'); style_run(r, size=26, bold=True, color=BLUE)
    p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r = p.add_run('保姆级上手指南'); style_run(r, size=22, bold=True, color=BLUE)
    p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r = p.add_run('—— 从「板子刚拆封」到「耳机里听到声音」——')
    style_run(r, size=12, color=BLUE2)
    for _ in range(3):
        doc.add_paragraph()
    p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r = p.add_run('配套项目：2026 FPGA 创新设计赛道·选题二\n「基于 FPGA 的实时多音色合成电子乐器引擎」')
    style_run(r, size=11)
    p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r = p.add_run('2026-10-05'); style_run(r, size=10, color=(0x66, 0x66, 0x66))
    doc.add_page_break()

    # ============================== 写在前面 ==============================
    H(doc, 1, '写在前面：这份教程假设你什么都不会')

    PARA(doc, '这份文档假设：你手上有一块 Tang Mega 138K 开发板，'
              '但你**从没用过 FPGA、不知道什么叫位流、也没烧过板子**。'
              '所有术语第一次出现时都会解释。')

    PARA(doc, '跟着做完，你会得到三样东西：')
    NUM(doc, '板子能跑起来（LED 会动）—— 证明板子和电脑连线是通的；')
    NUM(doc, '耳机里能听到声音 —— 证明我们写的音频引擎真的在工作；')
    NUM(doc, '知道出了问题该查哪里 —— 大部分人卡住都是卡在同样的几个地方。')

    NOTE(doc, '⚠️ 一句实话先放在这里：', RED)
    PARA(doc, '本文里凡是标注 **[已实测]** 的，是我们真在这台电脑上跑过、有原始输出的；'
              '凡是标注 **[需你在板上确认]** 的，是**我们还没有板子、没执行过**的 —— '
              '请以你眼前板子的实际现象为准，不要当成已经验证过的事实。', color=RED)

    # ============================== 第一章 ==============================
    doc.add_page_break()
    H(doc, 1, '第一章　先认识这块板子')

    H(doc, 2, '1.1 FPGA 是什么（一句话版）')

    PARA(doc, '普通芯片（比如单片机）出厂时功能就定死了；'
              '**FPGA 是一块「可以变成任何数字电路」的芯片** —— '
              '你把电路描述写成代码，烧进去，它就真的变成那块电路。'
              '可以理解成「数字电路版本的橡皮泥」。')

    PARA(doc, '所以我们做电子乐器，不是"写个程序让 CPU 算声音"，'
              '而是**让 FPGA 真的变成一台乐器**：32 个振荡器是 32 份真实的电路，'
              '同时、并行地在跑。这也是赛题的要求（禁止用 CPU 算音频）。')

    H(doc, 2, '1.2 你手里这块板子的关键参数')

    TABLE(doc,
          ['项目', '参数', '说明'],
          [
              ['板卡型号', 'Sipeed Tang Mega 138K Dock', 'Dock = 带扩展底板的大板'],
              ['FPGA 芯片', 'GW5AST-138C（高云半导体）', '国产 FPGA'],
              ['逻辑资源', '138 240 个 LUT4', '我们现在只用了约 6 000 个（5%）'],
              ['音频输出', '板载 PT8211 芯片 + 3.5 mm 耳机口', '★ 声音从这里出来'],
              ['用户按键', '2 个（板上）', 'AB13 / Y12'],
              ['用户 LED', '4 个', 'T18 / R18 / R17 / P16'],
              ['供电', '12V DC，或双 USB 5V', '★ 见第二章，这里最容易出问题'],
          ],
          widths=[3.0, 6.0, 7.0])

    H(doc, 2, '1.3 板子上你要认识的几个地方')

    PARA(doc, '不用记型号，只要找到这几个"口"就行（位置请对照你的板子）：')

    TABLE(doc,
          ['找什么', '长什么样 / 在哪', '干什么用'],
          [
              ['PWR 按键', '一个丝印 PWR 的小按钮', '★ 开机要靠它（长按）'],
              ['DEBUG-USB 口', '标注 DEBUG-USB / UART 的 USB 口', '★ 烧录走这个口'],
              ['USB3.0 口', '标注 USB3.0 的口', '供电 / 高速传输'],
              ['12V 电源座', '圆孔 DC 座', '用 12V 适配器供电时插这里'],
              ['3.5 mm 耳机口', '标 HP / 耳机图标的圆孔', '★ 插耳机听声音'],
              ['4 个 LED', '一排小灯', '程序在跑就会动'],
              ['2 个按键', '标 KEY / USER 的按钮', '我们用它演奏'],
              ['PMOD 排针', '两排 2.54 mm 插针', '外接我们的第 3 个按键'],
          ],
          widths=[3.2, 6.4, 6.4])

    NOTE(doc, '📌 一句话记住：烧录用 DEBUG-USB 口，听声音用耳机口，开机长按 PWR。')

    # ============================== 第二章 ==============================
    doc.add_page_break()
    H(doc, 1, '第二章　接线与开机（最容易翻车的一步）')

    H(doc, 2, '2.1 需要准备的东西')

    BULLET(doc, 'Tang Mega 138K Dock 开发板 × 1')
    BULLET(doc, 'USB 线 × 2（★ 很重要，理由见 2.3）')
    BULLET(doc, '3.5 mm 耳机 × 1（没有耳机也能做前几步，但听不到声音）')
    BULLET(doc, '电脑（Windows，已装 Gowin EDA V1.9.12.04）')

    H(doc, 2, '2.2 接线步骤')

    NUM(doc, '把 **USB 线 ①** 插到板子的 **DEBUG-USB 口**，另一端插电脑。'
             '（这个口负责烧录，也提供一部分电）')
    NUM(doc, '把 **USB 线 ②** 插到板子的 **USB3.0 口**，另一端插电脑。'
             '（这个口主要提供电）')
    NUM(doc, '（可选，效果更好）如果有 12V 电源适配器，插到 **12V DC 座**，'
             '这样就不需要插两根 USB 了。')
    NUM(doc, '把 **耳机插进 3.5 mm 耳机口**。')

    H(doc, 2, '2.3 ★ 为什么一定要"双供电"')

    NOTE(doc, '⚠️ 只插一根 USB 线供电，板子会「掉电重启」。', RED)

    PARA(doc, '现象是：**灯灭了又重新依次亮起来，或者程序跑到一半突然从头开始**。')

    PARA(doc, '这个坑最坑的地方在于：它会让你误以为"程序有 bug"，'
              '然后花几个小时去查代码 —— 实际上代码没问题，是电不够。'
              '**先确认供电稳了，再开始调程序。**')

    PARA(doc, '对策（任选一种）：')
    BULLET(doc, 'USB3.0 口 + DEBUG-USB 口同时插（官方推荐，双路 5V）')
    BULLET(doc, '用 12V DC 电源适配器（最稳）')

    H(doc, 2, '2.4 开机')

    NUM(doc, '接线确认无误后，**长按板上的 `PWR` 按键约 2 秒**。')
    NOTE(doc, '  ⚠️ 短按不开机。要按住约 2 秒。', RED)
    NUM(doc, '松手后，板上 LED 应该亮起来。')

    H(doc, 2, '2.5 装 USB 驱动（如果电脑认不出板子）')

    PARA(doc, '如果后面烧录时"扫不到设备"，多半是驱动没装。'
              '驱动就在 Gowin 的安装目录里：')

    CODE(doc, 'F:\\Gowin\\Gowin_V1.9.12.04_x64\\Programmer\\driver\\\n'
              '    GowinUSBCableDriverV5_for_win7+.exe')

    PARA(doc, '双击运行、一路下一步即可（需要管理员权限）。')

    # ============================== 第三章 ==============================
    doc.add_page_break()
    H(doc, 1, '第三章　第一次烧录（命令行版，最省事）')

    H(doc, 2, '3.1 什么是"烧录"')

    PARA(doc, '前面说过 FPGA 是"橡皮泥"。**烧录（下载）就是把电路图纸塞进 FPGA 的动作。**')

    PARA(doc, '那个"图纸"是一个文件，扩展名 `.fs`（叫 **位流 / bitstream**）。'
              '我们要做的就是把 `.fs` 送进板子。')

    H(doc, 2, '3.2 烧录工具有两种，我们用命令行的')

    BULLET(doc, '**图形界面**：Gowin Programmer（点鼠标，直观但步骤多）')
    BULLET(doc, '**命令行**：我们写好了脚本，一条命令搞定 ★ 推荐')

    PARA(doc, '命令行脚本在：')

    CODE(doc, r'fpga_hank\tools\gowin\program.ps1')

    H(doc, 2, '3.3 第 1 步：确认电脑能认出板子')

    PARA(doc, '打开 PowerShell，切到 `fpga_hank` 目录，执行：')

    CODE(doc, r'powershell -NoProfile -ExecutionPolicy Bypass -File '
              r'tools\gowin\program.ps1 -Mode scan')

    PARA(doc, '**看输出判断**：')

    TABLE(doc,
          ['看到什么', '说明', '怎么办'],
          [
              ['`No Gowin devices found`',
               '没找到器件', '查 3.5 的排查清单'],
              ['列出了器件（含 GW5AST-138C）',
               '★ 成功，链路通了', '继续 3.4'],
          ],
          widths=[6.5, 4.5, 5.0])

    NOTE(doc, '💡 我们已经试过：就算【不插板子】，这个命令也会明确报 '
              '`No Gowin devices found` —— 说明工具本身是好的，报错只是因为没板子。'
              '所以你能明确区分"工具坏了"和"板子没连上"。')

    H(doc, 2, '3.4 第 2 步：把位流送进去')

    PARA(doc, '我们**已经预先构建好两个位流**，你不用自己编译（编译一次约 1.5 分钟）：')

    TABLE(doc,
          ['文件', '是什么', '什么时候用'],
          [
              ['`out\\bitstream\\fpga_hank_TESTMODE0_演奏模式.fs`',
               '演奏模式', '★ 先烧这个，为了听声音'],
              ['`out\\bitstream\\fpga_hank_TESTMODE1_测试模式.fs`',
               '测试模式', '后面做 32 谱峰取证时用'],
          ],
          widths=[7.5, 3.0, 5.5])

    NOTE(doc, '⚠️ 这两个文件在 fpga_hank 目录下，不在 26Embedded 仓库里'
              '（它们各 33 MB，不进版本库）。如果找不到，看本章 3.6 自己构建。', RED)

    PARA(doc, '执行烧录（**先烧演奏模式**）：')

    CODE(doc, 'powershell -NoProfile -ExecutionPolicy Bypass -File '
              'tools\\gowin\\program.ps1 -Mode sram `\n'
              '    -Fs out\\bitstream\\fpga_hank_TESTMODE0_演奏模式.fs')

    PARA(doc, '等进度条走完即可（约 10~30 秒）。')

    H(doc, 2, '3.5 没找到器件时的排查清单')

    NUM(doc, '板子**开机了吗**？（长按 PWR 约 2 秒，灯亮才算）')
    NUM(doc, 'USB 线插的是 **DEBUG-USB 口**吗？（不是只供电的那个口）')
    NUM(doc, '**驱动装了吗**？（见 2.5）')
    NUM(doc, '**供电够吗**？（单根 USB 会掉电重启，见 2.3）')
    NUM(doc, '**是不是有别的程序占着**？（Gowin Programmer 图形界面、'
             '另一个烧录脚本都可能占用 —— 同时只能有一个程序访问下载线）')

    H(doc, 2, '3.6 想自己构建位流（可选）')

    CODE(doc, r'& "F:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe" '
              r'tools\gowin\build.tcl')

    PARA(doc, '约 85 秒后，产物在 `eda_proj\\fpga_hank\\impl\\pnr\\fpga_hank.fs`。')

    NOTE(doc, '★ 想切换"演奏模式 / 测试模式"，改 `rtl\\top.v` 里的 '
              '`parameter integer TEST_MODE`（0 = 演奏，1 = 测试），然后重新构建。')

    # ============================== 第四章 ==============================
    doc.add_page_break()
    H(doc, 1, '第四章　第一次听到声音')

    H(doc, 2, '4.1 操作')

    NUM(doc, '确认烧的是**演奏模式**位流（`TESTMODE0_演奏模式.fs`）')
    NUM(doc, '耳机插好，戴上一只耳朵')
    NUM(doc, '**按住板上的按键 `key`（丝印见 1.3，引脚 AB13）**')
    NOTE(doc, '  ★ 按住不放，等一两秒', GREEN)
    NUM(doc, '应该听到**持续的声音**')
    NUM(doc, '松开按键 → 声音应该**平滑地消失**（不是"啪"地断掉）')

    H(doc, 2, '4.2 没声音？按这个顺序查')

    TABLE(doc,
          ['#', '检查什么', '怎么确认'],
          [
              ['1', 'LED 在动吗', '`led[0]` 应该一直在闪。**不闪 = 时钟或配置没生效**，'
                                  '问题在烧录/时钟，不在音频通路'],
              ['2', '烧的是演奏模式吗', '测试模式下按键**无效**，但会持续发声'],
              ['3', '耳机插对孔了吗', '板上可能不止一个 3.5mm 孔'],
              ['4', '音量', '声音是数字合成的固定幅度，'
                            '如果完全没声，不是音量问题'],
              ['5', '供电稳吗', '单根 USB 会掉电重启（见 2.3）'],
              ['6', '功放使能', '`PA_EN`(AB16) 是**低有效**，代码里已常拉低；'
                                '接线不用管'],
              ['7', '还是不行', '转 `docs\\上板验证指南.md`，用 S0→S6 分级排障二分定位'],
          ],
          widths=[1.0, 3.6, 11.4])

    H(doc, 2, '4.3 ★ 4 个 LED 分别是什么意思')

    PARA(doc, '这四个灯是我们自己定义的（不是板子固定的），含义来自代码：')

    TABLE(doc,
          ['LED', '引脚', '亮/闪表示'],
          [
              ['`led[0]`', 'T18', '**在闪 = 逻辑在跑**（心跳）'],
              ['`led[1]`', 'R18', '亮 = 采样帧在流动（音频数据在走）'],
              ['`led[2]`', 'R17', '亮 = **有音符在发声**（任一通道被按下）'],
              ['`led[3]`', 'P16', '亮 = 包络在非静音阶段（**ADSR 真的在工作**）'],
          ],
          widths=[2.0, 2.0, 12.0])

    NOTE(doc, '📌 按 key 的时候，应该看到 `led[2]`、`led[3]` 有变化；'
              '`led[0]` 应该一直在闪。')

    # ============================== 第五章 ==============================
    doc.add_page_break()
    H(doc, 1, '第五章　玩起来：三个按键')

    PARA(doc, '我们的乐器有**三个独立的控制维度**（这是赛题的硬性要求）。')

    TABLE(doc,
          ['按键', '引脚', '在哪', '按下会怎样'],
          [
              ['`key`', 'AB13', '板上', '**按住 = 发声**（32 个振荡器齐发）；松开 = 进入衰减'],
              ['`key2`', 'Y12', '板上', '**每按一下换一种音色**，4 种循环'],
              ['`key_pitch`', 'Y22', '★ **PMOD 排针，需要自己接**',
               '**每按一下升 1 个半音**（-8~+7 循环，按 8 下回原调）'],
          ],
          widths=[2.4, 1.8, 4.6, 8.2])

    H(doc, 2, '5.1 第三个按键怎么接（板上没有这个按钮）')

    PARA(doc, '板上只有 2 个现成按键，但赛题要求"自研交互形态"——'
              '所以我们**用 PMOD 排针外接一个按钮**。这正好符合赛题要求。')

    PARA(doc, '接法（很简单，不需要电阻）：')

    NUM(doc, '找一个按钮（面包板按钮、杜邦线接的轻触开关都行）')
    NUM(doc, '按钮的**一端接到 PMOD 排针的 `Y22` 脚**')
    NUM(doc, '按钮的**另一端接板子的 `GND`**')
    NUM(doc, '不用外接电阻 —— 引脚内部已经上拉，按下就是 0')

    NOTE(doc, '💡 找不到 Y22 在哪？看 `fpga_hank\\constr\\fpga_hank.cst`，'
              '里面写了每个信号对应哪个物理引脚。', GREEN)

    H(doc, 2, '5.2 推荐的演示顺序（正好证明"三维度独立"）')

    NUM(doc, '**按住 `key`** → 听到持续音（默认是正弦，音色最干净）')
    NUM(doc, '**按住 `key` 不松，再按 `key2`** → 音色变了，'
             '**但声音没有断** ← ★ 这证明两个维度是独立的')
    NUM(doc, '**继续按住 `key`，再按 `key_pitch`** → 音高升了半音，'
             '**声音依然没断** ← ★ 第三个维度也独立')
    NUM(doc, '**松开 `key`** → 声音平滑衰减消失（约 63 毫秒）')

    NOTE(doc, '★ 第 2、3 步是关键：如果换音色时声音断了，说明两个控制维度'
              '互相干扰，那就不算"独立可控"。我们的代码在仿真里验证过这一点'
              '（`sim\\tb\\tb_interaction.v`，9 项全通过）。')

    # ============================== 第六章 ==============================
    doc.add_page_break()
    H(doc, 1, '第六章　32 个谱峰取证（赛题必备交付物）')

    PARA(doc, '赛题**明确要求**：要有一个"测试模式"，能输出 N 个不同频率的声音，'
              '用频谱数得出 N 根独立的柱子。这是**必备项，不能省**。')

    PARA(doc, '我们做的是 **32 个频率**：200 Hz、400 Hz、600 Hz …… 一直到 6400 Hz，'
              '每个间隔 200 Hz。')

    H(doc, 2, '6.1 先确认判据工具是好的（不需要板子）')

    CODE(doc, 'python tools\\verify\\check_peaks.py '
              '--file docs\\evidence\\tone_samples_pitch0.txt `\n'
              '    --format samples --fs 97656.25 --count 32 --start 200 --step 200')

    PARA(doc, '应该输出 `PASS`（32/32 命中）。如果你看到 PASS，'
              '说明**判据工具本身是好的**，后面真板录音若 FAIL，问题在录音，不在工具。')

    H(doc, 2, '6.2 用真板录音')

    NUM(doc, '烧**测试模式**位流：`fpga_hank_TESTMODE1_测试模式.fs`')
    NUM(doc, '耳机口用音频线接到电脑的 **Line-in（线路输入）**；'
             '没有线就用手机**贴着耳机录**')
    NUM(doc, '**录 5 秒以上**，存成 wav 文件')
    NUM(doc, '把录音转成文本样本（一行一个数），或用工具直接读 wav')
    NUM(doc, '跑判据：')

    CODE(doc, 'python tools\\verify\\check_peaks.py --file <你的录音> --format samples `\n'
              '    --fs <你声卡的真实采样率> --count 32 --start 200 --step 200')

    NOTE(doc, '⚠️⚠️ `--fs` 必须填【录音设备真实的采样率】（常见 44100 或 48000），'
              '不能照抄上面的 97656.25！', RED)

    PARA(doc, '**为什么**：97656.25 Hz 是 FPGA 内部输出的采样率，'
              '但你的声卡录音时用的是它自己的采样率。填错了，整个频率轴会缩放，'
              '**32 个本来正确的峰会被全部判成"杂散"**。')

    NOTE(doc, '这是本项目真实踩过的坑，写进了 skill：`--fs` 漏传/填错 → 32 个峰全部 FAIL。')

    H(doc, 2, '6.3 应该看到什么')

    PARA(doc, '频谱图上出现 **32 根等间距的柱子**，位置大致在 200 / 400 / 600 …… 6400 Hz。'
              '如果能数出 32 根，这一项就过了。')

    # ============================== 第七章 ==============================
    doc.add_page_break()
    H(doc, 1, '第七章　烧到 Flash（让板子断电后还能记住）')

    H(doc, 2, '7.1 SRAM 和 Flash 的区别')

    TABLE(doc,
          ['', 'SRAM 下载', 'Flash 烧写'],
          [
              ['掉电后', '**忘记**，需要重新烧', '**记住**，一上电就自己跑'],
              ['写入次数', '无限（本来就是内存）', '有限（Flash 有寿命）'],
              ['速度', '快', '慢一些'],
              ['什么时候用', '★ **调试阶段一律用这个**', '最终演示、要"开机即用"时'],
          ],
          widths=[2.6, 6.4, 6.4])

    NOTE(doc, '★ 我们脚本默认就是 SRAM 下载 —— 这是故意的：'
              '**即使位流有问题，也不会把板子刷成"一上电就跑坏程序"的状态**。', GREEN)

    H(doc, 2, '7.2 写入 Flash')

    CODE(doc, 'powershell -NoProfile -ExecutionPolicy Bypass -File '
              'tools\\gowin\\program.ps1 -Mode flash `\n'
              '    -Fs out\\bitstream\\fpga_hank_TESTMODE0_演奏模式.fs')

    NOTE(doc, '⚠️ 这一步会**改写板上的 Flash**。建议先用 SRAM 模式反复确认'
              '位流没问题，再执行这一步。', RED)

    H(doc, 2, '7.3 一个"不需要板子"的验证技巧')

    CODE(doc, 'powershell -NoProfile -ExecutionPolicy Bypass -File '
              'tools\\gowin\\program.ps1 -Mode verify')

    PARA(doc, '这个模式会让烧录工具**解析我们的位流并生成一份标准 JTAG 向量文件**。'
              '它不需要板子，但能证明"位流本身是有效的、器件型号是匹配的"。')

    PARA(doc, '我们实测的结果：生成的文件 **9 258 660 字节 / 65 694 行**，'
              '并且从里面提取出了正确的器件 ID `h0001081B`。')

    # ============================== 第八章 ==============================
    doc.add_page_break()
    H(doc, 1, '第八章　出问题怎么办')

    H(doc, 2, '8.1 症状 → 原因 速查表')

    TABLE(doc,
          ['症状', '最可能的原因', '怎么办'],
          [
              ['长按 PWR 没反应、灯不亮',
               '供电不足 / 线没插好', '插两根 USB，或用 12V 电源'],
              ['灯亮了但过一会儿灭了又重新亮',
               '★ 供电不足导致掉电重启', '插两根 USB（见 2.3）'],
              ['烧录时扫不到设备',
               '驱动没装 / 插错口 / 被别的程序占用',
               '见 3.5 的 5 条排查'],
              ['烧录成功但 LED 不动',
               '烧错文件 / 时钟问题',
               '确认烧的是 `.fs` 位流；换一个位流试'],
              ['LED 在闪但没声音',
               '烧的是测试模式 / 耳机没插好',
               '烧演奏模式位流；按住按键；见 4.2'],
              ['有声音但按键没反应',
               '烧的是测试模式（按键无效）', '改烧演奏模式'],
              ['声音断断续续',
               '★ 供电不稳', '插两根 USB'],
              ['换音色时声音断了',
               '理论上不应该', '记录现象并反馈 —— 这是设计问题'],
          ],
          widths=[4.6, 4.6, 6.2])

    H(doc, 2, '8.2 一句话总结排查思路')

    NOTE(doc, '先看电，再看线，再看烧的哪个文件，最后才怀疑代码。', GREEN)

    PARA(doc, '按我们这一路踩坑的经验，**新手卡住的地方 90% 是供电和接线**，'
              '不是代码。这也是为什么这份教程花了整整一章讲接线。')

    # ============================== 附录 ==============================
    doc.add_page_break()
    H(doc, 1, '附录 A　引脚对照表（实测，全部已验证）')

    PARA(doc, '这张表是我们**逐个真跑布局布线验证过**的（12 个引脚全部被正确约束）：')

    TABLE(doc,
          ['信号名', '物理引脚', '方向', '作用'],
          [
              ['`clk`', 'V22', '输入', '50 MHz 板载晶振'],
              ['`led[0]`', 'T18', '输出', '心跳（在跑就闪）'],
              ['`led[1]`', 'R18', '输出', '采样帧在流动'],
              ['`led[2]`', 'R17', '输出', '有音符在发声'],
              ['`led[3]`', 'P16', '输出', '包络非静音'],
              ['`HP_BCK`', 'Y17', '输出', 'PT8211 I2S 位时钟'],
              ['`HP_WS`', 'AB17', '输出', 'PT8211 I2S 字选'],
              ['`HP_DIN`', 'AA16', '输出', 'PT8211 I2S 数据'],
              ['`PA_EN`', 'AB16', '输出', '功放使能（低有效，必须拉低才出声）'],
              ['`key`', 'AB13', '输入', '演奏触发（按下 = 0）'],
              ['`key2`', 'Y12', '输入', '音色切换（按下 = 0）'],
              ['`key_pitch`', 'Y22', '输入', '半音变调（PMOD 外接，按下 = 0）'],
          ],
          widths=[2.8, 2.4, 1.8, 9.0])

    NOTE(doc, '⚠️ 两个实测结论（避免你重复踩坑）：', RED)
    BULLET(doc, '**`U21` / `P19` / `Y21` 不能用** —— 在本板器件版本上它们是 '
                'CPU/SSPI 专用脚，布局器会直接报错。'
                '网上有些例程把这几个当 LED 用，那是**另一个器件版本**的写法，'
                '不能照搬。')
    BULLET(doc, '**`F4` 不要用** —— 它在 1.5V 电压域，混进本工程全 3.3V 的约束里'
                '会多一处失败可能。')

    H(doc, 1, '附录 B　术语表（看不懂的词查这里）')

    TABLE(doc,
          ['术语', '大白话解释'],
          [
              ['FPGA', '可以"变成任何数字电路"的芯片，像数字电路版的橡皮泥'],
              ['RTL / Verilog', '描述电路"长什么样"的代码语言。我们写的 `rtl\\*.v` 就是它'],
              ['综合（Synthesis）', '把 RTL 代码变成"电路门级连接"的过程'],
              ['布局布线（P&R）', '把电路门安排到芯片的具体位置上、并连好线'],
              ['位流 / bitstream / `.fs`', '最终产物，那个"电路图纸"文件，烧进 FPGA 用的'],
              ['烧录 / 下载', '把位流送进 FPGA 的动作'],
              ['SRAM / Flash', 'FPGA 内部内存 / 板上的外部存储。SRAM 掉电忘，Flash 记得住'],
              ['I2S', '一种传送数字音频的标准协议（三根线：位时钟/字选/数据）'],
              ['PT8211', '板上的音频 DAC 芯片，把数字信号变成模拟声音'],
              ['DAC', '数字转模拟。把 0/1 变成耳机里能听的电压波形'],
              ['振荡器', '产生音调的东西。我们有 32 个，所以能同时发 32 个音'],
              ['复音', '能同时发多少个音。32 复音 = 同时 32 个音'],
              ['ADSR', '音量的四个阶段：起音(Attack) / 衰减(Decay) / 保持(Sustain) / 释放(Release)'],
              ['包络', '音量的变化曲线。ADSR 就是最常见的包络'],
              ['采样率', '每秒产生多少个音频点。我们是 97 656.25 Hz'],
              ['频谱 / 谱峰', '把声音拆成"有哪些频率成分"。32 个音 = 32 根柱子（谱峰）'],
              ['testbench / 仿真', '"在电脑上模拟运行"电路，不用真板子就能验证逻辑'],
              ['ModelSim', '我们用的仿真软件'],
              ['Gowin EDA', '高云的 FPGA 开发软件（综合/布局布线/烧录都在里面）'],
          ],
          widths=[4.0, 11.0])

    H(doc, 1, '附录 C　我们做到了什么（现状说明）')

    PARA(doc, '这份教程配套的项目，目前的状态是：')

    TABLE(doc,
          ['项目', '状态'],
          [
              ['构建（综合→布局布线→位流）', '✅ 已实测，时序零违例，12 引脚全约束'],
              ['全部仿真验证', '✅ PT8211 逐位解码 0 错 / ADSR 9 项 / 交互 9 项 / 32 谱峰 32-32 / 变调误差 0.0144%'],
              ['两种工作模式综合', '✅ 演奏模式与测试模式都实测通过'],
              ['烧录工具链', '✅ 已实测（能解析位流、生成 JTAG 向量、提取器件 ID）'],
              ['**实际物理烧录**', '⬜ **还没做过** —— 需要板子在场'],
              ['**真板发声**', '⬜ **还没做过**'],
              ['**真板频谱取证**', '⬜ **还没做过**'],
          ],
          widths=[5.0, 10.0])

    NOTE(doc, '★ 最后三行是这份教程存在的意义：'
              '前四行我们已经在电脑上验证过了，'
              '**后三行需要你插上板子才能完成**。', GREEN)

    PARA(doc, '你做完之后，如果一切正常，我们就能把"真板频谱取证"这一项补上，'
              '赛题要求的必备交付物就齐了。')

    out = sys.argv[1] if len(sys.argv) > 1 else r'docs\138K开发板-保姆级上手指南.docx'
    doc.save(out)
    print('已生成: %s' % out)
    print('大小: %.1f KB' % (os.path.getsize(out) / 1024))
    print('段落 %d  表格 %d' % (len(doc.paragraphs), len(doc.tables)))


if __name__ == '__main__':
    main()
