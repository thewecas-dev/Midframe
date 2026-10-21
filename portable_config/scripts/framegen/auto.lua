-- Auto performance mode: step down when playback can't keep up (one way, per file).
local M = {}

-- WARMUP covers the filter reload (TensorRT engine load) after any level change or seek, which
-- otherwise looks like slowness and makes auto mode step down for nothing.
M.WARMUP, M.BAD_TICKS = 8, 3
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
    st.warm_until, st.bad, st.prev = now + M.WARMUP, 0, nil
end

-- After a seek the filter reloads; give it a fresh warm-up without changing level.
M.rewarm = changed

-- start: first level to try. Levels above it are blocked: calibration already showed they're too slow.
-- Auto mode only ever steps down, and blocks each level it leaves: every level change reloads the
-- filter, which stalls playback for 1-2 s, so trying to climb back costs more than it can gain.
function M.new(levels, now, start)
    local st = { levels = levels, level = start or 1, blocked = {} }
    for i = 1, st.level - 1 do st.blocked[i] = true end
    changed(st, now)
    return st
end

M.HEADROOM = 1.5  -- measured: the real pipeline (decode, mpv render, display) needs ~1.4x the bench speed; 1.2 was not enough at 72 fps

local function gcd(a, b)
    while b ~= 0 do a, b = b, a % b end
    return a
end

-- RIFE-generated frames per second for src -> target: output frames that don't land on a source frame.
function M.rife_per_s(tn, td, sn, sd)
    local p = (tn * sd) / gcd(tn * sd, td * sn)  -- numerator of the reduced target/src ratio
    return tn / td * (1 - 1 / p)
end

-- Pick the best (lowest index) RIFE level that keeps up, from calibration measured on this GPU.
--   exact: {level = out_fps_at_2x} measured at this frame size (may be partial or empty)
--   ref:   {level = out_fps_at_2x} measured at ref_w x ref_h (scaled by pixel count as an estimate)
-- Returns level, known (true when the pick comes from an exact measurement).
-- A level nothing is known about is skipped: a wrong guess costs a multi-second reload plus drops.
function M.start_level(exact, ref, ref_w, ref_h, w, h, need_per_s, total)
    local scale = (ref_w and ref_h) and (ref_w * ref_h) / (w * h) or nil
    local fallback
    for i = 1, total do
        local e = exact[i]
        if e then
            if e / 2 >= need_per_s * M.HEADROOM then return i, true end
            fallback = i
        elseif scale and ref[i] then
            if ref[i] / 2 * scale >= need_per_s * M.HEADROOM then return i, false end
            fallback = fallback or i
        end
    end
    -- Nothing keeps up: the fastest measured level, else the fastest in the ladder.
    local last
    for i = total, 1, -1 do if exact[i] or (scale and ref[i]) then last = i; break end end
    return last or total, exact[last or total] ~= nil
end

function M.tick(st, s, now)
    if st.levels[st.level].off or now < st.warm_until then return nil end
    local prev = st.prev
    st.prev = s
    if not prev then return nil end

    local bad = s.drops - prev.drops > M.DROP_TOL or s.delayed - prev.delayed > 2
        or (s.vf_fps ~= nil and s.vf_fps < 0.95 * s.target)
    if not bad then
        st.bad = 0
        return nil
    end
    st.bad = st.bad + 1
    if st.bad < M.BAD_TICKS then return nil end
    st.blocked[st.level] = true
    st.level = st.level + 1
    changed(st, now)
    return "down"
end

return M
