"""One-octave keybed and keycap fit part: 8 white + 5 black keys."""

from cadgen import step, stl, threemf

from lib.keybed_shape import keybed


@step(out="../STEP/keybed.step")
@stl(out="../STL/keybed.stl", mesh_tolerance=4e-4)
@threemf(out="../3MF/keybed.3mf", mesh_tolerance=4e-4)
def keybed_fit_part():
    return keybed()


if __name__ == "__main__":
    keybed_fit_part()
