#!/usr/bin/env python3
"""Generate done.png and blocked.png from source.svg for the Pi recipe.

No external dependencies: writes raw PNG using zlib/struct from the stdlib.
Run: python3 gen-icons.py
"""
import struct, zlib, os
from pathlib import Path

OUT = Path(__file__).parent / "files" / ".config" / "pi" / "icons"
OUT.mkdir(parents=True, exist_ok=True)

S = 768


def make_rgba(pixel_func):
    """pixel_func(x, y) -> (r, g, b, a) in 0..255, top-left origin."""
    rows = []
    for y in range(S):
        row = bytearray([0])  # filter byte: None
        for x in range(S):
            row.extend(pixel_func(x, y))
        rows.append(row)
    raw = b"".join(rows)
    compressed = zlib.compress(raw)
    return compressed


def crc(data):
    return zlib.crc32(data) & 0xFFFFFFFF


def chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc(tag + data))


def png(data_rgba):
    out = b"\x89PNG\r\n\x1a\n"
    out += chunk(b"IHDR", struct.pack(">IIBBBBB", S, S, 8, 6, 0, 0, 0))
    out += chunk(b"IDAT", data_rgba)
    out += chunk(b"IEND", b"")
    return out


# The SVG is a blocky "pi" with 5 rectangles. Scale into 768x768.
# Normalized coordinates: viewBox 0 0 100 100.
#   left stem:   (18,16)-(30,84)
#   top bar:     (30,16)-(64,24)
#   right stem:  (50,16)-(62,40)
#   dot:         (62,52)-(74,84)

def in_shape(x, y):
    """Return True if (x,y) in 768px space is inside the blocky pi."""
    # Map pixel to viewBox [0,100)
    nx = x / S * 100
    ny = y / S * 100
    # Left stem
    if 18 <= nx < 30 and 16 <= ny < 84:
        return True
    # Top bar
    if 30 <= nx < 64 and 16 <= ny < 24:
        return True
    # Right P stem
    if 50 <= nx < 62 and 16 <= ny < 40:
        return True
    # Dot
    if 62 <= nx < 74 and 52 <= ny < 84:
        return True
    return False


def pixel_done(x, y):
    return (255, 255, 255, 255) if in_shape(x, y) else (0, 0, 0, 0)


def pixel_blocked(x, y):
    if in_shape(x, y):
        return (255, 59, 48, 255)  # SF red
    return (0, 0, 0, 0)


(OUT / "done.png").write_bytes(png(make_rgba(pixel_done)))
(OUT / "blocked.png").write_bytes(png(make_rgba(pixel_blocked)))
print(f"generated: {OUT / 'done.png'} and {OUT / 'blocked.png'}")
