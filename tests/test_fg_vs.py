import json
import math
import os
import sys
from fractions import Fraction as F

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "portable_config", "vs"))
import fg_vs


def raises(fn, *args):
    try:
        fn(*args)
    except ValueError:
        return True
    return False


def test_source_pos():
    got = [fg_vs.source_pos(i, F(5, 2)) for i in range(6)]
    assert got == [(0, 0), (0, F(2, 5)), (0, F(4, 5)), (1, F(1, 5)), (1, F(3, 5)), (2, 0)], got


def test_should_hold():
    assert fg_vs.should_hold(F(0), 0.05, False)          # on a source frame
    assert fg_vs.should_hold(F(1, 2), 0.3, False)        # scene cut
    assert fg_vs.should_hold(F(1, 2), 0.001, True)       # held anime drawing
    assert not fg_vs.should_hold(F(1, 2), 0.001, False)  # static live-action still interpolates
    assert not fg_vs.should_hold(F(1, 2), 0.05, True)    # normal motion


def test_source_fps_fallback():
    assert fg_vs.source_fps(23.976) == F(24000, 1001)
    assert fg_vs.source_fps(25.0) == F(25)
    assert fg_vs.source_fps(0) is None
    assert fg_vs.source_fps(math.nan) is None
    assert fg_vs.source_fps(None) is None


def test_pad_amount():
    assert fg_vs.pad_amount(1920, 1080) == (0, 72)
    assert fg_vs.pad_amount(3840, 2160) == (0, 16)
    assert fg_vs.pad_amount(1280, 720) == (0, 48)
    assert fg_vs.pad_amount(1024, 768) == (0, 0)
    w, h = 1918, 1038
    pw, ph = fg_vs.pad_amount(w, h)
    assert (w + pw) % 128 == 0 and (h + ph) % 128 == 0
    assert 1080 + 72 <= 2176 and 2160 + 16 <= 2176  # padded 4K still fits the engine's max shape


def test_shape_profile_fits_padding():
    for w, h in (fg_vs.MIN_SHAPE, fg_vs.OPT_SHAPE, fg_vs.MAX_SHAPE):
        assert w % fg_vs.PAD == 0 and h % fg_vs.PAD == 0, (w, h)
    pw, ph = fg_vs.pad_amount(1920, 1080)
    assert (1920 + pw, 1080 + ph) == fg_vs.OPT_SHAPE


def test_parse_params():
    good = {"num": 60000, "den": 1001, "level": 1, "anime": True, "engines": "C:/e",
            "matrix": "709", "range": "limited"}
    assert fg_vs.parse_params(json.dumps(good)) == good
    for bad in ({**good, "level": 0}, {**good, "level": 5}, {**good, "num": True},
                {k: v for k, v in good.items() if k != "num"}, {**good, "matrix": "evil"}):
        assert raises(fg_vs.parse_params, json.dumps(bad)), bad
    assert raises(fg_vs.parse_params, "not json")
    assert raises(fg_vs.parse_params, "[]")


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
    print("test_fg_vs ok")
