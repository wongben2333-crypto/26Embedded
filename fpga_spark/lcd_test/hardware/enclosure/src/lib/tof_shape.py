"""Parametric VB22B mounting cradle and fit references."""

from __future__ import annotations

from cadgen import build123d as bd
from cadgen import srgb

from lib.params import (
    TOF_AXIS_GAUGE_LENGTH,
    TOF_FIT_Z,
    TOF_LEFT_X,
    TOF_LENS_OFFSET_X,
    TOF_LENS_OFFSET_Y,
    TOF_LIGHT_WELL_DEPTH,
    TOF_INNER_CABLE_WINDOW_HEIGHT,
    TOF_INNER_CABLE_WINDOW_WIDTH,
    TOF_INNER_CABLE_WINDOW_Z,
    TOF_APERTURE_HEIGHT,
    TOF_APERTURE_CORNER_RADIUS,
    TOF_APERTURE_WIDTH,
    TOF_MODULE_DEPTH,
    TOF_MODULE_CLEARANCE_PER_SIDE,
    TOF_MODULE_HEIGHT,
    TOF_MODULE_WIDTH,
    TOF_SEAT_THICKNESS,
    TOF_MOUNT_OUTER_HEIGHT,
    TOF_MOUNT_OUTER_WIDTH,
    TOF_MOUNT_REAR_EXTENSION,
    TOF_MOUNT_SPLIT_Z,
    TOF_MOUNT_TOTAL_DEPTH,
    TOF_MOUNT_WALL,
    TOF_RIGHT_X,
    SHELL_TOF_BASE_Y,
    SHELL_TOF_BASE_Z,
    SHELL_TOF_LEFT_X,
    SHELL_TOF_RIGHT_X,
)


def tof_mount_local(
    z_min: float = -TOF_MOUNT_REAR_EXTENSION,
    z_max: float = TOF_MOUNT_TOTAL_DEPTH,
) -> bd.Shape:
    """Build one cradle section, optionally clipped to a Z interval."""
    start_z = max(z_min, -TOF_MOUNT_REAR_EXTENSION)
    end_z = min(z_max, TOF_MOUNT_TOTAL_DEPTH)
    if end_z <= start_z:
        raise ValueError(f"Invalid ToF mount Z interval: {z_min}..{z_max}")
    center_z = (start_z + end_z) / 2.0
    housing = bd.Pos(0, 0, center_z) * bd.Box(
        TOF_MOUNT_OUTER_WIDTH,
        TOF_MOUNT_OUTER_HEIGHT,
        end_z - start_z,
    )

    pocket_bottom_z = TOF_SEAT_THICKNESS
    pocket_top_z = (
        TOF_SEAT_THICKNESS
        + TOF_MODULE_DEPTH
        + TOF_MODULE_CLEARANCE_PER_SIDE
    )
    module_pocket = bd.Pos(
        0,
        0,
        (pocket_bottom_z + pocket_top_z) / 2.0,
    ) * bd.Box(
        TOF_MODULE_WIDTH + 2.0 * TOF_MODULE_CLEARANCE_PER_SIDE,
        TOF_MODULE_HEIGHT + 2.0 * TOF_MODULE_CLEARANCE_PER_SIDE,
        pocket_top_z - pocket_bottom_z,
    )
    housing -= module_pocket

    light_well_start = TOF_SEAT_THICKNESS + TOF_MODULE_DEPTH
    light_well_profile = bd.Plane.XY.offset(light_well_start - 0.2) * bd.RectangleRounded(
        TOF_APERTURE_WIDTH,
        TOF_APERTURE_HEIGHT,
        TOF_APERTURE_CORNER_RADIUS,
    )
    light_well = bd.Pos(TOF_LENS_OFFSET_X, TOF_LENS_OFFSET_Y, 0) * bd.extrude(
        light_well_profile,
        amount=TOF_LIGHT_WELL_DEPTH + 0.4,
    )
    housing -= light_well

    housing.label = "tof_mount_local"
    housing.color = srgb("#202326")
    return housing


def tof_module_local() -> bd.Shape:
    module = bd.Pos(0, 0, TOF_SEAT_THICKNESS + TOF_MODULE_DEPTH / 2.0) * bd.Box(
        TOF_MODULE_WIDTH, TOF_MODULE_HEIGHT, TOF_MODULE_DEPTH
    )
    module.label = "vb22b_reference"
    module.color = srgb("#24569A")
    return module


def tof_axis_local() -> bd.Shape:
    axis = (
        bd.Pos(
            TOF_LENS_OFFSET_X,
            TOF_LENS_OFFSET_Y,
            TOF_SEAT_THICKNESS + TOF_MODULE_DEPTH,
        )
        * bd.Cylinder(
            0.28,
            TOF_AXIS_GAUGE_LENGTH,
            align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN),
        )
    )
    axis.label = "detection_axis"
    axis.color = srgb("#D3342C")
    return axis


def tof_poses() -> tuple[tuple[bd.Location, str], tuple[bd.Location, str]]:
    """Return two upward sensor poses in the keybed's local Y-up frame."""
    right = bd.Pos(
        TOF_RIGHT_X,
        TOF_MODULE_HEIGHT / 2.0 + TOF_MOUNT_WALL,
        TOF_FIT_Z,
    ) * bd.Rot(-90, 0, 0)
    left = bd.Pos(
        TOF_LEFT_X,
        TOF_MODULE_HEIGHT / 2.0 + TOF_MOUNT_WALL,
        TOF_FIT_Z,
    ) * bd.Rot(-90, 0, 0)
    return ((left, "tof_left"), (right, "tof_right"))


def tof_mounts() -> bd.Compound:
    children = []
    for pose, label in tof_poses():
        mount = pose * tof_mount_local()
        mount.label = f"{label}:mount"
        children.append(mount)
    return bd.Compound(children=children, label="tof_mount_pair")


def tof_sensor_references() -> bd.Compound:
    children = []
    for pose, label in tof_poses():
        module = pose * tof_module_local()
        module.label = f"{label}:vb22b_reference"
        axis = pose * tof_axis_local()
        axis.label = f"{label}:detection_axis"
        children.extend([module, axis])
    return bd.Compound(children=children, label="tof_reference_pair")


def shell_tof_poses() -> tuple[tuple[bd.Location, str], tuple[bd.Location, str]]:
    """Both R1 sensors point vertically upward with their axes parallel to +Z."""
    left = bd.Pos(
        SHELL_TOF_LEFT_X,
        SHELL_TOF_BASE_Y,
        SHELL_TOF_BASE_Z,
    )
    right = bd.Pos(
        SHELL_TOF_RIGHT_X,
        SHELL_TOF_BASE_Y,
        SHELL_TOF_BASE_Z,
    )
    return ((left, "tof_left"), (right, "tof_right"))


def shell_tof_mounts() -> bd.Compound:
    children = []
    for pose, label in shell_tof_poses():
        mount = pose * tof_mount_local()
        mount.label = f"{label}:mount"
        children.append(mount)
    return bd.Compound(children=children, label="shell_tof_mount_pair")


def shell_tof_lower_mounts() -> bd.Compound:
    """Return the sensor seat and wiring-wall section owned by the bottom shell."""
    children = []
    for pose, label in shell_tof_poses():
        mount = pose * tof_mount_local(0.0, TOF_MOUNT_SPLIT_Z)
        mount.label = f"{label}:mount_lower"
        children.append(mount)
    return bd.Compound(children=children, label="shell_tof_lower_mount_pair")


def shell_tof_upper_mounts() -> bd.Compound:
    """Return the removable optical hood above the shell split."""
    children = []
    for pose, label in shell_tof_poses():
        mount = pose * tof_mount_local(TOF_MOUNT_SPLIT_Z, TOF_MOUNT_TOTAL_DEPTH)
        mount.label = f"{label}:mount_upper"
        children.append(mount)
    return bd.Compound(children=children, label="shell_tof_upper_mount_pair")


def shell_tof_sensor_references() -> bd.Compound:
    children = []
    for pose, label in shell_tof_poses():
        module = pose * tof_module_local()
        module.label = f"{label}:vb22b_reference"
        axis = pose * tof_axis_local()
        axis.label = f"{label}:detection_axis"
        children.extend([module, axis])
    return bd.Compound(children=children, label="shell_tof_reference_pair")


def shell_tof_aperture_tools() -> bd.Compound:
    """Cut table-clear optical paths through the R1 upper shell."""
    children = []
    for pose, label in shell_tof_poses():
        aperture_profile = bd.Plane.XY.offset(
            TOF_SEAT_THICKNESS + TOF_MODULE_DEPTH
        ) * bd.RectangleRounded(
            TOF_APERTURE_WIDTH,
            TOF_APERTURE_HEIGHT,
            TOF_APERTURE_CORNER_RADIUS,
        )
        aperture = pose * bd.extrude(
            aperture_profile,
            amount=100.0,
        )
        aperture.label = f"{label}:aperture_tool"
        children.append(aperture)
    return bd.Compound(children=children, label="tof_aperture_tools")


def shell_tof_module_pocket_tools() -> bd.Compound:
    """Rectangular pockets through the torso of the integrated ToF towers."""
    children = []
    pocket_bottom_z = TOF_SEAT_THICKNESS
    pocket_top_z = (
        TOF_SEAT_THICKNESS
        + TOF_MODULE_DEPTH
        + TOF_MODULE_CLEARANCE_PER_SIDE
    )
    pocket_depth = pocket_top_z - pocket_bottom_z
    pocket_center_z = (pocket_top_z + pocket_bottom_z) / 2.0
    for pose, label in shell_tof_poses():
        pocket = pose * bd.Pos(0, 0, pocket_center_z) * bd.Box(
            TOF_MODULE_WIDTH + 2.0 * TOF_MODULE_CLEARANCE_PER_SIDE,
            TOF_MODULE_HEIGHT + 2.0 * TOF_MODULE_CLEARANCE_PER_SIDE,
            pocket_depth,
        )
        pocket.label = f"{label}:module_pocket_tool"
        children.append(pocket)
    return bd.Compound(children=children, label="tof_module_pocket_tools")


def shell_tof_inner_cable_tools() -> bd.Compound:
    """Open the inward-facing wall of each ToF cradle toward the PCB bay."""
    children = []
    for pose, label in shell_tof_poses():
        x_center = SHELL_TOF_LEFT_X if label == "tof_left" else SHELL_TOF_RIGHT_X
        toward_center = 1.0 if x_center < 0.0 else -1.0
        slot = (
            pose
            * bd.Pos(
                toward_center
                * (TOF_MOUNT_OUTER_WIDTH / 2.0 - TOF_MOUNT_WALL / 2.0),
                0,
                TOF_INNER_CABLE_WINDOW_Z,
            )
            * bd.Box(
                TOF_MOUNT_WALL + 1.0,
                TOF_INNER_CABLE_WINDOW_WIDTH,
                TOF_INNER_CABLE_WINDOW_HEIGHT,
            )
        )
        slot.label = f"{label}:inner_cable_tool"
        children.append(slot)
    return bd.Compound(children=children, label="tof_inner_cable_tools")
