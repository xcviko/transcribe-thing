#!/usr/bin/env python3
"""analyze-sounds.py: check transcribe-thing's UI sounds against their recipes (standard library only).

Usage:
  python3 scripts/analyze-sounds.py [--set NAME] [sounds_dir] [--png out.png]   check mode (dir: Resources/Sounds)
  python3 scripts/analyze-sounds.py --measure [--recursive] PATH ...   measurement tables for any WAVs / folders
  python3 scripts/analyze-sounds.py [--ref LABEL=DIR ...] --compare LABEL=DIR ...
                                                                       the same tables grouped by cue, a row per set

Measurement mode (--measure / --compare) reads any PCM WAV (16/24/32-bit int or 32-bit float, any rate, stereo is
mixed to mono) and prints Markdown tables; nothing but numbers is written. See measure() for the definitions.
--measure lists identical files once. --compare looks each cue up as DIR/<cue>.wav; --ref sets (someone else's
sounds, measured for comparison only) also try the file names in ALIASES. --compare sets get generic checks
(48 kHz mono 16-bit, target peak, click-free end, start <= 120 ms) and set the exit status.

Check mode, per WAV, reports:
  len       duration (ms)                     peak   sample peak (dBFS)
  rms10     loudest 10 ms RMS (dBFS)          LUFS   max momentary loudness (BS.1770 K-weighting, 400 ms)
  cent      spectral centroid of the whole-file magnitude spectrum (bins > 80 dB down ignored)
  >3k       energy above 3 kHz relative to the loudest 1/3-octave band (dB; must be <= -24)
  atk       10-90 % rise time of each hit's envelope (Hilbert magnitude, 1 ms smoothing)
  tau       each hit's effective decay time constant (exp(-t/tau) fitted to the first 30 dB of its decay)
  tail      level of the last 25 ms relative to the peak (the natural decay is over before the fade)
  dominant  the three strongest spectral peaks (Hz, dB relative to the strongest)
plus a pitch track at recipe-specific windows. Everything is checked against EXPECT_SETS[set] below, where set is
--set NAME or else gen-sounds.py's DEFAULT_SET (so switching the shipped set is one line there); the exit status
is non-zero when any check fails. With --png, it also renders waveform + dB envelope and a log-frequency
spectrogram per sound into one PNG (written with zlib, no third-party modules).
"""
import cmath
import hashlib
import math
import os
import re
import struct
import sys
import wave
import zlib

# Per set (gen-sounds.py --set), per sound: max length (ms), target peak (dBFS), max centroid (Hz), hit onsets (ms),
#       max tau per hit (ms), pitch checks (window start ms, expected Hz, window ms), falls (early window ms, late
#       window ms, window ms): the dominant pitch in the early window must be >= 6 % above the late one.
EXPECT_SETS = {
    "current": {
        "start": dict(max_ms=150, peak=-11, cent=700, hits=(0,), tau=45, pitch=((25, 470, 25),), note="one woody tok"),
        "stop": dict(max_ms=170, peak=-11, cent=700, hits=(0,), tau=45, pitch=((25, 340, 25),),
                     falls=((2, 50, 14),), note="duller tok, sagging"),
        "lock": dict(max_ms=180, peak=-11, cent=700, hits=(0, 70), tau=40, pitch=((25, 440, 25), (95, 523, 25)),
                     note="tok-tok, second higher"),
        "paste": dict(max_ms=50, peak=-19, cent=900, hits=(0,), tau=20, pitch=(), falls=((0, 12, 8),),
                      note="tiny mouth pop, quietest"),
        "cancel": dict(max_ms=160, peak=-17, cent=700, hits=(0,), tau=45, pitch=(), falls=((0, 40, 16),),
                       note="low tuk gliding down"),
        "alert": dict(max_ms=450, peak=-11, cent=900, hits=(0, 140), tau=130,
                      pitch=((10, 262, 40), (160, 330, 40)), note="two soft wood notes up"),
        "error": dict(max_ms=350, peak=-13, cent=700, hits=(0, 125), tau=50, pitch=((25, 233, 40), (150, 196, 40)),
                      note="two muted knocks down"),
        "success": dict(max_ms=500, peak=-11, cent=900, hits=(0, 65, 130), tau=130,
                        pitch=((8, 262, 40), (75, 330, 40), (150, 392, 40)), note="low wood arpeggio C E G"),
    },
    "A": {
        "start": dict(max_ms=90, peak=-11, cent=450, hits=(0,), tau=20, pitch=((25, 175, 20),),
                      falls=((0, 25, 10),), note="tongue tok 250->175"),
        "stop": dict(max_ms=100, peak=-11, cent=400, hits=(0,), tau=22, pitch=((30, 135, 20),),
                     falls=((0, 30, 10),), note="lower tongue tok 200->135"),
        "lock": dict(max_ms=140, peak=-11, cent=450, hits=(0, 55), tau=15, pitch=((20, 160, 20), (80, 185, 20)),
                     note="tk-tok, second higher"),
        "paste": dict(max_ms=50, peak=-19, cent=500, hits=(0,), tau=10, pitch=(), falls=((0, 14, 10),),
                      note="tiny pop 280->150, quietest"),
        "cancel": dict(max_ms=110, peak=-17, cent=450, hits=(0,), tau=30, pitch=(), falls=((0, 40, 16),),
                       note="pop sliding 230->120"),
        "alert": dict(max_ms=280, peak=-11, cent=450, hits=(0, 110), tau=35,
                      pitch=((20, 196, 40), (130, 247, 40)), note="two pitched pops G3 B3"),
        "error": dict(max_ms=240, peak=-13, cent=400, hits=(0, 105), tau=25, pitch=((20, 140, 40), (125, 124, 40)),
                      note="two low pops down"),
        "success": dict(max_ms=300, peak=-11, cent=450, hits=(0, 60, 120), tau=40,
                        pitch=((10, 196, 40), (70, 247, 40), (130, 294, 40)), note="pops G3 B3 D4"),
    },
    "B": {
        "start": dict(max_ms=100, peak=-11, cent=450, hits=(0,), tau=25, pitch=((20, 280, 25),),
                      note="low wood block 280 Hz"),
        "stop": dict(max_ms=120, peak=-11, cent=400, hits=(0,), tau=25, pitch=((30, 199, 25),),
                     note="duller block 215 Hz, sagging"),
        "lock": dict(max_ms=150, peak=-11, cent=450, hits=(0, 60), tau=20, pitch=((20, 245, 25), (80, 290, 25)),
                     note="tok-tok, second higher"),
        "paste": dict(max_ms=50, peak=-19, cent=500, hits=(0,), tau=10, pitch=((3, 240, 15),),
                      note="tiny wood tick, quietest"),
        "cancel": dict(max_ms=120, peak=-17, cent=400, hits=(0,), tau=30, pitch=(), falls=((0, 40, 16),),
                       note="soft knock sagging down"),
        "alert": dict(max_ms=320, peak=-11, cent=400, hits=(0, 130), tau=60,
                      pitch=((20, 175, 40), (150, 220, 40)), note="two low wood notes F3 A3"),
        "error": dict(max_ms=260, peak=-13, cent=400, hits=(0, 115), tau=30, pitch=((20, 185, 40), (135, 156, 40)),
                      note="two muted knocks down"),
        "success": dict(max_ms=340, peak=-11, cent=400, hits=(0, 60, 120), tau=60,
                        pitch=((10, 175, 40), (70, 220, 40), (130, 262, 40)), note="wood arpeggio F3 A3 C4"),
    },
    "C": {
        "start": dict(max_ms=120, peak=-11, cent=450, hits=(0, 20), tau=20, pitch=((25, 350, 20),),
                      note="grace, then tok 350 Hz"),
        "stop": dict(max_ms=160, peak=-11, cent=400, hits=(0, 36), tau=20, pitch=((40, 233, 25),),
                     note="grace, then tok 233 Hz"),
        "lock": dict(max_ms=150, peak=-11, cent=600, hits=(0, 60), tau=15, pitch=(), falls=((60, 80, 10),),
                     note="two falling mouth pops"),
        "paste": dict(max_ms=50, peak=-19, cent=550, hits=(0,), tau=10, pitch=(), falls=((0, 12, 8),),
                      note="tiny pop 330->140, quietest"),
        "cancel": dict(max_ms=110, peak=-17, cent=500, hits=(0,), tau=25, pitch=(), falls=((0, 40, 16),),
                       note="pop sliding 360->130"),
        "alert": dict(max_ms=340, peak=-11, cent=400, hits=(0, 60), tau=90,
                      pitch=((10, 196, 40), (90, 294, 40)), note="two toks up G3 D4"),
        "error": dict(max_ms=310, peak=-13, cent=400, hits=(0, 125), tau=60, pitch=((20, 220, 40), (150, 147, 40)),
                      note="two toks down A3 D3"),
        "success": dict(max_ms=420, peak=-11, cent=400, hits=(0, 70, 140), tau=110,
                        pitch=((10, 196, 40), (80, 247, 40), (150, 294, 40)), note="toks G3 B3 D4"),
    },
}
EXPECT = EXPECT_SETS["current"]
HF_LIMIT_DB = -24.0
TAIL_LIMIT_DB = -24.0
ATTACK_LIMIT_MS = 5.0


def read(path):
    with wave.open(path, "rb") as w:
        sr, ch, width, n = w.getframerate(), w.getnchannels(), w.getsampwidth(), w.getnframes()
        raw = w.readframes(n)
    samples = [v / 32768 for v in struct.unpack("<%dh" % (len(raw) // 2), raw)]
    return sr, ch, width, samples


def read_any(path):
    """Any RIFF/WAVE PCM file (16/24/32-bit int, 32-bit float, plain or WAVE_FORMAT_EXTENSIBLE) ->
    (sample rate, channels, bits, 'int'|'float', mono samples in -1..1). Stereo is averaged to mono."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValueError(f"{path}: not a RIFF/WAVE file")
    pos, fmt, pcm = 12, None, None
    while pos + 8 <= len(data):
        tag, size = data[pos:pos + 4], struct.unpack("<I", data[pos + 4:pos + 8])[0]
        body = data[pos + 8:pos + 8 + size]
        if tag == b"fmt ":
            fmt = body
        elif tag == b"data":
            pcm = body
        pos += 8 + size + (size & 1)
    if fmt is None or pcm is None:
        raise ValueError(f"{path}: missing fmt or data chunk")
    code, ch, sr = struct.unpack("<HHI", fmt[:8])
    bits = struct.unpack("<H", fmt[14:16])[0]
    if code == 0xFFFE:
        code = struct.unpack("<H", fmt[24:26])[0]
    kind = "float" if code == 3 else "int"
    width = bits // 8
    count = len(pcm) // width
    if kind == "float" and bits == 32:
        vals = struct.unpack("<%df" % count, pcm[:count * 4])
    elif bits == 16:
        vals = [v / 32768 for v in struct.unpack("<%dh" % count, pcm[:count * 2])]
    elif bits == 24:
        vals = []
        for i in range(0, count * 3, 3):
            v = pcm[i] | (pcm[i + 1] << 8) | (pcm[i + 2] << 16)
            vals.append((v - (1 << 24) if v & 0x800000 else v) / 8388608)
    elif bits == 32:
        vals = [v / 2147483648 for v in struct.unpack("<%di" % count, pcm[:count * 4])]
    else:
        raise ValueError(f"{path}: unsupported format {code}/{bits}-bit")
    frames = len(vals) // ch
    mono = [sum(vals[i * ch:(i + 1) * ch]) / ch for i in range(frames)] if ch > 1 else list(vals)
    return sr, ch, bits, kind, mono


def db(x):
    return 20 * math.log10(max(x, 1e-12))


# ------------------------------------------------------------------------------------------------- DSP

_TWIDDLES = {}


def fft(values, inverse=False):
    """Iterative radix-2 FFT (len must be a power of two)."""
    a = [complex(v) for v in values]
    n = len(a)
    j = 0
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j |= bit
        if i < j:
            a[i], a[j] = a[j], a[i]
    size = 2
    sign = 1 if inverse else -1
    while size <= n:
        half = size // 2
        key = (size, sign)
        tw = _TWIDDLES.get(key)
        if tw is None:
            tw = [cmath.exp(sign * 2j * math.pi * k / size) for k in range(half)]
            _TWIDDLES[key] = tw
        for start in range(0, n, size):
            for k in range(half):
                u = a[start + k]
                v = a[start + k + half] * tw[k]
                a[start + k] = u + v
                a[start + k + half] = u - v
        size *= 2
    if inverse:
        a = [v / n for v in a]
    return a


def next_pow2(n):
    p = 1
    while p < n:
        p *= 2
    return p


def envelope(samples, sr, smooth_ms=1.0):
    """Hilbert magnitude (analytic signal via FFT), then a centred moving average."""
    n = len(samples)
    size = next_pow2(2 * n)
    spec = fft(samples + [0.0] * (size - n))
    h = [0.0] * size
    h[0] = 1.0
    h[size // 2] = 1.0
    for k in range(1, size // 2):
        h[k] = 2.0
    analytic = fft([s * w for s, w in zip(spec, h)], inverse=True)[:n]
    mag = [abs(v) for v in analytic]
    half = max(1, int(smooth_ms * sr / 1000) // 2)
    prefix = [0.0]
    for v in mag:
        prefix.append(prefix[-1] + v)
    return [(prefix[min(n, i + half + 1)] - prefix[max(0, i - half)]) / (min(n, i + half + 1) - max(0, i - half))
            for i in range(n)]


def spectrum(samples, sr, min_size=16384):
    """Whole-file magnitude spectrum (rectangular window: the sounds start and end at zero)."""
    size = max(min_size, next_pow2(len(samples)))
    mags = [abs(v) for v in fft(samples + [0.0] * (size - len(samples)))[: size // 2]]
    return mags, sr / size


def dominant_hz(samples, sr, start_ms, window_ms=20, size=8192, lo_hz=100):
    start = int(start_ms * sr / 1000)
    seg = samples[start:start + int(window_ms * sr / 1000)]
    if len(seg) < 64:
        return None
    hann = [0.5 - 0.5 * math.cos(2 * math.pi * i / (len(seg) - 1)) for i in range(len(seg))]
    spec = [abs(v) for v in fft([s * w for s, w in zip(seg, hann)] + [0.0] * (size - len(seg)))[: size // 2]]
    lo = int(lo_hz * size / sr)
    k = max(range(lo, len(spec) - 1), key=lambda i: spec[i])
    a, b, c = spec[k - 1], spec[k], spec[k + 1]
    denom = a - 2 * b + c
    shift = 0.5 * (a - c) / denom if denom else 0.0
    return (k + shift) * sr / size


def k_weighted_momentary_max(samples, sr):
    """Max momentary loudness (LUFS): BS.1770 K-weighting, 400 ms windows, 10 ms hop. The two filter stages are
    designed for `sr` from their analog prototypes (at 48 kHz this reproduces the published coefficients)."""

    def biquad(x, b, a):
        x1 = x2 = y1 = y2 = 0.0
        out = []
        for v in x:
            y = b[0] * v + b[1] * x1 + b[2] * x2 - a[1] * y1 - a[2] * y2
            x2, x1, y2, y1 = x1, v, y1, y
            out.append(y)
        return out

    padded = samples + [0.0] * int(0.4 * sr)
    k = math.tan(math.pi * 1681.974450955533 / sr)  # stage 1: high shelf, +4 dB
    q, vh = 0.7071752369554196, 10 ** (3.999843853973347 / 20)
    vb = vh ** 0.4996667741545416
    a0 = 1 + k / q + k * k
    shelf_b = ((vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0)
    shelf_a = (1.0, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0)
    k = math.tan(math.pi * 38.13547087602444 / sr)  # stage 2: RLB high-pass
    q = 0.5003270373238773
    a0 = 1 + k / q + k * k
    y = biquad(padded, shelf_b, shelf_a)
    y = biquad(y, (1.0, -2.0, 1.0), (1.0, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0))
    sq = [v * v for v in y]
    win, hop = int(0.4 * sr), int(0.01 * sr)
    prefix = [0.0]
    for v in sq:
        prefix.append(prefix[-1] + v)
    best = max((prefix[i + win] - prefix[i]) / win for i in range(0, max(1, len(sq) - win), hop))
    return -0.691 + 10 * math.log10(max(best, 1e-20))


def third_octave_bands():
    return [1000 * 2 ** (k / 3) for k in range(-16, 14)]  # 25 Hz .. 20 kHz


def analyze(samples, sr, spec_cfg):
    n = len(samples)
    pk = max(abs(v) for v in samples)
    win = int(0.010 * sr)
    rms10 = max(math.sqrt(sum(v * v for v in samples[i:i + win]) / win) for i in range(0, max(1, n - win), win // 2))
    mags, df = spectrum(samples, sr)
    top = max(mags)
    floor = top * 10 ** (-80 / 20)
    num = den = 0.0
    for k, m in enumerate(mags):
        f = k * df
        if f >= 20 and m >= floor:
            num += f * m
            den += m
    centroid = num / den if den else 0.0
    power = [m * m for m in mags]
    bands = []
    for fc in third_octave_bands():
        lo, hi = fc * 2 ** (-1 / 6), fc * 2 ** (1 / 6)
        bands.append((sum(power[int(lo / df) + 1:int(hi / df) + 1]), fc))
    peak_band, peak_fc = max(bands)
    hf = sum(power[int(3000 / df) + 1:])
    hf_db = 10 * math.log10(max(hf, 1e-30) / max(peak_band, 1e-30))
    # Dominant peaks: local maxima above 60 Hz, at least a quarter-octave apart.
    maxima = [k for k in range(int(60 / df) + 1, len(mags) - 1) if mags[k] >= mags[k - 1] and mags[k] > mags[k + 1]]
    maxima.sort(key=lambda k: -mags[k])
    chosen = []
    for k in maxima:
        if all(abs(math.log2(k / c)) > 0.25 for c in chosen):
            chosen.append(k)
        if len(chosen) == 3:
            break
    dominant = [(k * df, db(mags[k] / top)) for k in chosen]
    env = envelope(samples, sr)
    ms = sr / 1000
    hits = []
    onsets = list(spec_cfg.get("hits", (0,))) if spec_cfg else [0]
    for idx, onset in enumerate(onsets):
        o = int(onset * ms)
        end = int(onsets[idx + 1] * ms) if idx + 1 < len(onsets) else n
        # Rise measured from the level already ringing at the onset (earlier hits), within 12 ms.
        # The hit's peak is its first local maximum within 1.5 dB of the window's maximum, so beating with
        # notes that are still ringing doesn't count as a slow attack.
        search = range(o, min(end, o + int(12 * ms)))
        top = max(env[i] for i in search)
        p = next((i for i in search if env[i] >= top * 10 ** (-1.5 / 20) and env[i] >= env[i + 1]),
                 max(search, key=lambda i: env[i]))
        pv = env[p]
        base = env[o] if o > 0 else 0.0
        t10 = next(i for i in range(o, p + 1) if env[i] >= base + 0.1 * (pv - base))
        t90 = next(i for i in range(o, p + 1) if env[i] >= base + 0.9 * (pv - base))
        xs, ys = [], []
        for i in range(p + int(1 * ms), end):
            level = db(env[i] / pv)
            if level < -30:
                break
            xs.append(i / ms)
            ys.append(level)
        tau = None
        if len(xs) > int(3 * ms):
            mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
            slope = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sum((x - mx) ** 2 for x in xs)
            tau = -20 / math.log(10) / slope if slope < 0 else float("inf")
        hits.append(dict(onset=onset, attack=(t90 - t10) / ms, peak_ms=p / ms, tau=tau))
    tail = db(max(abs(v) for v in samples[-int(0.025 * sr):]) / pk)
    return dict(length_ms=n / ms, peak=db(pk), rms10=db(rms10), lufs=k_weighted_momentary_max(samples, sr),
                centroid=centroid, hf_db=hf_db, peak_band=peak_fc, dominant=dominant, hits=hits, tail=tail, env=env)


# ----------------------------------------------------------------------------------------- measurement

CUES = tuple(EXPECT)
TARGET_PEAK = {"paste": -19.0, "cancel": -17.0, "error": -13.0}  # everything else -11 dBFS
START_MAX_MS = 120.0
OCTAVES = (63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000)

# Other apps' file names for the same cues, tried by --ref after <cue>.wav. Wispr Flow's default set
# (selectedSoundFolder = null) is the bundle's root dictation-*/popo-lock/paste files plus notifv1/ notifications.
ALIASES = {
    "start": ("dictation-start.wav",),
    "stop": ("dictation-stop.wav",),
    "lock": ("popo-lock.wav",),
    "paste": ("paste.wav",),
    "cancel": (),
    "alert": ("notifv1/alert.wav", "alert.wav"),
    "error": ("notifv1/error.wav", "error.wav"),
    "success": ("notifv1/success.wav", "success.wav"),
}


def hann(n):
    return [0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1)) for i in range(n)] if n > 1 else [1.0] * n


def windowed_power(seg, sr, min_size=4096):
    """Hann-windowed power spectrum of `seg`, zero-padded to a power of two >= min_size -> (power, Hz per bin)."""
    size = max(min_size, next_pow2(len(seg)))
    w = hann(len(seg))
    spec = fft([a * b for a, b in zip(seg, w)] + [0.0] * (size - len(seg)))
    return [abs(v) ** 2 for v in spec[: size // 2]], sr / size


def centroid_of(power, df, floor_db=-80.0):
    """Magnitude-weighted spectral centroid above 20 Hz, ignoring bins more than 80 dB below the strongest."""
    mags = [math.sqrt(p) for p in power]
    top = max(mags) or 1e-12
    floor = top * 10 ** (floor_db / 20)
    num = den = 0.0
    for k, m in enumerate(mags):
        f = k * df
        if f >= 20 and m >= floor:
            num += f * m
            den += m
    return num / den if den else 0.0


def flatness_db(seg, sr, lo=100.0, hi=8000.0):
    """Spectral flatness (geometric / arithmetic mean of power, lo..hi Hz, bins floored 60 dB below the top) in
    dB: about -2.5 for white noise (a click, breath, contact noise), -25 or less for a clear tone."""
    if len(seg) < 48:
        return None
    power, df = windowed_power(seg, sr)
    band = power[int(lo / df) + 1:int(min(hi, sr / 2 - 1) / df) + 1]
    top = max(band)
    if top <= 0:
        return None
    vals = [max(v, top * 1e-6) for v in band]
    geo = math.exp(sum(math.log(v) for v in vals) / len(vals))
    return 10 * math.log10(geo / (sum(vals) / len(vals)))


def detect_hits(env, sr, floor_db=-35.0, rise_db=4.0, rise_ms=5.0, look_ms=30.0, gap_ms=20.0):
    """Onsets: the envelope rises >= rise_db within rise_ms, the new peak is within 35 dB of the file's maximum and
    >= 2 dB above everything in the preceding 3..look_ms ms (so beating between ringing modes isn't a hit).
    Returns [(onset index at 10 % of the rise, index of the hit's maximum)]."""
    ms = sr / 1000
    n = len(env)
    gmax = max(env) or 1e-12
    level = [db(v / gmax) for v in env]
    r, hop = int(rise_ms * ms), max(1, int(0.25 * ms))
    hits = []
    i = 0
    while i < n:
        before = level[i - r] if i >= r else -120.0
        if level[i] >= floor_db and level[i] - before >= rise_db:
            end = min(n, i + int(15 * ms))
            p = max(range(i, end), key=lambda k: env[k])
            while p + 1 < n and env[p + 1] >= env[p]:
                p += 1
            lo, hi = max(0, i - int(look_ms * ms)), i - int(3 * ms)
            prev = max(level[lo:hi]) if hi > lo else -120.0
            if level[p] >= prev + 2.0:
                b = min(range(max(0, i - r), i + 1), key=lambda k: env[k])
                t10 = next(k for k in range(b, p + 1) if env[k] >= env[b] + 0.1 * (env[p] - env[b]))
                hits.append((t10, p))
                i = p + int(gap_ms * ms)
                continue
        i += hop
    return hits


def measure(samples, sr):
    """Everything the tables print, for one mono signal:
      len     file length (ms)                      lead    silence before the first onset (ms)
      dur40   first onset -> last moment the envelope is within 40 dB of its maximum (ms)
      peak    sample peak (dBFS)                    rms10   loudest 10 ms RMS (dBFS)
      LUFS    max momentary loudness of the mono mix (BS.1770, 400 ms windows)
      cent    spectral centroid of the whole sound  cent20  centroid of the first 20 ms after the first onset
      roll85  frequency below which 85 % of the power lies
      oct     power per octave band (63 Hz .. 16 kHz), dB relative to the total
      hits    auto-detected onsets (ms after the first); per hit: atk = 10-90 % rise (ms), tau = exp decay constant
              fitted to the first 30 dB of the decay (ms), t40 = peak -> -40 dB (ms; '>' = next hit or file end first)
      flat    spectral flatness of the first 5 ms after the first onset / of 5-50 ms (dB; near -3 = noisy click,
              below -25 = tonal ring)
      dom     three strongest spectral peaks, Hz (dB relative to the strongest)
      pitch   dominant frequency (20 ms Hann) every `step` ms from the first onset while within 30 dB of the max"""
    ms = sr / 1000
    n_total = len(samples)
    pk = max(abs(v) for v in samples) or 1e-12
    # Trim to the audible part (-60 dB) plus 5 ms so long, padded files stay cheap for the pure-Python FFT.
    first = next(i for i, v in enumerate(samples) if abs(v) >= pk * 1e-3)
    last = n_total - 1 - next(i for i, v in enumerate(reversed(samples)) if abs(v) >= pk * 1e-3)
    t0 = max(0, first - int(5 * ms))
    s = samples[t0:min(n_total, last + int(5 * ms))]
    n = len(s)
    env = envelope(s, sr)
    gmax = max(env) or 1e-12
    hits = detect_hits(env, sr) or [(0, max(range(n), key=lambda k: env[k]))]
    onset = hits[0][0]
    active_end = max(i for i in range(n) if env[i] >= gmax * 0.01)
    win = int(0.010 * sr)
    rms10 = max(math.sqrt(sum(v * v for v in s[i:i + win]) / win) for i in range(0, max(1, n - win), max(1, win // 4)))

    mags, df = spectrum(s, sr)
    power = [m * m for m in mags]
    total = sum(power[int(20 / df) + 1:]) or 1e-30
    centroid = centroid_of(power, df)
    acc, roll85 = 0.0, 0.0
    for k in range(int(20 / df) + 1, len(power)):
        acc += power[k]
        if acc >= 0.85 * total:
            roll85 = k * df
            break
    octs = []
    for fc in OCTAVES:
        lo, hi = fc / math.sqrt(2), min(fc * math.sqrt(2), sr / 2)
        e = sum(power[int(lo / df) + 1:int(hi / df) + 1]) if lo < sr / 2 else 0.0
        octs.append(10 * math.log10(max(e, 1e-30) / total))
    p20, df20 = windowed_power(s[onset:onset + int(20 * ms)], sr)
    cent20 = centroid_of(p20, df20)
    maxima = [k for k in range(int(60 / df) + 1, len(mags) - 1) if mags[k] >= mags[k - 1] and mags[k] > mags[k + 1]]
    maxima.sort(key=lambda k: -mags[k])
    chosen = []
    for k in maxima:
        if all(abs(math.log2(k / c)) > 0.25 for c in chosen):
            chosen.append(k)
        if len(chosen) == 3:
            break
    top = max(mags) or 1e-12
    dominant = [(k * df, db(mags[k] / top)) for k in chosen]

    per_hit = []
    for idx, (t10, p_max) in enumerate(hits):
        end = hits[idx + 1][0] if idx + 1 < len(hits) else n
        window_top = max(env[t10:min(end, t10 + int(12 * ms))])
        p = next((i for i in range(t10, end - 1) if env[i] >= window_top * 10 ** (-1.5 / 20) and env[i] >= env[i + 1]),
                 p_max)
        lo_v = min(env[max(0, t10 - int(2 * ms)):t10 + 1])
        t_a = next(i for i in range(t10 - int(2 * ms) if t10 >= int(2 * ms) else 0, p + 1)
                   if env[i] >= lo_v + 0.1 * (env[p] - lo_v))
        t_b = next(i for i in range(t_a, p + 1) if env[i] >= lo_v + 0.9 * (env[p] - lo_v))
        pv = env[p_max]
        xs, ys = [], []
        t40 = None
        for i in range(p_max + int(1 * ms), end):
            lvl = db(env[i] / pv)
            if lvl < -40:
                t40 = (i - p_max) / ms
                break
            if lvl >= -30:
                xs.append(i / ms)
                ys.append(lvl)
        tau = None
        if len(xs) > int(3 * ms):
            mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
            slope = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sum((x - mx) ** 2 for x in xs)
            tau = -20 / math.log(10) / slope if slope < 0 else float("inf")
        per_hit.append(dict(at=(t10 - onset) / ms, attack=(t_b - t_a) / ms, tau=tau, t40=t40,
                            t40_cut=(end - p_max) / ms))
    next_on = hits[1][0] if len(hits) > 1 else n
    flat5 = flatness_db(s[onset:onset + int(5 * ms)], sr)
    flat_late = flatness_db(s[onset + int(5 * ms):min(next_on, onset + int(50 * ms))], sr)

    dur = (active_end - onset) / ms
    step = 10 if dur <= 150 else 20 if dur <= 400 else 50
    frame_len = int(20 * ms)
    frame_rms = []
    for t in range(onset, active_end, int(step * ms)):
        seg = s[t:t + frame_len]
        frame_rms.append((t, math.sqrt(sum(v * v for v in seg) / max(1, len(seg)))))
    best = max(r for _, r in frame_rms) if frame_rms else 0.0
    track = []
    for t, r in frame_rms:
        if r < best * 10 ** (-30 / 20) or len(track) >= 14:
            continue
        f = dominant_hz(s, sr, t / ms, window_ms=20, lo_hz=60)
        if f:
            track.append(((t - onset) / ms, f))
    return dict(length_ms=n_total / ms, lead_ms=(t0 + onset) / ms, dur40=dur, peak=db(pk), rms10=db(rms10),
                lufs=k_weighted_momentary_max(s, sr), centroid=centroid, cent20=cent20, roll85=roll85, octaves=octs,
                hits=per_hit, flat5=flat5, flat_late=flat_late, dominant=dominant, pitch=track, last=samples[-24:])


def _f(v, fmt="{:.0f}", none="-"):
    return none if v is None else fmt.format(v)


def generic_problems(cue, fmt, m):
    """Checks for our own sets: format, level target, click-free ends, start length."""
    problems = []
    sr, ch, bits, kind = fmt
    if (sr, ch, bits, kind) != (48000, 1, 16, "int"):
        problems.append(f"format {sr}/{ch}ch/{bits}bit")
    want = TARGET_PEAK.get(cue, -11.0)
    if abs(m["peak"] - want) > 0.6:
        problems.append(f"peak {m['peak']:.1f} != {want:.0f}")
    if cue == "start" and m["length_ms"] > START_MAX_MS:
        problems.append(f"start {m['length_ms']:.0f} > {START_MAX_MS:.0f} ms")
    if max(abs(v) for v in m["last"]) > 0.01:
        problems.append("end click risk")
    return problems


def md_tables(rows, first_col="sound"):
    """rows: [(label, fmt, measurement, status or None)] -> three Markdown tables as one string."""
    out = []
    has_status = any(r[3] is not None for r in rows)
    head = (f"| {first_col} | format | len ms | lead | dur40 | peak | rms10 | LUFS | cent | cent20 | roll85 | "
            "hits @ms | atk ms | tau ms | t40 ms | flat 0-5/5-50 ms | dominant Hz (dB) |" + (" check |" if has_status else ""))
    out.append(head)
    out.append("|" + "---|" * (head.count("|") - 1))
    for label, fmt, m, status in rows:
        if m is None:
            out.append(f"| {label} | {status} |")
            continue
        sr, ch, bits, kind = fmt
        hits = m["hits"]
        t40 = "/".join((f"{h['t40']:.0f}" if h["t40"] is not None else f">{h['t40_cut']:.0f}") for h in hits)
        cells = [label, f"{sr / 1000:g}k/{ch}ch/{bits}{'f' if kind == 'float' else ''}", f"{m['length_ms']:.0f}",
                 f"{m['lead_ms']:.0f}", f"{m['dur40']:.0f}", f"{m['peak']:.1f}", f"{m['rms10']:.1f}",
                 _f(m["lufs"], "{:.1f}"), f"{m['centroid']:.0f}", f"{m['cent20']:.0f}", f"{m['roll85']:.0f}",
                 f"{len(hits)}: " + "/".join(f"{h['at']:.0f}" for h in hits),
                 "/".join(f"{h['attack']:.1f}" for h in hits),
                 "/".join(_f(h["tau"] if h["tau"] is None else min(h["tau"], 9999)) for h in hits), t40,
                 f"{_f(m['flat5'])}/{_f(m['flat_late'])}",
                 " ".join(f"{f:.0f}({d:.0f})" for f, d in m["dominant"])]
        if has_status:
            cells.append(status or "")
        out.append("| " + " | ".join(cells) + " |")
    out.append("")
    head = f"| {first_col} | " + " | ".join(f"{fc // 1000}k" if fc >= 1000 else str(fc) for fc in OCTAVES) + " |"
    out.append("Octave-band power, dB relative to the whole sound:")
    out.append("")
    out.append(head)
    out.append("|" + "---|" * (len(OCTAVES) + 1))
    for label, fmt, m, status in rows:
        if m is not None:
            out.append(f"| {label} | " + " | ".join(f"{v:.0f}" if v > -99 else "-" for v in m["octaves"]) + " |")
    out.append("")
    out.append("Pitch track (dominant Hz at ms after the first onset):")
    out.append("")
    out.append(f"| {first_col} | track |")
    out.append("|---|---|")
    for label, fmt, m, status in rows:
        if m is not None:
            out.append(f"| {label} | " + " ".join(f"{t:.0f}:{f:.0f}" for t, f in m["pitch"]) + " |")
    return "\n".join(out)


def natural_key(text):
    return [int(t) if t.isdigit() else t for t in re.split(r"(\d+)", text)]


def wav_paths(target, recursive):
    """(label, path) for a file, or for every WAV in a folder (our cues first, in cue order; subfolders after,
    naturally sorted, when `recursive`)."""
    if os.path.isfile(target):
        return [(os.path.basename(target), target)]
    order = {f"{c}.wav": i for i, c in enumerate(CUES)}
    found = []
    for dirpath, dirnames, filenames in os.walk(target):
        dirnames.sort(key=natural_key)
        names = sorted((f for f in filenames if f.lower().endswith(".wav")), key=lambda f: (order.get(f, 99), f))
        found += [(os.path.relpath(os.path.join(dirpath, f), target), os.path.join(dirpath, f)) for f in names]
        if not recursive:
            break
    return found


def run_measure(targets, recursive):
    rows = []
    seen = {}
    for target in targets:
        for rel, path in wav_paths(target, recursive):
            label = rel if len(targets) == 1 else os.path.join(os.path.basename(os.path.normpath(target)), rel)
            with open(path, "rb") as f:
                digest = hashlib.sha256(f.read()).hexdigest()
            if digest in seen:
                rows.append((label, None, None, f"identical to {seen[digest]}"))
                continue
            seen[digest] = label
            sr, ch, bits, kind, mono = read_any(path)
            rows.append((label, (sr, ch, bits, kind), measure(mono, sr), None))
            print(f"measured {label}", file=sys.stderr)
    print(md_tables(rows, first_col="file"))
    return 0


def find_cue(folder, cue, aliases):
    for name in (f"{cue}.wav",) + (ALIASES.get(cue, ()) if aliases else ()):
        path = os.path.join(folder, name)
        if os.path.isfile(path):
            return path
    return None


def run_compare(refs, ours):
    """refs/ours: [(label, folder)]; references may use ALIASES, ours get generic_problems() checks."""
    rows = []
    failures = 0
    for cue in CUES:
        for label, folder, is_ref in [(lbl, d, True) for lbl, d in refs] + [(lbl, d, False) for lbl, d in ours]:
            path = find_cue(folder, cue, aliases=is_ref)
            tag = f"{cue} · {label}"
            if path is None:
                rows.append((tag, None, None, "(no such cue)" if is_ref else "MISSING"))
                failures += not is_ref
                continue
            sr, ch, bits, kind, mono = read_any(path)
            m = measure(mono, sr)
            status = None
            if not is_ref:
                problems = generic_problems(cue, (sr, ch, bits, kind), m)
                failures += bool(problems)
                status = "ok" if not problems else "; ".join(problems)
            else:
                status = os.path.relpath(path, folder)
            rows.append((tag, (sr, ch, bits, kind), m, status))
            print(f"measured {tag}", file=sys.stderr)
    print(md_tables(rows, first_col="cue · set"))
    return 1 if failures else 0


# ------------------------------------------------------------------------------------------------- PNG

FONT = {  # 3x5 glyphs, rows top to bottom
    "A": "010101111101101", "B": "110101110101110", "C": "011100100100011", "D": "110101101101110",
    "E": "111100110100111", "F": "111100110100100", "G": "011100101101011", "H": "101101111101101",
    "I": "111010010010111", "J": "001001001101010", "K": "101101110101101", "L": "100100100100111",
    "M": "101111111101101", "N": "110101101101101", "O": "010101101101010", "P": "110101110100100",
    "Q": "010101101110011", "R": "110101110101101", "S": "011100010001110", "T": "111010010010010",
    "U": "101101101101111", "V": "101101101101010", "W": "101101111111101", "X": "101101010101101",
    "Y": "101101010010010", "Z": "111001010100111", "0": "111101101101111", "1": "010110010010111",
    "2": "110001010100111", "3": "110001010001110", "4": "101101111001001", "5": "111100110001110",
    "6": "011100111101111", "7": "111001010010010", "8": "111101111101111", "9": "111101111001110",
    "-": "000000111000000", ".": "000000000000010", ":": "000010000010000", "/": "001001010100100",
    ">": "100010001010100", "(": "010100100100010", ")": "010001001001010", " ": "000000000000000",
    "+": "000010111010000", ",": "000000000010100", "%": "101001010100101", "=": "000111000111000",
}


class Image:
    def __init__(self, width, height, bg=(18, 18, 22)):
        self.w, self.h = width, height
        self.px = bytearray(bytes(bg) * (width * height))

    def set(self, x, y, rgb):
        if 0 <= x < self.w and 0 <= y < self.h:
            o = (y * self.w + x) * 3
            self.px[o:o + 3] = bytes(rgb)

    def rect(self, x0, y0, x1, y1, rgb):
        for y in range(max(0, y0), min(self.h, y1)):
            for x in range(max(0, x0), min(self.w, x1)):
                self.set(x, y, rgb)

    def line(self, x0, y0, x1, y1, rgb):
        dx, dy = abs(x1 - x0), -abs(y1 - y0)
        sx, sy = (1 if x0 < x1 else -1), (1 if y0 < y1 else -1)
        err = dx + dy
        while True:
            self.set(x0, y0, rgb)
            if x0 == x1 and y0 == y1:
                return
            e2 = 2 * err
            if e2 >= dy:
                err += dy
                x0 += sx
            if e2 <= dx:
                err += dx
                y0 += sy

    def text(self, x, y, s, rgb, scale=2):
        for ch in s.upper():
            glyph = FONT.get(ch, FONT[" "])
            for r in range(5):
                for c in range(3):
                    if glyph[r * 3 + c] == "1":
                        self.rect(x + c * scale, y + r * scale, x + (c + 1) * scale, y + (r + 1) * scale, rgb)
            x += 4 * scale

    def save(self, path):
        raw = b"".join(b"\x00" + bytes(self.px[y * self.w * 3:(y + 1) * self.w * 3]) for y in range(self.h))

        def chunk(tag, data):
            return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

        png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", self.w, self.h, 8, 2, 0, 0, 0))
        png += chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
        with open(path, "wb") as f:
            f.write(png)


def colormap(v):
    stops = ((0.0, (0, 0, 4)), (0.25, (60, 15, 110)), (0.5, (180, 45, 100)), (0.75, (248, 140, 40)),
             (1.0, (252, 245, 190)))
    v = min(1.0, max(0.0, v))
    for (a, ca), (b, cb) in zip(stops, stops[1:]):
        if v <= b:
            u = (v - a) / (b - a)
            return tuple(int(ca[i] + (cb[i] - ca[i]) * u) for i in range(3))
    return stops[-1][1]


def render_png(path, rows, sr=48000):
    """rows: [(name, samples, result)] -> per sound: waveform + dB envelope (1 px/ms), the first 30 ms zoomed
    (8 px/ms, to see the attack), and a log-frequency spectrogram."""
    label_w, panel_w, zoom_w, panel_h, gap, row_h, head = 150, 520, 240, 96, 16, 112, 34
    width = label_w + 2 * panel_w + zoom_w + 2 * gap + 10
    img = Image(width, head + row_h * len(rows) + 6)
    wx = label_w
    zx = wx + panel_w + gap
    sx = zx + zoom_w + gap
    img.text(wx, 10, "WAVEFORM + ENVELOPE DB 0..-60, 1 PX = 1 MS", (200, 200, 210))
    img.text(zx, 10, "FIRST 30 MS", (200, 200, 210))
    img.text(sx, 10, "SPECTROGRAM 60 HZ - 8 KHZ LOG, 70 DB", (200, 200, 210))
    f_lo, f_hi = 60.0, 8000.0
    win, nfft = 1024, 2048
    hann = [0.5 - 0.5 * math.cos(2 * math.pi * i / (win - 1)) for i in range(win)]
    for r, (name, s, res) in enumerate(rows):
        top = head + r * row_h
        img.text(10, top + 8, name, (240, 240, 245), scale=3)
        img.text(10, top + 34, f"{res['length_ms']:.0f} MS", (160, 160, 170))
        img.text(10, top + 48, f"C {res['centroid']:.0f} HZ", (160, 160, 170))
        img.text(10, top + 62, f"PK {res['peak']:.0f} DB", (160, 160, 170))
        img.rect(wx, top, wx + panel_w, top + panel_h, (30, 30, 36))
        for ms_mark in range(100, panel_w, 100):
            img.rect(wx + ms_mark, top, wx + ms_mark + 1, top + panel_h, (55, 55, 62))
        for level in (-20, -40):
            y = top + int(-level / 60 * (panel_h - 1))
            img.rect(wx, y, wx + panel_w, y + 1, (55, 55, 62))
        pk = max(abs(v) for v in s) or 1e-9
        mid = top + panel_h // 2
        per = sr // 1000
        prev = None
        for x in range(panel_w):
            seg = s[x * per:(x + 1) * per]
            if not seg:
                break
            lo, hi = min(seg) / pk, max(seg) / pk
            img.rect(wx + x, mid - int(hi * (panel_h / 2 - 2)), wx + x + 1, mid - int(lo * (panel_h / 2 - 2)) + 1,
                     (150, 160, 180))
            e = max(res["env"][x * per:(x + 1) * per]) / (max(res["env"]) or 1e-9)
            y = top + int(min(60.0, -db(e)) / 60 * (panel_h - 1))
            if prev is not None:
                img.line(wx + x - 1, prev, wx + x, y, (255, 150, 40))
            prev = y
        # Zoom: the first 30 ms at 8 px/ms (6 samples per column).
        img.rect(zx, top, zx + zoom_w, top + panel_h, (30, 30, 36))
        for ms_mark in range(5, 30, 5):
            img.rect(zx + ms_mark * 8, top, zx + ms_mark * 8 + 1, top + panel_h, (55, 55, 62))
        step = per // 8
        prev = None
        for x in range(zoom_w):
            seg = s[x * step:(x + 1) * step]
            if not seg:
                break
            lo, hi = min(seg) / pk, max(seg) / pk
            y_hi, y_lo = mid - int(hi * (panel_h / 2 - 2)), mid - int(lo * (panel_h / 2 - 2))
            if prev is not None:
                y_hi, y_lo = min(y_hi, prev), max(y_lo, prev)
            img.rect(zx + x, y_hi, zx + x + 1, y_lo + 1, (150, 200, 255))
            prev = mid - int(seg[-1] / pk * (panel_h / 2 - 2))
        # Spectrogram: 21 ms Hann frames every 1 ms, zero-padded to 2048 points.
        frames = []
        padded = [0.0] * (win // 2) + s + [0.0] * (win // 2)
        for x in range(min(panel_w, len(s) // per)):
            seg = padded[x * per:x * per + win]
            spec = fft([a * w for a, w in zip(seg, hann)] + [0.0] * (nfft - win))
            frames.append([abs(v) for v in spec[: nfft // 2]])
        gmax = max(max(f) for f in frames) or 1e-9
        img.rect(sx, top, sx + panel_w, top + panel_h, (0, 0, 4))
        for x, mags in enumerate(frames):
            for y in range(panel_h):
                f = f_lo * (f_hi / f_lo) ** (1 - y / (panel_h - 1))
                pos = f * nfft / sr
                k = int(pos)
                u = pos - k
                m = mags[k] * (1 - u) + mags[k + 1] * u
                img.set(sx + x, top + y, colormap(1 + db(m / gmax) / 70))
        for f_mark, colour in ((250, (90, 90, 110)), (500, (90, 90, 110)), (1000, (90, 90, 110)),
                               (2000, (90, 90, 110)), (3000, (60, 200, 220))):
            y = top + int((1 - math.log(f_mark / f_lo) / math.log(f_hi / f_lo)) * (panel_h - 1))
            for x in range(0, panel_w, 4):
                img.set(sx + x, y, colour)
            if f_mark != 2000:
                label = f"{f_mark // 1000}K" if f_mark >= 1000 else str(f_mark)
                img.text(sx + panel_w - 4 * 2 * len(label) - 4, y - 11, label, colour)
    img.save(path)


# ------------------------------------------------------------------------------------------------ main

def shipped_set(gen_path):
    """DEFAULT_SET from gen-sounds.py (the set Resources/Sounds is generated from), or "current"."""
    try:
        with open(gen_path) as f:
            m = re.search(r'^DEFAULT_SET = "([^"]+)"', f.read(), re.M)
        return m.group(1) if m else "current"
    except OSError:
        return "current"


def parse_sets(tokens):
    sets = []
    for tok in tokens:
        label, sep, folder = tok.partition("=")
        if not sep:
            label, folder = os.path.basename(os.path.normpath(tok)), tok
        sets.append((label, folder))
    return sets


def main():
    args = sys.argv[1:]
    if "--measure" in args:
        recursive = "--recursive" in args
        targets = [a for a in args if a not in ("--measure", "--recursive")]
        return run_measure(targets, recursive)
    if "--compare" in args or "--ref" in args:
        refs, ours, current = [], [], None
        for a in args:
            if a in ("--compare", "--ref"):
                current = ours if a == "--compare" else refs
            elif current is not None:
                current.append(a)
        return run_compare(parse_sets(refs), parse_sets(ours))
    png = None
    if "--png" in args:
        i = args.index("--png")
        png = args[i + 1]
        del args[i:i + 2]
    chosen = None
    if "--set" in args:
        i = args.index("--set")
        chosen = args[i + 1] if i + 1 < len(args) else ""
        del args[i:i + 2]
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if chosen is None:
        chosen = shipped_set(os.path.join(root, "scripts", "gen-sounds.py"))
    if chosen not in EXPECT_SETS:
        print(f"unknown set {chosen!r}; choose one of: {', '.join(EXPECT_SETS)}")
        return 2
    expect = EXPECT_SETS[chosen]
    folder = args[0] if args else os.path.join(root, "Resources", "Sounds")
    failures = 0
    rows = []
    print(f"set {chosen}: {folder}")
    print(f"{'sound':8s} {'len':>6s} {'peak':>6s} {'rms10':>6s} {'LUFS':>6s} {'cent':>5s} {'>3k':>6s} "
          f"{'atk ms':>9s} {'tau ms':>13s} {'tail':>5s}  {'dominant Hz (dB)':30s} status")
    details = []
    for name, cfg in expect.items():
        path = os.path.join(folder, f"{name}.wav")
        if not os.path.exists(path):
            print(f"{name:8s} MISSING")
            failures += 1
            continue
        sr, ch, width, s = read(path)
        res = analyze(s, sr, cfg)
        rows.append((name, s, res))
        problems = []
        if (sr, ch, width) != (48000, 1, 2):
            problems.append(f"format {sr}/{ch}ch/{width * 8}bit")
        if res["length_ms"] > cfg["max_ms"]:
            problems.append(f"length {res['length_ms']:.0f} > {cfg['max_ms']} ms")
        if abs(res["peak"] - cfg["peak"]) > 0.6:
            problems.append(f"peak {res['peak']:.1f} != {cfg['peak']}")
        if res["centroid"] > cfg["cent"]:
            problems.append(f"centroid {res['centroid']:.0f} > {cfg['cent']} Hz")
        if res["hf_db"] > HF_LIMIT_DB:
            problems.append(f">3 kHz only {res['hf_db']:.1f} dB below peak band")
        if res["tail"] > TAIL_LIMIT_DB:
            problems.append(f"tail {res['tail']:.1f} dB (chopped decay)")
        for h in res["hits"]:
            if h["attack"] > ATTACK_LIMIT_MS:
                problems.append(f"attack {h['attack']:.1f} ms @{h['onset']}")
            if h["tau"] is None or h["tau"] > cfg["tau"]:
                got = "none" if h["tau"] is None else f"{h['tau']:.0f}"
                problems.append(f"tau {got} > {cfg['tau']} ms @{h['onset']}")
        onset = max(abs(v) for v in s[:24])
        end = max(abs(v) for v in s[-24:])
        if onset > 0.02 or end > 0.01 or s[-1] != 0.0:
            problems.append(f"click risk (onset {onset:.3f}, end {end:.3f})")
        track = []
        for at_ms, want, window in cfg.get("pitch", ()):
            got = dominant_hz(s, sr, at_ms, window_ms=window)
            track.append(f"{at_ms}ms:{got:.0f}" if got else f"{at_ms}ms:-")
            if got is None or abs(got - want) / want > 0.06:
                problems.append(f"pitch@{at_ms}ms {got and round(got)} != ~{want}")
        for early_ms, late_ms, window in cfg.get("falls", ()):
            early = dominant_hz(s, sr, early_ms, window_ms=window)
            late = dominant_hz(s, sr, late_ms, window_ms=window)
            track.append(f"glide {early:.0f}->{late:.0f}")
            if not early >= late * 1.06:
                problems.append("pitch doesn't fall")
        failures += bool(problems)
        status = "PASS" if not problems else "FAIL " + "; ".join(problems)
        atk = "/".join(f"{h['attack']:.1f}" for h in res["hits"])
        tau = "/".join(f"{min(h['tau'], 9999):.0f}" if h["tau"] is not None else "-" for h in res["hits"])
        dom = " ".join(f"{f:.0f}({d:.0f})" for f, d in res["dominant"])
        lufs = f"{res['lufs']:.1f}" if res["lufs"] is not None else "-"
        print(f"{name:8s} {res['length_ms']:4.0f}ms {res['peak']:6.1f} {res['rms10']:6.1f} {lufs:>6s} "
              f"{res['centroid']:5.0f} {res['hf_db']:6.1f} {atk:>9s} {tau:>13s} {res['tail']:5.0f}  {dom:30s} {status}")
        details.append(f"  {name:8s} {cfg['note']:26s} peak band {res['peak_band']:.0f} Hz; pitch {' '.join(track)}")
    print("\n".join(details))
    if png:
        render_png(png, rows)
        print(f"wrote {png}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
