# Synthesises the Hammer Strike's swing: a short whoosh that peaks just as
# the hammer lands (the app plays it 140 ms into the swing).
import sys, wave
import numpy as np

sr = 44100
dur = 0.30
n = int(sr * dur)
t = np.arange(n) / sr
rng = np.random.default_rng(3)
noise = rng.standard_normal(n)

# A band of noise whose centre sweeps up as the hammer speeds up.
X = np.fft.rfft(noise)
f = np.fft.rfftfreq(n, 1 / sr)
out = np.zeros(n)
frames = 30
win = n // frames
for k in range(frames):
    lo = k * win
    seg = np.zeros(n)
    seg[lo:lo + win] = noise[lo:lo + win] * np.hanning(win)
    centre = 350 + 1700 * (k / frames) ** 2
    S = np.fft.rfft(seg)
    band = np.exp(-0.5 * ((f - centre) / (centre * 0.45)) ** 2)
    out += np.fft.irfft(S * band, n)

# Swell to a peak at 0.23 s, then cut off fast (the hammer has landed).
env = np.clip(t / 0.23, 0, 1) ** 2.2 * np.where(t < 0.23, 1, np.exp(-(t - 0.23) / 0.02))
x = out * env
x = x / np.abs(x).max() * 10 ** (-6 / 20)
pcm = (x * 32767).astype(np.int16)
with wave.open(sys.argv[1], "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(sr)
    w.writeframes(pcm.tobytes())
