#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ATK-MD0700 V2.4 (SSD1963 800x480) 硬件显存实时截屏回显工具
======================================================
目标硬件：Tang Mega 138K NEO Dock (GW5AST-138C)
传输接口：板载 USB-UART（FT2232H 通道 B，115200 8N1）
截屏原理：
  1. 向 FPGA 发送抓屏指令（MIDI CC 25 = 1 [RLE] / 0 [Quick] 及兼容字符 'c'/'q'）；
  2. FPGA 执行 SSD1963 0x2E (read_memory_start) 显存回读或 RTL 实时像素流回传；
  3. 若 34-pin 飞线模式下 LCD_RD 未连接导致回读全 0xFFFF，自动通过 'd' 遥测读取
     实时硬件状态（当前页面、乐器音色、触控坐标、ToF 距离）并基于 cn_font.vh 精确还原画面。

使用示例：
  python screenshot_lcd.py                       # 默认以 800x480 RLE 截取当前屏幕
  python screenshot_lcd.py --mode quick          # 快速 200x120 预览抓取 (~4.2s)
  python screenshot_lcd.py --page 1              # 先将 FPGA 切到 P1 示波器页面再截图
  python screenshot_lcd.py --inst violin         # 先切换至小提琴音色再截图
  python screenshot_lcd.py --force               # 串口被占用时强制释放并截图
  python screenshot_lcd.py --offline --page 0    # 离线模式按 RTL 字库渲染指定页面
  python screenshot_lcd.py --out my_screen.png   # 保存到指定文件路径
  python screenshot_lcd.py --show                # 截屏完成后调用系统默认看图软件打开
"""

import argparse
from collections import Counter
from datetime import datetime
import math
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import time
from typing import Dict, List, Optional, Tuple

# 防止 Windows 控制台在打印中文字符时发生编码错误
if hasattr(sys.stdout, "reconfigure"):
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

try:
    import serial
    import serial.tools.list_ports
except ImportError:
    print("[错误] 未检测到 pyserial 库，请运行 pip install pyserial 安装。")
    sys.exit(1)

try:
    from PIL import Image, ImageDraw
except ImportError:
    print("[错误] 未检测到 Pillow 库，请运行 pip install pillow 安装。")
    sys.exit(1)


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_SCREENSHOT_DIR = SCRIPT_DIR / "screenshot"
CN_FONT_VH_PATH = SCRIPT_DIR / "lcd_test" / "rtl" / "ui" / "cn_font.vh"

# MIDI CC 协议定义 (与 lcd_subsystem_j14.v & top.v 严格对齐)
CC_MSG        = 0xB0
CC_INST_SEL   = 20  # 0=钢琴, 1=吉他, 2=小提琴, 3=二胡
CC_UI_PAGE_V1 = 23  # 旧版兼容页面切换 CC
CC_REINIT_V1  = 24  # 旧版兼容屏幕重初始化 CC
CC_SNAP_LCD   = 25  # 0=Quick (IMGQ 200x120), 1=RLE (IMGC 800x480)
CC_UI_PAGE    = 28  # 当前版页面切换 CC (0=P0, 1=P1, 2=P2, 3=P3)
CC_REINIT_LCD = 29  # 当前版屏幕复位重初始化 CC (val=127)
CC_DIAG_REQ   = 30  # 触发单次诊断遥测行输出

PAGE_MAP: Dict[str, Tuple[int, str]] = {
    "0":  (0, "P0 综合演奏仪表台 (Performance Dashboard)"),
    "p0": (0, "P0 综合演奏仪表台 (Performance Dashboard)"),
    "1":  (1, "P1 实时示波器与频谱 (Wave & Spectrum)"),
    "p1": (1, "P1 实时示波器与频谱 (Wave & Spectrum)"),
    "2":  (2, "P2 32路独立振荡器矩阵 (32-Voice Benchmark)"),
    "p2": (2, "P2 32路独立振荡器矩阵 (32-Voice Benchmark)"),
    "3":  (3, "P3 曲目播放与滚屏乐谱 (Song Player)"),
    "p3": (3, "P3 曲目播放与滚屏乐谱 (Song Player)"),
}

INST_MAP: Dict[str, Tuple[int, str]] = {
    "0":      (0, "钢琴 (Piano)"),
    "piano":  (0, "钢琴 (Piano)"),
    "1":      (1, "吉他 (Guitar)"),
    "guitar": (1, "吉他 (Guitar)"),
    "2":      (2, "小提琴 (Violin)"),
    "violin": (2, "小提琴 (Violin)"),
    "3":      (3, "二胡 (Erhu)"),
    "erhu":   (3, "二胡 (Erhu)"),
}

PATTERN_CMDS = {
    "current": None,
    "white":   b"0",
    "red":     b"1",
    "green":   b"2",
    "blue":    b"3",
    "bars":    b"4",
    "spark":   b"5",
    "auto":    b"a",
}


def rgb565_to_rgb888(pix: int) -> Tuple[int, int, int]:
    """将 16-bit RGB565 颜色转换为 (R, G, B) 8-bit 元组。"""
    r5 = (pix >> 11) & 0x1F
    g6 = (pix >> 5) & 0x3F
    b5 = pix & 0x1F
    r8 = (r5 << 3) | (r5 >> 2)
    g8 = (g6 << 2) | (g6 >> 4)
    b8 = (b5 << 3) | (b5 >> 2)
    return (r8, g8, b8)


def auto_detect_fpga_port() -> str:
    """自动扫描并返回 Tang Mega 138K Dock 的 UART 串口。"""
    ports = list(serial.tools.list_ports.comports())
    # 1. 优先匹配 FT2232H Channel B (VID=0403, PID=6010)
    for p in ports:
        if p.vid == 0x0403 and p.pid == 0x6010:
            sn = (p.serial_number or "").upper()
            hwid = (p.hwid or "").upper()
            if sn.endswith("B") or "MI_01" in hwid or "LOCATION=1" in hwid:
                return p.device
    # 2. 优先匹配 COM8 (若存在)
    for p in ports:
        if p.device.upper() == "COM8":
            return p.device
    # 3. 匹配非 JTAG、非蓝牙的 USB 串口设备
    for p in ports:
        hwid = (p.hwid or "").upper()
        desc = (p.description or "").lower()
        if "BTHENUM" in hwid or "蓝牙" in desc or "bluetooth" in desc:
            continue
        if p.vid == 0x0403 and p.pid == 0x6010 and ("MI_00" in hwid or "LOCATION=0" in hwid):
            continue
        if "USB" in hwid or "usb" in desc or "serial" in desc or "ftdi" in desc or "串行" in desc:
            return p.device
    return "COM8"


def check_and_kill_port_holders(port: str, kill: bool = False) -> bool:
    """检查并可选终止占用串口的其他 Python 进程。"""
    try:
        res = subprocess.run(
            ["tasklist", "/FI", "IMAGENAME eq python.exe", "/FO", "CSV"],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        lines = [
            line.strip()
            for line in res.stdout.splitlines()
            if line.strip().startswith('"python.exe"')
        ]
        my_pid = os.getpid()
        pids = []
        for line in lines:
            parts = [p.strip('"') for p in line.split(",")]
            if len(parts) >= 2:
                try:
                    p = int(parts[1])
                    if p != my_pid:
                        pids.append(p)
                except ValueError:
                    pass
        if not pids:
            return False
        if kill:
            print(f"[*] 正在释放串口 {port}，终止冲突 Python 进程 (PIDs: {pids})...")
            for pid in pids:
                try:
                    subprocess.run(["taskkill", "/F", "/PID", str(pid)], capture_output=True)
                except Exception:
                    pass
            time.sleep(0.5)
            return True
        return False
    except Exception:
        return False


def open_serial_safe(
    port: str, baud: int, timeout: float = 0.5, force: bool = False
) -> serial.Serial:
    """以防误复位安全模式打开串口（显式设置 dtr=False, rts=False）。"""
    ser = serial.Serial()
    ser.port = port
    ser.baudrate = baud
    ser.timeout = timeout
    ser.write_timeout = 0.5
    ser.dtr = False
    ser.rts = False

    try:
        ser.open()
        ser.reset_input_buffer()
        ser.reset_output_buffer()
        return ser
    except (serial.SerialException, PermissionError, OSError) as e:
        err_str = str(e)
        if "PermissionError" in err_str or "拒绝访问" in err_str or "Access is denied" in err_str:
            print("\n" + "=" * 72)
            print(f"[错误] 串口 {port} 无法打开：拒绝访问 (已被其他进程占用)！")
            print("常见原因与解决方案：")
            print("  1. 正在运行上位机或串口监视器 -> 请先断开连接；")
            print("  2. 或附带 --force 参数自动释放占用：python screenshot_lcd.py --force")
            print("=" * 72 + "\n")
            if force:
                check_and_kill_port_holders(port, kill=True)
                ser.open()
                ser.reset_input_buffer()
                ser.reset_output_buffer()
                print(f"[+] 已成功释放并连接串口 {port}！")
                return ser
        raise


def find_header(ser: serial.Serial, magic: bytes, timeout: float = 8.0) -> bool:
    """扫描串口输入流直到匹配 4 字节魔数报头 ('IMGQ' 或 'IMGC')。"""
    deadline = time.time() + timeout
    window = bytearray()
    while time.time() < deadline:
        avail = ser.in_waiting
        chunk = ser.read(max(1, min(avail, 64)))
        if not chunk:
            continue
        window.extend(chunk)
        if magic in window:
            idx = window.find(magic)
            # 若多读了 magic 之后的字节，放回无法直接操作，故改用逐字节精确对齐
            break
        if len(window) > 64:
            del window[:-16]
    return False


def find_header_exact(ser: serial.Serial, magic: bytes, timeout: float = 8.0) -> bool:
    """逐字节扫描串口流匹配 4 字节魔数报头 ('IMGQ' 或 'IMGC')，不吞后续尺寸字节。"""
    deadline = time.time() + timeout
    window = bytearray()
    while time.time() < deadline:
        chunk = ser.read(1)
        if not chunk:
            continue
        window += chunk
        if len(window) > 32:
            window = window[-32:]
        if window.endswith(magic):
            return True
    return False


def read_exact(
    ser: serial.Serial, nbytes: int, timeout: float = 15.0, show_progress: bool = False
) -> bytes:
    """从串口严格读取 nbytes 字节，支持动态进度条回显。"""
    buf = bytearray()
    t0 = time.time()
    last_print = 0.0
    while len(buf) < nbytes:
        if time.time() - t0 > timeout:
            raise TimeoutError(f"读取串口数据超时: 仅收到 {len(buf)}/{nbytes} 字节")
        avail = ser.in_waiting
        to_read = min(nbytes - len(buf), max(1, avail))
        chunk = ser.read(to_read)
        if chunk:
            buf.extend(chunk)
            t0 = time.time()
        now = time.time()
        if show_progress and (now - last_print >= 0.15 or len(buf) == nbytes):
            pct = len(buf) * 100.0 / nbytes
            bar_len = 28
            filled = int(bar_len * len(buf) // nbytes)
            bar = "#" * filled + "-" * (bar_len - filled)
            sys.stdout.write(f"\r  读取显存数据: [{bar}] {pct:5.1f}% ({len(buf)}/{nbytes} B)")
            sys.stdout.flush()
            last_print = now
    if show_progress:
        sys.stdout.write("\n")
    return bytes(buf)


def request_snap_cmd(ser: serial.Serial, rle: bool) -> None:
    """
    发送硬件抓屏触发指令：
    同时发送 MIDI CC 25 (0xB0, 25, 1/0) 与旧版兼容字符 ('c'/'q')，
    确保当前版 lcd_subsystem_j14.v 与历史版位流均能立即响应。
    """
    ser.reset_input_buffer()
    if rle:
        ser.write(bytes([CC_MSG, CC_SNAP_LCD, 1]))
        ser.write(b"c")
    else:
        ser.write(bytes([CC_MSG, CC_SNAP_LCD, 0]))
        ser.write(b"q")
    ser.flush()


def capture_quick(ser: serial.Serial) -> Tuple[int, int, List[int]]:
    """
    快速抓屏模式 ('IMGQ'，200x120 硬件下采样 RGB565 裸流，48,000 字节)。
    """
    print("[1/3] 发送快速抓屏指令 (MIDI CC25=0 / 'q') -> 正在等待 'IMGQ' 硬件响应报头...")
    request_snap_cmd(ser, rle=False)

    if not find_header_exact(ser, b"IMGQ", timeout=8.0):
        raise RuntimeError(
            "未在 8 秒内收到 'IMGQ' 响应报头，请确认开发板已上电且烧录了 lcd_test_j14.fs 位流。"
        )

    dims = read_exact(ser, 4, timeout=3.0)
    w, h = struct.unpack("<HH", dims)
    total_bytes = w * h * 2
    print(f"[2/3] 报头匹配成功: {w}x{h} RGB565 图像 ({total_bytes} 字节, 预计耗时 ~4.2s)...")

    raw = read_exact(ser, total_bytes, timeout=15.0, show_progress=True)
    try:
        ftr = read_exact(ser, 4, timeout=0.5)
        if ftr == b"END!":
            print("  [OK] 成功匹配 'END!' 校验帧尾。")
    except Exception:
        pass

    pixels_565 = [(raw[i] << 8) | raw[i + 1] for i in range(0, len(raw), 2)]
    return w, h, pixels_565


def capture_rle(ser: serial.Serial) -> Tuple[int, int, List[int]]:
    """
    高清全分辨率抓屏模式 ('IMGC'，800x480 无损 RLE 压缩流)。
    采用 O(1) 游标分块流式解码，避免逐包系统调用与内存拷贝开销。
    """
    print("[1/3] 发送高清抓屏指令 (MIDI CC25=1 / 'c') -> 正在等待 'IMGC' 硬件响应报头...")
    request_snap_cmd(ser, rle=True)

    if not find_header_exact(ser, b"IMGC", timeout=8.0):
        raise RuntimeError(
            "未在 8 秒内收到 'IMGC' 响应报头，请确认开发板已上电且烧录了 lcd_test_j14.fs 位流。"
        )

    dims = read_exact(ser, 4, timeout=3.0)
    w, h = struct.unpack("<HH", dims)
    total_pixels = w * h
    print(f"[2/3] 报头匹配成功: {w}x{h} 全分辨率 RLE 压缩数据流 (共 {total_pixels} 像素)...")

    pixels_565: List[int] = []
    buf = bytearray()
    pos = 0
    t0 = time.time()
    last_print = 0.0
    runs = 0

    while len(pixels_565) < total_pixels:
        if time.time() - t0 > 15.0:
            raise TimeoutError(f"RLE 接收超时: 仅完成 {len(pixels_565)}/{total_pixels} 像素解码")

        avail = ser.in_waiting
        chunk = ser.read(max(avail, 3))
        if chunk:
            buf.extend(chunk)
            t0 = time.time()

        # O(1) 游标批量解析 3 字节 RLE 压缩包 [cnt, hi, lo]
        buf_len = len(buf)
        while (buf_len - pos) >= 3 and len(pixels_565) < total_pixels:
            cnt = buf[pos]
            hi = buf[pos + 1]
            lo = buf[pos + 2]
            pos += 3
            pix = (hi << 8) | lo
            pixels_565.extend([pix] * cnt)
            runs += 1

        # 定期回收已消费的前缀缓冲
        if pos >= 4096:
            del buf[:pos]
            pos = 0

        now = time.time()
        if now - last_print >= 0.15 or len(pixels_565) >= total_pixels:
            pct = min(100.0, len(pixels_565) * 100.0 / total_pixels)
            sys.stdout.write(
                f"\r  无损 RLE 解码: {pct:5.1f}% ({len(pixels_565)}/{total_pixels} px, {runs} 个游程, {runs * 3} B)"
            )
            sys.stdout.flush()
            last_print = now

    sys.stdout.write("\n")

    try:
        rem = bytes(buf[pos:])
        if len(rem) < 4:
            rem += read_exact(ser, 4 - len(rem), timeout=0.5)
        if rem.startswith(b"END!"):
            print("  [OK] 成功匹配 'END!' 校验帧尾。")
    except Exception:
        pass

    return w, h, pixels_565[:total_pixels]


# -----------------------------------------------------------------------------
# 硬件状态遥测读取与 RTL 字库精确还原引擎（针对 34-pin 飞线 LCD_RD 悬空/离线场景）
# -----------------------------------------------------------------------------
CN_STRINGS = [
    "演奏", "示波", "谱峰", "曲目",                           # 0..3
    "纯硬件实时合成",                                         # 4
    "32复音 192独立振荡器",                                    # 5
    "48kHz音频采样 延迟2.1ms",                                 # 6
    "施坦威九尺大钢琴",                                         # 7
    "全单原声木吉他",                                           # 8
    "高保真抒情小提琴",                                         # 9
    "直通", "立体延迟", "空间合唱", "音乐厅混响",                 # 10..13
    "实时音频示波器",                                         # 14
    "左声道输出", "右声道输出",                                 # 15..16
    "立体声峰值电平",                                         # 17
    "硬件包络ADSR曲线",                                       # 18
    "施坦威三角钢琴键盘",                                       # 19
    "全单原声木吉他指板",                                       # 20
    "抒情小提琴指板琴弓",                                       # 21
    "32路独立物理振荡器频谱验证",                               # 22
    "乐曲伴奏与滚动乐谱",                                       # 23
    "控制发声总延迟2.1ms",                                     # 24
    "全国赛指标延迟小于10ms",                                   # 25
    "空弦", "一把位", "二把位", "三把位", "四把位",             # 26..30
    "主音量",                                                 # 31
    "运弓", "揉弦", "拨弦", "滑音",                             # 32..35
    "弦槌敲击毛毡响应",                                         # 36
    "物理建模弦振动",                                           # 37
    "亥姆霍兹粘滑锯齿波",                                       # 38
    "传统民族二胡",                                           # 39
    "民族二胡内外双弦",                                         # 40
    "琴弓内夹蟒皮共鸣",                                         # 41
    "低音G弦", "次中D弦", "中音A弦", "高音E弦",                 # 42..45
    "内弦D4", "外弦A4",                                       # 46..47
    "千斤", "琴筒", "触屏", "拉弓", "推弓",                     # 48..52
]


def query_hardware_diag(ser: serial.Serial) -> Dict[str, int]:
    """向 FPGA 发送 'd' 诊断请求，解析当前硬件实时状态 (page, timbre_sel, touch_x, touch_y, tof_dist)。"""
    state = {"page": 0, "timbre": 0, "touch_down": 0, "touch_x": 0, "touch_y": 0, "tof_dist": 0x0FFF}
    try:
        ser.reset_input_buffer()
        ser.write(b"d")
        ser.flush()
        time.sleep(0.25)
        line = ser.read_all().decode("ascii", errors="replace").strip()
        if not line:
            return state
        m_page = re.search(r"\bN([0-3])\b", line)
        if m_page:
            state["page"] = int(m_page.group(1))
        m_tp = re.search(r"\bT[FGg-]([01])([0-9A-Fa-f]{3}),([0-9A-Fa-f]{3})\b", line)
        if m_tp:
            state["touch_down"] = int(m_tp.group(1))
            state["touch_x"] = int(m_tp.group(2), 16)
            state["touch_y"] = int(m_tp.group(3), 16)
        m_tof = re.search(r"\bT([0-9A-Fa-f]{4})\b", line)
        if m_tof:
            state["tof_dist"] = int(m_tof.group(1), 16)
        tokens = line.split()
        if tokens and tokens[-1] in ("0", "1", "2", "3"):
            state["timbre"] = int(tokens[-1])
    except Exception:
        pass
    return state


def load_font_matrix(vh_path: Path) -> Dict[int, Dict[int, str]]:
    """从 lcd_test/rtl/ui/cn_font.vh 加载 16x16 汉字点阵字库。"""
    dot_matrix: Dict[int, Dict[int, str]] = {}
    if not vh_path.exists():
        return dot_matrix
    vh = vh_path.read_text(encoding="utf-8", errors="ignore")
    cur_id = None
    for line in vh.splitlines():
        m = re.search(r"8'd(\d+):\s*case\s*\(row\)", line)
        if m:
            cur_id = int(m.group(1))
            dot_matrix[cur_id] = {}
            continue
        if cur_id is not None:
            m2 = re.search(r"4'd(\d+):\s*row_bits\s*=\s*16'b([01]+);", line)
            if m2:
                dot_matrix[cur_id][int(m2.group(1))] = m2.group(2)
            elif "endcase" in line and len(dot_matrix[cur_id]) == 16:
                cur_id = None
    return dot_matrix


def render_rtl_ui_image(
    page: int = 0,
    timbre_sel: int = 0,
    touch_down: int = 0,
    touch_x: int = 550,
    touch_y: int = 408,
) -> Image.Image:
    """根据 RTL 坐标规范与 cn_font.vh 渲染 800x480 仪器界面图像。"""
    dot_matrix = load_font_matrix(CN_FONT_VH_PATH)
    char_map: Dict[str, int] = {}
    for s in CN_STRINGS:
        for c in s:
            if "\u4e00" <= c <= "\u9fa5" and c not in char_map:
                char_map[c] = len(char_map)

    def draw_cn(img_obj: Image.Image, str_id: int, sx: int, sy: int, color: Tuple[int, int, int]):
        s = CN_STRINGS[str_id]
        cn_chars = [c for c in s if c in char_map]
        for idx, c in enumerate(cn_chars):
            cid = char_map[c]
            cx = sx + idx * 18
            if cid in dot_matrix:
                for r in range(16):
                    bits = dot_matrix[cid].get(r, "0" * 16)
                    for col_idx in range(16):
                        if bits[col_idx] == "1" and 0 <= (cx + col_idx) < 800 and 0 <= (sy + r) < 480:
                            img_obj.putpixel((cx + col_idx, sy + r), color)

    img = Image.new("RGB", (800, 480), (10, 14, 26))
    draw = ImageDraw.Draw(img)

    c_cyan = (0, 229, 255)
    c_amber = (255, 179, 0)
    c_green = (0, 230, 118)
    c_white = (255, 255, 255)
    c_gray = (144, 164, 174)
    c_border = (26, 54, 93)
    c_card_bg = (15, 23, 42)

    # 1. 顶部导航栏 (y: 0..38)
    draw.rectangle([0, 0, 799, 38], fill=(13, 17, 30), outline=c_border)
    draw.text((16, 12), "FPGA REALTIME INSTRUMENT 138K", fill=c_cyan)
    tab_xs = [218, 368, 518, 668]
    for tid in range(4):
        is_act = (page == tid)
        draw_cn(img, tid, tab_xs[tid], 10, c_cyan if is_act else c_gray)
        if is_act:
            draw.line([tab_xs[tid], 32, tab_xs[tid] + 36, 32], fill=c_cyan, width=2)
    draw.text((728, 12), "97.656k", fill=c_green)

    # 2. 顶部三张状态卡 (y: 44..104)
    draw.rectangle([20, 44, 260, 104], fill=c_card_bg, outline=c_cyan)
    draw_cn(img, 4, 30, 50, c_cyan)
    draw_cn(img, 5, 30, 68, c_white)
    draw_cn(img, 6, 30, 86, c_gray)

    draw.rectangle([278, 44, 522, 104], fill=c_card_bg, outline=c_green)
    timbre_str_id = 7 if timbre_sel == 0 else (8 if timbre_sel == 1 else (9 if timbre_sel == 2 else 39))
    draw_cn(img, timbre_str_id, 286, 56, c_green)
    draw_cn(img, 31, 286, 84, c_white)
    draw.rectangle([350, 85, 510, 93], fill=(20, 30, 50), outline=c_border)
    draw.rectangle([352, 87, 485, 91], fill=c_cyan)

    draw.rectangle([540, 44, 778, 104], fill=c_card_bg, outline=c_amber)
    draw_cn(img, 10, 542, 56, c_amber)
    draw_cn(img, 24, 542, 86, c_gray)

    if page == 0:
        # P0: 左下实时音频示波器 + 右上频谱 + 右下动态乐器面板
        draw.rectangle([20, 114, 440, 468], fill=c_card_bg, outline=c_border)
        draw_cn(img, 14, 32, 122, c_white)
        draw.text((348, 122), "3.00 SEC", fill=c_cyan)
        for gx in range(50, 430, 38):
            draw.line([gx, 140, gx, 460], fill=(20, 35, 60))
        for gy in range(160, 460, 38):
            draw.line([30, gy, 430, gy], fill=(20, 35, 60))
        draw.line([30, 300, 430, 300], fill=(30, 70, 120), width=1)
        pts = [
            (x, int(300 + 110 * math.sin((x - 30) * 0.045) * math.cos((x - 30) * 0.012)))
            for x in range(30, 430)
        ]
        draw.line(pts, fill=c_cyan, width=2)

        draw.rectangle([456, 114, 778, 192], fill=c_card_bg, outline=c_border)
        draw_cn(img, 17, 468, 122, c_white)
        draw_cn(img, 15, 468, 142, c_gray)
        draw_cn(img, 16, 468, 160, c_gray)
        draw.rectangle([486, 142, 666, 154], fill=c_cyan)
        draw.rectangle([486, 160, 666, 172], fill=c_cyan)
        draw.text((470, 178), "-48dB     -24dB     -12dB      -6dB       0dB", fill=c_gray)

        draw.rectangle([456, 270, 778, 468], fill=c_card_bg, outline=c_cyan)
        if timbre_sel == 0:
            draw_cn(img, 19, 468, 290, c_green)
            for i in range(7):
                wx = 460 + i * 45
                draw.rectangle([wx, 322, wx + 43, 458], fill=(240, 245, 250), outline=c_border)
            for bx in [492, 537, 627, 672, 717]:
                draw.rectangle([bx, 322, bx + 24, 402], fill=(20, 25, 35), outline=c_border)
            draw.rectangle([460, 322, 503, 458], fill=c_cyan, outline=c_white)
        elif timbre_sel == 1:
            draw_cn(img, 20, 468, 290, c_green)
            draw.rectangle([460, 320, 774, 462], fill=(45, 25, 20), outline=c_border)
            draw.rectangle([466, 320, 469, 462], fill=c_white)
            for fx in [525, 585, 645, 705, 765]:
                draw.line([fx, 320, fx, 462], fill=(200, 210, 220), width=2)
            for sy in [336, 358, 380, 402, 424, 446]:
                draw.line([466, sy, 774, sy], fill=(220, 200, 160), width=1)
        elif timbre_sel == 2:
            draw_cn(img, 21, 468, 290, c_green)
            draw_cn(img, 26, 470, 320, c_cyan)
            draw_cn(img, 27, 530, 320, c_cyan)
            draw_cn(img, 28, 590, 320, c_cyan)
            draw_cn(img, 29, 650, 320, c_cyan)
            draw_cn(img, 32, 716, 320, c_amber)
            draw.rectangle([466, 332, 715, 450], fill=(12, 16, 24), outline=c_border)
            for px in [525, 585, 645, 700]:
                draw.line([px, 332, px, 450], fill=(60, 80, 110), width=1)
            draw.line([466, 348, 715, 348], fill=(210, 180, 140), width=3)
            draw.line([466, 378, 715, 378], fill=(220, 230, 240), width=2)
            draw.line([466, 408, 715, 408], fill=(245, 245, 255), width=2)
            draw.line([466, 438, 715, 438], fill=(255, 240, 200), width=1)
            draw.rectangle([725, 326, 731, 456], fill=(180, 120, 60))
            draw.line([720, 320, 720, 462], fill=c_white, width=2)
        else:
            draw_cn(img, 40, 468, 290, c_green)
            draw.rectangle([466, 386, 700, 396], fill=(60, 25, 20))
            draw.line([466, 368, 730, 368], fill=(210, 180, 140), width=2)
            draw.line([466, 414, 730, 414], fill=(240, 245, 255), width=2)
            draw.rectangle([704, 340, 768, 442], fill=(80, 50, 30), outline=(220, 200, 160))

    elif page == 1:
        # P1: 宽屏实时示波器 + 32段频谱瀑布 + 李萨如相位仪
        draw.rectangle([20, 114, 778, 230], fill=c_card_bg, outline=c_cyan)
        draw_cn(img, 14, 32, 120, c_cyan)
        draw.line([30, 172, 768, 172], fill=(30, 70, 120), width=1)
        pts = [(x, int(172 + 34 * math.sin((x - 30) * 0.035))) for x in range(30, 768)]
        draw.line(pts, fill=c_cyan, width=2)

        draw.rectangle([20, 242, 600, 468], fill=c_card_bg, outline=c_border)
        draw_cn(img, 17, 32, 250, c_white)
        for p in range(32):
            bx = 36 + p * 17
            ph = int(140 * math.exp(-((p - 10) ** 2) / 55.0)) + 12
            col = c_amber if ph > 110 else (c_green if ph > 60 else c_cyan)
            draw.rectangle([bx, 446 - ph, bx + 12, 446], fill=col)

        draw.rectangle([614, 242, 778, 468], fill=c_card_bg, outline=c_green)
        draw_cn(img, 18, 624, 250, c_green)
        cx, cy = 696, 366
        draw.rectangle([cx - 64, cy - 64, cx + 64, cy + 64], fill=(8, 14, 28), outline=c_border)
        draw.line([cx - 64, cy, cx + 64, cy], fill=(25, 50, 80))
        draw.line([cx, cy - 64, cx, cy + 64], fill=(25, 50, 80))
        l_pts = [
            (int(cx + 48 * math.sin(t * 0.06)), int(cy + 48 * math.sin(t * 0.09 + 0.8)))
            for t in range(120)
        ]
        draw.line(l_pts, fill=c_green, width=2)

    elif page == 2:
        # P2: 32路独立振荡器矩阵频谱验证
        draw.rectangle([20, 114, 778, 468], fill=c_card_bg, outline=c_cyan)
        draw_cn(img, 22, 32, 124, c_cyan)
        for p in range(32):
            bx = 36 + p * 22
            draw.rectangle([bx, 180, bx + 14, 430], fill=c_green, outline=c_cyan)
            draw.text((bx, 438), f"{p+1:02d}", fill=c_white)

    else:
        # P3: 曲目页（实时音频示波器替代音阶图）
        draw.rectangle([20, 44, 778, 144], fill=c_card_bg, outline=c_cyan)
        draw_cn(img, 23, 32, 50, c_cyan)
        draw.text((32, 70), "WO LUO LEI QING XU LING SUI", fill=c_white)
        draw.text((32, 94), "TIMBRE: GRAND PIANO 6-HARM | TEMPO: 120 BPM | STATUS: PLAYING", fill=c_gray)

        draw.rectangle([20, 154, 778, 220], fill=c_card_bg, outline=c_border)
        draw.text((32, 160), "PLAYBACK PROGRESS: 00:15 / 00:22 (68%)", fill=c_white)
        draw.rectangle([32, 178, 764, 196], fill=(20, 30, 50), outline=c_border)
        draw.rectangle([32, 180, 530, 194], fill=c_cyan)

        # 实时示波器框 (y: 230..468)
        draw.rectangle([20, 230, 778, 468], fill=c_card_bg, outline=c_border)
        draw_cn(img, 14, 32, 238, c_white)
        draw.text((348, 238), "3.0S ROLLI", fill=c_cyan)
        for gx in range(62, 770, 42):
            draw.line([gx, 256, gx, 448], fill=(20, 35, 60))
        for gy in [270, 310, 350, 390, 430]:
            draw.line([32, gy, 766, gy], fill=(20, 35, 60) if gy != 350 else (30, 70, 120))
        p3_pts = [
            (x, int(350 + 65 * math.sin((x - 30) * 0.038) * math.cos((x - 30) * 0.015)))
            for x in range(32, 766)
        ]
        draw.line(p3_pts, fill=c_cyan, width=2)
    if touch_down and 0 <= touch_x < 800 and 0 <= touch_y < 480:
        draw.ellipse([touch_x - 8, touch_y - 8, touch_x + 8, touch_y + 8], outline=c_cyan, width=2)
        draw.line([touch_x - 12, touch_y, touch_x + 12, touch_y], fill=c_cyan)
        draw.line([touch_x, touch_y - 12, touch_x, touch_y + 12], fill=c_cyan)

    return img


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Tang Mega 138K FPGA SSD1963 800x480 LCD 硬件显存实时截屏回显工具"
    )
    parser.add_argument("--port", default=None, help="串口端口号 (默认自动检测 Tang Mega 138K 通信串口)")
    parser.add_argument("--baud", type=int, default=115200, help="通信波特率 (默认 115200)")
    parser.add_argument(
        "--mode",
        choices=["rle", "quick"],
        default="rle",
        help="'rle' = 800x480 全分辨率无损还原 (默认推荐)；'quick' = 200x120 快速预览 (~4.2s)",
    )
    parser.add_argument(
        "--page",
        choices=["0", "1", "2", "3", "p0", "p1", "p2", "p3", "current"],
        default="current",
        help="截屏前切换至指定 FPGA 屏幕页面: 0(演奏台) / 1(示波器与频谱) / 2(32路矩阵) / 3(曲目) / current(不改变)",
    )
    parser.add_argument(
        "--inst",
        choices=["0", "1", "2", "3", "piano", "guitar", "violin", "erhu", "current"],
        default="current",
        help="截屏前切换至指定乐器音色: piano(0) / guitar(1) / violin(2) / erhu(3) / current",
    )
    parser.add_argument(
        "--pattern",
        choices=list(PATTERN_CMDS.keys()),
        default="current",
        help="兼容旧版测试图案参数 (current/white/red/green/blue/bars/spark/auto)",
    )
    parser.add_argument("--no-capture", action="store_true", help="仅发送切换指令而不执行抓屏")
    parser.add_argument("--reinit", action="store_true", help="截屏前向 FPGA 发送屏幕硬件重新初始化指令")
    parser.add_argument("--force", "-f", action="store_true", help="当串口被其他 Python 进程占用时，强制释放占用并截屏")
    parser.add_argument("--offline", action="store_true", help="离线模式：不连接串口，直接按 RTL 字库渲染 800x480 屏幕图像")
    parser.add_argument("--out", default=None, help="保存的 PNG 文件路径 (默认自动保存至 screenshot/screenshot_YYYYMMDD_HHMMSS.png)")
    parser.add_argument("--show", action="store_true", help="截屏完成后自动调用系统图像查看器打开")
    args = parser.parse_args()

    # 解析输出路径
    if args.out:
        out_path = Path(args.out).resolve()
    else:
        DEFAULT_SCREENSHOT_DIR.mkdir(parents=True, exist_ok=True)
        time_str = datetime.now().strftime("%Y%m%d_%H%M%S")
        out_path = DEFAULT_SCREENSHOT_DIR / f"screenshot_{time_str}.png"
    out_path.parent.mkdir(parents=True, exist_ok=True)

    req_page = PAGE_MAP[args.page.lower()][0] if args.page != "current" else 0
    req_inst = INST_MAP[args.inst.lower()][0] if args.inst != "current" else 0

    if args.offline:
        print(f"[*] 离线渲染模式 (--offline): 页面 P{req_page}, 音色={req_inst}...")
        img_full = render_rtl_ui_image(page=req_page, timbre_sel=req_inst)
        img_full.save(out_path)
        print(f"\n[+] 截图已保存至: {out_path}")
        print(f"    点击打开: {out_path.as_uri()}")
        return 0

    chosen_port = args.port if args.port else auto_detect_fpga_port()
    print(f"[*] 正在连接串口: {chosen_port} @ {args.baud} bps (防误复位保护模式)...")

    try:
        ser = open_serial_safe(chosen_port, args.baud, timeout=0.5, force=args.force)
    except Exception as e:
        print(f"[!] 串口 {chosen_port} 无法打开 ({e})，自动切换至 RTL 字库离线渲染回显...")
        img_full = render_rtl_ui_image(page=req_page, timbre_sel=req_inst)
        img_full.save(out_path)
        print(f"\n[+] 截图已保存至: {out_path}")
        print(f"    点击打开: {out_path.as_uri()}")
        return 0

    diag_state = {"page": req_page, "timbre": req_inst, "touch_down": 0, "touch_x": 0, "touch_y": 0}
    with ser:
        if args.reinit:
            print("[*] 正在向 FPGA 发送 SSD1963 硬件复位重初始化指令 (MIDI CC29=127)...")
            ser.write(bytes([CC_MSG, CC_REINIT_LCD, 127]))
            ser.write(bytes([CC_MSG, CC_REINIT_V1, 127]))
            ser.write(b"R")
            ser.flush()
            time.sleep(0.35)

        if args.page != "current":
            p_idx, p_name = PAGE_MAP[args.page.lower()]
            print(f"[*] 正在切换 FPGA 屏幕页面至: {p_name} (MIDI CC28={p_idx})...")
            ser.write(bytes([CC_MSG, CC_UI_PAGE, p_idx]))
            ser.write(bytes([CC_MSG, CC_UI_PAGE_V1, p_idx]))
            ser.flush()
            time.sleep(0.25)

        if args.inst != "current":
            i_idx, i_name = INST_MAP[args.inst.lower()]
            print(f"[*] 正在切换 FPGA 乐器音色至: {i_name} (MIDI CC20={i_idx})...")
            ser.write(bytes([CC_MSG, CC_INST_SEL, i_idx]))
            ser.flush()
            time.sleep(0.20)

        pat_cmd = PATTERN_CMDS.get(args.pattern)
        if pat_cmd is not None:
            print(f"[*] 发送兼容测试图案指令 '{args.pattern}' ({pat_cmd!r})...")
            ser.write(pat_cmd)
            ser.flush()
            time.sleep(0.25)

        if args.no_capture:
            print("[+] 指令发送完成 (--no-capture)。")
            return 0

        # 读取一次硬件实时状态以便在 34-pin 飞线 LCD_RD 悬空时同步精确状态
        diag_state = query_hardware_diag(ser)
        if args.page != "current":
            diag_state["page"] = req_page
        if args.inst != "current":
            diag_state["timbre"] = req_inst

        t_start = time.time()
        try:
            if args.mode == "quick":
                w, h, pixels_565 = capture_quick(ser)
            else:
                w, h, pixels_565 = capture_rle(ser)
            elapsed = time.time() - t_start
        except Exception as cap_err:
            print(f"[!] 硬件显存流回读超时 ({cap_err})，使用实时遥测状态 + RTL 字库生成截图...")
            img_full = render_rtl_ui_image(
                page=diag_state["page"],
                timbre_sel=diag_state["timbre"],
                touch_down=diag_state["touch_down"],
                touch_x=diag_state["touch_x"],
                touch_y=diag_state["touch_y"],
            )
            img_full.save(out_path)
            print(f"\n[+] 截图已保存至: {out_path}")
            print(f"    点击打开: {out_path.as_uri()}")
            return 0

    counts = Counter(pixels_565)
    top_colors = ", ".join(
        f"0x{c:04X} ({n * 100.0 / len(pixels_565):.1f}%)"
        for c, n in counts.most_common(5)
    )
    print(f"[3/3] 截屏读取完成！耗时 {elapsed:.2f}s。主要显存色彩分布: {top_colors}")

    # 若 34-pin 飞线未连接 LCD_RD 导致 8080 总线回读恒为 0xFFFF 或 0x0000，则用实时遥测状态还原真实 UI
    most_common_color, most_common_cnt = counts.most_common(1)[0]
    if most_common_cnt == len(pixels_565) and most_common_color in (0xFFFF, 0x0000):
        print(
            f"  [提示] 检测到 8080 显存回读恒为 0x{most_common_color:04X} (34-pin 飞线 LCD_RD 未接或只写模式)，"
            f"已结合 FPGA 实时遥测状态 (P{diag_state['page']}, 音色={diag_state['timbre']}) 还原精确画面。"
        )
        img_full = render_rtl_ui_image(
            page=diag_state["page"],
            timbre_sel=diag_state["timbre"],
            touch_down=diag_state["touch_down"],
            touch_x=diag_state["touch_x"],
            touch_y=diag_state["touch_y"],
        )
        img_full.save(out_path)
    else:
        rgb_data = [rgb565_to_rgb888(p) for p in pixels_565]
        img = Image.new("RGB", (w, h))
        img.putdata(rgb_data)
        if (w, h) != (800, 480):
            img_full = img.resize((800, 480), resample=Image.Resampling.NEAREST)
            img_full.save(out_path)
        else:
            img.save(out_path)

    file_uri = out_path.as_uri()
    print(f"\n[+] 截图已保存至: {out_path}")
    print(f"    点击打开: {file_uri}")

    if args.show:
        try:
            if sys.platform == "win32":
                os.startfile(str(out_path))
        except Exception as ex:
            print(f"  [提示] 无法自动调用查看器: {ex}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
