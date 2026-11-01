"""Placeholder PCB envelope; not a manufacturing board outline."""

from __future__ import annotations

from cadgen import build123d as bd
from cadgen import srgb

from lib.params import (
    PCB_MOUNT_HOLE_DIAMETER,
    PCB_MOUNT_HOLE_X,
    PCB_MOUNT_HOLE_Y,
    PCB_PLACEHOLDER_CENTER_Z,
    PCB_PLACEHOLDER_BACK_Z,
    PCB_PLACEHOLDER_DEPTH,
    PCB_PLACEHOLDER_WIDTH,
    PCB_ROUNDED_CORNER_RADIUS,
    PCB_THICKNESS,
)


def pcb_envelope() -> bd.Shape:
    board = bd.Pos(0, -PCB_THICKNESS / 2.0, PCB_PLACEHOLDER_CENTER_Z) * bd.Box(
        PCB_PLACEHOLDER_WIDTH, PCB_THICKNESS, PCB_PLACEHOLDER_DEPTH
    )
    for x in (-PCB_MOUNT_HOLE_X, PCB_MOUNT_HOLE_X):
        for z in (
            PCB_PLACEHOLDER_CENTER_Z - PCB_MOUNT_HOLE_Y,
            PCB_PLACEHOLDER_CENTER_Z + PCB_MOUNT_HOLE_Y,
        ):
            hole = bd.Pos(x, -PCB_THICKNESS / 2.0, z) * bd.Rot(90, 0, 0) * bd.Cylinder(
                PCB_MOUNT_HOLE_DIAMETER / 2.0,
                PCB_THICKNESS + 0.4,
            )
            board -= hole
    board.label = "pcb_placeholder_envelope"
    board.color = srgb("#2F7051")
    return board


def pcb_profile() -> bd.Sketch:
    """Draft PCB profile shared by the 3D envelope and the DXF drawing."""
    with bd.BuildSketch() as sketch:
        bd.RectangleRounded(
            PCB_PLACEHOLDER_WIDTH,
            PCB_PLACEHOLDER_DEPTH,
            PCB_ROUNDED_CORNER_RADIUS,
        )
        hole_locations = [
            (x, y)
            for x in (-PCB_MOUNT_HOLE_X, PCB_MOUNT_HOLE_X)
            for y in (-PCB_MOUNT_HOLE_Y, PCB_MOUNT_HOLE_Y)
        ]
        with bd.Locations(hole_locations):
            bd.Circle(
                PCB_MOUNT_HOLE_DIAMETER / 2.0,
                mode=bd.Mode.SUBTRACT,
            )
    return sketch.sketch
