#!/usr/bin/env python3
"""
Minimal devkitPro `gbafix` replacement — patches a .gba ROM file
in-place so it passes the GBA BIOS's boot validation:

  - Bytes $04..$9F: 156-byte Nintendo logo bitmap (BIOS compares
    this against an embedded copy on real hardware; NormMatt's
    free BIOS replacement and our Pascal emulator both also check
    this).
  - Byte $BD: header complement checksum
    (negated sum of bytes $A0..$BC, low 8 bits).

The 156 logo bytes are public knowledge — documented in GBATEK §3
and present in every open-source GBA emulator + gbafix source.

Usage:
  python gbafix.py <rom.gba>
  python gbafix.py <rom.gba> --title "DBG_SMOKE" --gamecode "CDBG"
"""

import argparse
import sys
from pathlib import Path

NINTENDO_LOGO = bytes([
    0x24, 0xFF, 0xAE, 0x51, 0x69, 0x9A, 0xA2, 0x21,
    0x3D, 0x84, 0x82, 0x0A, 0x84, 0xE4, 0x09, 0xAD,
    0x11, 0x24, 0x8B, 0x98, 0xC0, 0x81, 0x7F, 0x21,
    0xA3, 0x52, 0xBE, 0x19, 0x93, 0x09, 0xCE, 0x20,
    0x10, 0x46, 0x4A, 0x4A, 0xF8, 0x27, 0x31, 0xEC,
    0x58, 0xC7, 0xE8, 0x33, 0x82, 0xE3, 0xCE, 0xBF,
    0x85, 0xF4, 0xDF, 0x94, 0xCE, 0x4B, 0x09, 0xC1,
    0x94, 0x56, 0x8A, 0xC0, 0x13, 0x72, 0xA7, 0xFC,
    0x9F, 0x84, 0x4D, 0x73, 0xA3, 0xCA, 0x9A, 0x61,
    0x58, 0x97, 0xA3, 0x27, 0xFC, 0x03, 0x98, 0x76,
    0x23, 0x1D, 0xC7, 0x61, 0x03, 0x04, 0xAE, 0x56,
    0xBF, 0x38, 0x84, 0x00, 0x40, 0xA7, 0x0E, 0xFD,
    0xFF, 0x52, 0xFE, 0x03, 0x6F, 0x95, 0x30, 0xF1,
    0x97, 0xFB, 0xC0, 0x85, 0x60, 0xD6, 0x80, 0x25,
    0xA9, 0x63, 0xBE, 0x03, 0x01, 0x4E, 0x38, 0xE2,
    0xF9, 0xA2, 0x34, 0xFF, 0xBB, 0x3E, 0x03, 0x44,
    0x78, 0x00, 0x90, 0xCB, 0x88, 0x11, 0x3A, 0x94,
    0x65, 0xC0, 0x7C, 0x63, 0x87, 0xF0, 0x3C, 0xAF,
    0xD6, 0x25, 0xE4, 0x8B, 0x38, 0x0A, 0xAC, 0x72,
    0x21, 0xD4, 0xF8, 0x07,
])
assert len(NINTENDO_LOGO) == 156


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('rom', help='path to .gba file (patched in place)')
    ap.add_argument('--title', default='', help='12-byte ASCII title (NUL-padded)')
    ap.add_argument('--gamecode', default='', help='4-byte ASCII game code')
    ap.add_argument('--makercode', default='01', help='2-byte ASCII maker code (default "01" Nintendo)')
    args = ap.parse_args()

    p = Path(args.rom)
    data = bytearray(p.read_bytes())
    if len(data) < 0xC0:
        sys.stderr.write(f'rom too small ({len(data)} < 0xC0)\n')
        return 1

    # $04..$9F : Nintendo logo
    data[0x04:0x04 + 156] = NINTENDO_LOGO

    # $A0..$AB : 12-byte title (NUL-padded if shorter)
    if args.title:
        title = args.title.encode('ascii')[:12]
        data[0xA0:0xAC] = title + b'\x00' * (12 - len(title))

    # $AC..$AF : 4-byte game code
    if args.gamecode:
        gc = args.gamecode.encode('ascii')[:4]
        data[0xAC:0xB0] = gc + b'\x00' * (4 - len(gc))

    # $B0..$B1 : 2-byte maker code
    if args.makercode:
        mc = args.makercode.encode('ascii')[:2]
        data[0xB0:0xB2] = mc + b'\x00' * (2 - len(mc))

    # $B2 : fixed value 0x96
    data[0xB2] = 0x96

    # $B3..$BC : main-unit / device / reserved / version (already-zero ok)

    # $BD : header complement checksum
    # = -(0x19 + sum(bytes $A0..$BC)) low 8 bits
    chk = 0x19 + sum(data[0xA0:0xBD])
    data[0xBD] = (-chk) & 0xFF

    p.write_bytes(bytes(data))
    print(f'gbafix: patched {p} ({len(data)} bytes)')
    print(f'        title="{data[0xA0:0xAC].rstrip(b"#"+b" "+b"\\x00").decode("ascii", errors="replace")}"')
    print(f'        gamecode="{data[0xAC:0xB0].decode("ascii", errors="replace")}"')
    print(f'        complement=0x{data[0xBD]:02X}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
