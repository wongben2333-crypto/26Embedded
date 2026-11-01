"""Check the vendor PCB STEP against the final enclosure and keybed."""

from __future__ import annotations

import json
from pathlib import Path

from cadgen import build123d as bd
from cadgen import read_scene
from cadgen.geometry import overlap_volume

from lib.params import (
    IDC_PLUG_DEPTH,
    IDC_PLUG_HEIGHT,
    IDC_PLUG_WIDTH,
    J13_CONNECTOR_CENTER_Y,
    PCB_DOWN_HEADER_BODY_Z_MAX,
    PCB_DOWN_HEADER_BODY_Z_MIN,
    PCB_DOWN_HEADER_PIN_DIAMETER,
    PCB_DOWN_HEADER_PIN_Z_MAX,
    PCB_DOWN_HEADER_PIN_Z_MIN,
    PCB_THICKNESS,
    PCB_TOP_Z,
)


ROOT = Path(__file__).resolve().parents[1]
PCB_STEP = ROOT.parent / "3D_PCB1_2026-10-27.step"
ASSEMBLY = ROOT / "STEP" / "assembly.step"
REPORT_DIR = ROOT / "reports" / "2026-10-28"
REPORT = REPORT_DIR / "actual_pcb_checks.json"
SWITCH_TO_CAP = {
    "SW1->0": "white_key_1",
    "SW2->0": "black_key_after_white_1",
    "SW3->0": "white_key_2",
    "SW4->0": "black_key_after_white_2",
    "SW5->0": "white_key_3",
    "SW6->0": "white_key_4",
    "SW7->0": "black_key_after_white_4",
    "SW8->0": "white_key_5",
    "SW9->0": "black_key_after_white_5",
    "SW10->0": "white_key_6",
    "SW11->0": "black_key_after_white_6",
    "SW12->0": "white_key_7",
    "SW13->0": "white_key_8",
}
DOWNWARD_HEADERS = tuple(f"H{index}" for index in range(1, 15))


def boxes_intersect(a: bd.Shape, b: bd.Shape) -> bool:
    a_box = a.bounding_box()
    b_box = b.bounding_box()
    return all(
        getattr(a_box.min, axis) <= getattr(b_box.max, axis) + 1e-5
        and getattr(b_box.min, axis) <= getattr(a_box.max, axis) + 1e-5
        for axis in ("X", "Y", "Z")
    )


def main() -> None:
    failures: list[str] = []
    shell_scene = read_scene(ASSEMBLY)
    shell_leaves = {leaf.label: leaf for leaf in shell_scene.leaves()}
    top = shell_leaves["top_shell_part"].shape().solids()[0]
    bottom = shell_leaves["bottom_shell_part"].shape().solids()[0]
    plate = shell_leaves["keybed_plate"].shape().solids()[0]
    caps = {
        label: leaf.shape().solids()[0]
        for label, leaf in shell_leaves.items()
        if label.startswith("white_key_")
        or label.startswith("black_key_after_white_")
    }

    pcb_scene = read_scene(PCB_STEP)
    board_offset = bd.Location((0.0, 0.0, PCB_TOP_Z - PCB_THICKNESS))
    actual: dict[str, list[bd.Solid]] = {}
    for leaf in pcb_scene.leaves():
        placed = leaf.shape().moved(board_offset)
        actual.setdefault(leaf.label, []).extend(placed.solids())

    all_parts = [
        (component, part)
        for component, parts in actual.items()
        for part in parts
    ]
    board_component, board_part = max(all_parts, key=lambda item: item[1].volume)
    if "=>" not in board_component:
        failures.append(f"Unexpected PCB board body label: {board_component}")

    collision_records = []
    critical_components = ["CN1->0", "CN2->0"]
    for component in critical_components:
        parts = actual[component]
        targets = [("top", top), ("bottom", bottom), ("keybed", plate)]
        overlaps = {}
        for part in parts:
            for target_label, target in targets:
                if not boxes_intersect(part, target):
                    continue
                volume = overlap_volume(part, target)
                if volume > 0.01:
                    overlaps[target_label] = round(
                        overlaps.get(target_label, 0.0) + volume,
                        4,
                    )
        if overlaps:
            collision_records.append(
                {"component": component, "overlaps_mm3": overlaps}
            )

    # The supplied PCB STEP still shows H1-H14 soldered upward. The hardware
    # plan is to solder them downward, so preserve the measured X/Y footprints
    # but model the plastic body and the individual pins at their real heights.
    downward_header_records = {}
    for header in DOWNWARD_HEADERS:
        component = f"{header}->0"
        parts = actual[component]
        boxes = [part.bounding_box() for part in parts]
        x_min = min(box.min.X for box in boxes)
        x_max = max(box.max.X for box in boxes)
        y_min = min(box.min.Y for box in boxes)
        y_max = max(box.max.Y for box in boxes)
        body = (
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
            "top": round(overlap_volume(body, top), 4),
            "bottom": round(overlap_volume(body, bottom), 4),
            "keybed": round(overlap_volume(body, plate), 4),
        }
        cap_overlaps = {
            label: round(overlap_volume(body, cap), 4)
            for label, cap in caps.items()
            if boxes_intersect(body, cap)
        }
        cap_overlaps = {
            label: volume
            for label, volume in cap_overlaps.items()
            if volume > 0.01
        }

        pin_centres = []
        for box in boxes:
            count_x = max(1, round(box.size.X / 2.54))
            count_y = max(1, round(box.size.Y / 2.54))
            for ix in range(count_x):
                for iy in range(count_y):
                    pin_centres.append(
                        (
                            box.min.X + (ix + 0.5) * box.size.X / count_x,
                            box.min.Y + (iy + 0.5) * box.size.Y / count_y,
                        )
                    )
        pin_overlaps = {"bottom": 0.0, "keybed": 0.0}
        for pin_x, pin_y in pin_centres:
            pin = (
                bd.Pos(pin_x, pin_y, PCB_DOWN_HEADER_PIN_Z_MIN)
                * bd.Cylinder(
                    PCB_DOWN_HEADER_PIN_DIAMETER / 2.0,
                    PCB_DOWN_HEADER_PIN_Z_MAX - PCB_DOWN_HEADER_PIN_Z_MIN,
                    align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN),
                )
            ).solid()
            pin_overlaps["bottom"] += overlap_volume(pin, bottom)
            pin_overlaps["keybed"] += overlap_volume(pin, plate)
        pin_overlaps = {
            key: round(value, 4)
            for key, value in pin_overlaps.items()
        }

        downward_header_records[header] = {
            "xy_mm": [
                round(x_min, 3),
                round(y_min, 3),
                round(x_max, 3),
                round(y_max, 3),
            ],
            "body_z_mm": [
                PCB_DOWN_HEADER_BODY_Z_MIN,
                PCB_DOWN_HEADER_BODY_Z_MAX,
            ],
            "pin_z_mm": [
                PCB_DOWN_HEADER_PIN_Z_MIN,
                PCB_DOWN_HEADER_PIN_Z_MAX,
            ],
            "pin_count": len(pin_centres),
            "body_overlaps_mm3": body_overlaps,
            "pin_overlaps_mm3": pin_overlaps,
            "keycap_overlaps_mm3": cap_overlaps,
        }
        if any(
            value > 0.01
            for value in body_overlaps.values()
        ) or any(value > 0.01 for value in pin_overlaps.values()) or cap_overlaps:
            collision_records.append(
                {
                    "component": component,
                    "future_downward_overlaps_mm3": downward_header_records[header],
                }
            )

    if collision_records:
        failures.append(
            f"Actual PCB STEP intersects enclosure: {collision_records}"
        )

    cn2 = actual["CN2->0"]
    cn2_boxes = [part.bounding_box() for part in cn2]
    cn2_min = [
        min(getattr(box.min, axis) for box in cn2_boxes)
        for axis in ("X", "Y", "Z")
    ]
    cn2_max = [
        max(getattr(box.max, axis) for box in cn2_boxes)
        for axis in ("X", "Y", "Z")
    ]
    cn2_size = [cn2_max[index] - cn2_min[index] for index in range(3)]
    if not (
        abs(cn2_size[0] - 58.4) < 0.02
        and abs(cn2_size[1] - 8.91) < 0.02
        and abs(cn2_size[2] - 12.2) < 0.02
    ):
        failures.append(f"CN2 envelope changed: {cn2_size}")

    cable_side_plug = (
        bd.Pos(0, J13_CONNECTOR_CENTER_Y, PCB_TOP_Z)
        * bd.Box(
            IDC_PLUG_WIDTH,
            IDC_PLUG_DEPTH,
            IDC_PLUG_HEIGHT,
            align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN),
        )
    ).solid()
    cable_plug_top_overlap = overlap_volume(top, cable_side_plug)
    if cable_plug_top_overlap > 0.01:
        failures.append(
            f"Cable-side IDC plug collides with the upper shell by "
            f"{cable_plug_top_overlap:.4f} mm3"
        )

    report = {
        "status": "PASS" if not failures else "FAIL",
        "failures": failures,
        "pcb_step": str(PCB_STEP),
        "board_component": board_component,
        "keybed_plate_present": "keybed_plate" in shell_leaves,
        "cn2": {
            "min_mm": [round(value, 3) for value in cn2_min],
            "max_mm": [round(value, 3) for value in cn2_max],
            "size_mm": [round(value, 3) for value in cn2_size],
        },
        "cable_side_idc": {
            "envelope_mm": [
                IDC_PLUG_WIDTH,
                IDC_PLUG_DEPTH,
                IDC_PLUG_HEIGHT,
            ],
            "top_overlap_mm3": round(cable_plug_top_overlap, 4),
        },
        "unexpected_collisions": collision_records,
        "checked_critical_components": critical_components,
        "downward_header_envelopes": downward_header_records,
        "switch_envelope_policy": (
            "Vendor PCB STEP switches are not used for vertical fit; "
            "switch_reference() is the authoritative 5.0 mm envelope."
        ),
    }
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    if failures:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
