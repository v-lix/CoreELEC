#!/usr/bin/env python3
"""Drive the real helper, engine and PCM bridge, and print a pass/fail table.

    test_real_engine.py <liborender.so> <libpcm_bridge.so>

The protocol test (test_protocol.py) runs the helper against a fake engine;
this runs it against the engine and bridge the box ships, with bytes it
makes itself: an OPCM stream header and a synthesised tone. Nothing here
needs a soundtrack, and anyone with the built libraries can run all of it
but the grid of an HRTF set, which needs a set (OMNI_HRTF) and says so when
it is skipped.

The PCM bridge rather than the object bridge because it accepts audio a test
can generate. What is exercised end to end is the helper's refusal of bad
input, its framing, the engine's construction at a named rate, the reset
boundary the host relies on, and the decoded rate the stream line reports -
the parts that are not codec-specific.

    OMNI_HELPER   the helper binary to run. Not in the tree - it is built by
                  package.mk, or by hand:
                      cc -O2 -I<orender_ffi/include> \\
                         -o omniphony-helper ../sources/omniphony-helper.c -ldl
                  Defaults to ./omniphony-helper.
    OMNI_CONFIG   the engine's config. Defaults to direct.yaml beside this.
    OMNI_HRTF     a SOFA HRTF set, for the grid built when one is chosen (the
                  engine repository's renderer/tests/sofa/tester.sofa will do);
                  without it only the refusal of a file that is none is run.
    OMNI_RATE     the rate to open the renderer at. Defaults to 48000. The
                  engine builds its head model at this rate, and every rate but
                  48000 resamples it first, so a non-default value here is also
                  a check that the helper survives the slow open.
"""
import os
import shutil
import subprocess
import struct
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from drive import (Helper, opcm_header, opcm_tone, open_payload, ST, LABEL_L, LABEL_R,
                   OP_OPEN, OP_CLOSE, OP_FEED, OP_RESET,
                   ST_OK, ST_PROTOCOL, ST_STATE, ST_BRIDGE, ST_INFO)

HERE = os.path.dirname(os.path.abspath(__file__))

args = [a for a in sys.argv[1:] if not a.startswith("-")]
if len(args) < 2 or any(a in ("-h", "--help") for a in sys.argv[1:]):
    print(__doc__.strip())
    sys.exit(0 if len(sys.argv) > 1 else 2)

LIB, BRIDGE = args[0], args[1]
EXE = os.environ.get("OMNI_HELPER", "./omniphony-helper")
CONFIG = os.environ.get("OMNI_CONFIG", os.path.join(HERE, "direct.yaml"))
RATE = int(os.environ.get("OMNI_RATE", "48000"))

for label, path in (("engine", LIB), ("bridge", BRIDGE), ("helper", EXE), ("config", CONFIG)):
    if not os.path.exists(path):
        sys.exit(f"no {label} at {path} - see --help")

CHANNELS = [LABEL_L, LABEL_R]
# Twelve seconds of patience for the open, in 20 ms looks. The engine's head
# model is resampled for any rate but 48000, which is seconds on slow hardware.
OPEN_POLL_S, OPEN_POLLS = 0.02, 600
BLOCK = 4096  # frames per FEED, comfortably more than one render block

results = []


def check(ok, what, detail=""):
    results.append((what, ok))
    print(f"  {what:<52} {'PASS' if ok else 'FAIL'}{('  ' + detail) if detail else ''}")


def env():
    e = dict(os.environ)
    e["LD_LIBRARY_PATH"] = os.path.dirname(LIB)
    return e


def opened(rate=RATE):
    """A helper with the engine up and the bridge waiting for a header."""
    h = Helper(EXE, env())
    h.send(OP_OPEN, open_payload(LIB, CONFIG, BRIDGE, rate=rate))
    # The engine is built inside this call, and off 48 kHz that means resampling
    # the head model first - seconds on slow hardware. Wait for it to answer
    # rather than assuming it already has: draining is non-blocking, so a loop
    # without the sleep spins past the whole open and finds nothing. This is the
    # same wait the host does, for the same reason.
    for _ in range(OPEN_POLLS):
        h.drain()
        if any(t.startswith("open ") for _, t in h.status):
            break
        time.sleep(OPEN_POLL_S)
    return h


def feed_pcm(h, frames, start=0, rate=RATE):
    h.send(OP_FEED, opcm_tone(frames, len(CHANNELS), rate, start=start))
    h.drain()


# ---- 1. malformed input is refused, with the right answer ------------------
print("=" * 74)
print(" 1. malformed input is refused, and says which way it was wrong")
print("=" * 74)

# Each case names the exit code and the status code the helper owes, so a build
# that swallows bad input, or reports the wrong kind of wrong, fails here
# instead of passing on "it did not crash".
cases = [
    ("truncated command header", 5, ST_PROTOCOL,
     lambda h: h.send_raw(b"OMNC\x02\x00\x00\x00")),
    ("payload shorter than its length", 5, ST_PROTOCOL,
     lambda h: h.send_raw(b"OMNC" + struct.pack("<BBHII", OP_FEED, 0, 0, 4096, 0) + b"short")),
    ("garbage instead of a command", 5, ST_PROTOCOL,
     lambda h: h.send_raw(b"\xde\xad\xbe\xef" * 8)),
    ("payload length of 4 GiB", 5, ST_PROTOCOL,
     lambda h: h.send_raw(b"OMNC" + struct.pack("<BBHII", OP_FEED, 0, 0, 0xFFFFFFF0, 0))),
    ("FEED before OPEN", 5, ST_STATE,
     lambda h: h.send(OP_FEED, b"\x00" * 64)),
    ("OPEN without a lib", 5, None,
     lambda h: h.send(OP_OPEN, b"config=/dev/null\n")),
]

for label, want_rc, want_st, act in cases:
    h = Helper(EXE, env())
    act(h)
    rc, err = h.finish()
    codes = [c for c, _ in h.status]
    ok = rc == want_rc and (want_st is None or want_st in codes)
    names = ",".join(ST.get(c, str(c)) for c in codes) or "-"
    check(ok, label, f"rc={rc} (want {want_rc})  status={names}")

# Bytes that are not an OPCM stream at all: the bridge cannot read one packet of
# it and cannot read any of them, which is the case the helper is meant to tell
# apart from a damaged file. It reports and exits rather than pushing silence.
h = opened()
rnd = os.urandom(4096)
for _ in range(64):
    if not h.send(OP_FEED, rnd):
        break
    h.drain()
h.send(OP_CLOSE)
rc, err = h.finish()
codes = [c for c, _ in h.status]
check(rc == 7 and ST_BRIDGE in codes, "random bytes are reported, not swallowed",
      f"rc={rc} (want 7)  status={','.join(ST.get(c, str(c)) for c in codes)}")

# ---- 2. synthetic PCM renders ----------------------------------------------
print()
print("=" * 74)
print(f" 2. a stream this script generated renders, at {RATE} Hz")
print("=" * 74)

h = opened()
open_lines = [t for c, t in h.status if c == ST_OK and t.startswith("open ")]
check(bool(open_lines), "the engine reports itself open",
      open_lines[0] if open_lines else "no open status")
check(any(f"rate={RATE}" in t for t in open_lines),
      "and open at the rate it was asked for")

h.send(OP_FEED, opcm_header(CHANNELS, RATE))
h.drain()
for i in range(8):
    feed_pcm(h, BLOCK, start=i * BLOCK)
h.send(OP_CLOSE)
rc, err = h.finish()

frames = sum(f for f, _ in h.audio)
pts = [p for _, p in h.audio]
check(rc == 0, "the helper closes cleanly", f"rc={rc}")
check(frames > 0, "audio comes back", f"{frames} frames in {len(h.audio)} blocks")
check(all(b >= a for a, b in zip(pts, pts[1:])), "its timestamps never go backwards")
# Two channels out, whatever went in. Nothing on the wire says so - an audio
# frame carries a frame count and the reader sizes the block as frames x 2 x
# f32 - so what proves it is that every byte the helper wrote was accounted for
# under that assumption. A different channel count would have left the reader
# mid-block, and the next header it looked for would have been sample data.
check(h.buf == b"", "every block was stereo, so nothing was left unparsed",
      f"{len(h.buf)} bytes unaccounted for")

# ---- 3. the reset boundary -------------------------------------------------
print()
print("=" * 74)
print(" 3. RESET draws a boundary the host can trust")
print("=" * 74)

h = opened()
h.send(OP_FEED, opcm_header(CHANNELS, RATE))
h.drain()
for i in range(4):
    feed_pcm(h, BLOCK, start=i * BLOCK)

h.send(OP_RESET)
h.drain()
# A reset returns the bridge to expecting a header, so the new timeline starts
# with one - the same thing the host does after a seek.
h.send(OP_FEED, opcm_header(CHANNELS, RATE))
h.drain()
for i in range(4):
    feed_pcm(h, BLOCK, start=i * BLOCK)

h.send(OP_RESET)
h.drain()
h.send(OP_CLOSE)
rc, err = h.finish()

marks = [(i, t) for i, e in enumerate(h.events) if e[0] == "status"
         for t in [e[2]] if t.startswith("reset epoch=")]
check(len(marks) == 2, "one acknowledgement per reset, and only one",
      f"{len(marks)} marks: {[t for _, t in marks]}")
check([t for _, t in marks] == ["reset epoch=1", "reset epoch=2"],
      "the epochs count up, so none can be missed")

if marks:
    at = marks[0][0]
    before = [e[2] for e in h.events[:at] if e[0] == "audio"]
    after = [e[2] for e in h.events[at:] if e[0] == "audio"]
    check(bool(before) and bool(after), "audio lands on both sides of the mark",
          f"{len(before)} before, {len(after)} after")
    # This is the property the host's stale-audio drop rests on. Each timeline
    # has to be sane on its own, and the two have to be distinguishable: the
    # engine restarts its sample count at a reset, so the new timeline begins
    # behind where the old one ended. That step backwards is the thing a host
    # cannot infer safely - two seeks in quick succession, or a seek taken when
    # the only block rendered was the first, leave nothing to step back from -
    # which is why the mark exists and why the host counts marks rather than
    # comparing timestamps.
    mono_b = all(a <= b for a, b in zip(before, before[1:]))
    mono_a = all(a <= b for a, b in zip(after, after[1:]))
    check(mono_b and mono_a, "each timeline's timestamps rise on their own",
          f"old {before[0]}..{before[-1]}, new {after[0]}..{after[-1]}")
    check(after[0] < before[-1], "and the new one starts behind the old one's end",
          f"{after[0]} < {before[-1]}")
else:
    check(False, "audio lands on both sides of the mark", "no reset mark to split on")
    check(False, "each timeline's timestamps rise on their own")
    check(False, "and the new one starts behind the old one's end")

check(rc == 0, "the helper survives two resets and closes cleanly", f"rc={rc}")

# ---- 4. the decoded rate is reported, even when it is not the one asked for --
print()
print("=" * 74)
print(" 4. the stream line says what the bridge actually decoded at")
print("=" * 74)


def stream_lines(h):
    return [t for c, t in h.status if c == ST_INFO and t.startswith("stream ")]


def reported_rate(h):
    """The rate= field of the last stream line, or None if there is none."""
    lines = stream_lines(h)
    if not lines:
        return None
    at = lines[-1].find("rate=")
    return int(lines[-1][at + 5:].split()[0]) if at >= 0 else None


def run_at(open_rate, header_rate):
    """Open the engine at one rate, declare another in the stream header."""
    h = opened(rate=open_rate)
    h.send(OP_FEED, opcm_header(CHANNELS, header_rate))
    h.drain()
    for i in range(4):
        h.send(OP_FEED, opcm_tone(BLOCK, len(CHANNELS), header_rate, start=i * BLOCK))
        h.drain()
    h.send(OP_CLOSE)
    rc, _ = h.finish()
    return h, rc


# Agreement: the ordinary case, and the one that proves the field is not simply
# echoing back what the helper was told to open at - the check below only means
# something because this one passes for a different reason.
h, rc = run_at(48000, 48000)
check(rc == 0 and reported_rate(h) == 48000, "a 48 kHz stream is reported as 48 kHz",
      f"rc={rc} rate={reported_rate(h)}")

# Disagreement: the whole point. This is the shape of DTS-HD MA with a 96 kHz
# XLL extension over a 48 kHz core - the host reads the core sync word, opens
# the engine at 48000, and the bridge decodes at 96000. Nothing downstream can
# notice: the film simply plays at half speed for its whole length. The helper
# has to report what was decoded, not what it was asked for.
h, rc = run_at(48000, 96000)
opened_at = [t for t in (t for c, t in h.status if c == ST_OK) if t.startswith("open ")]
check(reported_rate(h) == 96000,
      "a 96 kHz stream opened at 48 kHz is reported as 96 kHz",
      f"rate={reported_rate(h)} while {opened_at[0] if opened_at else '?'}")
check(any("rate=48000" in t for t in opened_at) and reported_rate(h) != 48000,
      "so the two rates are distinguishable, which is what the host acts on")

# bed= has to stay last on the line: the host reads it to the end of the line
# rather than to the next space, because a bed is a comma-separated list. A new
# key appended after it would be swallowed into the bed name.
lines = stream_lines(h)
check(bool(lines) and all(t.rfind("bed=") > t.rfind("rate=") for t in lines),
      "rate= comes before bed=, so bed= is still read to end of line",
      lines[-1] if lines else "no stream line")

# ---- 5. the override template composes on this engine -------------------
print()
print("=" * 74)
print(" 5. the override template composes on this engine")
print("=" * 74)


def key_paths(text):
    """Every key path of a block-style YAML document, list items aside."""
    paths, stack = set(), []
    for line in text.splitlines():
        content = line.strip()
        if not content or content.startswith("#") or content.startswith("-") \
                or ":" not in content:
            continue
        indent = len(line) - len(line.lstrip())
        while stack and stack[-1][0] >= indent:
            stack.pop()
        key = content.split(":", 1)[0].strip()
        paths.add(".".join([k for _, k in stack] + [key]))
        stack.append((indent, key))
    return paths


def compose(patch_text):
    work = tempfile.mkdtemp(prefix="omni-compose-")
    base, patch, out = (os.path.join(work, n) for n in ("render.yaml", "config.yaml", "out.yaml"))
    with open(base, "w") as f:
        f.write("render:\n  master_gain: -12.5\n  auto_gain: false\n  binaural:\n"
                "    output_mode: binaural\n    hrir_source: saf\n")
    with open(patch, "w") as f:
        f.write(patch_text)
    # The filled template names two files; the composition checks they exist.
    for name in ("Pulse.sofa", "chunked_multispeaker_brir.sofa"):
        open(os.path.join(work, name), "wb").close()
    run = subprocess.run([EXE, "--compose", LIB, base, patch, out], capture_output=True,
                         text=True, env=env())
    written = os.path.exists(out)
    shutil.rmtree(work)
    return run.returncode, run.stdout.strip(), written


TEMPLATE = os.environ.get("OMNI_TEMPLATE",
                          os.path.join(HERE, "..", "..", "omniphony", "config",
                                       "config.example.yaml"))
with open(TEMPLATE) as f:
    template = f.read()
with open(os.path.join(HERE, "config.filled.yaml")) as f:
    filled = f.read()

rc, line, written = compose(template)
check(rc == 0 and line == "status=none keys=0 layout_set=0 decode_thread_set=0"
      and not written, "as shipped, every value null, it changes nothing", line)
rc, line, written = compose(filled)
check(rc == 0 and line.startswith("status=applied keys=")
      and line.endswith("layout_set=1 decode_thread_set=1") and written,
      "filled in with its documented values, every key applies", line)
template_keys = key_paths(template)
filled_keys = {k for k in key_paths(filled) if not k.startswith("render.current_layout.")}
check(template_keys == filled_keys and len(template_keys) > 30,
      "the filled fixture holds exactly the template's keys",
      f"{len(template_keys)} keys; differ: {sorted(template_keys ^ filled_keys)[:6]}")

# ---- 6. an HRTF set's grid is built when it is chosen ----------------------
print()
print("=" * 74)
print(" 6. an HRTF set's grid is built when it is chosen, and a stream reads it")
print("=" * 74)

work = tempfile.mkdtemp(prefix="omni-grid-")
# As Kodi names them: one file per stream rate, in kHz.
grid = os.path.join(work, f"hrtf{RATE // 1000}.grid")


def prepare_hrtf(sofa):
    run = subprocess.run([EXE, "--prepare-hrtf", LIB, sofa, grid, str(RATE), "1"],
                         capture_output=True, text=True, env=env())
    return run.returncode, run.stdout.strip()


not_sofa = os.path.join(work, "not.sofa")
with open(not_sofa, "wb") as f:
    f.write(b"\x89HDF\r\n\x1a\n" + bytes(4096))
rc, line = prepare_hrtf(not_sofa)
check(rc == 1 and line.startswith("failed reason=unusable ") and not os.path.exists(grid),
      "a file that is no HRTF set is refused, nothing kept", line[:60])

# A real set is not something a test can make, so it is the caller's: the
# engine repository's renderer/tests/sofa/tester.sofa will do.
HRTF = os.environ.get("OMNI_HRTF")
if HRTF:
    sofa = os.path.join(work, "hrtf.sofa")
    shutil.copyfile(HRTF, sofa)
    rc, line = prepare_hrtf(sofa)
    check(rc == 0 and line.startswith("prepared grid=built ") and os.path.exists(grid),
          "the set's grid is built and kept", line)
    kept = os.stat(grid).st_ino
    rc, line = prepare_hrtf(sofa)
    check(rc == 0 and line.startswith("prepared grid=kept ") and os.stat(grid).st_ino == kept,
          "chosen again, it is found kept", line)

    config = os.path.join(work, "render.yaml")
    with open(config, "w") as f:
        f.write(f"render:\n  binaural:\n    output_mode: binaural\n"
                f"    hrir_source: sofa\n    hrtf_sofa_path: '{sofa}'\n"
                f"    hrtf_grid_cache: {{ path: '{os.path.join(work, 'hrtf{khz}.grid')}', "
                f"diffuse_field_eq: true }}\n")
    h = Helper(EXE, env())
    h.send(OP_OPEN, open_payload(LIB, config, BRIDGE, rate=RATE))
    h.send(OP_FEED, opcm_header(CHANNELS, RATE))
    for i in range(OPEN_POLLS):
        feed_pcm(h, BLOCK, start=i * BLOCK)
        if any(" hrir=sofa " in t for t in stream_lines(h)):
            break
        time.sleep(OPEN_POLL_S)
    h.send(OP_CLOSE)
    h.finish()
    heard = [t for t in stream_lines(h) if " hrir=" in t]
    check(any(" hrir=sofa " in t for t in heard) and os.stat(grid).st_ino == kept,
          "the first stream plays the set from that grid, unwritten",
          heard[-1][:60] if heard else "no stream line")
else:
    print("  (OMNI_HRTF not set: the build and the stream reading it not exercised)")
shutil.rmtree(work)

print()
print("=" * 74)
passed = sum(1 for _, ok in results if ok)
print(f" {passed}/{len(results)} checks passed")
print("=" * 74)
sys.exit(0 if passed == len(results) else 1)
