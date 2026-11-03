# -*- coding: utf-8 -*-
"""Final BAND_MUL (H4 adjusted, each row mean = 1.000000)."""
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

OLD = """    (0.5547, 2.2819, 0.9470, 0.8705, 0.7653, 0.5806),   # band0  D4  293.7 Hz
    (2.4952, 1.3220, 0.7837, 0.7090, 0.5115, 0.1786),   # band1  F4  349.2 Hz
    (3.1422, 1.0355, 0.9127, 0.6358, 0.1578, 0.1160),   # band2  A4  440.0 Hz
    (3.3610, 1.1660, 0.8982, 0.2678, 0.1348, 0.1723),   # band3  C5  523.2 Hz
    (3.3586, 1.2813, 0.8546, 0.1280, 0.1918, 0.1857),   # band4  D5  587.3 Hz"""

NEW = """    (0.5430, 2.2337, 0.9270, 0.9789, 0.7491, 0.5683),   # band0  D4  293.7 Hz  (H4 adjusted)
    (2.4182, 1.2812, 0.7595, 0.8722, 0.4957, 0.1731),   # band1  F4  349.2 Hz  (H4 adjusted)
    (2.9624, 0.9762, 0.8605, 0.9428, 0.1488, 0.1094),   # band2  A4  440.0 Hz  (H4 adjusted)
    (3.3609, 1.1660, 0.8982, 0.2678, 0.1348, 0.1723),   # band3  C5  523.2 Hz  (untouched)
    (3.3586, 1.2813, 0.8546, 0.1280, 0.1918, 0.1857),   # band4  D5  587.3 Hz  (untouched)"""

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

# sanity: print each row's mean
BAND = [(0.5430, 2.2337, 0.9270, 0.9789, 0.7491, 0.5683),
        (2.4182, 1.2812, 0.7595, 0.8722, 0.4957, 0.1731),
        (2.9624, 0.9762, 0.8605, 0.9428, 0.1488, 0.1094),
        (3.3609, 1.1660, 0.8982, 0.2678, 0.1348, 0.1723),
        (3.3586, 1.2813, 0.8546, 0.1280, 0.1918, 0.1857)]
for i, b in enumerate(BAND):
    print('  band%d mean = %.6f' % (i, sum(b) / 6.0))
