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

## Product

9. **Update check** against the latest GitHub release, one-line toast.
10. **Taskbar icon**: stamp ours onto mpv.exe at build time.
11. **First-run checklist screen** for the Windows settings (GPU high performance, G-SYNC off, fixed refresh).

## Verification still owed on the RTX 4050 laptop

- UI v2 end to end (sheet, quick menu, settings, native file dialog, YouTube track switching).
- 1440p and 4K sources, real anime (holds and cuts), crash relaunch.
