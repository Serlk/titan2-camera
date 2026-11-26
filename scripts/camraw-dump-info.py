#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 serlk <22211586+Serlk@users.noreply.github.com>
#
# Titan 2: what is in RAW engine request dumps (scripts/camraw-capture.sh), by the rules of the
# replay driver's loader (mtk-camraw-mt6878, mtk-camraw-replay.c), so a dump is judged on the PC:
#   - header, the 64 KiB command queue slot, the per-request settings buffer ("meta-in"), the frame
#     and configuration parameters (offsets from the start of the file);
#   - both descriptor lists (12 byte descriptors, register window 0x1a000000): every write must go
#     to one of six blocks, RAW/RMS/YUV of side A (0x1a03/04/05) and of side B (0x1a07/08/09), and
#     take its values from the slot or from the settings buffer;
#   - the buffers of the request: slot, settings buffer, picture planes (img_outs), statistics
#     (meta_outputs) from the frame parameters;
#   - the address words: two consecutive registers {low 32 bits, upper bits} whose 36-bit value
#     lies inside one of those buffers; address-like pairs that match no buffer are an objection;
#   - the kind of request: start with the one-time block (sets the grab window, the time stamp
#     counter and the interrupt enables), start-up without it, or steady (has the picture output);
#   - the split of the frame between the two RAW engines, the outputs and the enabled writers.
#
#   scripts/camraw-dump-info.py DUMP.bin [--writes]         one dump in full
#   scripts/camraw-dump-info.py --table [--start START.bin] DUMP.bin...
#                                                            one line per dump, sorted by directory and
#                                                            request; each steady request is paired with
#                                                            START (default: the first given dump with the
#                                                            one-time block)
#   scripts/camraw-dump-info.py --pair START.bin STEADY.bin  can the two be replayed together
# Replay rule: request 1 of a start is applied whole before the stream starts, then one steady
# request whole for every frame; registers of different requests are never combined.
# The dump header is struct mtk_cam_dump_header (mtk_cam-debug_dump_header.h), the frame and
# configuration parameters are struct mtkcam_ipi_frame_param / mtkcam_ipi_config_param, packed
# (mtk_cam-ipi.h), of MediaTek's GPL-2.0 camera driver, mtkcam/camsys/isp7sp/cam of
# https://github.com/NothingOSS/android_kernel_modules_nothing_mt6878.
# Exit status 0: no objection, 1: objection (printed), 2: not a usable dump.
import argparse
import struct
import sys

ENGINES = (("RAW-A", 0x1A030000), ("RMS-A", 0x1A040000), ("YUV-A", 0x1A050000),
           ("RAW-B", 0x1A070000), ("RMS-B", 0x1A080000), ("YUV-B", 0x1A090000))
SPAN = 0x10000
RAW_A, YUV_A, RAW_B, YUV_B = 0x1A030000, 0x1A050000, 0x1A070000, 0x1A090000
# frame parameters, packed: img_outs[16] of 0x81a bytes, meta_outputs[4] and meta_inputs[] of 18
FP_SIZE, FP_IMG, FP_IMG_N, FP_IMG_SIZE = 0x16883, 0xE593, 16, 0x81A
FP_META_OUT, FP_META_OUT_N, FP_META_IN, FP_META_SIZE = 0x16733, 4, 0x1677B, 18
OUT_NAMES = {6: "YUVO_1", 7: "YUVO_2", 11: "RZH1N2TO_2", 13: "DRZS4NO_3"}
FMT_NAMES = {24: "NV21", 50: "P012 packed", 27: "Y8", 15: "YUYV", 1: "BAYER10"}
RAW_WRITERS = ["IMGO", "UFEO", "PDO", "FLKO", "TSFSO", "AAO", "AAHO", "AFO", "LTMSO", "LTMSHO", "FHO"]
YUV_WRITERS = {0: "TCYSO", 2: "DRZS4NO_R3", 6: "RZH1N2TO_R2", 9: "YUVO_R1", 10: "YUVBO_R1", 13: "YUVO_R2",
               14: "YUVBO_R2"}
OUR_MODE = (4096, 3072)     # the 30 frames/s mode of drivers/media/i2c/imx766.c


def u16(d, o):
    return struct.unpack_from("<H", d, o)[0]


def u32(d, o):
    return struct.unpack_from("<I", d, o)[0]


def u64(d, o):
    return struct.unpack_from("<Q", d, o)[0]


def engine(reg):
    for name, base in ENGINES:
        if base <= reg < base + SPAN:
            return name
    return None


class Dump:
    def __init__(self, path):
        self.path = path
        self.obj = []       # objections
        self.notes = []
        d = self.d = open(path, "rb").read()
        if len(d) < 228:
            raise ValueError(f"{len(d)} bytes: shorter than the header")
        self.desc = d[:64].split(b"\0")[0].decode("ascii", "replace")
        self.seq = u32(d, 80)
        cq_off, cq_size, self.cq_iova = u32(d, 104), u32(d, 108), u64(d, 112)
        self.lists = [(u32(d, 120), u32(d, 124)), (u32(d, 128), u32(d, 132))]
        mi_off, mi_size, self.mi_iova = u32(d, 136), u32(d, 140), u64(d, 144)
        fp_off, fp_size = u32(d, 208), u32(d, 212)
        cf_off, cf_size = u32(d, 216), u32(d, 220)
        for name, off, size in (("queue", cq_off, cq_size), ("settings buffer", mi_off, mi_size),
                                ("frame parameters", fp_off, fp_size), ("configuration", cf_off, cf_size)):
            if not size or off + size > len(d):
                raise ValueError(f"{name}: offset 0x{off:x} size 0x{size:x} not inside the file")
        self.cq = d[cq_off:cq_off + cq_size]
        self.mi = d[mi_off:mi_off + mi_size]
        self.fp = d[fp_off:fp_off + fp_size]
        self.cf = d[cf_off:cf_off + cf_size]
        if not self.lists[0][1] or not self.lists[1][1]:
            self.obj.append("an empty list hangs the command queue")
        self.parse_params()
        self.parse_lists()
        self.find_addresses()
        self.classify()

    def parse_params(self):
        fp, cf = self.fp, self.cf
        self.bufs = [dict(name="queue slot", iova=self.cq_iova, size=len(self.cq), hits=[]),
                     dict(name="settings (meta-in)", iova=self.mi_iova, size=len(self.mi), hits=[])]
        self.outs = []
        if len(fp) != FP_SIZE:
            self.obj.append(f"frame parameters are 0x{len(fp):x} bytes, the known layout has 0x{FP_SIZE:x}")
            return
        self.workbuf = (u32(fp, 0), u32(fp, 4))
        for i in range(FP_IMG_N):
            o = FP_IMG + i * FP_IMG_SIZE
            oid, fmt, w, h = fp[o + 1], u32(fp, o + 2), u16(fp, o + 6), u16(fp, o + 8)
            planes = [(u64(fp, o + 18 + 16 * p), u32(fp, o + 18 + 16 * p + 12)) for p in range(4)]
            planes = [p for p in planes if p[0]]
            if not planes:
                continue
            crop = struct.unpack_from("<4H", fp, o + 18 + 32 * 4 * 16)
            out = dict(id=oid, fmt=fmt, w=w, h=h, stride=u16(fp, o + 10), planes=planes, crop=crop,
                       name=OUT_NAMES.get(oid, f"output {oid}"))
            self.outs.append(out)
            for p, (iova, size) in enumerate(planes):
                self.bufs.append(dict(name=f"{out['name']} plane {p}", iova=iova, size=size, hits=[]))
        for i in range(FP_META_OUT_N):
            o = FP_META_OUT + i * FP_META_SIZE
            if u64(fp, o + 2):
                self.bufs.append(dict(name=f"statistics id 0x{fp[o + 1]:x}", iova=u64(fp, o + 2),
                                      size=u32(fp, o + 14), hits=[]))
        o = FP_META_IN
        if u64(fp, o + 2) != self.mi_iova:
            self.notes.append(f"meta_inputs[0] 0x{u64(fp, o + 2):x} is not the settings buffer of the header")
        # configuration parameters
        self.in_fmt, self.pixel_id, self.pixel_mode = cf[1], cf[5], cf[8]
        self.in_crop = struct.unpack_from("<4H", cf, 0x0A)
        self.dev_mask = u16(cf, 0x208) if len(cf) >= 0x20A else 0

    def parse_lists(self):
        cq, mi = self.cq, self.mi
        self.writes = []        # (reg, value, list, source, descriptor number)
        self.ndesc = []
        self.count = {name: [0, 0] for name, _ in ENGINES}
        self.from_mi = 0
        for li, (off, size) in enumerate(self.lists):
            n, end = 0, False
            if off + size > len(cq):
                raise ValueError(f"list {li} outside the queue slot")
            for pos in range(off, off + size - 11, 12):
                ctrl, ptr = u32(cq, pos), u64(cq, pos + 4)
                op, cnt = (ctrl >> 25) & 3, ((ctrl >> 16) & 0x1FF) + 1
                reg = 0x1A000000 | ((ctrl >> 27) & 0x1F) << 16 | (ctrl & 0xFFFF)
                if op == 3:
                    end = True
                    break
                n += 1
                if op != 0:
                    self.obj.append(f"list {li}: operation {op} at 0x{pos:x}")
                    continue
                if self.cq_iova <= ptr and ptr + 4 * cnt <= self.cq_iova + len(cq):
                    src, vals = "slot", cq[ptr - self.cq_iova:]
                elif self.mi_iova <= ptr and ptr + 4 * cnt <= self.mi_iova + len(mi):
                    src, vals = "settings", mi[ptr - self.mi_iova:]
                    self.from_mi += cnt
                else:
                    self.obj.append(f"list {li} descriptor at 0x{pos:x}: values at 0x{ptr:x}, in no buffer of the dump")
                    continue
                name = engine(reg)
                if not name or engine(reg + 4 * (cnt - 1)) != name:
                    self.obj.append(f"list {li}: register 0x{reg:08x} is in none of the six blocks")
                    continue
                self.count[name][li] += cnt
                self.writes += [(reg + 4 * i, u32(vals, 4 * i), li, src, (li, n)) for i in range(cnt)]
            self.ndesc.append(n)
            if not end:
                self.obj.append(f"list {li} has no END")
        self.reg = {}
        for reg, val, _, _, _ in self.writes:
            self.reg[reg] = val

    def find_addresses(self):
        w = self.writes
        self.addr = []          # (reg, buffer index, offset)
        self.loose = []
        self.in_settings = []
        upper = self.cq_iova >> 32
        k = 0
        while k + 1 < len(w):
            reg, lo = w[k][0], w[k][1]
            # as the loader: both words in one descriptor, at a DMA port (upper half of the window)
            if (w[k + 1][4] != w[k][4] or w[k + 1][0] != reg + 4 or w[k + 1][1] != upper or
                    (reg & 0x7FFF) < 0x4000 or not lo):
                k += 1
                continue
            if w[k][3] != "slot":
                self.in_settings.append(reg)
            a = w[k + 1][1] << 32 | lo
            for i, b in enumerate(self.bufs):
                if b["iova"] <= a < b["iova"] + b["size"]:
                    b["hits"].append(reg)
                    self.addr.append((reg, i, a - b["iova"]))
                    break
            else:
                # a small low word followed by the upper bits value is a count next to a 3, not an address
                if lo >= 0x100000:
                    self.loose.append((reg, a))
            k += 2
        for reg, a in self.loose:
            self.obj.append(f"address 0x{a:x} at 0x{reg:08x} is in no buffer of the request")
        for reg in self.in_settings:
            self.obj.append(f"the address word of 0x{reg:08x} lies in the settings buffer, the loader patches only the slot")
        for b in self.bufs[2:]:
            if not b["hits"]:
                self.notes.append(f"{b['name']} of the frame parameters is written by no port of the lists")

    def classify(self):
        r = self.reg
        self.grab = None
        if RAW_A + 0x708 in r and RAW_A + 0x70C in r:
            p, l = r[RAW_A + 0x708], r[RAW_A + 0x70C]
            self.grab = ((p >> 16) - (p & 0xFFFF), (l >> 16) - (l & 0xFFFF))
        self.onetime = self.grab is not None
        self.picture = next((o for o in self.outs if o["id"] == 6), None)
        self.kind = "start, one-time block" if self.onetime else "steady" if self.picture else "start-up, no one-time block"
        self.split = []
        for base in (RAW_A, RAW_B):
            v = r.get(base + 0x7C4)
            self.split.append(None if v is None else (v & 0xFFFF, v >> 16, r.get(base + 0x7C8, 0)))
        self.twin = any(self.count[n][0] + self.count[n][1] for n in ("RAW-B", "RMS-B", "YUV-B"))
        self.mod5 = [r.get(b + 0x10) for b in (RAW_A, RAW_B, YUV_A, YUV_B)]
        self.nreg = len(r)
        self.tscnt = r.get(RAW_A + 0x77C)
        self.inten = r.get(RAW_A + 0x100)
        self.a_addr = sum(1 for reg, _, _ in self.addr if reg < RAW_B)
        if self.onetime and self.seq != 1:
            self.notes.append(f"the one-time block is in request {self.seq}, not in request 1")
        if self.onetime and self.grab != (self.in_crop[2], self.in_crop[3]):
            self.obj.append(f"grab window {self.grab[0]}x{self.grab[1]} is not the input crop")
        if (self.in_crop[2], self.in_crop[3]) != OUR_MODE or self.in_fmt != 1:
            self.obj.append(f"sensor mode {self.in_crop[2]}x{self.in_crop[3]} format {self.in_fmt} is not our IMX766 "
                            f"mode {OUR_MODE[0]}x{OUR_MODE[1]} RAW10")
        for s in self.split:
            if s and s[2] != self.in_crop[3]:
                self.obj.append("the split windows do not have the height of the input")
        if self.split[1] and self.split[1][1] != self.in_crop[2] - 1:
            self.obj.append("the split of side B does not end at the last column")

    def split_text(self):
        return " / ".join("-" if s is None else f"{s[0]}-{s[1]}" for s in self.split)

    def outs_text(self):
        return ", ".join(f"{o['name']} {FMT_NAMES.get(o['fmt'], o['fmt'])} {o['w']}x{o['h']}" for o in self.outs)

    def show(self, writes):
        d = self.d
        print(f"file            {self.path}, {len(d)} bytes, \"{self.desc}\"")
        print(f"request         sequence {self.seq}; kind: {self.kind}")
        print(f"queue slot      0x{len(self.cq):x} bytes captured at 0x{self.cq_iova:x}; main 0x{self.lists[0][0]:x} + "
              f"0x{self.lists[0][1]:x} ({self.ndesc[0]} writes), sub 0x{self.lists[1][0]:x} + 0x{self.lists[1][1]:x} "
              f"({self.ndesc[1]} writes); slot of the session buffer: offset 0x{self.workbuf[0]:x}")
        print(f"settings buffer 0x{len(self.mi):x} bytes captured at 0x{self.mi_iova:x}; {self.from_mi} list values come from it")
        print(f"registers       {self.nreg} written; values per block, main + sub:")
        for name, _ in ENGINES:
            print(f"                  {name} {self.count[name][0]} + {self.count[name][1]}")
        print(f"input           format {FMT_NAMES.get(self.in_fmt, self.in_fmt)}, pixel id {self.pixel_id}, crop "
              f"{self.in_crop}, pixel mode before RAW {self.pixel_mode}, engines mask 0x{self.dev_mask:x}")
        if self.onetime:
            print(f"one-time block  grab window {self.grab[0]}x{self.grab[1]}, sensor mode word 0x{self.reg[RAW_A + 0x700]:x}, "
                  f"time stamp counter {self.tscnt}, RAW interrupt enable 0x{self.inten or 0:08x}, "
                  f"YUV interrupt enable 0x{self.reg.get(YUV_A + 0x100, 0):x}")
        print(f"split           RAW-A / RAW-B columns: {self.split_text()}"
              f"{'' if self.split_text() in ('0-2079 / 1984-4095', '0-2079 / 2016-4095') else '  (not the common geometry)'}")
        print(f"frame number    register gets {self.reg.get(RAW_A + 0x2C40)}")
        for name, v, names in (("RAW-A", self.mod5[0], None), ("RAW-B", self.mod5[1], None),
                               ("YUV-A", self.mod5[2], YUV_WRITERS), ("YUV-B", self.mod5[3], YUV_WRITERS)):
            if v is None:
                continue
            on = [n for b, n in names.items() if v >> b & 1] if names else [n for i, n in enumerate(RAW_WRITERS) if v >> i & 1]
            print(f"writers {name}   0x{v:x}: {' '.join(on)}")
        for o in self.outs:
            print(f"output          {o['name']} (id {o['id']}): {FMT_NAMES.get(o['fmt'], o['fmt'])} {o['w']}x{o['h']} pitch "
                  f"{o['stride']}, crop {o['crop']}, planes " + ", ".join(f"0x{s:x}" for _, s in o["planes"]))
        for i, b in enumerate(self.bufs):
            print(f"buffer {i:2d}       {b['name']}: 0x{b['iova']:x} size 0x{b['size']:x}, {len(b['hits'])} address word(s)")
        for reg, i, off in self.addr:
            print(f"address         {engine(reg)} +0x{reg & 0xffff:04x} -> buffer {i} + 0x{off:x} ({self.bufs[i]['name']})")
        print(f"address words   {len(self.addr)}: {self.a_addr} on side A, {len(self.addr) - self.a_addr} on side B; "
              f"{len(self.loose)} in no buffer")
        if writes:
            for reg, val, li, src, _ in self.writes:
                print(f"  write list {li} {engine(reg)} 0x{reg:08x} = 0x{val:08x}{'  (settings)' if src != 'slot' else ''}")
        for n in self.notes:
            print(f"note            {n}")
        for o in self.obj:
            print(f"OBJECTION       {o}")
        print("result          " + ("the loader will refuse this dump" if self.obj else f"ok for the loader as: {self.kind}"))

    def row(self, start):
        if start is None or self is start or not self.picture:
            with_start = "-"
        else:
            bad = pair_problems(start, self)
            with_start = f"{start.seq}: " + ("; ".join(bad) if bad else "consistent")
        outs = ", ".join(f"{o['name']} {o['w']}x{o['h']}" for o in self.outs)
        return (f"| {self.where()} | {self.seq} | {self.kind} | {self.ndesc[0]} + {self.ndesc[1]} | {self.nreg} | "
                f"{self.split_text()} | {outs} | {' / '.join('-' if v is None else hex(v) for v in self.mod5)} | "
                f"{len(self.addr)} ({self.a_addr} A) | {'; '.join(self.obj) if self.obj else 'ok'} | {with_start} |")

    def where(self):
        return self.path.rstrip("/").rsplit("/", 2)[-2] if "/" in self.path else "."


def pair_problems(start, steady):
    bad = []
    if not start.onetime:
        bad.append("the start request has no one-time block (grab window, time stamp counter, interrupt enables)")
    if not steady.picture:
        bad.append("the per-frame request has no picture output (YUVO_1)")
    if steady.onetime:
        bad.append("the per-frame request carries the one-time block")
    for name in ("in_fmt", "pixel_id", "pixel_mode", "in_crop", "dev_mask"):
        if getattr(start, name) != getattr(steady, name):
            bad.append(f"{name} differs: {getattr(start, name)} / {getattr(steady, name)}")
    if start.twin != steady.twin:
        bad.append("one request is for two RAW engines, the other for one")
    if start.obj or steady.obj:
        bad.append("one of the two has objections of its own")
    return bad


def pair(start, steady):
    """Can START be applied before the stream and STEADY for every frame?"""
    bad = pair_problems(start, steady)
    print(f"start           request {start.seq}: {start.kind}; split {start.split_text()}; time stamp counter {start.tscnt}")
    print(f"per frame       request {steady.seq}: {steady.kind}; split {steady.split_text()}; {steady.outs_text()}")
    if steady.split_text() != "0-2079 / 1984-4095":
        print("note            the per-frame request does not have the common split 0-2079 / 1984-4095 "
              "(a whole request is still consistent in itself)")
    if start.path.rsplit("/", 1)[0] != steady.path.rsplit("/", 1)[0]:
        print("note            the two files are from different directories (different starts): allowed, "
              "each request is applied whole")
    for b in bad:
        print(f"OBJECTION       {b}")
    print("pair            " + ("NOT consistent for replay" if bad else "consistent for replay"))
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dumps", nargs="+")
    ap.add_argument("--writes", action="store_true")
    ap.add_argument("--table", action="store_true")
    ap.add_argument("--pair", action="store_true")
    ap.add_argument("--start", help="--table: the start request to pair the steady ones with")
    args = ap.parse_args()
    try:
        dumps = [Dump(p) for p in args.dumps]
    except (ValueError, struct.error) as e:
        print(f"not a usable dump: {e}")
        return 2
    if args.pair:
        if len(dumps) != 2:
            ap.error("--pair START.bin STEADY.bin")
        return pair(*dumps)
    if args.table:
        try:
            start = Dump(args.start) if args.start else next((d for d in dumps if d.onetime), None)
        except (ValueError, struct.error) as e:
            print(f"not a usable start dump: {e}")
            return 2
        dumps.sort(key=lambda d: (d.where(), d.seq))
        print("| directory | request | kind | writes main + sub | registers | split A / B (columns) | outputs | "
              "writer enables RAW-A / RAW-B / YUV-A / YUV-B | address words | loader | with start request |")
        print("|---|---|---|---|---|---|---|---|---|---|---|")
        for d in dumps:
            print(d.row(start))
    else:
        for d in dumps:
            d.show(args.writes)
    return 1 if any(d.obj for d in dumps) else 0


if __name__ == "__main__":
    sys.exit(main())
