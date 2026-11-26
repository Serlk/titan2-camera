#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 serlk <22211586+Serlk@users.noreply.github.com>
#
# Camera, hardware ISP: first frames of the RAW/YUV engines by replaying captured command queues
# (driver mtk-camraw-mt6878, board mt6878-unihertz-titan2-raw.dtb, docs/CAMERA.md "Hardware ISP").
# ON THE PHONE, as root, busybox sh. Needs v4l-utils and the two request dumps
#   /lib/firmware/titan2/camraw-start.bin   request 1 of a stream (one-time block)
#   /lib/firmware/titan2/camraw-frame.bin   a steady request of the same mode (picture output)
# (scripts/camraw-capture.sh on the original Android; scripts/camraw-dump-info.py --table on the PC).
#
#   camera-raw-replay-test.sh check       # module, nodes, dumps, the driver's reading of them (status)
#   camera-raw-replay-test.sh run [N]     # sensor mode, load, N frames (default 3) -> $OUT, verdict
#   camera-raw-replay-test.sh status      # debugfs status (with registers while a stream runs)
#   camera-raw-replay-test.sh runlist [TAG]  # five fixed variants (below) -> $MDIR; without TAG it
#                                            # runs all of it detached (nohup) and returns at once
#
# Variables: TWIN=0 (side A only, left part of the picture; default) | 1 (both RAW engines);
#   module parameters, empty = leave as is: REAPPLY (0|1|2), STATS_OFF (0|1), EXTRA_OFF (0|1),
#   PRESTART (0|1), ERR_MASK (0|1|2), CAM_MHZ (0|312), APPLY_DELAY_US (0..30000),
#   DB_ORDER (0|1), FRAME_DONE (0|1);
#   EXPOSURE, AGAIN: sensor controls (empty = as is); OUT (/tmp/camraw.nv21); MDIR (/root/camraw-runs).
# The sensor mode is that of the captured requests: 4096x3072 RAW10 (our IMX766 30 frames/s mode).
# The camera domains are on only while streaming: the driver reads its registers itself (status,
# dmesg); never use devmem on camera addresses.
set -u

W=4096
H=3072
OUT=${OUT:-/tmp/camraw.nv21}
DBGFS=/sys/kernel/debug/mtk-camraw-a
PARAMS=/sys/module/mtk_camraw_mt6878/parameters
FW_START=/lib/firmware/titan2/camraw-start.bin
FW_FRAME=/lib/firmware/titan2/camraw-frame.bin

say() { echo "== $*"; }
run() { echo "+ $*"; "$@"; }
die() { echo "!! $*" >&2; exit 1; }

load() {
	[ -d /sys/module/mtk_camraw_mt6878 ] || run modprobe mtk-camraw-mt6878 || die "no module mtk-camraw-mt6878"
	grep -q " /sys/kernel/debug debugfs" /proc/mounts || mount -t debugfs debugfs /sys/kernel/debug
	[ -d "$DBGFS" ] || die "no $DBGFS: the driver did not bind (board -raw? dmesg | grep camraw)"
	for p in twin:${TWIN:-0} reapply:${REAPPLY:-} stats_off:${STATS_OFF:-} extra_off:${EXTRA_OFF:-} \
	    prestart:${PRESTART:-} err_mask:${ERR_MASK:-} cam_mhz:${CAM_MHZ:-} apply_delay_us:${APPLY_DELAY_US:-} \
	    db_order:${DB_ORDER:-} frame_done:${FRAME_DONE:-}; do
		[ -n "${p#*:}" ] && run sh -c "echo ${p#*:} > $PARAMS/${p%%:*}"
	done
	say "module parameters: $(for f in twin reapply stats_off extra_off prestart err_mask cam_mhz apply_delay_us db_order frame_done start_fw frame_fw; do printf '%s=%s ' $f "$(cat $PARAMS/$f 2>/dev/null)"; done)"
}

find_nodes() {
	VIDEO=
	for v in /sys/class/video4linux/video*; do
		[ "$(cat "$v/name" 2>/dev/null)" = mtk-camraw-a ] && VIDEO=/dev/${v##*/}
	done
	[ -n "$VIDEO" ] || die "no video node mtk-camraw-a"
	MEDIA=
	for m in /dev/media*; do
		media-ctl -d "$m" -p 2>/dev/null | grep -qE "entity [0-9]+: imx766 " && MEDIA=$m
	done
	[ -n "$MEDIA" ] || die "no media device with the imx766 sensor"
	SENSOR=$(media-ctl -d "$MEDIA" -p | sed -n 's/.*entity [0-9]*: \(imx766 [0-9]*-[0-9a-f]*\).*/\1/p' | head -n 1)
	SENINF=$(media-ctl -d "$MEDIA" -p | sed -n 's/.*entity [0-9]*: \([^(]*seninf csi[0-9]\) .*/\1/p' | head -n 1)
	[ -n "$SENSOR" ] && [ -n "$SENINF" ] || die "sensor / seninf entities not found in $MEDIA"
	say "video node $VIDEO, media $MEDIA, sensor \"$SENSOR\", port \"$SENINF\""
}

set_formats() {
	CODE=$(media-ctl -d "$MEDIA" --get-v4l2 "\"$SENSOR\":0" | sed -n 's/.*fmt:\([A-Z0-9_]*\)\/.*/\1/p')
	[ -n "$CODE" ] || die "sensor format not read"
	run media-ctl -d "$MEDIA" -V "\"$SENSOR\":0 [fmt:$CODE/${W}x${H} field:none]" || die "the sensor refused the mode"
	CODE=$(media-ctl -d "$MEDIA" --get-v4l2 "\"$SENSOR\":0" | sed -n 's/.*fmt:\([A-Z0-9_]*\)\/.*/\1/p')
	run media-ctl -d "$MEDIA" -V "\"$SENINF\":0 [fmt:$CODE/${W}x${H} field:none]" || die "seninf refused the format"
	run media-ctl -d "$MEDIA" --get-v4l2 "\"$SENINF\":0"
	SNODE=$(media-ctl -d "$MEDIA" -e "$SENSOR")
	[ -n "${EXPOSURE:-}" ] && run v4l2-ctl -d "$SNODE" --set-ctrl "exposure=$EXPOSURE"
	[ -n "${AGAIN:-}" ] && run v4l2-ctl -d "$SNODE" --set-ctrl "analogue_gain=$AGAIN"
	say "sensor timing and exposure"
	v4l2-ctl -d "$SNODE" --list-ctrls 2>/dev/null |
		grep -E "pixel_rate|link_frequency|horizontal_blanking|vertical_blanking|exposure|analogue_gain"
}

log() { dmesg | grep -iE 'camraw|camyuv|m4u|iommu.*fault|translation fault|seninf|imx766' | tail -n "${1:-80}"; }

# pass criteria of the first replay test, from the kernel log of this run
verdict() {
	L=$(dmesg | tail -n +"$((LOG0 + 1))")
	ok=0; bad=0
	check() {	# $1 description, $2 0 = pass
		if [ "$2" = 0 ]; then echo "PASS  $1"; ok=$((ok + 1)); else echo "FAIL  $1"; bad=$((bad + 1)); fi
	}
	echo "$L" | grep -q "start request done" ; check "the start request's lists both finished" $?
	# writer enables of the start request, without the statistics writers when stats_off
	ma=7f8; mb=f8
	[ "$(cat $PARAMS/stats_off)" = Y ] && { ma=400; mb=0; }
	echo "$L" | grep -q "before viewfinder: RAW-A latched MOD5 0x$ma "; check "RAW-A latched the start request before VF on (MOD5 0x$ma)" $?
	if [ "$(cat $PARAMS/twin)" = Y ]; then
		echo "$L" | grep -q "before viewfinder: RAW-B latched MOD5 0x$mb SEL 0x11 "; check "RAW-B latched MOD5 0x$mb / SEL 0x11 before VF on" $?
	fi
	echo "$L" | grep -q "time stamp counter divider reads" ; [ $? != 0 ]; check "the start request set the time stamp counter" $?
	n=$(echo "$L" | sed -n 's/.*stop: lists started .*, start of frame \([0-9]*\),.*/\1/p' | tail -n 1)
	[ "${n:-0}" -ge 3 ]; check "starts of frame: ${n:-0} (>= 3)" $?
	echo "$L" | grep -q "stop: input underflow seen in interrupts (INT8): none"; check "no input underflow (INT8)" $?
	sw=$(echo "$L" | sed -n 's/.*stop: .*SW pass 1 done (frame done) \([0-9]*\),.*/\1/p' | tail -n 1)
	[ "${sw:-0}" -ge 1 ]; check "frame done (SW_PASS1_DONE): ${sw:-0}" $?
	d=$(echo "$L" | sed -n 's/.*stop: .*frames delivered \([0-9]*\),.*/\1/p' | tail -n 1)
	[ "${d:-0}" -ge 1 ]; check "frames delivered: ${d:-0}" $?
	# a probe line must exist (a delivered frame) and say what is expected
	probe() {	# $1 plane, $2 left|right, $3 written|untouched
		p=$(echo "$L" | grep "first frame: plane $1 .* $2 ")
		[ -n "$p" ] || return 1
		if [ "$3" = written ]; then echo "$p" | grep -qv "NOT WRITTEN"; else echo "$p" | grep -q "NOT WRITTEN"; fi
	}
	probe 0 left written; check "picture plane 0, left part written" $?
	probe 1 left written; check "picture plane 1, left part written" $?
	if [ "$(cat $PARAMS/twin)" = Y ]; then
		probe 0 right written; check "picture plane 0, right part written (twin)" $?
	else
		probe 0 right untouched; check "picture plane 0, right part untouched (side A only, expected)" $?
	fi
	echo "$L" | grep -qE "error interrupt|LINE SWITCHED OFF"; [ $? != 0 ]; check "no error interrupt, no interrupt storm" $?
	# fault reports of the M4U driver in this run only (not the APU's register readbacks)
	echo "$L" | grep -iE "iommu.*fault|translation fault" | grep -qviE "apu|FAULT_ST1|FAULT_VA|INT_ID"; [ $? != 0 ]; check "no IOMMU fault" $?
	echo "verdict: $ok passed, $bad failed"
	say "start-of-frame log (latched frame number = applications j?), first error time, clocks"
	echo "$L" | grep -E "stop: start of frame|stop: first error|clock rates|cam-sel|prestart|before viewfinder|rdy/req|underflow|TG measured" | head -n 24
}

# one stream of N frames with the current parameters; $1 tag (runlist: files in $MDIR)
stream() {
	LOG0=$(dmesg | wc -l)
	f=${MDIR:+$MDIR/$1.nv21}
	f=${f:-$OUT}
	say "capturing $N frame(s) -> $f"
	rm -f "$f"
	timeout 15 v4l2-ctl -d "$VIDEO" --stream-mmap=3 --stream-count="$N" --stream-to="$f"
	echo "v4l2-ctl: exit $?"
	ls -l "$f" 2>&1
	[ -n "${MDIR:-}" ] && dmesg | tail -n +"$((LOG0 + 1))" > "$MDIR/$1.log"
}

case ${1:-} in
check)
	load
	say "dumps"; ls -l "$FW_START" "$FW_FRAME" 2>&1
	find_nodes
	say "loading and reading of the dumps by the driver"
	echo 1 > "$DBGFS/load" || echo "!! loading failed"
	cat "$DBGFS/status"
	log 60
	;;
run)
	N=${2:-3}
	load
	[ -f "$FW_START" ] && [ -f "$FW_FRAME" ] || die "no $FW_START / $FW_FRAME"
	find_nodes
	set_formats
	say "loading the dumps"
	echo 1 > "$DBGFS/load" || { log 40; die "dumps not loaded"; }
	grep -E "^pair:|^video node:" "$DBGFS/status"
	run v4l2-ctl -d "$VIDEO" --get-fmt-video
	MDIR=
	stream run
	say "log"
	log 120
	say "verdict"
	verdict
	say "status (stream stopped: no registers; the stream's summary is the \"stop:\" lines above)"
	cat "$DBGFS/status"
	say "on the PC: ffmpeg -f rawvideo -pix_fmt nv21 -s 1472x1088 -i camraw.nv21 -frames:v 1 camraw.png"
	echo "   (1472 = the line pitch; the picture is the left 1450 columns; with TWIN=0 only the left ~724)"
	;;
status)
	cat "$DBGFS/status"
	;;
runlist)
	# tag:twin,db_order,frame_done,stats_off,extra_off (all others at their defaults)
	MDIR=${MDIR:-/root/camraw-runs}
	mkdir -p "$MDIR"
	LIST="r1-twin:1,0,0,0,0 r2-side-a:0,0,0,0,0 r3-twin-old-order:1,1,0,0,0 r4-twin-sof-delivery:1,0,1,0,0 r5-twin-min:1,0,0,1,1"
	if [ -z "${2:-}" ]; then
		# all of it, detached: a remote shell with a time limit must not cut it off
		nohup sh "$0" runlist all > "$MDIR/console.txt" 2>&1 &
		echo "running detached (pid $!): tail -f $MDIR/console.txt; done when $MDIR/summary.txt ends with \"== end\""
		exit 0
	fi
	N=3
	load
	[ -f "$FW_START" ] && [ -f "$FW_FRAME" ] || die "no $FW_START / $FW_FRAME"
	find_nodes
	set_formats > "$MDIR/sensor.txt" 2>&1
	echo 1 > "$DBGFS/load" || die "dumps not loaded"
	grep -E "^pair:|^video node:" "$DBGFS/status"
	[ "$2" = all ] && : > "$MDIR/summary.txt"
	for r in $LIST; do
		tag=${r%%:*}
		[ "$2" = all ] || [ "$2" = "$tag" ] || continue
		set -- runlist "$2" $(echo "${r#*:}" | tr , ' ')
		TWIN=$3 DB_ORDER=$4 FRAME_DONE=$5 STATS_OFF=$6 EXTRA_OFF=$7
		REAPPLY=1 PRESTART=0 ERR_MASK=1 CAM_MHZ=312 APPLY_DELAY_US=0
		say "run $tag"
		load
		stream "$tag"
		verdict > "$MDIR/$tag.verdict" 2>&1
		cat "$MDIR/$tag.verdict"
		{
			echo "== $tag ($r)"
			grep -E "^(PASS|FAIL)|verdict:" "$MDIR/$tag.verdict"
		} >> "$MDIR/summary.txt"
		sync
		sleep 1
	done
	[ "$2" = all ] && echo "== end" >> "$MDIR/summary.txt"
	cat "$DBGFS/status" > "$MDIR/status-last.txt"
	say "summary ($MDIR/summary.txt; full logs $MDIR/<tag>.log)"
	cat "$MDIR/summary.txt"
	;;
*)
	sed -n '5,26p' "$0"; exit 1 ;;
esac
