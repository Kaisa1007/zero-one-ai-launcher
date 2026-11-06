"""Gated RMS loudness of a 16-bit WAV (10 ms windows louder than -45 dBFS), in dBFS. Used to keep the system
voice at the same loudness when its processing changes."""
import array, math, wave


def gated_rms_dbfs(path, gate_db=-45.0):
    w = wave.open(str(path))
    n, ch, sr = w.getnframes(), w.getnchannels(), w.getframerate()
    d = array.array("h", w.readframes(n))
    win = sr // 100
    acc, cnt = 0.0, 0
    for k in range(0, n - win, win):
        s = 0
        for j in range(k * ch, (k + win) * ch):
            s += d[j] * d[j]
        ms = s / (win * ch) / (32768.0 ** 2)
        if 10 * math.log10(ms + 1e-12) > gate_db:
            acc += ms * win; cnt += win
    return 10 * math.log10(acc / cnt + 1e-12) if cnt else -120.0


def scale_wav(path, gain, ceiling=0.97):
    """Scales a 16-bit WAV in place; peaks above `ceiling` are soft-limited instead of clipped."""
    w = wave.open(str(path)); p = w.getparams(); d = array.array("h", w.readframes(w.getnframes())); w.close()
    out = array.array("h", [0] * len(d))
    for i, x in enumerate(d):
        v = x / 32768.0 * gain
        a = abs(v)
        if a > ceiling * 0.9:   # smooth knee from 90 % of the ceiling
            k = ceiling * 0.9
            a = k + (ceiling - k) * math.tanh((a - k) / (ceiling - k))
            v = math.copysign(a, v)
        out[i] = int(max(-1.0, min(1.0, v)) * 32767)
    w = wave.open(str(path), "wb"); w.setparams(p); w.writeframes(out.tobytes()); w.close()
