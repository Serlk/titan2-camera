#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 serlk <22211586+Serlk@users.noreply.github.com>
#
# Camera, hardware ISP: capture RAW-A request dumps on the original Android (root, adb) for the
# command queue replay of mtk-camraw-mt6878 (docs/CAMERA.md, "Hardware ISP").
# Kernel interface on the phone: /proc/mtk_cam_dbg/<n>/ctrl and .../data, n = 0 for RAW-A, and the
# dump header (struct mtk_cam_dump_header), as defined by mtk_cam-debug.c and
# mtk_cam-debug_dump_header.h of MediaTek's GPL-2.0 camera driver, mtkcam/camsys/isp7sp/cam of
# https://github.com/NothingOSS/android_kernel_modules_nothing_mt6878.
# ctrl commands (at most 15 characters): d:s starts dumping every request into a ring of at most
# 20 buffers (the oldest is recycled when it is full), r:a takes the oldest dumped request out of
# the ring, d:e stops and frees. After r:a, reading data returns one binary dump.
#
#   scripts/camraw-capture.sh first [SECONDS]   # the first requests after a stream start (default 8 s)
#   scripts/camraw-capture.sh steady            # the 20 newest requests of a running preview
#
# first:  a reader loop (r:a + cat data, one file per request) runs in ONE root shell on the phone
#         and is started BEFORE the camera is opened, so it stays ahead of the recycling (about
#         50 ms per request at 20 frames/s). It sends d:s itself, runs until SECONDS after you
#         confirm that the preview is up, then sends d:e.
# steady: d:s, you open the camera and let it preview, then leave it (home key) so that requests
#         stop; the ring keeps the 20 newest; one root shell reads them all, then d:e.
# The files are pulled and named by the request sequence number of the dump header (offset 0x50):
#   OUT/camraw-p<PIPE>-<seq>.bin, plus dmesg-after-<mode>.txt and the checker table
#   (scripts/camraw-dump-info.py --table). A start request (request 1) and a steady request of
#   the same mode are what the replay needs (camraw-start.bin and camraw-frame.bin on the phone).
# Variables: ADB (default: adb from PATH), OUT (./camraw-capture-<date>/camraw-<mode>), PIPE (0),
#   DBG and PTMP (paths on the phone), MAX (upper bound of files the loop writes, 80).
# The dumps contain the tuning output of the phone's own camera software, captured from your own
# device: keep them private, never publish or share them.
#
# Camera app settings: main rear camera, photo, 4:3, zoom 1x, no HDR / night / portrait; the
# preview must run in the 4096x3072 sensor mode our IMX766 driver has (the checker says so).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ADB=${ADB:-adb}
MODE=${1:-}
SECS=${2:-8}
PIPE=${PIPE:-0}
MAX=${MAX:-80}
DBG=${DBG:-/proc/mtk_cam_dbg}
P=$DBG/$PIPE
PTMP=${PTMP:-/data/local/tmp/camraw}
case $MODE in
first | steady) ;;
*) sed -n '5,34p' "$0"; exit 1 ;;
esac
D=${OUT:-$PWD/camraw-capture-$(date +%Y%m%d)/camraw-$MODE}

# every adb call reads /dev/null, or it would eat the script's stdin (the prompts)
# su -c takes ONE argument: no single quotes in the commands below
sh() { "$ADB" shell "su -c '$*'" </dev/null 2>/dev/null | tr -d '\r'; }
# prompts read the terminal, whatever stdin is
ask() { printf '%s' "$1"; read -r _ </dev/tty; }

"$ADB" wait-for-device </dev/null
[ "$(sh id -u)" = 0 ] || { echo "no root through su"; exit 2; }
if [ "$(sh "[ -e $P/ctrl ] && [ -e $P/data ] && echo yes")" != yes ]; then
	echo "no $P/ctrl and $P/data: this kernel has no dump interface, or the camera module is not loaded."
	echo "present:"; sh "ls -l $DBG $DBG/* 2>&1" | sed 's/^/  /'
	echo "Open the camera app once (the module creates the directories on first open) and run again."
	exit 2
fi
mkdir -p "$D"
{
	echo "date $(date +%F' '%T)"
	echo "mode $MODE"
	echo "build $(sh getprop ro.build.display.id)"
	echo "kernel $(sh uname -r)"
	echo "pipelines: $(sh "ls $DBG" | tr '\n' ' ')"
} | tee "$D/info.txt"

sh "rm -rf $PTMP; mkdir -p $PTMP/out"

# the reader, run on the phone: $1 ctrl/data directory, $2 output directory, $3 mode, $4 max
# files. Only shell builtins between the reads except cat, so one round is a few ms.
cat > "$D/.loop.sh" <<'LOOP'
P=$1; O=$2; M=$3; MAX=$4
i=0; fail=0
if [ "$M" = first ]; then
	echo d:s > "$P/ctrl" || echo "d:s failed"
	while [ ! -e "$O/../stop" ] && [ "$i" -lt "$MAX" ]; do
		if echo r:a > "$P/ctrl" 2>/dev/null && cat "$P/data" > "$O/r$i.bin" 2>/dev/null && [ -s "$O/r$i.bin" ]; then
			i=$((i + 1))
		else
			fail=$((fail + 1))
		fi
	done
else
	while [ "$i" -lt 20 ]; do
		echo r:a > "$P/ctrl" 2>/dev/null || break
		cat "$P/data" > "$O/r$i.bin" 2>/dev/null || break
		[ -s "$O/r$i.bin" ] || break
		i=$((i + 1))
	done
fi
echo d:e > "$P/ctrl" || echo "d:e failed"
rm -f "$O/r$i.bin"
echo "read $i requests, $fail empty reads"
LOOP
"$ADB" push "$D/.loop.sh" "$PTMP/loop.sh" </dev/null >/dev/null
rm -f "$D/.loop.sh"

if [ "$MODE" = first ]; then
	echo
	echo "The camera app must be CLOSED now (no preview running)."
	ask "Enter: start the reader on the phone: "
	"$ADB" shell "su -c 'sh $PTMP/loop.sh $P $PTMP/out first $MAX'" </dev/null 2>&1 | tr -d '\r' > "$D/loop-log.txt" &
	LPID=$!
	sleep 1
	echo "reader runs. Now open the camera app (main rear camera, photo, 4:3, 1x) and let it preview."
	ask "Enter as soon as the preview shows: "
	echo "reading for $SECS s more"
	sleep "$SECS"
	sh "touch $PTMP/stop"
	wait "$LPID" || true
	cat "$D/loop-log.txt"
else
	echo "ctrl d:s: $(sh "echo d:s > $P/ctrl; echo rc=\$?")"
	echo
	echo "Open the camera app (main rear camera, photo, 4:3, 1x, no HDR / night / portrait), point it at"
	echo "a lit scene with several colours, let it preview for a few seconds, then LEAVE it (home key)"
	echo "so that requests stop. The newest 20 requests stay in the ring."
	ask "Enter after leaving the camera: "
	sh "sh $PTMP/loop.sh $P $PTMP/out steady 20" | tee "$D/loop-log.txt"
fi
sh "dmesg" > "$D/dmesg-after-$MODE.txt"

# pull and name by the sequence number at offset 0x50
rm -rf "$D/.pull"
mkdir -p "$D/.pull"
"$ADB" pull "$PTMP/out/." "$D/.pull/" </dev/null >/dev/null || true
sh "rm -rf $PTMP"
got=0
for f in "$D"/.pull/r*.bin; do
	[ -e "$f" ] || continue
	if [ "$(stat -c %s "$f")" -lt 228 ]; then
		echo "  ${f##*/}: $(stat -c %s "$f") bytes, not a dump"
		continue
	fi
	seq=$(python3 -c 'import struct,sys; print(struct.unpack_from("<I", open(sys.argv[1],"rb").read(), 0x50)[0])' "$f")
	t=$D/camraw-p$PIPE-$seq.bin
	[ -e "$t" ] && t=$D/camraw-p$PIPE-$seq-$(date +%s%N).bin
	mv "$f" "$t"
	got=$((got + 1))
done
rm -rf "$D/.pull"
[ "$got" -gt 0 ] || { echo "no dumps: was the preview running (first: was the reader started before the camera)?"; exit 1; }
echo "$got dumps in $D"
echo
python3 "$ROOT/scripts/camraw-dump-info.py" --table "$D"/camraw-p"$PIPE"-*.bin | tee "$D/table.txt" || true
echo
echo "for the phone under Linux (board -all): a start request and a steady request with the common split"
echo "0-2079 / 1984-4095, e.g."
echo "  scp $D/camraw-p$PIPE-1.bin root@<phone>:/lib/firmware/titan2/camraw-start.bin"
echo "  scp $D/camraw-p$PIPE-<steady>.bin root@<phone>:/lib/firmware/titan2/camraw-frame.bin"
