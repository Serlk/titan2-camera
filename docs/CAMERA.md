<!-- SPDX-License-Identifier: GPL-2.0-or-later -->
<!-- Copyright (C) 2026 serlk <22211586+Serlk@users.noreply.github.com> -->
# Titan 2 cameras on mainline Linux: design, state and tests

State of 2026-11-26. This document describes what this repository ships and how to check it on
the phone. The kernel part (sensor, seninf, CAMSV and VCM drivers, device tree) is in
[kernel/](../kernel/README.md); the image builder is in
[titan2-tools](https://github.com/Serlk/titan2-tools).

## 1. Design

Applications do not talk to the camera hardware directly. Everything goes through
[libcamera](https://libcamera.org/) 0.7.1 with its `simple` pipeline handler and the software ISP:

```
sensor --CSI-2--> seninf port --> CAMSV (DMA through the MM IOMMU) --> V4L2 video node, RAW10 Bayer
  --> libcamera simple pipeline --> software ISP (GPU/EGL by default, CPU fallback)
  --> PipeWire camera node (WirePlumber) --> portal --> GNOME Snapshot, browsers, ...
  --> or directly: cam, qcam, GStreamer libcamerasrc
```

- **One media device per camera.** Each CAMSV instance (camsv1 IMX766, camsv2 Hi-847, camsv5
  S5KGD1SP) registers its own media device with one chain: sensor -> seninf port -> video node,
  the lens as an ancillary link of the sensor. libcamera's simple handler creates one camera per
  media device, so the cameras are independent: a camera whose graph is incomplete (for example
  the front sensor without its firmware patch) does not hide the others.
- **Device matching.** The simple handler only takes media devices listed in its
  `supportedDevices` table; patch 0001 adds the CAMSV driver name. The media device driver name is
  set explicitly to `mtk-camsv` because `media_device_info.driver` is only 16 bytes long.
- **Frame start.** Patch 0002 takes the frame start event from the capture video node when no
  subdevice of the chain provides `V4L2_EVENT_FRAME_SYNC`, so exposure and gain are applied on
  the start of frame and not only when a buffer arrives. The CAMSV driver sends that event.
- **Sensors in libcamera.** Patches 0003/0004 add the gain models (camera sensor helpers) and the
  sensor properties of the three sensors (test pattern codes after the drivers' menus); the
  unit cell size is not known and is left empty.
- **Camera names and priorities.** WirePlumber (`libcamera/50-titan2-camera.conf`) exposes the
  cameras only through libcamera (the raw CAMSV video nodes would otherwise show up as Bayer
  "cameras") and names them: IMX766 "Back Camera" (priority 1000, the default PipeWire camera),
  S5KGD1SP "Front Camera" (900), Hi-847 "Back Camera 2 (Hi-847)" (800). Uncommenting
  `node.disabled = true` for the Hi-847 gives Snapshot exactly two cameras (a front/back toggle
  instead of a list). `libcamera/90-titan2-snapshot.gschema.override` makes Snapshot start on
  "Back Camera"; `netroot/local.d/t2-camera-schemas.start` compiles the schemas at boot.
- **Output buffers.** The software ISP output comes from the system dma-heap (patch 0011): the
  CMA heap is too small for full-size frames. `libcamera/70-titan2-dma-heap.rules` gives the
  `video` group access to `/dev/dma_heap/*`, so libcamera works as the session user.
- **Orientation.** Hi-847 and IMX766 are "Back" with rotation 270, S5KGD1SP is "Front" with
  rotation 90 (from the device tree); applications decide whether they rotate.

## 2. Image quality

No tuning taken from the phone's original camera software is shipped. What exists:

| part | state |
|---|---|
| black level | 64 (10 bit) for all three sensors, subtracted per channel before the white balance gains and the colour matrix (patch 0009; before, the CPU debayer subtracted it after the gains and dark scenes turned magenta) |
| white balance | grey-world AWB with sums on the 8-bit scale (patch 0010); a sensor colour temperature axis and the per-unit white balance correction from the module EEPROM (patch 0021) |
| colour matrix | the module colour calibration (CCMs per colour temperature, patch 0005) |
| exposure | proportional AE with a tunable target and highlight limit (patches 0008, 0012), metering zones (0019), a linear metering mode, exposure program and 50 Hz flicker avoidance (0024); targets are our placeholders |
| focus | contrast autofocus on both rear cameras (patch 0015): coarse pass over 11 positions, fine pass around the best one, continuous mode by default, `AfModeAuto` + `AfTrigger`, manual `LensPosition`; lens map from the module EEPROM (0025), fallback map in `configuration.yaml` |
| lens shading | supported by the GPU software ISP (patches 0020, 0022), **but no tables are shipped, so it is off**. See the README for the two ways to make tables (module EEPROM, own flat-field) |
| tone, denoise, sharpening | gamma 2.2 by default; denoise and sharpening (GPU only, patch 0013) with our placeholder strengths over the analogue gain (patch 0017) |

The module EEPROM (8 KiB, read once by the hi847 and imx766 drivers) is exposed read-only at
`/sys/bus/nvmem/devices/<sensor>-eeprom/nvmem`; libcamera parses its lens calibration and white
balance there at run time. Nothing from it is stored in this repository.

## 3. Software ISP: GPU by default

`libcamera/configuration.yaml` sets `software_isp.mode: gpu`. The GPU path (EGL surfaceless on
panthor/panfrost, created inside the process that runs libcamera, normally WirePlumber) is the
only path with lens shading, the tone curve and the denoise/sharpen stage, and it outputs the
full size of each sensor mode. Measured on the phone (IMX766, 1920x1080 requested, sensor mode
2048x1152):

| chain (300 frames) | frames/s | CPU (of 8 cores) |
|---|---:|---:|
| software ISP on the CPU -> fakesink | ~27 | 35 % |
| software ISP on the GPU -> fakesink | 30 | 22 % |
| CPU ISP -> videoconvert -> openh264enc -> mp4, with queues | ~27 | 36 % |
| GPU ISP -> videoconvert -> openh264enc -> mp4, with queues | 30 | 20 % |
| GPU ISP -> vp8enc -> webm | 30 | 38 % |
| the same chains without `queue` elements | ~20 | — |

Notes:
- libcamera 0.7.1 reads **only** the configuration key: there is no environment override and no
  automatic fall back to the CPU when EGL does not initialise (the camera then does not start).
  `~/.config/libcamera/configuration.yaml` wins over `/etc/libcamera/configuration.yaml` if it
  exists; use it to switch one user to `mode: cpu`.
- The GPU path only offers 32-bit RGB formats (`XRGB8888`, `ARGB8888`, `XBGR8888`, `ABGR8888`);
  ask `cam` for `XRGB8888`, not `RGB888`. PipeWire and Snapshot use `BGRx` anyway.
- The session user needs access to `/dev/dri/renderD128`.
- The CPU debayer crops instead of scaling and gives at most the input width minus two pattern
  widths: a request for exactly 1920x1080 then picks the full 3264x2448 mode of the Hi-847.
  Ask for 1912x1080 on the CPU path to get the 1080p sensor mode.
- Open risk: after the GPU writes an output buffer, nothing invalidates the CPU cache before a
  CPU reader (videoconvert, the GTK sink) maps it. No artefacts were seen; if stale blocks or
  stripes appear, a `DMA_BUF_IOCTL_SYNC` read pair after `glFinish()` is the fix.

## 4. Stills

All three cameras give pictures in `cam`, `qcam` and GNOME Snapshot (through PipeWire and the
camera portal). Requirements and pitfalls found on the way:
- Snapshot saves pictures only if `XDG_PICTURES_DIR` exists: the titan2-tools niri session runs
  `xdg-user-dirs-update` (package `xdg-user-dirs`).
- GTK first tries to export its own GPU textures as dma-buf. A Mesa EGL bug returned success with
  an invalid file descriptor when the driver refused the export, and Snapshot failed to save; the
  fix is the first patch in titan2-tools `patches/mesa/`.
- `qcam`: "Save As..." writes JPEG/PNG; "Save Raw" and `cam --file=x.dng` write DNG (the APKBUILD
  change adds `tiff-dev`).
- `libcamera/camerabin-still.py` takes a still through the same camerabin path as Snapshot
  without GTK, to separate GStreamer/PipeWire problems from application problems.

## 5. Video recording

GNOME Snapshot 50 records H.264 in MP4 when `openh264enc` or `x264enc` is installed
(`openh264enc` is preferred), otherwise VP8 in WebM. With the GPU software ISP, `openh264enc`
keeps 1080p at 30 frames/s (table in section 3); x264 cannot keep 1080p30 on this CPU even with
`ultrafast`. Sound comes from the session's default PipeWire source through `pulsesrc`; record
as the session user (root has no session sound socket).

Results on the phone (2026-11-25, `-all` board):
- control path (libcamerasrc -> openh264enc -> MP4, 300 frames): 1920x1080, 30.0 frames/s by
  timestamps, 0 missing, 0 repeated;
- Snapshot, a 13 s clip: H.264 1920x1080 plus audio, 29.7 frames/s, 4 missing frames, audio
  present and in step with the video (the end of the audio 0.2 s before the video).

The one-minute acceptance runs (section 7.3) are still to be done; the control run with the
microphone in the same `gst-launch` pipeline did not finish its file (a test pipeline problem,
not seen in Snapshot).

Hardware encoders are kernel work: the JPEG encoder and the video co-processor (VCP) that runs the
H.264 encoder firmware. The VCP reaches its "ready" state on the phone, but it does not answer
the first request yet, so there is no hardware H.264 encoder. Snapshot will pick `v4l2h264enc` by
itself once such an encoder exists and its "hardware encoding" setting is on.

## 6. Hardware ISP

The SoC's RAW/YUV image processing engines are not used by this user space. The kernel series
has an experimental driver (`camraw`, board `-raw`) that replays a command queue captured from the
phone's original camera software on both RAW engines. It **delivers frames**: on a lit scene a
correct colour 1450x1088 picture comes out of the hardware ISP. You can reproduce this with your
own capture: `scripts/camraw-capture.sh` on the original Android, `scripts/camraw-dump-info.py` on
the PC, `scripts/camera-raw-replay-test.sh` on the phone (README.md, "Hardware ISP replay"). The
limits: everything the ISP does to the picture (black level, white balance, colour, sharpening) is
frozen in the captured request; there is no 3A, no auto exposure (exposure and gain by hand through
the sensor controls) and no libcamera integration, and nothing else in this repository depends on
it. The dumps contain the tuning output of the phone's camera software from your own device: never
publish or share them.

## 7. Tests on the phone

### 7.1 Bring-up without libcamera (root)

```
scripts/camera-raw-test.sh check                   # read only: devices, drivers, power domains
SENSOR=imx766 scripts/camera-raw-test.sh capture 5 # five RAW10 frames to /tmp/imx766.raw
scripts/camera-raw-test.sh pyconv > raw10png.py    # converter for the PC (python3 + numpy)
```

Never read camera, seninf, larb or M4U registers with devmem while their power domains are off:
the bus hangs and the phone reboots. The scripts only use the drivers.

### 7.2 libcamera

```
cam -l                                                  # three cameras
cam -c1 -p | grep -E 'Location|Rotation|Model'          # Back/270 (rear), Front/90 (front)
LIBCAMERA_LOG_LEVELS='SimplePipeline:1,SoftwareIsp:0,Debayer:1' cam -c1 --capture=300 --metadata \
  --stream width=1920,height=1080,pixelformat=XRGB8888 2>&1 | tee /tmp/gpu-cam.log
grep -ciE 'egl|debayer.*(error|fail)' /tmp/gpu-cam.log  # 0
wpctl status | sed -n '/Video/,/Settings/p'             # Back Camera (default), Back Camera 2 (Hi-847), Front Camera
gst-launch-1.0 pipewiresrc ! videoconvert ! waylandsink # the default camera through PipeWire
```

Expected with the GPU path: `Picked 1920x1080-...` (or 2048x1152 on the IMX766, a 1080-line
sensor mode, not the full frame), 300 frames at about 30 frames/s, no EGL errors; memory of the
process steady over the run. Autofocus: `LIBCAMERA_LOG_LEVELS=IPASoftAf:0` shows the scan and
"Focused at ..."; `LensPosition` appears in the metadata.

GPU acceptance in the session: ten minutes of Snapshot preview with steady WirePlumber memory,
no panthor faults in `dmesg`, no stale blocks in the picture; switching between the three
cameras several times; preview continues after a suspend/resume cycle.

### 7.3 Video recording (session user, not root)

`scripts/camera-record-test.sh` and `scripts/video-check.py` go to the phone together (they find
each other in the same directory; `py3-gst` is needed):

```
./camera-record-test.sh env             # sensor, effective configuration and software ISP mode,
                                        # elements, Snapshot settings, expected encoder, sound sources
./camera-record-test.sh control         # 300 frames without an application
./camera-record-test.sh control-audio   # the same with the session microphone
./camera-record-test.sh snapshot        # record 60 s in Snapshot ("Video"), clap at start and end, stop, close
./camera-record-test.sh photos          # after recording: 5 frames from each camera
./camera-record-test.sh stages          # if there is no clip or it is empty: where the data stops
```

`video-check.py` decodes every clip to the end and prints the container and codecs, the size,
the number of frames, the frame rate from the timestamps, missing and repeated frames, the audio
level, audio start/end against the video and, for the claps, the audio/video distance at the
start and at the end, then `result ok` or the failed checks. Acceptance for a one-minute clip:
H.264 1920x1080 in MP4 with audio, at least 1700 frames, 30 +- 1.5 frames/s by timestamps.
`missing` counts gaps in the timestamps; a recorder that spaces the timestamps evenly shows lost
frames only as too few frames for the duration.

## 8. Open items

- Lens shading tables (module EEPROM conversion or own flat-field), calibrated tone, AE and
  denoise values.
- Hi-847 lens infinity position (placeholder in `configuration.yaml`); IMX766 lens sweep.
- The one-minute recording acceptance; recording with the hardware H.264 encoder (kernel).
- The hardware ISP: 3A and auto exposure, requests built instead of replayed, libcamera integration.
