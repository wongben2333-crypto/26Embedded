# -*- coding: utf-8 -*-
"""Replace BAND_MUL with the corrected energy-criterion table (alpha=0.65, mean=1)."""
import io, os, sys, hashlib

HERE = os.path.dirname(os.path.abspath(__file__))
GEN = os.path.join(HERE, 'gen_piano_rom.py')

def fp(p):
    with open(p, 'rb') as f:
        return hashlib.sha256(f.read()).hexdigest()[:16].upper()

with io.open(GEN, 'r', encoding='utf-8', newline='') as f:
    raw = f.read()
eol = '\r\n' if '\r\n' in raw else '\n'
t = raw.replace('\r\n', '\n')

OLD = """BAND_MUL = [
    (0.858, 1.486, 0.936, 0.892, 0.984, 0.955),   # band0  D4  293.7 Hz
    (1.026, 1.274, 0.985, 1.055, 1.072, 0.687),   # band1  F4  349.2 Hz
    (1.479, 1.185, 1.169, 1.210, 0.690, 0.585),   # band2  A4  440.0 Hz
    (2.043, 1.206, 1.381, 0.844, 0.624, 0.558),   # band3  C5  523.2 Hz
    (2.213, 1.327, 1.422, 0.715, 0.679, 0.493),   # band4  D5  587.3 Hz
]"""

NEW = """BAND_MUL = [
    (0.5547, 2.2819, 0.9470, 0.8705, 0.7653, 0.5806),   # band0  D4  293.7 Hz
    (2.4952, 1.3220, 0.7837, 0.7090, 0.5115, 0.1786),   # band1  F4  349.2 Hz
    (3.1422, 1.0355, 0.9127, 0.6358, 0.1578, 0.1160),   # band2  A4  440.0 Hz
    (3.3610, 1.1660, 0.8982, 0.2678, 0.1348, 0.1723),   # band3  C5  523.2 Hz
    (3.3586, 1.2813, 0.8546, 0.1280, 0.1918, 0.1857),   # band4  D5  587.3 Hz
]
#  (alpha = 0.65 mild start is already baked in; each row's mean == 1.000
#   so the per-band total level is unchanged -- do NOT divide again.)"""

n = t.count(OLD)
print('anchor count = %d' % n)
if n != 1:
    print('FAILED - nothing written')
    sys.exit(2)
t = t.replace(OLD, NEW)
out = t.replace('\n', eol) if eol != '\n' else t
with io.open(GEN, 'w', encoding='utf-8', newline='') as f:
    f.write(out)
print('OK written  gen -> %s' % fp(GEN))
