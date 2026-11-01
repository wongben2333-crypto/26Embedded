"""R1 bottom shell: PCB-inside load-bearing tray with cable exits."""

from cadgen import step, stl, threemf

from lib.shell_shape import bottom_shell


@step(out="../STEP/bottom_shell.step")
@stl(out="../STL/bottom_shell.stl", mesh_tolerance=5e-5, mesh_angular_tolerance=0.2)
@threemf(out="../3MF/bottom_shell.3mf", mesh_tolerance=5e-5, mesh_angular_tolerance=0.2)
def bottom_shell_part():
    return bottom_shell()


if __name__ == "__main__":
    bottom_shell_part()
