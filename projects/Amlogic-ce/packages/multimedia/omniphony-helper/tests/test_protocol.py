#!/usr/bin/env python3
"""Focused helper protocol test using tests/fake_orender.c.

Usage: test_protocol.py <omniphony-helper> <libfake_orender.so> <libfake_orender_noroom.so>

The two libraries are fake_orender.c built as it is and with -DFAKE_NO_ROOM,
an engine from before rooms (see the head of fake_orender.c).
"""

import os
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from drive import Helper, OP_CLOSE, OP_FEED, OP_FLUSH, OP_OPEN, ST_INFO, ST_OK


def wait_for(helper, predicate, polls=500):
    for _ in range(polls):
        helper.drain()
        if predicate():
            return
        time.sleep(0.002)
    raise AssertionError("timed out waiting for helper output")


if len(sys.argv) != 4:
    raise SystemExit(__doc__.strip())

helper_path, library_path, noroom_path = map(os.path.abspath, sys.argv[1:])
h = Helper(helper_path)
h.send(OP_OPEN, f"lib={library_path}\n".encode())
wait_for(h, lambda: any(code == ST_OK and text.startswith("open ")
                         for code, text in h.status))

# The fake's first FEED is held entirely, as two packets that drain returns one
# per call; FLUSH must grow its output buffer, retry without losing the retained
# audio, call drain until it returns nothing, report metadata, emit audio, and
# only then acknowledge completion.
h.send(OP_FEED, b"held packet")
h.send(OP_FLUSH)
wait_for(h, lambda: any(code == ST_OK and text == "flush" for code, text in h.status))

flush_at = next(i for i, event in enumerate(h.events)
                if event[0] == "status" and event[2] == "flush")
audio_before = [event for event in h.events[:flush_at] if event[0] == "audio"]
assert [event[1] for event in audio_before] == [40000, 40000]
assert not any(event[0] == "audio" for event in h.events[flush_at + 1:])

lines = [text for code, text in h.status if code == ST_INFO]
assert any("source_label=DTS-HD_HRA_+_DTS:X_7.1.4" in text for text in lines)
assert any(text.endswith("bed=Lh,Rh,Ch,Lhs,Rhs") for text in lines)
assert any(" hrir=saf " in text for text in lines)
# The room is still loading while the first frames come out, with no
# convolution latency yet and its loudspeakers cascaded for the stand-in; the
# keys sit between hrir= and source_label=, so bed= stays last.
assert any(" hrir=saf brir=loading latency=0 render=cascade:3 source_label=" in text
           for text in lines)

# A subsequent frame clears the declaration. The empty token is intentional:
# omission would leave the host displaying the old DTS:X label forever.
h.send(OP_FEED, b"next packet")
wait_for(h, lambda: any("source_label= bed=L,R,C,Ls,Rs" in text for code, text in h.status
                         if code == ST_INFO))

# The HRIR set is live too: the configured set landing after the first block
# is reported on its own line rather than held at the first value.
assert any(" hrir=sofa " in text for code, text in h.status if code == ST_INFO)
# So is the room: once resident it is reported, with its latency, on a line
# of its own.
assert any(" brir=ready latency=127 render=room:3 " in text for code, text in h.status
           if code == ST_INFO)

# Drain is idempotent and the completion acknowledgement still follows any
# output (there should be none this time).
events_before = len(h.events)
h.send(OP_FLUSH)
wait_for(h, lambda: sum(code == ST_OK and text == "flush"
                         for code, text in h.status) == 2)
second_events = h.events[events_before:]
assert not any(event[0] == "audio" for event in second_events)
assert second_events[-1][0] == "status" and second_events[-1][2] == "flush"

h.send(OP_CLOSE)
rc, stderr = h.finish()
assert rc == 0, stderr

# The decode thread's default follows the codec - on for TrueHD and E-AC-3,
# whose decoding is a large share of the work, off otherwise - and OPEN's
# decode_thread key overrides it.
for extra, want in (("codec=truehd\n", "on"), ("codec=eac3\n", "on"),
                    ("codec=dts\n", "off"), ("", "off"),
                    ("codec=eac3\ndecode_thread=off\n", "off")):
    h = Helper(helper_path)
    h.send(OP_OPEN, f"lib={library_path}\n{extra}".encode())
    wait_for(h, lambda: any(code == ST_OK and text.startswith("open ")
                             for code, text in h.status))
    opened = next(text for code, text in h.status
                  if code == ST_OK and text.startswith("open "))
    assert opened.endswith(f"decode_thread={want}"), (extra, opened)
    h.send(OP_CLOSE)
    rc, stderr = h.finish()
    assert rc == 0, stderr


def opened_line(h):
    wait_for(h, lambda: any(code == ST_OK and text.startswith("open ")
                             for code, text in h.status))
    return next(text for code, text in h.status
                if code == ST_OK and text.startswith("open "))


# An engine from before rooms reports neither key, as empty values rather
# than by leaving them out, so the line keeps its shape.
h = Helper(helper_path)
h.send(OP_OPEN, f"lib={noroom_path}\n".encode())
opened_line(h)
h.send(OP_FEED, b"held packet")
h.send(OP_FLUSH)
wait_for(h, lambda: any(code == ST_OK and text == "flush" for code, text in h.status))
assert any(" brir= latency= render= source_label=" in text for code, text in h.status
           if code == ST_INFO)
h.send(OP_CLOSE)
rc, stderr = h.finish()
assert rc == 0, stderr

# The listener's override, composed over the host's config into a file of
# the helper's - OPEN's effective=, or effective.yaml beside the config - and
# never into the host's own; a composition there only while it is the one
# that plays. The fake engine logs what it is created from.
work = tempfile.mkdtemp(prefix="omni-helper-test-")
base = os.path.join(work, "render.yaml")
layout = os.path.join(work, "cascade-12.yaml")
log = os.path.join(work, "engine.log")
patches = {}
for name, body in (("applied", "sets two keys\n"), ("rejected", "reject\n"), ("none", "")):
    patches[name] = os.path.join(work, f"{name}.yaml")
    with open(patches[name], "w") as f:
        f.write(body)


def write_base():
    with open(base, "w") as f:
        f.write("base\n")


def base_text():
    with open(base) as f:
        return f.read()


def open_with(lib, extra):
    write_base()
    if os.path.exists(log):
        os.remove(log)
    env = dict(os.environ, FAKE_ORENDER_LOG=log)
    h = Helper(helper_path, env)
    h.send(OP_OPEN, f"lib={lib}\nconfig={base}\nlayout={layout}\n{extra}".encode())
    line = opened_line(h)
    h.send(OP_CLOSE)
    rc, stderr = h.finish()
    assert rc == 0, stderr
    with open(log) as f:
        calls = f.read().splitlines()
    return line, h, calls


# Applied: the session is created from the composition; the patch sets the
# layout, so OPEN's is dropped, and the decode thread, so the engine follows
# the composed config (live) whatever the codec or OPEN asked for. The
# host's config is left as it was written.
ram = os.path.join(work, "ram")
os.mkdir(ram)
named = os.path.join(ram, "effective.yaml")
beside = os.path.join(work, "effective.yaml")
for extra, effective in (("codec=dts\n", beside),
                         (f"codec=truehd\ndecode_thread=off\neffective={named}\n", named)):
    line, h, calls = open_with(
        library_path, f"{extra}override={patches['applied']}\noverride_dir={work}\n")
    assert line.endswith(" decode_thread=live override=applied keys=2"), (extra, line)
    assert f"create config={effective} layout=(null)" in calls, calls
    assert "set_option decode_thread=live" in calls, calls
    with open(effective) as f:
        assert f.read().startswith("composed from "), effective
    assert base_text() == "base\n"
os.remove(named)


def stale():
    """A composition left from an earlier stream, beside the config."""
    with open(beside, "w") as f:
        f.write("stale\n")


# Rejected: the host's config and layout stand, the codec's own default for
# the decode thread too, and the reason follows the acknowledgement. The
# composition the applied run left is removed: it no longer plays.
assert os.path.exists(beside)
line, h, calls = open_with(library_path, f"codec=truehd\noverride={patches['rejected']}\n")
assert line.endswith(" decode_thread=on override=rejected"), line
assert f"create config={base} layout={layout}" in calls, calls
opened_at = next(i for i, event in enumerate(h.events)
                 if event[0] == "status" and event[2].startswith("open "))
after = h.events[opened_at + 1]
assert after[0] == "status" and after[1] == ST_INFO, after
assert after[2] == "override_error fake: the patch says reject", after
assert base_text() == "base\n"
assert not os.path.exists(beside)

# None: a patch that sets nothing changes nothing.
stale()
line, h, calls = open_with(library_path, f"codec=dts\noverride={patches['none']}\n")
assert line.endswith(" decode_thread=off override=none"), line
assert f"create config={base} layout={layout}" in calls, calls
assert not os.path.exists(beside)

# Unsupported: an engine without the composition renders the host's config.
stale()
line, h, calls = open_with(noroom_path, f"override={patches['applied']}\n")
assert line.endswith(" override=unsupported"), line
assert f"create config={base} layout={layout}" in calls, calls
assert not os.path.exists(beside)

# No override asked for: the acknowledgement does not mention one.
stale()
line, h, calls = open_with(library_path, "codec=dts\n")
assert "override=" not in line, line
assert f"create config={base} layout={layout}" in calls, calls
assert not os.path.exists(beside)

# The composition is never the host's config, even when OPEN names it so.
line, h, calls = open_with(
    library_path, f"codec=dts\noverride={patches['applied']}\neffective={base}\n")
assert line.endswith(" override=rejected"), line
assert f"create config={base} layout={layout}" in calls, calls
assert base_text() == "base\n"


def run(args, stdin=b""):
    p = subprocess.run([helper_path] + args, input=stdin, capture_output=True, timeout=60)
    return p.returncode, p.stdout.decode(), p.stderr.decode()


# --prepare-brir: one line, prepared or failed with a reason word.
room = os.path.join(work, "room.room")
sofa = b"ROOM" * 100
SOURCE = "/storage/sofa/room.sofa"
rc, out, err = run(["--prepare-brir", library_path, room, SOURCE, str(len(sofa))], sofa)
assert rc == 0 and out == ("prepared emitters=3 orientations=1 seconds=0.250 rate=48000 "
                           "bytes=400 names=FL,FR,C conventions=MultiSpeakerBRIR "
                           f"source={SOURCE}\n"), (rc, out, err)
with open(room, "rb") as f:
    assert f.read() == sofa

rc, out, _ = run(["--prepare-brir", library_path, room, SOURCE, "6"], b"BADBAD")
assert rc == 1 and out == "failed reason=unusable fake: not a room response\n", (rc, out)

rc, out, _ = run(["--prepare-brir", library_path, room, SOURCE, "1000"], sofa)
assert rc == 1 and out == "failed reason=input stdin ended after 400 of 1000 bytes\n", (rc, out)

for size in ("0", "12x", "", "-5", str((4 << 30) + 1)):
    rc, out, _ = run(["--prepare-brir", library_path, room, SOURCE, size], sofa)
    assert rc == 1 and out.startswith("failed reason=input "), (size, rc, out)

rc, out, _ = run(["--prepare-brir", noroom_path, room, SOURCE, str(len(sofa))], sofa)
assert rc == 1 and out.startswith("failed reason=unsupported "), (rc, out)

rc, out, _ = run(["--prepare-brir", os.path.join(work, "missing.so"), room, SOURCE, "4"], b"ROOM")
assert rc == 1 and out.startswith("failed reason=engine "), (rc, out)

# The memory check refuses before a byte is read, when this machine is small
# enough for a file the helper accepts to exceed it.
with open("/proc/meminfo") as f:
    available = next(int(line.split()[1]) * 1024 for line in f
                     if line.startswith("MemAvailable:"))
if available <= 4 << 30:
    rc, out, _ = run(["--prepare-brir", library_path, room, SOURCE, str(available)], b"")
    assert rc == 1 and out.startswith("failed reason=memory needs "), (rc, out)
else:
    print(f"  (memory refusal not exercised: {available >> 20} MB available)")

# --describe: the engine's line after a word, or failed with a reason word.
rc, out, _ = run(["--describe", library_path, str(len(sofa))], sofa)
assert rc == 0 and out == ("described hrtf=no room=yes prepared=no conventions=MultiSpeakerBRIR "
                           "measurements=1 receivers=2 emitters=3 samples=12000 rate=48000 "
                           "orientations=1 speakers=3 names=FL,FR,C "
                           "reason=fake: 3 loudspeakers in every measurement\n"), (rc, out)
rc, out, _ = run(["--describe", library_path, "8"], b"HRTFHRTF")
assert rc == 0 and out.startswith("described hrtf=yes room=no "), (rc, out)
rc, out, _ = run(["--describe", library_path, "6"], b"BADBAD")
assert rc == 1 and out == "failed reason=unusable fake: not a SOFA file\n", (rc, out)
rc, out, _ = run(["--describe", library_path, "1000"], sofa)
assert rc == 1 and out == "failed reason=input stdin ended after 400 of 1000 bytes\n", (rc, out)
rc, out, _ = run(["--describe", noroom_path, str(len(sofa))], sofa)
assert rc == 1 and out.startswith("failed reason=unsupported "), (rc, out)
rc, out, err = run(["--describe", library_path], sofa)
assert rc == 2 and out == "" and err.startswith("usage: "), (rc, out, err)

# --prepare-hrtf: the staged set's grid, built or found kept, by path.
hrtf = os.path.join(work, "hrtf.sofa")
grid = os.path.join(work, "hrtf.grid")
with open(hrtf, "wb") as f:
    f.write(b"HRTF" * 100)
rc, out, _ = run(["--prepare-hrtf", library_path, hrtf, grid, "48000", "1"])
assert rc == 0 and out == "prepared grid=built seconds=0.100 bytes=16\n", (rc, out)
with open(grid) as f:
    assert f.read() == "grid 48000 1"
rc, out, _ = run(["--prepare-hrtf", library_path, hrtf, grid, "48000", "1"])
assert rc == 0 and out == "prepared grid=kept bytes=16\n", (rc, out)
rc, out, _ = run(["--prepare-hrtf", library_path, hrtf, grid, "96000", "0"])
assert rc == 0 and out.startswith("prepared grid=built "), (rc, out)
bad = os.path.join(work, "bad.sofa")
with open(bad, "wb") as f:
    f.write(b"BADBAD")
rc, out, _ = run(["--prepare-hrtf", library_path, bad, grid, "48000", "1"])
assert rc == 1 and out == "failed reason=unusable fake: not an HRTF set\n", (rc, out)
rc, out, _ = run(["--prepare-hrtf", library_path, hrtf, os.path.join(work, "no", "g"), "48000", "1"])
assert rc == 1 and out == "failed reason=write fake: cannot write\n", (rc, out)
for rate, eq in (("0", "1"), ("48k", "1"), ("", "1"), ("48000", "2"), ("48000", "")):
    rc, out, _ = run(["--prepare-hrtf", library_path, hrtf, grid, rate, eq])
    assert rc == 1 and out.startswith("failed reason=internal "), (rate, eq, rc, out)
rc, out, _ = run(["--prepare-hrtf", noroom_path, hrtf, grid, "48000", "1"])
assert rc == 1 and out.startswith("failed reason=unsupported "), (rc, out)
rc, out, err = run(["--prepare-hrtf", library_path, hrtf, grid, "48000"])
assert rc == 2 and out == "" and err.startswith("usage: "), (rc, out, err)

# --compose: the report, and an exit status a script can test.
composed = os.path.join(work, "out.yaml")
rc, out, _ = run(["--compose", library_path, base, patches["applied"], composed])
assert rc == 0 and out == "status=applied keys=2 layout_set=1 decode_thread_set=1\n", (rc, out)
assert os.path.exists(composed)
rc, out, _ = run(["--compose", library_path, base, patches["rejected"], composed])
assert rc == 1 and out.endswith("reason=fake: the patch says reject\n"), (rc, out)
rc, out, _ = run(["--compose", library_path, base, patches["none"], composed])
assert rc == 0 and out.startswith("status=none "), (rc, out)
rc, out, _ = run(["--compose", noroom_path, base, patches["applied"], composed])
assert rc == 2 and out.startswith("failed reason=unsupported "), (rc, out)

rc, out, err = run(["--prepare-brir", library_path, room, str(len(sofa))], sofa)
assert rc == 2 and out == "" and err.startswith("usage: "), (rc, out, err)

rc, out, err = run(["--compose", library_path, base])
assert rc == 2 and out == "" and err.startswith("usage: "), (rc, out, err)

shutil.rmtree(work)
print("helper protocol: PASS")
