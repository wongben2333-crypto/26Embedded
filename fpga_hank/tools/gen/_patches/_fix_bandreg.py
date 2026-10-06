# -*- coding: utf-8 -*-
"""Register band_ld_eff (combinational inst_sel path caused 498 violations)."""
import io, os, sys

R = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
p = os.path.join(R, "rtl", "synth", "piano_engine.v")
with io.open(p, "r", encoding="utf-8", newline="") as f:
    raw = f.read()
eol = "\r\n" if "\r\n" in raw else "\n"
t = raw.replace("\r\n", "\n")

old = "    wire [2:0] band_ld_eff = (inst_ok == 2'd2) ? band_ld : 3'd0;\n"
new = (
    "    //   NOTE: band_ld_eff MUST be registered. It combinationally depends on\n"
    "    //         inst_ok (= derived from inst_sel), and wiring it straight into the\n"
    "    //         case re-introduces the long inst_sel path (measured: 498 violated\n"
    "    //         endpoints / -0.536 ns). Same lesson as drv_on_r: any signal from\n"
    "    //         inst_sel must be registered before it reaches a voice or a LUT.\n"
    "    reg  [2:0] band_ld_eff;\n"
    "    always @(posedge clk) begin\n"
    "        if (!rst_n) band_ld_eff <= 3'd0;\n"
    "        else        band_ld_eff <= (inst_ok == 2'd2) ? band_ld : 3'd0;\n"
    "    end\n"
)
n = t.count(old)
print("anchor count = %d" % n)
if n != 1:
    print("FAILED - nothing written")
    sys.exit(2)
t = t.replace(old, new)
out = t.replace("\n", eol) if eol != "\n" else t
with io.open(p, "w", encoding="utf-8", newline="") as f:
    f.write(out)
print("OK written")
