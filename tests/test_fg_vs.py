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
    assert fg_vs.should_hold(F(0), False, 0.5, False)
    assert fg_vs.should_hold(F(1, 2), True, 0.5, False)
    assert fg_vs.should_hold(F(1, 2), False, 0.001, True)
    assert not fg_vs.should_hold(F(1, 2), False, 0.001, False)
    assert not fg_vs.should_hold(F(1, 2), False, 0.05, True)


def test_source_fps_fallback():
    assert fg_vs.source_fps(23.976) == F(24000, 1001)
    assert fg_vs.source_fps(25.0) == F(25)
    assert fg_vs.source_fps(0) == F(30000, 1001)
    assert fg_vs.source_fps(math.nan) == F(30000, 1001)
    assert fg_vs.source_fps(None) == F(30000, 1001)


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
