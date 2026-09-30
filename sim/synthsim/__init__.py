"""synthsim -- Python golden reference model for the 2026 GaoYun FPGA synth.

See CONTRACT.md for the frozen module interfaces.
"""
from __future__ import annotations

from .params import DEVICE, PARAMS_48K, PARAMS_96K, SynthParams

__all__ = ["SynthParams", "PARAMS_48K", "PARAMS_96K", "DEVICE"]
