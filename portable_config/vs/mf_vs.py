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
STATIC_EPS = 3 / 255      # per-pixel luma change below this between neighbours = static pixel (noise is 1-2 levels)
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
        raise ValueError(f"midframe: user-data is not JSON: {user_data!r}")
    if not isinstance(p, dict):
        raise ValueError("midframe: user-data must be an object")
    for key, typ in (("num", int), ("den", int), ("level", int), ("anime", bool),
                     ("engines", str), ("matrix", str), ("range", str)):
        v = p.get(key)
        if not isinstance(v, typ) or (typ is int and isinstance(v, bool)):
            raise ValueError(f"midframe: bad or missing {key!r}")
    p.setdefault("guard", True)
    if not isinstance(p["guard"], bool):
        raise ValueError("midframe: bad 'guard'")
    if p["num"] <= 0 or p["den"] <= 0:
        raise ValueError("midframe: fps must be positive")
    if not 1 <= p["level"] <= len(LADDER):
        raise ValueError(f"midframe: level {p['level']} outside 1..{len(LADDER)}")
    if p["matrix"] not in MATRICES or p["range"] not in RANGES:
        raise ValueError("midframe: unknown matrix/range")
    return p


# Installed layout: <app>/portable_config/vs/mf_vs.py and <app>/vs-runtime/vs-plugins/vstrt.dll
PLUGINS = os.environ.get("MIDFRAME_VS_PLUGINS", os.path.join(HERE, "..", "..", "vs-runtime", "vs-plugins"))


def pad_multiple(level):
    """RIFE needs frame sizes divisible by 32/scale (v1 network; 64 for the 4.25/4.26 heavy nets). The v2
    network pads internally, but padding anyway costs <1% and keeps one code path if vsmlrt falls back to v1."""
    step = LADDER[level - 1]
    return int(round(step.get("pad", 32) / step["scale"]))


def padded_size(level, width, height):
    m = pad_multiple(level)
    return width + (-width % m), height + (-height % m)


def backend(engines):
    import vsmlrt
    # Static shape = one engine per (model, frame size): fastest kernels, small file, quick to load on
    # seek. fp16 in and out halves GPU<->CPU traffic. CUDA graphs cut launch overhead (vsmlrt default).
    # Measured on the RTX 4050: 2 streams + 8 frames in flight (mpv side) plays 1080p 2x flat; 1 stream + 4
    # in flight made 1400 frames late in a minute (mpv's buffer is buffered-frames x concurrent-frames).
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


# --- Calibration files: <engines>/cal_<w>x<h>.json = {"ladder": 2, "levels": {"1": out_fps_at_2x | null, ...}}
# A level with a number has a built engine for that frame size and was measured on this GPU.
# "ladder": 2 = keys index the current ladder; files without it predate the optional heavy level at the top.
CAL_LADDER = 2

def cal_path(engines, width, height):
    return os.path.join(engines, f"cal_{width}x{height}.json")


def read_cal(engines, width, height):
    try:
        with open(cal_path(engines, width, height), encoding="utf-8") as f:
            d = json.load(f)
        shift = 0 if d.get("ladder") == CAL_LADDER else 1
        return {int(k) + shift: v for k, v in d["levels"].items() if v is not None}
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return {}


def write_cal(engines, width, height, levels):
    os.makedirs(engines, exist_ok=True)
    tmp = cal_path(engines, width, height) + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"w": width, "h": height, "ladder": CAL_LADDER, "levels": {str(k): v for k, v in sorted(levels.items())}}, f)
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

    # Static-pixel guard: pixels that don't change between the two neighbours (burned-in subtitles, logos,
    # held backgrounds) come from the source instead of RIFE, which would drag them along with the motion.
    shown = interp
    if params.get("guard", True):
        luma = core.resize.Point(core.std.ShufflePlanes(clip, 0, vs.GRAY), format=vs.GRAYS, range_in_s=params["range"], range_s="full")
        static = core.std.Expr([luma, luma[1:]], f"x y - abs {STATIC_EPS} < 1 0 ?")
        static = static.std.Minimum().std.Maximum().std.Maximum()  # drop speckle, then cover the anti-aliased edges
        if static.format.id != interp.format.replace(color_family=vs.GRAY).id:
            static = core.resize.Point(static, format=interp.format.replace(color_family=vs.GRAY).id)
        blank = core.std.BlankClip(interp, length=interp.num_frames, keep=True)
        src_out = core.std.FrameEval(blank, lambda n: src[source_pos(n, mult)[0]])
        mask_out = core.std.FrameEval(core.std.BlankClip(static, length=interp.num_frames, keep=True),
                                      lambda n: static[source_pos(n, mult)[0]])
        shown = core.std.MaskedMerge(interp, src_out, mask_out)

    def select(n, f):
        k, frac = source_pos(n, mult)
        if should_hold(frac, f.props.get("PlaneStatsDiff", 0.05), anime):
            return src[k]  # held frames never touch the GPU: VapourSynth is lazy
        return shown

    picked = core.std.FrameEval(core.std.BlankClip(interp, length=out_len, keep=True), select, prop_src=det_out)
    out = core.resize.Bicubic(picked, format=vs.YUV420P10, matrix_s=params["matrix"], range_s=params["range"])
    return core.std.AssumeFPS(out, fpsnum=dst_fps.numerator, fpsden=dst_fps.denominator)
