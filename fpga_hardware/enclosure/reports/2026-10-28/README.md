# 2026-10-28 外壳复检报告

本节报告对应 [../../MODIFICATION-2026-10-28.md](../../MODIFICATION-2026-10-28.md)
和当前 `STEP/assembly.step`。

## 几何与接口

| 文件 | 结果 |
|---|---|
| `shell_checks.json` | PASS：拓扑、键床/上盖/开关净空、ToF、线缆口、定位柱 |
| `fit_sample_checks.py` -> `fit_sample_checks.json` | PASS：13 键、键帽、导柱、ToF、打印样件 |
| `actual_pcb_checks.json` | PASS：实际 PCB、CN2、IDC、H1–H14 朝下包络 |
| `gerber_alignment_checks.json` | PASS：10 月 27 日 Gerber 的板框、孔、开关与连接器坐标 |
| STEP ACL | `publish-access.ps1` 非提升权限执行成功；目录与文件 `icacls` 均列出 `Authenticated Users:(RX/R)` |

关键阈值：

- 开关与键床最小净距：0.15 mm。
- 键帽到上盖开口：0.975 mm。
- 键床左右压边：0.5 mm/侧。
- 定位凸台到键帽：0.625 mm。
- 定位柱实际插入：0.876 mm；孔底余量：0.374 mm；键床/上盖求交：0 mm³。
- H2/H3/H4/H14 本体最近间隙：均为 0.400 mm；引脚最小间隙分别为
  0.992/0.541/1.030/0.332 mm。
- H5 不设键床通窗；安装键床前，必须把其朝上残留引脚剪平至 PCB 顶面或更低。
- H2/H3/H4/H14 本体和引脚包络对下壳：0 mm³。
- ToF 轴线误差：0°。
- IDC 对下壳贯通过口、对上盖干涉：分别 PASS、0 mm³。

## DfAM 原始数据

测量条件：PETG、0.2 mm 层高、45° 自支撑阈值。

| 文件 | 主要结果 |
|---|---|
| `top_shell_dfam.json` | 1 实体、水密；p05=2.00，悬垂面积约 35.0% |
| `top_shell_orientations.json` | 顶面朝下 34.8%；侧立约 3.8%，构建高 140 |
| `bottom_shell_dfam.json` | 1 实体、水密；p05=1.70，悬垂约 1.3% |
| `bottom_shell_orientations.json` | 当前开口向上姿态最优 |
| `keybed_dfam.json` | 键床+13 键帽，14 个独立实体；整体 p05=1.678 |
| `keybed_orientations.json` | 分件/装配说明用；实际按键床和键帽分别排盘 |
| `keybed_plate_dfam.json` | 键床板单独水密；p05=1.20，最小采样 0.90 |
| `keybed_plate_orientations.json` | PCB 接触面朝下时构建高 5.4，悬垂约 3.8% |
| `artifact_manifest.json` | 本轮 STEP/STL/3MF 与 assembly 的时间戳、大小和 SHA-256 |
| `step_metrics.json` | 三个 STEP 的精确包络和体积 |
| `mesh_consistency_checks.json` | STEP、STL、3MF 的 triangle、包络和体积一致性 |
| `acl_verification.txt` | STEP 目录及关键文件的 `icacls` 回读结果 |
| `../../exports/jlc_2026-10-28/keybed_parts.json` | 键床板和 13 键帽的独立 STL 拆分检查 |
| `../../exports/jlc_2026-10-28/shell_parts.json` | 上下壳单实体 STL 的闭合、绕序和开放边检查 |

## 复现命令

在 `fpga_hardware/enclosure` 下运行：

```powershell
uvx --offline --no-config --managed-python --python 3.13 --from cadgen==0.7.21 python src/bottom_shell.py --force
uvx --offline --no-config --managed-python --python 3.13 --from cadgen==0.7.21 python src/top_shell.py --force
uvx --offline --no-config --managed-python --python 3.13 --from cadgen==0.7.21 python src/keybed.py --force
uvx --offline --no-config --managed-python --python 3.13 --from cadgen==0.7.21 python src/assembly.py --force

$env:PYTHONPATH = (Resolve-Path -LiteralPath 'src').Path
uvx --offline --no-config --managed-python --python 3.13 --from cadgen==0.7.21 python checks/shell_checks.py
uvx --offline --no-config --managed-python --python 3.13 --from cadgen==0.7.21 python checks/fit_sample_checks.py
uvx --offline --no-config --managed-python --python 3.13 --from cadgen==0.7.21 python checks/actual_pcb_checks.py
uvx --offline --no-config --managed-python --python 3.13 --from cadgen==0.7.21 python checks/gerber_alignment_checks.py
uvx --offline --no-config --managed-python --python 3.13 --from cadgen==0.7.21 python tmp/export_step_metrics.py
.\.venv\Scripts\python.exe checks/mesh_consistency_checks.py
uvx --offline --no-config --managed-python --python 3.13 --from cadgen==0.7.21 python checks/export_keybed_parts_source.py
.\.venv\Scripts\python.exe checks/export_jlc_keybed_parts.py
.\publish-access.ps1
```

## 尚需切片/实物确认

- DfAM 工具不直接测量最小孔径、无支撑桥长或局部支撑必要性。
- 44 mm 和 36 mm 前侧窗口上缘的桥接必须在切片中检查。
- 键床板 p05=1.20 正好等于保守 FDM 支撑壁下限；实际打印需检查层间结合和翘曲。
- 键床定位柱只限制水平位移，垂直上跳需要首件验证。
