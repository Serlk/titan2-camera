#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 serlk <22211586+Serlk@users.noreply.github.com>
#
# Cameras: video recording with sound on an installed image (docs/CAMERA.md, "Video recording").
# Runs ON THE PHONE as the session user (not root: the sound source and the PipeWire camera node
# belong to the session), busybox sh. video-check.py (scripts/ of this repository) must be next
# to this script, or its path given in CHECK=.
#
#   camera-record-test.sh env             # what is selected: sensor, software ISP mode, elements,
#                                         # Snapshot settings, the encoder the H.264 profile takes,
#                                         # PipeWire sources
#   camera-record-test.sh control [N]     # control path without an application, N frames (300):
#                                         # libcamerasrc ! queue ! videoconvert ! I420 ! queue ! openh264enc ! mp4mux
#   camera-record-test.sh control-audio [N]  # the same plus the session microphone (pulsesrc ! fdkaacenc)
#   camera-record-test.sh snapshot        # starts Snapshot with a log; after it exits, checks the new clips
#   camera-record-test.sh check FILE...   # checks finished clips (a one-minute recording from the app)
#   camera-record-test.sh stages          # no clip or an empty one: where the data stops (PipeWire
#                                         # camera, session sound, profile/encoder, container finalisation)
#   camera-record-test.sh photos [N]      # after recording: N frames (5) from each camera through cam
#
# Variables: CAM: libcamera camera name (default IMX766, /base/soc@0/i2c@11e03000/camera@1a);
# OUT: result directory (~/camera-record-DATE); BITRATE: bit/s for control (8000000);
# PW_CAM: id/name of the PipeWire camera node for stages (empty: the default source);
# MIN_FRAMES: frame threshold for a one-minute clip (1700 = 28 frames/s on average).
# Time and frame rate come from the frame timestamps and the file duration (video-check.py), not
# from the wall clock.
set -u

CAM=${CAM:-/base/soc@0/i2c@11e03000/camera@1a}
OUT=${OUT:-$HOME/camera-record-$(date +%Y%m%d-%H%M%S)}
BITRATE=${BITRATE:-8000000}
PW_CAM=${PW_CAM:-}
MIN_FRAMES=${MIN_FRAMES:-1700}
HERE=$(cd "$(dirname "$0")" && pwd)
CHECK=${CHECK:-$HERE/video-check.py}
VIDEOS=${VIDEOS:-$HOME/Videos/Camera}

die() { echo "$*" >&2; exit 1; }

need_session() {
	[ "$(id -u)" != 0 ] || die "run as the session user, not as root"
	: "${XDG_RUNTIME_DIR:=/run/user/$(id -u)}"
	export XDG_RUNTIME_DIR
	[ -S "$XDG_RUNTIME_DIR/pipewire-0" ] || echo "WARNING: no $XDG_RUNTIME_DIR/pipewire-0: no PipeWire session found"
}

need_check() {
	[ -f "$CHECK" ] || die "no $CHECK (copy scripts/video-check.py next to this script or set CHECK=)"
}

has() { gst-inspect-1.0 "$1" >/dev/null 2>&1; }

# The first file found wins (libcamera 0.7.1): the user's configuration, then the system one.
softisp_config() {
	for f in "$HOME/.config/libcamera/configuration.yaml" /etc/libcamera/configuration.yaml; do
		if [ -f "$f" ]; then
			echo "libcamera configuration: $f"
			grep -nE '^[[:space:]]*mode:' "$f" | sed 's/^/  /'
			return
		fi
	done
	echo "libcamera configuration: none found (the library's default software ISP mode)"
}

# Which encoder the H.264 profile of Snapshot 50 gets: the profile exists if openh264enc or
# x264enc is installed; openh264enc ranks above x264enc; v4l2h264enc takes part only with the
# hardware encoding setting on and only if the element is registered (an H.264 M2M node exists).
encoder_choice() {
	hw=$(gsettings get org.gnome.Snapshot enable-hardware-encoding 2>/dev/null || echo "?")
	sw=
	has x264enc && sw=x264enc
	has openh264enc && sw=openh264enc
	echo "hardware encoding setting: $hw"
	if [ -z "$sw" ]; then
		echo "H.264/MP4 profile not available (no openh264enc and no x264enc) -> VP8/WebM"
		has v4l2h264enc && echo "  v4l2h264enc is there, but without a software encoder the H.264 profile is not chosen"
		return
	fi
	if [ "$hw" = true ] && has v4l2h264enc; then
		echo "expected encoder: v4l2h264enc (hardware; software fallback: $sw)"
	else
		echo "expected encoder: $sw (software)"
		[ "$hw" = true ] && echo "  the setting is on, but there is no v4l2h264enc element"
		has v4l2h264enc && [ "$hw" != true ] && echo "  v4l2h264enc is there, the setting is off: not used"
	fi
}

cmd_env() {
	need_session
	mkdir -p "$OUT"
	{
		echo "== kernel and packages"
		uname -a
		apk info -e -v libcamera gstreamer gst-plugins-bad gst-plugins-good gst-plugins-ugly snapshot pipewire mesa-egl 2>/dev/null
		echo "== libcamera cameras (selected CAM=$CAM)"
		cam -l 2>&1 | grep -vE '^\[' || true
		cam -l 2>&1 | grep -qF "$CAM" || echo "WARNING: $CAM is not in the list of cam -l"
		echo "== software ISP"
		softisp_config
		echo "== GStreamer elements"
		for e in libcamerasrc pipewiresrc pulsesrc videoconvert openh264enc x264enc v4l2h264enc \
			 v4l2jpegenc h264parse mp4mux qtmux fdkaacenc lamemp3enc openh264dec; do
			if has "$e"; then echo "  $e present"; else echo "  $e MISSING"; fi
		done
		echo "== Snapshot"
		gsettings list-recursively org.gnome.Snapshot 2>&1
		encoder_choice
		echo "== PipeWire"
		wpctl status 2>&1 | sed -n '/^Audio/,/^Settings/p'
	} 2>&1 | tee "$OUT/env.txt"
	echo "-> $OUT/env.txt"
}

# The control path. Queues between the camera, the colour conversion and the encoder are
# required: without them the chain runs in one thread and loses frame rate.
control_run() {
	audio=$1; n=$2
	need_session; need_check
	mkdir -p "$OUT"
	has openh264enc || die "no openh264enc"
	f=$OUT/control$([ "$audio" = 1 ] && echo -audio).mp4
	log=${f%.mp4}.log
	softisp_config | tee "${f%.mp4}.softisp.txt"
	abranch=
	if [ "$audio" = 1 ]; then
		abranch="pulsesrc ! queue ! audioconvert ! audioresample ! fdkaacenc ! aacparse ! mux."
	fi
	echo "recording $n frames -> $f"
	# -v prints the negotiated formats of every element; the libcamera log the chosen sensor
	# mode and the software ISP back end.
	# shellcheck disable=SC2086
	LIBCAMERA_LOG_LEVELS='SimplePipeline:1,SoftwareIsp:1,Debayer:1,*:2' \
	gst-launch-1.0 -e -v libcamerasrc camera-name="$CAM" ! \
		video/x-raw,width=1920,height=1080 ! identity eos-after="$n" ! queue ! \
		videoconvert n-threads=2 ! video/x-raw,format=I420 ! queue ! \
		openh264enc bitrate="$BITRATE" ! h264parse ! mp4mux name=mux ! filesink location="$f" \
		$abranch >"$log" 2>&1
	rc=$?
	echo "gst-launch: exit code $rc, log $log"
	echo "== sensor mode and software ISP (libcamera log)"
	grep -iE 'Picked|debayer|softwareisp|egl' "$log" | head -20
	echo "== negotiated formats"
	grep -E 'libcamerasrc[0-9]*\.GstPad:src: caps|openh264enc[0-9]*\.GstPad:(sink|src): caps|pulsesrc[0-9]*\.GstPad:src: caps' "$log" |
		sed 's/^.*GstPipeline:pipeline0\///' | sort -u
	echo "== errors and warnings"
	grep -ciE 'error|warn|qos|drop' "$log" | sed 's/^/lines with error|warn|qos|drop: /'
	grep -iE 'error|qos|drop' "$log" | head -10
	echo "== file check (encoder openh264enc, container MP4)"
	set -- --size 1920x1080 --fps 30 --min-frames "$n" --max-missing 0
	[ "$audio" = 1 ] && set -- "$@" --audio
	python3 "$CHECK" "$f" "$@" | tee "${f%.mp4}.check.txt"
}

check_clip() {
	need_check
	python3 "$CHECK" "$1" --size 1920x1080 --fps 30 --audio --events --min-frames "$MIN_FRAMES"
}

cmd_check() {
	[ $# -gt 0 ] || die "check FILE..."
	mkdir -p "$OUT"
	for f in "$@"; do
		check_clip "$f" | tee "$OUT/$(basename "$f").check.txt"
		echo
	done
}

cmd_snapshot() {
	need_session; need_check
	mkdir -p "$OUT"
	mark=$OUT/.start
	: >"$mark"
	softisp_config | tee "$OUT/snapshot.softisp.txt"
	encoder_choice | tee "$OUT/snapshot.encoder.txt"
	echo "Snapshot: \"Video\" mode, record 60 s with movement and a clap in front of the lens at the start and at the end, stop, close the window."
	RUST_LOG=snapshot=debug,aperture=debug GST_DEBUG=2 snapshot >"$OUT/snapshot.log" 2>&1
	echo "== profile and encoder from the application log"
	grep -iE 'profile|feature|hw accel|hardware|encod' "$OUT/snapshot.log" | head -20
	echo "== errors"
	grep -iE 'error|failed|not-negotiated|qos' "$OUT/snapshot.log" | head -20
	echo "== new clips in $VIDEOS"
	found=0
	# file names from Snapshot contain spaces: read them line by line
	find "$VIDEOS" -type f -newer "$mark" 2>/dev/null | sort > "$OUT/.new"
	while IFS= read -r f; do
		found=1
		ls -l "$f"
		check_clip "$f" | tee "$OUT/$(basename "$f").check.txt"
	done < "$OUT/.new"
	rm -f "$OUT/.new"
	[ "$found" = 1 ] || echo "no clips: run $0 stages"
}

# Where the data stops when the direct path records but the application leaves no clip or an
# empty one.
cmd_stages() {
	need_session; need_check
	mkdir -p "$OUT"
	src="pipewiresrc"
	[ -n "$PW_CAM" ] && src="pipewiresrc target-object=$PW_CAM"
	echo "== 1. PipeWire camera source ($src), 90 frames"
	# shellcheck disable=SC2086
	if timeout 30 gst-launch-1.0 -v $src num-buffers=90 ! fakesink >"$OUT/stage1.log" 2>&1; then
		grep -E 'pipewiresrc[0-9]*\.GstPad:src: caps' "$OUT/stage1.log" | sort -u | head -2
		echo "  the PipeWire camera delivers frames"
	else
		echo "  NO frames from the PipeWire camera node (log $OUT/stage1.log; wpctl status)"
	fi
	echo "== 2. session sound source (pulsesrc), 3 s"
	if timeout 30 gst-launch-1.0 -e pulsesrc num-buffers=300 ! audioconvert ! fdkaacenc ! aacparse ! \
		mp4mux ! filesink location="$OUT/stage2.mp4" >"$OUT/stage2.log" 2>&1; then
		python3 "$CHECK" "$OUT/stage2.mp4" --no-video --audio | sed 's/^/  /'
	else
		echo "  NO sound (log $OUT/stage2.log); to check without sound:"
		echo "  gsettings set org.gnome.Snapshot enable-audio-recording false"
	fi
	echo "== 3. profile and encoder"
	encoder_choice | sed 's/^/  /'
	echo "== 4. encoder and container finalisation on stop (SIGINT after 5 s, like the stop button)"
	enc=
	has x264enc && enc="x264enc tune=zerolatency speed-preset=faster bitrate=2048"
	has openh264enc && enc="openh264enc bitrate=2097152"
	if [ -n "$enc" ]; then
		# shellcheck disable=SC2086
		timeout -s INT 8 gst-launch-1.0 -e $src ! queue ! videoconvert ! video/x-raw,format=I420 ! queue ! \
			$enc ! h264parse ! mp4mux ! filesink location="$OUT/stage4.mp4" >"$OUT/stage4.log" 2>&1
		ls -l "$OUT/stage4.mp4" 2>&1 | sed 's/^/  /'
		python3 "$CHECK" "$OUT/stage4.mp4" --size 1920x1080 --fps 30 | sed 's/^/  /'
	else
		echo "  no software H.264 encoder"
	fi
	echo "-> $OUT"
}

cmd_photos() {
	n=${1:-5}
	mkdir -p "$OUT"
	i=1
	cam -l 2>&1 | grep -E '^[0-9]+:' | while read -r line; do
		echo "== camera $i: $line"
		if cam -c"$i" --capture="$n" >"$OUT/photo$i.log" 2>&1; then
			grep -c 'fps' "$OUT/photo$i.log" | sed "s/^/  frames received: /"
		else
			echo "  ERROR (log $OUT/photo$i.log)"
			tail -3 "$OUT/photo$i.log" | sed 's/^/  /'
		fi
		i=$((i + 1))
	done
}

case ${1:-} in
env) cmd_env ;;
control) control_run 0 "${2:-300}" ;;
control-audio) control_run 1 "${2:-300}" ;;
snapshot) cmd_snapshot ;;
check) shift; cmd_check "$@" ;;
stages) cmd_stages ;;
photos) cmd_photos "${2:-5}" ;;
*) sed -n '5,28p' "$0"; exit 1 ;;
esac
