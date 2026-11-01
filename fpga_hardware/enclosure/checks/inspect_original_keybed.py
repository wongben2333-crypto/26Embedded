"""Extract measurable keycap-layout evidence from the source keyboard mesh."""

from __future__ import annotations

import struct
from collections import Counter, defaultdict, deque
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "references" / "original_stl" / "piano keyboard.stl"


def read_binary_stl(path: Path) -> list[tuple[tuple[float, ...], ...]]:
    data = path.read_bytes()
    count = struct.unpack_from("<I", data, 80)[0]
    triangles = []
    for index in range(count):
        values = struct.unpack_from("<12fH", data, 84 + 50 * index)
        triangles.append(
            (
                values[3:6],
                values[6:9],
                values[9:12],
            )
        )
    return triangles


def normal(triangle: tuple[tuple[float, ...], ...]) -> tuple[float, float, float]:
    a, b, c = triangle
    ab = tuple(b[i] - a[i] for i in range(3))
    ac = tuple(c[i] - a[i] for i in range(3))
    cross = (
        ab[1] * ac[2] - ab[2] * ac[1],
        ab[2] * ac[0] - ab[0] * ac[2],
        ab[0] * ac[1] - ab[1] * ac[0],
    )
    length = sum(v * v for v in cross) ** 0.5
    return tuple(v / length for v in cross) if length else (0.0, 0.0, 0.0)


def area(triangle: tuple[tuple[float, ...], ...]) -> float:
    a, b, c = triangle
    ab = tuple(b[i] - a[i] for i in range(3))
    ac = tuple(c[i] - a[i] for i in range(3))
    cross = (
        ab[1] * ac[2] - ab[2] * ac[1],
        ab[2] * ac[0] - ab[0] * ac[2],
        ab[0] * ac[1] - ab[1] * ac[0],
    )
    return sum(v * v for v in cross) ** 0.5 / 2.0


def face_groups(
    triangles: list[tuple[tuple[float, ...], ...]],
) -> list[dict[str, object]]:
    vertex_to_faces: dict[tuple[float, ...], list[int]] = defaultdict(list)
    for index, triangle in enumerate(triangles):
        for vertex in triangle:
            vertex_to_faces[vertex].append(index)

    groups = []
    seen: set[int] = set()
    for start in range(len(triangles)):
        if start in seen:
            continue
        seen.add(start)
        queue = deque([start])
        members = []
        while queue:
            index = queue.popleft()
            members.append(index)
            for vertex in triangles[index]:
                for neighbor in vertex_to_faces[vertex]:
                    if neighbor not in seen:
                        seen.add(neighbor)
                        queue.append(neighbor)
        vertices = [vertex for index in members for vertex in triangles[index]]
        mins = tuple(min(vertex[axis] for vertex in vertices) for axis in range(3))
        maxs = tuple(max(vertex[axis] for vertex in vertices) for axis in range(3))
        groups.append(
            {
                "triangles": len(members),
                "area_mm2": round(sum(area(triangles[index]) for index in members), 4),
                "bounds_min": tuple(round(v, 4) for v in mins),
                "bounds_max": tuple(round(v, 4) for v in maxs),
                "size": tuple(round(maxs[i] - mins[i], 4) for i in range(3)),
                "center_xz": (
                    round((mins[0] + maxs[0]) / 2.0, 4),
                    round((mins[2] + maxs[2]) / 2.0, 4),
                ),
                "normal": tuple(round(v, 4) for v in normal(triangles[members[0]])),
                "mean_y": round(sum(vertex[1] for vertex in vertices) / len(vertices), 4),
            }
        )
    return sorted(groups, key=lambda item: (-item["area_mm2"], item["center_xz"]))


def main() -> None:
    triangles = read_binary_stl(SOURCE)
    axis_counts: Counter[str] = Counter()
    for triangle in triangles:
        nx, ny, nz = normal(triangle)
        dominant = max(
            (("+X", nx), ("-X", -nx), ("+Y", ny), ("-Y", -ny), ("+Z", nz), ("-Z", -nz)),
            key=lambda item: item[1],
        )
        axis_counts[dominant[0]] += 1
    upward = [triangle for triangle in triangles if normal(triangle)[1] > 0.999]
    print("dominant normal triangle counts:", dict(axis_counts))
    print("upward triangle count:", len(upward))
    print("upward triangle vertex Y values:", sorted(Counter(v[1] for t in upward for v in t).items()))
    print("upward face groups:")
    for group in face_groups(upward):
        print(group)


if __name__ == "__main__":
    main()
