#!/usr/bin/env python3
"""analyze-sounds.py: check Murmur's UI sounds against their recipes (standard library only).

Usage: python3 scripts/analyze-sounds.py [sounds_dir]        (default: Resources/Sounds)

For each WAV: format, length, peak and loudest-10-ms RMS (dBFS), the pitch track (dominant frequency per
window, Hann + FFT + parabolic interpolation), onset/tail click checks and a PASS/FAIL against the
expectations below. Exit status is non-zero when any check fails.
"""
import cmath
import math
import os
import struct
import sys
import wave

EXPECT = {
    # name: (max length ms, peak dBFS, [(window start ms, expected Hz[, window ms])], note)
    "start": (150, -14, [(0, 925, 8), (60, 988)], "rising pluck"),
    "stop": (180, -14, [(15, 784), (95, 587)], "falling pair"),
    "lock": (200, -14, [(20, 988), (100, 1175)], "double pluck, second higher"),
    "paste": (50, -22, [(2, 2100)], "tiny high tick, quietest"),
    "cancel": (170, -24, [], "noise swish"),
    "alert": (430, -14, [(30, 523), (200, 659)], "two bell tones up"),
    "error": (330, -16, [(30, 330), (170, 262)], "minor third down"),
    "success": (610, -14, [(20, 523), (80, 659), (300, 784)], "rising triad"),
}


def read(path):
    with wave.open(path, "rb") as w:
        sr, ch, width, n = w.getframerate(), w.getnchannels(), w.getsampwidth(), w.getnframes()
        raw = w.readframes(n)
    samples = [v / 32768 for v in struct.unpack("<%dh" % (len(raw) // 2), raw)]
    return sr, ch, width, samples


def fft(x):
    n = len(x)
    if n == 1:
        return x
    even = fft(x[0::2])
    odd = fft(x[1::2])
    out = [0j] * n
    for k in range(n // 2):
        t = cmath.exp(-2j * math.pi * k / n) * odd[k]
        out[k] = even[k] + t
        out[k + n // 2] = even[k] - t
    return out


def dominant_hz(samples, sr, start_ms, window_ms=20, size=8192):
    start = int(start_ms * sr / 1000)
    length = int(window_ms * sr / 1000)
    seg = samples[start:start + length]
    if len(seg) < 64:
        return None
    hann = [0.5 - 0.5 * math.cos(2 * math.pi * i / (len(seg) - 1)) for i in range(len(seg))]
    buf = [complex(s * w) for s, w in zip(seg, hann)] + [0j] * (size - len(seg))
    spectrum = [abs(v) for v in fft(buf)[: size // 2]]
    lo = int(80 * size / sr)
    k = max(range(lo, len(spectrum) - 1), key=lambda i: spectrum[i])
    a, b, c = spectrum[k - 1], spectrum[k], spectrum[k + 1]
    denom = a - 2 * b + c
    shift = 0.5 * (a - c) / denom if denom else 0.0
    return (k + shift) * sr / size


def centroid_hz(samples, sr, start_ms, window_ms=20, size=4096):
    start = int(start_ms * sr / 1000)
    seg = samples[start:start + int(window_ms * sr / 1000)]
    hann = [0.5 - 0.5 * math.cos(2 * math.pi * i / (len(seg) - 1)) for i in range(len(seg))]
    spectrum = [abs(v) for v in fft([complex(a * w) for a, w in zip(seg, hann)] + [0j] * (size - len(seg)))[: size // 2]]
    power = [m * m for m in spectrum]
    total = sum(power) or 1e-12
    return sum(i * sr / size * p for i, p in enumerate(power)) / total


def db(x):
    return 20 * math.log10(max(x, 1e-9))


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    folder = sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, "Resources", "Sounds")
    failures = 0
    print(f"{'sound':8s} {'fmt':14s} {'len':>7s} {'peak':>7s} {'rms10':>7s}  pitch track (ms: Hz)")
    for name, (max_ms, peak_target, pitches, note) in EXPECT.items():
        path = os.path.join(folder, f"{name}.wav")
        if not os.path.exists(path):
            print(f"{name:8s} MISSING")
            failures += 1
            continue
        sr, ch, width, s = read(path)
        length_ms = len(s) / sr * 1000
        peak = db(max(abs(v) for v in s))
        win = int(0.010 * sr)
        rms10 = max(math.sqrt(sum(v * v for v in s[i:i + win]) / win) for i in range(0, len(s) - win, win // 2))
        track = []
        problems = []
        for spec in pitches:
            at_ms, want = spec[0], spec[1]
            got = dominant_hz(s, sr, at_ms, window_ms=spec[2] if len(spec) > 2 else 20)
            track.append(f"{at_ms}:{got:.0f}" if got else f"{at_ms}:-")
            if got is None or abs(got - want) / want > 0.06:
                problems.append(f"pitch@{at_ms}ms {got and round(got)} != ~{want}")
        if name == "cancel":
            early, late = centroid_hz(s, sr, 15), centroid_hz(s, sr, 110)
            track.append(f"centroid {early:.0f}->{late:.0f}")
            if not early > late * 1.4:
                problems.append("swish doesn't sweep down")
        if (sr, ch, width) != (48000, 1, 2):
            problems.append(f"format {sr}/{ch}ch/{width * 8}bit")
        if length_ms > max_ms:
            problems.append(f"length {length_ms:.0f} > {max_ms} ms")
        if abs(peak - peak_target) > 0.6:
            problems.append(f"peak {peak:.1f} != {peak_target}")
        onset = max(abs(v) for v in s[:24])
        tail = max(abs(v) for v in s[-24:])
        if onset > 0.02 or tail > 0.01:
            problems.append(f"click risk (onset {onset:.3f}, tail {tail:.3f})")
        status = "PASS" if not problems else "FAIL " + "; ".join(problems)
        failures += bool(problems)
        fmt = f"{sr // 1000}k/{ch}ch/{width * 8}b"
        print(f"{name:8s} {fmt:14s} {length_ms:5.0f}ms {peak:6.1f} {db(rms10):6.1f}   {' '.join(track):28s} {note:28s} {status}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
