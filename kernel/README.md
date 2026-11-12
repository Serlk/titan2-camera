<!-- SPDX-License-Identifier: GPL-2.0-or-later -->
<!-- Copyright (C) 2026 serlk <22211586+Serlk@users.noreply.github.com> -->
# Kernel part of the Titan 2 camera support

The kernel drivers are a patch series (`patches/`) against the mainline port of
[titan2-linux](https://github.com/Serlk/titan2-linux), branch `titan2`. The series adds the MT6878 seninf (CSI-2
receiver) and CAMSV (capture to memory) drivers, the sensor drivers hi847 (the mainline driver
with OF/24 MHz support), imx766 and s5kgd1sp, the module calibration EEPROM as a read-only
nvmem device, the device tree bindings, and the camera nodes of
`mt6878-unihertz-titan2-cameras.dtsi` (included by `mt6878-unihertz-titan2-all.dts`).

This directory:

- `patches/`: the series as `git format-patch` files (12 patches):
  - `0001-media-dt-bindings-mediatek-Add-MT6878-CAMSV.patch`
  - `0002-media-mediatek-camsv-Add-MT6878-CAMSV-capture-driver.patch`
  - `0003-media-dt-bindings-mediatek-Add-MT6878-seninf.patch`
  - `0004-media-mediatek-seninf-Add-MT6878-sensor-interface-dr.patch`
  - `0005-media-dt-bindings-Add-Hynix-Hi-847-image-sensor.patch`
  - `0006-media-i2c-hi847-Add-OF-support-power-management-24-M.patch`
  - `0007-media-dt-bindings-Add-Sony-IMX766-image-sensor.patch`
  - `0008-media-i2c-Add-Sony-IMX766-image-sensor-driver.patch`
  - `0009-media-dt-bindings-Add-Samsung-S5KGD1SP-image-sensor.patch`
  - `0010-media-i2c-Add-Samsung-S5KGD1SP-image-sensor-driver.patch`
  - `0011-arm64-dts-mediatek-mt6878-Add-disabled-seninf-and-CA.patch`
  - `0012-arm64-dts-mediatek-mt6878-titan2-Add-the-three-camer.patch`
- `titan2-camera.config`: the kernel config fragment with these options.

## Building

The kernel code of this part lives only here, as a patch series; titan2-linux itself carries
only the base port. The commands assume `titan2-tools` and this repository are cloned side by
side and run in the root of `titan2-tools`, whose `scripts/build-mainline.sh` builds the kernel
(titan2-docs: `docs/BUILD-LINUX.md`).

**The patches** of this directory go on top of the branch `titan2` of
https://github.com/Serlk/titan2-linux:

    git clone -b titan2 https://github.com/Serlk/titan2-linux linux
    cd linux
    git checkout -b titan2-local 50a22e5003dd4a71f27f241069064799bf2a6a3c
    git am ../../titan2-camera/kernel/patches/*.patch
    cd ..

The series was made with `git format-patch` on `titan2` commit `50a22e5003dd4a71f27f241069064799bf2a6a3c` (the `git checkout` line
above). A newer `titan2` usually takes it as well (`git checkout -b titan2-local titan2`); if
`git am` stops, use the base commit. The series of titan2-camera, titan2-fingerprint and
titan2-gnss touch different hunks and can be applied one after another on the same tree (tested
in the order camera, fingerprint, gnss).

**The config fragment** `titan2-camera.config` is merged after the base config
(`configs/mainline-titan2.config` of titan2-tools) by `scripts/build-mainline.sh`:

    SRC=linux FRAGMENTS=../titan2-camera/kernel/titan2-camera.config scripts/build-mainline.sh

`FRAGMENTS` takes several files separated by spaces (a later value of a symbol wins, as in the
kernel's `scripts/kconfig/merge_config.sh`), e.g. all three optional parts:

    FRAGMENTS="../titan2-camera/kernel/titan2-camera.config ../titan2-fingerprint/kernel/titan2-fingerprint.config ../titan2-gnss/kernel/titan2-gnss.config" \
        SRC=linux scripts/build-mainline.sh

Without the matching patches the symbols of the fragment have no Kconfig entry and the kernel
build drops them silently.

## The S5KGD1SP firmware patch

The S5KGD1SP driver loads the sensor's firmware patch from `/lib/firmware/s5kgd1sp_tnp.bin`
(`request_firmware()`). That file is not part of the kernel, of this repository or of any image:
it has to be made from the firmware of your own device. `tools/csv2fw.py` of this repository only
converts a register table (CSV with the header `step,register_u16,value_u16`) into the flat
little-endian (register, value) format the driver reads; it contains no register data. Without
the file the front camera does not stream; the other two cameras do not need it.
