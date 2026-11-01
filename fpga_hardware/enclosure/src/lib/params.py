"""Mechanical parameters for the FPGA instrument enclosure.

All dimensions are millimetres. Coordinates used by the local fit models are:
+X right, +Y up, +Z toward the player/front. The keybed back edge is Z=0 and
the PCB top surface is Y=0. The final enclosure coordinate system will be
anchored to the bottom-shell exterior plane in the next phase.
"""

# Measured from references/original_stl/piano keyboard.stl.
ORIGINAL_WHITE_CAP_WIDTH = 14.24
ORIGINAL_WHITE_KEY_PITCH = 15.24
ORIGINAL_WHITE_CAP_DEPTH = 47.55
ORIGINAL_WHITE_CAP_HEIGHT = 4.80
ORIGINAL_BLACK_CAP_WIDTH = 7.62
ORIGINAL_BLACK_CAP_DEPTH = 29.007
ORIGINAL_BLACK_CAP_HEIGHT = 6.80

# One octave: C D E F G A B C, with C# D# F# G# A#.
WHITE_KEY_COUNT = 8
BLACK_KEY_COUNT = 5
WHITE_POSITIONS = tuple(range(WHITE_KEY_COUNT))
BLACK_POSITIONS = (0, 1, 3, 4, 5)
# The current Gerber places the A4 switch at X=+17.00 rather than the nominal
# +17.25. Follow the released layout so the switch body and cap socket stay
# concentric; this changes adjacent white-key pitches to 11.25 and 11.75 mm.
WHITE_KEY_CENTER_X_OVERRIDES = {5: 17.0}

# The user constrained the PCB width to 100 mm. Keep the one-octave arrangement
# but scale the white-key pitch so eight white keys fit with usable side margin.
WHITE_CAP_WIDTH = 10.50
WHITE_KEY_PITCH = 11.50
WHITE_CAP_DEPTH = ORIGINAL_WHITE_CAP_DEPTH
WHITE_CAP_HEIGHT = ORIGINAL_WHITE_CAP_HEIGHT
BLACK_CAP_WIDTH = 5.62
BLACK_CAP_DEPTH = ORIGINAL_BLACK_CAP_DEPTH
BLACK_CAP_HEIGHT = ORIGINAL_BLACK_CAP_HEIGHT
BLACK_KEY_SIDE_CLEARANCE = 0.30

# Switch data from C127415_1503566052111906983.pdf and the user's measurement.
# The complete height above the PCB is 5.0. The body is 8.5 wide by 7.8 deep;
# the lower 1.75 mm has the full 8.5 width. Use that conservative full-width
# envelope for keybed clearance instead of the older 7.8 x 7.8 placeholder.
SWITCH_BODY_WIDTH = 8.5
SWITCH_BODY_DEPTH = 7.8
SWITCH_BODY_HEIGHT = 3.0
SWITCH_PIN_PITCH = 4.5
SWITCH_PIN_DIAMETER = 0.7
SWITCH_PIN_PROTRUSION = 3.0
SWITCH_PLUNGER_DIAMETER = 3.5
SWITCH_PLUNGER_HEIGHT = 2.0
SWITCH_TOTAL_HEIGHT = SWITCH_BODY_HEIGHT + SWITCH_PLUNGER_HEIGHT
SWITCH_TRAVEL = 2.0

FIT_CLEARANCE = 0.30
# The datasheet permits an 8.7 mm switch body. A 9.0 mm pocket would leave only
# 0.15 mm per side with no allowance for FDM hole shrinkage. Since the complete
# shell is a one-shot print, use a 0.35 mm nominal pocket clearance per side.
SWITCH_POCKET_WIDTH = 9.2
SWITCH_POCKET_DEPTH = 8.3
SWITCH_POCKET_CLEARANCE_PER_SIDE = (
    SWITCH_POCKET_WIDTH - SWITCH_BODY_WIDTH
) / 2.0
SWITCH_POCKET_DEPTH_CLEARANCE_PER_SIDE = (
    SWITCH_POCKET_DEPTH - SWITCH_BODY_DEPTH
) / 2.0
SWITCH_POCKET_MIN_CLEARANCE = 0.15
# Clear the complete pad envelope: centres at +/-4.15, pad diameter 1.8
# (outer edge +/-5.05), plus 0.25 mm around every edge. The guide posts start
# above this relief, so they do not create thin webs inside the rebate.
SWITCH_PAD_RELIEF_SIZE = 10.6
SWITCH_PAD_RELIEF_DEPTH = 0.8
CAP_SOCKET_CLEARANCE_PER_SIDE = 0.10
CAP_SOCKET_DIAMETER = SWITCH_PLUNGER_DIAMETER + 2.0 * CAP_SOCKET_CLEARANCE_PER_SIDE
CAP_SOCKET_DEPTH = 3.2

PCB_THICKNESS = 1.6
PCB_PLACEHOLDER_WIDTH = 100.0
PCB_PLACEHOLDER_DEPTH = 70.0
PCB_PLACEHOLDER_BACK_Z = -4.0
PCB_PLACEHOLDER_CENTER_Z = PCB_PLACEHOLDER_BACK_Z + PCB_PLACEHOLDER_DEPTH / 2.0

KEYBED_PLATE_SIDE_MARGIN = 3.0
KEYBED_PLATE_BACK_MARGIN = 3.0
KEYBED_PLATE_THICKNESS = 2.0
KEYBED_PLATE_BOTTOM_Y = 0.0
KEYBED_PLATE_TOP_Y = KEYBED_PLATE_BOTTOM_Y + KEYBED_PLATE_THICKNESS
KEYBED_PLATE_WIDTH = (
    WHITE_KEY_COUNT * WHITE_KEY_PITCH + 2.0 * KEYBED_PLATE_SIDE_MARGIN
)
# Keep the switch/guide datum and rear edge fixed. Derive the depth from the
# requested rear/front edges so the plate ends exactly at Y=-26.8 in the shell.
# The remaining 8.2 mm of exposed PCB still serves the downward-facing front
# connector wires.
KEYBED_PLATE_DEPTH = 53.575
KEYBED_PLATE_BACK_Z = -KEYBED_PLATE_BACK_MARGIN
KEYBED_PLATE_REAR_Y = WHITE_CAP_DEPTH / 2.0 - KEYBED_PLATE_BACK_Z
KEYBED_PLATE_FRONT_Y = (
    WHITE_CAP_DEPTH / 2.0 - (KEYBED_PLATE_BACK_Z + KEYBED_PLATE_DEPTH)
)
KEYBED_PCB_FRONT_EXPOSURE_MIN = 8.0

# Positive X/Y location between the keybed and the lid. The keybed owns the
# four upward posts; the lid owns matching blind sockets in four local bosses
# under the front/rear rails. This replaces a rigid stop loaded against J13.
KEYBED_LOCATOR_PIN_DIAMETER = 1.6
KEYBED_LOCATOR_SOCKET_DIAMETER = 2.0
KEYBED_LOCATOR_PIN_TOP_Z = 19.0
KEYBED_LOCATOR_SOCKET_DEPTH = 1.25
KEYBED_LOCATOR_BOSS_WIDTH = 3.4
KEYBED_LOCATOR_BOSS_DEPTH = 2.9
# Shell coordinates. Front posts sit under the continuous front rail; rear
# posts sit under the two side segments left and right of the J13 opening.
KEYBED_LOCATOR_POSITIONS = (
    (-25.0, -25.7),
    (25.0, -25.7),
    (-35.0, 25.7),
    (35.0, 25.7),
)
KEYBED_LOCATOR_BOSS_Y_OFFSET = 0.15

CAP_BOTTOM_Y = SWITCH_TOTAL_HEIGHT
FULL_TRAVEL_CAP_TO_PLATE_GAP = (
    CAP_BOTTOM_Y - SWITCH_TRAVEL - KEYBED_PLATE_TOP_Y
)

# Each key gets two fixed guide pins on its centreline. The matching blind
# sockets in the keycap constrain front/back rocking while remaining printable
# as separate, support-free parts.
GUIDE_PIN_DIAMETER = 2.2
GUIDE_SOCKET_DIAMETER = 2.5
GUIDE_PIN_PITCH = 24.0
GUIDE_SOCKET_DEPTH = 2.8
GUIDE_INITIAL_INSERTION = 0.4
GUIDE_FULL_TRAVEL_INSERTION = GUIDE_INITIAL_INSERTION + SWITCH_TRAVEL
GUIDE_PIN_TOP_Y = CAP_BOTTOM_Y + GUIDE_INITIAL_INSERTION

# Locked user envelope: 31 x 15 x 6.2 mm. Each side gets 0.3 mm clearance and
# the four-wire lead exits through one narrow 15 x 6.2 mm end face toward the PCB.
TOF_MODULE_WIDTH = 31.0
TOF_MODULE_HEIGHT = 15.0
TOF_MODULE_DEPTH = 6.2
TOF_SEAT_THICKNESS = 1.5
TOF_MODULE_CLEARANCE_PER_SIDE = 0.30
TOF_LENS_OFFSET_X = 0.0
TOF_LENS_OFFSET_Y = 0.0
TOF_MOUNT_WALL = 2.0
TOF_MOUNT_REAR_EXTENSION = 0.0
TOF_LIGHT_WELL_DEPTH = 18.5
TOF_APERTURE_WIDTH = 29.0
TOF_APERTURE_HEIGHT = 13.0
TOF_APERTURE_CORNER_RADIUS = 1.0
TOF_INNER_CABLE_WINDOW_WIDTH = 12.0
TOF_INNER_CABLE_WINDOW_HEIGHT = 3.6
TOF_INNER_CABLE_WINDOW_Z = TOF_SEAT_THICKNESS + 3.1
TOF_MOUNT_OUTER_WIDTH = TOF_MODULE_WIDTH + 2.0 * TOF_MOUNT_WALL
TOF_MOUNT_OUTER_HEIGHT = TOF_MODULE_HEIGHT + 2.0 * TOF_MOUNT_WALL
TOF_MOUNT_TOTAL_DEPTH = (
    TOF_MOUNT_REAR_EXTENSION
    + TOF_SEAT_THICKNESS
    + TOF_MODULE_DEPTH
    + TOF_LIGHT_WELL_DEPTH
)
TOF_CENTER_SEPARATION_X = 90.0
TOF_AXIS_GAUGE_LENGTH = 55.0

# Fit-only layout. These are deliberately behind the keybed and do not describe
# final shell locations.
TOF_FIT_Z = -42.0
TOF_LEFT_X = -TOF_CENTER_SEPARATION_X / 2.0
TOF_RIGHT_X = TOF_CENTER_SEPARATION_X / 2.0

# R1 shell layout. External X/Y envelopes come from the supplied STL bounds.
# The 25.4 mm overall height is a design choice for R1; the original split
# files do not preserve their assembly transforms.
SHELL_ORIGIN_NOTE = "bottom exterior plane centre, +Z up"
TOP_SHELL_OUTER_WIDTH = 140.000
TOP_SHELL_OUTER_DEPTH = 109.000
TOP_SHELL_TOTAL_HEIGHT = 26.200
BOTTOM_SHELL_OUTER_WIDTH = 130.000
BOTTOM_SHELL_OUTER_DEPTH = TOP_SHELL_OUTER_DEPTH
BOTTOM_SHELL_HEIGHT = 22.124
BOTTOM_SHELL_WALL = 2.500
BOTTOM_SHELL_FLOOR = 2.500
BOTTOM_SHELL_CORNER_RADIUS = 10.000
TOP_SHELL_WALL = 2.000
TOP_SHELL_LID_THICKNESS = TOP_SHELL_TOTAL_HEIGHT - BOTTOM_SHELL_HEIGHT
TOP_SHELL_PLATE_BOTTOM_Z = TOP_SHELL_TOTAL_HEIGHT - TOP_SHELL_LID_THICKNESS
TOP_SHELL_CORNER_RADIUS = 18.000

# The switch bodies sit directly on this datum. Raising the board by one
# board thickness closes the former local-coordinate gap while preserving the
# 24.2 mm white-key and 26.2 mm black-key/ToF top heights.
PCB_TOP_Z = 14.400
PCB_MOUNT_HOLE_DIAMETER = 3.400
PCB_MOUNT_HOLE_X = 44.000
PCB_MOUNT_HOLE_Y = 28.000
PCB_ROUNDED_CORNER_RADIUS = 3.000
PCB_STANDOFF_DIAMETER = 8.000
PCB_STANDOFF_PILOT_DIAMETER = 2.500

PCB_CN2_ORIGIN_Y = 32.004
J13_CONNECTOR_WIDTH = 58.4
J13_CONNECTOR_DEPTH = 8.91
J13_CONNECTOR_HEIGHT = 12.2
J13_CONNECTOR_CENTER_Y = 32.104
J13_CONNECTOR_BOTTOM_Z = 11.2
J13_SHELL_CLEARANCE = 0.3

# A pre-terminated 40-way ribbon normally carries a 55.4 x 6.1 x 10.7 mm
# IDC socket at each end.  The service opening must pass that rigid plug, and
# the internal half must have a local roof above the board-mounted connector.
IDC_PLUG_WIDTH = 55.4
IDC_PLUG_DEPTH = 6.1
IDC_PLUG_HEIGHT = 10.7
IDC_PLUG_CLEARANCE = 0.5
J13_CABLE_RECESS_WIDTH = IDC_PLUG_WIDTH + 2.0 * IDC_PLUG_CLEARANCE
J13_CABLE_RECESS_DEPTH = IDC_PLUG_DEPTH + 2.0 * IDC_PLUG_CLEARANCE
J13_CABLE_RECESS_TOP_Z = PCB_TOP_Z + IDC_PLUG_HEIGHT + IDC_PLUG_CLEARANCE
J13_SERVICE_CAP_WIDTH = 60.0
J13_SERVICE_CAP_DEPTH = 9.0
J13_SERVICE_CAP_CENTER_Y = 33.0
J13_SERVICE_CAP_TOP_Z = 27.0
J13_SERVICE_CAP_CORNER_RADIUS = 2.0

# A 97 mm opening leaves 0.5 mm of keybed under the lid on both sides while
# still giving the outermost keycaps ample assembly clearance. The 49.5 mm
# depth leaves 0.975 mm in front of and behind the 47.55 mm white keycaps.
KEYBOARD_OPENING_WIDTH = 97.000
KEYBOARD_OPENING_DEPTH = 49.500
TOP_SCREW_X = 58.000
TOP_SCREW_Y = 25.000
TOP_SCREW_CLEARANCE_DIAMETER = 3.400
TOP_SCREW_COUNTERBORE_DIAMETER = 6.200
TOP_SCREW_COUNTERBORE_DEPTH = 2.000
SHELL_SCREW_BOSS_DIAMETER = 7.000
SHELL_SCREW_PILOT_DIAMETER = 2.500

# Local relief where downward-soldered headers pass beside PCB standoffs.
# The whole body+pin envelope is cleared by 0.40 mm so the curved standoff
# surfaces retain at least 0.30 mm of measured clearance.
PCB_HEADER_RELIEF_Z_MIN = 4.000
PCB_HEADER_RELIEF_Z_MAX = 13.100
PCB_HEADER_RELIEF_CLEARANCE = 0.400
PCB_DOWN_HEADER_PIN_Z_MIN = 4.300
PCB_DOWN_HEADER_PIN_Z_MAX = 10.300
PCB_DOWN_HEADER_BODY_Z_MIN = 10.300
PCB_DOWN_HEADER_BODY_Z_MAX = 12.800
PCB_DOWN_HEADER_PIN_DIAMETER = 0.640
PCB_STANDOFF_RELIEF_ENVELOPES = (
    ("H2", (-40.772, 29.464, -33.142, 32.004)),
    ("H4", (-48.392, 32.004, -40.762, 34.544)),
    ("H3", (40.386, 31.496, 45.476, 34.036)),
    ("H14", (34.326, -33.663, 49.576, -31.123)),
)

# Move only the +Y support rib locally around H2. The shifted strip spans
# Y=24.8..27.8, leaving 1.664 mm to the measured H2 edge at Y=29.464.
H2_RIB_X_MIN = -42.000
H2_RIB_X_MAX = -32.000
H2_RIB_Y_CENTER = 26.300
H2_RIB_DEPTH = 3.000
CABLE_EXIT_SPECS = (
    {
        "name": "fpga_j13",
        "face": "rear",
        "center": 0.0,
        "width": 56.8,
        "height": 12.0,
        "z": 14.0,
        "clamp_holes": (
            (-18.0, -10.0),
            (18.0, -10.0),
        ),
    },
    {"name": "photo_6ch", "face": "front", "center": -28.0, "width": 44.0, "height": 17.0, "z": 11.5},
    {"name": "encoder_4ch", "face": "front", "center": 28.0, "width": 36.0, "height": 14.0, "z": 11.0},
    {
        "name": "rear_aux_left",
        "face": "left",
        "center": 29.5,
        "width": 12.0,
        "height": 8.0,
        "z": 12.0,
        "clamp_holes": (),
    },
    {
        "name": "rear_aux_right",
        "face": "right",
        "center": 29.5,
        "width": 12.0,
        "height": 8.0,
        "z": 12.0,
        "clamp_holes": (),
    },
)
PHOTO_WIRE_COUNT = 12
PHOTO_WIRE_DIAMETER = 3.5
PHOTO_POWER_WIRE_COUNT = 2
PHOTO_POWER_WIRE_DIAMETER = 3.5
CABLE_CLAMP_HOLE_DIAMETER = 2.2
CABLE_CLAMP_HOLE_OFFSET = 4.0

SHELL_TOF_LEFT_X = -45.000
SHELL_TOF_RIGHT_X = 45.000
SHELL_TOF_BASE_Y = 45.000
SHELL_TOF_BASE_Z = 0.000
# Keep the complete sensor seat, cable window and lower light-well wall with
# the bottom shell.  Only the hood above the shell seam lifts with the lid.
TOF_MOUNT_SPLIT_Z = BOTTOM_SHELL_HEIGHT


def white_key_center_x(index: int) -> float:
    """Return a white-key centre relative to the octave centre."""
    nominal = (index - (WHITE_KEY_COUNT - 1) / 2.0) * WHITE_KEY_PITCH
    return WHITE_KEY_CENTER_X_OVERRIDES.get(index, nominal)


def black_key_center_x(index: int) -> float:
    """Return the black-key centre in the gap following white key index."""
    return (index + 0.5 - (WHITE_KEY_COUNT - 1) / 2.0) * WHITE_KEY_PITCH
