"""Split the checked keybed assembly into individually uploadable STL parts."""

from __future__ import annotations

import hashlib
import json
import zipfile
from pathlib import Path

import numpy as np
import trimesh
from trimesh.transformations import rotation_matrix


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "tmp" / "keybed_parts_raw"
OUTPUT_DIR = ROOT / "exports" / "jlc_2026-10-28" / "keybed_parts"
REPORT = ROOT / "exports" / "jlc_2026-10-28" / "keybed_parts.json"
ZIP_PATH = ROOT / "exports" / "jlc_2026-10-28" / "keybed_parts.zip"

def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare_for_print(mesh: trimesh.Trimesh) -> trimesh.Trimesh:
    mesh = mesh.copy()
    trimesh.repair.fix_normals(mesh, multibody=False)
    if mesh.volume < 0:
        mesh.invert()
    mesh.apply_transform(rotation_matrix(np.pi / 2.0, [1.0, 0.0, 0.0]))
    bounds = mesh.bounds
    mesh.apply_translation(
        [
            -(bounds[0, 0] + bounds[1, 0]) / 2.0,
            -(bounds[0, 1] + bounds[1, 1]) / 2.0,
            -bounds[0, 2],
        ]
    )
    return mesh


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    paths = sorted(SOURCE.glob("*.stl"))
    if len(paths) != 14:
        raise SystemExit(f"Expected 14 raw keybed STLs, found {len(paths)}")
    named_parts = [(path.stem, trimesh.load(path, force="mesh", process=True)) for path in paths]

    records = {}
    written = []
    for name, raw_mesh in named_parts:
        mesh = prepare_for_print(raw_mesh)
        if not mesh.is_watertight:
            raise SystemExit(f"{name}: mesh is not watertight")
        if not mesh.is_winding_consistent:
            raise SystemExit(f"{name}: winding is inconsistent after repair")
        if mesh.volume <= 0:
            raise SystemExit(f"{name}: non-positive volume")

        output = OUTPUT_DIR / f"{name}.stl"
        mesh.export(output, file_type="stl")
        written.append(output)
        records[name] = {
            "file": output.name,
            "triangles": int(len(mesh.faces)),
            "watertight": bool(mesh.is_watertight),
            "winding_consistent": bool(mesh.is_winding_consistent),
            "volume_mm3": round(float(mesh.volume), 6),
            "bounds_mm": [
                [round(float(value), 6) for value in mesh.bounds[0]],
                [round(float(value), 6) for value in mesh.bounds[1]],
            ],
            "sha256": sha256(output),
        }

    with zipfile.ZipFile(ZIP_PATH, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for output in written:
            archive.write(output, arcname=output.name)

    report = {
        "status": "PASS",
        "source": "parameterized keybed source via checks/export_keybed_parts_source.py",
        "part_count": len(written),
        "zip": str(ZIP_PATH.relative_to(ROOT)).replace("\\", "/"),
        "parts": records,
        "orientation": "Each part was rotated so its functional height is +Z, centered in XY, and placed at Z=0.",
    }
    REPORT.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
