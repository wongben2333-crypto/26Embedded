"""Shared placements that convert the keybed model into shell coordinates."""

from __future__ import annotations

from cadgen import build123d as bd
from cadgen import srgb

from lib.params import (
    J13_CONNECTOR_CENTER_Y,
    J13_CONNECTOR_BOTTOM_Z,
    J13_CONNECTOR_DEPTH,
    J13_CONNECTOR_HEIGHT,
    J13_CONNECTOR_WIDTH,
    PCB_PLACEHOLDER_CENTER_Z,
    PCB_TOP_Z,
    WHITE_CAP_DEPTH,
)


def keybed_placement() -> bd.Location:
    """Rotate the Y-up keybed into the shell's Z-up coordinate system."""
    # Anchor the keys by their own depth centre, not by the asymmetrically
    # shortened keybed plate, so shortening the routing-side edge does not
    # translate the keyboard or guide pins relative to the shell and PCB.
    y_center = WHITE_CAP_DEPTH / 2.0
    return bd.Pos(0, y_center, PCB_TOP_Z) * bd.Rot(90, 0, 0)


def pcb_placement() -> bd.Location:
    return (
        bd.Pos(0, PCB_PLACEHOLDER_CENTER_Z, PCB_TOP_Z)
        * bd.Rot(90, 0, 0)
    )


def j13_connector_reference() -> bd.Shape:
    """A 2x20 connector envelope at the provisional PCB rear edge."""
    connector = bd.Pos(0, J13_CONNECTOR_CENTER_Y, J13_CONNECTOR_BOTTOM_Z) * bd.Box(
        J13_CONNECTOR_WIDTH,
        J13_CONNECTOR_DEPTH,
        J13_CONNECTOR_HEIGHT,
        align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN),
    )
    connector.label = "j13_2x20_connector_reference"
    connector.color = srgb("#B37A2E")
    return connector
