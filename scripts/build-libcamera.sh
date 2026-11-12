#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 serlk <22211586+Serlk@users.noreply.github.com>
#
# libcamera for the cameras of the mainline Titan 2 (Alpine v3.24 aarch64): libcamera 0.7.1 from
# aports 3.24-stable + patches/libcamera/*.patch (simple pipeline for mtk-camsv-mt6878 with the
# software ISP, frame start from the video node, sensor helpers/properties/tuning for hi847,
# imx766 and s5kgd1sp) and the GPU software ISP (EGL/GLES, libcamera/APKBUILD.diff).
#
#   scripts/build-libcamera.sh fetch    APKBUILD of aports community/libcamera @ APORTS_COMMIT
#                                       -> $DL/src/aports-libcamera (+ libcamera/APKBUILD.diff)
#   scripts/build-libcamera.sh build    fetch + aarch64 build under emulation (scripts/abuild-inner.sh):
#                                       the libcamera archive is checked against the sha512 of
#                                       aports, the patches are added to source=, pkgrel
#                                       T2_REL+100+N; packages signed with the key in $KEYS ->
#                                       $OUT/packages/aports/aarch64 (slow: qt6/qcam, python)
#   scripts/build-libcamera.sh status   what has been built
#   scripts/build-libcamera.sh clean    remove the buildroot ($OUT/buildroot)
#
# Variables:
#   TITAN2_TOOLS=<dir>   a checkout of titan2-tools (Alpine's aarch64 key in tools/initramfs/keys);
#                        default external/titan2-tools:
#                          git clone https://github.com/Serlk/titan2-tools external/titan2-tools
#   OUT=<dir>            output (default out/libcamera); DL=<dir> downloads (default out/libcamera-dl)
#   KEYS=<dir>           package signing key, generated on first use (default out/build-keys);
#                        give titan2-tools' scripts/netroot-serve.sh its .rsa.pub as LOCAL_KEY
#   PACKAGER="Name <mail>"  abuild packager line
#
# Packages: libcamera, libcamera-ipa (simple IPA + tuning), libcamera-tools (cam, lc-compliance),
# qcam, libcamera-gstreamer (libcamerasrc), libcamera-v4l2, py3-libcamera. The PipeWire module
# (libspa-libcamera) is built in Alpine's pipewire package and uses our libcamera.so (same ABI 0.7).
#
# Host and trust: docker, host kernel >= 6.7 (binfmt_misc in user namespaces), Alpine packages
# checked with Alpine's aarch64 key; the libcamera-v0.7.1.tar.gz archive is checked against the
# sha512 of the aports APKBUILD (commit below, HTTPS gitlab.alpinelinux.org).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TITAN2_TOOLS=$(realpath -m "${TITAN2_TOOLS:-$ROOT/external/titan2-tools}")
OUT=$(realpath -m "${OUT:-$ROOT/out/libcamera}")
DL=$(realpath -m "${DL:-$ROOT/out/libcamera-dl}")
KEYS=$(realpath -m "${KEYS:-$ROOT/out/build-keys}")
REL=${ALPINE_RELEASE:-v3.24}
IMG=alpine:${REL#v}
# aports 3.24-stable community/libcamera: 0.7.1-r1 ("rebuild against libpisp 1.5.0")
APORTS_COMMIT=${APORTS_COMMIT:-c47555ebb1c7a0c29fbef5ebaf537177bfb00145}
# Our build number: pkgrel of the APKBUILD := T2_REL; the result is T2_REL + 100 + number of
# patches (10 + 100 + 25 = r135). Raise it with every rebuild that changes something, or apk on the
# phone treats the package as already installed. Alpine's version (0.7.1-r1) is always lower.
T2_REL=${T2_REL:-10}
mkdir -p "$OUT/packages" "$DL/src" "$DL/apk-cache" "$DL/apk-cache-x86" "$KEYS"

need_kernel() {
	local v
	v=$(uname -r | awk -F. '{print $1*100+$2}')
	[ "$v" -ge 607 ] || { echo "host kernel $(uname -r) < 6.7: no binfmt_misc in user namespaces" >&2; exit 1; }
}

need_tools() {
	ls "$TITAN2_TOOLS"/tools/initramfs/keys/*.rsa.pub >/dev/null 2>&1 || {
		echo "no Alpine key in $TITAN2_TOOLS/tools/initramfs/keys:" >&2
		echo "  git clone https://github.com/Serlk/titan2-tools $ROOT/external/titan2-tools (or set TITAN2_TOOLS)" >&2
		exit 1
	}
}

cmd_fetch() {
	local c=$APORTS_COMMIT d=$DL/src/aports-libcamera f
	rm -rf "$d" && mkdir -p "$d"
	for f in APKBUILD qcam.desktop; do
		curl -sfL -o "$d/$f" "https://gitlab.alpinelinux.org/alpine/aports/-/raw/$c/community/libcamera/$f"
	done
	echo "$c" >"$d/.aports-commit"
	cp "$d/APKBUILD" "$d/.APKBUILD.aports"
	grep -q '^pkgver=0.7.1$' "$d/APKBUILD" || { echo "aports APKBUILD is not 0.7.1: check the patches" >&2; exit 1; }
	patch -s -d "$d" -p0 --no-backup-if-mismatch <"$ROOT/libcamera/APKBUILD.diff"
	sed -i "s/^pkgrel=.*/pkgrel=$T2_REL/" "$d/APKBUILD"
	echo "aports community/libcamera @ ${c:0:12}: $(ls "$d" | tr '\n' ' ')"
}

cmd_build() {
	need_kernel
	need_tools
	cmd_fetch
	ls "$ROOT"/patches/libcamera/*.patch >/dev/null
	docker run --rm --security-opt seccomp=unconfined --security-opt apparmor=unconfined \
		--cap-add SYS_ADMIN -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" -e ALPINE_RELEASE="$REL" \
		-e PACKAGER="${PACKAGER:-}" \
		-v "$ROOT:/work:ro" -v "$TITAN2_TOOLS/tools/initramfs/keys:/alpine-keys:ro" \
		-v "$OUT:/out" -v "$KEYS:/out/build-keys" -v "$DL:/dl" \
		"$IMG" sh /work/scripts/abuild-inner.sh libcamera
	ls -l "$OUT"/packages/*/aarch64/ 2>/dev/null || true
}

cmd_status() {
	[ -f "$DL/src/aports-libcamera/.aports-commit" ] && echo "aports: $(cat "$DL/src/aports-libcamera/.aports-commit")"
	ls "$ROOT"/patches/libcamera/
	find "$OUT/packages" -name '*.apk' 2>/dev/null | sort
	[ -f "$OUT/build-libcamera.log" ] && tail -3 "$OUT/build-libcamera.log"
}

case "${1:-}" in
fetch) cmd_fetch ;;
build) cmd_build ;;
status) cmd_status ;;
clean) docker run --rm -v "$OUT:/out" "$IMG" sh -c 'rm -rf /out/buildroot' ;;
*) sed -n '5,34p' "$0"; exit 2 ;;
esac
