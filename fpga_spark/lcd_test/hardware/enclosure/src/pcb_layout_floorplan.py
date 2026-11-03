"""1:1 PCB floor-plan reference derived from the R1 enclosure.

This drawing is an EDA placement underlay, not a fabrication drawing.
Import it into the PCB editor and replace all symbols with real footprints.
"""

from cadgen import build123d as bd
from cadgen import dxf

from lib.params import (
    BLACK_CAP_DEPTH,
    GUIDE_PIN_PITCH,
    KEYBED_PLATE_BACK_Z,
    KEYBED_PLATE_DEPTH,
    KEYBED_PLATE_WIDTH,
    PCB_MOUNT_HOLE_X,
    PCB_MOUNT_HOLE_Y,
    WHITE_CAP_DEPTH,
    WHITE_KEY_COUNT,
    black_key_center_x,
    white_key_center_x,
)
from lib.pcb_shape import pcb_profile


# The keybed is rendered in PCB coordinates by the same transform used in
# assembly.py: local keybed +Z points toward the front (-Y of the PCB).
KEYBED_GLOBAL_BACK_Y = WHITE_CAP_DEPTH / 2.0 - KEYBED_PLATE_BACK_Z
KEYBED_GLOBAL_FRONT_Y = KEYBED_GLOBAL_BACK_Y - KEYBED_PLATE_DEPTH
LOW_CLEARANCE_BACK_Y = -15.225
LOW_CLEARANCE_FRONT_Y = -23.775

WHITE_CENTERS = tuple(white_key_center_x(i) for i in range(WHITE_KEY_COUNT))
BLACK_CENTERS = tuple(black_key_center_x(i) for i in (0, 1, 3, 4, 5))


def _rect(cx: float, cy: float, width: float, height: float) -> bd.Shape:
    return bd.Pos(cx, cy) * bd.Rectangle(width, height)


def _circle(cx: float, cy: float, diameter: float) -> bd.Shape:
    return bd.Pos(cx, cy) * bd.Circle(diameter / 2.0)


def _compound(shapes: list[bd.Shape], label: str) -> bd.Compound:
    return bd.Compound(children=shapes, label=label)


@dxf(out="../DXF/pcb_layout_floorplan.dxf")
def pcb_layout_floorplan():
    switch_faces = [
        _rect(x, 0.0, 7.8, 7.8) for x in WHITE_CENTERS
    ] + [
        _rect(x, (WHITE_CAP_DEPTH - BLACK_CAP_DEPTH) / 2.0, 7.8, 7.8)
        for x in BLACK_CENTERS
    ]

    guide_keepouts = []
    for x in WHITE_CENTERS:
        for y in (-GUIDE_PIN_PITCH / 2.0, GUIDE_PIN_PITCH / 2.0):
            guide_keepouts.append(_circle(x, y, 3.0))
    black_y = (WHITE_CAP_DEPTH - BLACK_CAP_DEPTH) / 2.0
    for x in BLACK_CENTERS:
        for y in (
            black_y - GUIDE_PIN_PITCH / 2.0,
            black_y + GUIDE_PIN_PITCH / 2.0,
        ):
            guide_keepouts.append(_circle(x, y, 3.0))

    # The top-side component keepout under the keybed.
    keybed_keepout = _rect(
        0.0,
        (KEYBED_GLOBAL_BACK_Y + KEYBED_GLOBAL_FRONT_Y) / 2.0,
        KEYBED_PLATE_WIDTH,
        abs(KEYBED_GLOBAL_BACK_Y - KEYBED_GLOBAL_FRONT_Y),
    )
    low_clearance = _rect(
        0.0,
        (LOW_CLEARANCE_BACK_Y + LOW_CLEARANCE_FRONT_Y) / 2.0,
        98.0,
        abs(LOW_CLEARANCE_BACK_Y - LOW_CLEARANCE_FRONT_Y),
    )
    keyboard_airspace = keybed_keepout + low_clearance

    mount_keepouts = [
        _circle(x, y, 8.0)
        for x in (-PCB_MOUNT_HOLE_X, PCB_MOUNT_HOLE_X)
        for y in (-PCB_MOUNT_HOLE_Y, PCB_MOUNT_HOLE_Y)
    ]
    support_ribs = [
        _rect(0.0, -28.0, 94.0, 3.0),
        _rect(0.0, 28.0, 94.0, 3.0),
    ]

    # Recommended finished-board harness envelopes. See PCB-LAYOUT-DESIGN.md.
    # Front connectors are single-row solder-pad arrays because the space
    # between the board edge and the Y=-28 support rib is only 5.5 mm.
    harnesses = [
        # J13 2x20, centre at X=0 Y=31.
        _rect(0.0, 31.0, 50.8, 5.08),
        # Two ToF footprints at the inward-facing sides of the 20 mm light wells.
        _rect(-31.0, 32.0, 5.08, 4.0),
        _rect(31.0, 32.0, 5.08, 4.0),
        # FPGA-side 3V3/GND input.
        _rect(-37.5, 32.2, 5.08, 5.08),
        # 1x16 solder-pad row: six BLACK, six GND12, two +12V, two spare.
        _rect(-28.0, -32.2, 40.64, 1.5),
        # 1x12 solder-pad row: eight A/B, 3V3, two GND, one spare.
        _rect(28.0, -32.2, 27.94, 1.5),
    ]

    # Component blocks deliberately kept away from the centre J13 and rear ribs.
    component_blocks = [
        _rect(-25.0, -19.0, 28.0, 8.0),  # bottom-side opto arrays
        _rect(28.0, -19.0, 30.0, 8.0),   # bottom-side encoder filters
        _rect(-31.0, 32.0, 10.0, 5.0),   # ToF-A pull-ups/filter
        _rect(31.0, 32.0, 10.0, 5.0),    # ToF-B pull-ups/filter
    ]

    return {
        "BOARD_REFERENCE": pcb_profile(),
        "SWITCH_REFERENCE": _compound(switch_faces, "switch_outline_reference"),
        "GUIDE_KEEP_OUT_REFERENCE": _compound(guide_keepouts, "guide_keepout_reference"),
        "COMPONENT_KEEP_OUT_REFERENCE": _compound(
            [keyboard_airspace, *mount_keepouts, *support_ribs],
            "component_keepout_reference",
        ),
        "HARNESS_REFERENCE": _compound(harnesses, "harness_reference"),
        "COMPONENT_BLOCK_REFERENCE": _compound(component_blocks, "component_block_reference"),
    }


if __name__ == "__main__":
    pcb_layout_floorplan()
