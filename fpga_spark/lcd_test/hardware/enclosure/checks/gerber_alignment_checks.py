"""Cross-check the received Gerber package against enclosure datums."""

from __future__ import annotations

import hashlib
import json
import re
import zipfile
from pathlib import Path

from lib.params import (
    BLACK_POSITIONS,
    CABLE_EXIT_SPECS,
    IDC_PLUG_HEIGHT,
    IDC_PLUG_WIDTH,
    J13_CONNECTOR_CENTER_Y,
    PCB_CN2_ORIGIN_Y,
    PCB_PLACEHOLDER_DEPTH,
    PCB_PLACEHOLDER_WIDTH,
    black_key_center_x,
    white_key_center_x,
)


ROOT = Path(__file__).resolve().parents[1]
GERBER_ZIP = ROOT.parent / "Gerber_PCB1_2026-10-27.zip"
REPORT_DIR = ROOT / "reports" / "2026-10-28"
REPORT = REPORT_DIR / "gerber_alignment_checks.json"
EXPECTED_SHA256 = "12E0087CDD879E0BD927E60772B862EF2B89EF3A4BB4B88E95708D26DBFC2A87"
MIL_TO_MM = 0.0254

WHITE_SWITCH_NAMES = ("SW1", "SW3", "SW5", "SW6", "SW8", "SW10", "SW12", "SW13")
BLACK_SWITCH_NAMES = ("SW2", "SW4", "SW7", "SW9", "SW11")
FRONT_CONNECTORS = ("CN1", "H5", "H6", "H7", "H10", "H11", "H12", "H13")


def close(actual: float, expected: float, tolerance: float = 0.01) -> bool:
    return abs(actual - expected) <= tolerance


def read_zip_text(archive: zipfile.ZipFile, name: str) -> str:
    return archive.read(name).decode("utf-8-sig")


def gerber_coordinates(text: str) -> list[tuple[float, float]]:
    return [
        (float(x_text) / 100_000.0, float(y_text) / 100_000.0)
        for x_text, y_text in re.findall(
            r"^G0[123]X(-?\d+)Y(-?\d+)",
            text,
            flags=re.MULTILINE,
        )
    ]


def drill_coordinates(text: str) -> list[tuple[float, float]]:
    return [
        (float(x_text), float(y_text))
        for x_text, y_text in re.findall(
            r"^X(-?\d+(?:\.\d+)?)Y(-?\d+(?:\.\d+)?)$",
            text,
            flags=re.MULTILINE,
        )
    ]


def main() -> None:
    failures: list[str] = []
    sha256 = hashlib.sha256(GERBER_ZIP.read_bytes()).hexdigest().upper()
    if sha256 != EXPECTED_SHA256:
        failures.append(f"Gerber SHA256 changed: {sha256}")

    with zipfile.ZipFile(GERBER_ZIP) as archive:
        outline_text = read_zip_text(archive, "Gerber_BoardOutlineLayer.GKO")
        npth_text = read_zip_text(archive, "Drill_NPTH_Through.DRL")
        probe = json.loads(archive.read("FlyingProbeTesting.json").decode("utf-8-sig"))

    outline_points = gerber_coordinates(outline_text)
    min_x = min(point[0] for point in outline_points)
    max_x = max(point[0] for point in outline_points)
    min_y = min(point[1] for point in outline_points)
    max_y = max(point[1] for point in outline_points)
    board_width = max_x - min_x
    board_depth = max_y - min_y
    if not close(board_width, PCB_PLACEHOLDER_WIDTH, 0.02):
        failures.append(f"Gerber board width is {board_width:.3f} mm")
    if not close(board_depth, PCB_PLACEHOLDER_DEPTH, 0.02):
        failures.append(f"Gerber board depth is {board_depth:.3f} mm")

    npth_points = drill_coordinates(npth_text)
    expected_holes = {
        (-44.0, -28.0),
        (-44.0, 28.0),
        (44.0, -28.0),
        (44.0, 28.0),
    }
    actual_holes = {(round(x, 3), round(y, 3)) for x, y in npth_points}
    if actual_holes != expected_holes:
        failures.append(f"Gerber NPTH holes differ: {sorted(actual_holes)}")

    component_rows = probe["components"]["rows"]
    components = {
        row[1]: {
            "layer": row[2],
            "x": float(row[3]) * MIL_TO_MM,
            "y": float(row[4]) * MIL_TO_MM,
            "angle": float(row[5]),
        }
        for row in component_rows
    }

    j13 = components["CN2"]
    if not close(j13["x"], 0.0) or not close(j13["y"], PCB_CN2_ORIGIN_Y, 0.002):
        failures.append(f"CN2/J13 position mismatch: {j13}")

    switch_checks = {}
    for index, name in enumerate(WHITE_SWITCH_NAMES):
        expected_x = white_key_center_x(index)
        actual = components[name]
        switch_checks[name] = {
            "expected": [round(expected_x, 3), 0.0],
            "actual": [round(actual["x"], 3), round(actual["y"], 3)],
        }
        if not close(actual["x"], expected_x) or not close(actual["y"], 0.0):
            failures.append(f"{name} does not match the enclosure key datum")
    for index, name in zip(BLACK_POSITIONS, BLACK_SWITCH_NAMES):
        expected = {
            "x": black_key_center_x(index),
            "y": 9.2715,
        }
        actual = components[name]
        switch_checks[name] = {
            "expected": [round(expected["x"], 3), expected["y"]],
            "actual": [round(actual["x"], 3), round(actual["y"], 3)],
        }
        if not close(actual["x"], expected["x"]) or not close(actual["y"], expected["y"]):
            failures.append(f"{name} does not match the enclosure key datum")

    left_front = next(spec for spec in CABLE_EXIT_SPECS if spec["name"] == "photo_6ch")
    right_front = next(spec for spec in CABLE_EXIT_SPECS if spec["name"] == "encoder_4ch")
    front_checks = {}
    for name in FRONT_CONNECTORS:
        actual = components[name]
        opening = left_front if actual["x"] < 0.0 else right_front
        opening_min = opening["center"] - opening["width"] / 2.0
        opening_max = opening["center"] + opening["width"] / 2.0
        inside = opening_min + 3.0 <= actual["x"] <= opening_max - 3.0
        front_checks[name] = {
            "x_mm": round(actual["x"], 3),
            "opening": [opening_min, opening_max],
            "center_inside_with_3mm_margin": inside,
        }
        if not inside:
            failures.append(f"Front connector {name} is not centered within its service port")

    rear_port = next(spec for spec in CABLE_EXIT_SPECS if spec["name"] == "fpga_j13")
    if (
        rear_port["width"] < IDC_PLUG_WIDTH + 1.0
        or rear_port["height"] < IDC_PLUG_HEIGHT + 1.0
    ):
        failures.append(
            "Rear opening cannot pass the pre-terminated 40P IDC plug"
        )

    report = {
        "status": "PASS" if not failures else "FAIL",
        "failures": failures,
        "gerber": {
            "path": str(GERBER_ZIP),
            "sha256": sha256,
            "board_mm": [round(board_width, 3), round(board_depth, 3)],
            "npth_holes_mm": sorted(actual_holes),
        },
        "j13": {
            "component": "CN2",
            "placement_origin_mm": [round(j13["x"], 3), round(j13["y"], 3)],
            "enclosure_body_center_y_mm": J13_CONNECTOR_CENTER_Y,
            "rear_ffc_opening_mm": [rear_port["width"], rear_port["height"]],
        },
        "switches": switch_checks,
        "front_connectors": front_checks,
    }
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    if failures:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
