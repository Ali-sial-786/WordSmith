"""Small DSP + synthesis toolkit for Wordsmith's sound effects.

Everything works on mono float64 numpy arrays at 44.1 kHz. Decoding, loudness
measurement and Vorbis encoding go through ffmpeg (must be on PATH). The only
Python dependency is numpy.

Synthesised voices (all original work):
  * tink()   - small struck steel bar (free-free bar modes) + strike click
  * anvil()  - anvil ring: inharmonic modes with beating pairs + hammer thump
  * bell()   - handbell-like tone used for chimes, "go" and the level-up stinger
  * sizzle(), quench(), whoosh(), sparkles(), crackle(), puff() - noise-based layers
"""
from __future__ import annotations

import re
import subprocess

import numpy as np

SR = 44100


# ---------------------------------------------------------------- basics
def n_samples(dur: float) -> int:
    return int(round(dur * SR))


def silence(dur: float) -> np.ndarray:
    return np.zeros(n_samples(dur))


def t_axis(n: int) -> np.ndarray:
    return np.arange(n) / SR


def db(x: float) -> float:
    return 20 * np.log10(max(float(x), 1e-12))


def undb(d: float) -> float:
    return 10 ** (d / 20)


def place(dst: np.ndarray, src: np.ndarray, at: float, gain: float = 1.0) -> np.ndarray:
    """Mix src into dst starting at `at` seconds (dst is grown if needed)."""
    i = n_samples(at)
    end = i + len(src)
    if end > len(dst):
        dst = np.concatenate([dst, np.zeros(end - len(dst))])
    dst[i:end] += gain * src
    return dst


def fade(x: np.ndarray, fade_in: float = 0.0, fade_out: float = 0.0) -> np.ndarray:
    y = x.copy()
    if fade_in > 0:
        k = min(len(y), n_samples(fade_in))
        y[:k] *= 0.5 - 0.5 * np.cos(np.linspace(0, np.pi, k))
    if fade_out > 0:
        k = min(len(y), n_samples(fade_out))
        y[len(y) - k:] *= 0.5 + 0.5 * np.cos(np.linspace(0, np.pi, k))
    return y


def trim(x: np.ndarray, start_db: float = -50, end_db: float = -60, pre: float = 0.002) -> np.ndarray:
    """Cut leading/trailing silence relative to the peak, keeping a tiny pre-roll."""
    pk = np.max(np.abs(x)) + 1e-12
    a = np.where(np.abs(x) > pk * undb(start_db))[0]
    b = np.where(np.abs(x) > pk * undb(end_db))[0]
    if len(a) == 0:
        return x
    i0 = max(0, a[0] - n_samples(pre))
    return x[i0:b[-1] + 1]


def fit(x: np.ndarray, dur: float, fade_out: float) -> np.ndarray:
    """Crop/pad to `dur` seconds and apply a raised-cosine fade-out."""
    n = n_samples(dur)
    y = x[:n] if len(x) >= n else np.concatenate([x, np.zeros(n - len(x))])
    return fade(y, fade_out=fade_out)


def normalize_peak(x: np.ndarray, peak: float = 1.0) -> np.ndarray:
    return x * (peak / (np.max(np.abs(x)) + 1e-12))


# ---------------------------------------------------------------- filters
def _butter_mag(f: np.ndarray, lo: float | None, hi: float | None, order: int) -> np.ndarray:
    h = np.ones_like(f)
    with np.errstate(divide="ignore"):
        if hi:
            h = h / np.sqrt(1 + (f / hi) ** (2 * order))
        if lo:
            h = h / np.sqrt(1 + (lo / np.maximum(f, 1e-6)) ** (2 * order))
    return h


def fft_filter(x: np.ndarray, lo: float | None = None, hi: float | None = None, order: int = 2) -> np.ndarray:
    """Zero-phase Butterworth-magnitude band/low/high-pass (offline, via FFT)."""
    pad = n_samples(0.25)
    n = 1 << int(np.ceil(np.log2(len(x) + 2 * pad)))
    X = np.fft.rfft(np.concatenate([x, np.zeros(n - len(x))]))
    f = np.fft.rfftfreq(n, 1 / SR)
    return np.fft.irfft(X * _butter_mag(f, lo, hi, order), n)[: len(x)]


def svf_bandpass(x: np.ndarray, fc: np.ndarray, q: float = 1.5) -> np.ndarray:
    """Time-varying state-variable band-pass (TPT form); fc is per-sample Hz."""
    fc = np.broadcast_to(np.asarray(fc, dtype=float), x.shape)
    g = np.tan(np.pi * np.clip(fc, 20, SR * 0.45) / SR)
    k = 1.0 / q
    a1 = 1 / (1 + g * (g + k))
    ic1 = ic2 = 0.0
    out = np.empty_like(x)
    for i in range(len(x)):
        v3 = x[i] - ic2
        v1 = a1[i] * ic1 + g[i] * a1[i] * v3
        v2 = ic2 + g[i] * v1
        ic1 = 2 * v1 - ic1
        ic2 = 2 * v2 - ic2
        out[i] = v1 * k  # unity-gain band-pass
    return out


def resample_pitch(x: np.ndarray, ratio: float) -> np.ndarray:
    """Tape-style pitch shift: ratio > 1 is higher and shorter."""
    if ratio > 1:
        x = fft_filter(x, hi=0.45 * SR / ratio, order=6)
    pos = np.arange(0, len(x) - 1, ratio)
    return np.interp(pos, np.arange(len(x)), x)


def true_peak(x: np.ndarray, oversample: int = 4) -> float:
    """Approximate ITU-R BS.1770 true peak (linear) via FFT oversampling."""
    peaks = []
    for ch in ([x] if x.ndim == 1 else x.T):
        n = len(ch)
        X = np.fft.rfft(np.concatenate([ch, np.zeros(64)]))
        y = np.fft.irfft(X, (n + 64) * oversample) * oversample
        peaks.append(np.max(np.abs(y)))
    return float(max(peaks))


def limit(x: np.ndarray, ceiling: float, lookahead: float = 0.0015, release: float = 0.06) -> np.ndarray:
    """Look-ahead peak limiter working on the 4x-oversampled envelope.

    Gain = min-hold over the look-ahead window -> one-pole release -> trailing box
    average of the same length. That chain never exceeds the gain each sample
    needs, so the output stays under `ceiling`, and the gain never steps (no clicks).
    """
    mono = np.abs(x) if x.ndim == 1 else np.max(np.abs(x), axis=1)
    n = len(mono)
    sig = x if x.ndim == 1 else x.mean(axis=1)
    X = np.fft.rfft(np.concatenate([sig, np.zeros(64)]))
    up = np.abs(np.fft.irfft(X, (n + 64) * 4) * 4)[: n * 4].reshape(n, 4).max(axis=1)
    env = np.maximum(up, mono)
    need = np.minimum(1.0, ceiling / np.maximum(env, 1e-12))
    w = max(1, n_samples(lookahead))
    held = np.min(np.lib.stride_tricks.sliding_window_view(np.concatenate([need, np.ones(w)]), w + 1), axis=1)[:n]
    coef = np.exp(-1 / (release * SR))
    g = np.empty(n)
    cur = 1.0
    for i in range(n):
        cur = held[i] if held[i] < cur else held[i] + (cur - held[i]) * coef
        g[i] = cur
    c = np.cumsum(np.concatenate([np.full(w, g[0]), g]))
    g = (c[w:] - c[:-w]) / w
    return x * (g if x.ndim == 1 else g[:, None])


# ---------------------------------------------------------------- ffmpeg I/O
def load(path: str, channels: int = 1) -> np.ndarray:
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(path), "-ac", str(channels), "-ar", str(SR), "-f", "f32le", "-"],
        capture_output=True, check=True).stdout
    x = np.frombuffer(raw, dtype=np.float32).astype(np.float64)
    return x if channels == 1 else x.reshape(-1, channels)


def _pcm_args(x: np.ndarray) -> list[str]:
    ch = 1 if x.ndim == 1 else x.shape[1]
    return ["-f", "f32le", "-ar", str(SR), "-ac", str(ch), "-i", "pipe:0"]


def measure(x: np.ndarray) -> dict:
    """EBU R128 loudness via ffmpeg: integrated (LUFS), max momentary (LUFS-M) and true peak (dBTP).

    The clip is padded with a second of silence on each side so even very short
    sounds yield 400 ms measurement blocks. For one-shot SFX the max momentary
    loudness is the stable measure (a clip under 300 ms always fits wholly inside
    one 400 ms block); integrated loudness is used for the ambience loop.
    """
    pad = np.zeros((SR,) + x.shape[1:])
    data = np.concatenate([pad, x, pad]).astype(np.float32).tobytes()
    err = subprocess.run(["ffmpeg", "-nostats", "-hide_banner", *_pcm_args(x),
                          "-af", "ebur128=peak=true", "-f", "null", "-"],
                         input=data, capture_output=True, check=True).stderr.decode()
    summary = err[err.rfind("Summary:"):]
    lufs = float(re.search(r"I:\s+(-?[\d.]+|-inf) LUFS", summary).group(1))
    tp = float(re.search(r"Peak:\s+(-?[\d.]+|-inf) dBFS", summary).group(1))
    moms = [float(v) for v in re.findall(r"\bM:\s*(-?[\d.]+)", err[:err.rfind("Summary:")])]
    return {"lufs": lufs, "mmax": max(moms) if moms else float("-inf"), "tp": tp}


def measure_file(path: str) -> dict:
    return measure(load(path, channels=int(probe(path)["channels"])))


def probe(path: str) -> dict:
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries",
                          "stream=codec_name,channels,sample_rate:format=duration,size",
                          "-of", "default=nw=1", str(path)], capture_output=True, text=True, check=True).stdout
    return dict(line.split("=", 1) for line in out.strip().splitlines())


def encode_ogg(x: np.ndarray, path: str, quality: float = 4) -> None:
    """Encode to Ogg Vorbis, bit-exact (no random stream serial, no encoder tag)."""
    subprocess.run(["ffmpeg", "-v", "error", "-y", *_pcm_args(x), "-c:a", "libvorbis", "-q:a", str(quality),
                    "-fflags", "+bitexact", "-flags:a", "+bitexact", "-map_metadata", "-1", str(path)],
                   input=x.astype(np.float32).tobytes(), check=True)


# ---------------------------------------------------------------- voices
def _partial(t, f, amp, tau, phase=0.0, detune_cents=0.0):
    if f >= SR * 0.48:
        return np.zeros_like(t)
    env = amp * np.exp(-t / tau)
    if detune_cents:
        # main tone + a quieter, slightly detuned twin: gentle shimmer (~30% beating
        # depth) rather than a full tremolo that would chop short sounds in two
        d = 2 ** (detune_cents / 1200)
        return env * (np.sin(2 * np.pi * f * t + phase) + 0.3 * np.sin(2 * np.pi * f * d * t + phase * 1.7)) / 1.3
    return env * np.sin(2 * np.pi * f * t + phase)


def modal(freqs, amps, taus, dur: float, detune_cents: float = 0.0, seed: int = 0) -> np.ndarray:
    """Sum of exponentially decaying sinusoids (generic struck-object body)."""
    rng = np.random.default_rng(seed)
    t = t_axis(n_samples(dur))
    x = sum(_partial(t, f, a, tau, phase=rng.uniform(0, 2 * np.pi), detune_cents=detune_cents)
            for f, a, tau in zip(freqs, amps, taus))
    return fade(x, fade_in=0.0008)


def thump(dur: float, f_hi: float = 120, f_lo: float = 70, tau: float = 0.04) -> np.ndarray:
    """Pitch-dropping low body hit."""
    t = t_axis(n_samples(dur))
    f = (f_hi - f_lo) * np.exp(-t / (tau * 1.2)) + f_lo
    return fade(np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / tau), fade_in=0.001)


def level(x: np.ndarray, ref_db: float = -18.0, win: float = 0.05) -> np.ndarray:
    """Scale so the loudest `win`-second RMS window sits at `ref_db` dBFS.

    Used to balance layers before mixing: a layer placed at -6 dB is then roughly
    6 dB quieter than one placed at 0 dB, whatever its crest factor.
    """
    w = max(1, n_samples(win))
    e = np.convolve(x ** 2, np.ones(w) / w, "same")
    return x * (undb(ref_db) / (np.sqrt(np.max(e)) + 1e-12))


def noise(n: int, rng: np.random.Generator) -> np.ndarray:
    return rng.standard_normal(n)


def click(rng: np.random.Generator, dur: float = 0.004, lo: float = 2000, hi: float = 12000, tau: float = 0.0012) -> np.ndarray:
    """Short band-limited noise burst: the 'strike' of a hard object."""
    n = n_samples(dur)
    x = fft_filter(noise(n, rng), lo=lo, hi=hi) * np.exp(-t_axis(n) / tau)
    return normalize_peak(x)


# Free-free bar mode ratios (Euler-Bernoulli): the classic glockenspiel/bar "tink".
BAR_RATIOS = (1.0, 2.756, 5.404, 8.933)


def tink(f0: float, dur: float = 0.22, seed: int = 7) -> np.ndarray:
    """Small struck steel bar. Same recipe for every pitch so the timbre matches."""
    rng = np.random.default_rng(seed)  # same seed for every note -> identical strike click
    t = t_axis(n_samples(dur))
    amps = (1.0, 0.42, 0.20, 0.07)
    taus = (0.105, 0.050, 0.028, 0.016)
    x = sum(_partial(t, f0 * r, a, tau, phase=0.3 * i, detune_cents=5.0)
            for i, (r, a, tau) in enumerate(zip(BAR_RATIOS, amps, taus)))
    x = fade(x, fade_in=0.0006)
    x = place(x, click(rng, dur=0.004, lo=2500, hi=14000), 0.0, 0.22)
    return fit(x, dur, fade_out=0.06)


ANVIL_RATIOS = (1.0, 1.47, 2.09, 2.56, 3.18, 3.91, 4.77, 5.62, 6.81)
ANVIL_AMPS = (0.80, 0.55, 1.00, 0.60, 0.50, 0.36, 0.26, 0.16, 0.10)
ANVIL_TAUS = (0.90, 0.50, 0.75, 0.45, 0.36, 0.26, 0.18, 0.12, 0.09)


def anvil(f0: float, dur: float, decay: float = 1.0, bright: float = 1.0, thump_gain: float = 0.5,
          seed: int = 11) -> np.ndarray:
    """Hammer on anvil: inharmonic plate-like modes with beating pairs, strike click, low thump."""
    rng = np.random.default_rng(seed)
    t = t_axis(n_samples(dur))
    x = np.zeros_like(t)
    for i, (r, a, tau) in enumerate(zip(ANVIL_RATIOS, ANVIL_AMPS, ANVIL_TAUS)):
        tilt = bright ** (i / (len(ANVIL_RATIOS) - 1))  # >1 favours high modes
        x += _partial(t, f0 * r, a * tilt, tau * decay, phase=rng.uniform(0, 2 * np.pi),
                      detune_cents=rng.uniform(2.0, 6.0))
    x = fade(x, fade_in=0.0005)
    x = place(x, click(rng, dur=0.006, lo=1500, hi=15000, tau=0.0015), 0.0, 0.5)
    if thump_gain:
        # pitch-dropping low body hit (felt more than heard on phone speakers)
        x += thump_gain * thump(dur, 115 + 70, 70, 0.045)
    return fit(x, dur, fade_out=min(0.25, dur * 0.3))


BELL_PARTIALS = ((1.0, 1.0, 1.0), (2.0, 0.45, 0.62), (3.0, 0.32, 0.45), (4.16, 0.12, 0.28),
                 (5.43, 0.08, 0.18), (6.79, 0.04, 0.12))


def bell(f0: float, dur: float, tau: float = 0.9, seed: int = 3, strike: float = 0.12) -> np.ndarray:
    """Handbell / glockenspiel-like tone: near-harmonic partials, beating, soft strike."""
    rng = np.random.default_rng(seed)
    t = t_axis(n_samples(dur))
    x = sum(_partial(t, f0 * r, a, tau * k, phase=rng.uniform(0, 2 * np.pi), detune_cents=3.0)
            for r, a, k in BELL_PARTIALS)
    x = fade(x, fade_in=0.0015)
    if strike:
        x = place(x, click(rng, dur=0.003, lo=3000, hi=12000), 0.0, strike)
    return fit(x, dur, fade_out=min(0.3, dur * 0.35))


def sparkles(dur: float, count: int, seed: int, f_range=(3000, 9000), decay: float = 0.35) -> np.ndarray:
    """Random tiny metallic pings + pops: flying sparks."""
    rng = np.random.default_rng(seed)
    x = silence(dur)
    times = np.sort(rng.exponential(decay, count))
    times = times[times < dur - 0.05]
    for at in times:
        level = np.exp(-at / (decay * 1.5)) * rng.uniform(0.35, 1.0)
        n = n_samples(rng.uniform(0.015, 0.045))
        t = t_axis(n)
        f = rng.uniform(*f_range)
        ping = np.sin(2 * np.pi * f * t) * np.exp(-t / rng.uniform(0.006, 0.02))
        x = place(x, fade(ping, fade_in=0.0004), at, 0.6 * level)
        x = place(x, click(rng, dur=0.002, lo=3000, hi=16000, tau=0.0005), at, 0.5 * level)
    return x[: n_samples(dur)]


def crackle(dur: float, rate: float, seed: int, lo: float = 1500, hi: float = 12000) -> np.ndarray:
    """Sparse random pops (Poisson process), like wood or scale crackling."""
    rng = np.random.default_rng(seed)
    x = silence(dur)
    at = rng.exponential(1 / rate)
    while at < dur - 0.01:
        x = place(x, click(rng, dur=rng.uniform(0.001, 0.004), lo=lo, hi=hi, tau=rng.uniform(0.0003, 0.0012)),
                  at, rng.uniform(0.2, 1.0) ** 2)
        at += rng.exponential(1 / rate)
    return x[: n_samples(dur)]


def sizzle(dur: float, seed: int, attack: float = 0.04, tau: float = 0.3) -> np.ndarray:
    """Hot metal touching moisture: bright hiss with crackle modulation."""
    rng = np.random.default_rng(seed)
    n = n_samples(dur)
    t = t_axis(n)
    hiss = fft_filter(noise(n, rng), lo=2500, hi=9500, order=3)
    hiss = normalize_peak(hiss) * 0.5
    wobble = 0.65 + 0.35 * normalize_peak(np.abs(fft_filter(noise(n, rng), hi=30)))
    x = hiss * wobble + 0.45 * crackle(dur, rate=90, seed=seed + 1, lo=2000)
    env = (1 - np.exp(-t / attack)) * np.exp(-t / tau)
    return fade(x * env, fade_out=min(0.15, dur * 0.3))


def quench(dur: float, seed: int) -> np.ndarray:
    """Red-hot steel plunged into water: steam hiss + bubbling + crackle."""
    rng = np.random.default_rng(seed)
    n = n_samples(dur)
    t = t_axis(n)
    steam = normalize_peak(fft_filter(noise(n, rng), lo=1200, hi=7500, order=2))
    steam_env = (1 - np.exp(-t / 0.06)) * np.exp(-t / (dur * 0.45))
    x = 0.6 * steam * steam_env
    # bubbling: short upward-gliding low blips, denser at the start
    at = 0.02
    while at < dur * 0.8:
        m = n_samples(rng.uniform(0.02, 0.05))
        tt = t_axis(m)
        f0 = rng.uniform(180, 520)
        f = f0 * (1 + 1.2 * tt / tt[-1])
        blip = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.sin(np.pi * np.arange(m) / m) ** 2
        x = place(x, blip, at, 0.22 * np.exp(-at / (dur * 0.4)) * rng.uniform(0.4, 1.0))
        at += rng.exponential(0.035)
    x = x[:n] + 0.35 * crackle(dur, rate=60, seed=seed + 5) * np.exp(-t / (dur * 0.35))
    return fade(x, fade_out=min(0.4, dur * 0.3))


def whoosh(dur: float, f_start: float, f_end: float, seed: int, q: float = 1.2, peak_at: float = 0.5) -> np.ndarray:
    """Band-pass swept noise with a swell envelope (air / embers rushing)."""
    rng = np.random.default_rng(seed)
    n = n_samples(dur)
    u = np.linspace(0, 1, n)
    fc = f_start * (f_end / f_start) ** u
    x = svf_bandpass(noise(n, rng), fc, q=q)
    env = np.where(u < peak_at, np.sin(0.5 * np.pi * u / peak_at) ** 2,
                   np.cos(0.5 * np.pi * (u - peak_at) / (1 - peak_at)) ** 2)
    return normalize_peak(x * env)


def puff(dur: float, seed: int, lo: float = 250, hi: float = 1800) -> np.ndarray:
    """Bellows puff: a short, soft burst of air."""
    rng = np.random.default_rng(seed)
    n = n_samples(dur)
    t = t_axis(n)
    x = fft_filter(noise(n, rng), lo=lo, hi=hi, order=2)
    env = np.sin(np.pi * np.clip(t / 0.06, 0, 0.5)) ** 2 * np.exp(-np.maximum(t - 0.03, 0) / (dur * 0.3))
    return fade(normalize_peak(x * env), fade_out=dur * 0.3)
