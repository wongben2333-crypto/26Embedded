"""Compare synthesized RTL algorithms with independent NumPy PCM/FFT results."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
N = 4096
FS = 50_000_000 / 512


def height(power):
    power = int(power)
    if power <= 4:
        return 0
    msb = power.bit_length() - 1
    normalized = power >> (msb - 4) if msb >= 4 else power << (4 - msb)
    return min(144, max(0, ((msb * 16 + (normalized & 15) - 32) * 3) >> 3))


def envelope(samples, width):
    """Group absolute PCM by elapsed time, retaining the last three seconds."""
    if len(samples) == 0:
        return np.zeros((width, 2), dtype=np.int64)
    buckets = np.arange(len(samples), dtype=np.int64) * width * 512 // 150_000_000
    starts = np.r_[0, np.flatnonzero(np.diff(buckets)) + 1]
    peaks = np.maximum.reduceat(np.abs(samples), starts)[-width:]
    result = np.zeros((width, 2), dtype=np.int64)
    result[:len(peaks), 0] = peaks
    result[:len(peaks), 1] = 1
    return result


def main():
    parser = argparse.ArgumentParser()
    local_bin = ROOT / "scratch/iverilog_pkg/mingw64/bin"
    parser.add_argument("--iverilog", default=shutil.which("iverilog") or str(local_bin / "iverilog.exe"))
    parser.add_argument("--vvp", default=shutil.which("vvp") or str(local_bin / "vvp.exe"))
    args = parser.parse_args()
    work = ROOT / "scratch/visualizer_test"
    work.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    runtime_bin = Path(args.vvp).parent
    extra_bins = [
        runtime_bin,
        Path(r"D:\mingw64\bin"),
        Path(r"C:\Users\gjl50\.cache\codex-runtimes\codex-primary-runtime\dependencies\native\git\mingw64\bin"),
    ]
    env["PATH"] = os.pathsep.join(str(p) for p in extra_bins if p.exists()) + os.pathsep + env.get("PATH", "")
    env["TMP"] = env["TMPDIR"] = str(work)
    n = np.arange(N)
    tone = np.rint(16000 * np.sin(2 * np.pi * 64 * n / N)).astype(np.int64)
    cases = [
        ("silence", np.zeros(N, dtype=np.int64)),
        ("DC", np.full(N, 12000)),
        ("negative full scale DC", np.full(N, -32768)),
        ("single tone", tone),
        ("half volume", np.rint(tone / 2).astype(np.int64)),
        ("two tones", np.rint(9000 * np.sin(2*np.pi*9*n/N) + 6000 * np.sin(2*np.pi*126*n/N)).astype(np.int64)),
        ("32 tones", np.rint(sum(300*np.sin(2*np.pi*200*k*n/FS) for k in range(1,33))).astype(np.int64)),
        ("impulses", np.where(n == 2000, 32767, np.where(n == 2001, -32768, 0))),
        ("full scale alternating", np.where(n % 2, -32768, 32767)),
        ("noise", np.random.default_rng(42).integers(-32768,32768,N)),
    ]
    vector_file = work / "vectors.hex"
    vector_file.write_text("".join(f"{int(x)&65535:04x}\n" for _, data in cases for x in data), encoding="ascii")
    executable = work / "visualizer.vvp"
    subprocess.run([args.iverilog, "-g2012", "-Irtl", "-s", "tb_audio_visualizer", "-o", str(executable),
                    "tests/tb_audio_visualizer.sv", "rtl/visualizer/audio_visualizer.v",
                    "rtl/visualizer/rolling_waveform.v", "rtl/visualizer/fft4096.v"],
                   cwd=ROOT, env=env, check=True)
    result_file = work / "results.txt"
    subprocess.run([args.vvp, str(executable), f"+vectors={vector_file.as_posix()}",
                    f"+output={result_file.as_posix()}", f"+cases={len(cases)}"],
                   cwd=ROOT, env=env, check=True, timeout=180)
    results = []
    for line in result_file.read_text().splitlines():
        tag, *values = line.split()
        values = [int(x) for x in values]
        if tag == "CASE":
            results.append({"meta": values, "FFT": [], "W0": [], "W1": [], "B": []})
        else:
            results[-1][tag].append(values[1:])
    assert len(results) == len(cases)
    hann = np.array([int(x,16) for x in (ROOT/"rtl/visualizer/fft_hann.hex").read_text().split()])
    frequencies = np.arange(1,2048) * FS / N
    errors = []
    history = np.empty(0, dtype=np.int64)
    for c, ((name, samples), result) in enumerate(zip(cases, results)):
        fft = np.array(result["FFT"])
        expected = np.fft.fft(((samples - (int(samples.sum()) >> 12)) * hann) >> 15) / N
        error = max(np.max(np.abs(fft[:,0]-expected.real)), np.max(np.abs(fft[:,1]-expected.imag)))
        assert error < 12, (name, "FFT numerical error", error)
        errors.append(float(error))
        history = np.r_[history, samples]
        for key, width in [("W0",420),("W1",758)]:
            np.testing.assert_array_equal(result[key], envelope(history,width), err_msg=name+key)
        history = np.r_[history, np.full(4096, 0x5555)]
        peak = int(np.abs(samples).max())
        assert result["meta"][1:] == [min(255,peak >> 7), c*2, int(peak>32)], name
        power = fft[1:2048,0]**2 + fft[1:2048,1]**2
        bands = np.array(result["B"])
        for b in range(32):
            mask = (frequencies >= 64*2**(b/4)) & (frequencies < 64*2**((b+1)/4))
            target = (b+1)*200
            bench_mask = (frequencies >= target-75) & (frequencies < target+75)
            assert bands[b,0] == height(power[mask].max(initial=0)), (name,b,"log band")
            assert bands[b,1] == height(power[bench_mask].max(initial=0)), (name,b,"benchmark band")
        if c < 3:
            assert not fft.any() and not bands.any(), (name,"DC rejection")
        if c in (3,4):
            assert np.argmax(power)+1 == 64, (name,"peak frequency")
        if c == 6:
            assert np.array(result["B"])[:,1].min() > 35, "Missing one of 32 measured tones"
        print(f"PASS {name}: FFT error {error:.3f} counts; waveform, levels, VU and metadata exact")
    full = np.array(results[3]["B"])[:,0].max()
    half = np.array(results[4]["B"])[:,0].max()
    assert 11 <= full-half <= 13, ("6 dB volume step",full,half)
    print(f"PASS {len(cases)} PCM cases; maximum FFT component error {max(errors):.3f} counts")
    rolling_executable = work / "rolling.vvp"
    rolling_results = work / "rolling.txt"
    subprocess.run([args.iverilog, "-g2012", "-s", "tb_rolling_waveform", "-o", str(rolling_executable),
                    "tests/tb_rolling_waveform.sv", "rtl/visualizer/rolling_waveform.v"],
                   cwd=ROOT, env=env, check=True)
    subprocess.run([args.vvp, str(rolling_executable), f"+output={rolling_results.as_posix()}"],
                   cwd=ROOT, env=env, check=True, timeout=180)
    n = np.arange(1_200_000, dtype=np.int64)
    levels = 1000 + ((n // 1300) * 137) % 28000
    levels[n % 10007 == 0] = 32768
    levels[n >= 900000] = 0
    pcm = np.where(n % 2 == 0, -levels, np.minimum(levels, 32767))
    snapshots = []
    for line in rolling_results.read_text().splitlines():
        tag, *values = line.split()
        values = [int(x) for x in values]
        if tag == "SNAP":
            snapshots.append({"samples": values[0], "W0": [], "W1": []})
        else:
            snapshots[-1][tag].append(values[1:])
    for result in snapshots:
        for key, width in [("W0",420),("W1",758)]:
            np.testing.assert_array_equal(result[key], envelope(pcm[:result["samples"]], width),
                                          err_msg=f"{key} at sample {result['samples']}")
    assert len(snapshots) == 10
    assert all(valid for peak, valid in snapshots[5]["W1"]), "Three-second window not full"
    assert not np.array(snapshots[-1]["W1"])[:,0].any(), "Old audio did not scroll out"
    print("PASS 10 rolling snapshots over 12.288 seconds: exact peaks and chronological order")
    dac_executable = work / "dac_pcm.vvp"
    sources = sorted(str(p.relative_to(ROOT)) for p in (ROOT / "rtl").rglob("*.v")
                     if not p.name.startswith("bench_"))
    subprocess.run([args.iverilog, "-g2012", "-Irtl", "-Irtl/effects", "-s", "tb_dac_pcm", "-o", str(dac_executable),
                    "tests/tb_dac_pcm.sv", *sources], cwd=ROOT, env=env, check=True)
    subprocess.run([args.vvp, str(dac_executable)], cwd=ROOT, env=env, check=True, timeout=60)


if __name__ == "__main__":
    main()
