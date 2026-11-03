"""Placeholder PCB envelope used only to establish the mechanical stack."""

from cadgen import step

from lib.pcb_shape import pcb_envelope


@step(out="../STEP/pcb_envelope.step")
def pcb_envelope_model():
    return pcb_envelope()


if __name__ == "__main__":
    pcb_envelope_model()
