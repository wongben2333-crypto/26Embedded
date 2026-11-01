"""R1 full assembly with all load-bearing parts and reference envelopes."""

from cadgen import build123d as bd
from cadgen import step

from bottom_shell import bottom_shell_part
from lib.assembly_layout import (
    j13_connector_reference,
    keybed_placement,
    pcb_placement,
)
from lib.keybed_shape import keybed, switch_references
from lib.pcb_shape import pcb_envelope
from lib.tof_shape import shell_tof_sensor_references
from top_shell import top_shell_part


@step(out="../STEP/assembly.step")
def enclosure_assembly():
    keybed_pose = keybed_placement()
    placed_keybed = keybed_pose * keybed()
    placed_keybed.label = "keybed_assembly"

    placed_switches = keybed_pose * switch_references()
    placed_switches.label = "switch_reference_set"

    placed_pcb = pcb_placement() * pcb_envelope()
    placed_pcb.label = "pcb_placeholder"

    return bd.Compound(
        children=[
            bottom_shell_part(),
            top_shell_part(),
            placed_keybed,
            placed_switches,
            placed_pcb,
            j13_connector_reference(),
            shell_tof_sensor_references(),
        ],
        label="fpga_instrument_enclosure_r1",
    )


if __name__ == "__main__":
    enclosure_assembly()
