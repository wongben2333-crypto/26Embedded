"""Print-only flat layout for the local keybed and ToF fit pieces."""

from __future__ import annotations

from cadgen import build123d as bd
from cadgen import step, stl, threemf

from lib.keybed_shape import keybed_plate, keycap, white_keycap
from lib.params import (
    BLACK_CAP_DEPTH,
    BLACK_CAP_HEIGHT,
    BLACK_CAP_WIDTH,
    BLACK_POSITIONS,
    WHITE_POSITIONS,
    black_key_center_x,
    white_key_center_x,
)
from lib.tof_shape import tof_mount_local


def _place_on_bed(shape: bd.Shape, x: float, y: float, rotate_x: float = 90.0) -> bd.Shape:
    """Rotate a model into printer coordinates and place its lowest point at Z=0."""
    rotated = bd.Rot(rotate_x, 0, 0) * shape
    bounds = rotated.bounding_box()
    center = bounds.center()
    return rotated.moved(
        bd.Location(
            (
                x - center.X,
                y - center.Y,
                -bounds.min.Z,
            )
        )
    )


@step(out="../STEP/fit_sample.step")
@stl(out="../STL/fit_sample.stl", mesh_tolerance=3e-4)
@threemf(out="../3MF/fit_sample.3mf", mesh_tolerance=3e-4)
def fit_sample():
    children: list[bd.Shape] = []

    plate = _place_on_bed(keybed_plate(), 0.0, 0.0)
    plate.label = "keybed_plate"
    children.append(plate)

    # Print caps as separate objects so they do not require elevated supports.
    for index in WHITE_POSITIONS:
        cap = _place_on_bed(white_keycap(index), white_key_center_x(index), 55.0)
        cap.label = f"white_key_{index + 1}_print"
        children.append(cap)

    for index in BLACK_POSITIONS:
        cap = _place_on_bed(
            keycap(
                black_key_center_x(index),
                BLACK_CAP_WIDTH,
                BLACK_CAP_DEPTH,
                BLACK_CAP_HEIGHT,
                f"black_key_after_white_{index + 1}",
                "#1E2226",
            ),
            black_key_center_x(index),
            100.0,
        )
        cap.label = f"black_key_after_white_{index + 1}_print"
        children.append(cap)

    # Lay the sensor cradles on their aperture face, opening upward.
    for x, label in ((-18.0, "tof_left_mount_print"), (18.0, "tof_right_mount_print")):
        mount = _place_on_bed(tof_mount_local(), x, -45.0, rotate_x=180.0)
        mount.label = label
        children.append(mount)

    return bd.Compound(children=children, label="flat_keybed_tof_fit_kit")


if __name__ == "__main__":
    fit_sample()
