#!/usr/bin/env python3
"""Phase 1 acceptance harness for omniphony-helper.

Speaks the helper's framed protocol and checks the three things Phase 1 says
it must do: decode every test stream end to end, refuse a truncated stream
without crashing, and keep timestamps sane across a mid-stream reset.

This is a test tool, not shipped code.
"""
import os
import struct
import subprocess
import sys

HDR = 16
OP_OPEN, OP_FEED, OP_FLUSH, OP_RESET, OP_CLOSE = 1, 2, 3, 4, 5
ST = {0: "OK", 1: "PROTOCOL", 2: "OPEN_FAILED", 3: "STATE", 4: "DECODE", 5: "INFO"}


def cmd(op, payload=b""):
    return b"OMNC" + struct.pack("<BBHII", op, 0, 0, len(payload), 0) + payload


class Helper:
    def __init__(self, exe, env=None):
        self.p = subprocess.Popen([exe], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, env=env)
        self.buf = b""
        self.audio = []      # (frames, pts_us)
        self.status = []     # (code, text)
        # Audio and status in the order they arrived. The helper is strictly
        # sequential - it finishes writing a packet's audio before it reads the
        # next command - so the position of the RESET status frame in this list
        # is the exact boundary between the old timeline and the new one.
        self.events = []     # ("audio", frames, pts) | ("status", code, text)

    def send(self, op, payload=b""):
        try:
            self.p.stdin.write(cmd(op, payload))
            self.p.stdin.flush()
            return True
        except (BrokenPipeError, ValueError):
            return False

    def send_raw(self, data):
        try:
            self.p.stdin.write(data)
            self.p.stdin.flush()
            return True
        except (BrokenPipeError, ValueError):
            return False

    def drain(self, want_bytes=1 << 20):
        """Read whatever is available and parse complete frames out of it."""
        os.set_blocking(self.p.stdout.fileno(), False)
        try:
            chunk = self.p.stdout.read(want_bytes)
        except BlockingIOError:
            chunk = None
        os.set_blocking(self.p.stdout.fileno(), True)
        if chunk:
            self.buf += chunk
        self._parse()

    def read_until_quiet(self, budget=400):
        """Blocking read until the helper stops producing, bounded."""
        os.set_blocking(self.p.stdout.fileno(), True)
        for _ in range(budget):
            self.drain()
            if not self._pending():
                break
        self._parse()

    def _pending(self):
        return False

    def _parse(self):
        while len(self.buf) >= HDR:
            magic = self.buf[:4]
            if magic == b"OMNI":
                frames, pts = struct.unpack("<Iq", self.buf[4:16])
                need = HDR + frames * 2 * 4
                if len(self.buf) < need:
                    return
                self.audio.append((frames, pts))
                self.events.append(("audio", frames, pts))
                self.buf = self.buf[need:]
            elif magic == b"OMNS":
                code, ln, _ = struct.unpack("<III", self.buf[4:16])
                need = HDR + ln
                if len(self.buf) < need:
                    return
                text = self.buf[HDR:need].decode("utf-8", "replace")
                self.status.append((code, text))
                self.events.append(("status", code, text))
                self.buf = self.buf[need:]
            else:
                raise AssertionError(f"unknown magic {magic!r}")

    def finish(self, timeout=60):
        out, err = b"", b""
        try:
            out, err = self.p.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.p.kill()
            out, err = self.p.communicate()
        if out:
            self.buf += out
            self._parse()
        return self.p.returncode, err.decode("utf-8", "replace")


def open_payload(lib, config, bridge, codec, layout=None):
    lines = [f"lib={lib}", f"config={config}", f"bridge={bridge}", f"codec={codec}"]
    if layout:
        lines.append(f"layout={layout}")
    return "\n".join(lines).encode()


def feed_file(h, path, chunk=4096, limit_bytes=None, reset_after=None):
    """Feed a file. Optionally send RESET once after N bytes."""
    sent = 0
    did_reset = False
    reset_at_frame = None
    with open(path, "rb") as f:
        while True:
            if limit_bytes is not None and sent >= limit_bytes:
                break
            data = f.read(chunk)
            if not data:
                break
            if not h.send(OP_FEED, data):
                break
            sent += len(data)
            h.drain()
            if reset_after is not None and not did_reset and sent >= reset_after:
                reset_at_frame = len(h.audio)
                if not h.send(OP_RESET):
                    break
                did_reset = True
                h.drain()
    return sent, reset_at_frame
