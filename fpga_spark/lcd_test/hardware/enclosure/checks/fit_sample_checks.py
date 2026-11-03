"""Deterministic checks for the phase-1 keybed/ToF/PCB fit models."""

from __future__ import annotations

import json
import math
from itertools import combinations
from pathlib import Path

from cadgen import build123d as bd
from cadgen import read_scene
from cadgen.geometry import boundary_edges, closest_points, overlap_volume, topology_errors

from lib.params import (
    BLACK_CAP_DEPTH,
    BLACK_CAP_HEIGHT,
    BLACK_CAP_WIDTH,
    BLACK_KEY_SIDE_CLEARANCE,
    BLACK_KEY_COUNT,
    BLACK_POSITIONS,
    CAP_BOTTOM_Y,
    CAP_SOCKET_DIAMETER,
    FULL_TRAVEL_CAP_TO_PLATE_GAP,
    GUIDE_FULL_TRAVEL_INSERTION,
    GUIDE_INITIAL_INSERTION,
    GUIDE_PIN_DIAMETER,
    GUIDE_PIN_PITCH,
    GUIDE_PIN_TOP_Y,
    GUIDE_SOCKET_DEPTH,
    GUIDE_SOCKET_DIAMETER,
    KEYBED_PLATE_BACK_Z,
    KEYBED_PLATE_BOTTOM_Y,
    KEYBED_PLATE_DEPTH,
    KEYBED_PLATE_THICKNESS,
    KEYBED_PLATE_TOP_Y,
    KEYBED_PLATE_TOP_Y,
    KEYBED_PLATE_WIDTH,
    SWITCH_BODY_HEIGHT,
    SWITCH_BODY_WIDTH,
    SWITCH_PIN_PITCH,
    SWITCH_PLUNGER_DIAMETER,
    SWITCH_POCKET_CLEARANCE_PER_SIDE,
    SWITCH_POCKET_DEPTH,
    SWITCH_POCKET_DEPTH_CLEARANCE_PER_SIDE,
    SWITCH_POCKET_MIN_CLEARANCE,
    SWITCH_POCKET_WIDTH,
    SWITCH_TOTAL_HEIGHT,
    SWITCH_TRAVEL,
    TOF_CENTER_SEPARATION_X,
    TOF_LIGHT_WELL_DEPTH,
    TOF_MODULE_DEPTH,
    TOF_MODULE_HEIGHT,
    TOF_MODULE_WIDTH,
    TOF_MOUNT_TOTAL_DEPTH,
    TOF_MOUNT_REAR_EXTENSION,
    TOF_SEAT_THICKNESS,
    WHITE_CAP_DEPTH,
    WHITE_CAP_HEIGHT,
    WHITE_CAP_WIDTH,
    WHITE_KEY_COUNT,
    WHITE_KEY_PITCH,
    black_key_center_x,
    white_key_center_x,
)


ROOT = Path(__file__).resolve().parents[1]
ASSEMBLY = ROOT / "STEP" / "fit_assembly.step"
SAMPLE = ROOT / "STEP" / "fit_sample.step"
REPORT_DIR = ROOT / "reports" / "2026-10-28"


def close(actual: float, expected: float, tolerance: float = 0.02) -> bool:
    return abs(actual - expected) <= tolerance


def bbox_center(shape: bd.Shape) -> bd.Vector:
    return shape.bounding_box().center()


def long_edge_direction(shape: bd.Shape) -> bd.Vector:
    edge = max(shape.edges(), key=lambda item: item.length)
    direction = (edge @ 1 - edge @ 0).normalized()
    return direction


def angle_degrees(a: bd.Vector, b: bd.Vector) -> float:
    return a.get_angle(b)


def main() -> None:
    failures: list[str] = []
    report: dict[str, object] = {}

    if not ASSEMBLY.is_file() or not SAMPLE.is_file():
        raise SystemExit("Build STEP/fit_assembly.step and STEP/fit_sample.step first")

    assembly = read_scene(ASSEMBLY)
    sample = read_scene(SAMPLE)
    leaves = list(assembly.leaves())
    sample_leaves = list(sample.leaves())
    by_label = {leaf.label: leaf for leaf in leaves}
    sample_by_label = {leaf.label: leaf for leaf in sample_leaves}

    white_labels = [f"white_key_{index + 1}" for index in range(WHITE_KEY_COUNT)]
    black_labels = [f"black_key_after_white_{index + 1}" for index in BLACK_POSITIONS]
    if len(white_labels) != 8:
        failures.append("Expected exactly 8 white keys")
    if len(black_labels) != 5:
        failures.append("Expected exactly 5 black keys")
    if not all(label in by_label for label in white_labels + black_labels):
        failures.append("One or more keycap leaves are missing from fit_assembly.step")

    white_centres = sorted(bbox_center(by_label[label].shape()).X for label in white_labels)
    white_pitches = [
        right - left for left, right in zip(white_centres, white_centres[1:])
    ]
    expected_white_centres = sorted(
        white_key_center_x(index)
        for index in range(WHITE_KEY_COUNT)
    )
    if len(white_pitches) != WHITE_KEY_COUNT - 1 or not all(
        close(actual, expected, 0.005)
        for actual, expected in zip(white_centres, expected_white_centres)
    ):
        failures.append(f"White-key pitch failed: {white_pitches}")

    black_centres = sorted(bbox_center(by_label[label].shape()).X for label in black_labels)
    expected_black_centres = sorted(
        black_key_center_x(index)
        for index in BLACK_POSITIONS
    )
    for actual, expected in zip(black_centres, expected_black_centres):
        if not close(actual, expected, 0.005):
            failures.append(
                f"Black-key centre mismatch: actual={actual:.4f}, expected={expected:.4f}"
            )

    for label in white_labels:
        size = by_label[label].shape().bounding_box().size
        if not (
            close(size.X, WHITE_CAP_WIDTH, 0.01)
            and close(size.Y, WHITE_CAP_HEIGHT, 0.01)
            and close(size.Z, WHITE_CAP_DEPTH, 0.01)
        ):
            failures.append(f"White-key envelope mismatch: {label} {size}")
    for label in black_labels:
        size = by_label[label].shape().bounding_box().size
        if not (
            close(size.X, BLACK_CAP_WIDTH, 0.01)
            and close(size.Y, BLACK_CAP_HEIGHT, 0.01)
            and close(size.Z, BLACK_CAP_DEPTH, 0.01)
        ):
            failures.append(f"Black-key envelope mismatch: {label} {size}")

    plate = by_label["keybed_plate"].shape()
    caps = {
        label: by_label[label]
        for label in white_labels + black_labels
    }
    plate_size = plate.bounding_box().size
    if not (
        close(plate_size.X, KEYBED_PLATE_WIDTH, 0.01)
        and close(plate_size.Y, GUIDE_PIN_TOP_Y, 0.01)
        and close(plate_size.Z, KEYBED_PLATE_DEPTH, 0.01)
    ):
        failures.append(f"Keybed plate/guide envelope mismatch: {plate_size}")

    switch_bodies = [
        leaf
        for leaf in leaves
        if leaf.label.endswith(":body") and leaf.label.startswith("switch_")
    ]
    if len(switch_bodies) != 13:
        failures.append(f"Expected 13 switch body references, found {len(switch_bodies)}")
    switch_clearances = []
    pcb = by_label["pcb_placeholder_envelope"].shape()
    for switch in switch_bodies:
        body = switch.shape().solids()[0]
        clearance = closest_points(body, plate).distance
        switch_clearances.append(clearance)
        if clearance < SWITCH_POCKET_MIN_CLEARANCE - 0.001:
            failures.append(
                f"{switch.label} to keybed clearance {clearance:.4f} mm is below "
                f"{SWITCH_POCKET_MIN_CLEARANCE:.2f} mm"
            )
        if overlap_volume(body, plate) > 1e-5:
            failures.append(f"{switch.label} intersects keybed plate")
        pcb_clearance = closest_points(body, pcb).distance
        if pcb_clearance > 0.02:
            failures.append(
                f"{switch.label} does not seat on the PCB: {pcb_clearance:.3f} mm gap"
            )

    plungers = [
        leaf
        for leaf in leaves
        if leaf.label.endswith(":plunger") and leaf.label.startswith("switch_")
    ]
    if len(plungers) != 13:
        failures.append(f"Expected 13 switch plunger references, found {len(plungers)}")

    cap_socket_clearance = CAP_SOCKET_DIAMETER - SWITCH_PLUNGER_DIAMETER
    if cap_socket_clearance <= 0:
        failures.append("Keycap socket is not larger than switch plunger")
    if not close(SWITCH_TOTAL_HEIGHT, 5.0, 0.001):
        failures.append(f"Switch total height is {SWITCH_TOTAL_HEIGHT}, expected 5.0 mm")
    if FULL_TRAVEL_CAP_TO_PLATE_GAP < 0:
        failures.append("Keycap collides with keybed plate at full travel")

    module_labels = ["tof_left:vb22b_reference", "tof_right:vb22b_reference"]
    mount_labels = ["tof_left:mount", "tof_right:mount"]
    axis_labels = ["tof_left:detection_axis", "tof_right:detection_axis"]
    if not all(label in by_label for label in module_labels + mount_labels + axis_labels):
        failures.append("One or more ToF leaves are missing")
    tof_center_x = [bbox_center(by_label[label].shape()).X for label in module_labels]
    separation = abs(tof_center_x[0] - tof_center_x[1])
    if separation < TOF_CENTER_SEPARATION_X - 0.01:
        failures.append(f"ToF centre separation is only {separation:.3f} mm")

    for module_label, mount_label in zip(module_labels, mount_labels):
        module_shape = by_label[module_label].shape()
        mount_shape = by_label[mount_label].shape()
        module_solid = module_shape.solids()[0]
        mount_solid = mount_shape.solids()[0]
        if overlap_volume(module_solid, mount_solid) > 1e-5:
            failures.append(f"{module_label} intersects its mount")

    expected_up = bd.Vector(0, 1, 0)
    axis_errors = {}
    for axis_label in axis_labels:
        direction = long_edge_direction(by_label[axis_label].shape())
        error = min(
            angle_degrees(direction, expected_up),
            angle_degrees(-direction, expected_up),
        )
        axis_errors[axis_label] = round(error, 4)
        if error > 0.1:
            failures.append(f"{axis_label} direction error is {error:.4f}°")

    hood_depth = (
        TOF_MOUNT_TOTAL_DEPTH
        - TOF_MODULE_DEPTH
        - TOF_MOUNT_REAR_EXTENSION
        - TOF_SEAT_THICKNESS
    )
    if not close(hood_depth, TOF_LIGHT_WELL_DEPTH, 0.001):
        failures.append(f"Light well depth inconsistency: {hood_depth}")
    if not (18.0 <= hood_depth <= 30.0):
        failures.append(f"Light well depth {hood_depth:.2f} mm is outside 18-30 mm")

    # Every printed component must be a positive-volume, boundary-free valid solid.
    for leaf in sample_leaves:
        solids = leaf.shape().solids()
        if len(solids) != 1:
            failures.append(f"{leaf.label} contains {len(solids)} solids, expected 1")
            continue
        solid = solids[0]
        if not solid.is_valid or solid.volume <= 0:
            failures.append(f"{leaf.label} is invalid or has non-positive volume")
        errors = topology_errors(solid)
        if errors:
            failures.append(f"{leaf.label} topology errors: {[issue.code for issue in errors]}")
        free_edges = [edge for shell in solid.shells() for edge in boundary_edges(shell)]
        if free_edges:
            failures.append(f"{leaf.label} has {len(free_edges)} boundary edges")

    # The sample is an assembly of separate printed pieces. No accidental overlap is allowed.
    overlap_failures = []
    candidate_pairs = 0
    for left, right in combinations(sample_leaves, 2):
        left_shape = left.shape()
        right_shape = right.shape()
        left_box = left_shape.bounding_box()
        right_box = right_shape.bounding_box()
        left_min = (left_box.min.X, left_box.min.Y, left_box.min.Z)
        left_max = (left_box.max.X, left_box.max.Y, left_box.max.Z)
        right_min = (right_box.min.X, right_box.min.Y, right_box.min.Z)
        right_max = (right_box.max.X, right_box.max.Y, right_box.max.Z)
        boxes_intersect = all(
            left_min[i] <= right_max[i] + 1e-6
            and right_min[i] <= left_max[i] + 1e-6
            for i in range(3)
        )
        if not boxes_intersect:
            continue
        candidate_pairs += 1
        left_solid = left_shape.solids()[0]
        right_solid = right_shape.solids()[0]
        volume = overlap_volume(left_solid, right_solid)
        if volume > 1e-5:
            overlap_failures.append(
                {"left": left.label, "right": right.label, "volume_mm3": volume}
            )
    if overlap_failures:
        failures.append(f"Unintended fit-sample overlaps: {overlap_failures}")

    cap_gaps = []
    for white_label in white_labels:
        for black_label in black_labels:
            gap = closest_points(
                by_label[white_label].shape().solids()[0],
                by_label[black_label].shape().solids()[0],
            ).distance
            if gap < BLACK_KEY_SIDE_CLEARANCE - 0.02:
                failures.append(
                    f"{white_label} to {black_label} gap {gap:.4f} mm is too small"
                )
            cap_gaps.append(gap)

    guide_socket_probes = {}
    guide_pin_probes = {}
    guide_cap_collisions = {}
    guide_socket_overlap_max = 0.0
    guide_pin_min_overlap = float("inf")
    guide_pin_probe_length = GUIDE_PIN_TOP_Y - KEYBED_PLATE_TOP_Y - 0.1
    guide_pin_probe_radius = (GUIDE_PIN_DIAMETER - 0.15) / 2.0
    guide_pin_expected_overlap = (
        math.pi * guide_pin_probe_radius**2 * guide_pin_probe_length
    )

    if GUIDE_PIN_DIAMETER >= GUIDE_SOCKET_DIAMETER:
        failures.append("Guide pin is not smaller than its cap socket")
    if GUIDE_FULL_TRAVEL_INSERTION + 0.3 > GUIDE_SOCKET_DEPTH:
        failures.append("Guide socket is too shallow for full switch travel")
    black_pin_edge_margin = (
        BLACK_CAP_DEPTH / 2.0
        - GUIDE_PIN_PITCH / 2.0
        - GUIDE_PIN_DIAMETER / 2.0
    )
    if black_pin_edge_margin < 1.0:
        failures.append(
            f"Black-key guide pin leaves only {black_pin_edge_margin:.3f} mm edge margin"
        )
    front_guide_pin_to_plate_edge = (
        KEYBED_PLATE_BACK_Z
        + KEYBED_PLATE_DEPTH
        - (
            WHITE_CAP_DEPTH / 2.0
            + GUIDE_PIN_PITCH / 2.0
            + GUIDE_PIN_DIAMETER / 2.0
        )
    )
    if front_guide_pin_to_plate_edge < 1.0:
        failures.append(
            "Shortened keybed leaves less than 1 mm beyond the front guide pin"
        )

    for cap_label, cap_leaf in caps.items():
        cap = cap_leaf.shape().solids()[0]
        cap_box = cap.bounding_box()
        center_x = (cap_box.min.X + cap_box.max.X) / 2.0
        center_z = (cap_box.min.Z + cap_box.max.Z) / 2.0
        for sign in (-1.0, 1.0):
            guide_z = center_z + sign * GUIDE_PIN_PITCH / 2.0
            guide_key = f"{cap_label}:{'back' if sign < 0 else 'front'}"

            socket_probe = (
                bd.Pos(center_x, cap_box.min.Y + 0.05, guide_z)
                * bd.Rot(-90, 0, 0)
                * bd.Cylinder(
                    (GUIDE_SOCKET_DIAMETER - 0.15) / 2.0,
                    GUIDE_SOCKET_DEPTH - 0.3,
                    align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN),
                )
            ).solid()
            socket_overlap = overlap_volume(cap, socket_probe)
            guide_socket_probes[guide_key] = round(socket_overlap, 4)
            guide_socket_overlap_max = max(guide_socket_overlap_max, socket_overlap)
            if socket_overlap > 0.01:
                failures.append(f"{guide_key} guide socket is obstructed")

            pin_probe = (
                bd.Pos(center_x, KEYBED_PLATE_TOP_Y + 0.05, guide_z)
                * bd.Rot(-90, 0, 0)
                * bd.Cylinder(
                    guide_pin_probe_radius,
                    guide_pin_probe_length,
                    align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN),
                )
            ).solid()
            pin_overlap = overlap_volume(plate, pin_probe)
            guide_pin_probes[guide_key] = round(pin_overlap, 4)
            guide_pin_min_overlap = min(guide_pin_min_overlap, pin_overlap)
            if pin_overlap < 0.8 * guide_pin_expected_overlap:
                failures.append(f"{guide_key} guide pin is missing or incomplete")

            full_pin_probe = (
                bd.Pos(center_x, cap_box.min.Y + 0.05, guide_z)
                * bd.Rot(-90, 0, 0)
                * bd.Cylinder(
                    GUIDE_PIN_DIAMETER / 2.0 - 0.05,
                    GUIDE_INITIAL_INSERTION - 0.05,
                    align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN),
                )
            ).solid()
            cap_collision = overlap_volume(cap, full_pin_probe)
            guide_cap_collisions[guide_key] = round(cap_collision, 4)
            if cap_collision > 0.01:
                failures.append(f"{guide_key} guide pin collides with keycap")

    guide_pitch_limit_deg = math.degrees(
        math.atan2(
            GUIDE_SOCKET_DIAMETER - GUIDE_PIN_DIAMETER,
            GUIDE_PIN_PITCH,
        )
    )

    report = {
        "status": "PASS" if not failures else "FAIL",
        "failures": failures,
        "keybed": {
            "white_keys": WHITE_KEY_COUNT,
            "black_keys": BLACK_KEY_COUNT,
            "white_pitches_mm": [round(value, 4) for value in white_pitches],
            "white_cap_mm": [WHITE_CAP_WIDTH, WHITE_CAP_HEIGHT, WHITE_CAP_DEPTH],
            "black_cap_mm": [BLACK_CAP_WIDTH, BLACK_CAP_HEIGHT, BLACK_CAP_DEPTH],
            "keybed_plate_mm": [
                KEYBED_PLATE_WIDTH,
                KEYBED_PLATE_THICKNESS,
                KEYBED_PLATE_DEPTH,
            ],
            "keybed_with_guides_height_mm": GUIDE_PIN_TOP_Y,
            "switch_pocket_mm": [
                SWITCH_POCKET_WIDTH,
                SWITCH_POCKET_DEPTH,
            ],
            "switch_side_clearance_mm": SWITCH_POCKET_CLEARANCE_PER_SIDE,
            "switch_depth_clearance_mm": SWITCH_POCKET_DEPTH_CLEARANCE_PER_SIDE,
            "switch_side_clearance_min_required_mm": SWITCH_POCKET_MIN_CLEARANCE,
            "measured_switch_side_clearances_mm": [
                round(value, 4) for value in switch_clearances
            ],
            "plunger_diameter_mm": SWITCH_PLUNGER_DIAMETER,
            "cap_socket_diameter_mm": CAP_SOCKET_DIAMETER,
            "switch_total_height_mm": SWITCH_TOTAL_HEIGHT,
            "switch_travel_mm": SWITCH_TRAVEL,
            "minimum_switch_body_to_pcb_gap_mm": round(
                min(closest_points(leaf.shape().solids()[0], pcb).distance for leaf in switch_bodies),
                4,
            ),
            "full_travel_cap_to_plate_gap_mm": FULL_TRAVEL_CAP_TO_PLATE_GAP,
            "minimum_white_black_cap_gap_mm": round(min(cap_gaps), 4),
            "key_guide": {
                "pin_diameter_mm": GUIDE_PIN_DIAMETER,
                "socket_diameter_mm": GUIDE_SOCKET_DIAMETER,
                "diametral_clearance_mm": round(
                    GUIDE_SOCKET_DIAMETER - GUIDE_PIN_DIAMETER,
                    4,
                ),
                "pin_pitch_mm": GUIDE_PIN_PITCH,
                "socket_depth_mm": GUIDE_SOCKET_DEPTH,
                "initial_insertion_mm": GUIDE_INITIAL_INSERTION,
                "full_travel_insertion_mm": GUIDE_FULL_TRAVEL_INSERTION,
                "theoretical_double_pin_pitch_limit_deg": round(
                    guide_pitch_limit_deg,
                    3,
                ),
                "black_key_edge_margin_mm": round(black_pin_edge_margin, 3),
                "front_guide_pin_to_plate_edge_mm": round(
                    front_guide_pin_to_plate_edge,
                    3,
                ),
                "socket_probe_overlap_max_mm3": round(
                    guide_socket_overlap_max,
                    4,
                ),
                "pin_probe_min_overlap_mm3": round(guide_pin_min_overlap, 4),
                "cap_collision_max_mm3": round(
                    max(guide_cap_collisions.values()),
                    4,
                ),
            },
        },
        "tof": {
            "module_envelope_mm": [TOF_MODULE_WIDTH, TOF_MODULE_HEIGHT, TOF_MODULE_DEPTH],
            "light_well_depth_mm": hood_depth,
            "mount_total_depth_mm": TOF_MOUNT_TOTAL_DEPTH,
            "centre_separation_x_mm": round(separation, 4),
            "axis_direction_errors_deg": axis_errors,
        },
        "print_sample": {
            "leaf_count": len(sample_leaves),
            "all_solids_valid_boundary_free": not any(
                "topology errors" in failure
                or "boundary edges" in failure
                or "invalid" in failure
                for failure in failures
            ),
            "overlap_candidate_pairs_checked": candidate_pairs,
            "unintended_overlaps": overlap_failures,
        },
        "assembly_leaf_count": len(leaves),
    }

    output_path = REPORT_DIR / "fit_sample_checks.json"
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    if failures:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
