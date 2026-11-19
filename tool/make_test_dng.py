#!/usr/bin/env python3
"""Generate a small, decoder-valid Bayer DNG without using personal photos."""
from pathlib import Path
import struct
import sys

def make_dng(path, orientation=1, w=256, h=192):
    tags = {}
    def field(tag, kind, values):
        if kind == 2:
            data = values.encode('ascii') + b'\0'
            count = len(data)
        elif kind == 5 or kind == 10:
            count = len(values)
            data = b''.join(struct.pack('<II' if kind == 5 else '<ii', *v) for v in values)
        else:
            count = len(values)
            data = struct.pack('<' + {1: 'B', 3: 'H', 4: 'I'}[kind] * count, *values)
        tags[tag] = (kind, count, data)
    for tag, val in [(254, 0), (256, w), (257, h), (273, 0), (278, h), (279, w*h*2)]:
        field(tag, 4, [val])
    for tag, val in [(258, 16), (259, 1), (262, 32803), (274, orientation), (277, 1), (50778, 21)]:
        field(tag, 3, [val])
    field(271, 2, 'Shipian'); field(272, 2, 'Synthetic Bayer')
    field(33421, 3, [2, 2]); field(33422, 1, [0, 1, 1, 2])
    field(50706, 1, [1, 4, 0, 0]); field(50707, 1, [1, 1, 0, 0])
    field(50708, 2, 'Shipian Synthetic Bayer')
    field(50710, 1, [0, 1, 2]); field(50711, 3, [1])
    field(50713, 3, [1, 1]); field(50714, 5, [(0, 1)])
    field(50717, 4, [65535]); field(50719, 4, [0, 0]); field(50720, 4, [w, h])
    field(50721, 10, [(1, 1), (0, 1), (0, 1), (0, 1), (1, 1), (0, 1), (0, 1), (0, 1), (1, 1)])
    field(50728, 5, [(1, 1), (1, 1), (1, 1)])
    field(50829, 4, [0, 0, h, w])
    extra = bytearray()
    entries = []
    data_start = 8 + 2 + len(tags) * 12 + 4
    for tag, (kind, count, data) in sorted(tags.items()):
        if len(data) > 4:
            offset = data_start + len(extra)
            extra += data
            if len(extra) % 2: extra += b'\0'
            inline = struct.pack('<I', offset)
        else:
            inline = data.ljust(4, b'\0')
        entries.append((tag, struct.pack('<HHI', tag, kind, count) + inline))
    pixels_start = data_start + len(extra)
    entries = [entry if tag != 273 else struct.pack('<HHII', 273, 4, 1, pixels_start)
               for tag, entry in entries]
    pixels = bytearray()
    for y in range(h):
        for x in range(w):
            channel = [0, 1, 1, 2][(y % 2) * 2 + x % 2]
            value = [0.2 + 0.7*x/w, 0.2 + 0.7*y/h, 0.65 - 0.4*x/w][channel]
            pixels += struct.pack('<H', int(value * 60000))
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b'II*\0' + struct.pack('<I', 8) + struct.pack('<H', len(tags)) +
                     b''.join(entries) + b'\0'*4 + extra + pixels)

if __name__ == '__main__':
    make_dng(sys.argv[1], *map(int, sys.argv[2:]))
