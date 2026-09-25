#!/usr/bin/env python3
"""gen-sounds.py: synthesize Murmur's eight original UI sounds (standard library only).

Usage: python3 scripts/gen-sounds.py [out_dir]        (default: Resources/Sounds)

Every file is 48 kHz, mono, 16-bit PCM. Recipes follow SPEC §5.5 / wispr-ux §3.2:
  start    rising glass pluck (880 Hz gliding up 2 semitones), 110 ms
  stop     falling pair 784 -> 587 Hz, 170 ms
  lock     two plucks 70 ms apart (+3 semitones) over a soft 160 Hz thump, 180 ms
  paste    tiny 2.1 kHz tick, the quietest sound, 45 ms
  cancel   soft band-passed "fff" swish sweeping 1.4 kHz -> 350 Hz, 160 ms
  alert    two soft bell tones 523 -> 659 Hz, 420 ms
  error    falling minor third 330 -> 262 Hz with a gentle reed timbre, 320 ms
  success  rising triad 523 / 659 / 784 Hz, bell timbre, 600 ms

Softness rules: raised-cosine attacks (no clicks), exponential decays, higher partials decaying faster,
a gentle low-pass, a very small room on the longer sounds, and conservative peaks (-14 dBFS for most,
-16 for error, -22 for paste, -24 for cancel). Output is deterministic (fixed noise seed).
"""
import math
import os
import random
import struct
import sys
import wave

SR = 48_000


def semitones(freq, steps):
    return freq * 2 ** (steps / 12)


class Canvas:
    def __init__(self, seconds):
        self.n = int(round(seconds * SR))
        self.buf = [0.0] * self.n

    def add(self, start_s, samples, gain=1.0):
        start = int(round(start_s * SR))
        for i, x in enumerate(samples):
            j = start + i
            if 0 <= j < self.n:
                self.buf[j] += gain * x


def envelope(n, attack, tau, hold=0.0):
    """Raised-cosine attack, optional hold, then an exponential tail."""
    out = []
    for i in range(n):
        t = i / SR
        if t < attack:
            out.append(0.5 - 0.5 * math.cos(math.pi * t / attack))
        elif t < attack + hold:
            out.append(1.0)
        else:
            out.append(math.exp(-(t - attack - hold) / tau))
    return out


def tone(freq, seconds, attack, tau, partials=((1.0, 1.0),), glide_to=None, glide_time=0.03,
         partial_damping=5.0, detune_cents=0.0):
    """A plucked/struck voice. `glide_to` bends the pitch exponentially towards a target frequency;
    upper partials decay `partial_damping` times faster per unit of ratio, like a real struck object."""
    n = int(round(seconds * SR))
    env = envelope(n, attack, tau)
    det = 2 ** (detune_cents / 1200)
    phases = [0.0] * len(partials)
    out = []
    for i in range(n):
        t = i / SR
        f = freq
        if glide_to is not None:
            f = glide_to + (freq - glide_to) * math.exp(-t / (glide_time / 3))
        f *= det
        s = 0.0
        for k, (ratio, amp) in enumerate(partials):
            phases[k] += 2 * math.pi * f * ratio / SR
            s += amp * math.sin(phases[k]) * math.exp(-t * (ratio - 1) * partial_damping)
        out.append(env[i] * s)
    return out


def noise_burst(seconds, highpass_hz, seed, attack=0.0004):
    rng = random.Random(seed)
    n = int(round(seconds * SR))
    raw = [rng.uniform(-1, 1) for _ in range(n)]
    filtered = highpass(raw, highpass_hz)
    out = []
    for i, x in enumerate(filtered):
        t = i / SR
        a = min(1.0, t / attack) if attack > 0 else 1.0
        # Hann-shaped tail so the tick never clicks at its end.
        w = 0.5 + 0.5 * math.cos(math.pi * i / max(1, n - 1))
        out.append(x * a * w)
    return out


def lowpass(samples, cutoff):
    a = math.exp(-2 * math.pi * cutoff / SR)
    y = 0.0
    out = []
    for x in samples:
        y = (1 - a) * x + a * y
        out.append(y)
    return out


def highpass(samples, cutoff):
    a = math.exp(-2 * math.pi * cutoff / SR)
    y = 0.0
    prev = 0.0
    out = []
    for x in samples:
        y = a * (y + x - prev)
        prev = x
        out.append(y)
    return out


def swept_bandpass(samples, f_start, f_end, sweep_s, q):
    """RBJ band-pass whose centre glides exponentially from f_start to f_end over sweep_s."""
    x1 = x2 = y1 = y2 = 0.0
    out = []
    for i, x in enumerate(samples):
        t = min(1.0, (i / SR) / sweep_s)
        f0 = f_start * (f_end / f_start) ** t
        w0 = 2 * math.pi * f0 / SR
        alpha = math.sin(w0) / (2 * q)
        b0, b1, b2 = alpha, 0.0, -alpha
        a0, a1, a2 = 1 + alpha, -2 * math.cos(w0), 1 - alpha
        y = (b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0
        x2, x1 = x1, x
        y2, y1 = y1, y
        out.append(y)
    return out


def small_room(samples, wet):
    """A tiny Schroeder room (4 damped combs + 2 allpasses) so tones sit instead of beeping."""
    if wet <= 0:
        return samples
    n = len(samples)
    acc = [0.0] * n
    for d_ms, fb in ((23.1, 0.62), (27.7, 0.60), (31.3, 0.58), (35.9, 0.55)):
        d = int(d_ms * SR / 1000)
        line = [0.0] * d
        idx = 0
        lp = 0.0
        for i in range(n):
            out = line[idx]
            lp = out * 0.6 + lp * 0.4
            line[idx] = samples[i] + lp * fb
            idx = (idx + 1) % d
            acc[i] += out * 0.25
    for d_ms, g in ((5.0, 0.6), (1.7, 0.6)):
        d = int(d_ms * SR / 1000)
        line = [0.0] * d
        idx = 0
        for i in range(n):
            delayed = line[idx]
            v = acc[i]
            y = -g * v + delayed
            line[idx] = v + g * y
            idx = (idx + 1) % d
            acc[i] = y
    return [(1 - wet) * d + wet * w for d, w in zip(samples, acc)]


def finish(samples, peak_dbfs, lowpass_hz=None, room=0.0, fade_ms=12.0):
    out = samples
    if lowpass_hz:
        out = lowpass(out, lowpass_hz)
    out = small_room(out, room)
    # Remove any DC left by filters, then fade the end to exact silence.
    mean = sum(out) / len(out)
    out = [x - mean for x in out]
    fade = int(fade_ms * SR / 1000)
    n = len(out)
    for i in range(fade):
        k = n - 1 - i
        out[k] *= 0.5 - 0.5 * math.cos(math.pi * i / fade)
    # A 1 ms fade-in guarantees the first samples start at zero.
    fade_in = int(0.001 * SR)
    for i in range(fade_in):
        out[i] *= i / fade_in
    peak = max(1e-9, max(abs(x) for x in out))
    target = 10 ** (peak_dbfs / 20)
    return [x * target / peak for x in out]


GLASS = ((1.0, 1.0), (2.0, 0.20))            # sine + octave at -14 dB
BELL = ((1.0, 1.0), (2.76, 0.10))            # sine + inharmonic partial at -20 dB
REED = ((1.0, 1.0), (3.0, 0.158))            # sine + 3rd harmonic at -16 dB


def pluck(freq, glide_semitones=0.0, tau=0.030, seconds=0.12):
    target = semitones(freq, glide_semitones) if glide_semitones else None
    return tone(freq, seconds, attack=0.002, tau=tau, partials=GLASS, glide_to=target, glide_time=0.030,
                partial_damping=8.0)


def make_start():
    c = Canvas(0.110)
    c.add(0.0, pluck(880.0, glide_semitones=2.0, tau=0.030, seconds=0.110))
    c.add(0.0, noise_burst(0.0015, 5000, seed=11), gain=10 ** (-28 / 20))
    return finish(c.buf, -14, lowpass_hz=9000, room=0.05)


def make_stop():
    c = Canvas(0.170)
    c.add(0.000, pluck(784.0, tau=0.035, seconds=0.125))
    c.add(0.045, pluck(587.33, tau=0.035, seconds=0.125), gain=0.95)
    return finish(c.buf, -14, lowpass_hz=8000, room=0.05)


def make_lock():
    c = Canvas(0.180)
    c.add(0.000, pluck(880.0, glide_semitones=2.0, tau=0.028, seconds=0.105))
    c.add(0.070, pluck(semitones(880.0, 3), glide_semitones=2.0, tau=0.030, seconds=0.110), gain=0.9)
    thump = tone(160.0, 0.090, attack=0.003, tau=0.020)
    c.add(0.000, thump, gain=10 ** (-10 / 20))
    c.add(0.0, noise_burst(0.0015, 5000, seed=23), gain=10 ** (-30 / 20))
    return finish(c.buf, -14, lowpass_hz=9000, room=0.05)


def make_paste():
    c = Canvas(0.045)
    burst = tone(2100.0, 0.025, attack=0.0015, tau=0.008)
    c.add(0.0, burst)
    c.add(0.0, noise_burst(0.003, 4000, seed=37), gain=10 ** (-18 / 20))
    return finish(c.buf, -22, lowpass_hz=11000, fade_ms=8)


def make_cancel():
    rng = random.Random(53)
    n = int(0.160 * SR)
    raw = [rng.uniform(-1, 1) for _ in range(n)]
    # Two cascaded band-passes give the swish a clear pitch-like sweep without getting whistly.
    shaped = swept_bandpass(swept_bandpass(raw, 1400.0, 350.0, 0.140, q=1.4), 1400.0, 350.0, 0.140, q=1.4)
    env = []
    for i in range(n):
        t = i / SR
        a = 0.5 - 0.5 * math.cos(math.pi * min(1.0, t / 0.018))
        env.append(a * math.exp(-max(0.0, t - 0.018) / 0.050))
    c = Canvas(0.160)
    c.add(0.0, [x * e for x, e in zip(shaped, env)])
    return finish(c.buf, -24, lowpass_hz=4000, fade_ms=20)


def make_alert():
    c = Canvas(0.420)
    c.add(0.000, tone(523.25, 0.40, attack=0.004, tau=0.180, partials=BELL, partial_damping=4.0))
    c.add(0.120, tone(659.25, 0.30, attack=0.004, tau=0.180, partials=BELL, partial_damping=4.0), gain=0.9)
    return finish(c.buf, -14, lowpass_hz=7000, room=0.10, fade_ms=40)


def make_error():
    c = Canvas(0.320)
    first = tone(330.0, 0.20, attack=0.006, tau=0.120, partials=REED, partial_damping=3.0)
    second = tone(261.63, 0.21, attack=0.006, tau=0.120, partials=REED, partial_damping=3.0)
    c.add(0.000, first)
    c.add(0.110, second, gain=0.95)
    return finish(c.buf, -16, lowpass_hz=3200, room=0.08, fade_ms=35)


def make_success():
    c = Canvas(0.600)
    for k, f in enumerate((523.25, 659.25, 783.99)):
        c.add(0.060 * k, tone(f, 0.60 - 0.060 * k, attack=0.004, tau=0.200, partials=BELL, partial_damping=4.0),
              gain=1.0 - 0.06 * k)
    return finish(c.buf, -14, lowpass_hz=7000, room=0.12, fade_ms=60)


SOUNDS = {
    "start": make_start,
    "stop": make_stop,
    "lock": make_lock,
    "paste": make_paste,
    "cancel": make_cancel,
    "alert": make_alert,
    "error": make_error,
    "success": make_success,
}


def write_wav(path, samples):
    frames = b"".join(struct.pack("<h", int(round(max(-1.0, min(1.0, s)) * 32767))) for s in samples)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(frames)


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, "Resources", "Sounds")
    os.makedirs(out, exist_ok=True)
    for name, make in SOUNDS.items():
        samples = make()
        path = os.path.join(out, f"{name}.wav")
        write_wav(path, samples)
        peak = max(abs(x) for x in samples)
        print(f"{name:8s} {len(samples) / SR * 1000:5.0f} ms  peak {20 * math.log10(peak):6.1f} dBFS  -> {path}")


if __name__ == "__main__":
    main()
