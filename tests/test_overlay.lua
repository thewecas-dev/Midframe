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
    level_label = "RIFE 4.26 full", backend = "TensorRT", auto_level = 1, auto_total = 7,
    drops = 0, delayed = 0, vram_mb = 2310, seek_ms = 420,
    hist = { real_fps = { 60, 59 }, drops = { 0, 1 }, vram = { 2300, 2310 } },
})
assert(out:find("→ target 60.000", 1, true), out)
assert(out:find("level 1/7", 1, true), out)
assert(out:find("seek 420 ms", 1, true), out)
assert(out:find("\\p1", 1, true), "has graphs")

-- missing values render as "?" instead of crashing
out = overlay.render({ hist = { real_fps = {}, drops = {}, vram = {} } })
assert(out:find("VRAM ? MB", 1, true), out)

print("test_overlay ok")
