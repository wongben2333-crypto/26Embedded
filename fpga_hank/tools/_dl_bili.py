# -*- coding: utf-8 -*-
"""Download audio of several Bilibili videos -> WAV (mono 48k). Usage: _dl_bili.py BV1 BV2 ..."""
import os, subprocess, sys
import requests

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.normpath(os.path.join(HERE, "..", "_tools"))
FFMPEG = os.path.join(TOOLS, "venv", "Lib", "site-packages", "imageio_ffmpeg",
                      "binaries", "ffmpeg-win-x86_64-v7.1.exe")

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/124.0 Safari/537.36")
HDR = {"User-Agent": UA, "Referer": "https://www.bilibili.com/"}
S = requests.Session()
S.headers.update(HDR)

TAG = {"BV1J6DiBbE2g": "erhu_liangzhu", "BV1PqedzNEZF": "erhu_ruoshui"}

for bv in sys.argv[1:]:
    tag = TAG.get(bv, bv)
    print("=" * 60)
    print("BV =", bv, " tag =", tag)
    r = S.get("https://api.bilibili.com/x/web-interface/view", params={"bvid": bv}, timeout=30)
    j = r.json()
    if j.get("code") != 0:
        print("  view failed:", j.get("code"), j.get("message")); continue
    d = j["data"]; cid = d["cid"]
    print("  title =", d["title"])
    print("  cid =", cid, " duration =", d["duration"], "s  pages =", len(d.get("pages", [])))
    r2 = S.get("https://api.bilibili.com/x/player/playurl",
               params={"bvid": bv, "cid": cid, "fnval": 16, "fourk": 1}, timeout=30)
    j2 = r2.json()
    dash = (j2.get("data") or {}).get("dash")
    if not dash:
        print("  no dash"); continue
    auds = dash.get("audio") or []
    for a in auds:
        print("     audio id=%s bw=%s codec=%s" % (a.get("id"), a.get("bandwidth"), a.get("codecs")))
    if not auds:
        print("  no audio"); continue
    a = sorted(auds, key=lambda x: x.get("bandwidth", 0))[-1]
    m4s = os.path.join(TOOLS, "bili_%s_%s.m4s" % (tag, bv))
    wav = os.path.join(TOOLS, "bili_%s_%s.wav" % (tag, bv))
    print("  chosen bw =", a.get("bandwidth"))
    with S.get(a["baseUrl"], stream=True, timeout=180) as resp:
        resp.raise_for_status()
        n = 0
        with open(m4s, "wb") as f:
            for chunk in resp.iter_content(1 << 16):
                f.write(chunk); n += len(chunk)
    print("  m4s %d bytes" % n)
    p = subprocess.run([FFMPEG, "-y", "-i", m4s, "-ac", "1", "-ar", "48000",
                        "-c:a", "pcm_s16le", wav], capture_output=True)
    if p.returncode != 0:
        print("  ffmpeg failed:", p.stderr.decode("utf-8", "replace")[-800:]); continue
    import soundfile as sf, numpy as np
    x, sr = sf.read(wav)
    print("  WAV %s  %.2f MB  sr=%d dur=%.2f s peak=%.4f rms=%.5f"
          % (os.path.basename(wav), os.path.getsize(wav) / 1e6, sr, len(x) / sr,
             float(np.max(np.abs(x))), float(np.sqrt(np.mean(x ** 2)))))
print("done")
