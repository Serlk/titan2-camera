<!-- SPDX-License-Identifier: GPL-2.0-or-later -->
<!-- Copyright (C) 2026 serlk <22211586+Serlk@users.noreply.github.com> -->
# titan2-camera: cameras of the Unihertz Titan 2 on mainline Linux

User-space camera support for mainline Linux on the **Unihertz Titan 2** (MediaTek MT6878):
patches for [libcamera](https://libcamera.org/) (simple pipeline handler + software ISP), the
libcamera, WirePlumber and udev configuration, an Alpine package build, and test scripts. Ordinary
applications (`cam`, `qcam`, GNOME Snapshot, GStreamer `libcamerasrc`, PipeWire and the camera
portal) use the cameras through libcamera; there is no hardware ISP driver.

> **Experimental.** The three cameras deliver pictures on the phone, but colour and lens shading
> are not calibrated (see below), and the GPU software ISP is not the default yet.

## Architecture

```
sensor (I2C, CSI-2) -> seninf (CSI-2 receiver) -> CAMSV (DMA to memory, through the MM IOMMU)
   -> V4L2 video node, RAW10 Bayer -> libcamera simple pipeline -> software ISP (CPU or GPU/EGL)
   -> PipeWire / GStreamer / applications
```

| camera | sensor | link | capture | lens |
|---|---|---|---|---|
| main rear | Sony IMX766 (i2c8 0x1a) | CSI port 2, C-PHY 3 trios | camsv1 | VCM DW9800K (driver dw9719) |
| second rear | Hynix Hi-847 (i2c7 0x20) | CSI port 1, D-PHY | camsv2 | VCM DW9714 |
| front | Samsung S5KGD1SP (i2c4 0x2d) | CSI port 0, D-PHY | camsv5 | fixed focus |

Each camera has its own CAMSV and its own media device; the kernel drivers (sensors, seninf,
CAMSV, VCMs) are in the kernel, see [kernel/README.md](kernel/README.md).

The **S5KGD1SP** needs its sensor firmware patch ("TnP") at `/lib/firmware/s5kgd1sp_tnp.bin`,
loaded by the driver with `request_firmware()`. It is **not distributed** here or anywhere in
these repositories: you have to make it from the firmware of your own device. Without it the
front sensor probes, but streaming does not start.

## Contents

| path | what |
|---|---|
| `patches/libcamera/0001-0025` | libcamera 0.7.1 patches: MT6878 CAMSV in the simple pipeline, frame start from the video node, sensor helpers and properties for the three sensors, initial tuning files (CCMs, black level), manual focus and contrast autofocus with the module EEPROM lens map, AE/AWB/CPU-debayer fixes, GPU detail stage (denoise/sharpen), lens shading and tone-curve support in the software ISP, output buffers from the system dma-heap |
| `libcamera/configuration.yaml` | `/etc/libcamera/configuration.yaml`: lens maps per sensor, software ISP mode |
| `libcamera/50-titan2-camera.conf` | WirePlumber: cameras only through libcamera (no raw CAMSV nodes), names and priorities |
| `libcamera/70-titan2-dma-heap.rules` | udev: `/dev/dma_heap/*` for the `video` group (libcamera as the session user) |
| `libcamera/90-titan2-snapshot.gschema.override` | GNOME Snapshot starts on the main rear camera |
| `libcamera/APKBUILD.diff` | changes to Alpine's libcamera APKBUILD (GPU software ISP) |
| `libcamera/camerabin-still.py` | the still-capture path of Snapshot/libaperture without GTK, for debugging |
| `scripts/build-libcamera.sh`, `scripts/abuild-inner.sh` | builds the patched libcamera as signed Alpine aarch64 packages |
| `scripts/camera-raw-test.sh` | bring-up test on the phone without libcamera: sensor -> seninf -> CAMSV -> memory, focus sweep, test pattern, RAW10 -> PNG converter |
| `netroot/` | the hook for titan2-tools' image builder: package lists and the install script |
| `kernel/` | where the kernel part is, and the camera kernel config fragment `kernel/titan2-camera.config` |

## Dependencies

- **titan2-tools** (https://github.com/Serlk/titan2-tools, branch `main`) builds and installs the
  root file system: `scripts/netroot-serve.sh build` with `CAMERA=1 CAMERA_DIR=<this checkout>`
  adds the packages of `netroot/packages`, upgrades `netroot/local-packages` from your
  `LOCAL_REPO` and runs `netroot/install.d/*.sh`. `scripts/build-libcamera.sh` also takes Alpine's
  aarch64 signing key from it (`TITAN2_TOOLS=`, default `external/titan2-tools`):

      git clone https://github.com/Serlk/titan2-tools external/titan2-tools

- **Kernel**: branch `camera` of https://github.com/Serlk/titan2-linux (on top of `titan2`), with
  `kernel/titan2-camera.config`; DTB `mt6878-unihertz-titan2-all.dtb`.
- **Mesa** with Mali-G615 (panthor/panfrost) support for the GPU software ISP and for GTK
  applications that take pictures (Snapshot).
- This repository does **not** need `titan2-vendor-runtime` from titan2-tools: the whole camera
  stack is open source and runs no code of the factory firmware.

## Build and install

```
git clone https://github.com/Serlk/titan2-tools external/titan2-tools
scripts/build-libcamera.sh build          # -> out/libcamera/packages/aports/aarch64 (slow)
```

Put the packages into your apk repository (for example with titan2-tools' repository tools) and
build the image with titan2-tools:

```
CAMERA=1 CAMERA_DIR=<this checkout> LOCAL_REPO=<repo with our libcamera> \
    LOCAL_KEY=<its public key, e.g. out/build-keys/titan2.rsa.pub> GFX=1 scripts/netroot-serve.sh build
```

(run in the titan2-tools checkout; see its README for where `LOCAL_REPO`, `LOCAL_KEY` and
`CAMERA_DIR` may live).

Alpine's libcamera (0.7.1-r1) is pulled in by `pipewire-libs`; a plain `apk add` does not replace
it. Our packages have pkgrel 100 or higher and are installed with `apk add --upgrade` (the image
builder does this for `netroot/local-packages`). On a running phone:
`apk add -u libcamera libcamera-ipa libcamera-tools qcam`.

## Test

On the phone, as root (needs `v4l-utils`):

```
scripts/camera-raw-test.sh check                   # read only
SENSOR=imx766 scripts/camera-raw-test.sh capture 5 # five RAW10 frames to /tmp/imx766.raw
scripts/camera-raw-test.sh pyconv > raw10png.py    # converter for the PC (python3 + numpy)
cam -l; cam -c 1 --capture=10                      # libcamera
qcam                                               # or GNOME Snapshot in the session
```

Do not read camera, seninf, larb or M4U registers with devmem while their power domains are
off: the bus hangs and the watchdog reboots the phone. The test script only uses the drivers.

## Colour and lens shading

No factory tuning is shipped in this repository. What is there:

- **Colour**: the colour correction matrices and the black level of patch 0005 are the module
  colour calibration (a few small measurements of each sensor's colour response), applied after
  the automatic white balance; patch 0021 adds a sensor-specific colour temperature axis for AWB
  and brings the white balance of each unit to the golden module with the gains stored in the
  module EEPROM (read at runtime from `/sys/bus/nvmem/devices/<sensor>-eeprom/nvmem`, exposed by
  the sensor driver).
- **Lens shading**: the software ISP can apply a 17 x 17 shading map per colour temperature
  (patches 0020 and 0022, GPU software ISP only), but the tuning files ship no tables, so shading
  correction is off. Two ways to get tables:
  1. *From the module EEPROM*: every module stores its own shading table; patch 0021 already
     reads it (`ModuleEeprom`), converting it into `Lsc` tables of the tuning file is still to
     be written.
  2. *Your own flat-field*: put a uniform diffuser (or an evenly lit white target filling the
     field of view) in front of the lens, capture raw frames of each sensor at two or three
     colour temperatures (for example 2800 K, 4000 K, 6500 K) with
     `scripts/camera-raw-test.sh capture` and a fixed exposure well below clipping, average a
     few frames, subtract the black level, take per channel the gain that brings each of the
     17 x 17 cells to the centre value, and write them as `Lsc` slots (`ct`, `r`, `g`, `b`) into
     `src/ipa/simple/data/<sensor>.yaml`.
- **Tone, AE, detail**: our own defaults (gamma 2.2, AE target, denoise/sharpen strengths over
  the analogue gain in patch 0017); they are placeholders until calibrated values exist.

## Status

- All three cameras stream (sensor modes: see `scripts/camera-raw-test.sh`) and work in `cam`,
  qcam and GNOME Snapshot through PipeWire.
- CPU software ISP is the default (1080p at 30 fps); the GPU software ISP (detail stage, lens
  shading, full-size output) works but is not the default yet.
- Autofocus: contrast AF on the two rear cameras; lens maps from the module EEPROM, the
  Hi-847 infinity position in `configuration.yaml` is a placeholder.
- Not done: lens shading tables, calibrated tone/noise settings, the hardware ISP.

## Related repositories

- [titan2-linux](https://github.com/Serlk/titan2-linux): the kernel. Branch `titan2` is the mainline port; branches `camera`, `fingerprint` and `gnss` carry the optional camera, fingerprint and GNSS series on top of it.
- [titan2-boot](https://github.com/Serlk/titan2-boot): the boot menu in `boot_a` (Android and Linux side by side).
- [titan2-tools](https://github.com/Serlk/titan2-tools): image builders, initramfs, network and disk root, modem, power and sensor services, and the shared `titan2-vendor-runtime`.
- [titan2-docs](https://github.com/Serlk/titan2-docs): documentation and hardware notes.
- [titan2-camera](https://github.com/Serlk/titan2-camera): cameras (libcamera patches, configuration, tests).
- [titan2-fingerprint](https://github.com/Serlk/titan2-fingerprint): the fingerprint reader (FocalTech sensor through the TEE).
- [titan2-gnss](https://github.com/Serlk/titan2-gnss): GNSS (navigation daemon, GPS HAL bridge, EPO assistance data).
- [titan2-android](https://github.com/Serlk/titan2-android): Android builds for the Titan 2.

## How this project is made / affiliation

- This project is developed with the help of AI coding assistants (Anthropic Claude). Commits
  carry a `Co-Authored-By: Claude` trailer; every change is reviewed and tested on the device
  by the human maintainer (serlk), who is responsible for it.
- It is **not affiliated with postmarketOS** or MT6878-Mainline, and not affiliated with
  Unihertz, MediaTek, Sony, Samsung or SK hynix.

## License

Copyright (c) 2026 serlk. The scripts and documentation are GPL-2.0-or-later, see
[LICENSE](LICENSE). The libcamera patches are under the licenses of the files they change
(LGPL-2.1-or-later, BSD-2-Clause for two shaders); the tuning files they add and the
configuration snippets in `libcamera/` are CC0-1.0, like libcamera's own tuning files. Every file
names its license in an `SPDX-License-Identifier` line or in [REUSE.toml](REUSE.toml); the texts
are in [LICENSES/](LICENSES/).
