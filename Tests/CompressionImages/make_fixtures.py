#!/usr/bin/env python3
import binascii
import os
import struct
import sys
import zlib

OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)


def chunk(name, data):
    return struct.pack(">I", len(data)) + name + data + struct.pack(">I", binascii.crc32(name + data) & 0xFFFFFFFF)


def channels(color_type):
    return {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color_type]


def pack_row(pixels, bit_depth, color_type):
    values = [v for pixel in pixels for v in (pixel if isinstance(pixel, tuple) else (pixel,))]
    if bit_depth == 16:
        return b"".join(struct.pack(">H", value) for value in values)
    if bit_depth == 8:
        return bytes(values)
    out = bytearray()
    current = bits = 0
    for value in values:
        current = (current << bit_depth) | value
        bits += bit_depth
        if bits == 8:
            out.append(current)
            current = bits = 0
    if bits:
        out.append(current << (8 - bits))
    return bytes(out)


PASSES = ((0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4),
          (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2))


def encoded_rows(grid, width, height, bit_depth, color_type, interlace):
    if not interlace:
        return b"".join(b"\0" + pack_row(grid[y], bit_depth, color_type) for y in range(height))
    result = bytearray()
    for x0, y0, dx, dy in PASSES:
        xs = list(range(x0, width, dx))
        ys = list(range(y0, height, dy))
        if not xs or not ys:
            continue
        for y in ys:
            result += b"\0" + pack_row([grid[y][x] for x in xs], bit_depth, color_type)
    return bytes(result)


def make_png(path, width, height, bit_depth, color_type, grid, interlace=0, extras=(), palette=None, trns=None):
    ihdr = struct.pack(">IIBBBBB", width, height, bit_depth, color_type, 0, 0, interlace)
    body = [chunk(b"IHDR", ihdr)]
    if palette is not None:
        body.append(chunk(b"PLTE", palette))
    if trns is not None:
        body.append(chunk(b"tRNS", trns))
    body.extend(chunk(name, data) for name, data in extras if name not in (b"tEXt",))
    compressed = zlib.compress(encoded_rows(grid, width, height, bit_depth, color_type, interlace), 6)
    midpoint = max(1, len(compressed) // 2)
    body += [chunk(b"IDAT", compressed[:midpoint]), chunk(b"IDAT", compressed[midpoint:])]
    body.extend(chunk(name, data) for name, data in extras if name == b"tEXt")
    body.append(chunk(b"IEND", b""))
    with open(path, "wb") as handle:
        handle.write(b"\x89PNG\r\n\x1a\n" + b"".join(body))


def parse_png(path):
    data = open(path, "rb").read()
    pos = 8
    chunks = []
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        raw = data[pos:pos + 12 + length]
        chunks.append((raw[4:8], raw[8:8 + length], raw))
        pos += 12 + length
    return chunks


def rewrite_png(source, output, mutate_pixel=False, mutate_metadata=False, metadata_free=False, refilter=False):
    parsed = parse_png(source)
    raw = zlib.decompress(b"".join(data for name, data, _ in parsed if name == b"IDAT"))
    if mutate_pixel:
        raw = bytearray(raw)
        raw[2] ^= 1
        raw = bytes(raw)
    if refilter:
        rebuilt_rows = bytearray()
        row_bytes, bpp, offset = 7 * 4, 4, 0
        for _ in range(5):
            assert raw[offset] == 0
            row = raw[offset + 1:offset + 1 + row_bytes]
            rebuilt_rows.append(1)
            rebuilt_rows.extend((value - (row[index - bpp] if index >= bpp else 0)) & 255
                                for index, value in enumerate(row))
            offset += 1 + row_bytes
        raw = bytes(rebuilt_rows)
    compressed = zlib.compress(raw, 9)
    rebuilt = [b"\x89PNG\r\n\x1a\n"]
    inserted = False
    for name, data, whole in parsed:
        if name == b"IDAT":
            if not inserted:
                rebuilt.append(chunk(b"IDAT", compressed))
                inserted = True
            continue
        if metadata_free and name not in (b"IHDR", b"PLTE", b"tRNS", b"IEND"):
            continue
        if mutate_metadata and name == b"tEXt":
            rebuilt.append(chunk(name, data + b" changed"))
        else:
            rebuilt.append(whole)
    with open(output, "wb") as handle:
        handle.write(b"".join(rebuilt))


icc = zlib.compress(b"strict-test-icc-profile")
metadata = ((b"iCCP", b"Test ICC\0\0" + icc), (b"eXIf", b"Exif\0\0strict"),
            (b"vpAg", b"safe-private-data"), (b"tEXt", b"Comment\0preserve exactly"))

rgba8 = [[((x * 31 + 7) & 255, (y * 47 + 11) & 255, (x * 13 + y * 19 + 3) & 255,
           0 if (x + y) % 3 == 0 else 255) for x in range(7)] for y in range(5)]
make_png(os.path.join(OUT, "rgba8.png"), 7, 5, 8, 6, rgba8, extras=metadata)
rewrite_png(os.path.join(OUT, "rgba8.png"), os.path.join(OUT, "rgba8-recompressed.png"))
rewrite_png(os.path.join(OUT, "rgba8.png"), os.path.join(OUT, "rgba8-refiltered.png"), refilter=True)
rewrite_png(os.path.join(OUT, "rgba8.png"), os.path.join(OUT, "rgba8-pixel-change.png"), mutate_pixel=True)
rewrite_png(os.path.join(OUT, "rgba8.png"), os.path.join(OUT, "rgba8-metadata-change.png"), mutate_metadata=True)
rewrite_png(os.path.join(OUT, "rgba8.png"), os.path.join(OUT, "rgba8-optimized.png"), metadata_free=True)

gray1 = [[(x + y) & 1 for x in range(9)] for y in range(3)]
make_png(os.path.join(OUT, "gray1.png"), 9, 3, 1, 0, gray1)
rewrite_png(os.path.join(OUT, "gray1.png"), os.path.join(OUT, "gray1-recompressed.png"))

rgba16 = [[(x * 5000 + 123, y * 7000 + 456, x * 3000 + y * 2000 + 789,
            0 if x == 0 else 65535) for x in range(4)] for y in range(3)]
make_png(os.path.join(OUT, "rgba16.png"), 4, 3, 16, 6, rgba16)
rewrite_png(os.path.join(OUT, "rgba16.png"), os.path.join(OUT, "rgba16-recompressed.png"))

grayalpha = [[((x * 37 + y * 13) & 255, 0 if x == 1 else 255) for x in range(6)] for y in range(4)]
make_png(os.path.join(OUT, "grayalpha8.png"), 6, 4, 8, 4, grayalpha)
rewrite_png(os.path.join(OUT, "grayalpha8.png"), os.path.join(OUT, "grayalpha8-recompressed.png"))

palette = bytes((255, 0, 0, 0, 255, 0, 0, 0, 255, 40, 50, 60))
indexed = [[(x + y) % 4 for x in range(7)] for y in range(4)]
make_png(os.path.join(OUT, "palette2.png"), 7, 4, 2, 3, indexed, palette=palette, trns=bytes((255, 128, 0, 255)))
rewrite_png(os.path.join(OUT, "palette2.png"), os.path.join(OUT, "palette2-recompressed.png"))

adam = [[((x * 23) & 255, (y * 29) & 255, ((x + y) * 17) & 255) for x in range(9)] for y in range(8)]
make_png(os.path.join(OUT, "adam7.png"), 9, 8, 8, 2, adam, interlace=1)
rewrite_png(os.path.join(OUT, "adam7.png"), os.path.join(OUT, "adam7-recompressed.png"))

for name, special in (("apng", (b"acTL", struct.pack(">II", 1, 0))),
                      ("c2pa", (b"caBX", b"c2pa manifest")),
                      ("hdr", (b"cICP", bytes((9, 16, 0, 1)))),
                      ("unsafe", (b"vpAG", b"unsafe-private-data")),
                      ("unknown-critical", (b"ABCD", b"unknown"))):
    make_png(os.path.join(OUT, name + ".png"), 7, 5, 8, 6, rgba8, extras=(special,))

bad = bytearray(open(os.path.join(OUT, "rgba8.png"), "rb").read())
bad[20] ^= 1
open(os.path.join(OUT, "bad-crc.png"), "wb").write(bad)

huge_ihdr = struct.pack(">IIBBBBB", 100000, 1010, 8, 6, 0, 0, 0)
open(os.path.join(OUT, "huge.png"), "wb").write(
    b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", huge_ihdr) + chunk(b"IDAT", zlib.compress(b"")) + chunk(b"IEND", b""))


def inject_jpeg(source, output, segments=(), trailing=b""):
    data = open(source, "rb").read()
    assert data[:2] == b"\xff\xd8"
    markers = []
    for marker, payload in segments:
        markers.append(b"\xff" + bytes((marker,)) + struct.pack(">H", len(payload) + 2) + payload)
    with open(output, "wb") as handle:
        handle.write(data[:2] + b"".join(markers) + data[2:] + trailing)


def oversized_jpeg_header(source, output):
    data = bytearray(open(source, "rb").read())
    pos = 2
    while pos + 4 < len(data):
        assert data[pos] == 0xff
        marker = data[pos + 1]
        length = struct.unpack(">H", data[pos + 2:pos + 4])[0]
        if marker in (0xc0, 0xc1, 0xc2):
            data[pos + 5:pos + 9] = b"\xff\xff\xff\xff"
            open(output, "wb").write(data)
            return
        pos += 2 + length
    raise RuntimeError("JPEG SOF not found")


if len(sys.argv) > 2:
    baseline = sys.argv[2]
    inject_jpeg(baseline, os.path.join(OUT, "jpeg-metadata.jpg"), (
        (0xE1, b"Exif\0\0II*\0strict-orientation"),
        (0xE2, b"ICC_PROFILE\0\x01\x01strict-icc"),
        (0xED, b"Photoshop 3.0\0strict-iptc"),
        (0xE1, b"http://ns.adobe.com/xap/1.0/\0strict-xmp"),
        (0xFE, b"strict-comment"),
    ))
    inject_jpeg(baseline, os.path.join(OUT, "jpeg-mpo.jpg"), ((0xE2, b"MPF\0strict"),))
    inject_jpeg(baseline, os.path.join(OUT, "jpeg-hdr.jpg"), ((0xE1, b"hdrgm:Version GContainer:GainMap"),))
    inject_jpeg(baseline, os.path.join(OUT, "jpeg-c2pa.jpg"), ((0xEB, b"JUMBF c2pa"),))
    inject_jpeg(baseline, os.path.join(OUT, "jpeg-c2pa-fragmented.jpg"),
                ((0xEB, b"JU"), (0xEB, b"MBF c2"), (0xEB, b"pa")))
    inject_jpeg(baseline, os.path.join(OUT, "jpeg-trailing.jpg"), (), trailing=open(baseline, "rb").read())
    open(os.path.join(OUT, "jpeg-truncated.jpg"), "wb").write(open(baseline, "rb").read()[:-17])
    oversized_jpeg_header(baseline, os.path.join(OUT, "jpeg-oversized.jpg"))
