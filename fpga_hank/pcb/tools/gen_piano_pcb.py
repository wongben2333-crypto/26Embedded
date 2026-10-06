# -*- coding: utf-8 -*-
"""Generate the 6-key capacitive-touch piano PCB as an LCEDA-Pro project.

Board: 6 white keys (C D E F G A) = 6 touch channels on ONE PMOD1 connector
(pins 5..10 -> AA19 AB20 AA20 AA21 AB21 AB22 -- all MEASURED usable on version C),
plus 5 cosmetic black keys (silkscreen only, no copper, no circuit).

Key design rules baked in:
  * 1 MOhm pull-up to 3.3 V + 100R..1k series protection per key
  * touch pads sit in the FRONT part of the white keys (y = 8..52 mm) where no
    black key exists, so the black keys cannot couple into them at all
  * ground keep-out: no copper pour within 2 mm under the pads
  * silkscreen carries note names AND the PMOD pin -> FPGA ball mapping
  * test points on every channel

⚠️ FORMAT SWITCH: FORMAT = "v2" emits the legacy array-based layout (the one the
user's own archive uses, and the one our first minimal project used). FORMAT = "v3"
emits the official key-value log records.  The user's import result is still
unknown, so the switch exists so a failure costs one parameter change, not a
rewrite.  See _research/pcb/LCEDA-FORMAT.md.

⚠️ Units: LCEDA **v2 geometry is in MIL** (39.3701 mil = 1 mm).  This is measured,
not assumed -- see LCEDA-FORMAT.md section 2.

Usage:  python gen_piano_pcb.py <out_dir> [v2|v3]
"""

import base64
import io
import json
import os
import sys
import zipfile

MIL = 39.3701


def mm2mil(v):
    return round(v * MIL, 4)


# ----------------------------------------------------------------- geometry ---
W = 23.5                 # white key width (mm)
LW = 150.0               # white key length (mm)
BW = 13.7                # black key width
LB = 95.0                # black key length
# ★ 渲染回读时发现的几何问题：只画 6 个白键（C..A）时，A# 黑键落在 k=6 → x=141，
#   正好压在板子右边缘（因为 A# 属于 A-B 交界，而 B 不存在）。
#   ⇒ 解法：画【7 个白键 C D E F G A B】，其中 **6 个做触摸通道（C..A）**、
#     **B 只做外观**（有键形、有丝印、无 PAD、不接电）。
#   好处：黑键恢复成【2+3】、板宽正好 7×23.5 = 164.5mm = **一个八度**、更像钢琴。
N_WHITE = 7                      # 画出来的白键数
N_KEYS = 6                       # 真正的触摸通道数
NOTES = ["C", "D", "E", "F", "G", "A", "B"]
BLACK = [("C#", 1), ("D#", 2), ("F#", 4), ("G#", 5), ("A#", 6)]

BOARD_W = N_WHITE * W    # 164.5 = 一个八度
BACK = 22.0
BOARD_H = LW + BACK      # 172.0

PAD_Y0, PAD_Y1 = 8.0, 52.0
PAD_W = 19.0

# 通道 → (PMOD1 物理针, 网络名, FPGA 球号)   —— 全部实测可用
CH = [
    ("C", 5,  "PMOD1_IO6", "AA19"),
    ("D", 6,  "PMOD1_IO7", "AB20"),
    ("E", 7,  "PMOD1_IO4", "AA20"),
    ("F", 8,  "PMOD1_IO5", "AA21"),
    ("G", 9,  "PMOD1_IO2", "AB21"),
    ("A", 10, "PMOD1_IO3", "AB22"),
]

HDR_PITCH = 2.54
HDR_CX = BOARD_W / 2.0
HDR_CY = LW + 11.0

PULLUP = "1M"
SERIES = "470R"

# ------------------------------------------------------------------- helpers --
LAYERS = [
    ["LAYER", 1, "TOP", "Top Layer", 3, "#ff0000", 1, "#ff0000", 1],
    ["LAYER", 2, "BOTTOM", "Bottom Layer", 3, "#0000ff", 1, "#0000ff", 1],
    ["LAYER", 3, "TOP_SILK", "Top Silkscreen Layer", 3, "#ffcc00", 1, "#ffcc00", 1],
    ["LAYER", 4, "BOT_SILK", "Bottom Silkscreen Layer", 3, "#66cc33", 1, "#66cc33", 1],
    ["LAYER", 5, "TOP_SOLDER_MASK", "Top Solder Mask Layer", 3, "#800080", 0.7, "#800080", 1],
    ["LAYER", 6, "BOT_SOLDER_MASK", "Bottom Solder Mask Layer", 3, "#aa00ff", 0.7, "#aa00ff", 1],
    ["LAYER", 7, "TOP_PASTE_MASK", "Top Paste Mask Layer", 3, "#808080", 1, "#808080", 1],
    ["LAYER", 8, "BOT_PASTE_MASK", "Bottom Paste Mask Layer", 3, "#800000", 1, "#800000", 1],
    ["LAYER", 9, "TOP_ASSEMBLY", "Top Assembly Layer", 3, "#33cc99", 1, "#33cc99", 1],
    ["LAYER", 10, "BOT_ASSEMBLY", "Bottom Assembly Layer", 3, "#5555ff", 1, "#5555ff", 1],
    ["LAYER", 11, "OUTLINE", "Board Outline Layer", 3, "#ff00ff", 1, "#ff00ff", 1],
]
PREFERENCE = ["PREFERENCE", 1, 10, 1, 12.0078, 24.0158, 1, 3, "L45", 1, 0, 0, 1]
SILK_OPTS = ["SILK_OPTS", 3, "#000000", "#FFFFFF"]
POUR_CLEAR = 0.2          # mm


class Ids:
    def __init__(self):
        self.n = 0

    def __call__(self):
        self.n += 1
        return "e%d" % self.n


def pad_row(x_mm, y_mm, w_mm, h_mm, num="1", layer=1, net=""):
    """LCEDA v2 PAD record (25 fields, order copied from a real footprint)."""
    return ["PAD", "", 0, net, layer, num, mm2mil(x_mm), mm2mil(y_mm), 0, None,
            ["RECT", mm2mil(w_mm), mm2mil(h_mm), 0], [], 0, 0, 0, 1, 0, 2, 2,
            -3937.008, -3937.008, 0, None, None, None, None]


# ---------------------------------------------------------------- footprints --
def fp_touchpad(w_mm, h_mm, name):
    nx = Ids()
    rows = [["DOCTYPE", "FOOTPRINT", "1.7"],
            ["CANVAS", 0, 0, "mil", 5, 5, 5, 5, 0.5, 0.5, 2]]
    rows += LAYERS
    rows += [["ACTIVE_LAYER", 1], PREFERENCE, SILK_OPTS]
    pad = pad_row(0, 0, w_mm, h_mm, "1")
    pad[1] = nx()
    rows.append(pad)
    s = ["STRING", nx(), 0, 3, mm2mil(-w_mm / 2), mm2mil(-h_mm / 2) - 40,
         name, "default", 40, 8, 0, 0, 3, 0, 0, 0, 0, 0]
    rows.append(s)
    rows.append(["ATTR", nx(), 0, "", 3, None, None, "Footprint", name,
                 0, 0, "default", 45, 6, 0, 0, 3, 0, 0, 0, 0, 0])
    return rows


def fp_chip2(name, pitch_mm=1.0, pad_mm=(0.9, 0.95)):
    """Two-terminal SMD (0603-ish)."""
    nx = Ids()
    rows = [["DOCTYPE", "FOOTPRINT", "1.7"],
            ["CANVAS", 0, 0, "mil", 5, 5, 5, 5, 0.5, 0.5, 2]]
    rows += LAYERS
    rows += [["ACTIVE_LAYER", 1], PREFERENCE, SILK_OPTS]
    for i, sx in enumerate((-1, 1)):
        p = pad_row(sx * pitch_mm / 2.0, 0, pad_mm[0], pad_mm[1], str(i + 1))
        p[1] = nx()
        rows.append(p)
    rows.append(["POLY", nx(), 0, "", 3, 6,
                 [mm2mil(-0.8), mm2mil(0.5), "L", mm2mil(0.8), mm2mil(0.5)], 0])
    rows.append(["ATTR", nx(), 0, "", 3, None, None, "Footprint", name,
                 0, 0, "default", 45, 6, 0, 0, 3, 0, 0, 0, 0, 0])
    return rows


def fp_hdr2x6(name):
    """2x6 2.54 mm through-hole header; pad = round 1.7 mm, drill 1.0 mm."""
    nx = Ids()
    rows = [["DOCTYPE", "FOOTPRINT", "1.7"],
            ["CANVAS", 0, 0, "mil", 5, 5, 5, 5, 0.5, 0.5, 2]]
    rows += LAYERS
    rows += [["ACTIVE_LAYER", 1], PREFERENCE, SILK_OPTS]
    # 物理针号排布与我们配出的 PMOD1 一致：11,12 / 9,10 / 7,8 / 5,6 / 3,4 / 1,2
    numbering = [(11, 12), (9, 10), (7, 8), (5, 6), (3, 4), (1, 2)]
    for r, (nl, nr) in enumerate(numbering):
        for c, num in enumerate((nl, nr)):
            p = pad_row((c - 0.5) * HDR_PITCH, -(r - 2.5) * HDR_PITCH,
                        1.7, 1.7, str(num))
            p[1] = nx()
            p[9] = [1.0 * MIL / MIL * 39.3701]      # hole ref (示意)
            rows.append(p)
    rows.append(["ATTR", nx(), 0, "", 3, None, None, "Footprint", name,
                 0, 0, "default", 45, 6, 0, 0, 3, 0, 0, 0, 0, 0])
    return rows


def fp_testpoint(name):
    nx = Ids()
    rows = [["DOCTYPE", "FOOTPRINT", "1.7"],
            ["CANVAS", 0, 0, "mil", 5, 5, 5, 5, 0.5, 0.5, 2]]
    rows += LAYERS
    rows += [["ACTIVE_LAYER", 1], PREFERENCE, SILK_OPTS]
    p = pad_row(0, 0, 1.5, 1.5, "1")
    p[1] = nx()
    rows.append(p)
    rows.append(["ATTR", nx(), 0, "", 3, None, None, "Footprint", name,
                 0, 0, "default", 45, 6, 0, 0, 3, 0, 0, 0, 0, 0])
    return rows


# ----------------------------------------------------------------------- PCB --
def build_pcb(fp_uuids):
    nx = Ids()
    rows = [["DOCTYPE", "PCB", "1.7"],
            ["CANVAS", 0, 0, "mm", 5, 5, 5, 5, 5, 5, 1]]
    rows += LAYERS
    rows += [["ACTIVE_LAYER", 1], PREFERENCE, SILK_OPTS]

    # --- 板框 ---
    rows.append(["POLY", nx(), 0, "", 11, 10,
                 ["R", 0, 0, mm2mil(BOARD_W), mm2mil(BOARD_H), 0, mm2mil(3.0)], 0])

    # --- 网络 ---
    nets = ["GND", "+3V3"] + [c[2] for c in CH]
    for n in nets:
        rows.append(["NET", n, None, None, 1, None, 0, None])

    # --- 元件实例：触摸 PAD ×6 ---
    comps = []
    for i, (note, pin, net, ball) in enumerate(CH):
        x = i * W
        cx = x + W / 2.0
        comps.append(dict(fp=fp_uuids["touch"]["fp"], x=cx, y=(PAD_Y0 + PAD_Y1) / 2.0,
                          rot=0, ref="PAD_%s" % note, net=net))
    # --- 串联电阻 + 上拉电阻 ×6 ---
    for i, (note, pin, net, ball) in enumerate(CH):
        cx = i * W + W / 2.0
        comps.append(dict(fp=fp_uuids["r"]["fp"], x=cx, y=LW + 4.2, rot=0,
                          ref="RS_%s" % note, net=net))
        comps.append(dict(fp=fp_uuids["r"]["fp"], x=cx, y=LW + 7.4, rot=0,
                          ref="RP_%s" % note, net="+3V3"))
    # --- 测试点 ×6 ---
    for i, (note, pin, net, ball) in enumerate(CH):
        comps.append(dict(fp=fp_uuids["tp"]["fp"], x=i * W + W / 2.0 + 6.0,
                          y=LW + 4.6, rot=0, ref="TP_%s" % note, net=net))
    # --- 排针 ---
    comps.append(dict(fp=fp_uuids["hdr"]["fp"], x=HDR_CX, y=HDR_CY, rot=0,
                      ref="J1", net=""))

    for c in comps:
        cid = nx()
        c["id"] = cid
        rows.append(["COMPONENT", cid, 0, 1, mm2mil(c["x"]), mm2mil(-c["y"]),
                     c["rot"], {"Unique ID": c["ref"], "CBB Title": ""}, 0])
        rows.append(["ATTR", nx(), 0, cid, 3, None, None, "Footprint",
                     c["fp"], 0, 0, "default", 45, 6, 0, 0, 3,
                     mm2mil(c["x"]), mm2mil(-c["y"]), 0, 0, 0])
        rows.append(["REUSE_BLOCK", cid, "", "$1%s" % cid])

    # --- 走线（TOP）---
    def track(x1, y1, x2, y2, net, wmil=20, layer=1):
        rows.append(["LINE", nx(), 0, net, layer,
                     mm2mil(x1), mm2mil(-y1), mm2mil(x2), mm2mil(-y2), wmil, 0])

    for i, (note, pin, net, ball) in enumerate(CH):
        cx = i * W + W / 2.0
        # PAD 顶部 -> 串联电阻 -> 排针
        track(cx, PAD_Y0, cx, LW + 3.4, net)
        hx = HDR_CX + (0.5 if (pin % 2 == 0) else -0.5) * HDR_PITCH
        hy = HDR_CY + (2.5 - (11 - pin) // 2) * HDR_PITCH
        track(cx, LW + 5.0, hx, hy, net, 20)
        # 上拉：+3V3
        track(cx, LW + 8.2, hx, hy, "+3V3", 15)
        # 测试点
        track(cx + 1.0, LW + 4.6, cx + 5.2, LW + 4.6, net, 12)

    # --- 丝印：音名 + 通道标注 + 排针对照 ---
    # ★ 循环必须是 N_WHITE(7)，不是 6：第 7 个键(B) 只做外观也要画轮廓与音名。
    #   第一版这里跟着 CH(6) 循环，结果 B 键**没有键形** —— 渲染回读时一眼看出。
    #   而黑键的 A# 挂在 A-B 交界，没有 B 键它就会掉到板子右边缘外，
    #   所以「画 7 个键、只用 6 个」不是可选美化，而是**几何上必须**。
    for i in range(N_WHITE):
        x = i * W
        cx = x + W / 2.0
        is_touch = (i < N_KEYS)
        rows.append(["STRING", nx(), 0, 3, mm2mil(cx), mm2mil(-3.0), NOTES[i],
                     "default", 90, 8, 0, 0, 3, 0, 0, 0, 0, 0])
        if is_touch:
            note, pin, net, ball = CH[i]
            rows.append(["STRING", nx(), 0, 3, mm2mil(cx), mm2mil(-57.0),
                         "%s\npin%d\n%s" % (note, pin, ball),
                         "default", 32, 8, 0, 0, 3, 0, 0, 0, 0, 0])
        else:
            rows.append(["STRING", nx(), 0, 3, mm2mil(cx), mm2mil(-57.0),
                         "%s\n外观件\n不接电" % NOTES[i],
                         "default", 32, 8, 0, 0, 3, 0, 0, 0, 0, 0])
        # 白键轮廓（开缺口，与用户认可的变体 B 一致）
        yb = LW - LB
        half = BW / 2.0
        left_blk = any(k == i for _, k in BLACK)
        right_blk = any(k == i + 1 for _, k in BLACK)
        pts = [x, 0, x + W, 0]
        if right_blk:
            pts += [x + W, yb, x + W - half, yb, x + W - half, LW]
        else:
            pts += [x + W, LW]
        if left_blk:
            pts += [x + half, LW, x + half, yb, x, yb]
        else:
            pts += [x, LW]
        flat = []
        for j in range(0, len(pts), 2):
            flat += [mm2mil(pts[j]), mm2mil(-pts[j + 1])]
        flat.append("L")
        flat.append(flat[0])
        flat.append(flat[1])
        rows.append(["POLY", nx(), 0, "", 3, 6, flat, 0])

    # --- 丝印：黑键（外观件）---
    for name, k in BLACK:
        cx = k * W
        rows.append(["POLY", nx(), 0, "", 3, 6,
                     [mm2mil(cx - BW / 2), mm2mil(-(LW - LB)), "L",
                      mm2mil(cx + BW / 2), mm2mil(-(LW - LB)), "L",
                      mm2mil(cx + BW / 2), mm2mil(-LW), "L",
                      mm2mil(cx - BW / 2), mm2mil(-LW), "L",
                      mm2mil(cx - BW / 2), mm2mil(-(LW - LB))], 0])
        rows.append(["STRING", nx(), 0, 3, mm2mil(cx), mm2mil(-(LW - LB) - 6.0),
                     name, "default", 45, 8, 0, 0, 3, 0, 0, 0, 0, 0])
        # 黑键做成【丝印实心填充】，纯外观件、不接电 —— 用户要的是"一眼看出是钢琴"
        rows.append(["FILL", nx(), 0, "", 3, 0.2, 0,
                     [[mm2mil(cx - BW / 2), mm2mil(-(LW - LB)), "L",
                       mm2mil(cx + BW / 2), mm2mil(-(LW - LB)), "L",
                       mm2mil(cx + BW / 2), mm2mil(-LW), "L",
                       mm2mil(cx - BW / 2), mm2mil(-LW), "L",
                       mm2mil(cx - BW / 2), mm2mil(-(LW - LB))]], 0])

    # --- 丝印：标题栏 ---
    rows.append(["STRING", nx(), 0, 3, mm2mil(4.0), mm2mil(-(LW + 18.0)),
                 "TOUCH PIANO 6KEY  %s\n1M pull-up + %s series  NO GND under pads"
                 % (PULLUP, SERIES), "default", 45, 8, 0, 0, 3, 0, 0, 0, 0, 0])
    rows.append(["STRING", nx(), 0, 3, mm2mil(4.0), mm2mil(-(LW + 14.5)),
                 "J1 = PMOD1 : 5=AA19 6=AB20 7=AA20 8=AA21 9=AB21 10=AB22  |  1,2=+3V3  3,4=GND",
                 "default", 40, 8, 0, 0, 3, 0, 0, 0, 0, 0])

    # --- 铺铜（GND 铺在排针后方，避开 PAD 正下方 2mm）---
    rows.append(["POUR", nx(), 0, "GND", 1, POUR_CLEAR, "POUR1", 0,
                 [["R", mm2mil(3.0), mm2mil(-(LW + 0.5)),
                   mm2mil(BOARD_W - 6.0), mm2mil(BACK - 3.0), 0, 0]],
                 ["SOLID", 6], 0, 0])
    rows.append(["POUR", nx(), 0, "GND", 2, POUR_CLEAR, "POUR2", 1,
                 [["R", mm2mil(-0.5), mm2mil(-(PAD_Y1 + 4.0)),
                   mm2mil(BOARD_W + 1.0), mm2mil(LW - (PAD_Y1 + 4.0)), 0, 0]],
                 ["SOLID", 6], 0, 0])
    return rows


# --------------------------------------------------------------- project.json -
def project_json(uuids, title):
    # ⚠️ uuids 里 "pcb" 是字符串、"sch" 是嵌套 dict —— 只有 footprint 那几项是
    #    {fp,sym,dev} 三元组。第一版直接 items() 遍历，撞上字符串索引报 TypeError。
    fp_keys = [k for k in uuids if isinstance(uuids[k], dict) and "fp" in uuids[k]]
    sym, dev = {}, {}
    for key in fp_keys:
        u = uuids[key]
        name = "FP_" + key.upper()
        sym[u["sym"]] = {"source": "", "desc": "", "tags": {"parent_tag": [], "child_tag": []},
                         "custom_tags": "[\"\"]", "title": name, "version": "1", "type": 2}
        dev[u["dev"]] = {"title": name, "attributes": {"Symbol": u["sym"],
                                                       "Footprint": u["fp"], "Device": name},
                         "description": "", "tags": {"parent_tag": [], "child_tag": []},
                         "custom_tags": "[\"\"]"}
    return {
        "schematics": {uuids["sch"]["sch"]: {"name": "Schematic1",
                                             "sheets": [{"name": "P1", "id": 1,
                                                         "uuid": uuids["sch"]["sheet"]}]}},
        "pcbs": {uuids["pcb"]: "PCB1"},
        "panels": {},
        "symbols": sym,
        "footprints": {uuids[k]["fp"]: {"title": "FP_" + k.upper(), "source": "",
                                        "version": "1", "type": 4, "desc": "",
                                        "tags": {"parent_tag": [], "child_tag": []},
                                        "custom_tags": "[\"\"]"} for k in fp_keys},
        "devices": dev,
        "boards": {"Board1": {"schematic": uuids["sch"]["sch"], "pcb": uuids["pcb"]}},
        "config": {"title": title},
    }


# ------------------------------------------------------------------ emission --
def jline(o):
    return json.dumps(o, ensure_ascii=False, separators=(",", ":"))


def write_lines(path, rows):
    with io.open(path, "w", encoding="utf-8", newline="\n") as fh:
        for r in rows:
            fh.write(jline(r) + "\n")


def new_uuids():
    """Deterministic uuids (32 hex) so regenerating gives identical bytes."""
    def u(tag):
        h = tag.encode().hex()
        return (h + "0" * 32)[:32]
    d = {}
    for k in ("touch", "r", "hdr", "tp"):
        d[k] = {"fp": u("fp" + k), "sym": u("sy" + k), "dev": u("dv" + k)}
    d["pcb"] = u("pcb")
    d["sch"] = {"sch": u("sch"), "sheet": u("sht")}
    return d


def emit(out_root, fmt="v2"):
    if fmt != "v2":
        raise NotImplementedError(
            "V3 emitter not written yet -- see _research/pcb/LCEDA-FORMAT.md. "
            "The switch exists so a failed import costs one parameter, not a rewrite.")
    uuids = new_uuids()
    root = out_root
    for sub in ("PCB", "SHEET", "SYMBOL", "FOOTPRINT", "POUR", "BLOB", "FONT",
                "INSTANCE", "PANEL"):
        os.makedirs(os.path.join(root, sub), exist_ok=True)
    os.makedirs(os.path.join(root, "SHEET", uuids["sch"]["sheet"]), exist_ok=True)

    write_lines(os.path.join(root, "PCB", uuids["pcb"] + ".epcb"), build_pcb(uuids))

    fps = {
        "touch": fp_touchpad(PAD_W, PAD_Y1 - PAD_Y0, "TOUCHPAD"),
        "r": fp_chip2("R0603"),
        "hdr": fp_hdr2x6("PMOD_2X6"),
        "tp": fp_testpoint("TP1.5"),
    }
    for k, rows in fps.items():
        write_lines(os.path.join(root, "FOOTPRINT", uuids[k]["fp"] + ".efoo"), rows)
        write_lines(os.path.join(root, "SYMBOL", uuids[k]["sym"] + ".esym"),
                    [["DOCTYPE", "SYMBOL", "1.7"],
                     ["CANVAS", 0, 0, "mil", 5, 5, 5, 5, 0.5, 0.5, 2]])

    write_lines(os.path.join(root, "SHEET", uuids["sch"]["sheet"], "1.esch"),
                [["DOCTYPE", "SCH", "1.1"],
                 ["HEAD", {"originX": 0, "originY": 0, "version": "2.0.16", "maxId": 10}],
                 ["FONTSTYLE", "st1", None, None, None, 20, None, None, None, None, 1, 1],
                 ["COMPONENT", "e1", "", 0, 0, 0, 0, {}, 0]])

    # POUR 文件名 = base64("<pcb_uuid>_0")  —— 实测规则
    pour_name = base64.b64encode((uuids["pcb"] + "_0").encode()).decode()
    with io.open(os.path.join(root, "POUR", pour_name + ".ecop"), "w",
                 encoding="utf-8", newline="\n") as fh:
        fh.write(jline(["DOCTYPE", "POURED", "1.1"]) + "\n")

    with io.open(os.path.join(root, "project.json"), "w", encoding="utf-8", newline="\n") as fh:
        json.dump(project_json(uuids, "TouchPiano6"), fh, ensure_ascii=False, indent=1)
    with io.open(os.path.join(root, "meta.json"), "w", encoding="utf-8", newline="\n") as fh:
        json.dump({"name": "Generated", "description": "6-key touch piano PCB",
                   "projectName": "TouchPiano6",
                   "owner": {"uuid": "0" * 32, "username": None, "nickname": None,
                             "avatar": None},
                   "members": [{"uuid": "0" * 32, "username": "", "nickname": "",
                                "avatar": ""}],
                   "backupTime": "2026-10-06 00:00:00"}, fh, ensure_ascii=False, indent=1)
    return uuids


# ------------------------------------------------------------------- packaging -
def zip_project(root, zip_path):
    """ZIP with FORWARD SLASH entry names.

    ⚠️ .NET's CreateFromDirectory writes 'PCB\\xxx.epcb' on Windows, but the ZIP
    spec requires '/'. The Lead hit exactly this bug. So we write every entry by
    hand -- and we assert afterwards that no backslash survived.
    """
    files = []
    for dp, _dn, fn in os.walk(root):
        for f in fn:
            p = os.path.join(dp, f)
            rel = os.path.relpath(p, root).replace("\\", "/")
            files.append((p, rel))
    files.sort(key=lambda t: t[1])
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
        for p, rel in files:
            assert "\\" not in rel, rel
            z.write(p, rel)
    return files


def selfcheck(root, zip_path):
    ok = True
    print("=" * 74)
    print("SELF-CHECK", root)

    n = bad = 0
    for dp, _dn, fn in os.walk(root):
        for f in fn:
            if f.lower().endswith((".epcb", ".efoo", ".esym", ".esch")):
                for i, raw in enumerate(io.open(os.path.join(dp, f), encoding="utf-8"), 1):
                    s = raw.strip()
                    if not s:
                        continue
                    n += 1
                    try:
                        a = json.loads(s)
                        assert isinstance(a, list) and a
                    except Exception as e:
                        bad += 1
                        print("   [1] FAIL %s:%d %s" % (f, i, e))
    print("   [1] %d records parse as JSON arrays, %d bad -> %s"
          % (n, bad, "PASS" if bad == 0 else "FAIL"))
    ok &= (bad == 0)

    # 板框尺寸反算
    pcb = [json.loads(l) for l in io.open(
        os.path.join(root, "PCB", os.listdir(os.path.join(root, "PCB"))[0]),
        encoding="utf-8") if l.strip()]
    sizes = [(r[6][3] / MIL, r[6][4] / MIL) for r in pcb if r[0] == "POLY" and r[4] == 11]
    got = sizes[0] if sizes else (0, 0)
    # 容差 1e-3 mm：mil 只存 4 位小数，往返会有 ~1e-6mm 误差。
    # （BOARD_W=141.0 恰好整除所以没暴露；改成 164.5 后暴露了 —— 自检起了作用。）
    good = abs(got[0] - BOARD_W) < 1e-3 and abs(got[1] - BOARD_H) < 1e-3
    print("   [2] board from raw coords %.4f x %.4f mm (intended %.1f x %.1f) -> %s"
          % (got[0], got[1], BOARD_W, BOARD_H, "PASS" if good else "FAIL"))
    ok &= good

    # project.json -> files
    pj = json.load(io.open(os.path.join(root, "project.json"), encoding="utf-8"))
    miss = []
    for u in pj["pcbs"]:
        if not os.path.exists(os.path.join(root, "PCB", u + ".epcb")):
            miss.append("PCB/" + u)
    for u in pj["footprints"]:
        if not os.path.exists(os.path.join(root, "FOOTPRINT", u + ".efoo")):
            miss.append("FOOTPRINT/" + u)
    for u in pj["symbols"]:
        if not os.path.exists(os.path.join(root, "SYMBOL", u + ".esym")):
            miss.append("SYMBOL/" + u)
    for sc in pj["schematics"].values():
        for sh in sc["sheets"]:
            if not os.path.exists(os.path.join(root, "SHEET", sh["uuid"], "1.esch")):
                miss.append("SHEET/" + sh["uuid"])
    print("   [3] project.json -> files: %s%s" % ("PASS" if not miss else "FAIL ", miss))
    ok &= (not miss)

    # ZIP 条目名必须是正斜杠
    with zipfile.ZipFile(zip_path) as z:
        names = z.namelist()
    bs = [x for x in names if "\\" in x]
    print("   [4] zip entries=%d, with backslash=%d -> %s"
          % (len(names), len(bs), "PASS" if not bs else "FAIL"))
    ok &= (not bs)

    print("   => %s" % ("ALL CHECKS PASS" if ok else "SOME CHECKS FAILED"))
    return ok


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else \
        r"C:\Users\Danny\Desktop\FPGA competition\fpga_hank\pcb\piano6"
    fmt = sys.argv[2] if len(sys.argv) > 2 else "v2"
    prj = os.path.join(out, "TouchPiano6")
    emit(prj, fmt)
    zp = os.path.join(out, "TouchPiano6.zip")
    files = zip_project(prj, zp)
    print("emitted %d files, zip %d bytes" % (len(files), os.path.getsize(zp)))
    good = selfcheck(prj, zp)
    print()
    print("board %.1f x %.1f mm, %d channels:" % (BOARD_W, BOARD_H, N_KEYS))
    for note, pin, net, ball in CH:
        print("   %s -> PMOD1 pin%-3d %-11s %s" % (note, pin, net, ball))
    return 0 if good else 1


if __name__ == "__main__":
    sys.exit(main())

