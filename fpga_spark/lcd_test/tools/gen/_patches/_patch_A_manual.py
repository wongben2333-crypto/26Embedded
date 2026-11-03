# -*- coding: utf-8 -*-
"""A 路线手工补丁（Lead 亲自做）—— 精确字符串替换，任一失败则不动任何文件。

改 gen_piano_rom.py 的 6 处：
  1) 新增 BAND_MUL(5 档) + N_BAND
  2) inst_amp_table(inst, band=0)
  3) 二胡分支乘 BAND_MUL[band]
  4) 模块端口加 input wire [2:0] band,
  5) case ({inst, n}) -> case ({inst, band, n})
  6) 发射循环：档循环 + 8bit 索引 (inst<<6)|(band<<3)|i
"""
import io, os, sys, hashlib

HERE = os.path.dirname(os.path.abspath(__file__))
GEN = os.path.join(HERE, 'gen_piano_rom.py')
RTL = os.path.normpath(os.path.join(HERE, '..', '..', 'rtl', 'synth', 'piano_engine.v'))

def fp(p):
    with open(p, 'rb') as f:
        return hashlib.sha256(f.read()).hexdigest()[:16].upper()

_EOL = {}

def read(p):
    with io.open(p, 'r', encoding='utf-8', newline='') as f:
        raw = f.read()
    _EOL[p] = '\r\n' if '\r\n' in raw else '\n'
    return raw.replace('\r\n', '\n')

def write(p, s):
    eol = _EOL.get(p, '\n')
    out = s.replace('\n', eol) if eol != '\n' else s
    with io.open(p, 'w', encoding='utf-8', newline='') as f:
        f.write(out)

def rep(t, old, new, tag, fail):
    n = t.count(old)
    if n != 1:
        fail.append('%s : found %d (want 1)' % (tag, n))
        return t
    return t.replace(old, new)

gen = read(GEN)
rtl = read(RTL)
g0, r0 = gen, rtl
fail = []

# ---- 1) BAND_MUL 表（插在 KSH_OFS_ENC 行之后）----
anchor1 = "KSH_OFS_ENC = {-1: 0, 0: 1, 1: 2}\n"
band_tbl = anchor1 + """
# ============================================================================
#  ★ A 路线（2026-10-06）：二胡 5 档谐波倍数（相对增益）
#    由实测琴体曲线在 n*f0 处的增益算出，已按各档 6 泛音【均值归零】、
#    再整体除以 1.068（不改该档总电平）。
#    验证（对照专业《赛马》实测）：D4 -> H2 主导(+4.8dB)、A4 -> H1 最强(-1.9)、
#                                  D5 -> H1 主导(-4.4)  ✓ 三个目标全中
#    含高频滚降：5kHz -9.1dB / 8kHz -15.1dB / 12kHz -22.3dB
#    ⚠️ 档 0 对【低于 D4】的音是【外推，无实测支撑】。
# ============================================================================
BAND_MUL = [
    (0.858, 1.486, 0.936, 0.892, 0.984, 0.955),   # band0  D4  293.7 Hz
    (1.026, 1.274, 0.985, 1.055, 1.072, 0.687),   # band1  F4  349.2 Hz
    (1.479, 1.185, 1.169, 1.210, 0.690, 0.585),   # band2  A4  440.0 Hz
    (2.043, 1.206, 1.381, 0.844, 0.624, 0.558),   # band3  C5  523.2 Hz
    (2.213, 1.327, 1.422, 0.715, 0.679, 0.493),   # band4  D5  587.3 Hz
]
N_BAND = len(BAND_MUL)
"""
gen = rep(gen, anchor1, band_tbl, '1 BAND_MUL', fail)

# ---- 2) inst_amp_table 签名 ----
gen = rep(gen, "def inst_amp_table(inst: int):",
               "def inst_amp_table(inst: int, band: int = 0):",
               '2 signature', fail)

# ---- 3) 二胡分支乘 BAND_MUL ----
old3 = '        raw = [float(v) for v in cfg["amp_lin"]]\n'
new3 = ('        raw = [float(v) for v in cfg["amp_lin"]]\n'
        '        # ★ A 路线：形状改由 BAND_MUL[band] 决定（RMS 归一在后面统一做）\n'
        '        _bm = BAND_MUL[band] if (0 <= band < N_BAND) else BAND_MUL[0]\n'
        '        raw = [raw[_i] * _bm[_i] for _i in range(len(raw))]\n')
gen = rep(gen, old3, new3, '3 band mul', fail)

# ---- 4) 模块端口 ----
gen = rep(gen, "    input  wire [2:0]  n,\n",
               "    input  wire [2:0]  n,\n    input  wire [2:0]  band,\n",
               '4 band port', fail)

# ---- 5) case 索引 ----
gen = rep(gen, "        case ({inst, n})\n",
               "        case ({inst, band, n})\n",
               '5 case idx', fail)

# ---- 6) 发射循环 ----
old6 = """    for k_inst in range(len(INSTRUMENTS)):
        cfg = INSTRUMENTS[k_inst]
        amps = inst_amp_table(k_inst)
        ks   = inst_k_table(k_inst)
        for i in range(N_PART):
            st1, st2 = inharm_shifts(i + 1, cfg["B"])
            plines.append("            5'd%d: begin amp_q16 = 17'd%d; k_q12 = 16'd%d; s_ring = 5'd%d; s_damp = 5'd%d; st1 = 5'd%d; st2 = 5'd%d; end\\n"
                          % ((k_inst << 3) | i, amps[i], ks[i],
                             S_RING[i], S_DAMP[i], st1, st2))
"""
new6 = """    # ★ A 路线：case 索引 {inst, band, n} = inst(2)+band(3)+n(3) = 8 bit
    #   钢琴/吉他只有 band0（6 行各）; 二胡 5 档（30 行） => 共 42 行
    for k_inst in range(len(INSTRUMENTS)):
        cfg = INSTRUMENTS[k_inst]
        ks   = inst_k_table(k_inst)
        _nband = N_BAND if k_inst == 2 else 1
        for k_band in range(_nband):
            amps = inst_amp_table(k_inst, k_band)
            for i in range(N_PART):
                st1, st2 = inharm_shifts(i + 1, cfg["B"])
                plines.append("            8'd%d: begin amp_q16 = 17'd%d; k_q12 = 16'd%d; s_ring = 5'd%d; s_damp = 5'd%d; st1 = 5'd%d; st2 = 5'd%d; end\\n"
                              % ((k_inst << 6) | (k_band << 3) | i, amps[i], ks[i],
                                 S_RING[i], S_DAMP[i], st1, st2))
"""
gen = rep(gen, old6, new6, '6 emit loop', fail)

# ---- 7) RTL: 加 band_ld（由 on_note 派生）+ 非二胡强制 0 + 接 .band() ----
#   档边界（参考音：D4=62 F4=65 A4=69 C5=72 D5=74）—— 取最近的参考
#     note >= 73 -> 4 (D5)  |  >= 71 -> 3 (C5)  |  >= 67 -> 2 (A4)
#     note >= 64 -> 1 (F4)  |  else  -> 0 (D4；低于 D4 是【外推】)
old7 = "    piano_partial_lut u_ld_lut (\n        .n       (ld_idx),\n"
new7 = (
    "    // ================= A 路线：二胡 5 档 band_ld（2026-10-06）=================\n"
    "    //   由 on_note 派生（装载期用，慢变量）；档 0 = D4 及更低（【外推，无实测支撑】）\n"
    "    //   ⚠️ 钢琴/吉他 ROM 只有 band0 行 ⇒ 必须强制 band=0，否则查到 default ⇒ 静音/垃圾\n"
    "    wire [2:0] band_ld = (on_note >= 7'd73) ? 3'd4 :\n"
    "                         (on_note >= 7'd71) ? 3'd3 :\n"
    "                         (on_note >= 7'd67) ? 3'd2 :\n"
    "                         (on_note >= 7'd64) ? 3'd1 : 3'd0;\n"
    "    wire [2:0] band_ld_eff = (inst_ok == 2'd2) ? band_ld : 3'd0;\n"
    "\n"
    "    piano_partial_lut u_ld_lut (\n"
    "        .n       (ld_idx),\n"
    "        .band    (band_ld_eff),\n"
)
rtl = rep(rtl, old7, new7, '7 rtl band_ld', fail)

if fail:
    print('FAILED -- nothing written:')
    for x in fail:
        print('   ' + x)
    sys.exit(2)

write(GEN, gen)
write(RTL, rtl)
print('OK: written')
print('  gen %s -> %s' % (fp(GEN), hashlib.sha256(gen.encode('utf-8')).hexdigest()[:16].upper()))
print('  rtl %s -> %s' % (fp(RTL), hashlib.sha256(rtl.encode('utf-8')).hexdigest()[:16].upper()))
