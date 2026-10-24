"""Read SSD1963 diagnostic lines from the Tang Mega 138K dock debugger UART.

Usage: python read_diag.py [COMx] [seconds]
Tries COM8 then COM7 (FT2232-compatible BL616 debugger, interface B is UART).
"""
import sys, time
import serial

ports = [sys.argv[1]] if len(sys.argv) > 1 else ["COM8", "COM7"]
secs = float(sys.argv[2]) if len(sys.argv) > 2 else 6.0

for p in ports:
    try:
        s = serial.Serial(p, 115200, timeout=0.2)
    except Exception as e:
        print(f"[{p}] open failed: {e}")
        continue
    print(f"[{p}] listening {secs}s ...")
    t0 = time.time()
    buf = b""
    while time.time() - t0 < secs:
        buf += s.read(4096)
    s.close()
    text = buf.decode("ascii", errors="replace")
    lines = [l for l in text.splitlines() if l.strip()]
    print(f"[{p}] {len(buf)} bytes, {len(lines)} lines")
    for l in lines[-40:]:
        print(l)
    if lines:
        break
