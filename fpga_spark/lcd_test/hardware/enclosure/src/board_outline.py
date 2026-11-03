"""Provisional PCB outline for R1; not yet a released manufacturing drawing."""

from cadgen import dxf

from lib.pcb_shape import pcb_profile


@dxf(out="../DXF/board_outline.dxf")
def board_outline_drawing():
    return pcb_profile()


if __name__ == "__main__":
    board_outline_drawing()
