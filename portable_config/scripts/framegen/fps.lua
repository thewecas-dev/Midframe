-- FPS math: parse container fps, list the menu choices, resolve a choice to a rational target.
local M = {}

local MULTS = { { "x1.5", 3, 2, "1.5" }, { "x2", 2, 1, "2" }, { "x2.5", 5, 2, "2.5" }, { "x3", 3, 1, "3" } }
local FIXED = { 60, 90, 120, 144 }
local EPS = 1e-6

local function valid(f) return type(f) == "number" and f == f and f > 0 and f < math.huge end

local function near_int(x)
    local k = math.floor(x + 0.5)
    return math.abs(x - k) < 0.01, k
end

local function gcd(a, b)
    while b ~= 0 do a, b = b, a % b end
    return a
end

local function reduce(n, d)
    local g = gcd(n, d)
    return math.floor(n / g), math.floor(d / g)
end

local function fmt(v)
    if math.abs(v - math.floor(v + 0.5)) < 0.0005 then return string.format("%d", math.floor(v + 0.5)) end
    return string.format("%.3f", v)
end
M.fmt = fmt

-- 23.976 -> 24000/1001, 25 -> 25/1, nil for 0/NaN/nil.
function M.snap(f)
    if not valid(f) then return nil end
    local ok, k = near_int(f)
    if ok then return k, 1 end
    ok, k = near_int(f * 1.001)
    if ok then return k * 1000, 1001 end
    return math.floor(f * 1000 + 0.5), 1000
end

function M.cap(display_fps)
    if not valid(display_fps) then return 144 end
    return math.floor(display_fps + 0.5)
end

local function allowed(t, src, cap) return t > src + EPS and t <= cap + EPS end

function M.options(src_num, src_den, cap)
    local src, out = src_num / src_den, {}
    for _, m in ipairs(MULTS) do
        local n, d = reduce(src_num * m[2], src_den * m[3])
        if allowed(n / d, src, cap) then
            out[#out + 1] = { choice = m[1], num = n, den = d,
                label = string.format("%s× (%s → %s fps)", m[4], fmt(src), fmt(n / d)) }
        end
    end
    for _, v in ipairs(FIXED) do
        if allowed(v, src, cap) then
            out[#out + 1] = { choice = tostring(v), num = v, den = 1, label = v .. " fps" }
        end
    end
    return out
end

-- choice: "x2" style multiplier or a number string (preset or user-typed custom value).
function M.resolve(choice, src_num, src_den, cap)
    local src, n, d = src_num / src_den, nil, nil
    for _, m in ipairs(MULTS) do
        if m[1] == choice then n, d = reduce(src_num * m[2], src_den * m[3]) end
    end
    if not n then
        if type(choice) == "string" and choice:sub(1, 1) == "x" then return nil, "unknown multiplier " .. choice end
        n, d = M.snap(tonumber(choice))
        if not n then return nil, "not a number: " .. tostring(choice) end
    end
    local t = n / d
    if t <= src + EPS then return nil, "must be above source fps (" .. fmt(src) .. ")" end
    if t > cap + EPS then return nil, "must be at most " .. cap .. " (display refresh)" end
    return n, d
end

return M
