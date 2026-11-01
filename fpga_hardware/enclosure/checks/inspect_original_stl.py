"""Inspect read-only source STL meshes without modifying or repairing them."""

from __future__ import annotations

import json
import math
import struct
from collections import Counter, defaultdict, deque
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INPUT_DIR = ROOT / "references" / "original_stl"
OUTPUT = ROOT / "tmp" / "original_stl_report.json"


def read_stl(path: Path) -> list[tuple[tuple[float, float, float], ...]]:
    data = path.read_bytes()
    if len(data) >= 84:
        count = struct.unpack_from("<I", data, 80)[0]
        if 84 + 50 * count == len(data):
            triangles = []
            for index in range(count):
                values = struct.unpack_from("<12fH", data, 84 + 50 * index)
                triangles.append(
                    (
                        tuple(float(v) for v in values[3:6]),
                        tuple(float(v) for v in values[6:9]),
                        tuple(float(v) for v in values[9:12]),
                    )
                )
            return triangles

    triangles = []
    vertices = []
    for line in data.decode("ascii", errors="strict").splitlines():
        words = line.strip().split()
        if len(words) == 4 and words[0].lower() == "vertex":
            vertices.append(tuple(float(v) for v in words[1:]))
            if len(vertices) == 3:
                triangles.append(tuple(vertices))
                vertices = []
    return triangles


def signed_volume(triangle: tuple[tuple[float, float, float], ...]) -> float:
    a, b, c = triangle
    return (
        a[0] * (b[1] * c[2] - b[2] * c[1])
        - a[1] * (b[0] * c[2] - b[2] * c[0])
        + a[2] * (b[0] * c[1] - b[1] * c[0])
    ) / 6.0


def triangle_area(triangle: tuple[tuple[float, float, float], ...]) -> float:
    a, b, c = triangle
    ab = tuple(b[i] - a[i] for i in range(3))
    ac = tuple(c[i] - a[i] for i in range(3))
    cross = (
        ab[1] * ac[2] - ab[2] * ac[1],
        ab[2] * ac[0] - ab[0] * ac[2],
        ab[0] * ac[1] - ab[1] * ac[0],
    )
    return math.sqrt(sum(v * v for v in cross)) / 2.0


def connected_components(
    triangles: list[tuple[tuple[float, float, float], ...]],
) -> list[int]:
    vertex_to_triangles: dict[tuple[float, float, float], list[int]] = defaultdict(list)
    for triangle_index, triangle in enumerate(triangles):
        for vertex in triangle:
            vertex_to_triangles[vertex].append(triangle_index)

    seen: set[int] = set()
    sizes = []
    for start in range(len(triangles)):
        if start in seen:
            continue
        seen.add(start)
        queue = deque([start])
        size = 0
        while queue:
            triangle_index = queue.popleft()
            size += 1
            for vertex in triangles[triangle_index]:
                for neighbor in vertex_to_triangles[vertex]:
                    if neighbor not in seen:
                        seen.add(neighbor)
                        queue.append(neighbor)
        sizes.append(size)
    return sorted(sizes, reverse=True)


def inspect(path: Path) -> dict[str, object]:
    triangles = read_stl(path)
    vertices = [vertex for triangle in triangles for vertex in triangle]
    mins = [min(vertex[axis] for vertex in vertices) for axis in range(3)]
    maxs = [max(vertex[axis] for vertex in vertices) for axis in range(3)]
    edges: Counter[tuple[tuple[float, float, float], tuple[float, float, float]]] = Counter()
    for triangle in triangles:
        for start, end in ((triangle[0], triangle[1]), (triangle[1], triangle[2]), (triangle[2], triangle[0])):
            key = tuple(sorted((start, end)))
            edges[key] += 1

    edge_counts = Counter(edges.values())
    area_sorted = sorted(triangle_area(triangle) for triangle in triangles)
    volume = sum(signed_volume(triangle) for triangle in triangles)
    components = connected_components(triangles)
    return {
        "file": path.name,
        "bytes": path.stat().st_size,
        "triangle_count": len(triangles),
        "vertex_count": len({vertex for triangle in triangles for vertex in triangle}),
        "bounds_min_mm": [round(v, 6) for v in mins],
        "bounds_max_mm": [round(v, 6) for v in maxs],
        "envelope_mm": [round(maxs[i] - mins[i], 6) for i in range(3)],
        "signed_volume_mm3": round(volume, 6),
        "surface_area_mm2": round(sum(triangle_area(triangle) for triangle in triangles), 6),
        "minimum_triangle_area_mm2": round(area_sorted[0], 12),
        "edge_incidence": {str(count): amount for count, amount in sorted(edge_counts.items())},
        "boundary_edge_count": edge_counts[1],
        "nonmanifold_edge_count": sum(amount for count, amount in edge_counts.items() if count > 2),
        "connected_component_triangle_counts": components,
    }


def main() -> None:
    paths = sorted(INPUT_DIR.glob("*.stl"))
    if not paths:
        raise SystemExit(f"No source STL files found in {INPUT_DIR}")
    report = {path.name: inspect(path) for path in paths}
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(report, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2, ensure_ascii=True))


if __name__ == "__main__":
    main()
