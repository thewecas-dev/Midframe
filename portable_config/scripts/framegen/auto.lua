-- Auto performance mode: step down when playback can't keep up, carefully step back up.
local M = {}

-- WARMUP covers the filter reload (TensorRT engine load) after any level change or seek, which
-- otherwise looks like slowness and makes auto mode step down for nothing.
M.WARMUP, M.BAD_TICKS, M.STABLE_UP = 8, 3, 30
-- A level that fails this soon after stepping up to it gets blocked; must exceed WARMUP + BAD_TICKS.
M.FAIL_WINDOW = M.WARMUP + M.BAD_TICKS + 4
M.DROP_TOL = 2  -- dropped frames per second tolerated before a tick counts as bad

-- Target fps fallbacks, highest first: target, 60, 2x source (each only if below target).
function M.fps_steps(tn, td, sn, sd)
    local target, src = tn / td, sn / sd
    local out = { { num = tn, den = td } }
    local function add(n, d)
        local v = n / d
        if v < target - 1e-6 and v > src + 1e-6 then
            for _, s in ipairs(out) do if math.abs(s.num / s.den - v) < 1e-6 then return end end
            out[#out + 1] = { num = n, den = d }
        end
    end
    add(60, 1)
    add(2 * sn, sd)
    table.sort(out, function(a, b) return a.num / a.den > b.num / b.den end)
    return out
end

function M.levels(rife_count, fps_steps)
    local out = {}
    for i = 1, rife_count do out[#out + 1] = { rife = i, fps = 1 } end
    for j = 2, #fps_steps do out[#out + 1] = { rife = rife_count, fps = j } end
    out[#out + 1] = { off = true }
    return out
end

local function changed(st, now)
    st.warm_until, st.good_since, st.bad, st.prev = now + M.WARMUP, now + M.WARMUP, 0, nil
end

-- After a seek the filter reloads; give it a fresh warm-up without changing level.
M.rewarm = changed

function M.new(levels, now)
    local st = { levels = levels, level = 1, blocked = {} }
    changed(st, now)
    return st
end

function M.tick(st, s, now)
    if st.levels[st.level].off or now < st.warm_until then return nil end
    local prev = st.prev
    st.prev = s
    if not prev then return nil end

    local bad = s.drops - prev.drops > M.DROP_TOL or s.delayed - prev.delayed > 2
        or (s.vf_fps ~= nil and s.vf_fps < 0.95 * s.target)
    if bad then
        st.bad, st.good_since = st.bad + 1, now
        if st.bad < M.BAD_TICKS then return nil end
        if st.up_level == st.level and now - st.up_time <= M.FAIL_WINDOW then st.blocked[st.level] = true end
        st.level = st.level + 1
        changed(st, now)
        return "down"
    end
    st.bad = 0
    if st.level > 1 and not st.blocked[st.level - 1] and now - st.good_since >= M.STABLE_UP then
        st.level = st.level - 1
        st.up_level, st.up_time = st.level, now
        changed(st, now)
        return "up"
    end
    return nil
end

return M
