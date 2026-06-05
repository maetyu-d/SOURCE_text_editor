#!/usr/bin/env python3
import math
import os
import struct
import zlib


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICONSET = os.path.join(ROOT, "assets", "SourCe.iconset")

SIZES = {
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
}

FONT = {
    "S": ["11110", "10000", "10000", "11110", "00010", "00010", "11110"],
    "o": ["00000", "01110", "10001", "10001", "10001", "10001", "01110"],
    "u": ["00000", "10001", "10001", "10001", "10001", "10011", "01101"],
    "r": ["00000", "10110", "11001", "10000", "10000", "10000", "10000"],
    "C": ["01111", "10000", "10000", "10000", "10000", "10000", "01111"],
    "e": ["00000", "01110", "10001", "11111", "10000", "10000", "01111"],
}


def png(path, width, height, rgba):
    raw = bytearray()
    stride = width * 4
    for y in range(height):
        raw.append(0)
        raw.extend(rgba[y * stride : (y + 1) * stride])

    def chunk(kind, data):
        return (
            struct.pack(">I", len(data))
            + kind
            + data
            + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
        )

    data = b"\x89PNG\r\n\x1a\n"
    data += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    data += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    data += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(data)


def blend(buf, size, x, y, color):
    if x < 0 or y < 0 or x >= size or y >= size:
        return
    i = (y * size + x) * 4
    sr, sg, sb, sa = color
    a = sa / 255.0
    inv = 1.0 - a
    buf[i + 0] = int(sr * a + buf[i + 0] * inv)
    buf[i + 1] = int(sg * a + buf[i + 1] * inv)
    buf[i + 2] = int(sb * a + buf[i + 2] * inv)
    buf[i + 3] = min(255, int(sa + buf[i + 3] * inv))


def rect(buf, size, x, y, w, h, color):
    x0 = max(0, int(x))
    y0 = max(0, int(y))
    x1 = min(size, int(math.ceil(x + w)))
    y1 = min(size, int(math.ceil(y + h)))
    for yy in range(y0, y1):
        for xx in range(x0, x1):
            blend(buf, size, xx, yy, color)


def hash32(text):
    h = 2166136261
    for ch in text.encode("utf-8"):
        h ^= ch
        h = (h * 16777619) & 0xFFFFFFFF
    return h


def hsv(h, s, v, a=255):
    h = h % 1.0
    i = int(h * 6)
    f = h * 6 - i
    p = v * (1 - s)
    q = v * (1 - f * s)
    t = v * (1 - (1 - f) * s)
    r, g, b = [(v, t, p), (q, v, p), (p, v, t), (p, q, v), (t, p, v), (v, p, q)][i % 6]
    return int(r * 255), int(g * 255), int(b * 255), a


def draw_word(buf, size):
    word = "SourCe"
    unit = max(1, size // 54)
    gap = unit
    width = sum(len(FONT[ch][0]) * unit + gap for ch in word) - gap
    height = 7 * unit
    x = (size - width) // 2
    y = int(size * 0.58)
    colors = [
        (255, 245, 88, 245),
        (93, 255, 193, 240),
        (255, 91, 178, 240),
        (107, 160, 255, 240),
        (255, 133, 58, 240),
        (197, 106, 255, 240),
    ]
    for ci, ch in enumerate(word):
        glyph = FONT[ch]
        for gy, row in enumerate(glyph):
            for gx, bit in enumerate(row):
                if bit == "1":
                    rect(buf, size, x + gx * unit, y + gy * unit, unit, unit, colors[ci])
        x += len(glyph[0]) * unit + gap


def render(size):
    buf = bytearray(size * size * 4)
    radius = size * 0.19
    source = "SourCe SuperCollider ChucK drawMemoryMap updateFeedbackLayer self source"

    for y in range(size):
        for x in range(size):
            dx = max(size * 0.08 - x, 0, x - size * 0.92)
            dy = max(size * 0.08 - y, 0, y - size * 0.92)
            outside = math.hypot(dx, dy)
            if outside <= radius * 0.44:
                i = (y * size + x) * 4
                wave = math.sin((x + y) * 0.018) * 0.035
                buf[i + 0] = int(12 + 18 * y / size)
                buf[i + 1] = int(9 + 10 * x / size)
                buf[i + 2] = int(45 + 28 * (1 - y / size) + wave * 255)
                buf[i + 3] = 255

    for i, ch in enumerate(source):
        h = hash32(source[: i + 1])
        y = int(size * (0.13 + ((h >> 8) % 620) / 1000))
        x = int(size * (0.08 + ((h >> 17) % 740) / 1000))
        w = int(size * (0.07 + ((h >> 3) % 130) / 1000))
        stripe_h = max(1, size // (36 + (h % 19)))
        color = hsv(0.48 + ((h >> 12) % 360) / 360.0, 0.92, 0.96, 150)
        rect(buf, size, x, y, w, stripe_h, color)
        if i % 3 == 0:
            for t in range(0, size // 3, max(1, size // 80)):
                rect(buf, size, x + t, y + t, max(1, size // 72), stripe_h, hsv(0.72 + i * 0.037, 0.82, 1.0, 82))

    for y in range(int(size * 0.16), int(size * 0.47), max(1, size // 28)):
        h = hash32(source + str(y))
        x = int(size * 0.13 + (h % int(size * 0.17)))
        w = int(size * 0.45 + ((h >> 7) % int(size * 0.24)))
        rect(buf, size, x, y, w, max(1, size // 42), hsv(0.12 + (h % 90) / 320.0, 0.96, 1.0, 175))

    draw_word(buf, size)

    border = max(2, size // 48)
    rect(buf, size, size * 0.08, size * 0.09, size * 0.84, border, (255, 72, 211, 210))
    rect(buf, size, size * 0.08, size * 0.88, size * 0.84, border, (90, 255, 228, 170))
    return buf


def main():
    os.makedirs(ICONSET, exist_ok=True)
    for name, size in SIZES.items():
        png(os.path.join(ICONSET, name), size, size, render(size))


if __name__ == "__main__":
    main()
