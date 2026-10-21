"""Pre-build the TensorRT engine for every ladder level so playback never stalls on a build.

Usage: python build_engines.py <engines_dir>
Writes <engines_dir>/READY (holding the ladder.json hash) when every engine exists.
"""
import hashlib
import os
import sys
from fractions import Fraction

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fg_vs


def ladder_hash():
    with open(os.path.join(fg_vs.HERE, "ladder.json"), "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def main(engines):
    import vapoursynth as vs
    os.makedirs(engines, exist_ok=True)
    blank = vs.core.std.BlankClip(width=1920, height=1080, format=vs.RGBH, length=4, fpsnum=24, fpsden=1)
    for level in range(1, len(fg_vs.LADDER) + 1):
        print(f"level {level}/{len(fg_vs.LADDER)}: {fg_vs.LADDER[level - 1]['label']}", flush=True)
        fg_vs.rife(blank, 2, level, engines).get_frame(1)  # first frame request builds + caches the engine
    with open(os.path.join(engines, "READY"), "w") as f:
        f.write(ladder_hash())
    print("done", flush=True)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
