local overlay = require "overlay"

local function eq(a, b, msg) assert(a == b, (msg or "") .. ":\nexpected " .. tostring(b) .. "\n     got " .. tostring(a)) end

-- graph is a filled area: baseline-left, the samples, baseline-right
eq(overlay.graph({ 0, 10 }, 0, 0, 100, 50, 10), "m 0 50 l 0 50 l 100 0 l 100 50", "two samples")
eq(overlay.graph({ 5 }, 0, 0, 100, 50, 10), "", "one sample")
eq(overlay.graph({}, 0, 0, 100, 50, 10), "", "empty")
eq(overlay.graph({ 0, 99 }, 0, 0, 100, 50, 10), "m 0 50 l 0 50 l 100 0 l 100 50", "clamped")
eq(overlay.graph({ 0, 5 }, 0, 0, 100, 50, 0), "m 0 50 l 0 50 l 100 50 l 100 50", "vmax 0 safe")

local out = overlay.render({
    src_res = "1920×1080", src_fps = 24000 / 1001, target_fps = 48, real_fps = 47.8, display_fps = 144,
    measured_display_fps = 48.8, res_w = 1440, res_h = 900,
    level_label = "RIFE 4.26", backend = "TensorRT", auto_level = 1, auto_total = 7,
    drops = 0, delayed = 0, vram_mb = 2310, seek_ms = 420, gpu_mhz = 600, gpu_max_mhz = 3105, gpu_pstate = "P5",
    hist = { real_fps = { 60, 59 }, drops = { 0, 1 }, vram = { 2300, 2310 } },
})
assert(out:find("600 / 3105 MHz · P5 · 2310 MB", 1, true), out)
assert(out:find("GPU parked in power saving", 1, true), "low clock warning")
assert(out:find("48.000 · real 47.8", 1, true), out)
assert(not overlay.render({ display_fps = 144, measured_display_fps = 76.7, target_fps = 72, hist = { real_fps = {}, drops = {}, vram = {} } }):find("variable refresh", 1, true), "a struggling GPU is not blamed on the display")
assert(out:find("144 Hz · measured 48.8", 1, true), out)
assert(out:find("variable refresh", 1, true), "VRR warning")
assert(out:find("1/7 · RIFE 4.26 · TensorRT", 1, true), out)
assert(out:find("seek 420 ms", 1, true), out)
assert(out:find("\\p1", 1, true), "has graphs")
assert(out:find("\\pos(1074,", 1, true), "panel text starts in the right-hand 360 px: " .. out:sub(1, 300))

-- missing values render as "?" instead of crashing
out = overlay.render({ hist = { real_fps = {}, drops = {}, vram = {} } })
assert(out:find("? / ? MHz", 1, true), out)

-- toast centres on screen and carries the message
local t = overlay.toast(1000, "Frame rate: 23.976 → 60 fps", "info")
assert(t:find("Frame rate: 23.976 → 60 fps", 1, true), t)
local x = tonumber(t:match("m (%d+)%.?%d* 84"))
assert(x and x > 300 and x < 500, "toast x " .. tostring(x))

-- control characters are dropped and long messages are cut to fit
t = overlay.toast(600, "line\r", "bad")
assert(not t:find("\r", 1, true), "no CR")
t = overlay.toast(600, string.rep("x", 400), "bad")
assert(t:find("…", 1, true), "truncated")

print("test_overlay ok")
