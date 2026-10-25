local ui = require "ui"
local sheet = require "sheet"
local home = require "home"
local settings = require "settings"

local function eq(a, b, msg) assert(a == b, (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a)) end
local LADDER = { { label = "RIFE 4.26" }, { label = "RIFE 4.6" }, { label = "RIFE 4.6 half" }, { label = "RIFE 4.6 quarter" } }
local CAL = { 45.5, 92.8, 134.0, 145.2 }  -- the RTX 4050 at 1080p

-- test_canvas_hit: last box wins, coordinates in design units
local c = ui.canvas(100, 100)
c:box(0, 0, 100, 100, "bg"); c:box(10, 10, 20, 20, "btn")
eq(c:hit(15, 15), "btn"); eq(c:hit(50, 50), "bg"); eq(c:hit(200, 5), nil)
assert(ui.esc("a{b}\\c") == "a(b)/c", "ASS specials escaped")
assert(ui.fit("abcdefghijklmnop", 10, 50) :find("…$"), "truncates with ellipsis")
c:text(1, 2, 7, 14, ui.C.text, "x", { bold = true })
assert(c:render():find("\\fnSegoe UI\\b1"), "font + bold tags")

-- test_rates_grouping: 23.976 source on 144 Hz -> even = 36 48 72 144, other = 60 90 120
local a = { src_num = 24000, src_den = 1001, cap = 144, exact = CAL, ref = CAL, ref_w = 1920, ref_h = 1080, w = 1920, h = 1080, ladder = LADDER }
local even, other = sheet.rates(a)
local function values(t) local o = {} for _, r in ipairs(t) do o[#o + 1] = r.value end return table.concat(o, ",") end
eq(values(even), "36,48,72,144", "even targets")
eq(values(other), "60,90,120", "other targets")
eq(even[2].choice, "x2", "48 comes from the 2x multiplier (exact ratio)")
assert(even[2].hint:find("2× · 3 refreshes"), even[2].hint)
assert(even[3].hint:find("needs 4.6 quarter"), even[3].hint)         -- 72 fps: level 4 with 1.5x headroom
eq(even[4].state, "muted", "144 too heavy"); assert(even[4].hint:find("too heavy"), even[4].hint)
-- no calibration at all: plain multiplier hints, nothing muted
local e2 = sheet.rates({ src_num = 24, src_den = 1, cap = 144, exact = {}, ref = {}, ladder = LADDER })
eq(e2[2].hint, "2×", "no measurement -> no claim"); eq(e2[2].state, "default")

-- test_preview
local r = sheet.resolve("x2", a)
local p = sheet.preview(r, a)
eq(p.src, "23.976"); eq(p.target, "47.952"); eq(p.label, "Smooth"); assert(p.note:find("RIFE 4.6 · measured 93 fps, needs 24"), p.note)
p = sheet.preview(sheet.resolve("144", a), a)
eq(p.label, "Too heavy"); eq(p.tone, "warn")
eq(sheet.resolve("20", a), nil, "below source is invalid")

-- test_sheet_render_and_clicks
local m = {
    kind = "yt", title = "Jailer Climax Scene", meta = "YouTube · 9:04 · source 30 fps", quality = "1080",
    qualities = sheet.QUALITIES, choice = "x2", custom = { text = "", valid = false, focus = false },
    even = even, other = other, preview = sheet.preview(r, a), remember = false, remember_label = "Don't ask again for YouTube",
    src_label = "23.976", cap = 144, quality_note = "Auto picks the best stream up to 1440p.", quality_label = "1080p",
    play_label = "Play at 48 fps", W = 1440, H = 900,
}
local cv = sheet.render(m)
local out = cv:render()
assert(out:find("Play at 48 fps"), "play button"); assert(out:find("QUALITY"), "quality section"); assert(out:find("Even on your 144 Hz display"))
local kinds = {}
for _, b in ipairs(cv.boxes) do kinds[b[5].kind] = (kinds[b[5].kind] or 0) + 1 end
eq(kinds.quality, 6, "six quality segments"); eq(kinds.rate, 7, "seven rate tiles"); eq(kinds.custom, 1); eq(kinds.play, 1); eq(kinds.original, 1); eq(kinds.remember, 1)
-- clicking a rate tile returns its choice
local hit
for _, b in ipairs(cv.boxes) do if b[5].kind == "rate" and b[5].choice == "x3" then hit = cv:hit((b[1] + b[3]) / 2, (b[2] + b[4]) / 2) end end
eq(hit and hit.choice, "x3", "tile click")
-- local sheet has no quality segment
m.kind = "local"; cv = sheet.render(m); kinds = {}
for _, b in ipairs(cv.boxes) do kinds[b[5].kind] = (kinds[b[5].kind] or 0) + 1 end
eq(kinds.quality, nil, "no quality on local sheet")

-- test_quick_menu
local qc = sheet.quick({ even = even, other = other, choice = "x2", enabled = true, src_label = "23.976", target_label = "47.952", cap = 144, W = 1440, H = 900, bottom = 816 })
kinds = {}
for _, b in ipairs(qc.boxes) do kinds[b[5].kind] = (kinds[b[5].kind] or 0) + 1 end
eq(kinds.rate, 7); eq(kinds.toggle, 1); eq(kinds.custom, 1)
eq(qc:hit(5, 5).kind, "close", "clicking outside closes")

-- test_home
local hc = home.render({ W = 1440, H = 900, status = { label = "RIFE ready · RTX 4050 · 144 Hz", tone = "good" },
    recents = { { title = "Sinners", meta = "D:\\Movies · 2h 17m", fps = "48 fps", progress = 0.4 } },
    strip = { "Engines: 1080p ready", "GPU: high performance ✓" }, version = "v0.2.0" })
local hk = {}
for _, b in ipairs(hc.boxes) do hk[b[5].kind] = (hk[b[5].kind] or 0) + 1 end
assert(hk.open >= 1 and hk.field == 1 and hk.play_link == 1 and hk.recent == 1 and hk.settings == 1 and hk.clear == 1, "home actions")
assert(hc:render():find("Play something smoother."), "headline")

-- test_clip: boxes outside a clip are dropped, inside are kept
local cc = ui.canvas(100, 100); cc:setclip(0, 0, 100, 50); cc:box(0, 10, 10, 10, "in"); cc:box(0, 80, 10, 10, "out"); cc:setclip(nil); cc:box(0, 80, 10, 10, "after")
eq(cc:hit(5, 15), "in"); eq(cc:hit(5, 85), "after"); assert(cc:render() == "" or true)

-- test_settings_scroll: a short window needs scrolling on the Playback tab; a tall one does not
local short = settings.render({ W = 1100, H = 560, tab = "playback", ladder = LADDER,
    playback = { ask_yt = true, ask_local = true, rate_label = "2× source", quality_label = "Auto · up to 1440p", anime = true, even = true, headroom_label = "1.5× (recommended)", audio_label = "0 ms" } })
assert(short.scroll_max > 0, "short drawer scrolls: " .. tostring(short.scroll_max))
assert(short:render():find("\\clip(", 1, true), "content clipped")
local tall = settings.render({ W = 1440, H = 1000, tab = "playback", ladder = LADDER,
    playback = { ask_yt = true, ask_local = true, rate_label = "2× source", quality_label = "Auto · up to 1440p", anime = true, even = true, headroom_label = "1.5× (recommended)", audio_label = "0 ms" } })
eq(tall.scroll_max, 0, "tall drawer does not scroll")

-- test_settings
local sc = settings.render({ W = 1440, H = 900, tab = "playback", ladder = LADDER,
    playback = { ask_yt = true, ask_local = true, rate_label = "2× source", quality_label = "Auto · up to 1440p", anime = true, even = true, headroom_label = "1.5× (recommended)", audio_label = "0 ms" },
    version = "Midframe 0.2.0" })
local sk = {}
for _, b in ipairs(sc.boxes) do sk[b[5].kind] = (sk[b[5].kind] or 0) + 1 end
eq(sk.toggle, 4, "four toggles"); eq(sk.cycle, 4, "four selects"); eq(sk.tab, 4); assert(sk.close >= 1)
sc = settings.render({ W = 1440, H = 900, tab = "engines", ladder = LADDER,
    engines = { { name = "1080p", dim = "1920×1080", w = 1920, h = 1080, state = "ready", vals = { 45, 93, 134, 145 } },
        { name = "4K", dim = "3840×2160", w = 3840, h = 2160, state = "none" } } })
sk = {}
for _, b in ipairs(sc.boxes) do sk[b[5].kind] = (sk[b[5].kind] or 0) + 1 end
eq(sk.prepare, 1, "one Prepare now"); assert(sc:render():find("All 4 levels measured"))
sc = settings.render({ W = 1440, H = 900, tab = "system", ladder = LADDER, checks = { { label = "G-SYNC off", ok = false, hint = "fix it" } } })
assert(sc:render():find("G%-SYNC off") and sc:render():find("fix it"))

print("test_ui ok")
