import math
import os

TABLE_SIZE = 4096
BIT_DEPTH = 16
MAX_VAL = (1 << (BIT_DEPTH - 1)) - 1  # 32767
MIN_VAL = -(1 << (BIT_DEPTH - 1))     # -32768

def to_hex16(val):
    if val < 0:
        val = (1 << 16) + val
    return f"{val & 0xFFFF:04X}"

def generate_sine():
    data = []
    for i in range(TABLE_SIZE):
        angle = 2.0 * math.pi * i / TABLE_SIZE
        sample = int(round(math.sin(angle) * MAX_VAL))
        sample = max(MIN_VAL, min(MAX_VAL, sample))
        data.append(to_hex16(sample))
    return data

def generate_sawtooth():
    data = []
    for i in range(TABLE_SIZE):
        # -1.0 to +1.0
        norm = (2.0 * i / TABLE_SIZE) - 1.0
        sample = int(round(norm * MAX_VAL))
        sample = max(MIN_VAL, min(MAX_VAL, sample))
        data.append(to_hex16(sample))
    return data

def generate_triangle():
    data = []
    half = TABLE_SIZE // 2
    for i in range(TABLE_SIZE):
        if i < half:
            norm = -1.0 + 2.0 * (i / half)
        else:
            norm = 1.0 - 2.0 * ((i - half) / half)
        sample = int(round(norm * MAX_VAL))
        sample = max(MIN_VAL, min(MAX_VAL, sample))
        data.append(to_hex16(sample))
    return data

def generate_square():
    data = []
    half = TABLE_SIZE // 2
    for i in range(TABLE_SIZE):
        sample = MAX_VAL if i < half else MIN_VAL
        data.append(to_hex16(sample))
    return data

def save_hex(filename, data):
    with open(filename, "w", encoding="utf-8") as f:
        for val in data:
            f.write(val + "\n")
    print(f"Generated {filename} ({len(data)} samples)")

if __name__ == "__main__":
    out_dir = os.path.join(os.path.dirname(__file__), "..", "rtl", "synth_core", "dds_wavetable")
    os.makedirs(out_dir, exist_ok=True)
    save_hex(os.path.join(out_dir, "wavetable_sine.hex"), generate_sine())
    save_hex(os.path.join(out_dir, "wavetable_saw.hex"), generate_sawtooth())
    save_hex(os.path.join(out_dir, "wavetable_tri.hex"), generate_triangle())
    save_hex(os.path.join(out_dir, "wavetable_sqr.hex"), generate_square())
