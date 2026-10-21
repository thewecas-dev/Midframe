local auto = require "auto"

local function eq(a, b, msg) assert(a == b, (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a)) end

-- test_fps_steps
local s = auto.fps_steps(144, 1, 24, 1)
eq(#s, 3, "144 from 24"); eq(s[1].num, 144); eq(s[2].num, 60); eq(s[3].num, 48)
s = auto.fps_steps(60, 1, 24, 1)
eq(#s, 2, "60 from 24"); eq(s[2].num, 48)
s = auto.fps_steps(48, 1, 24, 1)
eq(#s, 1, "2x only")

-- test_levels
local lv = auto.levels(4, auto.fps_steps(144, 1, 24, 1))
eq(#lv, 7, "4 rife + 2 fps + off"); assert(lv[7].off); eq(lv[5].rife, 4); eq(lv[5].fps, 2)

local W = auto.WARMUP
local GOOD = function(c) return { drops = 0, delayed = 0, vf_fps = 60, target = 60 } end
local function feed(st, t0, t1, sample, acts)
    for t = t0, t1 do
        local a = auto.tick(st, sample(t), t)
        if a then acts[#acts + 1] = { t = t, a = a } end
    end
    return acts
end
local SLOW = function() return { drops = 0, delayed = 0, vf_fps = 40, target = 60 } end

-- test_ignores_warmup
local st = auto.new(lv, 0)
local acts = feed(st, 0, W - 1, SLOW, {})
eq(#acts, 0, "warmup")

-- test_steps_down_after_3_bad
st = auto.new(lv, 0)
acts = feed(st, W, W + 3, SLOW, {})
eq(#acts, 1, "one down"); eq(acts[1].a, "down"); eq(st.level, 2)

local drops = 0
local DROPPY = function() drops = drops + 3; return { drops = drops, delayed = 0, vf_fps = 60, target = 60 } end
st = auto.new(lv, 0)
acts = feed(st, W, W + 3, DROPPY, {})
eq(#acts, 1, "3+ drops/s count as bad")
local d1 = 0
local ONE_DROP = function() d1 = d1 + 1; return { drops = d1, delayed = 0, vf_fps = 60, target = 60 } end
st = auto.new(lv, 0)
eq(#feed(st, W, W + 10, ONE_DROP, {}), 0, "1 drop/s is tolerated")

st = auto.new(lv, 0)
local seq = { [W + 1] = SLOW, [W + 2] = SLOW, [W + 3] = GOOD, [W + 4] = SLOW, [W + 5] = SLOW }
acts = feed(st, W, W + 5, function(t) return (seq[t] or GOOD)() end, {})
eq(#acts, 0, "non-consecutive bad")

-- test_never_steps_up: a level that failed is blocked; calm playback never triggers a reload
st = auto.new(lv, 0)
acts = feed(st, W, W + 3, SLOW, {})
eq(st.level, 2); assert(st.blocked[1], "failed level blocked")
eq(#feed(st, W + 4, W + 400, GOOD, {}), 0, "no step up, ever")

-- test_off_is_terminal
st = auto.new(lv, 0); st.level = 7
acts = feed(st, W, 100, SLOW, {})
eq(#acts, 0, "off terminal")

-- test_rife_per_s: interpolated frames per second
eq(auto.rife_per_s(48000, 1001, 24000, 1001), 48000 / 1001 / 2, "2x: half the output")
eq(auto.rife_per_s(60, 1, 24, 1), 48, "2.5x: 60 out, 12 land on source")
eq(auto.rife_per_s(60, 1, 30, 1), 30, "30 -> 60")

-- test_start_level: the user's measured RTX 4050 numbers (dynamic engines) as the 1080p reference
local ref = { 42.6, 26.1, 105.0, 120.9 }
local l, known = auto.start_level({}, ref, 1920, 1080, 1920, 1080, 24, 4)
eq(l, 3, "1080p 24->48 starts at 4.6 half"); eq(known, false, "estimated from reference")
eq(auto.start_level({}, ref, 1920, 1080, 1280, 720, 24, 4), 1, "720p 24->48 fits level 1")
eq(auto.start_level({}, ref, 1920, 1080, 3840, 2160, 30, 4), 4, "4K: nothing fits, fastest level")
l, known = auto.start_level({ [1] = 70 }, ref, 1920, 1080, 1920, 1080, 24, 4)
eq(l, 1, "exact measurement wins"); eq(known, true)
eq(auto.start_level({ [2] = 40 }, {}, nil, nil, 1920, 1080, 24, 4), 2, "only level: use it even if slow")
eq(auto.start_level({}, {}, nil, nil, 1920, 1080, 24, 4), 4, "no data at all: fastest level")

-- test_new_blocks_slower_levels
st = auto.new(lv, 0, 3)
eq(st.level, 3); assert(st.blocked[1] and st.blocked[2] and not st.blocked[3], "above start blocked")
eq(#feed(st, W, W + 120, GOOD, {}), 0, "never steps up into known-slow levels")

print("test_auto ok")
