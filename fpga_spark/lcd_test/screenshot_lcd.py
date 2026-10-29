#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ATK-MD0700 V2.4 (SSD1963 800x480) 硬件显存实时截屏回显工具
======================================================
目标硬件：Tang Mega 138K NEO Dock (GW5AST-138C)
传输接口：板载 USB-UART（FT2232H 通道 B，115200 8N1）
截屏原理：向 FPGA 发送抓屏指令，FPGA 直接向 SSD1963 控制器发起 0x2E (read_memory_start)
         显存回读周期，无损读取当前屏幕硬件画面并通过 UART 回传保存为 PNG。

支持特性：
  1. 智能端口自愈：自动识别 FTDI FT2232H 通道 B（Tang Mega UART），无需手动指定 COM8
  2. 防误复位保护：显式配置 dtr=False, rts=False 打开串口，彻底杜绝引发开发板复位或黑屏
  3. 智能冲突诊断与抢占 (--force)：当串口被其他上位机（如 fpga_synth_host.py）占用时，
     提供明确中文引导，或使用 --force 参数自动释放占用并截屏
  4. 极速 RLE 无损解码：采用流式缓冲块解码算法，解析 800x480 全分辨率画面仅需 ~3-4 秒
  5. 快速预览模式 (--mode quick)：200x120 硬件硬件下采样，4.17 秒确定性传输
  6. 屏幕页面联动 (--page 0..3)：支持截屏前一键切换至指定页面 (P0仪表/P1示波器/P2矩阵/P3曲目)
  7. 硬件复位联动 (--reinit)：支持在截屏前一键复位 SSD1963 控制器

使用示例：
  python screenshot_lcd.py                       # 默认以高画质 RLE 截取当前屏幕
  python screenshot_lcd.py --mode quick          # 快速 200x120 预览抓取 (~4.2s)
  python screenshot_lcd.py --page 1              # 先将 FPGA 切到 P1 示波器页面再截图
  python screenshot_lcd.py --force               # 冲突时强制释放串口占用并截图
  python screenshot_lcd.py --out my_screen.png   # 保存到指定文件路径
  python screenshot_lcd.py --show                # 截屏完成后调用系统默认看图软件打开
"""

import argparse
from collections import Counter
from datetime import datetime
import os
from pathlib import Path
import struct
import subprocess
import sys
import time
from typing import Optional, List, Tuple

# 防止 Windows 控制台在打印中文字符时发生编码错误
if hasattr(sys.stdout, 'reconfigure'):
    try:
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
        sys.stderr.reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass

try:
    import serial
    import serial.tools.list_ports
except ImportError:
    print("[错误] 未检测到 pyserial 库，请运行 pip install pyserial 安装。")
    sys.exit(1)

try:
    from PIL import Image
except ImportError:
    print("[错误] 未检测到 Pillow 库，请运行 pip install pillow 安装。")
    sys.exit(1)


DEFAULT_SCREENSHOT_DIR = Path(r"C:\Users\gjl50\Desktop\FPGA\fpga_spark\screenshot")

# 页面控制指令 (映射到 FPGA MIDI CC23 与 ASCII 指令)
PAGE_MAP = {
    "0": (0, b"m", "P0 综合仪表板 (Performance Dashboard)"),
    "p0": (0, b"m", "P0 综合仪表板 (Performance Dashboard)"),
    "1": (1, b"v", "P1 实时示波器与FFT (Wave & FFT)"),
    "p1": (1, b"v", "P1 实时示波器与FFT (Wave & FFT)"),
    "2": (2, b"t", "P2 32路振荡器矩阵 (32-Voice Benchmark)"),
    "p2": (2, b"t", "P2 32路振荡器矩阵 (32-Voice Benchmark)"),
    "3": (3, b"g", "P3 曲目播放器 (Song Player)"),
    "p3": (3, b"g", "P3 曲目播放器 (Song Player)"),
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
    """自动扫描并返回 Tang Mega 138K Dock 的 FT2232H 通道 B 串口。"""
    ports = list(serial.tools.list_ports.comports())
    for p in ports:
        if p.vid == 0x0403 and p.pid == 0x6010:
            sn = (p.serial_number or "").upper()
            hwid = (p.hwid or "").upper()
            if sn.endswith("B") or "MI_01" in hwid or "LOCATION=1" in hwid:
                return p.device
    for p in ports:
        if "COM8" in p.device:
            return "COM8"
    for p in ports:
        desc = (p.description or "").lower()
        if "usb serial" in desc or "ftdi" in desc:
            return p.device
    return "COM8"


def check_and_kill_port_holders(port: str, kill: bool = False) -> bool:
    """
    检查是否有正在运行的 Python 进程可能占用了串口。
    如果指定了 kill=True，尝试强制结束冲突进程以释放串口。
    """
    try:
        # 使用 tasklist 快速定位所有 python.exe
        res = subprocess.run(["tasklist", "/FI", "IMAGENAME eq python.exe", "/FO", "CSV"],
                             capture_output=True, text=True, encoding="utf-8", errors="replace")
        lines = [line.strip() for line in res.stdout.splitlines() if line.strip().startswith('"python.exe"')]
        my_pid = os.getpid()

        pids = []
        for line in lines:
            parts = [p.strip('"') for p in line.split(',')]
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
            print(f"[*] 正在尝试释放串口 {port}，终止冲突 Python 进程 (PIDs: {pids})...")
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


def open_serial_safe(port: str, baud: int, timeout: float = 0.5, force: bool = False) -> serial.Serial:
    """
    以防误复位安全模式打开串口（显式设置 dtr=False, rts=False）。
    当遇到 PermissionError 占用异常时提供自诊断及 --force 释放机制。
    """
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
        if "PermissionError" in err_str or "拒绝访问" in err_str or "5" in err_str:
            print("\n" + "=" * 72)
            print(f"[错误] 串口 {port} 无法打开：拒绝访问 (已被其他进程占用)！")
            print("常见占用原因及解决方案：")
            print("  1. 正在运行 fpga_synth_host.py (上位机控制中心)：")
            print("     -> 推荐方式 A: 直接在上位机图形界面右侧点击【📸 硬件屏幕截屏】即可一键抓屏")
            print("     -> 推荐方式 B: 在上位机界面顶部点击【🔌 断开连接】按钮释放串口")
            print("  2. 使用命令行强制抢占截屏：")
            print(f"     -> 运行: python screenshot_lcd.py --force")
            print("=" * 72 + "\n")

            if force:
                check_and_kill_port_holders(port, kill=True)
                # 重新尝试打开
                ser.open()
                ser.reset_input_buffer()
                ser.reset_output_buffer()
                print(f"[+] 已成功强制释放并连接串口 {port}！")
                return ser
        raise


def find_header(ser: serial.Serial, magic: bytes, timeout: float = 8.0) -> bool:
    """扫描串口流匹配 4 字节魔数报头 ('IMGQ' 或 'IMGC')。"""
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


def read_exact(ser: serial.Serial, nbytes: int, timeout: float = 15.0, show_progress: bool = False) -> bytes:
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


def capture_quick(ser: serial.Serial) -> Tuple[int, int, List[int]]:
    """
    快速抓屏模式 ('IMGQ'，200x120 硬件下采样 RGB565 裸流，48,000 字节)。
    在 115200 波特率下耗时恒定 4.17 秒。
    """
    ser.reset_input_buffer()
    ser.write(b"q")
    ser.flush()
    print("[1/3] 发送 'q' 指令 (200x120 快速预览显存回读) -> 正在等待 'IMGQ' 硬件响应报头...")

    if not find_header(ser, b"IMGQ", timeout=8.0):
        raise RuntimeError("未在 8 秒内收到 'IMGQ' 响应报头，请确认 FPGA 位流已正确烧录。")

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

    pixels_565 = [
        (raw[i] << 8) | raw[i + 1]
        for i in range(0, len(raw), 2)
    ]
    return w, h, pixels_565


def capture_rle(ser: serial.Serial) -> Tuple[int, int, List[int]]:
    """
    高清全分辨率抓屏模式 ('IMGC'，800x480 无损 RLE 压缩流)。
    采用流式大块缓冲解析算法，大幅消除系统调用开销，耗时仅需 ~3-4 秒。
    """
    ser.reset_input_buffer()
    ser.write(b"c")
    ser.flush()
    print("[1/3] 发送 'c' 指令 (800x480 全分辨率无损 RLE 显存回读) -> 正在等待 'IMGC' 硬件响应报头...")

    if not find_header(ser, b"IMGC", timeout=8.0):
        raise RuntimeError("未在 8 秒内收到 'IMGC' 响应报头，请确认 FPGA 位流已正确烧录。")

    dims = read_exact(ser, 4, timeout=3.0)
    w, h = struct.unpack("<HH", dims)
    total_pixels = w * h
    print(f"[2/3] 报头匹配成功: {w}x{h} 全分辨率 RLE 压缩数据流 (共 {total_pixels} 像素)...")

    pixels_565: List[int] = []
    buf = bytearray()
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

        # 内存批量解析 3 字节 RLE 压缩包 [cnt, hi, lo]
        while len(buf) >= 3 and len(pixels_565) < total_pixels:
            cnt = buf[0]
            hi = buf[1]
            lo = buf[2]
            del buf[:3]
            pix = (hi << 8) | lo
            pixels_565.extend([pix] * cnt)
            runs += 1

        now = time.time()
        if now - last_print >= 0.15 or len(pixels_565) >= total_pixels:
            pct = min(100.0, len(pixels_565) * 100.0 / total_pixels)
            sys.stdout.write(f"\r  无损 RLE 解码: {pct:5.1f}% ({len(pixels_565)}/{total_pixels} px, {runs} 个游程, 约 {runs*3} B)")
            sys.stdout.flush()
            last_print = now

    sys.stdout.write("\n")

    try:
        ftr = read_exact(ser, 4, timeout=0.5)
        if ftr == b"END!":
            print("  [OK] 成功匹配 'END!' 校验帧尾。")
    except Exception:
        pass

    return w, h, pixels_565[:total_pixels]


def main() -> int:
    parser = argparse.ArgumentParser(description="Tang Mega 138K FPGA SSD1963 800x480 LCD 硬件显存实时截屏回显工具")
    parser.add_argument("--port", default=None, help="串口端口号 (默认自动检测 Tang Mega 138K 通信串口)")
    parser.add_argument("--baud", type=int, default=115200, help="通信波特率 (默认 115200)")
    parser.add_argument(
        "--mode",
        choices=["rle", "quick"],
        default="rle",
        help="'rle' = 800x480 全分辨率无损还原 (默认推荐，晶莹剔透，~3.8s)；'quick' = 200x120 快速预览 (~4.2s)",
    )
    parser.add_argument(
        "--page",
        choices=["0", "1", "2", "3", "p0", "p1", "p2", "p3", "current"],
        default="current",
        help="截屏前切换至指定 FPGA 屏幕页面: 0(仪表盘) / 1(示波器与FFT) / 2(32路矩阵) / 3(曲目) / current(不改变)",
    )
    parser.add_argument("--reinit", action="store_true", help="截屏前向 FPGA 发送屏幕硬件重新初始化指令")
    parser.add_argument("--force", "-f", action="store_true", help="当串口被其他 Python 进程占用时，强制释放占用并继续截屏")
    parser.add_argument("--out", default=None, help="保存的 PNG 文件路径 (默认自动保存至 screenshot/screenshot_YYYYMMDD_HHMMSS.png)")
    parser.add_argument("--show", action="store_true", help="截屏完成后自动调用系统图像查看器打开")
    args = parser.parse_args()

    chosen_port = args.port if args.port else auto_detect_fpga_port()
    print(f"[*] 正在连接串口: {chosen_port} @ {args.baud} bps (防误复位保护模式)...")

    ser = open_serial_safe(chosen_port, args.baud, timeout=0.5, force=args.force)

    with ser:
        # 可选：复位 LCD 控制器
        if args.reinit:
            print("[*] 正在向 FPGA 发送 SSD1963 硬件复位重初始指令 ('R')...")
            ser.write(b"R")
            ser.flush()
            time.sleep(0.3)

        # 可选：切换 FPGA 页面
        if args.page != "current":
            p_idx, p_cmd, p_name = PAGE_MAP[args.page.lower()]
            print(f"[*] 正在切换 FPGA 屏幕页面至: {p_name}...")
            # 兼容 MIDI CC23 指令与 ASCII 指令
            ser.write(bytes([0xB0, 23, p_idx]))
            ser.write(p_cmd)
            ser.flush()
            time.sleep(0.25)  # 等待新页面渲染进显存

        t_start = time.time()
        if args.mode == "quick":
            w, h, pixels_565 = capture_quick(ser)
        else:
            w, h, pixels_565 = capture_rle(ser)
        elapsed = time.time() - t_start

    # 统计画面主要色相
    counts = Counter(pixels_565)
    top_colors = ", ".join(
        f"0x{c:04X} ({n * 100.0 / len(pixels_565):.1f}%)"
        for c, n in counts.most_common(5)
    )
    print(f"[3/3] 截屏读取成功！耗时 {elapsed:.2f}s。主要显存色彩分布: {top_colors}")

    # 构建并保存图像
    rgb_data = [rgb565_to_rgb888(p) for p in pixels_565]
    img = Image.new("RGB", (w, h))
    img.putdata(rgb_data)

    if args.out:
        out_path = Path(args.out).resolve()
    else:
        DEFAULT_SCREENSHOT_DIR.mkdir(parents=True, exist_ok=True)
        time_str = datetime.now().strftime("%Y%m%d_%H%M%S")
        out_path = DEFAULT_SCREENSHOT_DIR / f"screenshot_{time_str}.png"
    out_path.parent.mkdir(parents=True, exist_ok=True)

    if (w, h) != (800, 480):
        # 快速模式下使用最近邻插值保持像素边缘锐利
        img_full = img.resize((800, 480), resample=Image.Resampling.NEAREST)
        img_full.save(out_path)
    else:
        img.save(out_path)

    # 格式化绝对文件链接
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
