# -*- coding: utf-8 -*-
"""extract_melody.py —— 从麦克风录音里自动提取旋律（音名 + 时值）

★ 用途
  用户用电脑扬声器播放目标歌曲（如 Faded 副歌），本脚本：
      录音 → librosa.pyin 音高追踪 → 量化成音符 → 输出 (音名, 时值) 表
  供 song-demo 编码进 song_rom.v。

★ 为什么用 pyin
  pyin 是概率式 YIN，专为【含泛音/伴奏的准单音旋律】设计，
  比裸 FFT 峰值稳得多（FFT 会把泛音当基频）。

★ 注意
  · 多声部混音里提旋律是【估计】不是【精确转录】—— 结果必须人耳复核
  · 输出里会标注每段的置信度（voiced_flag / 概率），低置信段落标 [?]

用法：
    python tools/verify/extract_melody.py --sec 25 --out out/record/faded_ref.wav
    python tools/verify/extract_melody.py --analyze out/record/faded_ref.wav
"""
from __future__ import annotations

import argparse
import os
import sys

import numpy as np

sys.stdout.reconfigure(encoding='utf-8')

NAMES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B']


def hz_to_name(f: float) -> str:
    """频率 → 音名（如 440.0 → A4）"""
    if f <= 0:
        return '--'
    midi = int(round(69 + 12 * np.log2(f / 440.0)))
    return '%s%d' % (NAMES[midi % 12], midi // 12 - 1)


def record(sec: float, out: str, dev: int | None) -> tuple[np.ndarray, int]:
    import sounddevice as sd
    from scipy.io import wavfile

    info = sd.query_devices(dev, 'input')
    fs = int(info['default_samplerate'])
    print('[rec] 设备 %s  fs=%d  时长 %.1f s' % (info['name'], fs, sec))
    print('[rec] ★ 现在开始播放歌曲（副歌段落）……')
    sys.stdout.flush()
    rec = sd.rec(int(sec * fs), samplerate=fs, channels=1, dtype='float32', device=dev)
    sd.wait()
    x = np.asarray(rec, dtype=np.float64).squeeze()
    rms = float(np.sqrt(np.mean(x ** 2)))
    print('[rec] 完成  峰值=%.4f  RMS=%.5f (%.1f dBFS)' % (np.max(np.abs(x)), rms,
                                                          20 * np.log10(max(rms, 1e-12))))
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    wavfile.write(out, fs, np.clip(x * 32767, -32768, 32767).astype('<i2'))
    print('[rec] 已存 %s' % out)
    return x, fs


def analyze(path: str, fmin: float, fmax: float, min_dur: float):
    import librosa

    y, sr = librosa.load(path, sr=None, mono=True)
    print('[an] %s  sr=%d  时长=%.2f s' % (path, sr, len(y) / sr))

    # 带通滤波思路：pyin 支持 fmin/fmax 限定搜索范围（人声旋律大致 C3..C6）
    f0, voiced, vprob = librosa.pyin(
        y, fmin=fmin, fmax=fmax, sr=sr,
        frame_length=2048, hop_length=256,
    )
    times = librosa.times_like(f0, sr=sr, hop_length=256)

    ok = ~np.isnan(f0)
    print('[an] 有音高帧 %d / %d (%.1f%%)' % (ok.sum(), len(f0), 100 * ok.mean()))
    if ok.sum() == 0:
        print('[an] ❌ 没提取到任何音高 —— 录音太小/太吵/不是单音旋律')
        return []

    # ---- 量化成音符：连续且音名相同的帧合并 ----
    notes = []
    cur_name, cur_start, cur_f0s = None, None, []
    for t, f, v, p in zip(times, f0, ok, vprob):
        nm = hz_to_name(f) if v else None
        if nm != cur_name:
            if cur_name is not None:
                dur = t - cur_start
                if dur >= min_dur:
                    notes.append((cur_name, float(np.median(cur_f0s)), cur_start, dur,
                                  float(np.mean(cur_conf))))
            cur_name, cur_start, cur_f0s, cur_conf = nm, t, [], []
        if v:
            cur_f0s.append(f)
            cur_conf = getattr(cur_conf, '__len__', None) and cur_conf or []
    # 收尾（简化：上面分支已足够，单个音串尾在循环里被下一段切断）

    # 更稳的实现：按帧先算音名序列，再 run-length 合并
    notes = []
    names = np.array([hz_to_name(f) if v else None for f, v in zip(f0, ok)], dtype=object)
    i = 0
    while i < len(names):
        if names[i] is None:
            i += 1
            continue
        j = i
        while j + 1 < len(names) and names[j + 1] == names[i]:
            j += 1
        dur = times[j] - times[i] + (times[1] - times[0] if len(times) > 1 else 0)
        if dur >= min_dur:
            seg = f0[i:j + 1]
            seg = seg[~np.isnan(seg)]
            notes.append((str(names[i]), float(np.median(seg)), float(times[i]), float(dur),
                          float(np.mean(vprob[i:j + 1]))))
        i = j + 1

    print('\n[an] === 提取到的旋律（%d 个音，>=%.0f ms）===' % (len(notes), min_dur * 1000))
    print('  #  音名    实测Hz    起拍(s)   时长(ms)  置信')
    for k, (nm, f, t0, dur, cf) in enumerate(notes):
        flag = '  [?]' if cf < 0.5 else ''
        print('  %-3d %-6s %8.2f  %7.3f  %8.1f  %.2f%s' % (k, nm, f, t0, dur * 1000, cf, flag))

    # 音程串（与调性无关，用于跨来源比对）
    midis = [int(round(69 + 12 * np.log2(f / 440.0))) for _, f, _, _, _ in notes]
    if midis:
        rel = [m - midis[0] for m in midis]
        print('\n[an] 音程串（相对第 1 个音）: %s' % ' '.join('%+d' % r for r in rel))

    # 自查：重合率应该 ≈0（单旋律），级进率应该高
    if len(midis) > 1:
        steps = [abs(midis[k + 1] - midis[k]) for k in range(len(midis) - 1)]
        step_rate = sum(1 for s in steps if s <= 2) / len(steps)
        print('[an] 级进率(相邻差<=2半音) = %.1f%%   （旋律应【高】；分解和弦应低）' % (100 * step_rate))
    return notes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--sec', type=float, default=25.0, help='录音时长（秒）')
    ap.add_argument('--out', default=None, help='录音保存路径')
    ap.add_argument('--analyze', default=None, help='只分析已有 wav（不录音）')
    ap.add_argument('--device', type=int, default=28, help='输入设备号（默认 28=麦克风阵列2）')
    ap.add_argument('--fmin', type=float, default=130.0, help='音高搜索下限 Hz（C3≈131）')
    ap.add_argument('--fmax', type=float, default=1200.0, help='音高搜索上限 Hz（D6≈1175）')
    ap.add_argument('--min-dur', type=float, default=0.08, help='最短音符时长（秒）')
    args = ap.parse_args()

    if args.analyze:
        analyze(args.analyze, args.fmin, args.fmax, args.min_dur)
        return 0

    x, fs = record(args.sec, args.out or 'out/record/melody_ref.wav', args.device)
    import soundfile as sf
    tmp = (args.out or 'out/record/melody_ref.wav')
    analyze(tmp, args.fmin, args.fmax, args.min_dur)
    return 0


if __name__ == '__main__':
    sys.exit(main())
