"""Digital-only fit assembly with switch and VB22B reference envelopes."""

from cadgen import build123d as bd
from cadgen import step

from lib.keybed_shape import keybed, switch_references
from lib.pcb_shape import pcb_envelope
from lib.tof_shape import tof_mounts, tof_sensor_references


@step(out="../STEP/fit_assembly.step")
def fit_assembly():
    return bd.Compound(
        children=[
            keybed(),
            tof_mounts(),
            pcb_envelope(),
            switch_references(),
            tof_sensor_references(),
        ],
        label="keybed_tof_digital_fit_assembly",
    )


if __name__ == "__main__":
    fit_assembly()
