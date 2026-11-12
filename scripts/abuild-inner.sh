#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 serlk <22211586+Serlk@users.noreply.github.com>
#
# Inner part of scripts/build-libcamera.sh: runs in an alpine:3.24 (x86_64) container and builds
# aarch64 Alpine packages with abuild in an emulated aarch64 buildroot.
#   sh /work/scripts/abuild-inner.sh <aport>...
# Mounts: /work = this repository (ro), /alpine-keys = Alpine's aarch64 signing key(s) (ro, from
# titan2-tools tools/initramfs/keys), /out = output (buildroot, packages, logs),
# /out/build-keys = our package signing key (generated on first use), /dl = downloads and caches
# (/dl/src/aports-<aport> holds the APKBUILD to build).
#
# aarch64 binaries run through qemu-aarch64 (static-pie from the Alpine package qemu-aarch64) and
# binfmt_misc registered in the OWN binfmt_misc instance of a new user namespace (kernel >= 6.7:
# binfmt_misc is per user namespace). The host's global /proc/sys/fs/binfmt_misc is not touched.
# uid 0 in the namespace = the host user's uid (HOST_UID), 1..65535 -> 100000.., so the buildroot
# belongs to the user, not to root on the host.
set -eu
REL=${ALPINE_RELEASE:-v3.24}
MIRROR=${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}
QEMU=/usr/bin/qemu-aarch64
[ $# -gt 0 ] || { echo "usage: abuild-inner.sh <aport>..." >&2; exit 2; }

if [ -z "${T2_IN_NS:-}" ]; then
	apk add -q --cache-dir /dl/apk-cache-x86 qemu-aarch64 util-linux-misc openssl >/dev/null
	exec env T2_IN_NS=1 unshare --user --mount \
		--map-users=0:"${HOST_UID:?}":1 --map-users=1:100000:65535 \
		--map-groups=0:"${HOST_GID:?}":1 --map-groups=1:100000:65535 \
		--setuid=0 --setgid=0 sh "$0" "$@"
fi

# --- private binfmt_misc ---
mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc
# flags: F = open the interpreter now (works inside the chroot), O = open the binary by its
# original path, C = credentials from the binary
printf '%s' ':qemu-aarch64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:'"$QEMU"':FOC' \
	>/proc/sys/fs/binfmt_misc/register

mounts() {
	r=$1
	mkdir -p $r/proc $r/dev $r/tmp $r/run $r/sys $r/etc
	mount --rbind /proc $r/proc
	mount --rbind /dev $r/dev
	mount -t tmpfs -o mode=1777 tmpfs $r/tmp
	mount -t tmpfs -o mode=755 tmpfs $r/run
	mkdir -p $r/dev/shm 2>/dev/null || true
	mount -t tmpfs -o mode=1777 tmpfs $r/dev/shm
	cp /etc/resolv.conf $r/etc/resolv.conf
}

B=/out/buildroot
mkdir -p $B/etc/apk/keys /out/build-keys /out/packages
cp /alpine-keys/*.rsa.pub $B/etc/apk/keys/
printf '%s\n' "$MIRROR/$REL/main" "$MIRROR/$REL/community" >$B/etc/apk/repositories
mounts $B
apk add --root $B --arch aarch64 --initdb --no-interactive --keys-dir etc/apk/keys \
	--repositories-file $B/etc/apk/repositories --cache-dir /dl/apk-cache \
	alpine-base alpine-sdk sudo
mkdir -p $B/keys
mount --bind /out/build-keys $B/keys
mkdir -p $B/home/build/packages
mount --bind /out/packages $B/home/build/packages
if ! ls /out/build-keys/*.rsa >/dev/null 2>&1; then
	chroot $B sh -c 'cd /keys && openssl genrsa -out titan2.rsa 4096 2>/dev/null &&
		openssl rsa -in titan2.rsa -pubout -out titan2.rsa.pub 2>/dev/null'
fi
cp /out/build-keys/*.rsa.pub $B/etc/apk/keys/
key=$(cd /out/build-keys && ls *.rsa | head -n 1)
chroot $B apk update -q
mkdir -p $B/root/.abuild
printf 'PACKAGER="%s"\nPACKAGER_PRIVKEY=/keys/%s\nREPODEST=/home/build/packages\nJOBS=%s\nMAKEFLAGS=-j%s\n' \
	"${PACKAGER:-titan2-camera builder}" "$key" "$(nproc)" "$(nproc)" >$B/root/.abuild/abuild.conf
for p in "$@"; do
	d=$B/home/build/aports/$p
	rm -rf "$d" && mkdir -p "$d"
	cp /dl/src/aports-$p/* "$d/"
	# the unchanged upstream APKBUILD checksums: fetch and verify the upstream archive first
	chroot $B sh -c "cd /home/build/aports/$p && abuild -F fetch verify"
	if ls /work/patches/$p/*.patch >/dev/null 2>&1; then
		cp /work/patches/$p/*.patch "$d/"
		# pkgrel + 100 + N (N = number of our patches): the Titan 2 package is newer than the
		# Alpine one of the same name, and every new patch gives a new version (otherwise apk
		# considers a rebuilt package as already installed)
		npatch=$(ls /work/patches/$p/*.patch | wc -l)
		awk -v n="$npatch" '/^pkgrel=/ {sub(/=.*/, "=" substr($0, 8) + 100 + n)} {print}' "$d/APKBUILD" >"$d/APKBUILD.new" &&
			mv "$d/APKBUILD.new" "$d/APKBUILD"
		# add our patches to source= (before the closing quote)
		awk -v list="$(cd /work/patches/$p && ls *.patch | tr '\n' ' ')" '
			/^source="/ {insrc=1}
			insrc && /"$/ {sub(/"$/, "\n\t" list "\""); insrc=0}
			{print}' "$d/APKBUILD" >"$d/APKBUILD.new" && mv "$d/APKBUILD.new" "$d/APKBUILD"
	fi
	chroot $B sh -c "cd /home/build/aports/$p && abuild -F checksum && abuild -F -r -c -P /home/build/packages" \
		2>&1 | tee /out/build-$p.log
done
find /out/packages -name '*.apk' | sort
