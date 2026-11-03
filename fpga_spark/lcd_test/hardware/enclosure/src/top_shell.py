"""R1 upper shell: removable keyboard lid with clear ToF optical passages."""

from cadgen import step, stl, threemf

from lib.shell_shape import top_shell


@step(out="../STEP/top_shell.step")
@stl(out="../STL/top_shell.stl", mesh_tolerance=5e-5, mesh_angular_tolerance=0.2)
@threemf(out="../3MF/top_shell.3mf", mesh_tolerance=5e-5, mesh_angular_tolerance=0.2)
def top_shell_part():
    return top_shell()


if __name__ == "__main__":
    top_shell_part()
