#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 serlk <22211586+Serlk@users.noreply.github.com>
#
# Titan 2: the still-picture path of GNOME Snapshot / libaperture without GTK, to tell a
# GStreamer/PipeWire/libcamera problem from a Snapshot one. Builds the same camerabin as aperture:
#   camerabin (camera-source = wrappercamerabinsrc (pipewiresrc ! capsfilter ! decodebin3),
#              viewfinder-sink = fakesink, image-filter = videoconvert, jpegenc quality 95)
# and emits start-capture after the preview runs, then waits for the image-done message.
#   python3 camerabin-still.py [-o /tmp/still.jpg] [--caps 'video/x-raw,format=BGRx,width=1920,height=1080']
#                              [--target <pipewire node id|serial>] [--timeout 20]
# Needs py3-gst (gi GStreamer bindings), gst-plugins-good (jpegenc, multifilesink), gst-plugins-bad
# (camerabin), gst-plugin-pipewire. Debug: GST_DEBUG=2,camerabin*:6,wrappercamerabinsrc:6,basecamerasrc:6,pipewiresrc:5
import argparse
import sys

import gi

gi.require_version("Gst", "1.0")
gi.require_version("GstPbutils", "1.0")
from gi.repository import GLib, Gst, GstPbutils  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--output", default="/tmp/still.jpg")
    ap.add_argument("--caps", default="video/x-raw,format=BGRx,width=1920,height=1080")
    ap.add_argument("--target", default=None, help="pipewiresrc target-object (node serial or name)")
    ap.add_argument("--timeout", type=float, default=20.0)
    ap.add_argument("--delay", type=float, default=3.0, help="seconds of preview before the capture")
    args = ap.parse_args()

    Gst.init(None)
    for name in ("camerabin", "wrappercamerabinsrc", "pipewiresrc", "decodebin3",
                 "videoconvert", "jpegenc", "multifilesink", "fakesink"):
        if Gst.ElementFactory.find(name) is None:
            print(f"missing GStreamer element: {name}", file=sys.stderr)
            return 2

    src = Gst.ElementFactory.make("pipewiresrc", "src")
    src.set_property("client-name", "camerabin-still")
    if args.target:
        src.set_property("target-object", args.target)
    capsfilter = Gst.ElementFactory.make("capsfilter", "caps")
    capsfilter.set_property("caps", Gst.Caps.from_string(args.caps))
    decodebin = Gst.ElementFactory.make("decodebin3", "decode")
    post = Gst.ElementFactory.make("capsfilter", "post")
    post.set_property("caps", Gst.Caps.from_string("video/x-raw"))

    bin_ = Gst.Bin.new("source-bin")
    for e in (src, capsfilter, decodebin, post):
        bin_.add(e)
    src.link(capsfilter)
    capsfilter.link(decodebin)

    def on_pad_added(_db, pad):
        sinkpad = post.get_static_pad("sink")
        if not sinkpad.is_linked():
            print("decodebin3 pad:", pad.get_current_caps() or pad.query_caps(None).to_string())
            pad.link(sinkpad)

    decodebin.connect("pad-added", on_pad_added)
    ghost = Gst.GhostPad.new("src", post.get_static_pad("src"))
    ghost.set_active(True)
    bin_.add_pad(ghost)

    wrapper = Gst.ElementFactory.make("wrappercamerabinsrc", "wrapper")
    wrapper.set_property("video-source", bin_)

    camerabin = Gst.ElementFactory.make("camerabin", "camerabin")
    camerabin.set_property("camera-source", wrapper)
    camerabin.set_property("viewfinder-sink", Gst.ElementFactory.make("fakesink", "vf"))
    camerabin.set_property("image-filter", Gst.ElementFactory.make("videoconvert", "imgconv"))
    camerabin.set_property("location", args.output)

    jpeg = Gst.Caps.from_string("image/jpeg")
    profile = GstPbutils.EncodingVideoProfile.new(jpeg, None, None, 1)
    profile.set_variableframerate(True)
    camerabin.set_property("image-profile", profile)

    loop = GLib.MainLoop()
    state = {"done": False, "rc": 1}

    def on_message(_bus, msg):
        t = msg.type
        if t == Gst.MessageType.ERROR:
            err, dbg = msg.parse_error()
            print(f"ERROR from {msg.src.get_name()}: {err.message}\n  {dbg}")
            state["rc"] = 1
            loop.quit()
        elif t == Gst.MessageType.WARNING:
            err, dbg = msg.parse_warning()
            print(f"WARNING from {msg.src.get_name()}: {err.message}")
        elif t == Gst.MessageType.ELEMENT and msg.get_structure() is not None:
            s = msg.get_structure()
            if s.get_name() == "image-done":
                print("image-done:", s.get_string("filename"))
                state["done"] = True
                state["rc"] = 0
                loop.quit()
            elif s.get_name() in ("preview-image", "GstMultiFileSink"):
                print("element message:", s.get_name())
        elif t == Gst.MessageType.STATE_CHANGED and msg.src == camerabin:
            old, new, _ = msg.parse_state_changed()
            print(f"camerabin {old.value_nick} -> {new.value_nick}")
        return True

    bus = camerabin.get_bus()
    bus.add_signal_watch()
    bus.connect("message", on_message)

    def capture():
        caps = src.get_static_pad("src").get_current_caps()
        print("stream caps:", caps.to_string() if caps else None)
        print("start-capture ->", args.output)
        camerabin.set_property("mode", 1)  # mode-image
        camerabin.emit("start-capture")
        return False

    def timeout():
        print(f"timeout: no image-done after {args.timeout} s")
        loop.quit()
        return False

    print("starting camerabin")
    if camerabin.set_state(Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE:
        print("camerabin refused to start", file=sys.stderr)
        return 1
    GLib.timeout_add(int(args.delay * 1000), capture)
    GLib.timeout_add(int((args.delay + args.timeout) * 1000), timeout)
    try:
        loop.run()
    except KeyboardInterrupt:
        pass
    camerabin.set_state(Gst.State.NULL)
    return state["rc"]


if __name__ == "__main__":
    sys.exit(main())
