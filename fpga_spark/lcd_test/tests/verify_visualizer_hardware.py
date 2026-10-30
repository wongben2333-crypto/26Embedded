"""Exercise the actual LCD using its existing UART framebuffer readback."""

import argparse
import json
from pathlib import Path
import sys
import time

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from screenshot_lcd import (  # noqa: E402
    auto_detect_fpga_port, capture_rle, open_serial_safe, rgb565_to_rgb888,
)


def cc(ser, number, value):
    ser.write(bytes((0xB0, number, value)))
    ser.flush()
    time.sleep(0.03)


def capture(ser, folder, name):
    width, height, pixels = capture_rle(ser)
    assert (width, height) == (800, 480), (width, height)
    image = Image.new("RGB", (width, height))
    image.putdata([rgb565_to_rgb888(pixel) for pixel in pixels])
    path = folder / (name + ".png")
    image.save(path)
    print("Saved", path, flush=True)
    return pixels


def roi(pixels, x0, y0, x1, y1):
    return [pixels[y * 800 + x] for y in range(y0, y1)
            for x in range(x0, x1)]


def spectrum_heights(pixels):
    colors = {0x07E0, 0xFFE0, 0xF800}
    return [sum(pixels[y * 800 + 36 + 23 * band + 8] in colors
                for y in range(288, 432)) for band in range(32)]


def benchmark_heights(pixels):
    return [sum(pixels[y * 800 + 47 + 23 * band] == 0x07FF
                for y in range(287, 434)) for band in range(32)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", default=None)
    parser.add_argument("--out", type=Path,
                        default=ROOT.parent / "screenshot" / "audio_visualizer")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    port = args.port or auto_detect_fpga_port()
    result = {"port": port}
    with open_serial_safe(port, 115200) as ser:
        try:
            cc(ser, 7, 100)
            cc(ser, 22, 2)
            cc(ser, 28, 1)
            cc(ser, 23, 1)
            time.sleep(3.4)
            live = capture(ser, args.out, "p1_live")
            heights = spectrum_heights(live)
            assert max(heights) > 15, heights
            result["live_spectrum_heights"] = heights

            cc(ser, 28, 0)
            time.sleep(0.5)
            frozen = capture(ser, args.out, "p1_frozen")
            cc(ser, 7, 0)
            time.sleep(0.5)
            held = capture(ser, args.out, "p1_frozen_muted")
            for bounds in ((21, 68, 778, 241), (36, 288, 765, 432)):
                assert roi(frozen, *bounds) == roi(held, *bounds), bounds
            result["freeze_preserves_wave_and_spectrum"] = True

            cc(ser, 28, 1)
            time.sleep(3.4)
            muted = capture(ser, args.out, "p1_muted")
            assert max(spectrum_heights(muted)) == 0, spectrum_heights(muted)
            cyan_off_zero = sum(
                muted[y * 800 + x] == 0x07FF
                for y in range(70, 239) if abs(y - 154) > 2
                for x in range(22, 777))
            assert cyan_off_zero == 0, cyan_off_zero
            result["mute_clears_spectrum_and_waveform"] = True

            cc(ser, 7, 100)
            cc(ser, 23, 2)
            time.sleep(1.0)
            matrix = capture(ser, args.out, "p2_32_tones")
            heights = benchmark_heights(matrix)
            assert all(value > 0 for value in heights), heights
            result["measured_32_tone_heights"] = heights
            result["passed"] = True
        finally:
            cc(ser, 22, 0)
            cc(ser, 7, 100)
            cc(ser, 28, 1)
            cc(ser, 23, 1)
    (args.out / "results.json").write_text(
        json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print("PASS hardware: live signal, freeze, mute and 32 measured bands")


if __name__ == "__main__":
    main()
