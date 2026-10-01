#!/usr/bin/env python3
"""gen-sounds.py: synthesize transcribe-thing's nine original UI sounds (standard library only).

Usage: python3 scripts/gen-sounds.py [--set current|A|B|C] [out_dir]      (default: DEFAULT_SET, Resources/Sounds)

Every file is 48 kHz, mono, 16-bit PCM, peak-normalized to -11 dBFS (paste and modelSwitch -19, cancel -17,
error -13). There are
four sets; DEFAULT_SET (below) is the one Resources/Sounds holds, and analyze-sounds.py checks against the same
set's expectations, so shipping another set is a one-line change plus `make sounds`.

current: low, woody and percussive (knocks, a mouth pop, soft marimba notes).
  start    one soft woody "tok", 470 Hz, 100 ms
  stop     one duller "tok", 370 Hz sagging 2 semitones, 130 ms
  lock     "tok-tok" 70 ms apart, 440 -> 523 Hz (second higher, a latch), 160 ms
  paste    the tiniest mouth pop, 520 -> 240 Hz, 45 ms, the quietest sound
  cancel   a soft low "tuk" gliding 330 -> 150 Hz, 130 ms
  alert    two soft wooden marimba notes 262 -> 330 Hz, 350 ms
  error    two muted knocks 233 -> 196 Hz, 280 ms
  success  a small low wooden arpeggio C4 E4 G4, 380 ms
  modelSwitch  two tiny mouth pops 28 ms apart, the second higher, 70 ms, as quiet as paste

A "tongue click": pitch-dropping mouth pops (tongue voice), bodies 120-260 Hz, 1-2 kHz ceiling, almost no ring.
  start    pop 250 -> 175 Hz, tau 11 ms, 70 ms          stop     pop 200 -> 135 Hz, tau 13 ms, 85 ms
  lock     pops 225 -> 160 and 260 -> 185 Hz, 55 ms apart, 125 ms
  paste    tiny pop 280 -> 150 Hz, tau 5 ms, 45 ms      cancel   pop sliding 230 -> 120 Hz over ~45 ms, 95 ms
  alert    two pitched pops G3 -> B3, 110 ms apart      error    two low pops 140 -> 124 Hz, 105 ms apart
  success  pops G3 B3 D4, 60 ms apart, 270 ms
  modelSwitch  two tiny tongue ticks 280 -> 190 and 330 -> 220 Hz, 28 ms apart, 70 ms, as quiet as paste
  polishOn / polishOff  a drop: one tongue pop gliding up 190 -> 330 Hz, or down 330 -> 190, 90 ms, -15 dBFS
               (only this set has them: Polish came after the others were picked)

B "low wood block": modal knocks, fundamentals 155-290 Hz, tau 11-19 ms, low-passed at 1.5-2 kHz, a faint sub thump.
  start    block 280 Hz, 90 ms                          stop     duller block 215 Hz sagging 1.5 semitones, 105 ms
  lock     245 -> 290 Hz, 60 ms apart, 135 ms           paste    tiny tick 240 Hz, tau 5 ms, 40 ms
  cancel   knock 250 Hz sagging 6 semitones, 110 ms     alert    two wood-bar notes F3 -> A3, 130 ms apart, 300 ms
  error    two muted knocks 185 -> 156 Hz, 240 ms       success  wood-bar arpeggio F3 A3 C4, 320 ms
  modelSwitch  two tiny ticks 240 -> 290 Hz, 28 ms apart, 75 ms

C "matched": built from scratch to the measured shape of Wispr Flow's default cues (their audio is only measured by
  analyze-sounds.py, never used), 3-6 semitones lower. A near-pure "tok" (2nd mode 1.89x at -30 dB, 3-3.5 ms mallet
  so a ~2.5 ms attack, tau 6-8 ms into a faint room tail), led by a soft grace hit 17-22 dB down.
  start    grace 235 Hz, then tok 350 Hz 20 ms later, 115 ms
  stop     grace 350 Hz, then tok 233 Hz 36 ms later, 150 ms
  lock     mouth pops 330 -> 150 Hz and 520 -> 175 Hz, 60 ms apart, 140 ms
  paste    tiny pop 330 -> 140 Hz, tau 4 ms, 40 ms      cancel   pop sliding 360 -> 130 Hz, 100 ms
  alert    toks G3 -> D4, 60 ms apart, 330 ms           error    toks A3 -> D3, 125 ms apart, 300 ms
  success  toks G3 B3 D4, 70 ms apart, 400 ms
  modelSwitch  two tiny pops 330 -> 160 and 400 -> 190 Hz, 28 ms apart, 65 ms

Voices:
  knock   modal synthesis. A 1-3.5 ms mallet strike (raised-cosine force pulse with a little grain) drives
          2-3 two-pole resonators, one per vibrational mode, at inharmonic ratios (wood block ~1 : 2.32 :
          4.08, marimba bar ~1 : 3.93). Upper modes are quieter and die faster, like a real struck object.
          The strike itself is heard as a tiny low-passed contact noise, and some knocks get a short sub
          "thump" (a sine sliding down from ~150 Hz, gone within 22 ms) for body.
  pop     a mouth "tsk-pop": a sine burst whose pitch drops fast, plus a soft 2 ms band-limited transient.
  tongue  a tongue click: a pitch-dropping sine body with a faster-dying 2nd harmonic (so a 150 Hz body still
          reads on laptop speakers), an oral-cavity resonance that falls with it, and a soft release tick.
  finish  4th-order Butterworth low-pass (nothing bright), 2nd-order high-pass (40 Hz: no DC; set C uses
          90-130 Hz to drop the mallet's sub bump), a 1.5 ms fade-in, a raised-cosine fade-out to exact zero
          after the natural decay, and peak normalization.

scripts/analyze-sounds.py checks the result (level, spectral centroid, energy above 3 kHz, attack, decay,
pitch) and, with --compare, measures any set next to another. Output is deterministic (fixed noise seeds).
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


def tongue(f_start, f_end, glide_s, tau, seconds, attack_s=0.0008, h2_db=-16.0, cavity=None, click_db=-20.0,
           click_lp=1500.0, seed=5):
    """Tongue click / mouth "tok" (the tongue leaving the palate): a sine body whose pitch drops from f_start to
    f_end (about 95 % of the way after `glide_s`) under exp(-t/tau), a 2nd harmonic `h2_db` down that dies twice as
    fast (so a 150 Hz body still reads on laptop speakers), an optional oral-cavity resonance `cavity` = (ratio to
    the body pitch, dB, tau) rung by the release and falling with the body, and a soft band-limited release tick."""
    n = int(round(seconds * SR))
    tc = glide_s / 3

    def pitch(t):
        return f_end + (f_start - f_end) * math.exp(-t / tc)

    h2 = gain_db(h2_db) if h2_db is not None else 0.0
    phase = 0.0
    out = []
    for i in range(n):
        t = i / SR
        phase += TWO_PI * pitch(t) / SR
        a = 0.5 - 0.5 * math.cos(math.pi * min(1.0, t / attack_s))
        out.append(a * (math.sin(phase) * math.exp(-t / tau) + h2 * math.sin(2 * phase) * math.exp(-2 * t / tau)))
    if cavity is not None:
        ratio, level, c_tau = cavity
        ring = resonate(strike(0.8, seed), f_start * ratio, c_tau, seconds, glide=lambda t: pitch(t) / f_start)
        out = [a + b for a, b in zip(out, scaled(ring, gain_db(level)))]
    if click_db is not None:
        tick = scaled(contact(1.2, seed + 100, lowpass_hz=click_lp, highpass_hz=250.0), gain_db(click_db))
        for i in range(min(n, len(tick))):
            out[i] += tick[i]
    return out


def sag(semis, time_s):
    """Pitch multiplier that sags by `semis` semitones (exponential approach, ~95 % after `time_s`)."""
    return lambda t: 2 ** (semis / 12 * (1 - math.exp(-t / (time_s / 3))))


def finish(samples, peak_dbfs, lowpass_hz=3000.0, room=0.0, fade_in_ms=1.5, fade_out_ms=15.0, highpass_hz=40.0):
    out = butterworth(samples, "lowpass", lowpass_hz, 4)
    out = butterworth(out, "highpass", highpass_hz, 2)
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


def make_model_switch():
    c = Canvas(0.070)
    c.add(0.000, pop(470.0, 250.0, glide_s=0.010, tau=0.004, seconds=0.035, contact_db=-12.0, seed=41), gain=0.7)
    c.add(0.028, pop(560.0, 300.0, glide_s=0.010, tau=0.0045, seconds=0.042, contact_db=-12.0, seed=43))
    return finish(c.buf, -19, lowpass_hz=2500, fade_out_ms=8)


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


# --------------------------------------------------------------------------------- candidate set A: tongue

def a_start():
    c = Canvas(0.070)
    c.add(0.0, tongue(250.0, 175.0, glide_s=0.014, tau=0.011, seconds=0.070, h2_db=-14.0, cavity=(2.4, -8.0, 0.003),
                      click_db=-20.0, seed=101))
    return finish(c.buf, -11, lowpass_hz=1800, fade_out_ms=12)


def a_stop():
    c = Canvas(0.085)
    c.add(0.0, tongue(200.0, 135.0, glide_s=0.018, tau=0.013, seconds=0.085, h2_db=-12.0, cavity=(2.3, -12.0, 0.003),
                      click_db=-24.0, seed=103))
    return finish(c.buf, -11, lowpass_hz=1400, fade_out_ms=15)


def a_lock():
    c = Canvas(0.125)
    c.add(0.000, tongue(225.0, 160.0, glide_s=0.010, tau=0.008, seconds=0.065, h2_db=-14.0,
                        cavity=(2.4, -9.0, 0.0025), click_db=-20.0, seed=105), gain=0.85)
    c.add(0.055, tongue(260.0, 185.0, glide_s=0.010, tau=0.009, seconds=0.070, h2_db=-14.0,
                        cavity=(2.4, -9.0, 0.0025), click_db=-20.0, seed=107))
    return finish(c.buf, -11, lowpass_hz=1800, fade_out_ms=12)


def a_paste():
    c = Canvas(0.045)
    c.add(0.0, tongue(280.0, 150.0, glide_s=0.016, tau=0.005, seconds=0.045, h2_db=-12.0, cavity=(2.5, -8.0, 0.002),
                      click_db=-16.0, seed=109))
    return finish(c.buf, -19, lowpass_hz=1800, fade_out_ms=8)


def a_cancel():
    c = Canvas(0.095)
    c.add(0.0, tongue(230.0, 120.0, glide_s=0.045, tau=0.018, seconds=0.095, h2_db=-12.0, cavity=(2.3, -12.0, 0.003),
                      click_db=-22.0, seed=111))
    return finish(c.buf, -17, lowpass_hz=1400, fade_out_ms=18)


def a_model_switch():
    c = Canvas(0.070)
    c.add(0.000, tongue(280.0, 190.0, glide_s=0.008, tau=0.004, seconds=0.035, h2_db=-14.0, cavity=(2.5, -10.0, 0.002),
                        click_db=-18.0, seed=131), gain=0.7)
    c.add(0.028, tongue(330.0, 220.0, glide_s=0.008, tau=0.0045, seconds=0.042, h2_db=-14.0,
                        cavity=(2.5, -10.0, 0.002), click_db=-18.0, seed=133))
    return finish(c.buf, -19, lowpass_hz=1500, fade_out_ms=8)


def a_polish_on():
    c = Canvas(0.090)
    c.add(0.0, tongue(190.0, 330.0, glide_s=0.030, tau=0.014, seconds=0.090, h2_db=-14.0, cavity=(2.4, -10.0, 0.003),
                      click_db=-24.0, seed=135))
    return finish(c.buf, -15, lowpass_hz=1600, fade_out_ms=14)


def a_polish_off():
    c = Canvas(0.090)
    c.add(0.0, tongue(330.0, 190.0, glide_s=0.030, tau=0.014, seconds=0.090, h2_db=-14.0, cavity=(2.4, -10.0, 0.003),
                      click_db=-24.0, seed=137))
    return finish(c.buf, -15, lowpass_hz=1600, fade_out_ms=14)


def a_alert():
    c = Canvas(0.250)
    c.add(0.000, tongue(215.0, 196.0, glide_s=0.010, tau=0.022, seconds=0.140, h2_db=-16.0,
                        cavity=(2.4, -18.0, 0.003), click_db=-26.0, seed=113))
    c.add(0.110, tongue(270.0, 247.0, glide_s=0.010, tau=0.024, seconds=0.140, h2_db=-16.0,
                        cavity=(2.4, -18.0, 0.003), click_db=-26.0, seed=115), gain=0.95)
    return finish(c.buf, -11, lowpass_hz=1400, fade_out_ms=25)


def a_error():
    c = Canvas(0.210)
    c.add(0.000, tongue(175.0, 140.0, glide_s=0.012, tau=0.014, seconds=0.105, h2_db=-12.0,
                        cavity=(2.3, -16.0, 0.003), click_db=-26.0, seed=117))
    c.add(0.105, tongue(155.0, 124.0, glide_s=0.012, tau=0.014, seconds=0.105, h2_db=-12.0,
                        cavity=(2.3, -16.0, 0.003), click_db=-26.0, seed=119), gain=0.95)
    return finish(c.buf, -13, lowpass_hz=1200, fade_out_ms=20)


def a_success():
    c = Canvas(0.270)
    for k, (f, g) in enumerate(((196.0, 0.85), (246.94, 0.92), (293.66, 1.0))):
        onset = 0.060 * k
        c.add(onset, tongue(f * 1.12, f, glide_s=0.010, tau=0.024, seconds=0.270 - onset, h2_db=-16.0,
                            cavity=(2.4, -18.0, 0.003), click_db=-26.0, seed=121 + k), gain=g)
    return finish(c.buf, -11, lowpass_hz=1400, fade_out_ms=30)


# ----------------------------------------------------------------------------- candidate set B: low wood block

def b_start():
    c = Canvas(0.090)
    c.add(0.0, knock(280.0, tau=0.014, seconds=0.090, modes=WOOD, strike_ms=1.4, seed=201, contact_lp=1500.0,
                     sub=(110.0, 70.0, -14.0), grain_db=-24.0))
    return finish(c.buf, -11, lowpass_hz=1800, fade_out_ms=12)


def b_stop():
    c = Canvas(0.105)
    c.add(0.0, knock(215.0, tau=0.016, seconds=0.105, modes=WOOD_DULL, strike_ms=2.0, seed=203, contact_lp=1300.0,
                     glide=sag(-1.5, 0.040), sub=(95.0, 60.0, -12.0), grain_db=-26.0))
    return finish(c.buf, -11, lowpass_hz=1500, fade_out_ms=15)


def b_lock():
    c = Canvas(0.135)
    c.add(0.000, knock(245.0, tau=0.011, seconds=0.075, modes=WOOD, strike_ms=1.2, seed=205, contact_lp=1500.0,
                       sub=(110.0, 70.0, -14.0), grain_db=-24.0), gain=0.85)
    c.add(0.060, knock(290.0, tau=0.011, seconds=0.075, modes=WOOD, strike_ms=1.2, seed=207, contact_lp=1500.0,
                       grain_db=-24.0))
    return finish(c.buf, -11, lowpass_hz=1800, fade_out_ms=12)


def b_paste():
    c = Canvas(0.040)
    c.add(0.0, knock(240.0, tau=0.005, seconds=0.040, modes=WOOD, strike_ms=0.8, seed=209, contact_db=-18.0,
                     contact_lp=1800.0, grain_db=-22.0))
    return finish(c.buf, -19, lowpass_hz=2000, fade_out_ms=8)


def b_cancel():
    c = Canvas(0.110)
    c.add(0.0, knock(250.0, tau=0.018, seconds=0.110, modes=WOOD_DULL, strike_ms=1.8, seed=211, contact_lp=1300.0,
                     glide=sag(-6.0, 0.050), sub=(100.0, 60.0, -14.0), grain_db=-26.0))
    return finish(c.buf, -17, lowpass_hz=1500, fade_out_ms=20)


def b_model_switch():
    c = Canvas(0.075)
    c.add(0.000, knock(240.0, tau=0.004, seconds=0.030, modes=WOOD, strike_ms=0.8, seed=231, contact_db=-18.0,
                       contact_lp=1800.0, grain_db=-22.0), gain=0.7)
    c.add(0.028, knock(290.0, tau=0.0045, seconds=0.047, modes=WOOD, strike_ms=0.8, seed=233, contact_db=-18.0,
                       contact_lp=1800.0, grain_db=-22.0))
    return finish(c.buf, -19, lowpass_hz=2000, fade_out_ms=8)


def b_alert():
    c = Canvas(0.300)
    c.add(0.000, knock(174.61, tau=0.035, seconds=0.300, modes=MARIMBA, strike_ms=2.5, seed=213, contact_db=-24.0,
                       contact_lp=1300.0, grain_db=-28.0))
    c.add(0.130, knock(220.00, tau=0.035, seconds=0.170, modes=MARIMBA, strike_ms=2.5, seed=215, contact_db=-24.0,
                       contact_lp=1300.0, grain_db=-28.0), gain=0.9)
    return finish(c.buf, -11, lowpass_hz=2000, room=0.05, fade_out_ms=30)


def b_error():
    c = Canvas(0.240)
    c.add(0.000, knock(185.0, tau=0.018, seconds=0.125, modes=WOOD_KNOCK, strike_ms=2.5, seed=217, contact_lp=1200.0,
                       sub=(100.0, 60.0, -12.0), grain_db=-24.0))
    c.add(0.115, knock(155.6, tau=0.018, seconds=0.125, modes=WOOD_KNOCK, strike_ms=2.5, seed=219, contact_lp=1200.0,
                       sub=(90.0, 55.0, -12.0), grain_db=-24.0), gain=0.92)
    return finish(c.buf, -13, lowpass_hz=1500, room=0.03, fade_out_ms=25)


def b_success():
    c = Canvas(0.320)
    for k, (f, g) in enumerate(((174.61, 0.85), (220.00, 0.92), (261.63, 1.0))):
        onset = 0.060 * k
        c.add(onset, knock(f, tau=0.040, seconds=0.320 - onset, modes=MARIMBA, strike_ms=2.2, seed=221 + k,
                           contact_db=-24.0, contact_lp=1300.0, grain_db=-28.0), gain=g)
    return finish(c.buf, -11, lowpass_hz=2000, room=0.05, fade_out_ms=35)


# ------------------------------------------------------------ candidate set C: matched to Wispr Flow's default
# Synthesized from scratch to the *measured* character of the reference (see analyze-sounds.py --compare): a
# near-pure "tok" (2nd mode ~1.9x, -30 dB) with a ~2.5 ms attack and a fast ~7 ms decay into a faint room tail,
# preceded by a soft grace hit (start: lower grace, then the main tok 20 ms later; stop: the reverse, 36 ms
# apart), and pitch-dropping mouth pops for lock. Everything sits 3-6 semitones below the reference.

TOK = ((1.0, 1.0, 1.0), (1.89, 0.035, 0.6))


def c_start():
    c = Canvas(0.115)
    c.add(0.000, knock(235.0, tau=0.008, seconds=0.050, modes=TOK, strike_ms=3.0, seed=301, contact_db=None), gain=0.08)
    c.add(0.020, knock(350.0, tau=0.007, seconds=0.095, modes=TOK, strike_ms=3.5, seed=303, contact_db=-30.0,
                       contact_lp=1500.0, glide=sag(-0.5, 0.020)))
    return finish(c.buf, -11, lowpass_hz=2200, room=0.10, fade_out_ms=15, highpass_hz=130.0)


def c_stop():
    c = Canvas(0.150)
    c.add(0.000, knock(350.0, tau=0.008, seconds=0.060, modes=TOK, strike_ms=3.0, seed=305, contact_db=None), gain=0.13)
    c.add(0.036, knock(233.08, tau=0.006, seconds=0.114, modes=TOK, strike_ms=3.5, seed=307, contact_db=-30.0,
                       contact_lp=1300.0, glide=sag(-0.7, 0.025)))
    return finish(c.buf, -11, lowpass_hz=1800, room=0.07, fade_out_ms=20, highpass_hz=110.0)


def c_lock():
    c = Canvas(0.140)
    c.add(0.000, tongue(330.0, 150.0, glide_s=0.012, tau=0.005, seconds=0.050, h2_db=None, cavity=(2.2, -12.0, 0.002),
                        click_db=-22.0, click_lp=1800.0, seed=309))
    c.add(0.060, tongue(520.0, 175.0, glide_s=0.018, tau=0.009, seconds=0.080, h2_db=-18.0, cavity=(2.2, -12.0, 0.002),
                        click_db=-16.0, click_lp=2000.0, seed=311), gain=0.75)
    return finish(c.buf, -11, lowpass_hz=2000, room=0.04, fade_out_ms=15, highpass_hz=100.0)


def c_paste():
    c = Canvas(0.040)
    c.add(0.0, tongue(330.0, 140.0, glide_s=0.010, tau=0.004, seconds=0.040, h2_db=None, cavity=(2.2, -12.0, 0.002),
                      click_db=-20.0, click_lp=1800.0, seed=313))
    return finish(c.buf, -19, lowpass_hz=2000, fade_out_ms=8, highpass_hz=100.0)


def c_cancel():
    c = Canvas(0.100)
    c.add(0.0, tongue(360.0, 130.0, glide_s=0.025, tau=0.014, seconds=0.100, h2_db=-18.0, cavity=(2.2, -16.0, 0.002),
                      click_db=-22.0, click_lp=1400.0, seed=315))
    return finish(c.buf, -17, lowpass_hz=1400, room=0.04, fade_out_ms=18, highpass_hz=90.0)


def c_model_switch():
    c = Canvas(0.065)
    c.add(0.000, tongue(330.0, 160.0, glide_s=0.008, tau=0.0035, seconds=0.030, h2_db=None, cavity=(2.2, -12.0, 0.002),
                        click_db=-20.0, click_lp=1800.0, seed=331), gain=0.7)
    c.add(0.028, tongue(400.0, 190.0, glide_s=0.008, tau=0.004, seconds=0.037, h2_db=None, cavity=(2.2, -12.0, 0.002),
                        click_db=-20.0, click_lp=1800.0, seed=333))
    return finish(c.buf, -19, lowpass_hz=2000, fade_out_ms=8, highpass_hz=100.0)


def c_alert():
    c = Canvas(0.330)
    c.add(0.000, knock(196.0, tau=0.025, seconds=0.200, modes=TOK, strike_ms=3.0, seed=317, contact_db=-30.0,
                       contact_lp=1300.0))
    c.add(0.060, knock(293.66, tau=0.055, seconds=0.270, modes=TOK, strike_ms=3.0, seed=319, contact_db=-30.0,
                       contact_lp=1300.0), gain=0.9)
    return finish(c.buf, -11, lowpass_hz=2000, room=0.07, fade_out_ms=35, highpass_hz=100.0)


def c_error():
    c = Canvas(0.300)
    c.add(0.000, knock(220.00, tau=0.040, seconds=0.200, modes=TOK, strike_ms=3.5, seed=321, contact_db=-30.0,
                       contact_lp=1200.0))
    c.add(0.125, knock(146.83, tau=0.040, seconds=0.175, modes=TOK, strike_ms=3.5, seed=323, contact_db=-30.0,
                       contact_lp=1200.0), gain=0.95)
    return finish(c.buf, -13, lowpass_hz=1600, room=0.06, fade_out_ms=35, highpass_hz=90.0)


def c_success():
    c = Canvas(0.400)
    for k, (f, tau, g) in enumerate(((196.0, 0.055, 0.8), (246.94, 0.055, 0.9), (293.66, 0.075, 1.0))):
        onset = 0.070 * k
        c.add(onset, knock(f, tau=tau, seconds=0.400 - onset, modes=TOK, strike_ms=3.0, seed=325 + k,
                           contact_db=-30.0, contact_lp=1300.0), gain=g)
    return finish(c.buf, -11, lowpass_hz=2000, room=0.07, fade_out_ms=45, highpass_hz=100.0)


# --------------------------------------------------------------------------------------------------- sets

SETS = {
    "current": {"start": make_start, "stop": make_stop, "lock": make_lock, "paste": make_paste,
                "cancel": make_cancel, "alert": make_alert, "error": make_error, "success": make_success,
                "modelSwitch": make_model_switch},
    "A": {"start": a_start, "stop": a_stop, "lock": a_lock, "paste": a_paste,
          "cancel": a_cancel, "alert": a_alert, "error": a_error, "success": a_success,
          "modelSwitch": a_model_switch, "polishOn": a_polish_on, "polishOff": a_polish_off},
    "B": {"start": b_start, "stop": b_stop, "lock": b_lock, "paste": b_paste,
          "cancel": b_cancel, "alert": b_alert, "error": b_error, "success": b_success,
          "modelSwitch": b_model_switch},
    "C": {"start": c_start, "stop": c_stop, "lock": c_lock, "paste": c_paste,
          "cancel": c_cancel, "alert": c_alert, "error": c_error, "success": c_success,
          "modelSwitch": c_model_switch},
}
DEFAULT_SET = "A"
SOUNDS = SETS[DEFAULT_SET]


def write_wav(path, samples):
    frames = b"".join(struct.pack("<h", int(round(max(-1.0, min(1.0, s)) * 32767))) for s in samples)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(frames)


def main():
    args = sys.argv[1:]
    chosen = DEFAULT_SET
    if "--set" in args:
        i = args.index("--set")
        chosen = args[i + 1] if i + 1 < len(args) else ""
        del args[i:i + 2]
    if chosen not in SETS:
        sys.exit(f"unknown set {chosen!r}; choose one of: {', '.join(SETS)}")
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = args[0] if args else os.path.join(root, "Resources", "Sounds")
    os.makedirs(out, exist_ok=True)
    for name, make in SETS[chosen].items():
        samples = make()
        path = os.path.join(out, f"{name}.wav")
        write_wav(path, samples)
        print(f"{name:11s} {len(samples) / SR * 1000:5.0f} ms  peak {20 * math.log10(peak(samples)):6.1f} dBFS  -> {path}")


if __name__ == "__main__":
    main()
