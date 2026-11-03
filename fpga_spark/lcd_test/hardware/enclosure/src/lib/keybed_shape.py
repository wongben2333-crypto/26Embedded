"""Parameterized one-octave keybed, keycaps and switch references."""

from __future__ import annotations

from cadgen import build123d as bd
from cadgen import srgb

from lib.params import (
    BLACK_CAP_DEPTH,
    BLACK_CAP_HEIGHT,
    BLACK_CAP_WIDTH,
    BLACK_KEY_SIDE_CLEARANCE,
    BLACK_POSITIONS,
    CAP_BOTTOM_Y,
    CAP_SOCKET_DEPTH,
    CAP_SOCKET_DIAMETER,
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
    KEYBED_PLATE_WIDTH,
    KEYBED_LOCATOR_PIN_DIAMETER,
    KEYBED_LOCATOR_PIN_TOP_Z,
    KEYBED_LOCATOR_POSITIONS,
    PCB_TOP_Z,
    PCB_THICKNESS,
    SWITCH_BODY_DEPTH,
    SWITCH_BODY_HEIGHT,
    SWITCH_BODY_WIDTH,
    SWITCH_PAD_RELIEF_DEPTH,
    SWITCH_PAD_RELIEF_SIZE,
    SWITCH_PIN_DIAMETER,
    SWITCH_PIN_PITCH,
    SWITCH_PIN_PROTRUSION,
    SWITCH_PLUNGER_DIAMETER,
    SWITCH_PLUNGER_HEIGHT,
    SWITCH_POCKET_DEPTH,
    SWITCH_POCKET_WIDTH,
    WHITE_CAP_DEPTH,
    WHITE_CAP_HEIGHT,
    WHITE_CAP_WIDTH,
    WHITE_KEY_COUNT,
    WHITE_KEY_PITCH,
    WHITE_POSITIONS,
    black_key_center_x,
    white_key_center_x,
)


def keybed_plate() -> bd.Shape:
    plate_center_y = KEYBED_PLATE_BOTTOM_Y + KEYBED_PLATE_THICKNESS / 2.0
    plate_center_z = KEYBED_PLATE_BACK_Z + KEYBED_PLATE_DEPTH / 2.0
    plate = bd.Pos(0, plate_center_y, plate_center_z) * bd.Box(
        KEYBED_PLATE_WIDTH,
        KEYBED_PLATE_THICKNESS,
        KEYBED_PLATE_DEPTH,
    )

    pocket_tool_height = KEYBED_PLATE_THICKNESS + 2.0
    pockets = []
    for index in WHITE_POSITIONS:
        pockets.append(
            bd.Pos(
                white_key_center_x(index),
                plate_center_y,
                WHITE_CAP_DEPTH / 2.0,
            )
            * bd.Box(SWITCH_POCKET_WIDTH, pocket_tool_height, SWITCH_POCKET_DEPTH)
        )
    for index in BLACK_POSITIONS:
        pockets.append(
            bd.Pos(
                black_key_center_x(index),
                plate_center_y,
                BLACK_CAP_DEPTH / 2.0,
            )
            * bd.Box(SWITCH_POCKET_WIDTH, pocket_tool_height, SWITCH_POCKET_DEPTH)
        )

    plate = plate - pockets

    # The switch pads and solder fillets sit at +/-4.15 mm from each switch
    # centre. Relieve the complete pad envelope so the keybed bears on the PCB
    # rather than on the solder. The 0.8 mm deep relief leaves a 1.2 mm top web.
    pad_reliefs = []
    for index in WHITE_POSITIONS:
        pad_reliefs.append(
            bd.Pos(
                white_key_center_x(index),
                SWITCH_PAD_RELIEF_DEPTH / 2.0 - 0.2,
                WHITE_CAP_DEPTH / 2.0,
            )
            * bd.Box(
                SWITCH_PAD_RELIEF_SIZE,
                SWITCH_PAD_RELIEF_DEPTH + 0.4,
                SWITCH_PAD_RELIEF_SIZE,
            )
        )
    for index in BLACK_POSITIONS:
        pad_reliefs.append(
            bd.Pos(
                black_key_center_x(index),
                SWITCH_PAD_RELIEF_DEPTH / 2.0 - 0.2,
                BLACK_CAP_DEPTH / 2.0,
            )
            * bd.Box(
                SWITCH_PAD_RELIEF_SIZE,
                SWITCH_PAD_RELIEF_DEPTH + 0.4,
                SWITCH_PAD_RELIEF_SIZE,
            )
        )

    # The released A4 centre creates one 11.25 mm white-key pitch. Two nominal
    # 10.6 mm rebates then leave a 0.65 mm knife-edge, below the FDM 0.8 mm
    # positive-feature limit. Merge only that shallow rebate pair.
    for left_index in range(WHITE_KEY_COUNT - 1):
        left_x = white_key_center_x(left_index)
        right_x = white_key_center_x(left_index + 1)
        rebate_gap = abs(right_x - left_x) - SWITCH_PAD_RELIEF_SIZE
        if rebate_gap < 0.8:
            pad_reliefs.append(
                bd.Pos(
                    (left_x + right_x) / 2.0,
                    SWITCH_PAD_RELIEF_DEPTH / 2.0 - 0.2,
                    WHITE_CAP_DEPTH / 2.0,
                )
                * bd.Box(
                    0.9,
                    SWITCH_PAD_RELIEF_DEPTH + 0.4,
                    SWITCH_PAD_RELIEF_SIZE,
                )
            )
    plate -= pad_reliefs

    key_layout = [
        (white_key_center_x(index), WHITE_CAP_DEPTH)
        for index in WHITE_POSITIONS
    ]
    key_layout.extend(
        (black_key_center_x(index), BLACK_CAP_DEPTH)
        for index in BLACK_POSITIONS
    )
    for center_x, depth in key_layout:
        for sign in (-1.0, 1.0):
            pin = (
                bd.Pos(
                    center_x,
                    SWITCH_PAD_RELIEF_DEPTH + 0.1,
                    depth / 2.0 + sign * GUIDE_PIN_PITCH / 2.0,
                )
                * bd.Rot(-90, 0, 0)
                * bd.Cylinder(
                    GUIDE_PIN_DIAMETER / 2.0,
                    GUIDE_PIN_TOP_Y - (SWITCH_PAD_RELIEF_DEPTH + 0.1),
                    align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN),
                )
            )
            plate += pin

    # Four upward posts provide positive X/Y location against the removable
    # lid. They are placed in the front/rear material strips outside all
    # keycap envelopes and stop below the keycap underside.
    locator_height = KEYBED_LOCATOR_PIN_TOP_Z - PCB_TOP_Z - KEYBED_PLATE_TOP_Y
    for shell_x, shell_y in KEYBED_LOCATOR_POSITIONS:
        local_z = WHITE_CAP_DEPTH / 2.0 - shell_y
        post = (
            bd.Pos(shell_x, KEYBED_PLATE_TOP_Y, local_z)
            * bd.Rot(-90, 0, 0)
            * bd.Cylinder(
                KEYBED_LOCATOR_PIN_DIAMETER / 2.0,
                locator_height,
                align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN),
            )
        )
        plate += post

    plate.label = "keybed_plate"
    plate.color = srgb("#3B4148")
    return plate


def keycap(
    center_x: float,
    width: float,
    depth: float,
    height: float,
    label: str,
    color: str,
) -> bd.Shape:
    cap = bd.Pos(center_x, CAP_BOTTOM_Y + height / 2.0, depth / 2.0) * bd.Box(
        width, height, depth
    )
    socket_tool = (
        bd.Pos(center_x, CAP_BOTTOM_Y + CAP_SOCKET_DEPTH / 2.0, depth / 2.0)
        * bd.Rot(90, 0, 0)
        * bd.Cylinder(CAP_SOCKET_DIAMETER / 2.0, CAP_SOCKET_DEPTH + 0.2)
    )
    cap = cap - socket_tool
    for sign in (-1.0, 1.0):
        guide_socket = (
            bd.Pos(
                center_x,
                CAP_BOTTOM_Y,
                depth / 2.0 + sign * GUIDE_PIN_PITCH / 2.0,
            )
            * bd.Rot(-90, 0, 0)
            * bd.Cylinder(
                GUIDE_SOCKET_DIAMETER / 2.0,
                GUIDE_SOCKET_DEPTH + 0.2,
                align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN),
            )
        )
        cap -= guide_socket

    cap.label = label
    cap.color = srgb(color)
    return cap


def white_keycap(index: int) -> bd.Shape:
    """Build a white key with rear notches around adjacent black keys."""
    cap = keycap(
        white_key_center_x(index),
        WHITE_CAP_WIDTH,
        WHITE_CAP_DEPTH,
        WHITE_CAP_HEIGHT,
        f"white_key_{index + 1}",
        "#F1F0EA",
    )
    white_left = white_key_center_x(index) - WHITE_CAP_WIDTH / 2.0
    white_right = white_key_center_x(index) + WHITE_CAP_WIDTH / 2.0
    notch_start_z = -0.2
    notch_end_z = BLACK_CAP_DEPTH + BLACK_KEY_SIDE_CLEARANCE
    notch_depth = notch_end_z - notch_start_z
    notch_z = (notch_start_z + notch_end_z) / 2.0
    tools: list[bd.Shape] = []

    for black_index in BLACK_POSITIONS:
        black_center = black_key_center_x(black_index)
        black_left = black_center - BLACK_CAP_WIDTH / 2.0
        black_right = black_center + BLACK_CAP_WIDTH / 2.0

        # Black key in the gap after this white key.
        if black_index == index:
            boundary = black_left - BLACK_KEY_SIDE_CLEARANCE
            width = white_right - boundary + 0.2
            if width > 0:
                tools.append(
                    bd.Pos(
                        boundary + width / 2.0,
                        CAP_BOTTOM_Y + WHITE_CAP_HEIGHT / 2.0,
                        notch_z,
                    )
                    * bd.Box(width, WHITE_CAP_HEIGHT + 0.4, notch_depth)
                )

        # Black key in the gap before this white key.
        if black_index == index - 1:
            boundary = black_right + BLACK_KEY_SIDE_CLEARANCE
            width = boundary - white_left + 0.2
            if width > 0:
                tools.append(
                    bd.Pos(
                        boundary - width / 2.0,
                        CAP_BOTTOM_Y + WHITE_CAP_HEIGHT / 2.0,
                        notch_z,
                    )
                    * bd.Box(width, WHITE_CAP_HEIGHT + 0.4, notch_depth)
                )

    if tools:
        cap -= tools
    return cap


def keybed() -> bd.Compound:
    children: list[bd.Shape] = [keybed_plate()]
    for index in WHITE_POSITIONS:
        children.append(white_keycap(index))
    for index in BLACK_POSITIONS:
        children.append(
            keycap(
                black_key_center_x(index),
                BLACK_CAP_WIDTH,
                BLACK_CAP_DEPTH,
                BLACK_CAP_HEIGHT,
                f"black_key_after_white_{index + 1}",
                "#1E2226",
            )
        )
    return bd.Compound(children=children, label="keybed_one_octave")


def switch_reference(center_x: float, center_z: float, label: str) -> bd.Compound:
    """Purchasable four-leg switch placeholder used only for digital fit checks."""
    # The local frame is anchored at the PCB top surface.
    body_bottom = 0.0
    body = bd.Pos(center_x, body_bottom + SWITCH_BODY_HEIGHT / 2.0, center_z) * bd.Box(
        SWITCH_BODY_WIDTH, SWITCH_BODY_HEIGHT, SWITCH_BODY_DEPTH
    )
    body.label = f"{label}:body"

    plunger = (
        bd.Pos(
            center_x,
            body_bottom + SWITCH_BODY_HEIGHT + SWITCH_PLUNGER_HEIGHT / 2.0,
            center_z,
        )
        * bd.Rot(90, 0, 0)
        * bd.Cylinder(SWITCH_PLUNGER_DIAMETER / 2.0, SWITCH_PLUNGER_HEIGHT)
    )
    plunger.label = f"{label}:plunger"

    pins: list[bd.Shape] = []
    for pin_x, pin_z in ((-1, -1), (1, -1), (-1, 1), (1, 1)):
        pin = (
            bd.Pos(
                center_x + pin_x * SWITCH_PIN_PITCH / 2.0,
                -SWITCH_PIN_PROTRUSION / 2.0,
                center_z + pin_z * SWITCH_PIN_PITCH / 2.0,
            )
            * bd.Rot(90, 0, 0)
            * bd.Cylinder(SWITCH_PIN_DIAMETER / 2.0, SWITCH_PIN_PROTRUSION)
        )
        pin.label = f"{label}:pin_{len(pins) + 1}"
        pins.append(pin)

    return bd.Compound(
        children=[body, plunger, *pins],
        label=label,
    )


def switch_references() -> bd.Compound:
    children = []
    for index in WHITE_POSITIONS:
        children.append(
            switch_reference(
                white_key_center_x(index),
                WHITE_CAP_DEPTH / 2.0,
                f"switch_white_{index + 1}",
            )
        )
    for index in BLACK_POSITIONS:
        children.append(
            switch_reference(
                black_key_center_x(index),
                BLACK_CAP_DEPTH / 2.0,
                f"switch_black_after_white_{index + 1}",
            )
        )
    return bd.Compound(children=children, label="switch_reference_set")
