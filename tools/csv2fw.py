#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 serlk <22211586+Serlk@users.noreply.github.com>
"""Convert a sensor register table (CSV) into a raw register firmware file.

Input: CSV with the header "step,register_u16,value_u16" and one row per
register write, steps numbered 0..n-1 (for example
the S5KGD1SP TnP table).

Output: the s5kgd1sp driver's TnP format, a flat array of little-endian u16
pairs (register, value), 4 bytes per row, in step order, no header.

Usage: csv2fw.py table.csv s5kgd1sp_tnp.bin
"""

import csv
import struct
import sys


def main(argv):
    if len(argv) != 3:
        sys.stderr.write(f"usage: {argv[0]} <table.csv> <out.bin>\n")
        return 2

    with open(argv[1], newline="") as f:
        rows = list(csv.reader(f))

    header = [c.strip() for c in rows[0]]
    if header[:2] != ["step", "register_u16"] or len(header) != 3:
        sys.stderr.write(f"unexpected header: {rows[0]}\n")
        return 1

    out = bytearray()
    for expected, row in enumerate(rows[1:]):
        if not row:
            continue
        step, reg, val = (int(row[0], 0), int(row[1], 0), int(row[2], 0))
        if step != expected:
            sys.stderr.write(f"step {step} out of order (expected {expected})\n")
            return 1
        if not (0 <= reg <= 0xffff and 0 <= val <= 0xffff):
            sys.stderr.write(f"step {step}: value out of range\n")
            return 1
        out += struct.pack("<HH", reg, val)

    with open(argv[2], "wb") as f:
        f.write(out)

    sys.stderr.write(f"{len(out) // 4} entries written to {argv[2]}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
