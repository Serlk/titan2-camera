<!-- SPDX-License-Identifier: GPL-2.0-or-later -->
<!-- Copyright (C) 2026 serlk <22211586+Serlk@users.noreply.github.com> -->
# Kernel part of the Titan 2 camera support

The kernel drivers live in the kernel repository, not here:

- https://github.com/Serlk/titan2-linux, branch **`camera`**: a patch series on top of the
  mainline port branch `titan2`. It adds the MT6878 seninf (CSI-2 receiver) and CAMSV (capture to
  memory) drivers, the sensor drivers hi847 (mainline driver with OF/24 MHz support), imx766 and
  s5kgd1sp, the module calibration EEPROM as a read-only nvmem device, the device tree bindings,
  and the camera nodes of `mt6878-unihertz-titan2-cameras.dtsi` (included by
  `mt6878-unihertz-titan2-all.dts`).

      git clone -b camera https://github.com/Serlk/titan2-linux

- `titan2-camera.config` (this directory): the kernel config fragment with the camera options,
  merged after titan2-tools' `configs/mainline-titan2.config`.

A copy of the series as plain patches (`kernel/series/camera/`) will be added to this repository
later.

The S5KGD1SP driver loads the sensor's firmware patch from `/lib/firmware/s5kgd1sp_tnp.bin`
(`request_firmware()`). That file is not part of the kernel, of this repository or of any image:
it has to be made from the firmware of your own device.
