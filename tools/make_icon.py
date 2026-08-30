"""Produce the Thunderstore icon: exactly 256x256, from whatever art is supplied.

Thunderstore rejects anything that is not 256x256, and Daniel's artwork is
650x650 -- so this resizes rather than asks him to. PIL is not installed and is
not worth a dependency for one image (CLAUDE.md rule 4: the answer is almost
always the stdlib), so the PNG is decoded, resampled and re-encoded here with
zlib and struct.

    py tools/make_icon.py                 icon-source.png -> icon.png at 256x256
    py tools/make_icon.py <path>          use a different source

Box filter, not nearest neighbour: 650 -> 256 is a 2.54x reduction, and dropping
pixels at that ratio visibly shreds fine detail. Alpha is PREMULTIPLIED before
averaging and divided out afterwards, because averaging colour and alpha
independently pulls the colour of fully transparent pixels into the edges and
leaves a halo.
"""

import os
import struct
import sys
import zlib

SIZE = 256
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(HERE, "mod", "thunderstore", "icon-source.png")
OUT = os.path.join(HERE, "mod", "thunderstore", "icon.png")


def read_png(path):
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit("%s is not a PNG" % path)
    width, height = struct.unpack(">II", data[16:24])
    depth, colour, _comp, _filt, interlace = data[24:29]
    if depth != 8 or colour not in (2, 6) or interlace != 0:
        raise SystemExit(
            "only 8-bit RGB/RGBA, non-interlaced PNGs are handled; this is "
            "depth=%d colour=%d interlace=%d" % (depth, colour, interlace))
    channels = 4 if colour == 6 else 3

    raw = b""
    index = 8
    while index + 8 <= len(data):
        length = struct.unpack(">I", data[index:index + 4])[0]
        tag = data[index + 4:index + 8]
        if tag == b"IDAT":
            raw += data[index + 8:index + 8 + length]
        index += 12 + length
        if tag == b"IEND":
            break

    return width, height, channels, unfilter(zlib.decompress(raw),
                                             width, height, channels)


def unfilter(stream, width, height, channels):
    """PNG scanline filters 0-4. Each row is prefixed with its filter type."""
    stride = width * channels
    out = bytearray(stride * height)
    previous = bytearray(stride)
    pos = 0
    for row in range(height):
        kind = stream[pos]
        pos += 1
        line = bytearray(stream[pos:pos + stride])
        pos += stride
        if kind == 1:                                   # Sub
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif kind == 2:                                 # Up
            for i in range(stride):
                line[i] = (line[i] + previous[i]) & 0xFF
        elif kind == 3:                                 # Average
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + previous[i]) >> 1)) & 0xFF
        elif kind == 4:                                 # Paeth
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                up = previous[i]
                upleft = previous[i - channels] if i >= channels else 0
                guess = left + up - upleft
                da, db, dc = abs(guess - left), abs(guess - up), abs(guess - upleft)
                near = left if (da <= db and da <= dc) else (up if db <= dc else upleft)
                line[i] = (line[i] + near) & 0xFF
        elif kind != 0:
            raise SystemExit("unknown PNG filter %d on row %d" % (kind, row))
        out[row * stride:(row + 1) * stride] = line
        previous = line
    return out


def box_resize(pixels, width, height, channels, size):
    """Average each output pixel's footprint, in premultiplied alpha."""
    out = bytearray(size * size * 4)
    for oy in range(size):
        y0, y1 = oy * height // size, max(oy * height // size + 1,
                                          (oy + 1) * height // size)
        for ox in range(size):
            x0, x1 = ox * width // size, max(ox * width // size + 1,
                                             (ox + 1) * width // size)
            r = g = b = a = n = 0
            for sy in range(y0, y1):
                base = (sy * width) * channels
                for sx in range(x0, x1):
                    i = base + sx * channels
                    alpha = pixels[i + 3] if channels == 4 else 255
                    r += pixels[i] * alpha
                    g += pixels[i + 1] * alpha
                    b += pixels[i + 2] * alpha
                    a += alpha
                    n += 1
            o = (oy * size + ox) * 4
            if a == 0:
                out[o:o + 4] = b"\x00\x00\x00\x00"
            else:
                out[o] = min(255, r // a)
                out[o + 1] = min(255, g // a)
                out[o + 2] = min(255, b // a)
                out[o + 3] = a // n
    return out


def chunk(tag, payload):
    return (struct.pack(">I", len(payload)) + tag + payload
            + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))


def write_png(path, size, rgba):
    rows = bytearray()
    for y in range(size):
        rows.append(0)                                  # filter: none
        rows += rgba[y * size * 4:(y + 1) * size * 4]
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(rows), 9))
    png += chunk(b"IEND", b"")
    open(path, "wb").write(png)
    return len(png)


def main(argv):
    source = argv[0] if argv else SOURCE
    if not os.path.isfile(source):
        raise SystemExit("no source image at " + source)

    width, height, channels, pixels = read_png(source)
    print("source %s  %dx%d  %d channels" % (os.path.basename(source),
                                             width, height, channels))
    if width != height:
        print("  NOTE: not square -- it will be squashed, not cropped")

    written = write_png(OUT, SIZE, box_resize(pixels, width, height,
                                              channels, SIZE))

    # Verified by reading back what was written, not by trusting the writer.
    check = open(OUT, "rb").read(24)
    out_w, out_h = struct.unpack(">II", check[16:24])
    assert (out_w, out_h) == (SIZE, SIZE), (out_w, out_h)
    print("wrote %s  %dx%d  %d bytes" % (OUT, out_w, out_h, written))


if __name__ == "__main__":
    main(sys.argv[1:])
