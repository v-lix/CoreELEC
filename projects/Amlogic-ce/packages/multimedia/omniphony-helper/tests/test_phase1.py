#!/usr/bin/env python3
"""Run the Phase 1 acceptance checks and print a pass/fail table."""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from drive import Helper, open_payload, feed_file, OP_OPEN, OP_CLOSE, OP_RESET, OP_FEED, cmd, ST

EXE = "/tmp/p1/omniphony-helper"
LIB = sys.argv[1]
BRIDGE = sys.argv[2]
CONFIG = "/tmp/p1/direct.yaml"
SAMPLES = "/tmp/claude-0/-home-user/a8420036-75d3-5b6c-a18f-14812caffed8/scratchpad/objtest/objtest-64/samples"

STREAMS = [
    ("ac3-51.ac3", "ac3"),
    ("dtsx-714.dts", "dts"),
    ("ddp-atmos.ec3", "eac3"),
    ("ddp-atmos-71.ec3", "eac3"),
    ("truehd-atmos.thd", "truehd"),
]

results = []


def env():
    e = dict(os.environ)
    e["LD_LIBRARY_PATH"] = os.path.dirname(LIB)
    return e


# ---- 1. every stream decodes end to end ------------------------------------
print("=" * 74)
print(" 1. all five streams decode end to end")
print("=" * 74)
for name, codec in STREAMS:
    path = os.path.join(SAMPLES, name)
    h = Helper(EXE, env())
    h.send(OP_OPEN, open_payload(LIB, CONFIG, BRIDGE, codec))
    h.drain()
    sent, _ = feed_file(h, path)
    h.send(OP_CLOSE)
    rc, err = h.finish()
    frames = sum(f for f, _ in h.audio)
    secs = frames / 48000.0
    pts = [p for _, p in h.audio]
    mono = all(b >= a for a, b in zip(pts, pts[1:])) if len(pts) > 1 else True
    info = [t for c, t in h.status if c == 5]
    ok = rc == 0 and secs > 0.5 and mono
    results.append((f"decode {name}", ok))
    print(f"  {name:<20} rc={rc}  {secs:6.2f}s in {len(h.audio):5d} blocks  "
          f"pts monotonic={mono}  {'PASS' if ok else 'FAIL'}")
    if info:
        print(f"       {info[0]}")
    if not ok and err.strip():
        print(f"       stderr: {err.strip()[:200]}")

# ---- 2. a truncated / malformed stream is refused without a crash ----------
print()
print("=" * 74)
print(" 2. truncated and malformed input is refused without a crash")
print("=" * 74)

cases = []

# 2a. a command header that stops half way
h = Helper(EXE, env())
h.send_raw(b"OMNC\x02\x00\x00\x00")          # 8 of the 16 header bytes
rc, err = h.finish()
cases.append(("truncated command header", rc, [c for c, _ in h.status]))

# 2b. a header promising a payload that never arrives
h = Helper(EXE, env())
h.send_raw(b"OMNC" + struct.pack("<BBHII", OP_FEED, 0, 0, 4096, 0) + b"short")
rc, err = h.finish()
cases.append(("payload shorter than its length", rc, [c for c, _ in h.status]))

# 2c. garbage where a command should be
h = Helper(EXE, env())
h.send_raw(b"\xde\xad\xbe\xef" * 8)
rc, err = h.finish()
cases.append(("garbage instead of a command", rc, [c for c, _ in h.status]))

# 2d. an absurd payload length, which must not be allocated
h = Helper(EXE, env())
h.send_raw(b"OMNC" + struct.pack("<BBHII", OP_FEED, 0, 0, 0xFFFFFFF0, 0))
rc, err = h.finish()
cases.append(("payload length of 4 GiB", rc, [c for c, _ in h.status]))

# 2e. FEED before OPEN
h = Helper(EXE, env())
h.send(OP_FEED, b"\x00" * 64)
rc, err = h.finish()
cases.append(("FEED before OPEN", rc, [c for c, _ in h.status]))

# 2f. a truncated *audio* stream: half a TrueHD file, then close
h = Helper(EXE, env())
h.send(OP_OPEN, open_payload(LIB, CONFIG, BRIDGE, "truehd"))
h.drain()
size = os.path.getsize(os.path.join(SAMPLES, "truehd-atmos.thd"))
feed_file(h, os.path.join(SAMPLES, "truehd-atmos.thd"), limit_bytes=size // 2)
h.send(OP_CLOSE)
rc, err = h.finish()
cases.append(("half a TrueHD file then CLOSE", rc, [c for c, _ in h.status]))

# 2g. random bytes fed as if they were a stream: must never sync, must not grow
h = Helper(EXE, env())
h.send(OP_OPEN, open_payload(LIB, CONFIG, BRIDGE, "eac3"))
h.drain()
rnd = os.urandom(4096)
for _ in range(256):
    if not h.send(OP_FEED, rnd):
        break
    h.drain()
h.send(OP_CLOSE)
rc, err = h.finish()
cases.append(("1 MB of random bytes as eac3", rc, [c for c, _ in h.status]))

for label, rc, codes in cases:
    # A crash shows as a negative return code (killed by a signal).
    crashed = rc is not None and rc < 0
    ok = not crashed
    results.append((f"no crash: {label}", ok))
    names = ",".join(ST.get(c, str(c)) for c in codes) or "-"
    print(f"  {label:<34} rc={rc!s:<5} status={names:<22} {'PASS' if ok else 'FAIL (signal)'}")

# ---- 3. timestamps across a mid-stream reset -------------------------------
print()
print("=" * 74)
print(" 3. timestamps across a mid-stream RESET")
print("=" * 74)
for name, codec in [("ddp-atmos-71.ec3", "eac3"), ("truehd-atmos.thd", "truehd")]:
    path = os.path.join(SAMPLES, name)
    half = os.path.getsize(path) // 2
    h = Helper(EXE, env())
    h.send(OP_OPEN, open_payload(LIB, CONFIG, BRIDGE, codec))
    h.drain()
    feed_file(h, path, reset_after=half)
    h.send(OP_CLOSE)
    rc, err = h.finish()
    # Split on the reset status frame's position in the output stream, not on a
    # count taken when RESET was sent: audio already in flight has not been
    # drained at that moment, so a send-time count straddles the boundary.
    at = next((i for i, e in enumerate(h.events)
               if e[0] == "status" and e[2].startswith("reset")), None)
    if at is None:
        print(f"  {name:<20} no reset status frame; inconclusive")
        results.append((f"reset {name}", False))
        continue
    before = [e[2] for e in h.events[:at] if e[0] == "audio"]
    after = [e[2] for e in h.events[at:] if e[0] == "audio"]
    if not before or not after:
        print(f"  {name:<20} RESET did not land inside the stream; inconclusive")
        results.append((f"reset {name}", False))
        continue
    mono_b = all(y >= x for x, y in zip(before, before[1:]))
    mono_a = all(y >= x for x, y in zip(after, after[1:]))
    # Each timeline must be monotonic on its own. The engine restarts its count
    # at reset, so the two are not expected to be continuous with each other -
    # what matters is that neither is corrupt and the boundary is unambiguous.
    ok = rc == 0 and mono_b and mono_a
    results.append((f"reset {name}", ok))
    print(f"  {name:<20} rc={rc}  {len(before)} blocks before, {len(after)} after")
    print(f"       pts before: {before[0]:>9} .. {before[-1]:>9}   monotonic={mono_b}")
    print(f"       pts after : {after[0]:>9} .. {after[-1]:>9}   monotonic={mono_a}")
    print(f"       timeline restarted at the reset: {after[0] < before[-1]}   "
          f"{'PASS' if ok else 'FAIL'}")

print()
print("=" * 74)
passed = sum(1 for _, ok in results if ok)
print(f" {passed}/{len(results)} checks passed")
print("=" * 74)
sys.exit(0 if passed == len(results) else 1)
