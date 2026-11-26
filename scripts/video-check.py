#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 serlk <22211586+Serlk@users.noreply.github.com>
#
# Titan 2: check a recorded clip (Snapshot, or a gst-launch control run) by opening it again and
# decoding it to the end with decodebin, independently of the pipeline that wrote it:
#   container and codecs, picture size, frame count, frame rate from the frame timestamps,
#   frames missing or repeated in the timestamp sequence, largest gap, file duration,
#   audio track present and not silent, audio start/end relative to the video start/end,
#   and, with --events, the audio/video distance of one audible + visible event (a clap in
#   front of the lens) in the first and in the last seconds of the clip.
#
#   python3 video-check.py CLIP.mp4 [--size 1920x1080] [--fps 30] [--fps-tol 1.5]
#                          [--audio] [--min-frames N] [--max-missing N] [--events] [--window 10]
#                          [--no-video]   (an audio-only test file)
# Exit status 0: every requested check passed; 1: a check failed; 2: the file does not decode.
# Needs py3-gst and the decoders of the clip (openh264dec from gst-plugins-bad, fdkaacdec/mpg123,
# jpegdec for MJPEG), level and videoscale (gst-plugins-good/-base).
import argparse
import sys

import gi

gi.require_version("Gst", "1.0")
gi.require_version("GstApp", "1.0")
gi.require_version("GstPbutils", "1.0")
from gi.repository import GLib, Gst, GstApp, GstPbutils  # noqa: E402,F401

SEC = Gst.SECOND
THUMB_W, THUMB_H = 64, 36


def describe(path):
    """Container, streams and tags as GstDiscoverer sees the file."""
    out = {"container": "?", "video": None, "audio": None, "duration": None}
    try:
        info = GstPbutils.Discoverer.new(30 * SEC).discover_uri(Gst.filename_to_uri(path))
    except GLib.Error as e:
        out["error"] = e.message
        return out
    out["duration"] = info.get_duration() / SEC
    top = info.get_stream_info()
    if isinstance(top, GstPbutils.DiscovererContainerInfo):
        out["container"] = top.get_caps().get_structure(0).get_name()
    for v in info.get_video_streams():
        out["video"] = {
            "codec": v.get_caps().get_structure(0).get_name(),
            "size": (v.get_width(), v.get_height()),
            "fps": (v.get_framerate_num(), v.get_framerate_denom()),
            "bitrate": v.get_bitrate(),
        }
    for a in info.get_audio_streams():
        out["audio"] = {
            "codec": a.get_caps().get_structure(0).get_name(),
            "rate": a.get_sample_rate(),
            "channels": a.get_channels(),
        }
    return out


class Decode:
    """Decode the whole file; keep every video frame timestamp and the audio level."""

    def __init__(self, path):
        self.frames = []      # (pts seconds, mean luma of a thumbnail)
        self.size = None
        self.audio = []       # (pts seconds, duration seconds) per decoded buffer
        self.levels = []      # (time seconds, rms dB) every 10 ms
        self.error = None
        self.pipe = Gst.Pipeline.new("check")
        src = Gst.ElementFactory.make("filesrc")
        src.set_property("location", path)
        self.dec = Gst.ElementFactory.make("decodebin")
        self.pipe.add(src)
        self.pipe.add(self.dec)
        src.link(self.dec)
        self.dec.connect("pad-added", self.on_pad)

    def branch(self, desc, pad):
        b = Gst.parse_bin_from_description(desc, True)
        self.pipe.add(b)
        b.sync_state_with_parent()
        pad.link(b.get_static_pad("sink"))
        return b

    def on_pad(self, _dec, pad):
        caps = pad.get_current_caps() or pad.query_caps(None)
        s = caps.get_structure(0)
        if s.get_name().startswith("video/") and self.size is None:
            self.size = (s.get_value("width"), s.get_value("height"))
            b = self.branch(
                "queue ! videoconvert ! videoscale ! "
                f"video/x-raw,format=GRAY8,width={THUMB_W},height={THUMB_H} ! "
                "appsink name=v sync=false emit-signals=true max-buffers=8", pad)
            b.get_by_name("v").connect("new-sample", self.on_frame)
        elif s.get_name().startswith("audio/") and not self.audio:
            pad.add_probe(Gst.PadProbeType.BUFFER, self.on_audio)
            self.branch("queue ! audioconvert ! level interval=10000000 post-messages=true ! "
                        "fakesink sync=false", pad)
        else:
            self.branch("fakesink sync=false", pad)

    def on_frame(self, sink):
        sample = sink.emit("pull-sample")
        buf = sample.get_buffer()
        ok, m = buf.map(Gst.MapFlags.READ)
        luma = sum(m.data) / max(1, len(m.data)) if ok else 0.0
        if ok:
            buf.unmap(m)
        self.frames.append((buf.pts / SEC, luma))
        return Gst.FlowReturn.OK

    def on_audio(self, _pad, info):
        buf = info.get_buffer()
        if buf.pts != Gst.CLOCK_TIME_NONE:
            dur = buf.duration / SEC if buf.duration != Gst.CLOCK_TIME_NONE else 0.0
            self.audio.append((buf.pts / SEC, dur))
        return Gst.PadProbeReturn.OK

    def run(self):
        bus = self.pipe.get_bus()
        self.pipe.set_state(Gst.State.PLAYING)
        while True:
            msg = bus.timed_pop_filtered(
                600 * SEC, Gst.MessageType.ERROR | Gst.MessageType.EOS | Gst.MessageType.ELEMENT)
            if msg is None:
                self.error = "no end of stream within 600 s"
                break
            if msg.type == Gst.MessageType.ERROR:
                err, dbg = msg.parse_error()
                self.error = f"{msg.src.get_name()}: {err.message} ({dbg})"
                break
            if msg.type == Gst.MessageType.EOS:
                break
            s = msg.get_structure()
            if s is not None and s.get_name() == "level":
                rms = s.get_value("rms")
                self.levels.append((s.get_value("stream-time") / SEC, max(rms)))
        self.pipe.set_state(Gst.State.NULL)
        self.frames.sort()
        return self.error is None


def frame_stats(frames):
    pts = [p for p, _ in frames]
    n = len(pts)
    st = {"frames": n, "missing": 0, "repeated": 0, "max_gap": 0.0, "fps": 0.0, "nominal": 0.0}
    if n < 2:
        return st
    d = sorted(b - a for a, b in zip(pts, pts[1:]))
    nominal = d[len(d) // 2]
    st["nominal"] = nominal
    st["first"], st["last"] = pts[0], pts[-1]
    st["fps"] = (n - 1) / (pts[-1] - pts[0]) if pts[-1] > pts[0] else 0.0
    st["max_gap"] = d[-1]
    for x in d:
        if x <= 0:
            st["repeated"] += 1
        elif nominal > 0 and x > 1.5 * nominal:
            st["missing"] += round(x / nominal) - 1
    return st


def event(frames, levels, t0, t1):
    """Largest picture change and loudest moment between t0 and t1 -> (video s, audio s)."""
    v = [(abs(b[1] - a[1]), b[0]) for a, b in zip(frames, frames[1:]) if t0 <= b[0] <= t1]
    a = [(lv, t) for t, lv in levels if t0 <= t <= t1]
    if not v or not a:
        return None
    return max(v)[1], max(a)[1], max(v)[0], max(a)[0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--size", default=None, help="expected WxH, e.g. 1920x1080")
    ap.add_argument("--fps", type=float, default=None, help="expected frame rate")
    ap.add_argument("--fps-tol", type=float, default=1.5)
    ap.add_argument("--audio", action="store_true", help="an audible audio track is required")
    ap.add_argument("--min-frames", type=int, default=0)
    ap.add_argument("--max-missing", type=int, default=None)
    ap.add_argument("--events", action="store_true",
                    help="audio/video distance of a clap in the first and last --window seconds")
    ap.add_argument("--window", type=float, default=10.0)
    ap.add_argument("--no-video", action="store_true", help="the file has no video stream")
    args = ap.parse_args()

    Gst.init(None)
    fails = []
    d = describe(args.file)
    print(f"file       {args.file}")
    if "error" in d:
        print(f"discover   FAILED: {d['error']}")
    print(f"container  {d['container']}  duration {d['duration'] if d['duration'] is not None else '?'} s")
    if d["video"]:
        v = d["video"]
        print(f"video      {v['codec']} {v['size'][0]}x{v['size'][1]} "
              f"header rate {v['fps'][0]}/{v['fps'][1]} bitrate {v['bitrate']}")
    if d["audio"]:
        a = d["audio"]
        print(f"audio      {a['codec']} {a['rate']} Hz {a['channels']} ch")

    dec = Decode(args.file)
    if not dec.run():
        print(f"decode     FAILED after {len(dec.frames)} frames: {dec.error}")
        return 2
    st = frame_stats(dec.frames)
    print(f"decode     to the end, {st['frames']} frames, picture "
          f"{dec.size[0] if dec.size else '?'}x{dec.size[1] if dec.size else '?'}")
    if st["frames"] >= 2:
        print(f"timing     first {st['first']:.3f} s last {st['last']:.3f} s, "
              f"{st['fps']:.2f} frames/s by timestamps, frame period {st['nominal'] * 1000:.2f} ms")
        print(f"gaps       missing {st['missing']} repeated {st['repeated']} "
              f"largest interval {st['max_gap'] * 1000:.1f} ms")

    if not dec.size and not args.no_video:
        fails.append("no video stream")
    if args.size and dec.size and f"{dec.size[0]}x{dec.size[1]}" != args.size:
        fails.append(f"picture {dec.size[0]}x{dec.size[1]}, expected {args.size}")
    if args.fps and abs(st["fps"] - args.fps) > args.fps_tol:
        fails.append(f"{st['fps']:.2f} frames/s, expected {args.fps} +- {args.fps_tol}")
    if st["frames"] < args.min_frames:
        fails.append(f"{st['frames']} frames, expected at least {args.min_frames}")
    if args.max_missing is not None and st["missing"] > args.max_missing:
        fails.append(f"{st['missing']} missing frames, at most {args.max_missing} allowed")

    if dec.audio:
        a0 = dec.audio[0][0]
        a1 = dec.audio[-1][0] + dec.audio[-1][1]
        peak = max((lv for _, lv in dec.levels), default=-999.0)
        print(f"audio      first {a0:.3f} s end {a1:.3f} s, {len(dec.audio)} buffers, "
              f"loudest 10 ms {peak:.1f} dB rms")
        if st["frames"] >= 2:
            v_end = st["last"] + st["nominal"]
            print(f"a/v        audio starts {(a0 - st['first']) * 1000:+.0f} ms after the video, "
                  f"ends {(a1 - v_end) * 1000:+.0f} ms after it")
        if args.audio and peak < -70.0:
            fails.append(f"audio track is silent ({peak:.1f} dB)")
    else:
        print("audio      no track")
        if args.audio:
            fails.append("no audio track")

    if args.events and st["frames"] >= 2 and dec.levels:
        for name, t0, t1 in (("start", st["first"], st["first"] + args.window),
                             ("end", st["last"] - args.window, st["last"])):
            ev = event(dec.frames, dec.levels, t0, t1)
            if ev:
                print(f"event {name:5s} picture change at {ev[0]:.3f} s (luma step {ev[2]:.1f}), "
                      f"loudest at {ev[1]:.3f} s ({ev[3]:.1f} dB): audio {(ev[1] - ev[0]) * 1000:+.0f} ms")

    for f in fails:
        print(f"FAIL       {f}")
    print("result     " + ("FAILED" if fails else "ok"))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
