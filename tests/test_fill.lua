local fill = require "fill"
local function eq(a, b, msg) assert(a == b, (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a)) end
local function near(a, b, msg) assert(math.abs(a - b) < 0.01, (msg or "") .. ": expected ~" .. b .. ", got " .. tostring(a)) end

-- synthetic 1920x1080 bgr0 frame: grey picture with black bars (top/bottom 140 px, left/right 0)
local function frame(w, h, top, bottom, left, right, lum)
    local rows = {}
    local black = string.rep(string.char(0, 0, 0, 0), w)
    local pix = string.char(lum, lum, lum, 0)
    local line = string.rep(string.char(0, 0, 0, 0), left) .. string.rep(pix, w - left - right) .. string.rep(string.char(0, 0, 0, 0), right)
    for y = 0, h - 1 do rows[#rows + 1] = (y < top or y >= h - bottom) and black or line end
    return table.concat(rows)
end
local W, H = 1920, 1080
local c = fill.detect(frame(W, H, 140, 140, 0, 0, 90), W, H, W * 4)
assert(c, "bars found")
eq(c.y, 140, "top bar"); eq(c.h, 800, "picture height"); eq(c.x, 0); eq(c.w, 1920)
eq(fill.detect(frame(W, H, 0, 0, 0, 0, 90), W, H, W * 4), nil, "no bars -> nil")
eq(fill.detect(frame(W, H, 8, 8, 0, 0, 90), W, H, W * 4), nil, "hairline bars ignored")
eq(fill.detect(frame(W, H, 0, 0, 0, 0, 10), W, H, W * 4), nil, "all-dark frame -> no info")
c = fill.detect(frame(W, H, 0, 0, 240, 240, 60), W, H, W * 4)
eq(c.x, 240, "pillarbox left"); eq(c.w, 1440, "pillarbox width")
eq(fill.detect(frame(W, H, 300, 40, 0, 0, 60), W, H, W * 4), nil, "uneven dark areas are scene content")
eq(fill.detect(frame(W, H, 100, 100, 200, 200, 60), W, H, W * 4), nil, "dark on both axes is a scene, not bars")
c = fill.detect(frame(W, H, 150, 130, 0, 0, 60), W, H, W * 4)
eq(c.y, 130, "slightly uneven bars -> symmetric crop by the smaller bar"); eq(c.h, 820)
-- merge keeps the larger picture area
local m = fill.merge({ x = 0, y = 140, w = 1920, h = 800 }, { x = 0, y = 100, w = 1920, h = 880 })
eq(m.y, 100); eq(m.h, 880); eq(m.x, 0); eq(m.w, 1920)

-- params: 2.40:1 picture (1920x800) on a 16:9 window
local p = fill.params(1920, 800, 1920, 1080, "fit", 0.5)
eq(p.bars, "top-bottom"); near(p.ratio, 1.35); eq(p.zoom, 0); eq(p.scale_y, 1)
p = fill.params(1920, 800, 1920, 1080, "zoom", 0.5)
near(2 ^ p.zoom, 1.35, "zoom fills height"); eq(p.scale_y, 1)
p = fill.params(1920, 800, 1920, 1080, "stretch", 0.5)
eq(p.zoom, 0); near(p.scale_y, 1.35, "stretch fills height"); eq(p.scale_x, 1)
p = fill.params(1920, 800, 1920, 1080, "fill", 0.5)
near(2 ^ p.zoom, math.sqrt(1.35), "half zoom"); near(p.scale_y, math.sqrt(1.35), "half stretch")
near((2 ^ p.zoom) * p.scale_y, 1.35, "zoom x stretch covers the bars exactly")
-- 4:3 on 16:9: bars left/right, stretch on x
p = fill.params(1440, 1080, 1920, 1080, "fill", 0.5)
eq(p.bars, "left-right"); near(p.scale_x, math.sqrt(4 / 3)); eq(p.scale_y, 1)
-- matching aspect: nothing to do
p = fill.params(1920, 1080, 1920, 1080, "fill", 0.5)
eq(p.bars, "none"); eq(p.zoom, 0)
assert(fill.describe("fill", 0.5, fill.params(1920, 800, 1920, 1080, "fill", 0.5), { w = 1920, h = 800 }):find("Fill 50% · crop 1920×800 · zoom 1.16× · stretch 1.16×", 1, true))
eq(fill.describe("fit", 0.5, nil, nil), "Fit")
local mc = fill.manual_crop(1920, 1080, 2.39)
eq(mc.h, 802, "2.39 crop height"); eq(mc.y, 138); eq(mc.w, 1920)
eq(fill.manual_crop(1920, 1080, 16 / 9), nil, "same aspect: nothing to crop")
mc = fill.manual_crop(1920, 1080, 4 / 3)
eq(mc.w, 1440, "narrower aspect crops the sides"); eq(mc.x, 240)
p = fill.params(1920, 800, 1920, 1080, "manual", 0.5, { zoom = 1.2, stretch = 1.1 })
near(2 ^ p.zoom, 1.2, "manual zoom"); near(p.scale_y, 1.1, "manual stretch on the bars axis"); eq(p.scale_x, 1)
p = fill.params(1920, 1080, 1920, 1080, "manual", 0.5, { zoom = 1.2, stretch = 0.9 })
near(2 ^ p.zoom, 1.2, "manual works without bars too"); near(p.scale_y, 0.9)
assert(fill.describe("manual", 0.5, p, nil):find("Manual · zoom 1.20× · stretch 0.90×", 1, true), fill.describe("manual", 0.5, p, nil))
print("test_fill ok")
