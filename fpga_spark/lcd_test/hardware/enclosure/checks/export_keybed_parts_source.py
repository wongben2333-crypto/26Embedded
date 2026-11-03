"""Export individual keybed and keycap STL bodies from the parameterized source."""

from pathlib import Path

from cadgen import build123d as bd

from lib.keybed_shape import keybed_plate, keycap, white_keycap
from lib.params import (
    BLACK_CAP_DEPTH,
    BLACK_CAP_HEIGHT,
    BLACK_CAP_WIDTH,
    BLACK_POSITIONS,
    WHITE_POSITIONS,
    black_key_center_x,
    white_key_center_x,
)


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "tmp" / "keybed_parts_raw"
WHITE_NOTES = ("C4", "D4", "E4", "F4", "G4", "A4", "B4", "C5")
BLACK_NOTES = ("Cs4", "Ds4", "Fs4", "Gs4", "As4")


OUTPUT.mkdir(parents=True, exist_ok=True)
bd.export_stl(keybed_plate(), OUTPUT / "keybed_plate.stl", tolerance=4e-4)

for index, note in zip(WHITE_POSITIONS, WHITE_NOTES):
    bd.export_stl(
        white_keycap(index),
        OUTPUT / f"white_key_{index + 1:02d}_{note}.stl",
        tolerance=4e-4,
    )

for index, note in zip(BLACK_POSITIONS, BLACK_NOTES):
    bd.export_stl(
        keycap(
            black_key_center_x(index),
            BLACK_CAP_WIDTH,
            BLACK_CAP_DEPTH,
            BLACK_CAP_HEIGHT,
            f"black_key_after_white_{index + 1}",
            "#1E2226",
        ),
        OUTPUT / f"black_key_{BLACK_POSITIONS.index(index) + 1:02d}_{note}.stl",
        tolerance=4e-4,
    )
