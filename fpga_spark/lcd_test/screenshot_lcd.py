#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ATK-MD0700 V2.4 (SSD1963 800x480) Hardware Framebuffer Screenshot Tool
======================================================================
Reads the live displayed image directly from the SSD1963 internal 1215KB
display SRAM (command 0x2E read_memory_start) via the Tang Mega 138K FPGA
over the onboard USB-UART (default COM8, 115200 8N1) and saves a PNG image.

Usage Examples:
  # 1. Capture whatever is currently on the LCD screen (Quick 200x120 -> 800x480, ~4.2s):
  python screenshot_lcd.py

  # 2. Switch LCD to the 8-Color Bar Test Pattern, capture screenshot, and save to bars.png:
  python screenshot_lcd.py --pattern bars --out bars.png

  # 3. Full-resolution 800x480 lossless RLE capture:
  python screenshot_lcd.py --mode rle --out screenshot_full.png

  # 4. Resume automatic color cycling on the LCD:
  python screenshot_lcd.py --pattern auto --no-capture
"""

import argparse
import struct
import sys
import time
from collections import Counter
from datetime import datetime
from pathlib import Path

import serial
from PIL import Image


DEFAULT_SCREENSHOT_DIR = Path(r"C:\Users\gjl50\Desktop\FPGA\fpga_spark\screenshot")


PATTERN_CMDS = {
    "current": None,
    "white":   b"0",
    "red":     b"1",
    "green":   b"2",
    "blue":    b"3",
    "bars":    b"4",
    "auto":    b"a",
}


def rgb565_to_rgb888(pix: int) -> tuple[int, int, int]:
    """Convert a 16-bit RGB565 integer to an (R, G, B) 8-bit tuple."""
    r5 = (pix >> 11) & 0x1F
    g6 = (pix >> 5) & 0x3F
    b5 = pix & 0x1F
    r8 = (r5 << 3) | (r5 >> 2)
    g8 = (g6 << 2) | (g6 >> 4)
    b8 = (b5 << 3) | (b5 >> 2)
    return (r8, g8, b8)


def find_header(ser: serial.Serial, magic: bytes, timeout: float = 8.0) -> bool:
    """Scan incoming UART stream until the 4-byte magic header ('IMGQ' or 'IMGC') is found."""
    deadline = time.time() + timeout
    window = bytearray()
    while time.time() < deadline:
        chunk = ser.read(1)
        if not chunk:
            continue
        window += chunk
        if len(window) > 64:
            window = window[-64:]
        if window.endswith(magic):
            return True
    return False


def read_exact(ser: serial.Serial, nbytes: int, timeout: float = 15.0, show_progress: bool = False) -> bytes:
    """Read exactly nbytes from serial port with a live progress bar."""
    buf = bytearray()
    t0 = time.time()
    last_print = 0.0
    while len(buf) < nbytes:
        if time.time() - t0 > timeout:
            raise TimeoutError(f"UART read timeout: got {len(buf)}/{nbytes} bytes")
        avail = ser.in_waiting
        to_read = min(nbytes - len(buf), max(1, avail))
        chunk = ser.read(to_read)
        if chunk:
            buf.extend(chunk)
            t0 = time.time()  # reset inactivity timeout when bytes arrive
        now = time.time()
        if show_progress and (now - last_print >= 0.15 or len(buf) == nbytes):
            pct = len(buf) * 100.0 / nbytes
            bar_len = 28
            filled = int(bar_len * len(buf) // nbytes)
            bar = "#" * filled + "-" * (bar_len - filled)
            sys.stdout.write(f"\r  Receiving [{bar}] {pct:5.1f}% ({len(buf)}/{nbytes} B)")
            sys.stdout.flush()
            last_print = now
    if show_progress:
        sys.stdout.write("\n")
    return bytes(buf)


def capture_quick(ser: serial.Serial) -> tuple[int, int, list[int]]:
    """
    Capture 'IMGQ' (200x120 subsampled raw RGB565 stream, 48,000 bytes).
    Deterministic 4.17s transfer at 115200 bps regardless of image complexity.
    """
    ser.reset_input_buffer()
    ser.write(b"q")
    ser.flush()
    print("[1/3] Sent 'q' (Quick 200x120 Hardware GRAM Readback) -> waiting for 'IMGQ' header...")

    if not find_header(ser, b"IMGQ", timeout=8.0):
        raise RuntimeError(
            "Did not receive 'IMGQ' header within 8s. "
            "Please make sure the latest bitstream/lcd_test_138c.fs is programmed."
        )

    dims = read_exact(ser, 4, timeout=3.0)
    w, h = struct.unpack("<HH", dims)
    total_bytes = w * h * 2
    print(f"[2/3] Header matched: {w}x{h} RGB565 ({total_bytes} bytes, ~{total_bytes * 10 / 115200:.1f}s)...")

    raw = read_exact(ser, total_bytes, timeout=15.0, show_progress=True)
    ftr = read_exact(ser, 6, timeout=3.0)
    if not ftr.startswith(b"END!"):
        print(f"  [Warning] Expected 'END!' footer, got {ftr!r}")

    pixels_565 = [
        (raw[i] << 8) | raw[i + 1]
        for i in range(0, len(raw), 2)
    ]
    return w, h, pixels_565


def capture_rle(ser: serial.Serial) -> tuple[int, int, list[int]]:
    """
    Capture 'IMGC' (800x480 lossless RLE-compressed RGB565 stream).
    Each packet is 3 bytes: [count (1..255), pix_hi, pix_lo].
    """
    ser.reset_input_buffer()
    ser.write(b"c")
    ser.flush()
    print("[1/3] Sent 'c' (Full 800x480 RLE Hardware GRAM Readback) -> waiting for 'IMGC' header...")

    if not find_header(ser, b"IMGC", timeout=8.0):
        raise RuntimeError(
            "Did not receive 'IMGC' header within 8s. "
            "Please make sure the latest bitstream/lcd_test_138c.fs is programmed."
        )

    dims = read_exact(ser, 4, timeout=3.0)
    w, h = struct.unpack("<HH", dims)
    total_pixels = w * h
    print(f"[2/3] Header matched: {w}x{h} RLE stream ({total_pixels} pixels total)...")

    pixels_565: list[int] = []
    last_print = 0.0
    runs = 0
    while len(pixels_565) < total_pixels:
        pkt = read_exact(ser, 3, timeout=10.0, show_progress=False)
        cnt, hi, lo = pkt[0], pkt[1], pkt[2]
        pix = (hi << 8) | lo
        pixels_565.extend([pix] * cnt)
        runs += 1
        now = time.time()
        if now - last_print >= 0.15 or len(pixels_565) >= total_pixels:
            pct = min(100.0, len(pixels_565) * 100.0 / total_pixels)
            sys.stdout.write(
                f"\r  Decoding RLE: {pct:5.1f}% ({len(pixels_565)}/{total_pixels} px, {runs} runs, {runs*3} B)"
            )
            sys.stdout.flush()
            last_print = now
    sys.stdout.write("\n")

    ftr = read_exact(ser, 6, timeout=3.0)
    if not ftr.startswith(b"END!"):
        print(f"  [Warning] Expected 'END!' footer, got {ftr!r}")

    return w, h, pixels_565[:total_pixels]


def main() -> int:
    parser = argparse.ArgumentParser(description="Capture hardware screenshot from SSD1963 800x480 LCD over UART")
    parser.add_argument("--port", default="COM8", help="Serial port name (default: COM8)")
    parser.add_argument("--baud", type=int, default=115200, help="Baud rate (default: 115200)")
    parser.add_argument(
        "--mode",
        choices=["quick", "rle"],
        default="quick",
        help="'quick' = 200x120 raw RGB565 upscaled to 800x480 (~4.2s); 'rle' = 800x480 RLE stream",
    )
    parser.add_argument(
        "--pattern",
        choices=list(PATTERN_CMDS.keys()),
        default="current",
        help="Optional: lock LCD to a specific pattern before capturing (white/red/green/blue/bars/auto/current)",
    )
    parser.add_argument("--no-capture", action="store_true", help="Only switch pattern without capturing screenshot")
    parser.add_argument("--out", default=None, help="Output PNG file path (default: C:\\Users\\gjl50\\Desktop\\FPGA\\fpga_spark\\screenshot\\screenshot_YYYYMMDD_HHMMSS.png)")
    args = parser.parse_args()

    print(f"Opening {args.port} @ {args.baud} bps...")
    with serial.Serial(args.port, args.baud, timeout=0.2) as ser:
        # Optional pattern command
        pat_cmd = PATTERN_CMDS[args.pattern]
        if pat_cmd is not None:
            print(f"Setting LCD pattern to '{args.pattern}' (UART cmd {pat_cmd!r})...")
            ser.write(pat_cmd)
            ser.flush()
            time.sleep(0.25)  # allow 1-2 frames for the new pattern to be written to SSD1963 GRAM

        if args.no_capture:
            print("Done (--no-capture specified).")
            return 0

        t_start = time.time()
        if args.mode == "quick":
            w, h, pixels_565 = capture_quick(ser)
        else:
            w, h, pixels_565 = capture_rle(ser)
        elapsed = time.time() - t_start

    # Summarize top colors read back from SSD1963 GRAM
    counts = Counter(pixels_565)
    top_colors = ", ".join(
        f"0x{c:04X} ({n * 100.0 / len(pixels_565):.1f}%)"
        for c, n in counts.most_common(5)
    )
    print(f"[3/3] Capture finished in {elapsed:.2f}s! Top RGB565 colors in GRAM: {top_colors}")

    # Build PIL Image
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
        # Save upscaled 800x480 (nearest-neighbor preserves crisp pixel edges)
        img_full = img.resize((800, 480), resample=Image.Resampling.NEAREST)
        img_full.save(out_path)
        print(f"Saved 800x480 screenshot to: {out_path}")
    else:
        img.save(out_path)
        print(f"Saved 800x480 screenshot to: {out_path}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
