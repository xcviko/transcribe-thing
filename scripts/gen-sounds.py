#!/usr/bin/env python3
"""gen-sounds.py: synthesize transcribe-thing's eight original UI sounds (standard library only).

Usage: python3 scripts/gen-sounds.py [out_dir]        (default: Resources/Sounds)

Every file is 48 kHz, mono, 16-bit PCM. The family is low, woody and percussive: knocks, a mouth pop
and soft marimba notes instead of glassy tones, so the cues feel physical and never bright.

  start    one soft woody "tok", 470 Hz, 100 ms
  stop     one duller "tok", 370 Hz sagging 2 semitones, 130 ms
  lock     "tok-tok" 70 ms apart, 440 -> 523 Hz (second higher, a latch), 160 ms
  paste    the tiniest mouth pop, 520 -> 240 Hz, 45 ms, the quietest sound
  cancel   a soft low "tuk" gliding 330 -> 150 Hz, 130 ms
  alert    two soft wooden marimba notes 262 -> 330 Hz, 350 ms
  error    two muted knocks 233 -> 196 Hz, 280 ms
  success  a small low wooden arpeggio C4 E4 G4, 380 ms

Voices:
  knock   modal synthesis. A 1-3 ms mallet strike (raised-cosine force pulse with a little grain) drives
          2-3 two-pole resonators, one per vibrational mode, at inharmonic ratios (wood block ~1 : 2.32 :
          4.08, marimba bar ~1 : 3.93). Upper modes are quieter and die faster, like a real struck object.
          The strike itself is heard as a tiny low-passed contact noise, and some knocks get a short sub
          "thump" (a sine sliding down from ~150 Hz, gone within 22 ms) for body.
  pop     a mouth "tsk-pop": a sine burst whose pitch drops fast, plus a soft 2 ms band-limited transient.
  finish  4th-order Butterworth low-pass (nothing bright), 40 Hz high-pass (no DC), a 1.5 ms fade-in, a
          raised-cosine fade-out to exact zero after the natural decay, and peak normalization
          (-11 dBFS; paste -19, cancel -17, error -13). At equal peaks these low, soft-edged knocks
          measure 2-4 dB quieter than the earlier bright tones, so every peak sits 3 dB above that set's.

scripts/analyze-sounds.py checks the result (level, spectral centroid, energy above 3 kHz, attack, decay,
pitch). Output is deterministic (fixed noise seeds).
"""
import math
import os
import random
import struct
import sys
import wave

SR = 48_000
TWO_PI = 2 * math.pi


def gain_db(x):
    return 10 ** (x / 20)


def peak(samples):
    return max(abs(v) for v in samples) or 1e-12


def scaled(samples, target_peak):
    k = target_peak / peak(samples)
    return [v * k for v in samples]


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


# ---------------------------------------------------------------------------------------------- filters

class Biquad:
    """RBJ audio-EQ-cookbook biquad (direct form I)."""

    def __init__(self, kind, freq, q=1 / math.sqrt(2)):
        w0 = TWO_PI * freq / SR
        cw = math.cos(w0)
        alpha = math.sin(w0) / (2 * q)
        if kind == "lowpass":
            b = ((1 - cw) / 2, 1 - cw, (1 - cw) / 2)
        elif kind == "highpass":
            b = ((1 + cw) / 2, -(1 + cw), (1 + cw) / 2)
        elif kind == "bandpass":
            b = (alpha, 0.0, -alpha)
        else:
            raise ValueError(kind)
        a0 = 1 + alpha
        self.b = tuple(v / a0 for v in b)
        self.a = (-2 * cw / a0, (1 - alpha) / a0)

    def run(self, samples):
        b0, b1, b2 = self.b
        a1, a2 = self.a
        x1 = x2 = y1 = y2 = 0.0
        out = []
        for x in samples:
            y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2, x1 = x1, x
            y2, y1 = y1, y
            out.append(y)
        return out


def butterworth(samples, kind, freq, order):
    """Cascade of 2nd-order sections with Butterworth Qs (order must be even)."""
    for k in range(order // 2):
        q = 1 / (2 * math.cos(math.pi * (2 * k + 1) / (2 * order)))
        samples = Biquad(kind, freq, q).run(samples)
    return samples


def small_room(samples, wet):
    """A tiny Schroeder room (4 damped combs + 2 allpasses) so the longer notes sit instead of beeping."""
    if wet <= 0:
        return samples
    n = len(samples)
    acc = [0.0] * n
    for d_ms, fb in ((23.1, 0.55), (27.7, 0.53), (31.3, 0.51), (35.9, 0.49)):
        d = int(d_ms * SR / 1000)
        line = [0.0] * d
        idx = 0
        lp = 0.0
        for i in range(n):
            out = line[idx]
            lp = out * 0.5 + lp * 0.5
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


# ----------------------------------------------------------------------------------------------- voices

def strike(ms, seed, grain=0.3):
    """Mallet (or tongue) contact force: a raised-cosine pulse `ms` long with a little random grain."""
    n = max(4, int(round(ms * SR / 1000)))
    rng = random.Random(seed)
    return [(0.5 - 0.5 * math.cos(TWO_PI * (i + 0.5) / n)) * (1 + grain * rng.uniform(-1, 1)) for i in range(n)]


def contact(ms, seed, lowpass_hz=2000.0, highpass_hz=250.0):
    """The strike heard directly: a Hann-windowed noise tick `ms` long, band-limited to highpass..lowpass."""
    n = max(4, int(round(ms * SR / 1000)))
    rng = random.Random(seed)
    raw = [rng.uniform(-1, 1) * (0.5 - 0.5 * math.cos(TWO_PI * (i + 0.5) / n)) for i in range(n)]
    raw += [0.0] * int(0.004 * SR)  # room for the filters to ring out
    return Biquad("highpass", highpass_hz).run(butterworth(raw, "lowpass", lowpass_hz, 4))


def resonate(excitation, freq, tau, seconds, glide=None):
    """One vibrational mode: a two-pole resonator ringing at `freq` whose amplitude decays as exp(-t/tau).
    `glide(t)` optionally returns a pitch multiplier over time (a mode that sags as the object settles)."""
    n = int(round(seconds * SR))
    r = math.exp(-1 / (tau * SR))
    y1 = y2 = 0.0
    out = []
    for i in range(n):
        f = freq * (glide(i / SR) if glide else 1.0)
        w = TWO_PI * f / SR
        x = excitation[i] if i < len(excitation) else 0.0
        y = math.sin(w) * x + 2 * r * math.cos(w) * y1 - r * r * y2
        y2, y1 = y1, y
        out.append(y)
    return out


def thump(f_start, f_end, seconds=0.022, tau=0.007):
    """Sub "body" under a knock: a sine sliding from f_start down to f_end Hz, gone within `seconds`."""
    n = int(round(seconds * SR))
    phase = 0.0
    out = []
    for i in range(n):
        t = i / SR
        f = f_end + (f_start - f_end) * math.exp(-t / (seconds / 4))
        phase += TWO_PI * f / SR
        attack = 0.5 - 0.5 * math.cos(math.pi * min(1.0, t / 0.0015))
        u = i / (n - 1)
        taper = 1.0 if u < 0.6 else 0.5 + 0.5 * math.cos(math.pi * (u - 0.6) / 0.4)
        out.append(math.sin(phase) * attack * math.exp(-t / tau) * taper)
    return out


# Modes as (frequency ratio, peak gain, decay-time scale relative to the fundamental's tau).
WOOD = ((1.0, 1.0, 1.0), (2.32, 0.28, 0.45), (4.08, 0.08, 0.22))        # wood block "tok"
WOOD_DULL = ((1.0, 1.0, 1.0), (2.32, 0.15, 0.40), (4.08, 0.035, 0.20))   # softer mallet, fewer overtones
WOOD_KNOCK = ((1.0, 1.0, 1.0), (2.26, 0.30, 0.40), (3.62, 0.08, 0.20))   # knuckle on a door / table
MARIMBA = ((1.0, 1.0, 1.0), (3.93, 0.16, 0.20), (2.71, 0.05, 0.10))     # tuned bar + a faint wood mode


def grain(center_hz, seconds, seed, tau=0.004):
    """Wood "grain": the dense cloud of tiny, heavily damped modes a real block has, as a few ms of
    band-passed noise under an exp(-t/tau) envelope. Makes a knock read as wood rather than as a tone."""
    n = int(round(seconds * SR))
    rng = random.Random(seed)
    raw = []
    for i in range(n):
        t = i / SR
        a = 0.5 - 0.5 * math.cos(math.pi * min(1.0, t / 0.0005))
        u = i / (n - 1)
        taper = 1.0 if u < 0.7 else 0.5 + 0.5 * math.cos(math.pi * (u - 0.7) / 0.3)
        raw.append(rng.uniform(-1, 1) * a * math.exp(-t / tau) * taper)
    return Biquad("bandpass", center_hz, q=1.0).run(raw)


def knock(f0, tau, seconds, modes=WOOD, strike_ms=1.5, seed=1, contact_db=-20.0, contact_lp=2000.0,
          glide=None, sub=None, grain_db=None):
    """A struck wooden object: `strike` drives one resonator per mode; `sub` = (from Hz, to Hz, dB);
    `grain_db` adds wood grain centred between the first two modes."""
    n = int(round(seconds * SR))
    exc = strike(strike_ms, seed)
    out = [0.0] * n
    for ratio, g, tau_scale in modes:
        mode = scaled(resonate(exc, f0 * ratio, tau * tau_scale, seconds, glide), g)
        for i in range(n):
            out[i] += mode[i]
    if contact_db is not None:
        tick = scaled(contact(strike_ms, seed + 1000, lowpass_hz=contact_lp), gain_db(contact_db))
        for i in range(min(n, len(tick))):
            out[i] += tick[i]
    if sub is not None:
        f_from, f_to, level = sub
        body = scaled(thump(f_from, f_to), gain_db(level))
        for i in range(min(n, len(body))):
            out[i] += body[i]
    if grain_db is not None:
        texture = scaled(grain(f0 * 1.6, min(seconds, 0.025), seed + 2000), gain_db(grain_db))
        for i in range(min(n, len(texture))):
            out[i] += texture[i]
    return out


def pop(f_start, f_end, glide_s, tau, seconds, attack_s=0.001, contact_db=-14.0, seed=7, contact_lp=1600.0):
    """Mouth "tsk-pop": a sine burst whose pitch drops from f_start to f_end (about 95 % of the way after
    `glide_s`) under an exp(-t/tau) envelope, plus a soft 2 ms band-limited transient (lips parting)."""
    n = int(round(seconds * SR))
    phase = 0.0
    out = []
    for i in range(n):
        t = i / SR
        f = f_end + (f_start - f_end) * math.exp(-t / (glide_s / 3))
        phase += TWO_PI * f / SR
        a = 0.5 - 0.5 * math.cos(math.pi * min(1.0, t / attack_s))
        out.append(math.sin(phase) * a * math.exp(-t / tau))
    if contact_db is not None:
        tick = scaled(contact(2.0, seed, lowpass_hz=contact_lp, highpass_hz=300.0), gain_db(contact_db))
        for i in range(min(n, len(tick))):
            out[i] += tick[i]
    return out


def sag(semis, time_s):
    """Pitch multiplier that sags by `semis` semitones (exponential approach, ~95 % after `time_s`)."""
    return lambda t: 2 ** (semis / 12 * (1 - math.exp(-t / (time_s / 3))))


def finish(samples, peak_dbfs, lowpass_hz=3000.0, room=0.0, fade_in_ms=1.5, fade_out_ms=15.0):
    out = butterworth(samples, "lowpass", lowpass_hz, 4)
    out = butterworth(out, "highpass", 40.0, 2)
    out = small_room(out, room)
    n = len(out)
    fade_in = int(fade_in_ms * SR / 1000)
    for i in range(fade_in):
        out[i] *= 0.5 - 0.5 * math.cos(math.pi * i / fade_in)
    fade_out = int(fade_out_ms * SR / 1000)
    for i in range(fade_out):  # i == 0 is the last sample, which becomes exactly zero
        out[n - 1 - i] *= 0.5 - 0.5 * math.cos(math.pi * i / fade_out)
    return scaled(out, gain_db(peak_dbfs))


# ---------------------------------------------------------------------------------------------- recipes

def make_start():
    c = Canvas(0.100)
    c.add(0.0, knock(470.0, tau=0.022, seconds=0.100, modes=WOOD, strike_ms=1.2, seed=11,
                     sub=(150.0, 95.0, -12.0), grain_db=-20.0))
    return finish(c.buf, -11, lowpass_hz=3000)


def make_stop():
    c = Canvas(0.130)
    c.add(0.0, knock(370.0, tau=0.024, seconds=0.130, modes=WOOD_DULL, strike_ms=2.0, seed=13,
                     glide=sag(-2.0, 0.045), sub=(130.0, 80.0, -10.0), grain_db=-22.0))
    return finish(c.buf, -11, lowpass_hz=2400)


def make_lock():
    c = Canvas(0.160)
    c.add(0.000, knock(440.0, tau=0.018, seconds=0.090, modes=WOOD, strike_ms=1.0, seed=17,
                       sub=(150.0, 95.0, -12.0), grain_db=-20.0), gain=0.8)
    c.add(0.070, knock(523.25, tau=0.018, seconds=0.090, modes=WOOD, strike_ms=1.0, seed=19, grain_db=-20.0))
    return finish(c.buf, -11, lowpass_hz=3000)


def make_paste():
    c = Canvas(0.045)
    c.add(0.0, pop(520.0, 240.0, glide_s=0.012, tau=0.0065, seconds=0.045, contact_db=-12.0, seed=37))
    return finish(c.buf, -19, lowpass_hz=2500, fade_out_ms=10)


def make_cancel():
    c = Canvas(0.130)
    c.add(0.0, pop(330.0, 150.0, glide_s=0.035, tau=0.022, seconds=0.130, contact_db=-16.0, seed=53))
    # A small woody "k" riding on the pop, sagging with it, so it articulates as "tuk" on laptop speakers too.
    c.add(0.0, knock(300.0, tau=0.010, seconds=0.060, modes=((1.0, 1.0, 1.0), (2.32, 0.30, 0.45)),
                     strike_ms=1.5, seed=57, contact_db=None, glide=sag(-5.0, 0.030)), gain=0.35)
    return finish(c.buf, -17, lowpass_hz=2200, fade_out_ms=20)


def make_alert():
    c = Canvas(0.350)
    c.add(0.000, knock(261.63, tau=0.055, seconds=0.350, modes=MARIMBA, strike_ms=2.5, seed=61, contact_db=-22.0,
                       grain_db=-26.0))
    c.add(0.140, knock(329.63, tau=0.050, seconds=0.210, modes=MARIMBA, strike_ms=2.5, seed=67, contact_db=-22.0,
                       grain_db=-26.0),
          gain=0.9)
    return finish(c.buf, -11, lowpass_hz=3000, room=0.06, fade_out_ms=30)


def make_error():
    c = Canvas(0.280)
    c.add(0.000, knock(233.08, tau=0.026, seconds=0.155, modes=WOOD_KNOCK, strike_ms=2.5, seed=71,
                       sub=(120.0, 75.0, -10.0), grain_db=-20.0))
    c.add(0.125, knock(196.00, tau=0.026, seconds=0.155, modes=WOOD_KNOCK, strike_ms=2.5, seed=73,
                       sub=(110.0, 70.0, -10.0), grain_db=-20.0), gain=0.92)
    return finish(c.buf, -13, lowpass_hz=2200, room=0.04, fade_out_ms=25)


def make_success():
    c = Canvas(0.380)
    notes = ((261.63, 0.050, 0.85), (329.63, 0.050, 0.92), (392.00, 0.065, 1.0))
    for k, (f, tau, g) in enumerate(notes):
        onset = 0.065 * k
        c.add(onset, knock(f, tau=tau, seconds=0.380 - onset, modes=MARIMBA, strike_ms=2.2, seed=81 + k,
                           contact_db=-22.0, grain_db=-26.0), gain=g)
    return finish(c.buf, -11, lowpass_hz=3000, room=0.06, fade_out_ms=40)


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
        print(f"{name:8s} {len(samples) / SR * 1000:5.0f} ms  peak {20 * math.log10(peak(samples)):6.1f} dBFS  -> {path}")


if __name__ == "__main__":
    main()
