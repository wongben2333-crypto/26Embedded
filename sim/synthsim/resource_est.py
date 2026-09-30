"""FPGA resource estimation for the wavetable polyphonic synth.

Answers analysis question (b): the resource budget of 32 voices on the target
device (``params.DEVICE`` = GW5AST-LV138PG484A, Tang Mega 138K Dock).

Estimates LUT / FF / DSP / B-SRAM for the whole voice chain: phase
accumulator, wavetable address + linear interpolation, ADSR envelope,
amplitude multiply, mixer adder tree, and the voice allocator.  Every cost
base is an engineering assumption documented at its definition site, and
deliberately errs on the conservative (high) side.

Python 3.8 compatible: typing.* only, no PEP-604 unions, no match statement.
"""
from __future__ import annotations

from typing import Dict

from .params import DEVICE, SynthParams

# ---------------------------------------------------------------------------
# Per-voice cost bases (documented assumptions).
#
# A single voice, time-multiplexed over the sample period, contains:
#   1. phase accumulator        (params.phase_bits = 32 wide)
#   2. wavetable address + linear interpolation
#   3. ADSR envelope state machine (16-bit level, exponential curve)
#   4. amplitude multiply  osc_sample x envelope   (one 18x18 DSP)
# ---------------------------------------------------------------------------

# Phase accumulator: one phase_bits-wide register (32) + increment adder.
# Assumption: the increment adder shares the per-sample LUT/carry datapath
# already booked in PER_VOICE_INTERP_LUT, so only the register is counted.
PER_VOICE_PHASE_FF = 32

# Wavetable address + linear interpolation ~120 LUT/voice (brief base figure).
# Breakdown: an 8-bit phase fraction x 16-bit sample-delta multiply is
# ~100..130 LUT4s (partial-product reduction), plus ~10..20 LUT for the 10-bit
# address mux and delta selection.  Booked as a single conservative figure.
PER_VOICE_INTERP_LUT = 120

# Envelope: 16-bit level register, 24-bit segment-increment accumulator, 4-bit
# state, exponential-segment lookup and compare/mux logic.
# Assumption: ~80 LUT per voice (level/increment comparators dominate).
PER_VOICE_ENV_LUT = 80

# Envelope state registers: level 16 + increment 24 + state/control 4 = 44.
PER_VOICE_ENV_FF = 44

# Interpolation pipeline registers: 2 stages x 16-bit samples = 32, plus the
# 10-bit address register and 16-bit delta register (overlap rounded to 48).
PER_VOICE_INTERP_FF = 48

# Amplitude multiply (wavetable sample x envelope): one 18x18 DSP per voice.
PER_VOICE_DSP = 1

# ---------------------------------------------------------------------------
# Shared (once per synth, not per voice).
# ---------------------------------------------------------------------------

# Mixer: (n_voices-1) 32-bit adder-tree adds.
# Assumption: ~1 LUT per bit per add on LUT4 fabric with carry chains;
# plus 64 LUT of saturation logic (params.saturate=True hard clip) and the
# registered output.
MIXER_LUT_PER_ADD_BIT = 1.0
MIXER_SAT_LUT = 64.0
MIXER_FF = 64.0  # registered mix output + bus control

# Voice allocator (note-on/off + oldest/weakest steal): per slot a note+velocity
# register (7+7 bits) and an age counter (24 bits) ~= 32 FF/slot; priority
# encoder and comparator tree ~= 16 LUT/slot plus 128 LUT of fixed control.
ALLOC_LUT_PER_SLOT = 16.0
ALLOC_LUT_BASE = 128.0
ALLOC_FF_PER_SLOT = 32.0

# Mixer accumulator width (matches the RTL mix bus assumption).
MIX_BITS = 32


def estimate_voice(n_voices: int, params: "SynthParams") -> Dict[str, float]:
    """Per-voice and total resource estimate for ``n_voices`` voices.

    Returned keys: per_voice_lut, per_voice_dsp, per_voice_ff, total_lut,
    total_dsp, total_ff, total_bsram_kb, bsram_per_level_kb, lut_pct, dsp_pct,
    bsram_pct, ff_pct.  Percentages are of ``params.DEVICE`` (GW5AST-LV138).
    """
    n = int(n_voices)

    per_voice_lut = float(PER_VOICE_INTERP_LUT + PER_VOICE_ENV_LUT)
    per_voice_ff = float(
        PER_VOICE_PHASE_FF + PER_VOICE_INTERP_FF + PER_VOICE_ENV_FF
    )
    per_voice_dsp = float(PER_VOICE_DSP)

    # Mixer adder tree: (n-1) adds of MIX_BITS bits, plus saturation logic.
    mixer_lut = MIXER_SAT_LUT
    if n > 1:
        mixer_lut = (n - 1) * MIX_BITS * MIXER_LUT_PER_ADD_BIT + MIXER_SAT_LUT
    alloc_lut = ALLOC_LUT_BASE + ALLOC_LUT_PER_SLOT * n

    total_lut = per_voice_lut * n + mixer_lut + alloc_lut
    total_ff = per_voice_ff * n + MIXER_FF + ALLOC_FF_PER_SLOT * n
    total_dsp = per_voice_dsp * n

    # B-SRAM: table_size x table_bits bits per mip level = 2 KB at 1024x16.
    # A voice reads ONE level per sample (the level selected for its note), so
    # a single level must be resident at minimum; the full mipmap (all
    # mip_octaves levels) is stored anyway because any voice may need any
    # level at note-on -- and it is still tiny (16 KB of 6 MB).
    bsram_per_level_kb = params.table_size * params.table_bits / 8.0 / 1024.0
    total_bsram_kb = bsram_per_level_kb * params.mip_octaves

    lut_pct = total_lut / DEVICE["lut"] * 100.0
    ff_pct = total_ff / DEVICE["ff"] * 100.0
    dsp_pct = total_dsp / DEVICE["dsp"] * 100.0
    bsram_pct = total_bsram_kb / DEVICE["bsram_kb"] * 100.0

    return {
        "per_voice_lut": per_voice_lut,
        "per_voice_dsp": per_voice_dsp,
        "per_voice_ff": per_voice_ff,
        "total_lut": total_lut,
        "total_dsp": total_dsp,
        "total_ff": total_ff,
        "total_bsram_kb": total_bsram_kb,
        "bsram_per_level_kb": bsram_per_level_kb,
        "lut_pct": lut_pct,
        "dsp_pct": dsp_pct,
        "bsram_pct": bsram_pct,
        "ff_pct": ff_pct,
    }


def compare_devices(total_lut: float, total_dsp: float,
                    total_bsram_kb: float) -> str:
    """Compare a resource triple against the target device, human-readable.

    Returns one sentence with the utilization percentages and a feasibility
    verdict (ample margin <= 50%, moderate <= 80%, tight <= 100%, else
    infeasible).
    """
    lut_pct = total_lut / DEVICE["lut"] * 100.0
    dsp_pct = total_dsp / DEVICE["dsp"] * 100.0
    bsram_pct = total_bsram_kb / DEVICE["bsram_kb"] * 100.0
    worst = max(lut_pct, dsp_pct, bsram_pct)
    if worst <= 100.0:
        if worst <= 50.0:
            verdict = "FEASIBLE with ample margin"
        elif worst <= 80.0:
            verdict = "FEASIBLE with moderate margin"
        else:
            verdict = "FEASIBLE but tight (worst resource >= 80%)"
    else:
        verdict = "NOT FEASIBLE"
    return (
        "%s on %s: LUT %.0f/%.0f (%.1f%%), DSP %.0f/%.0f (%.1f%%), "
        "B-SRAM %.1f/%.0f KB (%.1f%%)"
        % (verdict, DEVICE["name"], total_lut, float(DEVICE["lut"]), lut_pct,
           total_dsp, float(DEVICE["dsp"]), dsp_pct,
           total_bsram_kb, float(DEVICE["bsram_kb"]), bsram_pct)
    )


def _self_test() -> None:
    from .params import PARAMS_48K  # local import keeps module import light

    print("Per-voice cost bases (assumptions documented in module source):")
    print("  LUT %d (wavetable/interp %d + envelope %d)"
          % (PER_VOICE_INTERP_LUT + PER_VOICE_ENV_LUT,
             PER_VOICE_INTERP_LUT, PER_VOICE_ENV_LUT))
    print("  FF  %d (phase %d + interp pipe %d + envelope %d)"
          % (PER_VOICE_PHASE_FF + PER_VOICE_INTERP_FF + PER_VOICE_ENV_FF,
             PER_VOICE_PHASE_FF, PER_VOICE_INTERP_FF, PER_VOICE_ENV_FF))
    print("  DSP %d per voice (18x18 amplitude multiply)" % PER_VOICE_DSP)
    print("  wavetable B-SRAM: %.2f KB per mip level; full %d-level mipmap "
          "= %.1f KB (shared, not per voice)"
          % (PARAMS_48K.table_size * PARAMS_48K.table_bits / 8.0 / 1024.0,
             PARAMS_48K.mip_octaves,
             PARAMS_48K.table_size * PARAMS_48K.table_bits / 8.0 / 1024.0
             * PARAMS_48K.mip_octaves))
    print()
    print("Target device: %s  (LUT %d, FF %d, DSP %d, B-SRAM %d KB)"
          % (DEVICE["name"], DEVICE["lut"], DEVICE["ff"], DEVICE["dsp"],
             DEVICE["bsram_kb"]))
    print()
    print("%6s %10s %8s %8s %8s %8s %8s %10s %8s"
          % ("voices", "LUT", "LUT%", "DSP", "DSP%", "FF", "FF%",
             "BSRAM_KB", "BSRAM%"))
    for n in (4, 8, 16, 32):
        est = estimate_voice(n, PARAMS_48K)
        print("%6d %10.0f %8.1f %8.0f %8.1f %8.0f %8.1f %10.1f %8.1f"
              % (n, est["total_lut"], est["lut_pct"], est["total_dsp"],
                 est["dsp_pct"], est["total_ff"], est["ff_pct"],
                 est["total_bsram_kb"], est["bsram_pct"]))
    est32 = estimate_voice(32, PARAMS_48K)
    print()
    print(compare_devices(est32["total_lut"], est32["total_dsp"],
                          est32["total_bsram_kb"]))
    print("=> 32 voices fit the GW5AST-LV138 with large margin: "
          "LUT %.0f/138240 (%.1f%%), DSP %.0f/298 (%.1f%%), "
          "FF %.0f/138240 (%.1f%%), B-SRAM %.0f/6120 KB (%.1f%%); "
          "worst-case utilization is DSP at %.1f%%."
          % (est32["total_lut"], est32["lut_pct"], est32["total_dsp"],
             est32["dsp_pct"], est32["total_ff"], est32["ff_pct"],
             est32["total_bsram_kb"], est32["bsram_pct"],
             est32["dsp_pct"]))


if __name__ == "__main__":
    _self_test()
