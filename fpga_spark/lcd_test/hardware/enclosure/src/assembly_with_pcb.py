"""Final visual assembly using the supplied EasyEDA PCB STEP."""

from __future__ import annotations

from pathlib import Path

from cadgen import build123d as bd
from cadgen import read_step, step

from bottom_shell import bottom_shell_part
from lib.assembly_layout import keybed_placement
from lib.keybed_shape import keybed
from lib.params import PCB_THICKNESS, PCB_TOP_Z
from lib.tof_shape import shell_tof_sensor_references
from top_shell import top_shell_part


PCB_STEP = Path(__file__).resolve().parents[2] / "3D_PCB1_2026-10-27.step"


@step(out="../STEP/assembly_with_pcb.step")
def enclosure_assembly_with_pcb():
    placed_keybed = keybed_placement() * keybed()
    placed_keybed.label = "keybed_assembly"

    pcb = bd.Pos(0, 0, PCB_TOP_Z - PCB_THICKNESS) * read_step(PCB_STEP)
    pcb.label = "pcb_actual"

    return bd.Compound(
        children=[
            bottom_shell_part(),
            top_shell_part(),
            placed_keybed,
            pcb,
            shell_tof_sensor_references(),
        ],
        label="fpga_instrument_enclosure_with_pcb",
    )


if __name__ == "__main__":
    enclosure_assembly_with_pcb()
