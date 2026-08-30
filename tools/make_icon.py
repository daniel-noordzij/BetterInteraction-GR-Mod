"""Generate the Thunderstore icon: exactly 256x256 PNG, no dependencies.

Thunderstore rejects anything that is not 256x256, so the size is asserted
rather than assumed. PIL is not installed and is not worth adding for one
image -- CLAUDE.md rule 4, the answer is almost always the stdlib -- so this
writes the PNG by hand with zlib and struct.

The design is deliberately plain: a dark rounded tile with a single bright
interact ring, the same shape the mod spends its time drawing.
"""

import math
import os
import struct
import zlib

SIZE = 256
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "mod", "thunderstore", "icon.png")

BG = (24, 20, 17)
TILE = (44, 34, 26)
RING = (214, 173, 94)
RING_DIM = (86, 68, 44)


def rounded(x, y, left, top, right, bottom, radius):
    if x < left or x > right or y < top or y > bottom:
        return False
    for cx, cy in ((left + radius, top + radius), (right - radius, top + radius),
                   (left + radius, bottom - radius),
                   (right - radius, bottom - radius)):
        if ((x < left + radius or x > right - radius)
                and (y < top + radius or y > bottom - radius)):
            if math.hypot(x - cx, y - cy) <= radius:
                return True
            continue
    if (left + radius <= x <= right - radius) or (top + radius <= y <= bottom - radius):
        return True
    return False


def build():
    mid = SIZE / 2.0
    rows = []
    for y in range(SIZE):
        row = bytearray()
        row.append(0)                        # PNG filter: none
        for x in range(SIZE):
            colour = BG
            if rounded(x, y, 18, 18, SIZE - 18, SIZE - 18, 46):
                colour = TILE
            dist = math.hypot(x + 0.5 - mid, y + 0.5 - mid)
            # The interact ring, with a gap at the top like a progress arc.
            if 62 <= dist <= 86:
                angle = math.degrees(math.atan2(y + 0.5 - mid, x + 0.5 - mid))
                if angle < 0:
                    angle += 360
                colour = RING if not (250 <= angle <= 290) else RING_DIM
            row += bytes(colour)
        rows.append(bytes(row))
    return b"".join(rows)


def chunk(tag, payload):
    return (struct.pack(">I", len(payload)) + tag + payload
            + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))


def main():
    raw = build()
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "wb") as handle:
        handle.write(png)

    # Verified, not assumed: read the dimensions back out of the file we wrote.
    with open(OUT, "rb") as handle:
        head = handle.read(24)
    width, height = struct.unpack(">II", head[16:24])
    assert (width, height) == (SIZE, SIZE), (width, height)
    print("wrote %s  %dx%d  %d bytes" % (OUT, width, height, len(png)))


if __name__ == "__main__":
    main()
