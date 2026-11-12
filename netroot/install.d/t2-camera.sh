# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 serlk <22211586+Serlk@users.noreply.github.com>
#
# Cameras in the Titan 2 rootfs. Sourced by titan2-tools scripts/netroot-serve.sh build with
# CAMERA=1 CAMERA_DIR=<this repository>: $R = image root, $X = this repository (mounted read-only
# in the build container). Packages: netroot/packages and netroot/local-packages (libcamera
# from LOCAL_REPO, built by scripts/build-libcamera.sh). Installs:
#   /etc/libcamera/configuration.yaml   lens maps per sensor, software ISP mode
#   /etc/wireplumber/...                cameras only through libcamera, no raw V4L2 nodes
#   /etc/udev/rules.d/70-titan2-dma-heap.rules  dma-buf heaps for the video group
#   GSettings override (Snapshot default camera) + local.d script compiling the schemas
install -D -m 644 $X/libcamera/configuration.yaml $R/etc/libcamera/configuration.yaml
install -D -m 644 $X/libcamera/50-titan2-camera.conf \
	$R/etc/wireplumber/wireplumber.conf.d/50-titan2-camera.conf
# /dev/dma_heap/* for the video group (libcamera runs as the session user)
install -D -m 644 $X/libcamera/70-titan2-dma-heap.rules \
	$R/etc/udev/rules.d/70-titan2-dma-heap.rules
# GNOME Snapshot: start on the main rear camera; schemas compiled at boot (local.d)
install -D -m 644 $X/libcamera/90-titan2-snapshot.gschema.override \
	$R/usr/share/glib-2.0/schemas/90-titan2-snapshot.gschema.override
install -D -m 755 $X/netroot/local.d/t2-camera-schemas.start \
	$R/etc/local.d/t2-camera-schemas.start
echo "CAMERA: libcamera configuration + WirePlumber camera profile"
