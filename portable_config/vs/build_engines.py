"""Pre-build the TensorRT engine for every ladder level, then measure each level's speed on this GPU,
so playback can start at a level that keeps up instead of stepping down through slow ones.

Usage: python build_engines.py <engines_dir>
Writes <engines_dir>/READY as JSON: {"w": 1920, "h": 1080, "levels": [output fps at 2x, per level]}.
Engines that already exist are reused (vsmlrt skips the build), so re-running only re-measures.
"""
import gc
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fg_vs

W, H = 1920, 1080
FRAMES = 96


def measure(level, engines):
    """Output fps of raw RIFE at 2x on 1080p (half the frames are interpolated)."""
    import vapoursynth as vs
    core = vs.core
    a = core.std.BlankClip(format=vs.RGBH, width=W, height=H, length=1, color=[0.40, 0.40, 0.40])
    b = core.std.BlankClip(format=vs.RGBH, width=W, height=H, length=1, color=[0.45, 0.45, 0.45])
    clip = fg_vs.rife(core.std.Interleave([a * FRAMES, b * FRAMES]), 2, level, engines)[:FRAMES]
    for _ in clip[:8].frames(prefetch=8):  # warm-up: engine load, first inferences
        pass
    t = time.perf_counter()
    for _ in clip.frames(prefetch=8):
        pass
    fps = clip.num_frames / (time.perf_counter() - t)
    del clip
    gc.collect()  # free this level's engine before the next, so levels don't compete for VRAM
    return round(fps, 1)


def main(engines):
    os.makedirs(engines, exist_ok=True)
    levels = []
    for level in range(1, len(fg_vs.LADDER) + 1):
        print(f"level {level}/{len(fg_vs.LADDER)}: {fg_vs.LADDER[level - 1]['label']}", flush=True)
        levels.append(measure(level, engines))  # first request also builds + caches the engine
        print(f"  {levels[-1]} fps", flush=True)
    with open(os.path.join(engines, "READY"), "w") as f:
        json.dump({"w": W, "h": H, "levels": levels}, f)
    print("done", flush=True)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
