"""R1 enclosure checks on the saved STEP assembly and child documents."""

from __future__ import annotations

import json
import math
from itertools import combinations
from pathlib import Path

import ezdxf
from cadgen import build123d as bd
from cadgen import read_scene
from cadgen.drawing_checks import validate_dxf_file
from cadgen.geometry import boundary_edges, closest_points, overlap_volume, topology_errors
from ezdxf import bbox as dxf_bbox

from lib.params import (
    BOTTOM_SHELL_OUTER_DEPTH,
    BOTTOM_SHELL_OUTER_WIDTH,
    BOTTOM_SHELL_WALL,
    BLACK_CAP_DEPTH,
    CABLE_CLAMP_HOLE_DIAMETER,
    CABLE_CLAMP_HOLE_OFFSET,
    CABLE_EXIT_SPECS,
    FULL_TRAVEL_CAP_TO_PLATE_GAP,
    IDC_PLUG_DEPTH,
    IDC_PLUG_HEIGHT,
    IDC_PLUG_WIDTH,
    J13_CABLE_RECESS_TOP_Z,
    J13_CONNECTOR_CENTER_Y,
    J13_SERVICE_CAP_TOP_Z,
    KEYBED_LOCATOR_PIN_DIAMETER,
    KEYBED_LOCATOR_PIN_TOP_Z,
    KEYBED_LOCATOR_POSITIONS,
    KEYBED_LOCATOR_BOSS_DEPTH,
    KEYBED_LOCATOR_BOSS_WIDTH,
    KEYBED_LOCATOR_BOSS_Y_OFFSET,
    KEYBED_LOCATOR_SOCKET_DEPTH,
    KEYBED_LOCATOR_SOCKET_DIAMETER,
    KEYBED_PCB_FRONT_EXPOSURE_MIN,
    KEYBED_PLATE_FRONT_Y,
    KEYBED_PLATE_REAR_Y,
    KEYBED_PLATE_TOP_Y,
    KEYBED_PLATE_WIDTH,
    KEYBOARD_OPENING_DEPTH,
    KEYBOARD_OPENING_WIDTH,
    PCB_MOUNT_HOLE_X,
    PCB_MOUNT_HOLE_Y,
    PCB_DOWN_HEADER_BODY_Z_MAX,
    PCB_DOWN_HEADER_BODY_Z_MIN,
    PCB_DOWN_HEADER_PIN_DIAMETER,
    PCB_DOWN_HEADER_PIN_Z_MAX,
    PCB_DOWN_HEADER_PIN_Z_MIN,
    PCB_PLACEHOLDER_DEPTH,
    PCB_PLACEHOLDER_WIDTH,
    PCB_STANDOFF_RELIEF_ENVELOPES,
    PCB_THICKNESS,
    PCB_TOP_Z,
    PHOTO_WIRE_COUNT,
    PHOTO_WIRE_DIAMETER,
    PHOTO_POWER_WIRE_COUNT,
    PHOTO_POWER_WIRE_DIAMETER,
    SHELL_TOF_BASE_Y,
    SHELL_TOF_LEFT_X,
    SHELL_TOF_RIGHT_X,
    SWITCH_BODY_WIDTH,
    SWITCH_PAD_RELIEF_DEPTH,
    SWITCH_PAD_RELIEF_SIZE,
    SWITCH_POCKET_DEPTH,
    SWITCH_POCKET_MIN_CLEARANCE,
    SWITCH_POCKET_WIDTH,
    SWITCH_TOTAL_HEIGHT,
    SWITCH_TRAVEL,
    TOF_MODULE_DEPTH,
    TOF_MODULE_CLEARANCE_PER_SIDE,
    TOF_MODULE_HEIGHT,
    TOF_MODULE_WIDTH,
    TOF_SEAT_THICKNESS,
    TOF_MOUNT_OUTER_HEIGHT,
    TOF_MOUNT_OUTER_WIDTH,
    TOF_MOUNT_SPLIT_Z,
    TOF_MOUNT_WALL,
    TOF_APERTURE_HEIGHT,
    TOF_APERTURE_CORNER_RADIUS,
    TOF_APERTURE_WIDTH,
    TOF_INNER_CABLE_WINDOW_HEIGHT,
    TOF_INNER_CABLE_WINDOW_WIDTH,
    TOF_INNER_CABLE_WINDOW_Z,
    TOF_LIGHT_WELL_DEPTH,
    WHITE_CAP_DEPTH,
    TOP_SHELL_OUTER_DEPTH,
    TOP_SHELL_OUTER_WIDTH,
    TOP_SHELL_PLATE_BOTTOM_Z,
    TOP_SHELL_TOTAL_HEIGHT,
    TOP_SCREW_X,
    TOP_SCREW_Y,
)


ROOT = Path(__file__).resolve().parents[1]
ASSEMBLY = ROOT / "STEP" / "assembly.step"
BOARD_DXF = ROOT / "DXF" / "board_outline.dxf"
REPORT_DIR = ROOT / "reports" / "2026-10-28"
REPORT = REPORT_DIR / "shell_checks.json"


def close(actual: float, expected: float, tolerance: float = 0.02) -> bool:
    return abs(actual - expected) <= tolerance


def bbox(shape: bd.Shape) -> tuple[bd.Vector, bd.Vector, bd.Vector]:
    box = shape.bounding_box()
    return box.min, box.max, box.size


def long_edge_direction(shape: bd.Shape) -> bd.Vector:
    edge = max(shape.edges(), key=lambda item: item.length)
    return (edge @ 1 - edge @ 0).normalized()


def main() -> None:
    failures: list[str] = []
    scene = read_scene(ASSEMBLY)
    leaves = list(scene.leaves())
    by_label = {leaf.label: leaf for leaf in leaves}

    required = [
        "bottom_shell_part",
        "top_shell_part",
        "keybed_plate",
        "pcb_placeholder",
        "j13_2x20_connector_reference",
        "tof_left:vb22b_reference",
        "tof_right:vb22b_reference",
        "tof_left:detection_axis",
        "tof_right:detection_axis",
    ]
    missing = [label for label in required if label not in by_label]
    if missing:
        raise SystemExit(f"Missing required leaves: {missing}")

    shell_records = {}
    for label in ("bottom_shell_part", "top_shell_part"):
        shape = by_label[label].shape()
        solids = shape.solids()
        free_edges = [
            edge
            for solid in solids
            for shell in solid.shells()
            for edge in boundary_edges(shell)
        ]
        issues = topology_errors(shape)
        if len(solids) != 1 or not shape.is_valid or shape.volume <= 0:
            failures.append(f"{label} is not one valid positive-volume solid")
        if free_edges:
            failures.append(f"{label} has {len(free_edges)} free edges")
        if issues:
            failures.append(f"{label} topology issues: {[issue.code for issue in issues]}")
        shell_records[label] = {
            "solids": len(solids),
            "volume_mm3": round(shape.volume, 3),
            "bbox_mm": [round(value, 3) for value in bbox(shape)[2]],
            "free_edges": len(free_edges),
            "topology_issues": len(issues),
        }

    bottom_size = bbox(by_label["bottom_shell_part"].shape())[2]
    if not close(bottom_size.X, BOTTOM_SHELL_OUTER_WIDTH, 0.02) or not close(
        bottom_size.Y, BOTTOM_SHELL_OUTER_DEPTH, 0.02
    ):
        failures.append(f"Bottom shell footprint mismatch: {bottom_size}")
    top_size = bbox(by_label["top_shell_part"].shape())[2]
    if not close(top_size.X, TOP_SHELL_OUTER_WIDTH, 0.02) or not close(
        top_size.Y, TOP_SHELL_OUTER_DEPTH, 0.02
    ):
        failures.append(f"Top shell footprint mismatch: {top_size}")
    if not close(TOP_SCREW_X, 58.0, 0.001) or not close(TOP_SCREW_Y, 25.0, 0.001):
        failures.append(
            f"Shell screw pattern changed: X={TOP_SCREW_X}, Y={TOP_SCREW_Y}"
        )

    caps = {
        label: leaf.shape().solids()[0]
        for label, leaf in by_label.items()
        if label.startswith("white_key_") or label.startswith("black_key_after_white_")
    }
    if len(caps) != 13:
        failures.append(f"Expected 13 keycaps, found {len(caps)}")
    black_caps = {
        label: cap
        for label, cap in caps.items()
        if label.startswith("black_key_after_white_")
    }

    switch_bodies = {
        label: leaf.shape().solids()[0]
        for label, leaf in by_label.items()
        if label.startswith("switch_") and label.endswith(":body")
    }
    if len(switch_bodies) != 13:
        failures.append(f"Expected 13 switch bodies, found {len(switch_bodies)}")

    top = by_label["top_shell_part"].shape().solids()[0]
    bottom = by_label["bottom_shell_part"].shape().solids()[0]
    plate = by_label["keybed_plate"].shape().solids()[0]
    pcb = by_label["pcb_placeholder"].shape().solids()[0]
    connector = by_label["j13_2x20_connector_reference"].shape().solids()[0]
    tof_modules = {
        label: by_label[label].shape().solids()[0]
        for label in (
            "tof_left:vb22b_reference",
            "tof_right:vb22b_reference",
        )
    }
    axes = {
        label: by_label[label].shape().solids()[0]
        for label in (
            "tof_left:detection_axis",
            "tof_right:detection_axis",
        )
    }

    down_header_checks = {}
    for header, (x_min, y_min, x_max, y_max) in PCB_STANDOFF_RELIEF_ENVELOPES:
        body_probe = (
            bd.Pos(
                (x_min + x_max) / 2.0,
                (y_min + y_max) / 2.0,
                PCB_DOWN_HEADER_BODY_Z_MIN,
            )
            * bd.Box(
                x_max - x_min,
                y_max - y_min,
                PCB_DOWN_HEADER_BODY_Z_MAX - PCB_DOWN_HEADER_BODY_Z_MIN,
                align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN),
            )
        ).solid()
        body_overlaps = {
            "bottom_shell": round(overlap_volume(body_probe, bottom), 4),
            "top_shell": round(overlap_volume(body_probe, top), 4),
            "keybed": round(overlap_volume(body_probe, plate), 4),
        }
        pitch = 2.54
        pin_count = max(1, round((x_max - x_min) / pitch))
        pin_centres = [
            (
                x_min + (index + 0.5) * (x_max - x_min) / pin_count,
                (y_min + y_max) / 2.0,
            )
            for index in range(pin_count)
        ]
        pin_overlap = 0.0
        pin_clearance = float("inf")
        for pin_x, pin_y in pin_centres:
            pin = bd.Pos(
                pin_x,
                pin_y,
                PCB_DOWN_HEADER_PIN_Z_MIN,
            ) * bd.Cylinder(
                PCB_DOWN_HEADER_PIN_DIAMETER / 2.0,
                PCB_DOWN_HEADER_PIN_Z_MAX - PCB_DOWN_HEADER_PIN_Z_MIN,
                align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN),
            )
            pin_solid = pin.solid()
            pin_overlap += overlap_volume(pin_solid, bottom)
            pin_clearance = min(pin_clearance, closest_points(pin_solid, bottom).distance)
        body_clearance = closest_points(body_probe, bottom).distance
        down_header_checks[header] = {
            "body": body_overlaps,
            "body_min_clearance_mm": round(body_clearance, 4),
            "pins_to_bottom_mm3": round(pin_overlap, 4),
            "pins_min_clearance_mm": round(pin_clearance, 4),
        }
        if any(value > 0.01 for value in body_overlaps.values()) or pin_overlap > 0.01:
            failures.append(
                f"Downward header {header} has shell overlap: "
                f"{down_header_checks[header]}"
            )
        if body_clearance < 0.30 - 0.01 or pin_clearance < 0.30 - 0.01:
            failures.append(
                f"Downward header {header} clearance below 0.30 mm: "
                f"body={body_clearance:.4f}, pins={pin_clearance:.4f}"
            )

    black_key_top_z = max(bbox(cap)[1].Z for cap in black_caps.values())
    if not close(TOP_SHELL_TOTAL_HEIGHT, black_key_top_z, 0.01):
        failures.append(
            f"Main shell plane {TOP_SHELL_TOTAL_HEIGHT:.3f} is not flush with "
            f"black key tops {black_key_top_z:.3f}"
        )
    if not close(bbox(top)[1].Z, J13_SERVICE_CAP_TOP_Z, 0.01):
        failures.append(
            f"J13 service cap top {bbox(top)[1].Z:.3f} does not match "
            f"the intended {J13_SERVICE_CAP_TOP_Z:.3f}"
        )

    opening_half_width = KEYBOARD_OPENING_WIDTH / 2.0
    opening_half_depth = KEYBOARD_OPENING_DEPTH / 2.0
    plate_min, plate_max, _ = bbox(plate)
    if plate_min.X > -opening_half_width + 0.01:
        failures.append("Keybed has no left-side underlap at the keyboard opening")
    if plate_max.X < opening_half_width - 0.01:
        failures.append("Keybed has no right-side underlap at the keyboard opening")
    if plate_min.Y > -opening_half_depth + 0.01:
        failures.append("Keybed does not cover the front edge of the keyboard opening")
    if plate_max.Y < opening_half_depth - 0.01:
        failures.append("Keybed does not cover the rear edge of the keyboard opening")

    opening_cap_clearances = {}
    for label, cap in caps.items():
        cap_box = cap.bounding_box()
        clearances = {
            "left": round(cap_box.min.X + opening_half_width, 4),
            "right": round(opening_half_width - cap_box.max.X, 4),
            "front": round(cap_box.min.Y + opening_half_depth, 4),
            "rear": round(opening_half_depth - cap_box.max.Y, 4),
        }
        opening_cap_clearances[label] = clearances
        if min(clearances.values()) < 0.5 - 0.01:
            failures.append(
                f"{label} has less than 0.5 mm clearance to keyboard opening: "
                f"{clearances}"
            )

    pad_relief_probes = {}
    for label, body in switch_bodies.items():
        body_box = body.bounding_box()
        probe = (
            bd.Pos(
                (body_box.min.X + body_box.max.X) / 2.0,
                (body_box.min.Y + body_box.max.Y) / 2.0,
                PCB_TOP_Z + 0.05,
            )
            * bd.Box(
                SWITCH_PAD_RELIEF_SIZE - 0.2,
                SWITCH_PAD_RELIEF_SIZE - 0.2,
                SWITCH_PAD_RELIEF_DEPTH - 0.1,
                align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN),
            )
        ).solid()
        overlap = overlap_volume(plate, probe)
        pad_relief_probes[label] = round(overlap, 4)
        if overlap > 0.01:
            failures.append(f"{label} underside pad relief is obstructed: {overlap:.3f} mm3")

    locator_records = {}
    locator_probe_length = (
        KEYBED_LOCATOR_PIN_TOP_Z
        - (PCB_TOP_Z + KEYBED_PLATE_TOP_Y)
        + 0.10
    )
    locator_probe_radius = (KEYBED_LOCATOR_PIN_DIAMETER - 0.15) / 2.0
    locator_expected_overlap = math.pi * locator_probe_radius**2 * locator_probe_length
    rail_bottom = TOP_SHELL_PLATE_BOTTOM_Z - 4.0
    for index, (locator_x, locator_y) in enumerate(KEYBED_LOCATOR_POSITIONS, start=1):
        post_probe = bd.Pos(
            locator_x,
            locator_y,
            PCB_TOP_Z + KEYBED_PLATE_TOP_Y + 0.05,
        ) * bd.Cylinder(
            locator_probe_radius,
            locator_probe_length,
            align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN),
        )
        post_solid = plate & post_probe.solid()
        post_solid_volume = post_solid.volume
        post_tip_z = bbox(post_solid)[1].Z
        socket_probe = bd.Pos(
            locator_x,
            locator_y,
            rail_bottom + 0.05,
        ) * bd.Cylinder(
            (KEYBED_LOCATOR_SOCKET_DIAMETER - 0.15) / 2.0,
            KEYBED_LOCATOR_SOCKET_DEPTH - 0.15,
            align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN),
        )
        socket_overlap = overlap_volume(top, socket_probe.solid())
        engagement = min(
            KEYBED_LOCATOR_PIN_TOP_Z - rail_bottom,
            KEYBED_LOCATOR_SOCKET_DEPTH,
        )
        socket_floor_clearance = (
            rail_bottom
            + KEYBED_LOCATOR_SOCKET_DEPTH
            - post_tip_z
        )
        lid_intersection = overlap_volume(plate, top)
        locator_records[f"L{index}"] = {
            "position": [locator_x, locator_y],
            "post_solid_probe_volume_mm3": round(post_solid_volume, 4),
            "post_tip_z_mm": round(post_tip_z, 4),
            "engagement_mm": round(engagement, 4),
            "socket_floor_clearance_mm": round(socket_floor_clearance, 4),
            "socket_void_overlap_mm3": round(socket_overlap, 4),
            "keybed_lid_intersection_mm3": round(lid_intersection, 4),
        }
        if post_solid_volume < 0.8 * locator_expected_overlap:
            failures.append(f"Keybed locator post L{index} is missing or incomplete")
        if socket_overlap > 0.01:
            failures.append(f"Top-shell locator socket L{index} is obstructed")
        if lid_intersection > 0.01:
            failures.append(f"Keybed/lid locator intersection L{index} is not zero")

    locator_boss_cap_clearances = {}
    for index, (locator_x, locator_y) in enumerate(KEYBED_LOCATOR_POSITIONS, start=1):
        boss_y = locator_y + (
            KEYBED_LOCATOR_BOSS_Y_OFFSET
            if locator_y > 0.0
            else -KEYBED_LOCATOR_BOSS_Y_OFFSET
        )
        boss_probe = (
            bd.Pos(
                locator_x,
                boss_y,
                rail_bottom,
            )
            * bd.Box(
                KEYBED_LOCATOR_BOSS_WIDTH,
                KEYBED_LOCATOR_BOSS_DEPTH,
                TOP_SHELL_PLATE_BOTTOM_Z - rail_bottom,
                align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN),
            )
        ).solid()
        minimum = min(closest_points(boss_probe, cap).distance for cap in caps.values())
        locator_boss_cap_clearances[f"L{index}"] = round(minimum, 4)
        if minimum < 0.5 - 0.01:
            failures.append(
                f"Locator boss L{index} is only {minimum:.3f} mm from a keycap"
            )
    tof_outer_y = SHELL_TOF_BASE_Y + TOF_MOUNT_OUTER_HEIGHT / 2.0
    top_rear_edge_y = bbox(top)[1].Y
    bottom_rear_edge_y = bbox(bottom)[1].Y
    if not close(top_rear_edge_y, tof_outer_y, 0.01):
        failures.append(
            f"Shell rear edge Y={top_rear_edge_y:.3f} is not flush with "
            f"ToF outer edge Y={tof_outer_y:.3f}"
        )
    if not close(bottom_rear_edge_y, tof_outer_y, 0.01):
        failures.append(
            f"Bottom shell rear edge Y={bottom_rear_edge_y:.3f} is not flush with "
            f"ToF outer edge Y={tof_outer_y:.3f}"
        )

    intended_pairs = [
        ("top/bottom", top, bottom, "overlap"),
        ("top/keybed", top, plate, "overlap"),
        ("bottom/keybed", bottom, plate, "overlap"),
        ("top/pcb", top, pcb, "overlap"),
        ("bottom/pcb", bottom, pcb, "overlap"),
        ("keybed/pcb", plate, pcb, "overlap"),
        ("keybed/j13", plate, connector, "overlap"),
        ("top/j13", top, connector, "overlap"),
        ("bottom/tof_left", bottom, tof_modules["tof_left:vb22b_reference"], "overlap"),
        ("bottom/tof_right", bottom, tof_modules["tof_right:vb22b_reference"], "overlap"),
        ("top/tof_left", top, tof_modules["tof_left:vb22b_reference"], "overlap"),
        ("top/tof_right", top, tof_modules["tof_right:vb22b_reference"], "overlap"),
    ]

    for cap_label, cap in caps.items():
        intended_pairs.append((f"top/{cap_label}", top, cap, "overlap"))
        intended_pairs.append((f"j13/{cap_label}", connector, cap, "overlap"))

    for label, a, b, mode in intended_pairs:
        overlap = overlap_volume(a, b)
        if overlap > 0.01:
            failures.append(f"Unintended overlap {label}: {overlap:.4f} mm3")

    j13_profile = next(spec for spec in CABLE_EXIT_SPECS if spec["name"] == "fpga_j13")
    if (
        j13_profile["width"] < IDC_PLUG_WIDTH + 1.0
        or j13_profile["height"] < IDC_PLUG_HEIGHT + 1.0
    ):
        failures.append("Rear 40P FFC service opening is undersized")
    j13_envelope_min, j13_envelope_max, _ = bbox(connector)
    _, j13_pcb_max, _ = bbox(pcb)
    j13_rear_edge_margin = j13_pcb_max.Y - j13_envelope_max.Y
    if j13_rear_edge_margin < -2.0:
        failures.append(
            f"J13 body overhangs PCB rear edge by {-j13_rear_edge_margin:.3f} mm"
        )

    idc_plug = (
        bd.Pos(0, J13_CONNECTOR_CENTER_Y, PCB_TOP_Z)
        * bd.Box(
            IDC_PLUG_WIDTH,
            IDC_PLUG_DEPTH,
            IDC_PLUG_HEIGHT,
            align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN),
        )
    ).solid()
    idc_plug_top_overlap = overlap_volume(top, idc_plug)
    if idc_plug_top_overlap > 0.01:
        failures.append(
            f"Cable-side IDC plug intersects the upper shell by "
            f"{idc_plug_top_overlap:.3f} mm3"
        )

    idc_pass_probe = (
        bd.Pos(
            0,
            BOTTOM_SHELL_OUTER_DEPTH / 2.0 - BOTTOM_SHELL_WALL / 2.0,
            j13_profile["z"],
        )
        * bd.Box(
            IDC_PLUG_WIDTH,
            BOTTOM_SHELL_WALL + 2.0,
            IDC_PLUG_HEIGHT,
        )
    ).solid()
    idc_pass_overlap = overlap_volume(bottom, idc_pass_probe)
    if idc_pass_overlap > 0.01:
        failures.append(
            f"Pre-terminated 40P IDC plug cannot pass the rear opening: "
            f"{idc_pass_overlap:.3f} mm3"
        )

    seam_distance = closest_points(top, bottom).distance
    if seam_distance > 0.01:
        failures.append(f"Top/bottom seam distance is {seam_distance:.3f} mm")

    # With the PCB-top datum at Y=0 in the keybed model, the physical shell
    # placing it at Z=12 keeps the complete switch height inside the body.
    theoretical_cap_rest_z = PCB_TOP_Z + SWITCH_TOTAL_HEIGHT
    theoretical_full_press_z = theoretical_cap_rest_z - SWITCH_TRAVEL
    theoretical_plate_top_z = PCB_TOP_Z + KEYBED_PLATE_TOP_Y
    if not close(SWITCH_TOTAL_HEIGHT, 5.0, 0.001):
        failures.append(f"Switch total height {SWITCH_TOTAL_HEIGHT} is not 5.0 mm")
    if theoretical_full_press_z - theoretical_plate_top_z < 0.9:
        failures.append("Insufficient keybed clearance at full switch travel")
    if not close(FULL_TRAVEL_CAP_TO_PLATE_GAP, 1.0, 0.01):
        failures.append(f"Full-travel keybed clearance is {FULL_TRAVEL_CAP_TO_PLATE_GAP}")

    for label, body in switch_bodies.items():
        clearance = closest_points(body, plate).distance
        if clearance < SWITCH_POCKET_MIN_CLEARANCE - 0.001:
            failures.append(
                f"{label} to keybed clearance is {clearance:.3f} mm, "
                f"below {SWITCH_POCKET_MIN_CLEARANCE:.3f} mm"
            )
        pcb_clearance = closest_points(body, pcb).distance
        if pcb_clearance > 0.02:
            failures.append(
                f"{label} does not seat on the PCB: {pcb_clearance:.3f} mm gap"
            )

    # The provisional board fits fully inside the bottom cavity.
    inner_width = BOTTOM_SHELL_OUTER_WIDTH - 2.0 * BOTTOM_SHELL_WALL
    inner_depth = BOTTOM_SHELL_OUTER_DEPTH - 2.0 * BOTTOM_SHELL_WALL
    pcb_min, pcb_max, pcb_size = bbox(pcb)
    if pcb_size.X >= inner_width or pcb_size.Y >= inner_depth:
        failures.append("PCB placeholder does not fit inside the R1 bottom cavity")
    if pcb_min.Z < 10.3:
        failures.append(f"PCB is too low for switch pins: min Z={pcb_min.Z:.3f}")

    plate_min, plate_max, _ = bbox(plate)
    pcb_front_cantilever = plate_min.Y - pcb_min.Y
    if pcb_front_cantilever < KEYBED_PCB_FRONT_EXPOSURE_MIN - 0.01:
        failures.append(
            f"PCB front cantilever is only {pcb_front_cantilever:.3f} mm; "
            f"expected at least {KEYBED_PCB_FRONT_EXPOSURE_MIN:.1f} mm"
        )
    if not close(plate_min.Y, KEYBED_PLATE_FRONT_Y, 0.01):
        failures.append(
            f"Keybed front edge is {plate_min.Y:.3f} mm, expected "
            f"{KEYBED_PLATE_FRONT_Y:.3f} mm"
        )
    if not close(plate_max.Y, KEYBED_PLATE_REAR_Y, 0.01):
        failures.append(
            f"Keybed rear edge is {plate_max.Y:.3f} mm, expected "
            f"{KEYBED_PLATE_REAR_Y:.3f} mm"
        )
    for label, cap in caps.items():
        cap_center_y = bbox(cap)[0].Y + bbox(cap)[2].Y / 2.0
        expected_center_y = (
            0.0
            if label.startswith("white_key_")
            else (WHITE_CAP_DEPTH - BLACK_CAP_DEPTH) / 2.0
        )
        if abs(cap_center_y - expected_center_y) > 0.02:
            failures.append(
                f"{label} shifted by {cap_center_y - expected_center_y:.3f} mm "
                "when shortening keybed"
            )

    # The bottom support pads reach the provisional board underside.
    pcb_to_bottom_distance = closest_points(pcb, bottom).distance
    if pcb_to_bottom_distance > 0.05:
        failures.append(
            f"PCB support pads miss board underside by {pcb_to_bottom_distance:.3f} mm"
        )

    for module_label, module in tof_modules.items():
        module_size = bbox(module)[2]
        if not (
            close(module_size.X, TOF_MODULE_WIDTH, 0.02)
            and close(module_size.Y, TOF_MODULE_HEIGHT, 0.02)
            and close(module_size.Z, TOF_MODULE_DEPTH, 0.02)
        ):
            failures.append(f"{module_label} envelope mismatch: {module_size}")
        if not close(bbox(module)[0].Z, TOF_SEAT_THICKNESS, 0.02):
            failures.append(
                f"{module_label} does not sit on the {TOF_SEAT_THICKNESS:.3f} mm "
                "bottom-shell seat"
            )

    aperture_probes = {}
    for label, x in (("tof_left", SHELL_TOF_LEFT_X), ("tof_right", SHELL_TOF_RIGHT_X)):
        aperture_profile = (
            bd.Plane.XY.offset(TOF_MODULE_DEPTH)
            * bd.RectangleRounded(
                TOF_APERTURE_WIDTH - 0.4,
                TOF_APERTURE_HEIGHT - 0.4,
                TOF_APERTURE_CORNER_RADIUS - 0.2,
            )
        )
        aperture_probe = bd.Pos(x, SHELL_TOF_BASE_Y, 0) * bd.extrude(
            aperture_profile,
            amount=TOF_LIGHT_WELL_DEPTH - 0.2,
        ).solids()[0]
        aperture_overlap = overlap_volume(top, aperture_probe) + overlap_volume(
            bottom, aperture_probe
        )
        aperture_probes[label] = round(aperture_overlap, 4)
        if aperture_overlap > 0.01:
            failures.append(f"{label} rectangular aperture is obstructed")
    if TOF_MODULE_WIDTH - TOF_APERTURE_WIDTH < 0.9:
        failures.append("ToF aperture leaves less than a 0.45 mm side lip")
    if TOF_MODULE_HEIGHT - TOF_APERTURE_HEIGHT < 0.9:
        failures.append("ToF aperture leaves less than a 0.45 mm front/back lip")
    narrow_face_margin_y = (TOF_MODULE_HEIGHT - TOF_INNER_CABLE_WINDOW_WIDTH) / 2.0
    narrow_face_margin_z = (TOF_MODULE_DEPTH - TOF_INNER_CABLE_WINDOW_HEIGHT) / 2.0
    if narrow_face_margin_y < 1.2 or narrow_face_margin_z < 1.2:
        failures.append("ToF narrow-side cable window leaves less than a 1.2 mm lip")

    tof_inner_cable_probes = {}
    for label, x in (("tof_left", SHELL_TOF_LEFT_X), ("tof_right", SHELL_TOF_RIGHT_X)):
        toward_center = 1.0 if x < 0.0 else -1.0
        wall_center_x = x + toward_center * (
            TOF_MOUNT_OUTER_WIDTH / 2.0 - TOF_MOUNT_WALL / 2.0
        )
        probe = (
            bd.Pos(wall_center_x, SHELL_TOF_BASE_Y, TOF_INNER_CABLE_WINDOW_Z)
            * bd.Box(
                TOF_MOUNT_WALL - 0.2,
                TOF_INNER_CABLE_WINDOW_WIDTH - 0.2,
                TOF_INNER_CABLE_WINDOW_HEIGHT - 0.2,
            )
        ).solid()
        clear_volume = overlap_volume(bottom, probe)
        tof_inner_cable_probes[label] = round(clear_volume, 4)
        if clear_volume > 0.01:
            failures.append(f"{label} inner cable passage is obstructed")

    lower_tof_top_overlaps = {}
    lower_tof_bottom_probes = {}
    lower_tof_seat_volumes = {}
    for label, x in (("tof_left", SHELL_TOF_LEFT_X), ("tof_right", SHELL_TOF_RIGHT_X)):
        lower_envelope = (
            bd.Pos(x, SHELL_TOF_BASE_Y, TOF_MOUNT_SPLIT_Z / 2.0)
            * bd.Box(
                TOF_MOUNT_OUTER_WIDTH - 0.4,
                TOF_MOUNT_OUTER_HEIGHT - 0.4,
                TOF_MOUNT_SPLIT_Z - 0.4,
            )
        ).solid()
        top_overlap = overlap_volume(top, lower_envelope)
        lower_tof_top_overlaps[label] = round(top_overlap, 4)
        if top_overlap > 0.01:
            failures.append(
                f"{label} lower mount still moves with the upper shell: "
                f"{top_overlap:.3f} mm3"
            )

        outer_wall_probe = (
            bd.Pos(
                x,
                SHELL_TOF_BASE_Y + TOF_MOUNT_OUTER_HEIGHT / 2.0
                - TOF_MOUNT_WALL / 2.0,
                TOF_MOUNT_SPLIT_Z / 2.0,
            )
            * bd.Box(
                TOF_MOUNT_OUTER_WIDTH - 2.0,
                TOF_MOUNT_WALL - 0.2,
                TOF_MOUNT_SPLIT_Z - 1.0,
            )
        ).solid()
        bottom_volume = overlap_volume(bottom, outer_wall_probe)
        lower_tof_bottom_probes[label] = round(bottom_volume, 4)
        if bottom_volume <= 0.01:
            failures.append(f"{label} lower mount is missing from the bottom shell")

        seat_probe = (
            bd.Pos(x, SHELL_TOF_BASE_Y, TOF_SEAT_THICKNESS / 2.0)
            * bd.Box(20.0, 10.0, TOF_SEAT_THICKNESS - 0.2)
        ).solid()
        seat_volume = overlap_volume(bottom, seat_probe)
        lower_tof_seat_volumes[label] = round(seat_volume, 4)
        if seat_volume <= 0.01:
            failures.append(f"{label} bottom-shell seat is missing")

    # Detection axes must avoid the shells, PCB, keybed and all keycaps.
    axis_obstructions = {}
    for axis_label, axis in axes.items():
        obstacles = {
            "bottom_shell": bottom,
            "top_shell": top,
            "pcb": pcb,
            "keybed": plate,
            **{f"cap:{label}": cap for label, cap in caps.items()},
        }
        collisions = []
        for obstacle_label, obstacle in obstacles.items():
            volume = overlap_volume(axis, obstacle)
            if volume > 0.01:
                collisions.append((obstacle_label, round(volume, 4)))
        axis_obstructions[axis_label] = collisions
        if collisions:
            failures.append(f"{axis_label} obstructed by {collisions}")

    expected_up = bd.Vector(0, 0, 1)
    axis_errors = {}
    for axis_label, axis in axes.items():
        direction = long_edge_direction(axis)
        error = min(
            direction.get_angle(expected_up),
            (-direction).get_angle(expected_up),
        )
        axis_errors[axis_label] = round(error, 4)
        if error > 0.1:
            failures.append(f"{axis_label} is not vertical: {error:.3f} deg")

    module_centres = [bbox(module)[0].X + bbox(module)[2].X / 2.0 for module in tof_modules.values()]
    separation = abs(module_centres[0] - module_centres[1])
    if separation < 80.0:
        failures.append(f"ToF centre separation is only {separation:.3f} mm")

    cable_exit_probes = {}
    for spec in CABLE_EXIT_SPECS:
        name = spec["name"]
        width = spec["width"]
        height = spec["height"]
        z = spec["z"]
        clamp_offset = spec.get("clamp_offset", CABLE_CLAMP_HOLE_OFFSET)
        if spec["face"] in ("rear", "front"):
            side_y = 1.0 if spec["face"] == "rear" else -1.0
            probe = (
                bd.Pos(
                    spec["center"],
                    side_y
                    * (BOTTOM_SHELL_OUTER_DEPTH / 2.0 - BOTTOM_SHELL_WALL / 2.0),
                    z,
                )
                * bd.Box(
                    width - 0.15,
                    BOTTOM_SHELL_WALL + 2.0,
                    height - 0.15,
                )
            ).solid()
        else:
            side = -1.0 if spec["face"] == "left" else 1.0
            probe = (
                bd.Pos(
                    side * BOTTOM_SHELL_OUTER_WIDTH / 2.0,
                    spec["center"],
                    z,
                )
                * bd.Box(
                    BOTTOM_SHELL_WALL + 1.0,
                    width - 0.15,
                    height - 0.15,
                )
            ).solid()
        overlap = overlap_volume(bottom, probe)
        cable_exit_probes[name] = round(overlap, 4)
        if overlap > 0.01:
            failures.append(f"Cable exit {name} is obstructed: {overlap:.3f} mm3")

    front_ports = {
        spec["name"]: spec
        for spec in CABLE_EXIT_SPECS
        if spec["face"] == "front"
    }
    if set(front_ports) != {"photo_6ch", "encoder_4ch"}:
        failures.append(f"Unexpected front cable ports: {sorted(front_ports)}")
    else:
        photo_port = front_ports["photo_6ch"]
        encoder_port = front_ports["encoder_4ch"]
        if photo_port["width"] < 40.0 or photo_port["height"] < 16.0:
            failures.append("Front photo/12V service opening is smaller than 40 x 16 mm")
        if encoder_port["width"] < 32.0 or encoder_port["height"] < 12.0:
            failures.append("Front encoder opening is smaller than 32 x 12 mm")
        photo_interval = (
            photo_port["center"] - photo_port["width"] / 2.0,
            photo_port["center"] + photo_port["width"] / 2.0,
        )
        encoder_interval = (
            encoder_port["center"] - encoder_port["width"] / 2.0,
            encoder_port["center"] + encoder_port["width"] / 2.0,
        )
        if encoder_interval[0] - photo_interval[1] < 8.0:
            failures.append("Front cable openings leave less than 8 mm web between them")

    rear_side_ports = {
        spec["name"]: spec
        for spec in CABLE_EXIT_SPECS
        if spec["face"] in ("left", "right")
    }
    if set(rear_side_ports) != {"rear_aux_left", "rear_aux_right"}:
        failures.append(f"Unexpected rear side cable ports: {sorted(rear_side_ports)}")
    else:
        left_side = rear_side_ports["rear_aux_left"]
        right_side = rear_side_ports["rear_aux_right"]
        for side_name, side_port in rear_side_ports.items():
            if side_port["width"] < 10.0 or side_port["height"] < 6.0:
                failures.append(
                    f"Rear side opening {side_name} is smaller than 10 x 6 mm"
                )
        if not (
            close(left_side["center"], right_side["center"], 0.01)
            and close(left_side["z"], right_side["z"], 0.01)
            and close(left_side["width"], right_side["width"], 0.01)
            and close(left_side["height"], right_side["height"], 0.01)
        ):
            failures.append("Rear side cable openings are not symmetric")

    clamp_probe_overlaps = {}
    for spec in CABLE_EXIT_SPECS:
        if spec["face"] not in ("front", "rear"):
            continue
        clamp_offset = spec.get("clamp_offset", CABLE_CLAMP_HOLE_OFFSET)
        side_y = 1.0 if spec["face"] == "rear" else -1.0
        wall_center_y = side_y * (
            BOTTOM_SHELL_OUTER_DEPTH / 2.0 - BOTTOM_SHELL_WALL / 2.0
        )
        custom_holes = spec.get("clamp_holes")
        if custom_holes is not None:
            clamp_holes = tuple(
                (
                    spec["center"] + offset_x,
                    wall_center_y,
                    spec["z"] + offset_z,
                    f"{'left' if offset_x < 0 else 'right'}_{'top' if offset_z > 0 else 'bottom'}",
                )
                for offset_x, offset_z in custom_holes
            )
        else:
            clamp_holes = tuple(
                (
                    spec["center"]
                    + side * (spec["width"] / 2.0 + clamp_offset),
                    wall_center_y,
                    spec["z"],
                    "left" if side < 0 else "right",
                )
                for side in (-1.0, 1.0)
            )
        for hole_x, hole_y, hole_z, hole_name in clamp_holes:
            key = f"{spec['name']}:{hole_name}"
            clamp_rotation = (
                bd.Rot(0, 90, 0)
                if spec["face"] in ("left", "right")
                else bd.Rot(90, 0, 0)
            )
            hole = (
                bd.Pos(
                    hole_x,
                    hole_y,
                    hole_z,
                )
                * clamp_rotation
                * bd.Cylinder(
                    CABLE_CLAMP_HOLE_DIAMETER / 2.0,
                    BOTTOM_SHELL_WALL + 2.0,
                )
            ).solid()
            overlap = overlap_volume(bottom, hole)
            clamp_probe_overlaps[key] = round(overlap, 4)
            if overlap > 0.01:
                failures.append(f"Cable clamp hole {key} is obstructed")

    photo_exit = next(spec for spec in CABLE_EXIT_SPECS if spec["name"] == "photo_6ch")
    photo_wire_area = PHOTO_WIRE_COUNT * math.pi * (PHOTO_WIRE_DIAMETER / 2.0) ** 2
    photo_power_area = (
        PHOTO_POWER_WIRE_COUNT
        * math.pi
        * (PHOTO_POWER_WIRE_DIAMETER / 2.0) ** 2
    )
    photo_total_bundle_area = photo_wire_area + photo_power_area
    photo_exit_area = photo_exit["width"] * photo_exit["height"]
    if photo_exit_area < 5.0 * photo_total_bundle_area:
        failures.append(
            f"Photo cable opening {photo_exit_area:.1f} mm2 is too small for "
            f"photo and 12 V conductors"
        )

    dxf_findings = validate_dxf_file(BOARD_DXF)
    if dxf_findings:
        failures.append(
            f"DXF validation findings: {[finding.code for finding in dxf_findings]}"
        )
    dxf_doc = ezdxf.readfile(BOARD_DXF)
    dxf_msp = dxf_doc.modelspace()
    expected_holes = {
        (-PCB_MOUNT_HOLE_X, -PCB_MOUNT_HOLE_Y),
        (-PCB_MOUNT_HOLE_X, PCB_MOUNT_HOLE_Y),
        (PCB_MOUNT_HOLE_X, -PCB_MOUNT_HOLE_Y),
        (PCB_MOUNT_HOLE_X, PCB_MOUNT_HOLE_Y),
    }
    actual_holes = {
        (round(circle.dxf.center.x, 3), round(circle.dxf.center.y, 3))
        for circle in dxf_msp.query("CIRCLE")
    }
    if actual_holes != expected_holes:
        failures.append(f"DXF mount-hole positions mismatch: {sorted(actual_holes)}")
    dxf_size = dxf_bbox.extents(dxf_msp).size
    if not close(dxf_size.x, PCB_PLACEHOLDER_WIDTH, 0.02) or not close(
        dxf_size.y, PCB_PLACEHOLDER_DEPTH, 0.02
    ):
        failures.append(f"DXF board extents mismatch: {dxf_size}")

    report = {
        "status": "PASS" if not failures else "FAIL",
        "failures": failures,
        "shells": shell_records,
        "assembly": {
            "leaf_count": len(leaves),
            "top_overall_height_mm": round(bbox(top)[1].Z, 3),
            "main_top_plane_z_mm": TOP_SHELL_TOTAL_HEIGHT,
            "j13_service_cap_top_z_mm": J13_SERVICE_CAP_TOP_Z,
            "j13_cable_recess_top_z_mm": J13_CABLE_RECESS_TOP_Z,
            "j13_service_cap_roof_mm": round(
                J13_SERVICE_CAP_TOP_Z - J13_CABLE_RECESS_TOP_Z,
                3,
            ),
            "black_key_top_z_mm": round(black_key_top_z, 3),
            "tof_surface_flush_with_black_keys": close(
                TOP_SHELL_TOTAL_HEIGHT, black_key_top_z, 0.01
            ),
            "tof_outer_y_mm": round(tof_outer_y, 3),
            "shell_rear_edge_y_mm": round(top_rear_edge_y, 3),
            "bottom_rear_edge_y_mm": round(bottom_rear_edge_y, 3),
            "shell_reaches_tof_outermost_edge": close(
                top_rear_edge_y, tof_outer_y, 0.01
            ),
            "bottom_shell_reaches_tof_outermost_edge": close(
                bottom_rear_edge_y, tof_outer_y, 0.01
            ),
            "bottom_footprint_mm": [
                round(bottom_size.X, 3),
                round(bottom_size.Y, 3),
            ],
            "top_footprint_mm": [
                round(top_size.X, 3),
                round(top_size.Y, 3),
            ],
            "shell_screw_pattern_xy_mm": [TOP_SCREW_X, TOP_SCREW_Y],
            "keyboard_opening_mm": [
                KEYBOARD_OPENING_WIDTH,
                KEYBOARD_OPENING_DEPTH,
            ],
            "keybed_plate_front_rear_y_mm": [
                KEYBED_PLATE_FRONT_Y,
                KEYBED_PLATE_REAR_Y,
            ],
            "keybed_opening_underlap_each_side_mm": round(
                KEYBED_PLATE_WIDTH / 2.0 - KEYBOARD_OPENING_WIDTH / 2.0,
                3,
            ),
            "minimum_keycap_to_opening_edge_mm": round(
                min(min(values.values()) for values in opening_cap_clearances.values()),
                4,
            ),
            "pcb_top_z_mm": PCB_TOP_Z,
            "pcb_front_cantilever_mm": round(pcb_front_cantilever, 3),
            "keybed_front_edge_y_mm": round(plate_min.Y, 3),
            "pcb_front_edge_y_mm": round(pcb_min.Y, 3),
            "j13_center_y_mm": J13_CONNECTOR_CENTER_Y,
            "j13_pcb_rear_edge_margin_mm": round(j13_rear_edge_margin, 3),
            "rear_ffc_opening_mm": [
                j13_profile["width"],
                j13_profile["height"],
            ],
            "preterminated_idc_plug_envelope_mm": [
                IDC_PLUG_WIDTH,
                IDC_PLUG_DEPTH,
                IDC_PLUG_HEIGHT,
            ],
            "preterminated_idc_pass_overlap_mm3": round(idc_pass_overlap, 4),
            "cable_side_idc_to_top_overlap_mm3": round(
                idc_plug_top_overlap,
                4,
            ),
            "minimum_switch_body_to_pcb_gap_mm": round(
                min(closest_points(body, pcb).distance for body in switch_bodies.values()),
                4,
            ),
            "switch_total_height_mm": SWITCH_TOTAL_HEIGHT,
            "switch_travel_mm": SWITCH_TRAVEL,
            "switch_pocket_mm": [
                SWITCH_POCKET_WIDTH,
                SWITCH_POCKET_DEPTH,
            ],
            "minimum_switch_to_keybed_clearance_mm": round(
                min(closest_points(body, plate).distance for body in switch_bodies.values()),
                4,
            ),
            "pad_relief_probe_overlap_mm3": pad_relief_probes,
            "full_travel_cap_to_keybed_mm": FULL_TRAVEL_CAP_TO_PLATE_GAP,
            "pcb_to_bottom_min_distance_mm": round(pcb_to_bottom_distance, 4),
            "tof_axis_collisions": axis_obstructions,
            "tof_axis_direction_errors_deg": axis_errors,
            "tof_centre_separation_mm": round(separation, 3),
            "tof_module_envelope_mm": [
                TOF_MODULE_WIDTH,
                TOF_MODULE_HEIGHT,
                TOF_MODULE_DEPTH,
            ],
            "tof_seat_thickness_mm": TOF_SEAT_THICKNESS,
            "tof_light_well_depth_mm": TOF_LIGHT_WELL_DEPTH,
            "tof_side_clearance_each_mm": TOF_MODULE_CLEARANCE_PER_SIDE,
            "tof_aperture_each_mm": [
                TOF_APERTURE_WIDTH,
                TOF_APERTURE_HEIGHT,
            ],
            "tof_aperture_probe_overlap_mm3": aperture_probes,
            "tof_inner_cable_window_each_mm": [
                TOF_INNER_CABLE_WINDOW_WIDTH,
                TOF_INNER_CABLE_WINDOW_HEIGHT,
            ],
            "tof_narrow_face_margin_mm": {
                "width_direction": round(narrow_face_margin_y, 3),
                "thickness_direction": round(narrow_face_margin_z, 3),
            },
            "tof_inner_cable_probe_overlap_mm3": tof_inner_cable_probes,
            "tof_mount_split_z_mm": TOF_MOUNT_SPLIT_Z,
            "tof_lower_mount_on_top_shell_overlap_mm3": lower_tof_top_overlaps,
            "tof_lower_mount_on_bottom_shell_volume_mm3": lower_tof_bottom_probes,
            "tof_seat_probe_volume_mm3": lower_tof_seat_volumes,
            "photo_cable": {
                "wire_count": PHOTO_WIRE_COUNT,
                "wire_diameter_mm": PHOTO_WIRE_DIAMETER,
                "wire_bundle_area_mm2": round(photo_wire_area, 3),
                "power_wire_count": PHOTO_POWER_WIRE_COUNT,
                "power_wire_diameter_mm": PHOTO_POWER_WIRE_DIAMETER,
                "power_wire_area_mm2": round(photo_power_area, 3),
                "combined_bundle_area_mm2": round(photo_total_bundle_area, 3),
                "opening_mm2": round(photo_exit_area, 3),
                "opening_to_bundle_area_ratio": round(photo_exit_area / photo_wire_area, 3),
                "opening_to_combined_bundle_ratio": round(
                    photo_exit_area / photo_total_bundle_area,
                    3,
                ),
            },
            "cable_exit_probe_overlap_mm3": cable_exit_probes,
            "cable_clamp_probe_overlap_mm3": clamp_probe_overlaps,
            "rear_side_cable_openings": {
                name: {
                    "face": port["face"],
                    "center_y_mm": port["center"],
                    "center_z_mm": port["z"],
                    "size_mm": [port["width"], port["height"]],
                }
                for name, port in rear_side_ports.items()
            },
            "top_bottom_seam_distance_mm": round(seam_distance, 4),
            "board_dxf": {
                "extents_mm": [round(dxf_size.x, 3), round(dxf_size.y, 3)],
                "mount_holes": sorted(actual_holes),
                "validation_findings": len(dxf_findings),
            },
            "keybed_locators": locator_records,
            "locator_boss_to_keycap_clearance_mm": locator_boss_cap_clearances,
            "downward_header_clearance": down_header_checks,
        },
        "unresolved": [
            "The purchased 40P IDC plug and any optional strain relief must be checked against the published 55.4 x 6.1 x 10.7 mm envelope.",
            "The final 40P IDC clamp and bend-radius control hardware is not yet specified.",
            "The four keybed locator posts constrain X/Y only; final lid installation force and print tolerance still require physical confirmation.",
        ],
    }
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    if failures:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
