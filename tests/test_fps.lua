local fps = require "fps"

local function eq(a, b, msg) assert(a == b, (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a)) end

-- test_snap_fps
local n, d = fps.snap(23.976); eq(n, 24000, "23.976 num"); eq(d, 1001, "23.976 den")
n, d = fps.snap(29.97); eq(n, 30000); eq(d, 1001)
n, d = fps.snap(59.94); eq(n, 60000); eq(d, 1001)
n, d = fps.snap(25); eq(n, 25); eq(d, 1)
n, d = fps.snap(24); eq(n, 24); eq(d, 1)
eq(fps.snap(0), nil, "zero"); eq(fps.snap(0/0), nil, "nan"); eq(fps.snap(nil), nil, "nil")

-- test_cap
eq(fps.cap(143.98), 144); eq(fps.cap(nil), 144); eq(fps.cap(0), 144); eq(fps.cap(0/0), 144); eq(fps.cap(60), 60)

-- test_options
local function choices(opts) local t = {} for _, o in ipairs(opts) do t[#t + 1] = o.choice end return table.concat(t, ",") end
local o = fps.options(24000, 1001, 144)
eq(choices(o), "x1.5,x2,x2.5,x3,60,90,120,144", "ntsc film")
eq(o[2].label, "2× (23.976 → 47.952 fps)", "mult label")
eq(o[5].label, "60 fps", "fixed label")
eq(o[3].num, 60000); eq(o[3].den, 1001)
eq(choices(fps.options(60, 1, 144)), "x1.5,x2,90,120,144", "60fps source")
eq(choices(fps.options(24, 1, 60)), "x1.5,x2,x2.5,60", "60Hz cap")

-- test_resolve_custom
n, d = fps.resolve("x2.5", 24000, 1001, 144); eq(n, 60000); eq(d, 1001)
n, d = fps.resolve("60", 24000, 1001, 144); eq(n, 60); eq(d, 1)
n, d = fps.resolve("75", 24, 1, 144); eq(n, 75); eq(d, 1)
local err
n, err = fps.resolve("abc", 24, 1, 144); eq(n, nil); assert(err:find("number"), err)
n, err = fps.resolve("20", 24, 1, 144); eq(n, nil); assert(err:find("above"), err)
n, err = fps.resolve("200", 24, 1, 144); eq(n, nil); assert(err:find("at most"), err)
n, err = fps.resolve("x9", 24, 1, 144); eq(n, nil)

print("test_fps ok")
