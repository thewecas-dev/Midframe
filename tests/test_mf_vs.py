import json
import math
import os
import sys
from fractions import Fraction as F

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "portable_config", "vs"))
import mf_vs


def raises(fn, *args):
    try:
        fn(*args)
    except ValueError:
        return True
    return False


def test_source_pos():
    got = [mf_vs.source_pos(i, F(5, 2)) for i in range(6)]
    assert got == [(0, 0), (0, F(2, 5)), (0, F(4, 5)), (1, F(1, 5)), (1, F(3, 5)), (2, 0)], got


def test_should_hold():
    assert mf_vs.should_hold(F(0), 0.05, False)          # on a source frame
    assert mf_vs.should_hold(F(1, 2), 0.3, False)        # scene cut
    assert mf_vs.should_hold(F(1, 2), 0.001, True)       # held anime drawing
    assert not mf_vs.should_hold(F(1, 2), 0.001, False)  # static live-action still interpolates
    assert not mf_vs.should_hold(F(1, 2), 0.05, True)    # normal motion


def test_source_fps_fallback():
    assert mf_vs.source_fps(23.976) == F(24000, 1001)
    assert mf_vs.source_fps(25.0) == F(25)
    assert mf_vs.source_fps(0) is None
    assert mf_vs.source_fps(math.nan) is None
    assert mf_vs.source_fps(None) is None


def test_padded_size():
    # level 1 (heavy): 64; levels 2/3: scale 1 -> multiple of 32; level 4: 64; level 5: 128
    assert mf_vs.padded_size(1, 1920, 1080) == (1920, 1088)
    assert mf_vs.padded_size(2, 1920, 1080) == (1920, 1088)
    assert mf_vs.padded_size(4, 1920, 1080) == (1920, 1088)
    assert mf_vs.padded_size(5, 1920, 1080) == (1920, 1152)
    assert mf_vs.padded_size(5, 3840, 2160) == (3840, 2176)
    assert mf_vs.padded_size(2, 1280, 720) == (1280, 736)
    assert mf_vs.padded_size(3, 1024, 768) == (1024, 768)
    assert mf_vs.padded_size(1, 1280, 720) == (1280, 768)


def test_cal_roundtrip():
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        assert mf_vs.read_cal(d, 1920, 1080) == {}
        mf_vs.write_cal(d, 1920, 1080, {3: 105.0, 1: 42.6})
        assert mf_vs.read_cal(d, 1920, 1080) == {1: 42.6, 3: 105.0}
        # legacy file without the ladder marker: keys predate the heavy level, shift by one
        with open(mf_vs.cal_path(d, 1280, 720), "w") as f:
            json.dump({"w": 1280, "h": 720, "levels": {"1": 90, "4": 200}}, f)
        assert mf_vs.read_cal(d, 1280, 720) == {2: 90, 5: 200}
        with open(mf_vs.cal_path(d, 1920, 1080), "w") as f:
            f.write("garbage")
        assert mf_vs.read_cal(d, 1920, 1080) == {}


def test_parse_params():
    good = {"num": 60000, "den": 1001, "level": 1, "anime": True, "engines": "C:/e",
            "matrix": "709", "range": "limited"}
    assert mf_vs.parse_params(json.dumps(good)) == {**good, "guard": True}
    for bad in ({**good, "level": 0}, {**good, "level": 6}, {**good, "num": True},
                {k: v for k, v in good.items() if k != "num"}, {**good, "matrix": "evil"}):
        assert raises(mf_vs.parse_params, json.dumps(bad)), bad
    assert raises(mf_vs.parse_params, "not json")
    assert raises(mf_vs.parse_params, "[]")


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
    print("test_mf_vs ok")
