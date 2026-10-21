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

-- test_steps_up_after_stable
st = auto.new(lv, 0); st.level = 2
acts = feed(st, W, W + 40, GOOD, {})
eq(acts[1] and acts[1].a, "up", "up after stable"); eq(st.level, 1)

-- test_blocks_after_failed_up
st = auto.new(lv, 0); st.level = 2
acts = feed(st, W, W + 40, GOOD, {})          -- goes up to 1 around t=33
local up_t = acts[1].t
acts = feed(st, up_t + 1, up_t + auto.FAIL_WINDOW, SLOW, {})  -- fails right after stepping up
eq(acts[1].a, "down"); eq(st.level, 2); assert(st.blocked[1], "level 1 blocked")
assert(auto.FAIL_WINDOW > auto.WARMUP + auto.BAD_TICKS, "a failed step-up must be detectable")
acts = feed(st, up_t + auto.FAIL_WINDOW + 1, up_t + 200, GOOD, {})
eq(#acts, 0, "never retries a blocked level")

-- test_off_is_terminal
st = auto.new(lv, 0); st.level = 7
acts = feed(st, W, 100, SLOW, {})
eq(#acts, 0, "off terminal")

print("test_auto ok")
