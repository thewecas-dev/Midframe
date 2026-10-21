"""Measure where FrameGen's time goes, outside mpv. Run with FrameGen's bundled Python:

    D:\\FrameGen\\vs-runtime\\python.exe D:\\FrameGen\\portable_config\\vs\\bench.py

Prints frames/second for: colour conversion only, raw RIFE per level, and the full FrameGen filter
per level. 1080p, 23.976 -> 47.952 fps (2x). Real-time needs >= 48 output fps.
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vapoursynth as vs  # noqa: E402
import fg_vs  # noqa: E402

core = vs.core
ENGINES = os.path.join(fg_vs.HERE, "..", "engines")
FRAMES = 240  # output frames per measurement
W, H = 1920, 1080


def source(n):
    # Alternating brightness so every frame pair looks like motion (no holds, no scene cuts).
    a = core.std.BlankClip(format=vs.YUV420P8, width=W, height=H, length=1, color=[100, 128, 128])
    b = core.std.BlankClip(format=vs.YUV420P8, width=W, height=H, length=1, color=[112, 128, 128])
    return core.std.Interleave([a * n, b * n])


def measure(label, clip, frames=FRAMES):
    clip = clip[:frames]
    for _ in clip[:8].frames(prefetch=8):  # warm-up: engine load, first inference
        pass
    t = time.perf_counter()
    for _ in clip.frames(prefetch=8):  # 8 in flight, like mpv's concurrent-frames=8
        pass
    fps = clip.num_frames / (time.perf_counter() - t)
    print(f"{label:<40} {fps:7.1f} fps  {'OK' if fps >= 48 else 'TOO SLOW'}", flush=True)


def params(level):
    return fg_vs.parse_params(json.dumps({"num": 48000, "den": 1001, "level": level, "anime": True,
                                          "engines": ENGINES, "matrix": "709", "range": "limited"}))


def main():
    print(f"VapourSynth {core.version_number()}, {core.num_threads} threads\n")
    src = source(FRAMES)
    rgb = core.resize.Bicubic(src, format=vs.RGBH, matrix_in_s="709")
    measure("convert only (YUV->RGB->YUV)", core.resize.Bicubic(rgb, format=vs.YUV420P10, matrix_s="709"))
    for level in range(1, len(fg_vs.LADDER) + 1):
        name = fg_vs.LADDER[level - 1]["label"]
        measure(f"raw RIFE   L{level} {name}", fg_vs.rife(rgb, 2, level, ENGINES))
        measure(f"FrameGen   L{level} {name}", fg_vs.build(src, 24000 / 1001, params(level)))


if __name__ == "__main__":
    main()
