"""Measure where FrameGen's time goes, outside mpv. Run with FrameGen's bundled Python:

    D:\\FrameGen\\vs-runtime\\python.exe D:\\FrameGen\\portable_config\\vs\\bench.py [width height]

Prints frames/second for: colour conversion only, raw RIFE per level (also recorded as calibration),
and the full FrameGen filter per level. Default 1080p, 23.976 -> 47.952 fps (2x): real time needs >= 48.
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vapoursynth as vs  # noqa: E402
import fg_vs  # noqa: E402
import build_engines  # noqa: E402

core = vs.core
ENGINES = os.path.join(fg_vs.HERE, "..", "engines")
FRAMES = 240


def source(n, w, h):
    # Alternating brightness so every frame pair looks like motion (no holds, no scene cuts).
    a = core.std.BlankClip(format=vs.YUV420P8, width=w, height=h, length=1, color=[100, 128, 128])
    b = core.std.BlankClip(format=vs.YUV420P8, width=w, height=h, length=1, color=[112, 128, 128])
    return core.std.Interleave([a * n, b * n])


def measure(label, clip):
    clip = clip[:FRAMES]
    for _ in clip[:8].frames(prefetch=8):
        pass
    t = time.perf_counter()
    for _ in clip.frames(prefetch=8):  # 8 in flight, like mpv's concurrent-frames=8
        pass
    fps = clip.num_frames / (time.perf_counter() - t)
    print(f"{label:<40} {fps:7.1f} fps  {'OK' if fps >= 48 else 'TOO SLOW'}", flush=True)


def main(w=1920, h=1080):
    print(f"VapourSynth R{core.core_version.release_major}, {core.num_threads} threads, {w}x{h}\n")
    src = source(FRAMES, w, h)
    rgb = core.resize.Bicubic(src, format=vs.RGBH, matrix_in_s="709")
    measure("convert only (YUV->RGB->YUV)", core.resize.Bicubic(rgb, format=vs.YUV420P10, matrix_s="709"))
    cal = build_engines.main(ENGINES, w, h)
    for level, fps in sorted(cal.items()):
        print(f"{'raw RIFE   L%d %s' % (level, fg_vs.LADDER[level - 1]['label']):<40} {fps:7.1f} fps")
    for level in sorted(cal):
        params = fg_vs.parse_params(json.dumps({"num": 48000, "den": 1001, "level": level, "anime": True,
                                                "engines": ENGINES, "matrix": "709", "range": "limited"}))
        measure(f"FrameGen   L{level} {fg_vs.LADDER[level - 1]['label']}", fg_vs.build(src, 24000 / 1001, params))


if __name__ == "__main__":
    main(*(int(x) for x in sys.argv[1:3]))
