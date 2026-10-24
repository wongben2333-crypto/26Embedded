# -*- coding: utf-8 -*-
"""
update_hardware_plan_pdf.py
为《硬件方案规划书-交互与传感器硬件.pdf》添加物料链接与附录采购指南
"""
import os
import fitz

BASE_DIR = r"C:\Users\gjl50\Desktop\嵌赛\fpga_spark"
PDF_BACKUP = os.path.join(BASE_DIR, "硬件方案规划书-交互与传感器硬件_v1.1_原始备份.pdf")
PDF_TARGET = os.path.join(BASE_DIR, "硬件方案规划书-交互与传感器硬件.pdf")
FONT_PATH = r"C:\Windows\Fonts\msyh.ttc"

def build_updated_pdf():
    doc = fitz.open(PDF_BACKUP)
    print("Loaded backup PDF, pages:", len(doc))

    # 1. 在第 10 页（物料清单表格）给各行添加超链接
    p10 = doc[9]
    table_links = [
        (198, 230, "https://yourcee.taobao.com/search.htm?q=12*12+%C7%E1%B4%A5%BF%AA%B9%D8"),
        (232, 248, "https://s.taobao.com/search?q=PLA+3D%E6%89%93%E5%8D%B0%E8%80%97%E6%9D%90"),
        (250, 266, "https://s.taobao.com/search?q=%E6%8C%89%E9%94%AE%E5%9B%9E%E5%BC%B9%E7%A1%85%E8%83%B6%E5%BC%B9%E7%B0%A7"),
        (268, 284, "https://yourcee.taobao.com/search.htm?q=%CD%AD%B1%40%BD%BA%B4%F8"),
        (286, 302, "https://yourcee.taobao.com/search.htm?q=1M+%B5%E7%D7%E8"),
        (304, 335, "https://s.taobao.com/search?q=VL53L4CD+%E6%A8%A1%E5%9D%97"),
        (337, 353, "https://yourcee.taobao.com/search.htm?q=HC-SR04P"),
        (355, 371, "https://yourcee.taobao.com/search.htm?q=%B2%DB%D0%CD%B9%E2%B5%E7"),
        (373, 389, "https://yourcee.taobao.com/search.htm?q=EC11+%B1%E0%C2%EB%C6%F7"),
        (391, 453, "https://yourcee.taobao.com/search.htm?q=ADS1115"),
        (455, 471, "https://yourcee.taobao.com/search.htm?q=MB-102+%C3%E6%B0%FC%B0%E5"),
        (473, 489, "https://yourcee.taobao.com/search.htm?q=%B6%C3%B0%EE%CF%DF"),
        (509, 525, "https://yourcee.taobao.com/search.htm?q=WS2812B"),
        (527, 543, "https://yourcee.taobao.com/search.htm?q=12V+2A+%B5%E7%D4%B4")
    ]
    for y0, y1, url in table_links:
        r = fitz.Rect(95, y0, 515, y1)
        p10.insert_link({"kind": fitz.LINK_URI, "from": r, "uri": url})
    print("Page 10 table links added.")

    # 2. 插入第 13 页：附录（推荐采购店铺、采购清单与购买链接汇总）
    p13 = doc.new_page(width=612, height=792)
    p13.insert_font(fontname="yahei", fontfile=FONT_PATH)

    # 绘制标题栏
    p13.draw_rect(fitz.Rect(40, 35, 572, 65), color=(0.15, 0.35, 0.75), fill=(0.92, 0.95, 1.0))
    p13.insert_text((50, 56), "十、附录：推荐店铺、物料清单与购买直达链接（核验版）", fontname="yahei", fontsize=13, color=(0.1, 0.25, 0.65))

    y = 80
    p13.insert_text((45, y), "10.1 核心推荐店铺及开票资质（完美支持高校财务报销）", fontname="yahei", fontsize=10.5, color=(0.8, 0.1, 0.1))
    y += 18
    stores = [
        ("① 优信电子（淘宝企业店）", "https://yourcee.taobao.com", "全国高校竞赛常用店，品类极全现货，可开正规高校抬头增值税电子普票。"),
        ("② 微雪电子（Waveshare 旗舰店）", "https://waveshare.taobao.com", "知名开源硬件厂商，工业级品质、提供完整原理图与 Wiki 文档，发票规范。"),
        ("③ 立创商城（嘉立创旗下自营）", "https://www.szlcsc.com", "100% 正品原装元器件，一键生成报销电子发票与销售明细清单。"),
        ("④ DFRobot 官方旗舰店", "https://dfrobot.taobao.com", "创客与高校竞赛知名品牌，提供 VL53L4CD 激光测距等高集成度模块。")
    ]
    for name, url, desc in stores:
        p13.insert_text((55, y), f"• {name}：", fontname="yahei", fontsize=9, color=(0.1, 0.1, 0.1))
        # 链接文字
        link_rect = fitz.Rect(200, y - 10, 360, y + 2)
        p13.insert_text((200, y), url, fontname="yahei", fontsize=9, color=(0.15, 0.45, 0.85))
        p13.insert_link({"kind": fitz.LINK_URI, "from": link_rect, "uri": url})
        p13.insert_text((370, y), f"- {desc[:16]}...", fontname="yahei", fontsize=8.5, color=(0.35, 0.35, 0.35))
        y += 16

    y += 8
    p13.insert_text((45, y), "10.2 采购清单与购买直达链接（点击名称或链接可直接跳转采购）", fontname="yahei", fontsize=10.5, color=(0.8, 0.1, 0.1))
    y += 18

    # 绘制表格表头
    p13.draw_rect(fitz.Rect(40, y - 12, 572, y + 6), color=(0.7, 0.7, 0.7), fill=(0.9, 0.92, 0.95))
    p13.insert_text((45, y), "物料名称 / 规格型号", fontname="yahei", fontsize=8.5, color=(0.1, 0.1, 0.1))
    p13.insert_text((180, y), "关键技术要求（赛题/平台符合性）", fontname="yahei", fontsize=8.5, color=(0.1, 0.1, 0.1))
    p13.insert_text((380, y), "店铺", fontname="yahei", fontsize=8.5, color=(0.1, 0.1, 0.1))
    p13.insert_text((430, y), "购买直达链接", fontname="yahei", fontsize=8.5, color=(0.1, 0.1, 0.1))
    p13.insert_text((535, y), "参考价", fontname="yahei", fontsize=8.5, color=(0.1, 0.1, 0.1))
    y += 18

    items = [
        ("VL53L4CD 激光ToF测距", "3.3V I2C, 100Hz刷新率, 手势连续变调", "淘宝/DF", "https://s.taobao.com/search?q=VL53L4CD+%E6%A8%A1%E5%9D%97", "35元"),
        ("LM393 槽型光电开关(5mm)", "板载迟滞比较器, 3.3V DO, <20us触发", "优信电子", "https://yourcee.taobao.com/search.htm?q=%B2%DB%D0%CD%B9%E2%B5%E7", "3.5元*8"),
        ("EC11 旋转编码器模块", "带按键, 15脉冲/30档, 集成上拉, 调参数", "优信电子", "https://yourcee.taobao.com/search.htm?q=EC11+%B1%E0%C2%EB%C6%F7", "4.5元*4"),
        ("12x12 轻触按键+键帽", "4脚直插, 独立接入, 首边沿锁存发声", "优信电子", "https://yourcee.taobao.com/search.htm?q=12*12+%C7%E1%B4%A5%BF%AA%B9%D8", "12元/包"),
        ("双面导电铜箔胶带(20mm)", "贴于键面作电容电极, 配合1M电阻", "优信电子", "https://yourcee.taobao.com/search.htm?q=%CD%AD%B1%40%BD%BA%B4%F8", "15元/卷"),
        ("1MΩ 金属膜电阻(1/4W)", "电容检测RC上拉, 限制电流测充放电", "优信电子", "https://yourcee.taobao.com/search.htm?q=1M+%B5%E7%D7%E8", "4元/包"),
        ("WS2812B 幻彩灯带(60灯)", "5V供电, 3.3V数据线直连, LED曲目指引", "优信电子", "https://yourcee.taobao.com/search.htm?q=WS2812B", "20元/米"),
        ("MB-102 830孔面包板", "2块拼接, 原型搭建, 2.54mm间距", "优信电子", "https://yourcee.taobao.com/search.htm?q=MB-102+%C3%E6%B0%FC%B0%E5", "9元*2"),
        ("彩虹杜邦线+排针排母", "公对母+母对母20cm, 40P直针/圆孔母", "优信电子", "https://yourcee.taobao.com/search.htm?q=%B6%C3%B0%EE%CF%DF", "15元/套"),
        ("12V 2A DC5521 电源适配器", "输入100-240V, 输出12V 2A, 确保系统稳定", "优信电子", "https://yourcee.taobao.com/search.htm?q=12V+2A+%B5%E7%D4%B4", "22元"),
        ("HC-SR04P 3.3V超声波(备选)", "3.3V宽压, Echo直接3.3V, 免分压", "优信电子", "https://yourcee.taobao.com/search.htm?q=HC-SR04P", "8元"),
        ("ADS1115 16位ADC模块(备选)", "I2C, 860SPS, 备选慢速模拟力度采集", "优信电子", "https://yourcee.taobao.com/search.htm?q=ADS1115", "16元")
    ]

    for name, spec, store, url, price in items:
        p13.draw_rect(fitz.Rect(40, y - 11, 572, y + 5), color=(0.85, 0.85, 0.85))
        p13.insert_text((45, y), name, fontname="yahei", fontsize=8, color=(0.1, 0.1, 0.1))
        p13.insert_text((180, y), spec, fontname="yahei", fontsize=7.5, color=(0.25, 0.25, 0.25))
        p13.insert_text((380, y), store, fontname="yahei", fontsize=8, color=(0.2, 0.2, 0.2))
        
        # 链接
        link_r = fitz.Rect(430, y - 9, 520, y + 3)
        p13.insert_text((430, y), "[点击直达购买]", fontname="yahei", fontsize=8, color=(0.1, 0.4, 0.8))
        p13.insert_link({"kind": fitz.LINK_URI, "from": link_r, "uri": url})
        
        p13.insert_text((535, y), price, fontname="yahei", fontsize=8, color=(0.7, 0.2, 0.1))
        y += 16

    y += 10
    # 底部提醒
    p13.draw_rect(fitz.Rect(40, y - 8, 572, y + 48), color=(0.9, 0.6, 0.2), fill=(1.0, 0.97, 0.9))
    p13.insert_text((50, y + 8), "重要提醒（电气安全与赛题指标）：", fontname="yahei", fontsize=8.5, color=(0.8, 0.2, 0.0))
    p13.insert_text((50, y + 24), "1. Tang Mega 60K/138K Dock 的所有 GPIO 引脚均为严格的 3.3V LVCMOS 电平，严禁外部模块向 FPGA 引脚输入 5V！", fontname="yahei", fontsize=7.5, color=(0.3, 0.1, 0.1))
    p13.insert_text((50, y + 38), "2. 槽型光电务必选择带 LM393 迟滞比较器版本；测距 ToF 必须选择 VL53L4CD（100Hz）以确保特雷门表情连贯流畅。", fontname="yahei", fontsize=7.5, color=(0.3, 0.1, 0.1))

    # 3. 插入第 14 页：店家咨询话术与发票报销模板
    p14 = doc.new_page(width=612, height=792)
    p14.insert_font(fontname="yahei", fontfile=FONT_PATH)

    p14.draw_rect(fitz.Rect(40, 35, 572, 65), color=(0.15, 0.35, 0.75), fill=(0.92, 0.95, 1.0))
    p14.insert_text((50, 56), "十一、附录：向店家核验参数与高校发票开具沟通指南", fontname="yahei", fontsize=13, color=(0.1, 0.25, 0.65))

    y = 85
    p14.insert_text((45, y), "11.1 向店家客服确认技术参数话术模板（可直接复制发送）", fontname="yahei", fontsize=10.5, color=(0.8, 0.1, 0.1))
    y += 18

    box1 = fitz.Rect(45, y, 565, y + 155)
    p14.draw_rect(box1, color=(0.7, 0.7, 0.7), fill=(0.97, 0.97, 0.97))
    t1 = [
        "你好！我们正在参加全国大学生 FPGA 嵌入式竞赛，主控板（高云半导体 FPGA）GPIO 为严格的 3.3V LVCMOS 电平。",
        "想向您确认一下这几款模块的具体技术参数，以便我们确定采购批次：",
        "1. 【供电与输出电平】：模块在 3.3V 供电下能否正常工作？输出信号（DO/I2C/Echo）高电平是否为 3.3V？（不能输出 5V）。",
        "2. 【槽型光电对管】：板载是否集成了 LM393 电压比较器？输出是否有滞回（迟滞）整形电路，防止手指遮挡临界抖动？",
        "3. 【ToF/测距传感器】：这款激光测距模块芯片型号是 VL53L4CD 还是 VL53L0X？最高刷新率是否支持 100Hz？",
        "4. 【EC11 旋转编码器】：是否自带轻触按键开关？引脚板载是否带有上拉电阻？旋转一圈是多少个脉冲/定位档位？",
        "5. 【WS2812B 灯带】：5V 供电时，DIN 数据输入端是否可以直接兼容 3.3V 逻辑驱动信号？",
        "麻烦客服帮忙核对确认下，非常感谢！"
    ]
    ty = y + 16
    for line in t1:
        p14.insert_text((55, ty), line, fontname="yahei", fontsize=7.8, color=(0.15, 0.15, 0.15))
        ty += 16

    y = y + 175
    p14.insert_text((45, y), "11.2 向店家确认高校发票开具与报销话术模板（可直接复制发送）", fontname="yahei", fontsize=10.5, color=(0.8, 0.1, 0.1))
    y += 18

    box2 = fitz.Rect(45, y, 565, y + 140)
    p14.draw_rect(box2, color=(0.7, 0.7, 0.7), fill=(0.97, 0.97, 0.97))
    t2 = [
        "你好！我们是高校实验室参赛团队集中采购，需要在下单后开具报销发票，请问：",
        "1. 店铺能否开具正规的【增值税电子普通发票】？",
        "2. 发票抬头可以填写我们【学校全称】与【统一社会信用代码（税号）】吗？是否支持在备注栏填写项目组信息？",
        "3. 发票商品类目名称是什么？（最好是 *电子元器件*、*传感器*、*集成电路* 等规范类目，以便学校财务入账审核）。",
        "4. 开票是否需要加收税点？一般确认收货后多久能开出电子发票并发送到邮箱？",
        "如果可以正常开具发票，我们核对好型号就直接从贵店集中下单，谢谢！"
    ]
    ty = y + 16
    for line in t2:
        p14.insert_text((55, ty), line, fontname="yahei", fontsize=8, color=(0.15, 0.15, 0.15))
        ty += 18

    y = y + 160
    p14.insert_text((45, y), "11.3 采购流程建议", fontname="yahei", fontsize=10.5, color=(0.1, 0.25, 0.65))
    y += 16
    steps = [
        "第一步：先在【优信电子】将琴键开关、槽型光电(8个)、编码器(4个)、铜箔、面包板、杜邦线、12V电源一次性加入购物车；",
        "第二步：通过客服旺旺发送上述话术一、话术二，确认 3.3V 电平兼容性与高校开票事宜；",
        "第三步：ToF 测距模块在淘宝/DFRobot/微雪拍下 VL53L4CD（确认 100Hz 刷新率），备选测距购买 HC-SR04P（3.3V款）；",
        "第四步：付款时填写学校发票抬头与税号，收货后立即用示波器/万用表打标测试 3.3V 电平，确认无误后申请开票报销。"
    ]
    for step in steps:
        p14.insert_text((55, y), step, fontname="yahei", fontsize=8, color=(0.25, 0.25, 0.25))
        y += 16

    doc.save(PDF_TARGET)
    print("Successfully updated PDF! Total pages:", len(doc))

if __name__ == "__main__":
    build_updated_pdf()
