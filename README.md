# FrameGen

A Windows video player (mpv + uosc) that interpolates frames in real time with RIFE through TensorRT.
It plays local files and YouTube links (streamed, never downloaded) at 1.5×/2×/2.5×/3× or 60/90/120/144 fps.

Design: `docs/specs/2026-10-21-framegen-design.md` · Plan: `docs/plans/2026-10-21-framegen.md`

## Use

| Key | Action |
|---|---|
| Ctrl+O | Open a file (or drag one onto the window) |
| Ctrl+V | Play a YouTube/URL from the clipboard |
| F | Frame-rate menu: presets, Custom…, interpolation on/off |
| D | Debug overlay: source vs output, auto level, drops, VRAM, seek time, graphs |

- Before each video starts, FrameGen asks the **frame rate**; for YouTube it first asks the **quality**
  (Auto / 2160p / 1440p / 1080p / 720p / 480p). Enter accepts the highlighted (last used) answer, Esc keeps it.
  Turn the prompts off with `ask=no` in `portable_config\script-opts\framegen.conf`.
- The quality can also be changed during playback from the stream-quality button in the bottom bar.
- **First launch:** FrameGen builds and measures the RIFE engines for 1080p in the background (10–20 min,
  one time). Videos play at their original fps until the start screen says "RIFE ready".
- **First video at a new size** (720p, 1440p, 4K…): one more engine is built for that size (a few minutes),
  while the video plays at its original fps. Engines are kept in `portable_config\engines`.
- Keep the laptop plugged in, and stop Windows from parking the GPU during playback (the debug overlay's
  "GPU clock" line shows a few hundred MHz and P5 when it does, and frames drop even on the lightest level):
  1. Settings → System → Display → Graphics → Add desktop app → `mpv.exe` from the install folder → Options → **High performance**.
  2. NVIDIA Control Panel → Manage 3D settings → Program Settings → add `mpv.exe` → **Power management mode: Prefer maximum performance**.
  3. Windows power mode (Settings → System → Power) set to **Best performance** while watching.

## How a level is picked

Each engine is measured once on your GPU (`engines\cal_<w>x<h>.json`). A video starts at the best RIFE level
whose measured speed covers the frames it needs with 20% headroom; auto mode never tries levels already known
to be too slow. During playback it only ever steps down (each level change reloads the filter, a 1–2 s stall),
and a level that failed stays blocked until the next file. On a 144 Hz panel, prefer 2× (48) and 3× (72) for
24 fps sources: 60 fps needs an uneven 2.4 refreshes per frame. Ladder (best quality first): RIFE 4.26 → RIFE 4.6 → RIFE 4.6 half scale → RIFE 4.6 quarter.

## Build the installer (on Windows)

1. Install 7-Zip and Inno Setup 6, and make sure `7z.exe` and `iscc.exe` are on PATH.
2. From the repo root, run `powershell -ExecutionPolicy Bypass -File packaging\build.ps1`.
3. The output is `dist\FrameGen-Setup.exe`, plus `.bin` slices. Keep them together.

## Tests (any OS)

`tests/run.sh` needs `lua` and `python3` (set `VS_PYTHON` to a Python with VapourSynth to also run the filter test).
It covers the fps math, auto step-down, overlay, mpv wiring with prompts and build queue (against a stub mpv),
the frame-hold logic and the filter graph itself (with a stand-in for the GPU part of RIFE).
The GPU path can only be tested on Windows: `vs-runtime\python.exe portable_config\vs\bench.py [w h]`
prints raw RIFE and full-filter speed per level and records the calibration. Run it only while FrameGen is
closed or idle with "RIFE ready" shown: two engine builds on one GPU slow each other down badly.

## Windows acceptance checklist (RTX 4050, plugged in)

Turn on the debug overlay (D) for each check.

- [ ] First launch: start screen shows "Preparing RIFE…", later "RIFE ready"; `engines\cal_1920x1080.json` has 4 numbers.
- [ ] 1080p 24fps file at 2×: starts at the level `bench.py` says keeps up, real ≈ 47.9, drops flat over 60s.
- [ ] 1080p YouTube: quality prompt, then frame-rate prompt, then smooth playback; the quality button switches stream.
- [ ] Seek 10 times: `seek` stays under 1500 ms each time, and audio stays in sync.
- [ ] Anime clip: no melting at scene cuts, and held drawings stay held.
- [ ] 4K at 144: starts at the fastest level, auto steps down with no visible stutter, ends on a notice if it has to.
- [ ] Rename `portable_config\engines` while playing, then seek: an "Interpolation turned off" notice appears and playback continues.
- [ ] End `mpv.exe` in Task Manager: FrameGen reopens at the same spot with interpolation off and no prompts.

If something fails: `portable_config\framegen-error.log` (filter errors), `portable_config\engines\build-error.log`
(engine builds), or start `mpv.exe --log-file=fg.log` from the install folder and reproduce the problem.
