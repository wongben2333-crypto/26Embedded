# -*- coding: utf-8 -*-
"""record_audio.py —— 从麦克风录音，并立即做 FFT 初判（真板 32 谱峰取证用）

★ 为什么需要它：
  赛题必备交付物是"频谱能数出 32 根独立谱峰"，而且**必须在真板上取证**。
  本机没有 ffmpeg/sox，但有 `sounddevice`（0.5.6）+ `scipy` + `numpy`，
  所以直接在 Python 里录成 WAV，避免格式转换的麻烦。

★ 用法：
    python tools/verify/record_audio.py --sec 10 --out out/record/mic1.wav
    python tools/verify/record_audio.py --list            # 列出输入设备
    python tools/verify/record_audio.py --device 1 --sec 8

★ 录完会立刻：
  1) 报告实际采样率、时长、电平（太小声/削顶都会提示）
  2) 做一次 FFT，粗看 200..6400 Hz 区间能不能看出等间距的峰
     （正式判据仍以 check_peaks.py 为准 —— 这里只是给个即时反馈）
"""
from __future__ import annotations

import argparse
import os
import sys

import numpy as np

sys.stdout.reconfigure(encoding='utf-8')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--list', action='store_true', help='列出输入设备')
    ap.add_argument('--device', type=int, default=None, help='输入设备号（默认用系统默认）')
    ap.add_argument('--sec', type=float, default=10.0, help='录音时长（秒）')
    ap.add_argument('--fs', type=float, default=None, help='采样率（默认用设备默认值）')
    ap.add_argument('--out', default=None, help='输出 WAV 路径')
    ap.add_argument('--channels', type=int, default=1, help='通道数（默认单声道）')
    args = ap.parse_args()

    import sounddevice as sd
    from scipy.io import wavfile

    if args.list:
        print('输入设备：')
        for i, d in enumerate(sd.query_devices()):
            if d['max_input_channels'] > 0:
                print('  [%d] %-52s 通道%d  默认%.0f Hz'
                      % (i, d['name'], d['max_input_channels'], d['default_samplerate']))
        return 0

    dev = args.device
    info = sd.query_devices(dev, 'input')
    fs = int(args.fs or info['default_samplerate'])
    print('[rec] 设备     : %s' % info['name'])
    print('[rec] 采样率   : %d Hz' % fs)
    print('[rec] 时长     : %.1f s' % args.sec)
    print('[rec] 通道     : %d' % args.channels)
    print('[rec] 开始录音 …… 请让板子持续发声（测试模式不需要按键）')
    sys.stdout.flush()

    n = int(round(args.sec * fs))
    try:
        rec = sd.rec(n, samplerate=fs, channels=args.channels,
                     dtype='float32', device=dev)
        sd.wait()
    except Exception as e:
        print('[rec] ❌ 录音失败: %s' % e)
        return 2

    # ★ 必须 squeeze：sd.rec 即使 channels=1 也返回形状 (n,1)，
    #   直接拿去做 xw * w 会广播成 (n,n) 矩阵 —— 实测要分配 58 GiB 直接崩。
    x = np.asarray(rec, dtype=np.float64).squeeze()

    peak = float(np.max(np.abs(x)))
    rms = float(np.sqrt(np.mean(x ** 2)))
    db = 20 * np.log10(max(rms, 1e-12))
    print('[rec] 峰值     : %.4f' % peak)
    print('[rec] RMS      : %.5f  (%.1f dBFS)' % (rms, db))
    if peak < 0.005:
        print('[rec] ⚠️ 电平极低 —— 麦克风可能没收到声音，或板子没在发声')
    elif peak > 0.99:
        print('[rec] ⚠️ 可能削顶（麦克风离太近/音量太大）')
    else:
        print('[rec] ✅ 电平正常')

    if args.out:
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        pcm = np.clip(x * 32767.0, -32768, 32767).astype('<i2')
        wavfile.write(args.out, fs, pcm)
        print('[rec] 已保存   : %s  (%d 样本)' % (args.out, len(pcm)))

    # ---------------- 即时 FFT 初判 ----------------
    xw = x - x.mean()
    w = np.blackman(len(xw))
    sp = np.abs(np.fft.rfft(xw * w))
    fr = np.fft.rfftfreq(len(xw), 1.0 / fs)

    m = (fr > 150) & (fr < 7000)
    spm, frm = sp[m], fr[m]
    peak_idx = np.argmax(spm)
    print('[rec] 最强频率 : %.1f Hz' % frm[peak_idx])

    # 数一数 200 Hz 整数倍附近有没有局部峰
    hits = 0
    for k in range(1, 33):
        tgt = 200.0 * k
        sel = (frm > tgt - 60) & (frm < tgt + 60)
        if sel.any():
            loc = spm[sel].max()
            if loc > 0.05 * spm.max():
                hits += 1
    print('[rec] 初判      : 200..6400 Hz 的 32 个频点上，有 %d 个明显能量' % hits)
    if hits >= 28:
        print('[rec] ✅ 初判通过 —— 很可能能数出 32 根谱峰，接着跑正式判据')
    elif hits >= 15:
        print('[rec] ⚠️ 初判勉强 —— 峰数偏少，可能是麦克风频响/噪声问题，建议换个位置重录')
    else:
        print('[rec] ❌ 初判不通过 —— 换更安静的环境、把麦克风靠近喇叭再录一次')
    return 0


if __name__ == '__main__':
    sys.exit(main())
