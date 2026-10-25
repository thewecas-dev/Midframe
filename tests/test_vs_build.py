"""Runs mf_vs.build() in real VapourSynth with a stand-in vsmlrt (no GPU needed).
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

    def RIFE(clip, multi, scale, model, backend, video_player, _implementation=None):
        assert clip.format.color_family == vs.RGB and clip.format.sample_type == vs.FLOAT
        need = int(round(32 / scale))
        assert clip.width % need == 0 and clip.height % need == 0, (clip.width, clip.height, scale)
        assert backend["static_shape"] and backend["output_format"] == 1
        mult = Fraction(multi)
        fps = clip.fps * mult
        return core.std.BlankClip(clip, format=out_format, length=int(clip.num_frames * mult),
                                  fpsnum=fps.numerator, fpsden=fps.denominator, color=[0.5, 0.5, 0.5])
    m.RIFE = RIFE
    return m


import mf_vs  # noqa: E402

PARAMS = json.dumps({"num": 60, "den": 1, "level": 2, "anime": True, "engines": "/tmp",
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
    out = mf_vs.build(video_in, src_fps, mf_vs.parse_params(PARAMS))
    for n in range(12):
        out.get_frame(n)  # every frame, held or interpolated, must come back in one format
    assert calls, "RIFE was never used"
    return out


def test_static_guard():
    """Left half identical in every frame (a logo), right half alternating (motion): on an interpolated frame the
    left half is the source pixel, the right half is the fake RIFE output (0.5)."""
    sys.modules["vsmlrt"] = fake_vsmlrt(vs.RGBS)
    w, h = 1920, 1080
    left = core.std.BlankClip(format=vs.YUV420P8, width=w // 2, height=h, length=1, color=[200, 128, 128])
    ra = core.std.BlankClip(left, color=[100, 128, 128])
    rb = core.std.BlankClip(left, color=[112, 128, 128])
    a, b = core.std.StackHorizontal([left, ra]), core.std.StackHorizontal([left, rb])
    video_in = core.std.Interleave([a * 24, b * 24])
    params = mf_vs.parse_params(PARAMS)
    out = mf_vs.build(video_in, 30, params)
    f = out.get_frame(1)  # between source 0 and 1
    y_left, y_right = int(f[0][h // 2, 100]), int(f[0][h // 2, w - 100])  # output is 10-bit limited YUV
    assert abs(y_left - 800) < 12, y_left             # source luma 200 -> 800 in 10 bit
    assert abs(y_right - 502) < 20, y_right           # RIFE stand-in grey 0.5 -> (0.5*219+16)*4
    params["guard"] = False
    f = mf_vs.build(video_in, 30, params).get_frame(1)
    assert abs(int(f[0][h // 2, 100]) - 502) < 20, "guard off: RIFE output everywhere"


def test_rife_outputs_float32():
    out = run(vs.RGBS, 23.976)
    assert out.format.id == vs.YUV420P10 and (out.width, out.height) == (1920, 1080)
    assert out.fps == Fraction(60), out.fps


def test_rife_outputs_float16():
    run(vs.RGBH, 30.0)


def test_odd_resolution():
    out = run(vs.RGBS, 25.0, w=1280, h=536)
    assert (out.width, out.height) == (1280, 536)


def test_passthrough_when_not_faster_or_unknown():
    sys.modules["vsmlrt"] = fake_vsmlrt(vs.RGBS)
    video_in = core.std.BlankClip(format=vs.YUV420P8, width=640, height=360, length=10)
    p = mf_vs.parse_params(PARAMS)  # target 60
    assert mf_vs.build(video_in, 59.94, {**p, "num": 60000, "den": 1001}) is video_in  # target == source
    assert mf_vs.build(video_in, 60.0, p) is video_in                                  # target == source
    assert mf_vs.build(video_in, 0.0, p) is video_in                                   # fps unknown


def test_build_engines_writes_calibration():
    import tempfile
    import build_engines
    sys.modules["vsmlrt"] = fake_vsmlrt(vs.RGBS)
    with tempfile.TemporaryDirectory() as d:
        cal = build_engines.main(d, 1280, 720, ["3"])
        assert list(cal) == [3] and cal[3] > 0, cal
        cal = build_engines.main(d, 1280, 720)          # fills the rest, keeps level 3
        assert sorted(cal) == [1, 2, 3, 4, 5], cal
        assert mf_vs.read_cal(d, 1280, 720) == cal


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
    print("test_vs_build ok")
