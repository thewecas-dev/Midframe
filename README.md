<p align="center"><img src="packaging/banner.png" alt="Midframe" width="800"></p>
<p align="center"><strong>Watch 24 fps films at 144. Watch 30 fps YouTube at 60.</strong><br>
A Windows video player that generates the missing frames in real time, on your NVIDIA GPU.</p>

<p align="center">
<a href="#why-midframe-exists">Why</a> ·
<a href="#install">Install</a> ·
<a href="#features">Features</a> ·
<a href="#use">Use</a> ·
<a href="#troubleshooting">Troubleshooting</a> ·
<a href="#build-from-source">Build</a>
</p>

---

Films are shot at 24 frames per second. Your monitor can show 144. Midframe fills the gap: every frame in between
is generated live by [RIFE](https://github.com/hzwer/ECCV2022-RIFE), an AI interpolation model, running on TensorRT
while you watch. No downloading, no re-encoding, no waiting. Open a file or paste a YouTube link and press play.

## Why Midframe exists

Smooth, interpolated playback on Windows has mostly meant one thing: SVP, a mature and capable product, but a
paid one. The free tools around it work differently. Flowframes, RIFE-App and friends are converters: you hand
them a file, wait, and get a new, larger file back. That's ideal for archiving, but it doesn't help with the video you
want to watch right now, or with a YouTube link.

Midframe fills that gap. It's a free, open-source player that interpolates on demand, while you watch, for local
files and streams alike. Nothing is written to disk and there's nothing to wait for. If you have an RTX card and a
high-refresh display, this is the missing piece.

Tested on an RTX 4050 Laptop (6 GB): 1080p at 2× and 3× and YouTube 1080p 30→60 play with **zero dropped frames**.

## Features

- **Real-time AI interpolation.** RIFE 4.26 and 4.6 on NVIDIA TensorRT. Pick 1.5×, 2×, 2.5×, 3×, a fixed 60/90/120/144, or type your own.
- **Local files and YouTube.** Drag a file in, or press Ctrl+V with a link on the clipboard. Quality from 480p to 2160p via yt-dlp.
- **Never stutters.** Every engine is benchmarked once on *your* GPU. If a video is too heavy, Midframe steps down a quality level instead of dropping frames.
- **Anime-aware.** Held drawings stay held and scene cuts are never blended. Turn it off for live action if you prefer.
- **Nothing to tune.** Engines build themselves in the background. Levels pick themselves. You answer two questions per video, or none.
- **Crash recovery.** If the player ever dies, it reopens the same file at the same second.
- **Debug overlay.** One key shows level, drops, GPU clock, measured refresh rate and live graphs.
- **Built on the best.** [mpv](https://mpv.io), [VapourSynth](https://www.vapoursynth.com), [vs-mlrt](https://github.com/AmusementClub/vs-mlrt), [uosc](https://github.com/tomasklaen/uosc), [yt-dlp](https://github.com/yt-dlp/yt-dlp). Free and MIT licensed.

## Requirements

| | |
|---|---|
| **OS** | Windows 10 or 11, 64-bit |
| **GPU** | NVIDIA RTX 20-series or newer with a current Game Ready or Studio driver. Integrated and AMD GPUs are not supported (RIFE runs on CUDA/TensorRT). |
| **VRAM** | 4 GB for 1080p, 6 GB recommended for 1440p and 4K |
| **Disk** | About 6 GB for the install, plus 1–2 GB of generated engines |
| **Display** | Any. A 120/144 Hz panel is where it shines. |

## Install

**1. Download.** Get the setup from the [latest release](https://github.com/thewecas-dev/Midframe/releases/latest).
It comes as `Midframe-Setup` plus several `.bin` slices; keep them all in one folder. Every push to `main` also
builds one on GitHub Actions, downloadable from the workflow run as an artifact.

**2. Run the setup.** It installs to `%LOCALAPPDATA%\Midframe`. No admin rights needed.

**3. Fix three Windows settings.** These make or break smooth playback. Do them once.

| Setting | Where | Why |
|---|---|---|
| GPU → **High performance** | Settings → System → Display → Graphics → *Add desktop app* → `%LOCALAPPDATA%\Midframe\mpv.exe` → Options | Otherwise the GPU idles at a few hundred MHz during playback |
| **G-SYNC off** | NVIDIA Control Panel → *Set up G-SYNC* → untick *Enable G-SYNC* (or at least for windowed mode) | Variable refresh rate fights mpv's frame pacing |
| **Fixed refresh rate** | Settings → System → Display → Advanced display → set 144 Hz, not *Dynamic* | Same reason |

**4. Launch and wait once.** Start Midframe from the Start menu. The first launch builds and benchmarks the RIFE engines
for 1080p in the background (10–20 minutes, one time only). The start screen says **RIFE ready** when it's done.
Keep a laptop plugged in while it runs.

That's it. Open a file.

## Use

**Home.** Midframe opens on a start screen: drop a video on it, click **Open file…** (the normal Windows dialog),
or paste a link into the field. Recent videos sit on the right and resume where you stopped. The strip at the bottom
shows engine and system state at a glance.

**Before each video** one setup sheet appears: for YouTube, the qualities that stream actually has and the frame-rate
tiles; for local files, the frame-rate tiles alone. Tiles are grouped into rates that divide your display refresh
evenly and the rest, each with a hint from your GPU's calibration ("2× · 3 refreshes", "needs 4.6 quarter",
"too heavy"). A strip underneath previews the result: `23.976 → 47.952 fps · RIFE 4.6 · plays smoothly`.
Enter plays, Esc keeps the defaults, **Custom** takes a typed value, and "Don't ask again" remembers your answer per kind.

| Key | Action |
|---|---|
| **Ctrl+O** | Open a file (Windows file dialog) |
| **Ctrl+V** | Play the link or file path on the clipboard |
| **F** | Frame-rate quick menu (same tiles, plus custom and the interpolation toggle) |
| **Ctrl+,** | Settings: ask/don't ask, defaults, anime mode, headroom, audio offset, engines per resolution, system check |
| **D** | Debug overlay |
| **Shift+I** | mpv's own stats page |

The bottom bar has a quality pill (opens the sheet again), the frame-rate button with the current target, subtitles,
debug, settings and fullscreen.

**Pick a target that divides your refresh rate.** On a 144 Hz display: 2× (48) or 3× (72) for films, 2× (60) for
30 fps video. 60 fps on 144 Hz is an uneven 2.4 refreshes per frame and looks worse than 48. The sheet marks the even ones.

**New resolutions build one more engine.** The first 720p, 1440p or 4K video plays at its original rate for a few
minutes while the engine builds, then interpolation switches on by itself. Settings → Engines can build them ahead of time.

**Anime** is handled faithfully by default (Settings → Faithful anime mode).

## How it picks a level

Every engine is measured once on your GPU (`portable_config\engines\cal_<w>x<h>.json`). A video starts at the best
level whose measured speed covers the frames it needs with 50% headroom. The ladder, best quality first:

> RIFE 4.26 → RIFE 4.6 → RIFE 4.6 half scale → RIFE 4.6 quarter scale → lower target fps → original fps

During playback it only ever steps down (a level change reloads the filter, a 1–2 s pause), and a level that failed
stays blocked until the next file. If the filter itself fails (driver, VRAM) the video keeps playing at its
original rate and a notice says why.

## Troubleshooting

Press **D** first. The overlay answers most questions:

| Overlay shows | Meaning | Fix |
|---|---|---|
| `GPU clock 600 / 3105 MHz · P5` | GPU parked in power saving | Windows Graphics setting → High performance (see Install) |
| `display 144 Hz (measured 48.3)` | variable refresh rate active | Turn off G-SYNC, set a fixed refresh rate |
| `preparing RIFE 4.6…` in the status line | an engine is being built | Wait. Original fps meanwhile |
| "Interpolation turned off: …" notice | filter error | See `portable_config\midframe-error.log` |
| "RIFE setup failed" | engine build error | See `portable_config\engines\build-error.log`. Usually a driver or CUDA problem; `nvidia-smi` must work |

For anything else, start `mpv.exe --log-file=midframe.log` from the install folder, reproduce, and attach the log
and an overlay screenshot to an issue.

To benchmark the pipeline outside mpv (prints raw RIFE and full-filter fps per level and records the calibration;
run only while Midframe is closed):

```
vs-runtime\python.exe portable_config\vs\bench.py [width height]
```

## Build from source

On Windows, with [7-Zip](https://www.7-zip.org) and [Inno Setup 6](https://jrsoftware.org/isinfo.php) on PATH
and about 10 GB free:

```powershell
powershell -ExecutionPolicy Bypass -File packaging\build.ps1
```

It downloads pinned versions of mpv, VapourSynth, vs-mlrt with the TensorRT runtime, the RIFE models, uosc and
yt-dlp, adds this repo's `portable_config`, and produces the setup plus `.bin` slices in `dist\`. The same script
runs in `.github/workflows/build.yml`. The icon is drawn by `packaging\make_icon.py` (Pillow).

Layout:

- `portable_config/scripts/midframe/` — the mpv Lua side: prompts, menus, auto mode, overlay, engine builds.
- `portable_config/vs/` — the VapourSynth side: `mf_vs.py` builds the filter graph, `build_engines.py` measures
  levels, `ladder.json` defines them.
- `packaging/` — build script, launcher with crash recovery, installer, icon.

## Tests (any OS)

```
tests/run.sh
```

Needs `lua` and `python3`. Set `VS_PYTHON` to a Python with VapourSynth installed to also run the real filter-graph
test (the GPU part is stubbed). Covers the fps math, auto step-down, overlay, mpv wiring against a stub mpv, the
frame-hold logic and the filter graph.

## Contributing

Issues with an overlay screenshot and `midframe.log` are the most useful thing you can send. Pull requests: keep
`tests/run.sh` green, and if you change `ladder.json` re-run `bench.py` and mention the numbers.

## Licenses

Midframe's own code is MIT (see `LICENSE`). The installer bundles third-party software under its own terms:
mpv (GPL-2.0+/LGPL-2.1+), VapourSynth (LGPL-2.1), vs-mlrt (GPL-3.0) with NVIDIA TensorRT and CUDA runtime
libraries (NVIDIA EULA, redistributable), the RIFE models (MIT, from the vs-mlrt model releases), uosc (LGPL-3.0),
yt-dlp (Unlicense). Streaming a site's content is subject to that site's terms.
