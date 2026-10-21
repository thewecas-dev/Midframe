<p align="center"><img src="packaging/icon.png" width="96" alt="Tween icon"></p>
<h1 align="center">Tween</h1>
<p align="center">A Windows video player that generates the frames in between.<br>
Local files and YouTube links, interpolated in real time with RIFE on your NVIDIA GPU.</p>

---

Tween plays a 24 fps film at 48, 72 or 144 fps, and a 30 fps YouTube video at 60. The extra frames are made live
by RIFE (an AI interpolation model) running on TensorRT. Nothing is downloaded, nothing is re-encoded, and when
the GPU can't keep up Tween steps down a level instead of stuttering.

Built on [mpv](https://mpv.io), [VapourSynth](https://www.vapoursynth.com), [vs-mlrt](https://github.com/AmusementClub/vs-mlrt),
[uosc](https://github.com/tomasklaen/uosc) and [yt-dlp](https://github.com/yt-dlp/yt-dlp). Free, MIT licensed.

## What you need

| | |
|---|---|
| OS | Windows 10 or 11, 64-bit |
| GPU | NVIDIA RTX 20-series or newer, with a current Game Ready or Studio driver (TensorRT and the RIFE models run on CUDA; integrated and AMD GPUs are not supported) |
| VRAM | 4 GB for 1080p, 6 GB recommended for 1440p/4K |
| Disk | about 6 GB for the install, plus 1–2 GB of generated engines |
| Display | any; a 120/144 Hz panel is where it shines |

Tested on an RTX 4050 Laptop (6 GB): 1080p at 2× and 3× and YouTube 1080p 30→60 play with zero dropped frames.

## Install

1. Download `Tween-Setup.exe` and its `.bin` slices from the latest release and keep them in one folder.
2. Run the setup. It installs to `%LOCALAPPDATA%\Tween` and needs no admin rights.
3. **Three Windows settings** make or break smooth playback. Do them once:
   - Settings → System → Display → Graphics → *Add desktop app* → `%LOCALAPPDATA%\Tween\mpv.exe` → Options → **High performance**. Otherwise the GPU idles at a few hundred MHz during playback.
   - NVIDIA Control Panel → *Set up G-SYNC* → **untick Enable G-SYNC** (or at least windowed mode). A variable refresh rate fights mpv's frame pacing.
   - Settings → System → Display → Advanced display → refresh rate set to a **fixed** value (144 Hz), not "Dynamic".
4. Start Tween from the Start menu. The first launch builds and measures the RIFE engines for 1080p in the
   background (10–20 minutes, once). The start screen says **RIFE ready** when it's done. Keep the laptop plugged in.

## Use

| Key | Action |
|---|---|
| Ctrl+O | Open a file (or drag one onto the window) |
| Ctrl+V | Play a YouTube/URL from the clipboard |
| F | Frame-rate menu: 1.5× 2× 2.5× 3×, 60 90 120 144, Custom…, interpolation on/off |
| D | Debug overlay: level, drops, GPU clock, measured refresh rate, graphs |
| Shift+I | mpv's own stats page |

- Before each video Tween asks for the **frame rate**; for YouTube it first asks the **quality**
  (Auto / 2160p / 1440p / 1080p / 720p / 480p). Enter accepts the highlighted (last used) answer, Esc keeps it.
  Set `ask=no` in `portable_config\script-opts\framegen.conf` to skip the prompts.
- **Pick a target that divides your refresh rate.** On 144 Hz: 2× (48) and 3× (72) for films, 2× (60) for 30 fps
  video. 60 fps on 144 Hz is an uneven 2.4 refreshes per frame.
- **The first video at a new size** (720p, 1440p, 4K) builds one more engine (a few minutes) while the video plays
  at its original rate; interpolation starts on its own when the engine is ready.
- Anime is handled faithfully by default: held drawings stay held and nothing is blended across a scene cut.
  Set `anime=no` in `framegen.conf` for live action only.

## How it picks a level

Every engine is measured once on your GPU (`portable_config\engines\cal_<w>x<h>.json`). A video starts at the
best level whose measured speed covers the frames it needs with 50% headroom. Ladder, best quality first:
RIFE 4.26 → RIFE 4.6 → RIFE 4.6 half scale → RIFE 4.6 quarter → lower target fps → original fps.
During playback it only ever steps down (a level change reloads the filter, a 1–2 s pause) and a level that failed
stays blocked until the next file. If the filter itself fails (driver, VRAM) the video keeps playing at its
original rate and a notice says why.

## Troubleshooting

Turn on the debug overlay (D) first. It answers most questions:

| Overlay shows | Meaning | Fix |
|---|---|---|
| `GPU clock 600 / 3105 MHz · P5` | GPU parked in power saving | Windows Graphics setting → High performance (above) |
| `display 144 Hz (measured 48.3)` | variable refresh rate active | turn off G-SYNC, fixed refresh rate |
| `preparing RIFE 4.6…` in the status line | an engine is being built | wait; original fps meanwhile |
| "Interpolation turned off: …" notice | filter error | see `portable_config\framegen-error.log` |
| "RIFE setup failed" | engine build error | see `portable_config\engines\build-error.log`; usually a driver or CUDA problem (`nvidia-smi` must work) |

For anything else: start `mpv.exe --log-file=tween.log` from the install folder, reproduce, and attach the log to
an issue together with an overlay screenshot.

Benchmark the pipeline without mpv (prints raw RIFE and full-filter fps per level and records the calibration;
run it only while Tween is closed):

```
vs-runtime\python.exe portable_config\vs\bench.py [width height]
```

## Build from source

On Windows, with [7-Zip](https://www.7-zip.org) and [Inno Setup 6](https://jrsoftware.org/isinfo.php) on PATH
and about 10 GB free:

```powershell
powershell -ExecutionPolicy Bypass -File packaging\build.ps1
```

It downloads pinned versions of mpv, VapourSynth (R79, the last with the API vs-mlrt's TensorRT plugin needs),
vs-mlrt with the TensorRT runtime, the RIFE models, uosc and yt-dlp, adds this repo's `portable_config`, and
produces `dist\Tween-Setup.exe` plus `.bin` slices. The icon is drawn by `packaging\make_icon.py` (Pillow).

Layout:

- `portable_config/scripts/framegen/` — the mpv Lua side: prompts, menus, auto mode, overlay, engine builds.
  (The script id stays `framegen` for config and script-message compatibility.)
- `portable_config/vs/` — the VapourSynth side: `fg_vs.py` builds the filter graph, `build_engines.py` measures
  levels, `ladder.json` defines them.
- `packaging/` — build script, launcher with crash recovery, installer, icon.
- `docs/` — design notes and the implementation plan.

## Tests (any OS)

```
tests/run.sh
```

Needs `lua` and `python3`. Set `VS_PYTHON` to a Python with VapourSynth installed to also run the real filter-graph
test (the GPU part is stubbed). Covers the fps math, auto step-down, overlay, mpv wiring against a stub mpv, the
frame-hold logic and the filter graph.

## Contributing

Issues with an overlay screenshot and `tween.log` are the most useful thing you can send. Pull requests: keep
`tests/run.sh` green, and if you change `ladder.json` re-run `bench.py` and mention the numbers.

## Licenses

Tween's own code is MIT (see `LICENSE`). The installer bundles third-party software under its own terms:
mpv (GPL-2.0+/LGPL-2.1+), VapourSynth (LGPL-2.1), vs-mlrt (GPL-3.0) with NVIDIA TensorRT and CUDA runtime
libraries (NVIDIA EULA, redistributable), the RIFE models (MIT, from the vs-mlrt model releases), uosc (LGPL-3.0),
yt-dlp (Unlicense). Streaming a site's content is subject to that site's terms.
