# FrameGen: Real-Time RIFE Video Player for Windows (Design)

Date: 2026-10-21

## Intent

A free Windows desktop video player that plays **local video files** and
**YouTube links (streamed, never downloaded)**. While it plays, it uses the
**RIFE** AI model to create in-between frames in real time, so a 24/30fps
video plays at 60, 90, 120fps or any higher rate the user picks.

**Why:** The user tried SVP. It's paid and was unreliable: it stuttered,
crashed and had trouble seeking. FrameGen exists to give the same smoothness
**reliably**. Reliability matters more than peak interpolation quality.

## Target user & hardware

- One user (the author), on a Windows laptop with an **NVIDIA RTX 4050
  Laptop GPU (6 GB VRAM)**.
- Content: movies (often 24fps), YouTube videos and anime, usually at
  **1080p or 1440p**, and 4K when available.
- Development happens on macOS. All GPU/RIFE testing happens on the user's
  Windows laptop.

## Goals

1. Play local files (any format mpv supports) and YouTube URLs, streamed
   with no file saved to disk.
2. Interpolate frames with RIFE in real time.
3. **FPS picker** with:
   - multipliers of the source fps: **1.5×, 2×, 2.5×, 3×**
   - fixed targets: **60, 90, 120, 144**
   - a custom value box.

   Before the user applies a choice, the picker previews the result, e.g.
   "24 → 60 fps". Changes apply during playback, without restarting the video.
4. **Quality picker:** wherever the source offers several qualities
   (YouTube, other streams), the user can pick one, e.g. 2160p/1440p/1080p/720p.
   It also has an **Auto** option that picks the highest quality the laptop
   can interpolate smoothly. A source with only one quality has no picker.
5. **Auto performance mode:** measures real RIFE throughput on this laptop.
   When playback can't keep up, it steps down in this order:
   1. lighter RIFE model / lower internal RIFE scale (e.g. 1.0 → 0.5 → 0.25)
   2. lower target fps
   3. interpolation off (plays the original fps), with a small on-screen
      notice.
6. **Anime-safe interpolation**, on by default:
   - **scene-cut detection:** no blending across hard cuts
   - **duplicate-frame handling:** anime held on 2s/3s must not warp or
     "melt".
7. **Debug mode** (toggled by a hotkey and a menu item, off by default): a
   **minimal, semi-transparent overlay** for testing. It shows:
   - source vs output: resolution, source fps, target fps, real delivered fps
   - RIFE details: model, backend (TensorRT/Vulkan), internal scale, current
     auto-mode step
   - live **graphs**: frame time per frame (ms), real output fps over time,
     RIFE inference time per frame, dropped/late frames, GPU VRAM use
   - counters: frames generated vs original, frames dropped, current
     stream/codec.

   It must be small and stay out of the way (e.g. a corner panel). When
   off, it costs nothing.
8. Packaged as a single **Windows installer**. Free, no license.

## Hard requirements (anti-goals: failure even if interpolation looks great)

- **No stutter.** Smoothness beats quality. Never drop into choppy
  playback: step down (Goal 5) instead.
- **No crashes.** If RIFE fails (VRAM out of memory, TensorRT error, driver
  problem), turn interpolation off, keep playing and show what happened.
  The player itself must not die because of the interpolation path.
- **Seeking must work.** After a seek, playback resumes as fast as it
  would without interpolation. RIFE restarts from the new position. No
  freezes, no audio/video drift after seeking.
- Audio stays in sync at all times.

## Non-goals

- A browser version. It was dropped because web pages can't read YouTube
  frames.
- Exporting or re-encoding interpolated video to files.
- Libraries, playlists, accounts or other media-center features.
- macOS/Linux builds.
- Supporting non-NVIDIA GPUs well. The Vulkan backend may work as a
  fallback, but it isn't a target.

## How it's built (decided)

These are Claude's recommendations; the user accepted the overall
direction (Windows app, RIFE):

- **Playback engine: mpv (libmpv).** It handles decoding, audio sync,
  seeking, subtitles, formats and the rendering/display timing.
- **YouTube: yt-dlp**, through mpv's built-in yt-dlp integration. It
  streams with no download, and the format list feeds the quality picker.
- **Interpolation: RIFE 4.x inside mpv through VapourSynth** (mpv's
  `vapoursynth` video filter).
  - Primary backend: **TensorRT** (NVIDIA RTX 4050).
  - Fallback backend: **ncnn-Vulkan**.
  - Non-integer ratios (e.g. 24→60) use RIFE 4.x arbitrary timesteps.

## Calls made by Claude (user to check)

- **Seek/fps-change warm-up:** after a seek or an fps change, it's fine to
  play a few hundred ms at the original fps while RIFE warms back up. That
  meets "resumes as fast as without interpolation". So mpv's built-in
  `vapoursynth` filter is acceptable, and no custom always-running pipeline
  is needed.
- **Stream quality is never changed mid-play by auto mode.** Auto quality
  picks once, at load. The step-down ladder only touches RIFE settings,
  target fps and on/off. A manual quality change reloads the stream at the
  current position.
- **Display: one 144Hz laptop panel (user confirmed).** The target fps is
  capped at the display refresh rate, so the 144 preset is the max. If an
  external monitor is connected later, cap at that monitor's refresh rate.
- **Anime held frames: keep the holds (user chose "faithful").** Repeated
  drawings stay held. RIFE only generates frames between distinct drawings
  where there's real motion, never across a hold or a scene cut.
- **HDR:** tone-map to SDR before RIFE. HDR passthrough is a later
  improvement.

## Left to the builder

- GUI toolkit and the language for the app shell around libmpv.
- Exact RIFE model versions and their order in the step-down ladder.
- Thresholds and timing for auto mode (when to step down, when to try
  stepping back up).
- How scene-cut and duplicate-frame detection are implemented.
- Debug overlay layout, graph styling and the hotkey.
- How bundled dependencies (Python/VapourSynth runtime, TensorRT engines,
  yt-dlp) are packaged and updated. Includes whether TensorRT engines are
  built on first run, and showing progress if they are.
- Keeping yt-dlp up to date, since YouTube changes often.

## Expected performance on RTX 4050 Laptop (estimates, to verify)

| Source | Target | Expectation |
|---|---|---|
| 1080p | 60fps | Smooth with lighter RIFE 4.x models |
| 1080p | 90–120fps | Borderline; likely needs internal scale 0.5 |
| 1440p | 60fps | Likely OK at scale 0.5 |
| 4K | 60fps | At the edge; lightest model and lowest scale, may fall back to original fps |

The laptop must be on mains power: on battery the GPU slows down a lot.
