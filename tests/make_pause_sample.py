"""Builds a test recording with long pauses: speech, 25 s of silence, speech,
40 s of quiet background noise, speech. A transcript must contain all three
repetitions — that is exactly the "lost speech after a pause" problem."""
import random
import sys
import wave

src, dst = sys.argv[1], sys.argv[2]
with wave.open(src, "rb") as w:
    assert w.getnchannels() == 1 and w.getsampwidth() == 2, "expects 16-bit mono"
    rate = w.getframerate()
    speech = w.readframes(w.getnframes())

silence = b"\x00\x00" * (rate * 25)
random.seed(1)
noise = b"".join(random.randint(-60, 60).to_bytes(2, "little", signed=True) for _ in range(rate * 40))

with wave.open(dst, "wb") as out:
    out.setnchannels(1)
    out.setsampwidth(2)
    out.setframerate(rate)
    out.writeframes(speech + silence + speech + noise + speech)
print(f"{dst}: {(len(speech) * 3 + len(silence) + len(noise)) / 2 / rate:.1f} s")
