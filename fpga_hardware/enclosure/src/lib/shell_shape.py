"""R1 parametric shell bodies with explicit provisional interfaces."""

from __future__ import annotations

from cadgen import build123d as bd
from cadgen import srgb

from lib.params import (
    BOTTOM_SHELL_CORNER_RADIUS,
    BOTTOM_SHELL_FLOOR,
    BOTTOM_SHELL_HEIGHT,
    BOTTOM_SHELL_OUTER_DEPTH,
    BOTTOM_SHELL_OUTER_WIDTH,
    BOTTOM_SHELL_WALL,
    CABLE_CLAMP_HOLE_DIAMETER,
    CABLE_CLAMP_HOLE_OFFSET,
    CABLE_EXIT_SPECS,
    J13_CABLE_RECESS_DEPTH,
    J13_CABLE_RECESS_TOP_Z,
    J13_CABLE_RECESS_WIDTH,
    J13_CONNECTOR_CENTER_Y,
    J13_CONNECTOR_DEPTH,
    J13_CONNECTOR_HEIGHT,
    J13_CONNECTOR_WIDTH,
    J13_CONNECTOR_BOTTOM_Z,
    J13_SERVICE_CAP_CENTER_Y,
    J13_SERVICE_CAP_CORNER_RADIUS,
    J13_SERVICE_CAP_DEPTH,
    J13_SERVICE_CAP_TOP_Z,
    J13_SERVICE_CAP_WIDTH,
    J13_SHELL_CLEARANCE,
    KEYBED_LOCATOR_BOSS_DEPTH,
    KEYBED_LOCATOR_BOSS_WIDTH,
    KEYBED_LOCATOR_BOSS_Y_OFFSET,
    KEYBED_LOCATOR_POSITIONS,
    KEYBED_LOCATOR_SOCKET_DEPTH,
    KEYBED_LOCATOR_SOCKET_DIAMETER,
    KEYBOARD_OPENING_DEPTH,
    KEYBOARD_OPENING_WIDTH,
    PCB_MOUNT_HOLE_DIAMETER,
    PCB_MOUNT_HOLE_X,
    PCB_MOUNT_HOLE_Y,
    H2_RIB_DEPTH,
    H2_RIB_X_MAX,
    H2_RIB_X_MIN,
    H2_RIB_Y_CENTER,
    PCB_HEADER_RELIEF_CLEARANCE,
    PCB_HEADER_RELIEF_Z_MAX,
    PCB_HEADER_RELIEF_Z_MIN,
    PCB_PLACEHOLDER_WIDTH,
    PCB_STANDOFF_DIAMETER,
    PCB_STANDOFF_PILOT_DIAMETER,
    PCB_STANDOFF_RELIEF_ENVELOPES,
    PCB_THICKNESS,
    PCB_TOP_Z,
    SHELL_SCREW_BOSS_DIAMETER,
    SHELL_SCREW_PILOT_DIAMETER,
    TOP_SCREW_CLEARANCE_DIAMETER,
    TOP_SCREW_COUNTERBORE_DEPTH,
    TOP_SCREW_COUNTERBORE_DIAMETER,
    TOP_SCREW_X,
    TOP_SCREW_Y,
    TOP_SHELL_CORNER_RADIUS,
    TOP_SHELL_LID_THICKNESS,
    TOP_SHELL_OUTER_DEPTH,
    TOP_SHELL_OUTER_WIDTH,
    TOP_SHELL_PLATE_BOTTOM_Z,
    TOP_SHELL_TOTAL_HEIGHT,
    TOP_SHELL_WALL,
    TOF_MOUNT_SPLIT_Z,
    SHELL_TOF_LEFT_X,
    SHELL_TOF_RIGHT_X,
)
from lib.tof_shape import (
    shell_tof_aperture_tools,
    shell_tof_inner_cable_tools,
    shell_tof_lower_mounts,
    shell_tof_module_pocket_tools,
    shell_tof_upper_mounts,
)


def rounded_box(
    width: float,
    depth: float,
    height: float,
    bottom_z: float,
    corner_radius: float,
) -> bd.Shape:
    body = bd.Pos(0, 0, bottom_z) * bd.Box(
        width,
        depth,
        height,
        align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN),
    )
    vertical_edges = body.edges().filter_by(bd.Axis.Z)
    return bd.fillet(vertical_edges, corner_radius)


def _main_solid(shape: bd.Shape) -> bd.Solid:
    """Discard only tiny disconnected Boolean slivers, never a real part island."""
    solids = sorted(shape.solids(), key=lambda item: item.volume, reverse=True)
    if not solids:
        raise ValueError("Shell Boolean produced no solid")
    if len(solids) > 1 and solids[0].volume < 100.0 * solids[1].volume:
        raise ValueError("Shell Boolean produced multiple comparable-size solids")
    return solids[0]


def bottom_shell() -> bd.Shape:
    outer = rounded_box(
        BOTTOM_SHELL_OUTER_WIDTH,
        BOTTOM_SHELL_OUTER_DEPTH,
        BOTTOM_SHELL_HEIGHT,
        0.0,
        BOTTOM_SHELL_CORNER_RADIUS,
    )
    cavity = rounded_box(
        BOTTOM_SHELL_OUTER_WIDTH - 2.0 * BOTTOM_SHELL_WALL,
        BOTTOM_SHELL_OUTER_DEPTH - 2.0 * BOTTOM_SHELL_WALL,
        BOTTOM_SHELL_HEIGHT - BOTTOM_SHELL_FLOOR + 0.1,
        BOTTOM_SHELL_FLOOR,
        max(0.1, BOTTOM_SHELL_CORNER_RADIUS - BOTTOM_SHELL_WALL),
    )
    shell = outer - cavity

    board_bottom_z = PCB_TOP_Z - PCB_THICKNESS
    standoff_height = board_bottom_z - BOTTOM_SHELL_FLOOR
    supports: list[bd.Shape] = []
    for x in (-PCB_MOUNT_HOLE_X, PCB_MOUNT_HOLE_X):
        for y in (-PCB_MOUNT_HOLE_Y, PCB_MOUNT_HOLE_Y):
            supports.append(
                bd.Pos(x, y, BOTTOM_SHELL_FLOOR)
                * bd.Cylinder(
                    PCB_STANDOFF_DIAMETER / 2.0,
                    standoff_height,
                    align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN),
                )
            )

    # Support ribs run beneath the PCB and stop at its underside. The +Y rib
    # jogs inward only around H2, preserving a 1.664 mm clearance to the
    # measured downward-header edge.
    rib_width = PCB_PLACEHOLDER_WIDTH - 6.0
    supports.append(
        bd.Pos(0, -28.0, BOTTOM_SHELL_FLOOR)
        * bd.Box(
            rib_width,
            3.0,
            standoff_height,
            align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN),
        )
    )
    for x_min, x_max, y_center in (
        (-rib_width / 2.0, H2_RIB_X_MIN, 28.0),
        (H2_RIB_X_MIN, H2_RIB_X_MAX, H2_RIB_Y_CENTER),
        (H2_RIB_X_MAX, rib_width / 2.0, 28.0),
    ):
        supports.append(
            bd.Pos(
                (x_min + x_max) / 2.0,
                y_center,
                BOTTOM_SHELL_FLOOR,
            )
            * bd.Box(
                x_max - x_min,
                H2_RIB_DEPTH,
                standoff_height,
                align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN),
            )
        )
    shell = shell + supports

    # The user will solder the short headers downward. Clear their measured
    # XY envelopes plus 0.30 mm only through the upper standoff/rib band.
    for _header, (x_min, y_min, x_max, y_max) in PCB_STANDOFF_RELIEF_ENVELOPES:
        relief = bd.Pos(
            (x_min + x_max) / 2.0,
            (y_min + y_max) / 2.0,
            PCB_HEADER_RELIEF_Z_MIN,
        ) * bd.Box(
            x_max - x_min + 2.0 * PCB_HEADER_RELIEF_CLEARANCE,
            y_max - y_min + 2.0 * PCB_HEADER_RELIEF_CLEARANCE,
            PCB_HEADER_RELIEF_Z_MAX - PCB_HEADER_RELIEF_Z_MIN,
            align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN),
        )
        shell -= relief

    for x in (-TOP_SCREW_X, TOP_SCREW_X):
        for y in (-TOP_SCREW_Y, TOP_SCREW_Y):
            boss = bd.Pos(x, y, BOTTOM_SHELL_FLOOR) * bd.Cylinder(
                SHELL_SCREW_BOSS_DIAMETER / 2.0,
                BOTTOM_SHELL_HEIGHT - BOTTOM_SHELL_FLOOR,
                align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN),
            )
            shell += boss
            pilot = bd.Pos(x, y, BOTTOM_SHELL_HEIGHT - 8.0) * bd.Cylinder(
                SHELL_SCREW_PILOT_DIAMETER / 2.0,
                8.1,
                align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN),
            )
            shell -= pilot

    # Explicit cable-bundle exits with two clamp-screw holes per port.
    for spec in CABLE_EXIT_SPECS:
        width = spec["width"]
        height = spec["height"]
        z = spec["z"]
        center = spec["center"]
        clamp_offset = spec.get("clamp_offset", CABLE_CLAMP_HOLE_OFFSET)
        if spec["face"] in ("rear", "front"):
            side_y = 1.0 if spec["face"] == "rear" else -1.0
            wall_center_y = side_y * (
                BOTTOM_SHELL_OUTER_DEPTH / 2.0 - BOTTOM_SHELL_WALL / 2.0
            )
            slot = bd.Pos(center, wall_center_y, z) * bd.Box(
                width,
                BOTTOM_SHELL_WALL + 2.0,
                height,
            )
            clamp_centres = (
                (
                    center - width / 2.0 - clamp_offset,
                    wall_center_y,
                    z,
                ),
                (
                    center + width / 2.0 + clamp_offset,
                    wall_center_y,
                    z,
                ),
            )
            clamp_rotation = bd.Rot(90, 0, 0)
        elif spec["face"] in ("left", "right"):
            side = -1.0 if spec["face"] == "left" else 1.0
            wall_center_x = side * (
                BOTTOM_SHELL_OUTER_WIDTH / 2.0 - BOTTOM_SHELL_WALL / 2.0
            )
            slot = bd.Pos(
                wall_center_x,
                center,
                z,
            ) * bd.Box(
                BOTTOM_SHELL_WALL + 2.0,
                width,
                height,
            )
            clamp_centres = (
                (
                    wall_center_x,
                    center - width / 2.0 - clamp_offset,
                    z,
                ),
                (
                    wall_center_x,
                    center + width / 2.0 + clamp_offset,
                    z,
                ),
            )
            clamp_rotation = bd.Rot(0, 90, 0)
        else:
            raise ValueError(f"Unsupported cable-exit face: {spec['face']}")
        if "clamp_holes" in spec:
            custom_holes = spec["clamp_holes"]
            if custom_holes:
                if spec["face"] not in ("front", "rear"):
                    raise ValueError(
                        "Custom clamp holes currently require front/rear face"
                    )
                clamp_centres = tuple(
                    (center + offset_x, wall_center_y, z + offset_z)
                    for offset_x, offset_z in custom_holes
                )
            else:
                clamp_centres = ()
        shell -= slot
        for hole_x, hole_y, hole_z in clamp_centres:
            clamp_hole = (
                bd.Pos(hole_x, hole_y, hole_z)
                * clamp_rotation
                * bd.Cylinder(
                    CABLE_CLAMP_HOLE_DIAMETER / 2.0,
                    BOTTOM_SHELL_WALL + 2.0,
                )
            )
            shell -= clamp_hole

    # Keep the sensor seat, wire exits and lower hood with the bottom shell.
    # Removing the lid therefore leaves every ToF module and its cable fixed.
    for mount in shell_tof_lower_mounts().solids():
        shell += mount
    shell -= shell_tof_module_pocket_tools()
    shell -= shell_tof_aperture_tools()
    shell -= shell_tof_inner_cable_tools()

    # Re-establish the rear 40P channel after adding the lower ToF cradles;
    # otherwise their rear walls would refill part of the service opening.
    j13_exit = next(spec for spec in CABLE_EXIT_SPECS if spec["name"] == "fpga_j13")
    rear_wall_y = BOTTOM_SHELL_OUTER_DEPTH / 2.0 - BOTTOM_SHELL_WALL / 2.0
    shell -= bd.Pos(
        j13_exit["center"],
        rear_wall_y,
        j13_exit["z"],
    ) * bd.Box(
        j13_exit["width"],
        BOTTOM_SHELL_WALL + 2.0,
        j13_exit["height"],
    )

    # The CN2 body reaches into the inner front corners of both lower cradles.
    # Preserve the same local relief that previously existed in the integrated
    # upper-shell towers.
    for x_min, x_max in ((-29.5, -27.3), (27.3, 29.5)):
        connector_corner_relief = bd.Pos(
            (x_min + x_max) / 2.0,
            36.1,
            11.0,
        ) * bd.Box(
            x_max - x_min,
            1.6,
            TOF_MOUNT_SPLIT_Z - 11.0 + 0.2,
            align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN),
        )
        shell -= connector_corner_relief

    for x in (-PCB_MOUNT_HOLE_X, PCB_MOUNT_HOLE_X):
        for y in (-PCB_MOUNT_HOLE_Y, PCB_MOUNT_HOLE_Y):
            pilot = bd.Pos(x, y, board_bottom_z - 7.0) * bd.Cylinder(
                PCB_STANDOFF_PILOT_DIAMETER / 2.0,
                7.1,
                align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN),
            )
            shell -= pilot

    shell = _main_solid(shell.clean())
    shell.label = "bottom_shell"
    shell.color = srgb("#353B42")
    return shell


def top_shell() -> bd.Shape:
    lid = rounded_box(
        TOP_SHELL_OUTER_WIDTH,
        TOP_SHELL_OUTER_DEPTH,
        TOP_SHELL_LID_THICKNESS,
        TOP_SHELL_PLATE_BOTTOM_Z,
        TOP_SHELL_CORNER_RADIUS,
    )
    shell = lid

    # The cable-side IDC socket is taller than the board-side box header.
    # Raise only the 40P area into a rounded service cap so the main top plane
    # and both ToF/keycap sight lines stay unchanged.
    cap_bottom_z = TOP_SHELL_TOTAL_HEIGHT - 2.0
    service_cap = rounded_box(
        J13_SERVICE_CAP_WIDTH,
        J13_SERVICE_CAP_DEPTH,
        J13_SERVICE_CAP_TOP_Z - cap_bottom_z,
        cap_bottom_z,
        J13_SERVICE_CAP_CORNER_RADIUS,
    )
    service_cap = service_cap.moved(
        bd.Location((0.0, J13_SERVICE_CAP_CENTER_Y, 0.0))
    )
    shell += service_cap

    # Downward gussets around the keyboard opening transfer finger loads into
    # the lid without using the PCB as a structural member.
    rail_bottom = TOP_SHELL_PLATE_BOTTOM_Z - 4.0
    rail_height = 4.2
    rail_x = KEYBOARD_OPENING_WIDTH / 2.0 + TOP_SHELL_WALL / 2.0
    rail_y = KEYBOARD_OPENING_DEPTH / 2.0 + TOP_SHELL_WALL / 2.0
    for x in (-rail_x, rail_x):
        shell += bd.Pos(x, 0, rail_bottom) * bd.Box(
            TOP_SHELL_WALL,
            KEYBOARD_OPENING_DEPTH + 2.0 * TOP_SHELL_WALL,
            rail_height,
            align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN),
        )
    shell += bd.Pos(0, -rail_y, rail_bottom) * bd.Box(
        KEYBOARD_OPENING_WIDTH + 2.0 * TOP_SHELL_WALL,
        TOP_SHELL_WALL,
        rail_height,
        align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN),
    )
    # Leave a central bridge in the rear rail for the actual 2x20 connector.
    rear_segment_width = 32.0
    rear_clear_width = (
        J13_CONNECTOR_WIDTH + 2.0 * J13_SHELL_CLEARANCE
    )
    rear_side_center_x = rear_clear_width / 2.0 + rear_segment_width / 2.0
    for x in (-rear_side_center_x, rear_side_center_x):
        shell += bd.Pos(x, rail_y, rail_bottom) * bd.Box(
            rear_segment_width,
            TOP_SHELL_WALL,
            rail_height,
            align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN),
        )

    # Local bosses carry blind sockets for the four keybed location posts.
    # Their Y envelopes stay at least 0.5 mm clear of the keycap fronts/rears.
    for locator_x, locator_y in KEYBED_LOCATOR_POSITIONS:
        boss_y = locator_y + (
            KEYBED_LOCATOR_BOSS_Y_OFFSET
            if locator_y > 0.0
            else -KEYBED_LOCATOR_BOSS_Y_OFFSET
        )
        shell += bd.Pos(locator_x, boss_y, rail_bottom) * bd.Box(
            KEYBED_LOCATOR_BOSS_WIDTH,
            KEYBED_LOCATOR_BOSS_DEPTH,
            TOP_SHELL_PLATE_BOTTOM_Z - rail_bottom,
            align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN),
        )

    # The narrower/deeper keyboard opening moves the rear rail over the four
    # M3 shell bosses. Relieve the rail underside around those fixed bosses;
    # the visible lid surface and screw counterbores remain unchanged.
    for x in (-TOP_SCREW_X, TOP_SCREW_X):
        for y in (-TOP_SCREW_Y, TOP_SCREW_Y):
            boss_clearance = bd.Pos(
                x,
                y,
                rail_bottom - 0.2,
            ) * bd.Cylinder(
                SHELL_SCREW_BOSS_DIAMETER / 2.0 + 0.3,
                TOP_SHELL_PLATE_BOTTOM_Z - rail_bottom + 0.2,
                align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN),
            )
            shell -= boss_clearance

    keyboard_cut = bd.Pos(
        0,
        0,
        TOP_SHELL_PLATE_BOTTOM_Z - 0.2,
    ) * bd.Box(
        KEYBOARD_OPENING_WIDTH,
        KEYBOARD_OPENING_DEPTH,
        J13_SERVICE_CAP_TOP_Z - (TOP_SHELL_PLATE_BOTTOM_Z - 0.2) + 0.2,
        align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN),
    )
    shell -= keyboard_cut

    for locator_x, locator_y in KEYBED_LOCATOR_POSITIONS:
        socket = bd.Pos(
            locator_x,
            locator_y,
            rail_bottom - 0.2,
        ) * bd.Cylinder(
            KEYBED_LOCATOR_SOCKET_DIAMETER / 2.0,
            KEYBED_LOCATOR_SOCKET_DEPTH + 0.2,
            align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN),
        )
        shell -= socket

    # The J13 body is taller than the switch stack. Recess only the underside
    # of the otherwise continuous top plate so the visible top stays planar.
    j13_clearance_top_z = (
        J13_CONNECTOR_BOTTOM_Z
        + J13_CONNECTOR_HEIGHT
        + J13_SHELL_CLEARANCE
    )
    j13_recess_bottom_z = TOP_SHELL_PLATE_BOTTOM_Z - 0.2
    j13_cut = bd.Pos(
        0,
        J13_CONNECTOR_CENTER_Y,
        j13_recess_bottom_z,
    ) * bd.Box(
        J13_CONNECTOR_WIDTH + 2.0 * J13_SHELL_CLEARANCE,
        J13_CONNECTOR_DEPTH + 2.0 * J13_SHELL_CLEARANCE,
        j13_clearance_top_z - j13_recess_bottom_z,
        align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN),
    )
    shell -= j13_cut

    # Allocate the published 55.4 x 6.1 x 10.7 mm cable-side IDC socket
    # envelope above the PCB.  The raised cap leaves 1.4 mm of roof above it.
    cable_recess_bottom_z = TOP_SHELL_PLATE_BOTTOM_Z - 0.2
    cable_cut = bd.Pos(
        0,
        J13_CONNECTOR_CENTER_Y,
        cable_recess_bottom_z,
    ) * bd.Box(
        J13_CABLE_RECESS_WIDTH,
        J13_CABLE_RECESS_DEPTH,
        J13_CABLE_RECESS_TOP_Z - cable_recess_bottom_z,
        align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN),
    )
    shell -= cable_cut

    for x in (-TOP_SCREW_X, TOP_SCREW_X):
        for y in (-TOP_SCREW_Y, TOP_SCREW_Y):
            clearance = bd.Pos(x, y, TOP_SHELL_PLATE_BOTTOM_Z - 0.2) * bd.Cylinder(
                TOP_SCREW_CLEARANCE_DIAMETER / 2.0,
                TOP_SHELL_LID_THICKNESS + 0.4,
                align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN),
            )
            counterbore = bd.Pos(
                x,
                y,
                TOP_SHELL_TOTAL_HEIGHT - TOP_SCREW_COUNTERBORE_DEPTH,
            ) * bd.Cylinder(
                TOP_SCREW_COUNTERBORE_DIAMETER / 2.0,
                TOP_SCREW_COUNTERBORE_DEPTH + 0.2,
                align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN),
            )
            shell -= [clearance, counterbore]

    # Only the removable optical hood sits above the shell seam.  The sensor
    # seat, cable exit and lower light-well walls now remain in the bottom.
    for mount in shell_tof_upper_mounts().solids():
        shell += mount
    shell -= shell_tof_module_pocket_tools()
    shell -= shell_tof_aperture_tools()
    shell -= shell_tof_inner_cable_tools()

    # The CN2 3D body is 58.4 mm wide and extends into the two inner front
    # corners of the ToF towers. Relieve only those interior corners, well
    # before the 31 x 15 mm optical modules begin.
    for x_min, x_max in ((-29.5, -27.3), (27.3, 29.5)):
        connector_corner_relief = bd.Pos(
            (x_min + x_max) / 2.0,
            36.1,
            11.0,
        ) * bd.Box(
            x_max - x_min,
            1.6,
            12.9,
            align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN),
        )
        shell -= connector_corner_relief

    shell = _main_solid(shell)
    shell.label = "top_shell"
    shell.color = srgb("#4A5158")
    return shell
