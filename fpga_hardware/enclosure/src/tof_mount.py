"""Printed pair of VB22B mounting cradles for 1:1 fit checking."""

from cadgen import step, stl, threemf

from lib.tof_shape import tof_mounts


@step(out="../STEP/tof_mount.step")
@stl(out="../STL/tof_mount.stl", mesh_tolerance=3e-4)
@threemf(out="../3MF/tof_mount.3mf", mesh_tolerance=3e-4)
def tof_mount_part():
    return tof_mounts()


if __name__ == "__main__":
    tof_mount_part()
