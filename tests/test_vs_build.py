"""Runs fg_vs.build() in real VapourSynth with a stand-in vsmlrt (no GPU needed).
Skips when VapourSynth isn't installed."""
import json
import os
import sys
import types
from fractions import Fraction

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "portable_config", "vs"))
try:
    import vapoursynth as vs
except ImportError:
    print("test_vs_build skipped (no vapoursynth)")
    sys.exit(0)
core = vs.core


def fake_vsmlrt(out_format):
    """Mimics vsmlrt.RIFE's contract: float RGB in, size divisible by 64 required, length*multi out."""
    m = types.ModuleType("vsmlrt")
    m.Backend = types.SimpleNamespace(TRT=lambda **kw: kw)
    m.RIFEModel = lambda v: v

    def RIFE(clip, multi, scale, model, backend, video_player):
        assert clip.format.color_family == vs.RGB and clip.format.sample_type == vs.FLOAT
        assert clip.width % 64 == 0 and clip.height % 64 == 0, (clip.width, clip.height)
        mult = Fraction(multi)
        fps = clip.fps * mult
        return core.std.BlankClip(clip, format=out_format, length=int(clip.num_frames * mult),
                                  fpsnum=fps.numerator, fpsden=fps.denominator, color=[0.5, 0.5, 0.5])
    m.RIFE = RIFE
    return m


import fg_vs  # noqa: E402

PARAMS = json.dumps({"num": 60, "den": 1, "level": 1, "anime": True, "engines": "/tmp",
                     "matrix": "709", "range": "limited"})


def run(out_format, src_fps, w=1920, h=1080, frames=48):
    sys.modules["vsmlrt"] = fake_vsmlrt(out_format)
    # Alternating brightness: every pair of frames differs like normal motion (not a hold, not a cut).
    a = core.std.BlankClip(format=vs.YUV420P8, width=w, height=h, length=1, color=[100, 128, 128])
    b = core.std.BlankClip(format=vs.YUV420P8, width=w, height=h, length=1, color=[112, 128, 128])
    video_in = core.std.Interleave([a * (frames // 2), b * (frames // 2)])
    calls = []
    real = sys.modules["vsmlrt"].RIFE
    sys.modules["vsmlrt"].RIFE = lambda *a, **k: calls.append(1) or real(*a, **k)
    out = fg_vs.build(video_in, src_fps, fg_vs.parse_params(PARAMS))
    for n in range(12):
        out.get_frame(n)  # every frame, held or interpolated, must come back in one format
    assert calls, "RIFE was never used"
    return out


def test_rife_outputs_float32():
    out = run(vs.RGBS, 23.976)
    assert out.format.id == vs.YUV420P10 and (out.width, out.height) == (1920, 1080)
    assert out.fps == Fraction(60), out.fps


def test_rife_outputs_float16():
    run(vs.RGBH, 30.0)


def test_odd_resolution():
    out = run(vs.RGBS, 25.0, w=1280, h=536)
    assert (out.width, out.height) == (1280, 536)


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
    print("test_vs_build ok")
