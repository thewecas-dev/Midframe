local overlay = require "overlay"

local function eq(a, b, msg) assert(a == b, (msg or "") .. ":\nexpected " .. tostring(b) .. "\n     got " .. tostring(a)) end

-- graph is a filled area: baseline-left, the samples, baseline-right
eq(overlay.graph({ 0, 10 }, 0, 0, 100, 50, 10), "m 0 50 l 0 50 l 100 0 l 100 50", "two samples")
eq(overlay.graph({ 5 }, 0, 0, 100, 50, 10), "", "one sample")
eq(overlay.graph({}, 0, 0, 100, 50, 10), "", "empty")
eq(overlay.graph({ 0, 99 }, 0, 0, 100, 50, 10), "m 0 50 l 0 50 l 100 0 l 100 50", "clamped")
eq(overlay.graph({ 0, 5 }, 0, 0, 100, 50, 0), "m 0 50 l 0 50 l 100 50 l 100 50", "vmax 0 safe")

local out = overlay.render({
    src_res = "1920×1080", src_fps = 24000 / 1001, target_fps = 60, real_fps = 59.8, display_fps = 144,
    measured_display_fps = 48.8, res_w = 1280,
    level_label = "RIFE 4.26 full", backend = "TensorRT", auto_level = 1, auto_total = 7,
    drops = 0, delayed = 0, vram_mb = 2310, seek_ms = 420, gpu_mhz = 600, gpu_max_mhz = 3105, gpu_pstate = "P5",
    hist = { real_fps = { 60, 59 }, drops = { 0, 1 }, vram = { 2300, 2310 } },
})
assert(out:find("GPU clock 600 / 3105 MHz · P5  ← power-saving", 1, true), out)
assert(out:find("→ target 60.000", 1, true), out)
assert(out:find("display 144 Hz (measured 48.8)", 1, true), out)
assert(out:find("level 1/7", 1, true), out)
assert(out:find("seek 420 ms", 1, true), out)
assert(out:find("\\p1", 1, true), "has graphs")
assert(out:find("\\pos(934,10)", 1, true), "text starts at the right-hand panel: " .. out:sub(1, 200))

-- missing values render as "?" instead of crashing
out = overlay.render({ hist = { real_fps = {}, drops = {}, vram = {} } })
assert(out:find("VRAM ? MB", 1, true), out)

-- rounded rect starts after the top-left corner and closes back on it
local r = overlay.rrect(0, 0, 100, 40, 10)
assert(r:sub(1, 6) == "m 10 0", r)
assert(r:find("b 0 0 0 0 10 0$"), r)
eq(overlay.rrect(0, 0, 10, 10, 50):sub(1, 5), "m 5 0", "radius clamped to half size")

-- toast centres on screen and carries the message
local t = overlay.toast(1000, "Frame rate: 23.976 → 60 fps", "info")
assert(t:find("Frame rate: 23.976 → 60 fps", 1, true), t)
local x = tonumber(t:match("m (%d+) 24"))
assert(x and x > 300 and x < 500, "toast x " .. tostring(x))

-- idle screen: buttons are clickable, side by side, inside the window
local ass, boxes = overlay.idle(1440, 810, "ready")
assert(ass:find("Drop a video here", 1, true) and ass:find("RIFE ready", 1, true), ass)
assert(overlay.hit(boxes.open, (boxes.open[1] + boxes.open[3]) / 2, (boxes.open[2] + boxes.open[4]) / 2), "open hit")
assert(not overlay.hit(boxes.open, boxes.paste[1] + 5, boxes.paste[2] + 5), "boxes don't overlap")
assert(boxes.open[3] < boxes.paste[1], "open left of paste")
assert(not overlay.hit(nil, 1, 1), "nil box")
assert(select(1, overlay.idle(1440, 810, "building")):find("Preparing RIFE", 1, true))

-- control characters are dropped and long messages are cut to fit
t = overlay.toast(600, "line\r", "bad")
assert(not t:find("\r", 1, true), "no CR")
t = overlay.toast(600, string.rep("x", 400), "bad")
assert(#t < 1200 and t:find("…", 1, true), "truncated")

print("test_overlay ok")
