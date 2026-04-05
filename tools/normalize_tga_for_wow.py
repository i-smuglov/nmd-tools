"""
Rewrite TGAs for WoW: 32-bit BGRA, uncompressed type-2, bottom-left, no TRUEVISION footer.
- Upgrades 24-bit -> 32-bit (alpha 255).
- Strips TGA 2.0 extension footer that Photoshop adds (can confuse some loaders).

Run from anywhere:
  python tools/normalize_tga_for_wow.py
Backups: *.tga.bak next to each file.
"""

from __future__ import annotations

import os
import struct
import shutil
import sys

ICONS_DIR = os.path.normpath(
    os.path.join(os.path.dirname(__file__), "..", "Icons")
)


def parse_uncompressed_truecolor(path: str) -> tuple[int, int, int, bytes, bool]:
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 18:
        raise ValueError("too small")
    idlen = data[0]
    cmaptype = data[1]
    imgtype = data[2]
    w, h = struct.unpack_from("<HH", data, 12)
    bpp = data[16]
    desc = data[17]
    if cmaptype != 0:
        raise ValueError("colormap TGAs not supported")
    if imgtype != 2:
        raise ValueError(f"need uncompressed RGB (type 2), got {imgtype} — turn off RLE in Photoshop")
    stride = bpp // 8
    if stride not in (3, 4):
        raise ValueError(f"need 24 or 32 bpp, got {bpp}")
    off = 18 + idlen
    need = w * h * stride
    if off + need > len(data):
        raise ValueError("truncated pixel data")
    pixels = data[off : off + need]
    top_first = (desc & 0x20) != 0
    return w, h, stride, pixels, top_first


def rows_bottom_first(w: int, h: int, stride: int, pixels: bytes, top_first: bool) -> list[bytes]:
    rows: list[bytes] = []
    for r in range(h):
        rows.append(pixels[r * w * stride : (r + 1) * w * stride])
    if top_first:
        rows.reverse()
    return rows


def to_bgra32(rows: list[bytes], w: int, stride: int) -> list[bytes]:
    if stride == 4:
        return rows
    out: list[bytes] = []
    for row in rows:
        buf = bytearray(w * 4)
        for x in range(w):
            b, g, r = row[x * 3 : x * 3 + 3]
            buf[x * 4 : x * 4 + 4] = (b, g, r, 255)
        out.append(bytes(buf))
    return out


def write_wow_tga(path: str, w: int, h: int, rows_bgra: list[bytes]) -> None:
    hdr = bytearray(18)
    hdr[2] = 2
    struct.pack_into("<HH", hdr, 12, w, h)
    hdr[16] = 32
    hdr[17] = 0x08
    with open(path, "wb") as f:
        f.write(hdr)
        f.write(b"".join(rows_bgra))


def main() -> int:
    if not os.path.isdir(ICONS_DIR):
        print("Icons folder not found:", ICONS_DIR, file=sys.stderr)
        return 1
    tg = [f for f in os.listdir(ICONS_DIR) if f.lower().endswith(".tga")]
    if not tg:
        print("No .tga in", ICONS_DIR, file=sys.stderr)
        return 1
    for name in sorted(tg):
        path = os.path.join(ICONS_DIR, name)
        try:
            w, h, stride, pixels, top_first = parse_uncompressed_truecolor(path)
            rows = rows_bottom_first(w, h, stride, pixels, top_first)
            bgra = to_bgra32(rows, w, stride)
            bak = path + ".bak"
            if not os.path.isfile(bak):
                shutil.copy2(path, bak)
            write_wow_tga(path, w, h, bgra)
            print(f"OK {name}  -> 32-bit classic TGA ({w}x{h}), backup {name}.bak")
        except Exception as e:
            print(f"SKIP {name}: {e}", file=sys.stderr)
            return 1
    print("Done. /reload in WoW. If still wrong, fix alpha in Photoshop (shape should match the logo, not a circle).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
