"""RIFE frame interpolation for mpv's vapoursynth filter.

Pure helpers (top half) import without VapourSynth so they can be tested anywhere.
"""
import json
import math
import os
from fractions import Fraction

HERE = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(HERE, "ladder.json"), encoding="utf-8") as _f:
    LADDER = json.load(_f)

DUP_THRESHOLD = 0.0015    # luma PlaneStatsDiff below this = same anime drawing held
SCENE_THRESHOLD = 0.12    # luma PlaneStatsDiff above this = hard scene cut
MAX_SRC_FRAMES = 8_000_000  # video_in reports a bogus huge length; ~92h at 24fps
MATRICES = {"709", "470bg", "170m", "2020ncl"}
RANGES = {"limited", "full"}


def source_fps(container_fps):
    """Snap mpv's float fps to an exact fraction; None when unknown (0/NaN, common at stream start)."""
    try:
        f = float(container_fps)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(f) or f <= 0:
        return None
    k = round(f)
    if abs(f - k) < 0.01:
        return Fraction(k)
    k = round(f * 1.001)
    if abs(f * 1.001 - k) < 0.01:
        return Fraction(k * 1000, 1001)
    return Fraction(round(f * 1000), 1000)


def source_pos(i, mult):
    """Output frame i -> (left source frame, position between it and the next). Matches vsmlrt.RIFE."""
    t = Fraction(i) / mult
    n = math.floor(t)
    return n, t - n


def should_hold(frac, diff, anime):
    """Show the source frame instead of a RIFE frame: on-source, across a scene cut, or a held anime drawing."""
    return frac == 0 or diff > SCENE_THRESHOLD or (anime and diff < DUP_THRESHOLD)


def parse_params(user_data):
    try:
        p = json.loads(user_data)
    except (TypeError, ValueError):
        raise ValueError(f"framegen: user-data is not JSON: {user_data!r}")
    if not isinstance(p, dict):
        raise ValueError("framegen: user-data must be an object")
    for key, typ in (("num", int), ("den", int), ("level", int), ("anime", bool),
                     ("engines", str), ("matrix", str), ("range", str)):
        v = p.get(key)
        if not isinstance(v, typ) or (typ is int and isinstance(v, bool)):
            raise ValueError(f"framegen: bad or missing {key!r}")
    if p["num"] <= 0 or p["den"] <= 0:
        raise ValueError("framegen: fps must be positive")
    if not 1 <= p["level"] <= len(LADDER):
        raise ValueError(f"framegen: level {p['level']} outside 1..{len(LADDER)}")
    if p["matrix"] not in MATRICES or p["range"] not in RANGES:
        raise ValueError("framegen: unknown matrix/range")
    return p


# Installed layout: <app>/portable_config/vs/fg_vs.py and <app>/vs-runtime/vs-plugins/vstrt.dll
PLUGINS = os.environ.get("FRAMEGEN_VS_PLUGINS", os.path.join(HERE, "..", "..", "vs-runtime", "vs-plugins"))


def pad_multiple(level):
    """RIFE needs frame sizes divisible by 32/scale (v1 network). The v2 network pads internally,
    but padding to 32 anyway costs <1% and keeps one code path if vsmlrt falls back to v1."""
    return int(round(32 / LADDER[level - 1]["scale"]))


def padded_size(level, width, height):
    m = pad_multiple(level)
    return width + (-width % m), height + (-height % m)


def backend(engines):
    import vsmlrt
    # Static shape = one engine per (model, frame size): fastest kernels, small file, quick to load on
    # seek. fp16 in and out halves GPU<->CPU traffic. CUDA graphs cut launch overhead (vsmlrt default).
    # ponytail: num_streams=2 keeps the GPU fed with a 2-deep queue; raise to 3 if util stays < 85%.
    return vsmlrt.Backend.TRT(fp16=True, output_format=1, static_shape=True, use_cuda_graph=True,
                              num_streams=2, engine_folder=engines)


def rife(rgb, mult, level, engines):
    import vapoursynth as vs
    dll = os.path.join(PLUGINS, "vstrt.dll")
    if not hasattr(vs.core, "trt") and os.path.exists(dll):
        vs.core.std.LoadPlugin(dll)
    import vsmlrt
    step = LADDER[level - 1]
    pw, ph = padded_size(level, rgb.width, rgb.height)
    pw, ph = pw - rgb.width, ph - rgb.height
    padded = rgb.std.AddBorders(right=pw, bottom=ph) if pw or ph else rgb
    out = vsmlrt.RIFE(padded, multi=mult, scale=step["scale"], model=vsmlrt.RIFEModel(step["model"]),
                      backend=backend(engines), video_player=True, _implementation=step.get("impl"))
    return out.std.Crop(right=pw, bottom=ph) if pw or ph else out


# --- Calibration files: <engines>/cal_<w>x<h>.json = {"levels": {"1": out_fps_at_2x | null, ...}}
# A level with a number has a built engine for that frame size and was measured on this GPU.

def cal_path(engines, width, height):
    return os.path.join(engines, f"cal_{width}x{height}.json")


def read_cal(engines, width, height):
    try:
        with open(cal_path(engines, width, height), encoding="utf-8") as f:
            levels = json.load(f)["levels"]
        return {int(k): v for k, v in levels.items() if v is not None}
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return {}


def write_cal(engines, width, height, levels):
    os.makedirs(engines, exist_ok=True)
    tmp = cal_path(engines, width, height) + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"w": width, "h": height, "levels": {str(k): v for k, v in sorted(levels.items())}}, f)
    os.replace(tmp, cal_path(engines, width, height))


def build(video_in, container_fps, params):
    import vapoursynth as vs
    core = vs.core

    src_fps = source_fps(container_fps)
    dst_fps = Fraction(params["num"], params["den"])
    # Unknown source fps, or a target that isn't faster: play through untouched rather than guess.
    # Guessing wrong would desync audio; mult 1 would make vsmlrt raise.
    if src_fps is None or dst_fps <= src_fps:
        return video_in
    mult = dst_fps / src_fps
    if int(mult) == mult:
        mult = int(mult)
    anime = params["anime"]

    clip = core.std.AssumeFPS(video_in[:MAX_SRC_FRAMES], fpsnum=src_fps.numerator, fpsden=src_fps.denominator)
    # Matrix only: transfer stays as-is (PQ/HLG for HDR) so mpv still tone-maps the output.
    rgb = core.resize.Bicubic(clip, format=vs.RGBH, matrix_in_s=params["matrix"], range_in_s=params["range"])
    interp = rife(rgb, mult, params["level"], params["engines"])
    # RIFE may return a different float format (e.g. RGBS for RGBH in); held frames must match it.
    src = rgb if interp.format.id == rgb.format.id else core.resize.Point(rgb, format=interp.format.id)

    # Tiny luma clip; PlaneStatsDiff(n, n+1) drives both scene-cut and duplicate-drawing detection.
    small = core.resize.Bilinear(clip, max(clip.width // 8 // 2 * 2, 16), max(clip.height // 8 // 2 * 2, 16),
                                 format=vs.GRAY8)
    det = core.std.PlaneStats(small, small[1:])

    out_len = interp.num_frames
    det_out = core.std.FrameEval(core.std.BlankClip(det, length=out_len, keep=True),
                                 lambda n: det[source_pos(n, mult)[0]])

    def select(n, f):
        k, frac = source_pos(n, mult)
        if should_hold(frac, f.props.get("PlaneStatsDiff", 0.05), anime):
            return src[k]  # held frames never touch the GPU: VapourSynth is lazy
        return interp

    picked = core.std.FrameEval(core.std.BlankClip(interp, length=out_len, keep=True), select, prop_src=det_out)
    out = core.resize.Bicubic(picked, format=vs.YUV420P10, matrix_s=params["matrix"], range_s=params["range"])
    return core.std.AssumeFPS(out, fpsnum=dst_fps.numerator, fpsden=dst_fps.denominator)
