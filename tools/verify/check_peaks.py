#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_peaks.py - 验证 FPGA 测试模式输出的 N 路均匀分布频率是否形成 N 个独立谱峰。

目标平台: Sipeed Tang Mega 138K + PT8211 (I2S, 16-bit, 逐样本合成)
用法示例见 SPECTRUM-VERIFY.md。无参数时打印帮助。
"""
from __future__ import annotations

import argparse
import sys
import wave

import numpy as np
from scipy.signal import find_peaks, windows

GRID_START = 200.0
GRID_STEP = 200.0
GRID_COUNT = 32
FS = 48000
BITS = 16
DELAY = 1
FLOOR_DB = -40.0
TOL_HZ = 2.0


def expected_grid(start, step, count):
    return [start + step * i for i in range(count)]


def synth_reference(freqs, fs, dur, amp=0.25, dac_bits=BITS):
    n = int(round(fs * dur))
    t = np.arange(n) / fs
    x = np.zeros(n)
    for f in freqs:
        x += np.sin(2.0 * np.pi * f * t)
    x /= max(float(np.max(np.abs(x))), 1e-12)
    x *= amp
    q = (1 << (dac_bits - 1)) - 1
    return np.round(x * q).astype(np.int64), x


def pack_i2s_frames(samples, bits=BITS, delay=DELAY):
    sh = 32 - bits - delay
    out = []
    for s in samples:
        u = int(s) & ((1 << bits) - 1)
        out.append((u << sh) & 0xFFFFFFFF)
        out.append(0)
    return out


def unpack_i2s_frames(frames, bits=BITS, delay=DELAY):
    sh = 32 - bits - delay
    mask = (1 << bits) - 1
    vals = []
    for i in range(0, len(frames) - 1, 2):
        v = (frames[i] >> sh) & mask
        if v >= (1 << (bits - 1)):
            v -= 1 << bits
        vals.append(v)
    return np.asarray(vals, dtype=np.int64)


def frames_to_bit_lines(frames, width=32):
    lines = []
    for fi, w in enumerate(frames):
        ws = 0 if fi % 2 == 0 else 1
        for k in range(width):
            lines.append("%d,%d" % (ws, (w >> (width - 1 - k)) & 1))
    return lines


def parse_word_lines(lines, bits=BITS, delay=DELAY):
    frames = []
    for ln in lines:
        ln = ln.strip()
        if not ln or ln.startswith('#'):
            continue
        tok = ln.replace(',', ' ').split()
        if not tok:
            continue
        frames.append(int(tok[0], 0))
    return unpack_i2s_frames(frames, bits=bits, delay=delay)


def parse_i2s_bits_lines(lines, bits=BITS, delay=DELAY, ws_left=0):
    ws, din = [], []
    for ln in lines:
        ln = ln.strip()
        if not ln or ln.startswith('#'):
            continue
        tok = ln.replace(',', ' ').split()
        if len(tok) < 2:
            continue
        ws.append(1 if int(tok[0]) else 0)
        din.append(1 if int(tok[1]) else 0)
    ws = np.asarray(ws, dtype=np.int8)
    din = np.asarray(din, dtype=np.int8)
    if ws.size == 0:
        return np.zeros(0, dtype=np.int64)
    edges = np.flatnonzero(np.diff(ws) != 0) + 1
    bounds = np.concatenate(([0], edges, [ws.size]))
    left = []
    for a, b in zip(bounds[:-1], bounds[1:]):
        seg = din[a:b]
        if seg.size < delay + bits:
            continue
        if int(ws[a]) == ws_left:
            val = 0
            for bitv in seg[delay:delay + bits]:
                val = (val << 1) | int(bitv)
            if val >= (1 << (bits - 1)):
                val -= 1 << bits
            left.append(val)
    return np.asarray(left, dtype=np.int64)


def parse_sample_lines(lines):
    out = []
    for ln in lines:
        ln = ln.strip()
        if not ln or ln.startswith('#'):
            continue
        out.append(float(ln.replace(',', ' ').split()[0]))
    return np.asarray(out, dtype=float)


def analyze(x, fs, freqs=None, floor_db=FLOOR_DB, tol_hz=TOL_HZ, min_sep_hz=None):
    x = np.asarray(x, dtype=float)
    n = int(x.size)
    if n < 64:
        raise SystemExit("样本太少 (%d)，请检查采集长度" % n)
    x = x - float(x.mean())
    mag = np.abs(np.fft.rfft(x * windows.blackmanharris(n)))
    f = np.fft.rfftfreq(n, 1.0 / fs)
    pmax = float(mag.max())
    if pmax <= 0:
        raise SystemExit("输入全零：没有信号")
    db = 20.0 * np.log10(np.maximum(mag, 1e-12) / pmax)
    df = float(fs) / n
    if freqs and len(freqs) > 1:
        step = float(np.median(np.diff(sorted(freqs))))
    else:
        step = 100.0
    if min_sep_hz is None:
        min_sep_hz = max(2.0 * df, 0.5 * step)
    pk, _ = find_peaks(db, height=floor_db,
                       distance=max(1, int(round(min_sep_hz / df))),
                       prominence=20.0)
    rows, used = [], set()
    for ft in (freqs or []):
        if pk.size == 0:
            rows.append(dict(expect=ft, found=float('nan'), err=float('nan'),
                             level=float('-inf'), ok=False))
            continue
        i = int(np.argmin(np.abs(f[pk] - ft)))
        err = float(f[pk][i] - ft)
        lvl = float(db[pk][i])
        ok = (abs(err) <= tol_hz) and (lvl >= floor_db)
        rows.append(dict(expect=ft, found=float(f[pk][i]), err=err, level=lvl, ok=ok))
        if ok:
            used.add(int(pk[i]))
    spurious = [(float(f[i]), float(db[i])) for i in pk if int(i) not in used]
    return dict(rows=rows, spurious=spurious, df=df, n=n, f=f, db=db, pk=pk,
                floor_db=floor_db, min_sep_hz=min_sep_hz, tol_hz=tol_hz, step=step)


def report(res, freqs):
    print("=== 频谱判定 ===")
    print("样本数 %d   频率分辨率 %.4f Hz   窗 Blackman-Harris" % (res['n'], res['df']))
    print("判据: 峰值 >= %.1f dBc, 最小间隔 >= %.1f Hz, 频率误差 <= +-%.1f Hz"
          % (res['floor_db'], res['min_sep_hz'], res['tol_hz']))
    hit = 0
    if freqs:
        print("  #  期望(Hz)   实测(Hz)    误差(Hz)   电平(dBc)  判定")
        for k, r in enumerate(res['rows'], 1):
            if r['ok']:
                hit += 1
            print("%3d  %9.2f  %9.2f  %+9.2f  %9.2f  %s"
                  % (k, r['expect'], r['found'], r['err'], r['level'],
                     'PASS' if r['ok'] else 'FAIL'))
        lv = [r['level'] for r in res['rows'] if r['ok']]
        print("--- 汇总 ---")
        print("期望谱峰 %d   命中 %d   未命中 %d"
              % (len(res['rows']), hit, len(res['rows']) - hit))
        if lv:
            print("命中峰电平范围 %.2f ~ %.2f dBc (离散度 %.2f dB)"
                  % (min(lv), max(lv), max(lv) - min(lv)))
    print("未预期谱峰(>= %.1f dBc): %d" % (res['floor_db'], len(res['spurious'])))
    for ff, dd in res['spurious'][:12]:
        print("   杂散: %10.2f Hz  %8.2f dBc" % (ff, dd))
    if not freqs:
        pk_f = res['f'][res['pk']]
        if pk_f.size > 1:
            sp = np.diff(pk_f)
            print("检出谱峰 %d 个；间隔中位数 %.3f Hz (min %.3f, max %.3f)"
                  % (pk_f.size, float(np.median(sp)), float(sp.min()), float(sp.max())))
    return hit


def write_wav(path, samples, fs):
    s = np.clip(np.round(np.asarray(samples, dtype=float)), -32768, 32767).astype('<i2')
    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(int(fs))
        w.writeframes(s.tobytes())
    return path


def plot(path, res, freqs, fs, xmax=None):
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    f, db = res['f'], res['db']
    top = xmax if xmax else (max(freqs) * 1.6 if freqs else fs / 2)
    m = f <= top
    fig, ax = plt.subplots(figsize=(16, 7), dpi=120)
    ax.plot(f[m] / 1000.0, db[m], lw=0.7, color='#1f77b4', label='spectrum (Blackman-Harris)')
    if freqs:
        for ft in freqs:
            ax.axvline(ft / 1000.0, color='red', ls='--', lw=0.8, alpha=0.55)
        pf = res['f'][res['pk']]
        pd_ = res['db'][res['pk']]
        k = pf <= top
        ax.plot(pf[k] / 1000.0, pd_[k], 'o', ms=4, color='#2ca02c', label='detected peaks')
    ax.axhline(res['floor_db'], color='gray', ls=':', lw=1.0,
               label='threshold %.0f dBc' % res['floor_db'])
    ax.set_xlabel('Frequency (kHz)')
    ax.set_ylabel('Level (dBc)')
    ax.set_ylim(max(res['floor_db'] - 20, -120), 6)
    n_ok = sum(1 for r in res['rows'] if r['ok'])
    title = ('%d expected / %d detected / %d spurious -> %s'
             % (len(res['rows']), n_ok, len(res['spurious']),
                'PASS' if (freqs and n_ok == len(res['rows']) and not res['spurious']) else 'CHECK'))
    ax.set_title(title)
    ax.grid(alpha=0.3)
    ax.legend(loc='upper right')
    fig.tight_layout()
    fig.savefig(path)
    plt.close(fig)
    return path


def load_signal(args):
    if args.format == 'pcm16':
        with open(args.file, 'rb') as fh:
            raw = fh.read()
        return np.frombuffer(raw, dtype='<i2').astype(float), args.fs
    with open(args.file, 'r', encoding='utf-8', errors='replace') as fh:
        lines = fh.readlines()
    if args.format == 'i2s-bits':
        return parse_i2s_bits_lines(lines, bits=args.bits, delay=args.delay,
                                    ws_left=args.ws_left).astype(float), args.fs
    if args.format == 'i2s-words':
        return parse_word_lines(lines, bits=args.bits, delay=args.delay).astype(float), args.fs
    return parse_sample_lines(lines), args.fs


def build_freqs(args):
    if args.tones:
        return [float(t) for t in args.tones.replace(',', ' ').split()]
    if args.count:
        return expected_grid(args.start, args.step, args.count)
    return None


def run_selftest(args):
    freqs = expected_grid(args.start, args.step, args.count)
    ok = True
    print("[1/4] 32 音合成 -> int16 量化 -> 32bit I2S 帧 -> 打包/解包")
    sig, _ = synth_reference(freqs, args.fs, args.dur)
    dec = unpack_i2s_frames(pack_i2s_frames(sig)).astype(float)
    same = bool(np.array_equal(dec.astype(np.int64), sig))
    print("      I2S 打包/解包逐样本一致:", same)
    ok &= same
    res = analyze(dec, args.fs, freqs, args.floor_db, args.tol_hz, args.min_sep)
    hit = report(res, freqs)
    ok &= (hit == len(freqs) and not res['spurious'])

    print()
    print("[2/4] 逐 BCLK 位流 (ws,din) 文本行 -> 解码 -> 分析（验证真正的 I2S 帧格式）")
    bitlines = frames_to_bit_lines(pack_i2s_frames(sig))
    dec2 = parse_i2s_bits_lines(bitlines, bits=args.bits, delay=args.delay,
                                ws_left=args.ws_left).astype(float)
    same2 = bool(np.array_equal(dec2.astype(np.int64), sig))
    print("      位流解码逐样本一致:", same2, "| 解码样本数", dec2.size)
    ok &= same2
    res2 = analyze(dec2, args.fs, freqs, args.floor_db, args.tol_hz, args.min_sep)
    hit2 = report(res2, freqs)
    ok &= (hit2 == len(freqs) and not res2['spurious'])

    print()
    print("[3/4] 负对照：只发 16 路（应恰好检出 16），且用 32 路判据应报 16 个未命中")
    half = freqs[:16]
    sig16, _ = synth_reference(half, args.fs, args.dur)
    dec16 = unpack_i2s_frames(pack_i2s_frames(sig16)).astype(float)
    res16 = analyze(dec16, args.fs, half, args.floor_db, args.tol_hz, args.min_sep)
    hit16 = report(res16, half)
    n_ok16 = sum(1 for r in res16['rows'] if r['ok'])
    print("      16 路自洽命中 %d/16" % n_ok16)
    res16b = analyze(dec16, args.fs, freqs, args.floor_db, args.tol_hz, args.min_sep)
    miss = sum(1 for r in res16b['rows'] if not r['ok'])
    print("      用 32 路判据检查 16 路信号 -> 未命中 %d 个（期望 16）" % miss)
    ok &= (n_ok16 == 16 and miss == 16)

    print()
    print("[4/4] 文本行解析路径（word 行 / sample 行）")
    wl = ["%#010x" % w for w in pack_i2s_frames(sig)]
    dec3 = parse_word_lines(wl).astype(float)
    same3 = bool(np.array_equal(dec3.astype(np.int64), sig))
    sl = [str(int(v)) for v in sig]
    dec4 = parse_sample_lines(sl)
    same4 = bool(np.array_equal(dec4.astype(np.int64), sig))
    print("      i2s-words 文本解析一致:", same3, "| samples 文本解析一致:", same4)
    ok &= (same3 and same4)

    print()
    print("[5/5] 灵敏度对照：人为硬限幅（模拟 32 路累加饱和）必须能检出杂散")
    _, xf = synth_reference(freqs, args.fs, args.dur)
    xn = xf / max(float(np.max(np.abs(xf))), 1e-12)
    yclip = np.round(np.clip(xn, -0.5, 0.5) * ((1 << (args.bits - 1)) - 1)).astype(float)
    res_clip = analyze(yclip, args.fs, freqs, args.floor_db, args.tol_hz, args.min_sep)
    n_sp = len(res_clip['spurious'])
    print("      限幅信号检出杂散峰 %d 个 -> %s"
          % (n_sp, "检出异常 OK" if n_sp >= 5 else "未检出（判据过松）FAIL"))
    ok &= (n_sp >= 5)

    print()
    print("SELFTEST:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


def main(argv=None):
    ap = argparse.ArgumentParser(description="FPGA 测试模式多音频谱谱峰验证")
    ap.add_argument('--selftest', action='store_true', help='无硬件自检（合成+编解码+负对照）')
    ap.add_argument('--file', help='输入文件')
    ap.add_argument('--format', default='samples',
                    choices=['i2s-bits', 'i2s-words', 'samples', 'pcm16'],
                    help='i2s-bits: 每行 "ws,din"(每个BCLK一个采样点); '
                         'i2s-words: 每行一个32bit I2S帧字; samples: 每行一个十进制样本; '
                         'pcm16: 小端16bit裸PCM')
    ap.add_argument('--fs', type=float, default=FS, help='采样率 Hz (默认 48000)')
    ap.add_argument('--bits', type=int, default=BITS, help='I2S 有效位数 (默认 16)')
    ap.add_argument('--delay', type=int, default=DELAY, help='I2S MSB 相对 WS 边的延迟位数 (默认 1)')
    ap.add_argument('--ws-left', type=int, default=0, help='左声道对应的 WS 电平 (默认 0)')
    ap.add_argument('--tones', help='期望频率列表，逗号/空格分隔')
    ap.add_argument('--start', type=float, default=GRID_START, help='起始频率 Hz (默认 200)')
    ap.add_argument('--step', type=float, default=GRID_STEP, help='频率间隔 Hz (默认 200)')
    ap.add_argument('--count', type=int, default=GRID_COUNT, help='音数 (默认 32)')
    ap.add_argument('--dur', type=float, default=1.0, help='自检信号时长 s (默认 1.0)')
    ap.add_argument('--floor-db', type=float, default=FLOOR_DB, help='峰值门限 dBc (默认 -40)')
    ap.add_argument('--tol-hz', type=float, default=TOL_HZ, help='频率容差 Hz (默认 2)')
    ap.add_argument('--min-sep', type=float, default=None, help='最小峰间隔 Hz (默认自动)')
    ap.add_argument('--plot', help='输出频谱 PNG（可直接作为报告截图）')
    ap.add_argument('--xmax', type=float, default=None, help='绘图横轴上界 Hz')
    ap.add_argument('--write-wav', help='把解码后的左声道写成 16bit WAV（用于试听/ffmpeg 分析）')
    args = ap.parse_args(argv)

    if args.selftest:
        return run_selftest(args)
    if not args.file:
        ap.print_help()
        return 2

    x, fs = load_signal(args)
    freqs = build_freqs(args)
    print("输入: %s (%s)  解码样本数: %d  采样率: %g Hz" % (args.file, args.format, x.size, fs))
    if args.write_wav:
        print("已写 WAV:", write_wav(args.write_wav, x, fs))
    res = analyze(x, fs, freqs, args.floor_db, args.tol_hz, args.min_sep)
    hit = report(res, freqs)
    if args.plot:
        print("已写频谱图:", plot(args.plot, res, freqs or [], fs, args.xmax))
    if freqs:
        good = (hit == len(freqs)) and not res['spurious']
        print("结论:", "PASS - 检出 %d 路独立谱峰" % hit if good
              else "FAIL - 命中 %d/%d, 杂散 %d" % (hit, len(freqs), len(res['spurious'])))
        return 0 if good else 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
