# -*- coding: utf-8 -*-
"""Capture all 4 pages from live hardware via COM8."""
import time
import os
import struct
import serial
from PIL import Image

ARTIFACT_DIR = r"C:\Users\gjl50\.gemini\antigravity\brain\82a16fbc-7ec9-41a5-b107-e87a2b91ea46"

def read_exact(ser, nbytes, timeout=10.0):
    buf = bytearray()
    t0 = time.time()
    while len(buf) < nbytes:
        if time.time() - t0 > timeout:
            raise TimeoutError(f"UART read timeout: got {len(buf)}/{nbytes} bytes")
        chunk = ser.read(min(nbytes - len(buf), max(1, ser.in_waiting)))
        if chunk:
            buf.extend(chunk)
            t0 = time.time()
    return bytes(buf)

def find_header(ser, hdr, timeout=8.0):
    t0 = time.time()
    matched = 0
    while time.time() - t0 < timeout:
        b = ser.read(1)
        if not b:
            continue
        if b[0] == hdr[matched]:
            matched += 1
            if matched == len(hdr):
                return True
        else:
            matched = 1 if b[0] == hdr[0] else 0
    return False

def capture_page(ser, cmd_char, page_name, out_filename):
    print(f"[*] Switching to {page_name} (sending '{cmd_char}')...")
    ser.reset_input_buffer()
    ser.write(cmd_char.encode("ascii"))
    time.sleep(0.5)

    print(f"[*] Requesting capture (sending 'c')...")
    ser.reset_input_buffer()
    ser.write(b"c")
    ser.flush()

    if not find_header(ser, b"IMGC", timeout=8.0):
        print(f"[FAIL] Did not receive 'IMGC' header for {page_name}")
        return False

    dims = read_exact(ser, 4, timeout=3.0)
    w, h = struct.unpack("<HH", dims)
    total_pixels = w * h
    print(f"    Header: {w}x{h} ({total_pixels} pixels)")

    pixels_565 = []
    t_start = time.time()
    while len(pixels_565) < total_pixels:
        pkt = read_exact(ser, 3, timeout=10.0)
        cnt, hi, lo = pkt[0], pkt[1], pkt[2]
        pix = (hi << 8) | lo
        pixels_565.extend([pix] * cnt)

    try:
        read_exact(ser, 6, timeout=1.0)
    except Exception:
        pass

    out_path = os.path.join(ARTIFACT_DIR, out_filename)
    img = Image.new("RGB", (w, h))
    rgb888 = []
    for p in pixels_565[:total_pixels]:
        r = ((p >> 11) & 0x1F) * 255 // 31
        g = ((p >> 5) & 0x3F) * 255 // 63
        b = (p & 0x1F) * 255 // 31
        rgb888.append((r, g, b))
    img.putdata(rgb888)
    img.save(out_path)
    print(f"[OK] Saved {out_filename} ({time.time() - t_start:.2f}s)")
    return True

def main():
    with serial.Serial("COM8", 115200, timeout=2.0) as ser:
        capture_page(ser, "m", "Page 0: Performance", "hardware_page0_performance.png")
        capture_page(ser, "v", "Page 1: Wave & FFT",    "hardware_page1_wave_fft.png")
        capture_page(ser, "t", "Page 2: 32-Benchmark",  "hardware_page2_benchmark.png")
        capture_page(ser, "g", "Page 3: Song Player",   "hardware_page3_songplayer.png")

if __name__ == "__main__":
    main()
