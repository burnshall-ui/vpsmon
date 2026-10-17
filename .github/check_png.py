"""Checks a PNG written by vpsmon with a decoder that is not vpsmon's.

The encoder's own tests can be consistently wrong with it; this reads the
file with Python's zlib: every chunk CRC, IHDR first and IEND last, 8-bit
RGB, IDAT inflating to exactly one filter byte plus 3 * width per row, and
more than one colour in the picture.
"""

import struct, sys, zlib

data = open(sys.argv[1], "rb").read()
assert data[:8] == b"\x89PNG\r\n\x1a\n", "bad signature"

pos, chunks, idat = 8, [], b""
while pos < len(data):
    (length,) = struct.unpack(">I", data[pos:pos + 4])
    kind = data[pos + 4:pos + 8]
    body = data[pos + 8:pos + 8 + length]
    (crc,) = struct.unpack(">I", data[pos + 8 + length:pos + 12 + length])
    assert zlib.crc32(kind + body) == crc, f"CRC mismatch in {kind}"
    chunks.append(kind)
    if kind == b"IHDR":
        w, h, depth, ctype = struct.unpack(">IIBB", body[:10])
    if kind == b"IDAT":
        idat += body
    pos += 12 + length

assert chunks[0] == b"IHDR" and chunks[-1] == b"IEND", chunks
assert (depth, ctype) == (8, 2), "expected 8-bit RGB"
raw = zlib.decompress(idat)
stride = 1 + 3 * w
assert len(raw) == h * stride, f"{len(raw)} bytes, expected {h * stride}"
assert all(raw[r * stride] == 0 for r in range(h)), "unexpected filter byte"
colours = {raw[r * stride + 1 + 3 * x:][:3] for r in range(h) for x in range(w)}
assert len(colours) >= 2, "blank image"
print(f"PNG ok: {w}x{h}, {len(chunks)} chunks, {len(colours)} colours")
