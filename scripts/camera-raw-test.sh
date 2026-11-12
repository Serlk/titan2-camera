#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 serlk <22211586+Serlk@users.noreply.github.com>
#
# Camera bring-up test on the phone: real sensor -> seninf -> CAMSV -> memory, without libcamera.
# All three cameras are in the regular DTB mt6878-unihertz-titan2-all.dtb
# (mt6878-unihertz-titan2-cameras.dtsi), each on its own CAMSV and its own media device; udev
# loads the modules at boot. SENSOR= selects the sensor (default hi847):
#   hi847     second rear camera, i2c7 0x20, CSI port 1 -> camsv2 (1a101000), VCM DW9714 i2c7 0x0c
#   imx766    main rear camera, i2c8 0x1a, CSI port 2 (C-PHY, 3 trios) -> camsv1 (1a100000),
#             VCM DW9800K i2c8 0x0c
#   s5kgd1sp  front camera, i2c4 0x2d, CSI port 0 -> camsv5 (1a104000), fixed focus;
#             needs /lib/firmware/s5kgd1sp_tnp.bin, the sensor's TnP firmware patch. It is not
#             distributed: make it from your own device's firmware (see kernel/README.md) and
#             copy it to /lib/firmware/ on the phone.
# Kernel: the sensor modules, dw9714 / dw9719, mtk-seninf-mt6878, mtk-camsv-mt6878
# (kernel/titan2-camera.config). Busybox sh, as root. Needs v4l-utils: apk add v4l-utils.
#
# The modules load by themselves (udev, modalias of the DT nodes); `load` below only loads what
# is missing. For a manual order (debugging), blacklist them in /etc/modprobe.d (modprobe by name
# still works):
#   printf 'blacklist %s\n' hi847 imx766 s5kgd1sp dw9714 dw9719 mtk_camsv_mt6878 \
#       mtk_seninf_mt6878 > /etc/modprobe.d/camera.conf
#
#   camera-raw-test.sh check           # read only: dmesg, power domains, PM, I2C devices, nodes
#   camera-raw-test.sh load            # modprobe VCM, sensor (probe: power on, chip ID,
#                                      # power off), seninf, camsv (camsv powers CAM_MAIN)
#   camera-raw-test.sh graph           # media-ctl -p
#   camera-raw-test.sh capture [N]     # mode format on sensor and seninf, N frames (5), verify
#   camera-raw-test.sh focus [N]       # VCM: positions FOCUS (default "0 256 512 768 1023"),
#                                      # N frames per position (2) -> $OUT.fPOS
#   camera-raw-test.sh tpg [N]         # test model of the same CSI port (GRBG): path without sensor
#   camera-raw-test.sh verify          # check $OUT again (needs BPL/SIZE from the environment)
#   camera-raw-test.sh pyconv          # prints a RAW10 -> PNG converter for the PC (python3)
#   camera-raw-test.sh all [N]         # check, load, graph, capture, check
#   camera-raw-test.sh parallel [N]    # capture from all sensors of SENSORS (default
#                                      # "hi847 s5kgd1sp imx766") at once, logs /tmp/<sensor>.log
#
# A CAMSV graph is only built once its sensor (and VCM) is bound: with the blacklist,
# "SENSOR=hi847 ... load" brings up camsv2 only; `load` with another SENSOR adds that one.
#
# Mode: MODE=full (default) or MODE=small:
#   hi847     full 3264x2448 @30 (500 MHz, 1 Gbit/s per lane); small (= 1080) 1920x1080 @60 (400 MHz)
#   imx766    full 4096x3072 @30 (574 MHz, 1.148 Gsym/s per trio); small 2048x1152 @120 (377 MHz)
#   s5kgd1sp  full 3280x2464 @30 (432 MHz, 864 Mbit/s per lane); no small mode
# The Bayer order is taken from the sensor (hi847 GRBG; imx766 unflipped RGGB; s5kgd1sp with the
# H+V flip of the factory configuration GRBG); the video node gets RAW10 packed of the same order
# (pgAA/pRAA/pBAA/pGAA).
# Exposure/gain: EXPOSURE (lines), AGAIN (sensor code); empty = driver default (976 lines, 4x:
# almost black with the Hi-847, a scene is visible with EXPOSURE=2400 AGAIN=200).
#   AGAIN: hi847 0..232 (gain/64 - 16), imx766 0..16128 (16384 - 16384/gain),
#          s5kgd1sp 32..512 (gain * 32).
# Buffers: BUFS (4); frames: OUT (default /tmp/$SENSOR.raw), N frames of sizeimage bytes.
# Debugging: CAMSV_DEBUG (default 0; 3 for analysis, the per-frame output slows the system down)
# is the camsv `debug` parameter: bit 0 CQ/IOVA addresses, bit 1 dump of camsv and seninf
# (log_status, with the CSI receiver) at start, after 1 s, on timeout and on stop. Dump from a
# second shell during a capture:
#   v4l2-ctl -d /dev/videoN --log-status
#
# SAFETY / RECOVERY:
# - Do NOT read camsys/seninf/larb/M4U registers with devmem (0x1a00_0000.., 0x11c8_0000..,
#   0x1400_0000..) while the CAM_MAIN/MM_INFRA power domains are off (before load, after the
#   stream stopped, after rmmod): the bus hangs and the watchdog reboots the phone.
#   All dumps go through the driver only (CAMSV_DEBUG, --log-status during a capture).
# - Do not read /sys/kernel/debug/clk/clk_summary or clk_dump (they read camsys clock gates
#   with the domain off).
# - If the phone hangs after load/capture (no ssh, no screen), hold the power key until it
#   reboots. A process in D state is not killed by timeout.
set -u
CAMSV_DEBUG=${CAMSV_DEBUG:-0}
SENSOR=${SENSOR:-hi847}
MODE=${MODE:-full}
BUFS=${BUFS:-4}
OUT=${OUT:-/tmp/$SENSOR.raw}
EXPOSURE=${EXPOSURE:-}
AGAIN=${AGAIN:-}
FOCUS=${FOCUS:-0 256 512 768 1023}
SENINF_DEV=1a00e000.seninf
CAMSV_DEV=1a100000.camsv	# find_media sets it from the sensor's graph
CAMSV_ALL="1a100000.camsv 1a101000.camsv 1a104000.camsv"
PD=/sys/kernel/debug/pm_genpd
TNP_FW=/lib/firmware/s5kgd1sp_tnp.bin

# sensor: module, I2C controller, address, CSI port, VCM module (empty: none), mode size
W=; H=
case "$SENSOR" in
hi847)	DRV=hi847; I2C_DEV=11e02000.i2c; ADDR=0020; CSI=csi1; VCM=dw9714
	case "$MODE" in
	full)	W=3264; H=2448 ;;
	small|1080) W=1920; H=1080 ;;
	esac ;;
imx766)	DRV=imx766; I2C_DEV=11e03000.i2c; ADDR=001a; CSI=csi2; VCM=dw9719
	case "$MODE" in
	full)	W=4096; H=3072 ;;
	small)	W=2048; H=1152 ;;
	esac ;;
s5kgd1sp) DRV=s5kgd1sp; I2C_DEV=11c23000.i2c; ADDR=002d; CSI=csi0; VCM=
	case "$MODE" in
	full)	W=3280; H=2464 ;;
	esac ;;
*)	echo "!! SENSOR=hi847|imx766|s5kgd1sp" >&2; exit 2 ;;
esac
[ -n "$W" ] || { echo "!! MODE=$MODE is not supported for $SENSOR" >&2; exit 2; }
SUBDEV_NAME="$SENINF_DEV $CSI"

say() { echo "== $*"; }
run() { echo "+ $*"; "$@"; }
die() { echo "!! $*" >&2; exit 1; }

# I2C device at an address below the controller
i2c_dev() {
	for d in /sys/devices/platform/soc@0/$I2C_DEV/i2c-*/*-"$1"; do
		[ -e "$d" ] && { echo "$d"; return; }
	done
}

i2c_state() {
	d=$(i2c_dev "$1")
	if [ -n "$d" ]; then
		drv=$(readlink "$d/driver" 2>/dev/null); drv=${drv##*/}
		echo "$d: name=$(cat "$d/name" 2>/dev/null) driver=${drv:-none} runtime=$(cat "$d/power/runtime_status" 2>/dev/null)"
	else
		echo "no device *-$1 on $I2C_DEV (wrong DTB?)"
	fi
}

check() {
	say "dmesg: $DRV, ${VCM:-no VCM}, seninf, camsv, power domains"
	dmesg | grep -iE "$DRV|${VCM:-$DRV}|seninf|camsv|cam-main|csi-rx|6_vbuck1|mtk-iommu|hypervisor page" | tail -n 40
	say "power domains (pm_genpd_summary: cam-*, csi-rx)"
	if [ -r "$PD/pm_genpd_summary" ]; then
		grep -iE "^(cam|csi)|$SENINF_DEV|camsv|genpd:" "$PD/pm_genpd_summary"
	else
		echo "(no $PD: mount -t debugfs none /sys/kernel/debug)"
	fi
	say "sensor and VCM on $I2C_DEV"
	i2c_state "$ADDR"
	[ -n "$VCM" ] && i2c_state 000c
	if [ "$SENSOR" = s5kgd1sp ]; then
		say "TnP patch"
		ls -l "$TNP_FW" 2>/dev/null || echo "no $TNP_FW: the stream will not start (see the header)"
	fi
	say "regulators (fixed, GPIO)"
	for r in /sys/class/regulator/regulator.*; do
		n=$(cat "$r/name" 2>/dev/null)
		case "$n" in
		cam_*|6_vbuck1)
			echo "$n: state=$(cat "$r/state" 2>/dev/null) users=$(cat "$r/num_users" 2>/dev/null)" ;;
		esac
	done
	say "devices: driver and runtime PM"
	for d in $SENINF_DEV $CAMSV_ALL; do
		p=/sys/bus/platform/devices/$d
		if [ -e "$p" ]; then
			drv=$(readlink "$p/driver" 2>/dev/null); drv=${drv##*/}
			echo "$d: driver=${drv:-none} runtime=$(cat "$p/power/runtime_status" 2>/dev/null)"
		else
			echo "$d: no device"
		fi
	done
	say "clock counters (software only, no register reads)"
	for c in camtg2_sel camtg3_sel camtg5_sel cam_sel seninf_sel seninf1_sel seninf2_sel; do
		[ -r /sys/kernel/debug/clk/$c/clk_enable_count ] &&
			echo "$c: enable_count=$(cat /sys/kernel/debug/clk/$c/clk_enable_count) rate=$(cat /sys/kernel/debug/clk/$c/clk_rate 2>/dev/null)"
	done
	say "V4L2 nodes"
	ls -l /dev/media* /dev/video* /dev/v4l-subdev* 2>/dev/null
}

load() {
	if [ -n "$VCM" ]; then
		say "$VCM: VCM (the graph is built only once both sensor and VCM are bound)"
		lsmod | grep -q "^$VCM " || run modprobe "$VCM"
	fi
	say "$DRV: the probe powers the sensor (MCLK, PDN/RST, supplies), reads the chip ID, powers off"
	lsmod | grep -q "^$DRV " || run modprobe "$DRV"
	sleep 1
	dmesg | grep -iE "$DRV|${VCM:-$DRV}|-$ADDR|-000c" | tail -n 12
	d=$(i2c_dev "$ADDR")
	[ -n "$d" ] && [ -e "$d/driver" ] ||
		echo "!! $DRV did not bind (chip id / clock / regulators / endpoint: see dmesg above)"
	if [ -n "$VCM" ]; then
		d=$(i2c_dev 000c)
		[ -n "$d" ] && [ -e "$d/driver" ] || echo "!! $VCM did not bind (regulator cam_afvdd?)"
	fi
	say "seninf and camsv (the camsv probe powers CAM_MAIN; if the phone hangs: RECOVERY)"
	lsmod | grep -q '^mtk_seninf_mt6878' || run modprobe mtk-seninf-mt6878
	lsmod | grep -q '^mtk_camsv_mt6878' || run modprobe mtk-camsv-mt6878 debug="$CAMSV_DEBUG"
	[ -w /sys/module/mtk_camsv_mt6878/parameters/debug ] &&
		echo "$CAMSV_DEBUG" > /sys/module/mtk_camsv_mt6878/parameters/debug
	sleep 1
	dmesg | grep -iE "seninf|camsv|iommu|m4u|smi" | tail -n 30
}

irqs() { grep -iE "camsv|seninf" /proc/interrupts; }

# the CAMSV media device whose graph holds the sensor (each camsv has its own:
# camsv1 IMX766, camsv2 Hi-847, camsv5 S5KGD1SP)
find_media() {
	MEDIA=
	for m in /dev/media*; do
		[ -e "$m" ] || continue
		media-ctl -d "$m" -p 2>/dev/null | grep -q "MT6878 CAMSV" || continue
		media-ctl -d "$m" -p 2>/dev/null | grep -qE "entity [0-9]+: $DRV [0-9]+-$ADDR" &&
			{ MEDIA=$m; break; }
	done
	[ -n "$MEDIA" ] || die "no CAMSV media device with $DRV (load? sensor/VCM not bound, graph not built; dmesg)"
	CAMSV_DEV=$(media-ctl -d "$MEDIA" -p | sed -n 's/.*entity [0-9]*: \([0-9a-f]*\.camsv\) .*/\1/p' | head -n 1)
	[ -n "$CAMSV_DEV" ] || die "no *.camsv entity in $MEDIA"
	VIDEO=$(media-ctl -d "$MEDIA" -e "$CAMSV_DEV")
	SUBDEV=$(media-ctl -d "$MEDIA" -e "$SUBDEV_NAME")
	SENSOR_NAME=$(media-ctl -d "$MEDIA" -p | sed -n "s/.*entity [0-9]*: \\($DRV [0-9]*-$ADDR\\).*/\\1/p" | head -n 1)
	LENS_NAME=$(media-ctl -d "$MEDIA" -p | sed -n 's/.*entity [0-9]*: \([a-z0-9]* [0-9]*-000c\).*/\1/p' | head -n 1)
	[ -c "$VIDEO" ] || die "no video node for $CAMSV_DEV"
	[ -c "$SUBDEV" ] || die "no node for the subdevice \"$SUBDEV_NAME\""
	[ -n "$SENSOR_NAME" ] || die "no $DRV entity in the graph"
	SENSOR_NODE=$(media-ctl -d "$MEDIA" -e "$SENSOR_NAME")
	LENS=
	[ -n "$LENS_NAME" ] && LENS=$(media-ctl -d "$MEDIA" -e "$LENS_NAME")
	echo "media=$MEDIA camsv=$CAMSV_DEV video=$VIDEO seninf=$SUBDEV sensor=\"$SENSOR_NAME\" ($SENSOR_NODE) lens=\"${LENS_NAME:-none}\" (${LENS:-})"
}

graph() {
	find_media
	run media-ctl -d "$MEDIA" -p
}

# media bus code (SXXXX10_1X10) -> RAW10 MIPI packed fourcc and the order for the converter
code_fourcc() {
	case "$1" in
	SGRBG10_1X10) FOURCC=pgAA; ORDER=GRBG ;;
	SRGGB10_1X10) FOURCC=pRAA; ORDER=RGGB ;;
	SBGGR10_1X10) FOURCC=pBAA; ORDER=BGGR ;;
	SGBRG10_1X10) FOURCC=pGAA; ORDER=GBRG ;;
	*) die "code $1 is not RAW10" ;;
	esac
}

# format along the whole chain and on the video node; sets CODE/FOURCC/ORDER/BPL/SIZE
set_formats() {
	if [ "${1:-sensor}" = sensor ]; then
		# the sensor's current code (depends on its flips)
		CODE=$(media-ctl -d "$MEDIA" --get-v4l2 "\"$SENSOR_NAME\":0" | sed -n 's/.*fmt:\([A-Z0-9_]*\)\/.*/\1/p')
		[ -n "$CODE" ] || die "could not read the sensor's format code"
		say "mode format ${W}x${H} $CODE on the sensor, seninf $CSI (sink; the source copies the sink)"
		run media-ctl -d "$MEDIA" -V "\"$SENSOR_NAME\":0 [fmt:$CODE/${W}x${H} field:none]" ||
			die "set fmt $DRV"
		run media-ctl -d "$MEDIA" --get-v4l2 "\"$SENSOR_NAME\":0"
	else
		CODE=SGRBG10_1X10	# test model: always GRBG
	fi
	code_fourcc "$CODE"
	run media-ctl -d "$MEDIA" -V "\"$SUBDEV_NAME\":0 [fmt:$CODE/${W}x${H} field:none]" ||
		die "set fmt seninf"
	run media-ctl -d "$MEDIA" --get-v4l2 "\"$SUBDEV_NAME\":1"
	run v4l2-ctl -d "$VIDEO" --set-fmt-video=width="$W",height="$H",pixelformat="$FOURCC" ||
		die "set fmt camsv"
	run v4l2-ctl -d "$VIDEO" --get-fmt-video
	BPL=$(v4l2-ctl -d "$VIDEO" --get-fmt-video | sed -n 's/.*Bytes per Line *: *\([0-9]*\).*/\1/p')
	SIZE=$(v4l2-ctl -d "$VIDEO" --get-fmt-video | sed -n 's/.*Size Image *: *\([0-9]*\).*/\1/p')
	[ -n "$BPL" ] && [ -n "$SIZE" ] || die "could not parse bytesperline/sizeimage"
	echo "bytesperline=$BPL sizeimage=$SIZE order=$ORDER"
}

sensor_ctrls() {
	say "sensor controls"
	run v4l2-ctl -d "$SENSOR_NODE" -l
	[ -n "$EXPOSURE" ] && run v4l2-ctl -d "$SENSOR_NODE" -c exposure="$EXPOSURE"
	[ -n "$AGAIN" ] && run v4l2-ctl -d "$SENSOR_NODE" -c analogue_gain="$AGAIN"
	run v4l2-ctl -d "$SUBDEV" -c test_pattern=0
	if [ "$SENSOR" = s5kgd1sp ] && [ ! -s "$TNP_FW" ]; then
		echo "!! no $TNP_FW: s5kgd1sp refuses to start streaming (failed to load s5kgd1sp_tnp.bin)"
	fi
}

# stream <file> <frames>
stream() {
	f=$1; n=$2
	say "capture of $n frames -> $f (timeout 20 s)"
	rm -f "$f"
	before=$(dmesg | wc -l)
	say "interrupts before the capture"
	irqs
	run timeout 20 v4l2-ctl -d "$VIDEO" --stream-mmap="$BUFS" --stream-count="$n" \
		--stream-to="$f" --verbose
	echo "v4l2-ctl rc=$?"
	say "interrupts after the capture"
	irqs
	say "dmesg during the capture (complete: $f.dmesg)"
	dmesg | tail -n +"$((before + 1))" > "$f.dmesg"
	tail -n 150 "$f.dmesg"
	say "M4U / CQ / CSI / sensor errors"
	grep -iE "fault|iova|not visible|outside its slot|CQ list|not applied|timeout|not supported|no link frequency|failed|tnp" "$f.dmesg" | head -n 20
}

capture() {
	find_media
	set_formats sensor
	sensor_ctrls
	stream "$OUT" "$N"
	verify sensor
}

# VCM sweep. While the lens node is closed, the driver keeps the lens powered off (runtime PM:
# every v4l2-ctl -c opens, sets and closes the node, and the lens is released at once), so the
# node is held open on file descriptor 9 for the whole sweep.
focus() {
	find_media
	[ -n "$LENS" ] || die "$SENSOR has no VCM in the graph (s5kgd1sp is fixed focus; dw9714/dw9719 not bound?)"
	set_formats sensor
	sensor_ctrls
	say "lens $LENS_NAME ($LENS): controls"
	exec 9<>"$LENS" || die "could not open $LENS"
	run v4l2-ctl -d "$LENS" -l
	for p in $FOCUS; do
		say "focus_absolute=$p"
		run v4l2-ctl -d "$LENS" -c focus_absolute="$p" || echo "!! focus_absolute=$p"
		run v4l2-ctl -d "$LENS" -C focus_absolute
		sleep 1	# lens travel and settling
		stream "$OUT.f$p" "$NF"
		[ -s "$OUT.f$p" ] && echo "$OUT.f$p: $(wc -c < "$OUT.f$p") bytes"
	done
	exec 9>&-
	say "on the PC, for each position P (use the last frame: the first may catch the lens moving)"
	echo "  python3 raw10png.py $OUT.fP $W $H $BPL $ORDER fP.png --frame $((NF - 1))"
	echo "  the converter's \"sharpness\" line: higher is sharper; the maximum is the scene's focus position"
}

tpg() {
	find_media
	set_formats seninf
	say "test model of port $CSI (the sensor stays off)"
	run v4l2-ctl -d "$SUBDEV" -c test_pattern=1 || die "test_pattern"
	stream "$OUT" "$N"
	run v4l2-ctl -d "$SUBDEV" -c test_pattern=0
	verify tpg
}

# a piece of the file: offset and length in bytes
chunk() { tail -c +"$(($1 + 1))" "$OUT" | head -c "$2"; }
hx() { chunk "$1" "$2" | od -An -v -tx1; }
nonzero() { chunk "$1" "$2" | od -An -v -tx1 | grep -q '[1-9a-f]'; }

verify() {
	say "checking $OUT (${W}x${H}, stride ${BPL:-?})"
	[ -s "$OUT" ] || { echo "EMPTY: no frame at all (no SOF: CSI not receiving / CQ / DMA, see the dump)"; return 1; }
	[ -n "${SIZE:-}" ] && [ -n "${BPL:-}" ] ||
		die "SIZE/BPL not set (verify on its own: SENSOR=.. MODE=.. BPL=.. SIZE=..)"
	got=$(wc -c < "$OUT")
	frames=$((got / SIZE))
	echo "size $got bytes = $frames frame(s) of $SIZE (+$((got % SIZE)))"
	i=0
	while [ "$i" -lt "$frames" ]; do
		off=$((i * SIZE))
		head=no; tail=no
		nonzero "$off" 65536 && head=yes
		nonzero $((off + SIZE - 65536)) 65536 && tail=yes
		echo "frame $i: first 64 KiB non-zero=$head, last 64 KiB non-zero=$tail"
		i=$((i + 1))
	done
	say "line 0, line $((H / 2)), last line of frame 0 (first 40 bytes)"
	hx 0 40
	hx $((BPL * (H / 2))) 40
	hx $((BPL * (H - 1))) 40
	if [ "$frames" -ge 2 ]; then
		chunk "$SIZE" "$SIZE" > "$OUT.f1"
		if chunk 0 "$SIZE" | cmp -s - "$OUT.f1"; then
			same="identical"
		else
			same="different"
		fi
		rm -f "$OUT.f1"
		if [ "${1:-sensor}" = sensor ]; then
			echo "frames 0 and 1 are $same (sensor: \"different\" expected, noise; \"identical\" = no new data)"
		else
			echo "frames 0 and 1 are $same (test model: \"identical\" expected)"
		fi
	fi
	say "distinct byte values in 64 KiB from the middle of frame 0 (1 = flat fill, ~256 = image/noise)"
	chunk $((BPL * (H / 2))) 65536 | od -An -v -tx1 | tr -s ' ' '\n' | grep . | sort -u | wc -l
	echo "File: $OUT. On the PC: camera-raw-test.sh pyconv > raw10png.py;"
	echo "  python3 raw10png.py $OUT $W $H $BPL ${ORDER:-GRBG} out.png   (frame 0; --frame K for frame K)"
	echo "Expected: sensor: the scene (dark with the lens covered, ~ pedestal 64/1023);"
	echo "  test model: 8 bars white..black (cropped by the window), --black 0."
}

# Converter for the PC: RAW10 MIPI packed (4 pixels = 5 bytes, the low 2 bits in the 5th byte) ->
# half-resolution PNG (each 2x2 quad -> one RGB pixel), pedestal 64 subtracted, grey world white
# balance, gamma 2.2; prints a sharpness figure (for the focus sweep). Needs numpy; the PNG is
# written with zlib (no PIL).
pyconv() {
	cat <<'PYEOF'
#!/usr/bin/env python3
"""raw10png.py RAW W H STRIDE ORDER OUT.png [--frame K] [--black 64] [--no-wb]
RAW10 MIPI packed Bayer (V4L2 pBAA/pgAA/pGAA/pRAA) -> half-size RGB PNG."""
import argparse, struct, sys, zlib
import numpy as np

ap = argparse.ArgumentParser()
ap.add_argument("raw"); ap.add_argument("w", type=int); ap.add_argument("h", type=int)
ap.add_argument("stride", type=int)
ap.add_argument("order", choices=["RGGB", "GRBG", "GBRG", "BGGR"])
ap.add_argument("out"); ap.add_argument("--frame", type=int, default=0)
ap.add_argument("--black", type=int, default=64); ap.add_argument("--no-wb", action="store_true")
a = ap.parse_args()

size = a.stride * a.h
with open(a.raw, "rb") as f:
    f.seek(size * a.frame)
    buf = f.read(size)
if len(buf) < size:
    sys.exit("short file: %d of %d bytes" % (len(buf), size))
rows = np.frombuffer(buf, np.uint8).reshape(a.h, a.stride)[:, : a.w * 5 // 4]
g = rows.reshape(a.h, a.w // 4, 5).astype(np.uint16)
lo = g[:, :, 4]
px = np.empty((a.h, a.w // 4, 4), np.uint16)
for i in range(4):
    px[:, :, i] = (g[:, :, i] << 2) | ((lo >> (2 * i)) & 3)
img = px.reshape(a.h, a.w).astype(np.float32)
print("raw10: min %d max %d mean %.1f" % (img.min(), img.max(), img.mean()))
img = np.clip(img - a.black, 0, None)

pos = {c: [] for c in "RGB"}
for k, c in enumerate(a.order):
    pos[c].append((k // 2, k % 2))
q = lambda yx: img[yx[0]::2, yx[1]::2]
r = q(pos["R"][0]); b = q(pos["B"][0]); gg = (q(pos["G"][0]) + q(pos["G"][1])) / 2
# focus metric: mean squared gradient of green, normalised by its mean level
gx = np.diff(gg, axis=1); gy = np.diff(gg, axis=0)
print("sharpness %.4f" % ((np.mean(gx * gx) + np.mean(gy * gy)) / (gg.mean() ** 2 + 1e-6)))
rgb = np.stack([r, gg, b], axis=-1)
if not a.no_wb:
    m = rgb.reshape(-1, 3).mean(axis=0) + 1e-6
    rgb = rgb * (m[1] / m)
top = np.percentile(rgb, 99.5) or 1.0
rgb = np.clip(rgb / top, 0, 1) ** (1 / 2.2)
out = (rgb * 255 + 0.5).astype(np.uint8)

hh, ww = out.shape[:2]
raw = b"".join(b"\0" + out[y].tobytes() for y in range(hh))
def chunk(t, d):
    c = struct.pack(">I", len(d)) + t + d
    return c + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", ww, hh, 8, 2, 0, 0, 0)) \
    + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b"")
open(a.out, "wb").write(png)
print("%s: %dx%d RGB (%s, black %d)" % (a.out, ww, hh, a.order, a.black))
PYEOF
}

# all sensors of SENSORS at once (one process each, with its own OUT and log)
parallel() {
	for s in ${SENSORS:-hi847 s5kgd1sp imx766}; do
		say "$s: capture $N -> /tmp/$s.raw, log /tmp/$s.log"
		SENSOR=$s OUT=/tmp/$s.raw sh "$0" capture "$N" > "/tmp/$s.log" 2>&1 &
	done
	wait
	for s in ${SENSORS:-hi847 s5kgd1sp imx766}; do
		say "$s"
		grep -E "^media=|v4l2-ctl rc=|^size|frames 0 and 1|EMPTY|^!!" "/tmp/$s.log"
	done
	irqs
}

N=${2:-5}
NF=${2:-2}
case "${1:-all}" in
check)	check ;;
load)	load ;;
graph)	graph ;;
capture) capture ;;
focus)	focus ;;
tpg)	tpg ;;
verify)	ORDER=${ORDER:-GRBG}; verify sensor ;;
pyconv)	pyconv ;;
all)	check; load; graph; capture; check ;;
parallel) parallel ;;
*)	sed -n '4,70p' "$0"; exit 2 ;;
esac
