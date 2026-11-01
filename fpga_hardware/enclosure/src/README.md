# CAD models

整机结构和尺寸决策以 [`../../docs/ENCLOSURE-DESIGN.md`](../../docs/ENCLOSURE-DESIGN.md)
为准；本文件只说明参数化生成脚本和输出物。
本次硬件确认版的逐项改动见
[`../MODIFICATION-2026-10-28.md`](../MODIFICATION-2026-10-28.md)。

| Script | Outputs | Purpose |
| --- | --- | --- |
| `keybed.py` | `STEP/keybed.step`, `STL/keybed.stl`, `3MF/keybed.3mf` | One-octave keybed and 13 separate keycaps |
| `tof_mount.py` | `STEP/tof_mount.step`, `STL/tof_mount.stl`, `3MF/tof_mount.3mf` | Two upward-pointing 31×15×6.2 mm ToF cradles with a 1.5 mm bottom seat |
| `pcb_envelope.py` | `STEP/pcb_envelope.step` | Provisional PCB envelope only |
| `fit_sample.py` | `STEP/fit_sample.step`, `STL/fit_sample.stl`, `3MF/fit_sample.3mf` | Flat local print kit; no complete shell |
| `fit_assembly.py` | `STEP/fit_assembly.step` | Digital checks with switch and ToF reference envelopes |
| `bottom_shell.py` | `STEP/bottom_shell.step`, `STL/bottom_shell.stl`, `3MF/bottom_shell.3mf` | PCB tray plus fixed ToF seats, lower hoods and wire windows |
| `top_shell.py` | `STEP/top_shell.step`, `STL/top_shell.stl`, `3MF/top_shell.3mf` | Upper shell with removable ToF hoods above the seam |
| `assembly.py` | `STEP/assembly.step` | One-box assembly with split ToF cradles and three cable exits |
| `board_outline.py` | `DXF/board_outline.dxf` | Provisional PCB outline and mounting holes |
| `pcb_layout_floorplan.py` | `DXF/pcb_layout_floorplan.dxf` | 1:1 PCB placement and keep-out underlay |

Run from `fpga_hardware/enclosure` with the pinned `cadgen` Python:

```powershell
uvx --offline --no-config --managed-python --python 3.13 --from cadgen==0.7.21 python src/fit_sample.py
uvx --offline --no-config --managed-python --python 3.13 --from cadgen==0.7.21 python src/fit_assembly.py
uvx --offline --no-config --managed-python --python 3.13 --from cadgen==0.7.21 python src/assembly.py
uvx --offline --no-config --managed-python --python 3.13 --from cadgen==0.7.21 python src/board_outline.py
uvx --offline --no-config --managed-python --python 3.13 --from cadgen==0.7.21 python src/pcb_layout_floorplan.py
```

The original STL inputs are retained under `references/original_stl/` and are
never overwritten.

R2 interfaces:

- ToF cradles split at `Z=22.124 mm`: seats, lower walls and wire windows stay
  in the bottom shell; only the upper light hoods lift with the top shell.
- Rear 56.8×12 mm 40P service opening passes a pre-terminated
  55.4×10.7×6.1 mm IDC plug; two Ø2.2 mm lower clamp holes remain.
- Left and right rear aux windows are each 12×8 mm, mirrored at `Y=29.5`.
- The 40P area has a local Z=27.0 mm service cap over a Z=25.6 mm recess,
  leaving 1.4 mm of roof while the main top plane remains Z=26.2 mm.
- Left 44×17 mm photo-sensor/12V service opening and right 36×14 mm encoder
  service opening, each with two Ø2.2 mm clamp-screw holes.

If Windows reports “no permission” when opening generated CAD files in desktop
CAD software, run `powershell -ExecutionPolicy Bypass -File publish-access.ps1`
from the enclosure project root. This grants ordinary desktop users read access
without changing the generated geometry.

Run the same access-publishing command after every full STEP/STL/3MF export.
Cadgen may replace outputs with owner-only ACLs. The 2026-10-28 verification is
stored in `reports/2026-10-28/acl_verification.txt`.
