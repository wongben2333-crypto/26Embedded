"""Export JLC-ready single-body STLs for the bottom and top shells."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

import numpy as np
import trimesh
from trimesh.transformations import rotation_matrix


ROOT = Path(__file__).resolve().parents[1]
OUTPUT_DIR = ROOT / "exports" / "jlc_2026-10-28"
REPORT = OUTPUT_DIR / "shell_parts.json"
PARTS = {
    "bottom_shell_single": (ROOT / "STL" / "bottom_shell.stl", 0.0),
    "top_shell_single": (ROOT / "STL" / "top_shell.stl", np.pi),
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def clean_export(source: Path, output: Path, rotate_x: float) -> dict:
    mesh = trimesh.load(source, force="mesh", process=True)
    mesh.merge_vertices()
    mesh.update_faces(mesh.unique_faces())
    mesh.remove_unreferenced_vertices()
    trimesh.repair.fix_normals(mesh, multibody=False)
    if mesh.volume < 0:
        mesh.invert()
    if rotate_x:
        mesh.apply_transform(rotation_matrix(rotate_x, [1.0, 0.0, 0.0]))
    bounds = mesh.bounds
    mesh.apply_translation(
        [
            -(bounds[0, 0] + bounds[1, 0]) / 2.0,
            -(bounds[0, 1] + bounds[1, 1]) / 2.0,
            -bounds[0, 2],
        ]
    )

    face_edges = np.vstack(
        (
            mesh.faces[:, [0, 1]],
            mesh.faces[:, [1, 2]],
            mesh.faces[:, [2, 0]],
        )
    )
    face_edges.sort(axis=1)
    _, edge_counts = np.unique(face_edges, axis=0, return_counts=True)
    boundary_edges = int((edge_counts == 1).sum())
    nonmanifold_edges = int((edge_counts > 2).sum())
    if not mesh.is_watertight or not mesh.is_winding_consistent:
        raise SystemExit(f"{source.name}: repaired mesh is not closed/consistent")
    if len(mesh.split(only_watertight=False)) != 1:
        raise SystemExit(f"{source.name}: expected one connected shell")
    if boundary_edges or nonmanifold_edges or mesh.volume <= 0:
        raise SystemExit(f"{source.name}: mesh validation failed")

    mesh.export(output, file_type="stl")
    return {
        "file": output.name,
        "triangles": int(len(mesh.faces)),
        "watertight": bool(mesh.is_watertight),
        "winding_consistent": bool(mesh.is_winding_consistent),
        "connected_shells": len(mesh.split(only_watertight=False)),
        "boundary_edges": boundary_edges,
        "nonmanifold_edges": nonmanifold_edges,
        "volume_mm3": round(float(mesh.volume), 6),
        "bounds_mm": [
            [round(float(value), 6) for value in mesh.bounds[0]],
            [round(float(value), 6) for value in mesh.bounds[1]],
        ],
        "sha256": sha256(output),
    }


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    records = {}
    for name, (source, rotate_x) in PARTS.items():
        records[name] = clean_export(source, OUTPUT_DIR / f"{name}.stl", rotate_x)
    report = {
        "status": "PASS",
        "parts": records,
        "orientation": "Bottom uses floor at Z=0; top is rotated 180 degrees about X so the visible top face is at Z=0.",
    }
    REPORT.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
