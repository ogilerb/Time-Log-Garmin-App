"""Generate launcher_icon.png (40x40, indexed palette).

    python make_icon.py

Kept in the repo so the icon is reproducible rather than an opaque binary. A
palette PNG is used deliberately: Garmin's resource compiler warns on 32-bit
PNGs and prefers a small indexed palette.
"""

import math
import struct
import zlib

SIZE = 40
# index 0 = transparent, 1 = white, 2 = green
PALETTE = [(0, 0, 0), (255, 255, 255), (60, 200, 90)]
ALPHA = [0, 255, 255]


def chunk(tag: bytes, data: bytes) -> bytes:
    return (
        struct.pack(">I", len(data))
        + tag
        + data
        + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    )


def render() -> list[list[int]]:
    px = [[0] * SIZE for _ in range(SIZE)]
    c = (SIZE - 1) / 2.0
    outer, inner = 18.5, 15.5

    # Dial ring, antialias-free so the palette stays at three colours.
    for y in range(SIZE):
        for x in range(SIZE):
            d = math.hypot(x - c, y - c)
            if inner <= d <= outer:
                px[y][x] = 1

    def hand(angle_deg: float, length: float, colour: int) -> None:
        # 0 degrees points up; clock angles increase clockwise.
        a = math.radians(angle_deg - 90)
        for step in range(int(length * 4)):
            r = step / 4.0
            x, y = c + r * math.cos(a), c + r * math.sin(a)
            for dx in (0, 1):
                for dy in (0, 1):
                    xi, yi = int(x) + dx, int(y) + dy
                    if 0 <= xi < SIZE and 0 <= yi < SIZE:
                        px[yi][xi] = colour

    hand(0, 9, 1)      # hour hand, straight up
    hand(105, 12, 2)   # minute hand, green accent
    return px


def main() -> None:
    px = render()

    raw = b"".join(b"\x00" + bytes(row) for row in px)
    plte = b"".join(bytes(c) for c in PALETTE)

    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 3, 0, 0, 0))
        + chunk(b"PLTE", plte)
        + chunk(b"tRNS", bytes(ALPHA))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )

    with open("launcher_icon.png", "wb") as fh:
        fh.write(png)
    print(f"wrote launcher_icon.png ({len(png)} bytes)")


if __name__ == "__main__":
    main()
