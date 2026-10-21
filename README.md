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

- The quality menu is the stream-quality button in the bottom bar (YouTube only).
- On first launch, FrameGen builds the RIFE TensorRT engines in the background, which takes several minutes. Video plays normally until they're ready.
- Keep the laptop plugged in.

## Build the installer (on Windows)

1. Install 7-Zip and Inno Setup 6, and make sure `7z.exe` and `iscc.exe` are on PATH.
2. From the repo root, run `powershell -ExecutionPolicy Bypass -File packaging\build.ps1`.
3. The output is `dist\FrameGen-Setup.exe`, plus `.bin` slices. Keep them together.

## Tests (any OS)

`tests/run.sh` needs `lua` and `python3`. It covers the fps math, auto step-down, overlay, mpv wiring (with a stub mpv) and the frame-hold logic.
The GPU path can only be tested on Windows, using the checklist below.

## Windows acceptance checklist (RTX 4050, plugged in)

Turn on the debug overlay (D) for each check.

- [ ] 1080p 24fps file at 2×: real ≈ 47.9, 0 drops over 60s.
- [ ] 1080p YouTube at 60: smooth, and the quality menu switches stream. Nothing is saved except `portable_config\engines`.
- [ ] Seek 10 times: `seek` stays under 1000 ms each time, and audio stays in sync.
- [ ] Anime clip: no melting at scene cuts, and held drawings stay held.
- [ ] 4K at 144: auto steps down with no visible stutter, and ends on a notice if it has to.
- [ ] Rename `portable_config\engines` while playing, then seek: an "Interpolation turned off" notice appears and playback continues.
- [ ] End `mpv.exe` in Task Manager: FrameGen reopens at the same spot with interpolation off.

If something fails, the mpv log helps. Start `mpv.exe --log-file=fg.log` from the install folder and reproduce the problem.
