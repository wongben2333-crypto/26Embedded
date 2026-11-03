"""Confirm each maintained STL/3MF pair matches its generated STEP export."""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import trimesh


ROOT = Path(__file__).resolve().parents[1]
REPORT_DIR = ROOT / "reports" / "2026-10-28"
REPORT = REPORT_DIR / "mesh_consistency_checks.json"
STEP_METRICS = REPORT_DIR / "step_metrics.json"
PARTS = ("bottom_shell", "top_shell", "keybed")


def load_concatenated(path: Path) -> trimesh.Trimesh:
    scene = trimesh.load(path, force="scene", process=False)
    return scene.to_geometry()


def main() -> None:
    if not STEP_METRICS.is_file():
        raise SystemExit("Run tmp/export_step_metrics.py before this check")
    step_metrics = json.loads(STEP_METRICS.read_text(encoding="utf-8"))
    failures = []
    records = {}
    for part in PARTS:
        stl = load_concatenated(ROOT / "STL" / f"{part}.stl")
        three_mf = load_concatenated(ROOT / "3MF" / f"{part}.3mf")
        step_record = step_metrics[part]
        step_bounds = np.asarray(step_record["bounds_mm"], dtype=float)
        step_volume = float(step_record["volume_mm3"])
        bounds_delta = np.abs(stl.bounds - three_mf.bounds)
        step_stl_bounds_delta = np.abs(stl.bounds - step_bounds)
        step_3mf_bounds_delta = np.abs(three_mf.bounds - step_bounds)
        volume_delta = abs(stl.volume - three_mf.volume)
        step_stl_volume_delta = abs(stl.volume - step_volume) / max(abs(step_volume), 1e-9)
        step_3mf_volume_delta = abs(three_mf.volume - step_volume) / max(abs(step_volume), 1e-9)
        volume_relative_delta = volume_delta / max(abs(stl.volume), 1e-9)
        record = {
            "stl_triangles": int(len(stl.faces)),
            "3mf_triangles": int(len(three_mf.faces)),
            "max_bound_delta_mm": round(float(bounds_delta.max()), 9),
            "step_stl_max_bound_delta_mm": round(float(step_stl_bounds_delta.max()), 9),
            "step_3mf_max_bound_delta_mm": round(float(step_3mf_bounds_delta.max()), 9),
            "step_volume_mm3": round(step_volume, 6),
            "stl_volume_mm3": round(float(stl.volume), 6),
            "3mf_volume_mm3": round(float(three_mf.volume), 6),
            "volume_relative_delta": float(volume_relative_delta),
            "step_stl_volume_relative_delta": float(step_stl_volume_delta),
            "step_3mf_volume_relative_delta": float(step_3mf_volume_delta),
        }
        records[part] = record
        if bounds_delta.max() > 0.01:
            failures.append(f"{part}: STL/3MF bounds differ")
        if volume_relative_delta > 1e-4:
            failures.append(f"{part}: STL/3MF volume differs")
        if max(step_stl_bounds_delta.max(), step_3mf_bounds_delta.max()) > 0.01:
            failures.append(f"{part}: STEP/mesh bounds differ")
        if max(step_stl_volume_delta, step_3mf_volume_delta) > 1e-4:
            failures.append(f"{part}: STEP/mesh volume differs")

    report = {
        "status": "PASS" if not failures else "FAIL",
        "failures": failures,
        "parts": records,
        "method": "Exact STEP volume/bounds were compared with STL and 3MF after exporting both meshes from that STEP with identical tolerances.",
    }
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    if failures:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
