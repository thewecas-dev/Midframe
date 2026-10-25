# Midframe TODO

Ranked roughly by how much you'd feel it while watching. Nothing here is started unless marked.

## Playback smoothness

1. **Seamless level changes and faster seeks.** Every auto step-down and every seek reloads the VapourSynth filter
   (1–2 s freeze). Plan: load all ladder levels once per video and switch levels inside the running script through a
   small control file, so auto mode never stalls; pre-write the half/quarter-scale model files and cache the Python
   import so the unavoidable reload after a seek drops well under a second.
2. **Frame cache / look-ahead queue** (idea, 2026-10-25). Spend ~3 s at start (and after seeks) filling a queue of
   interpolated frames before playback begins, keep generating while paused, so resuming has a deep buffer and
   transient GPU hiccups never reach the screen.
   Constraints to work through before building:
   - mpv's `vapoursynth` filter already pipelines `buffered-frames × concurrent-frames` frames; a 3 s queue at 72 fps
     is ~220 frames of 1080p 10-bit (~1.3 GB in RAM), so the depth must be bounded by memory, not time.
   - mpv pulls frames from the filter only while playing; filling during pause needs the queue outside mpv's pull
     loop (a VapourSynth-side ring buffer that keeps requesting frames, or our own filter).
   - Seeks flush everything; the fill time becomes seek latency unless playback starts from a shallow queue and
     deepens in the background.
   - Audio/video sync must come from pts, not queue position, so the queue can't change timing, only absorb jitter.
3. **Smart Auto quality.** "Auto" = up to 1440p today. Pick the highest quality whose calibrated speed still holds
   the chosen frame rate (the sheet already computes this per tile).
4. **HDR handling.** Tone-map to SDR before RIFE, or pass HDR metadata through and let mpv tone-map after. Needs one
   HDR test clip.
5. **Background engine builds while idle.** Build 1440p and 4K engines when the home screen has been idle for a while.

## Watching flow

6. **Play the next episode.** On end-of-file, offer / auto-play the next file in the folder with the same frame-rate
   choice, no sheet.
7. **Keyboard polish in the sheet and quick menu.** Arrows move between tiles, Tab switches sections, digits pick
   quality.
8. **Recents with thumbnails** (mpv `overlay-add` can show a saved PNG per entry).

## Distribution (measured on the 0.2.0 package: 3.9 GB installed, 3.1 GB download in two slices)

9. **Trim the build.** Delete from `build\app` before packaging: TensorRT builder resources for sm90 and sm100
   (700 MB, datacenter-only GPUs), the TensorRT-RTX runtime + parser + `vstrt_rtx.dll` (195 MB, we use classic
   TensorRT), and every model we never load (dpir 498 MB, waifu2x 90, cugan 85, RealESRGAN 7, old RIFE versions
   ~170 MB; keep `rife/rife_v4.26`, `rife_v2/rife_v4.26`, `rife/rife_v4.6` and the half/quarter rewrites). Also
   mpv's `doc`, `installer`, `updater.bat`, `mpv-register.bat`. Expected: ~2.1 GB installed, ~1.7 GB download, one
   slice. Verify by building a 1080p engine from the trimmed tree on the RTX 4050 (sm89) before shipping.
10. **Download the GPU runtime at install time.** The setup carries only mpv, VapourSynth, Python and our config
    (~150 MB). An Inno Setup download page (`CreateDownloadPage` / `DownloadTemporaryFile`, Inno 6.1+) fetches
    `midframe-runtime-<vsmlrt tag>.7z` (the trimmed set from 9, hosted in a separate "runtime" release of this
    repo so upstream retags can't break installs), checks its SHA-256, and a bundled `7za.exe` extracts it to
    `vs-runtime\vs-plugins`. App releases then stay ~150 MB; the runtime release only changes when vs-mlrt or
    TensorRT is bumped. In-app: an Engines-tab "Repair runtime" button that re-downloads when `vstrt.dll` or the
    models are missing, so an interrupted install is recoverable without reinstalling. Installer-side rather than
    in-app so the player never starts without its filter chain.
11. **Update check** against the latest GitHub release, one-line toast.
12. **First-run checklist screen** for the Windows settings (GPU high performance, G-SYNC off, fixed refresh).

## From the Reddit thread (2026-10-25)

- **RIFE model choice** (asked for 4.25 heavy v2 to compare with SVP): in progress — optional "RIFE 4.25 heavy"
  level at the top of the ladder, a "Best RIFE model" setting, calibration files versioned so existing ones keep
  working. Heavy is 2–3× slower than 4.26, so it is built only when picked.
- **Anime4K**: in progress — the fast A/B/C shader chains bundled under `portable_config\shaders`, a Picture
  setting; runs as mpv GLSL shaders after RIFE, so it never touches the filter.
- **Linux / AMD**: skipped for now. Linux-NVIDIA is plausible (mpv, VapourSynth and vs-mlrt all exist there; our
  Windows-only bits are the file dialog, Explorer, launcher and rcedit) but needs a machine to test on. AMD needs
  ROCm MIGraphX or the much slower ncnn Vulkan backend. Open to a contributor PR.
- **"DLSS for video"**: not a thing we can call. The driver-level equivalent is RTX Video Super Resolution; in mpv
  it is `vf=d3d11vpp:scale=…:scaling-mode=nvidia` and needs frames as D3D11 surfaces, which our software filter
  path doesn't produce. Document it as unsupported unless a cheap upload path turns up.

## Verification still owed on the RTX 4050 laptop

- UI v2 end to end (sheet, quick menu, settings, native file dialog, YouTube track switching).
- 1440p and 4K sources, real anime (holds and cuts), crash relaunch.
