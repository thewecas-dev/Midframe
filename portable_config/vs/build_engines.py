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


def die_with_children():
    """Windows: put this process in a job that kills every descendant (vsmlrt's trtexec) when it ends.
    mpv kills the builder when the player quits; without this the trtexec build kept running, pinning the GPU
    and corrupting the next measurements."""
    if os.name != "nt":
        return
    import ctypes
    from ctypes import wintypes
    k32 = ctypes.windll.kernel32
    job = k32.CreateJobObjectW(None, None)
    JobObjectExtendedLimitInformation, KILL_ON_JOB_CLOSE = 9, 0x2000

    class IO_COUNTERS(ctypes.Structure):
        _fields_ = [(n, ctypes.c_ulonglong) for n in ("ReadOps", "WriteOps", "OtherOps", "ReadBytes", "WriteBytes", "OtherBytes")]

    class BASIC(ctypes.Structure):
        _fields_ = [("PerProcessUserTimeLimit", wintypes.LARGE_INTEGER), ("PerJobUserTimeLimit", wintypes.LARGE_INTEGER),
                    ("LimitFlags", wintypes.DWORD), ("MinimumWorkingSetSize", ctypes.c_size_t),
                    ("MaximumWorkingSetSize", ctypes.c_size_t), ("ActiveProcessLimit", wintypes.DWORD),
                    ("Affinity", ctypes.c_size_t), ("PriorityClass", wintypes.DWORD), ("SchedulingClass", wintypes.DWORD)]

    class EXTENDED(ctypes.Structure):
        _fields_ = [("BasicLimitInformation", BASIC), ("IoInfo", IO_COUNTERS), ("ProcessMemoryLimit", ctypes.c_size_t),
                    ("JobMemoryLimit", ctypes.c_size_t), ("PeakProcessMemoryUsed", ctypes.c_size_t), ("PeakJobMemoryUsed", ctypes.c_size_t)]

    info = EXTENDED()
    info.BasicLimitInformation.LimitFlags = KILL_ON_JOB_CLOSE
    k32.SetInformationJobObject(job, JobObjectExtendedLimitInformation, ctypes.byref(info), ctypes.sizeof(info))
    k32.AssignProcessToJobObject(job, k32.GetCurrentProcess())  # the handle stays open for our lifetime on purpose

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
    die_with_children()
    main(sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4:])
