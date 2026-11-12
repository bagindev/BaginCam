"""
dng_rewrite_check.py - port Python 1:1 dari ios-app/BaginCam/DNGWriter.swift untuk menguji logikanya
di PC (Swift tidak bisa dijalankan di Windows). Menulis ulang DNG Bayer Apple dengan data CFA baru,
lalu dicek dengan rawpy (LibRaw) + ExifTool.

  python dng_rewrite_check.py <dng_asli> <out.dng> [--merge-folder <folder burst>]
"""
import struct
import sys

import numpy as np

TYPE_SIZE = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 13: 4}
STRUCTURAL = {254, 256, 257, 258, 259, 262, 273, 277, 278, 279, 284, 322, 323, 324, 325, 330, 347,
              513, 514, 50712, 34665, 34853, 305}


class IFD:
    def __init__(self):
        self.entries, self.exif, self.gps, self.sub = {}, None, None, []


def parse_ifd(d, bo, off, depth=0):
    ifd = IFD()
    n, = struct.unpack_from(bo + "H", d, off)
    for i in range(n):
        e = off + 2 + i * 12
        tag, typ, cnt = struct.unpack_from(bo + "HHI", d, e)
        size = TYPE_SIZE.get(typ, 1) * cnt
        voff = e + 8 if size <= 4 else struct.unpack_from(bo + "I", d, e + 8)[0]
        if voff + size > len(d):
            continue
        ifd.entries[tag] = (typ, cnt, bytes(d[voff:voff + size]))
        if tag == 34665:
            ifd.exif = parse_ifd(d, bo, struct.unpack_from(bo + "I", d, e + 8)[0], depth + 1)
        elif tag == 34853:
            ifd.gps = parse_ifd(d, bo, struct.unpack_from(bo + "I", d, e + 8)[0], depth + 1)
        elif tag == 330:
            for k in range(cnt):
                ifd.sub.append(parse_ifd(d, bo, struct.unpack_from(bo + "I", d, voff + k * 4)[0], depth + 1))
    return ifd


def first(entry, bo):
    if entry is None:
        return None
    typ, cnt, b = entry
    if typ in (3, 8):
        return struct.unpack(bo + "H", b[:2])[0]
    if typ in (4, 9, 13):
        return struct.unpack(bo + "I", b[:4])[0]
    return b[0]


def num(tag, bo, short=None, long=None):
    if short is not None:
        return (3, 1, struct.pack(bo + "H", short))
    return (4, 1, struct.pack(bo + "I", long or 0))


def block_size(entries):
    s = 2 + len(entries) * 12 + 4
    for typ, cnt, b in entries.values():
        if len(b) > 4:
            s += len(b) + len(b) % 2
    return s


def write_ifd(entries, base, bo):
    out = bytearray()
    tags = sorted(entries)
    val_pos = base + 2 + len(tags) * 12 + 4
    values = bytearray()
    out += struct.pack(bo + "H", len(tags))
    for t in tags:
        typ, cnt, b = entries[t]
        out += struct.pack(bo + "HHI", t, typ, cnt)
        if len(b) <= 4:
            out += b.ljust(4, b"\0")
        else:
            out += struct.pack(bo + "I", val_pos)
            values += b + (b"\0" if len(b) % 2 else b"")
            val_pos += len(b) + len(b) % 2
    out += struct.pack(bo + "I", 0)
    return bytes(out + values)


def rewrite(original, pixels, software="BaginCam HDR+ (cek PC)"):
    d = original
    bo = ">" if d[:2] == b"MM" else "<"
    ifd0 = parse_ifd(d, bo, struct.unpack_from(bo + "I", d, 4)[0])
    raw = next(i for i in [ifd0] + ifd0.sub
               if (first(i.entries.get(254), bo) or 0) == 0 and first(i.entries.get(262), bo) == 32803)
    h, w = pixels.shape
    merged = {t: e for t, e in ifd0.entries.items() if t not in STRUCTURAL}
    if raw is not ifd0:
        merged.update({t: e for t, e in raw.entries.items() if t not in STRUCTURAL})
    merged.update({254: num(254, bo, long=0), 256: num(256, bo, long=w), 257: num(257, bo, long=h),
                   258: num(258, bo, short=16), 259: num(259, bo, short=1), 262: num(262, bo, short=32803),
                   277: num(277, bo, short=1), 278: num(278, bo, long=h), 279: num(279, bo, long=w * h * 2),
                   284: num(284, bo, short=1), 305: (2, len(software) + 1, software.encode() + b"\0")})
    exif = {t: e for t, e in ifd0.exif.entries.items() if t != 40965} if ifd0.exif else None
    gps = dict(ifd0.gps.entries) if ifd0.gps else None
    for t, present in ((34665, exif), (34853, gps)):
        if present is not None:
            merged[t] = num(t, bo, long=0)
    merged[273] = num(273, bo, long=0)
    pos = 8 + block_size(merged)
    exif_base = pos
    pos += block_size(exif) if exif else 0
    gps_base = pos
    pos += block_size(gps) if gps else 0
    pos += (4 - pos % 4) % 4
    strip = pos
    if exif:
        merged[34665] = num(34665, bo, long=exif_base)
    if gps:
        merged[34853] = num(34853, bo, long=gps_base)
    merged[273] = num(273, bo, long=strip)
    out = bytearray((b"MM\0*" if bo == ">" else b"II*\0") + struct.pack(bo + "I", 8))
    out += write_ifd(merged, 8, bo)
    if exif:
        out += write_ifd(exif, exif_base, bo)
    if gps:
        out += write_ifd(gps, gps_base, bo)
    out += b"\0" * (strip - len(out))
    assert len(out) == strip
    out += pixels.astype(bo + "u2").tobytes()
    return bytes(out)


if __name__ == "__main__":
    import rawpy
    src, dst = sys.argv[1], sys.argv[2]
    orig = open(src, "rb").read()
    with rawpy.imread(src) as r:
        px = r.raw_image.copy()          # seluruh area sensor (termasuk margin)
    if "--merge-folder" in sys.argv:
        from pathlib import Path
        sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "pc-lab"))
        import burst_merge as bm
        import robust_merge as rm
        import torch
        folder = Path(sys.argv[sys.argv.index("--merge-folder") + 1])
        frames = []
        for p in bm.list_raws(folder):
            with rawpy.imread(p) as r:
                frames.append(r.raw_image.astype(np.float32).copy())
        merged = rm.align_and_robust_merge(torch.from_numpy(np.stack(frames))[:, None], noise_reduction=18)
        px = np.clip(np.rint(merged[0].numpy()), 0, 65535).astype(np.uint16)
    open(dst, "wb").write(rewrite(orig, px))
    print("tulis", dst, px.shape)
