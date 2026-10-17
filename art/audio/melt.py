# Synthesises the Survival melt: a sizzle, a sagging groan, bubbling and drips.
import sys, wave
import numpy as np

sr = 44100
dur = 2.4
n = int(sr * dur)
t = np.arange(n) / sr
rng = np.random.default_rng(7)

def band(x, lo, hi):
    f = np.fft.rfftfreq(len(x), 1 / sr)
    X = np.fft.rfft(x)
    m = 1 / (1 + (lo / np.maximum(f, 1)) ** 4) / (1 + (f / hi) ** 4)
    return np.fft.irfft(X * m, len(x))

def env(a, s, r):
    e = np.clip(t / a, 0, 1)
    return e * np.where(t < s, 1.0, np.exp(-(t - s) / r))

# Sizzle with crackle.
sizzle = band(rng.standard_normal(n), 2500, 10000)
crackle = np.zeros(n)
for i in rng.choice(n, 260, replace=False):
    crackle[i:i + 60] += rng.uniform(0.4, 1.0) * np.exp(-np.arange(min(60, n - i)) / 12)
sizzle = sizzle * (0.55 + 0.45 * band(crackle, 30, 400) / (np.abs(crackle).max() + 1e-9) * 6)
sizzle *= env(0.06, 1.5, 0.45)

# Steam.
steam = band(rng.standard_normal(n), 700, 3200) * env(0.4, 1.7, 0.5) * 0.5

# Groan: metal giving way.
f = 170 * np.exp(-t * 0.55) + 55 + 4 * np.sin(2 * np.pi * 5.5 * t)
groan = np.sin(2 * np.pi * np.cumsum(f) / sr) * env(0.25, 1.2, 0.6) * 0.35
groan += 0.4 * np.sin(2 * 2 * np.pi * np.cumsum(f) / sr) * env(0.25, 1.0, 0.5) * 0.35

# Bubbles.
bub = np.zeros(n)
for start in rng.uniform(0.3, 1.9, 14):
    i = int(start * sr)
    k = np.arange(int(0.07 * sr))
    k = k[: n - i]
    f0 = rng.uniform(140, 320)
    ph = 2 * np.pi * np.cumsum(f0 * (1 + 0.8 * k / len(k))) / sr
    bub[i:i + len(k)] += np.sin(ph) * np.exp(-k / (0.018 * sr)) * rng.uniform(0.3, 0.6)

# Drips.
drip = np.zeros(n)
for start in (1.15, 1.5, 1.85, 2.05):
    i = int(start * sr)
    k = np.arange(int(0.05 * sr))
    k = k[: n - i]
    ph = 2 * np.pi * np.cumsum(500 + 1400 * (k / len(k)) ** 0.5) / sr
    drip[i:i + len(k)] += np.sin(ph) * np.exp(-k / (0.012 * sr)) * 0.55

x = 0.9 * sizzle / np.abs(sizzle).max() + steam / np.abs(steam).max() * 0.35 + groan + bub * 0.7 + drip
x *= np.clip((dur - t) / 0.35, 0, 1)  # fade out
x = x / np.abs(x).max() * 10 ** (-3 / 20)
pcm = (x * 32767).astype(np.int16)
with wave.open(sys.argv[1], "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(sr)
    w.writeframes(pcm.tobytes())
