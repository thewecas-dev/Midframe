"""Build the TensorRT engine for RIFE levels at one frame size, measure each on this GPU, and record
the result in <engines>/cal_<w>x<h>.json so playback starts at a level that keeps up.

Usage: python build_engines.py <engines_dir> <width> <height> [level ...]
       (no levels = every ladder level; levels already measured for this size are skipped)
Engines that already exist are reused (vsmlrt skips the build), so re-running only re-measures.
"""
import gc
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mf_vs

FRAMES = 96


def measure(level, engines, width, height):
    """Output fps of raw RIFE at 2x (half the frames are interpolated) for width x height."""
    import vapoursynth as vs
    core = vs.core
    a = core.std.BlankClip(format=vs.RGBH, width=width, height=height, length=1, color=[0.40, 0.40, 0.40])
    b = core.std.BlankClip(format=vs.RGBH, width=width, height=height, length=1, color=[0.45, 0.45, 0.45])
    clip = mf_vs.rife(core.std.Interleave([a * FRAMES, b * FRAMES]), 2, level, engines)[:FRAMES]
    for _ in clip[:8].frames(prefetch=8):  # warm-up: engine build/load, first inferences
        pass
    t = time.perf_counter()
    for _ in clip.frames(prefetch=8):
        pass
    fps = clip.num_frames / (time.perf_counter() - t)
    del clip
    gc.collect()  # free this level's engine before the next, so levels don't compete for VRAM
    return round(fps, 1)


def main(engines, width, height, levels=()):
    levels = [int(x) for x in levels] or list(range(1, len(mf_vs.LADDER) + 1))
    cal = mf_vs.read_cal(engines, width, height)
    for level in levels:
        if level in cal:
            continue
        print(f"{width}x{height} level {level}/{len(mf_vs.LADDER)}: {mf_vs.LADDER[level - 1]['label']}", flush=True)
        cal[level] = measure(level, engines, width, height)
        print(f"  {cal[level]} fps", flush=True)
        mf_vs.write_cal(engines, width, height, cal)  # progress survives a crash in a later level
    print("done", flush=True)
    return cal


if __name__ == "__main__":
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    main(sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4:])
