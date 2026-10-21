-- Loads main.lua against a recording stub of mpv's Lua API.
local function eq(a, b, msg) assert(a == b, (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a)) end

local function make_env(files)
    local E = { cmds = {}, async = {}, osd = {}, events = {}, observers = {}, bindings = {}, messages = {}, props = {} }
    local function json(v)
        if type(v) == "table" then
            local keys = {}
            for k in pairs(v) do keys[#keys + 1] = k end
            table.sort(keys)
            local parts = {}
            for _, k in ipairs(keys) do parts[#parts + 1] = string.format("%q:%s", k, json(v[k])) end
            return "{" .. table.concat(parts, ",") .. "}"
        elseif type(v) == "string" then return string.format("%q", v)
        elseif type(v) == "number" and v == math.floor(v) then return string.format("%d", v) end
        return tostring(v)
    end
    local timer = { kill = function() end, resume = function() end }
    local mp = {
        command_native = function(c) if c[1] == "expand-path" then return (c[2]:gsub("^~~/", "portable_config/")) end end,
        command_native_async = function(c, cb) E.async[#E.async + 1] = { cmd = c, cb = cb } end,
        commandv = function(...) E.cmds[#E.cmds + 1] = table.concat({ ... }, " ") end,
        osd_message = function(t) E.osd[#E.osd + 1] = t end,
        get_property_number = function(p, def) local v = E.props[p]; if v == nil then return def end return v end,
        get_property_native = function(p) return E.props[p] end,
        get_property_bool = function(p) return E.props[p] end,
        get_property = function(p) return E.props[p] end,
        get_time = function() return 0 end,
        register_event = function(n, f) E.events[n] = f end,
        observe_property = function(n, _, f) E.observers[n] = f end,
        add_periodic_timer = function() return timer end,
        add_timeout = function() return timer end,
        add_key_binding = function(_, n, f) E.bindings[n] = f end,
        register_script_message = function(n, f) E.messages[n] = f end,
        enable_messages = function() end,
        create_osd_overlay = function() return { update = function() end, remove = function() end } end,
    }
    package.loaded["mp"] = mp
    package.loaded["mp.utils"] = {
        file_info = function(p) return files[p] end,
        format_json = json,
        parse_json = function() return { {}, {}, {}, {} } end,  -- 4-step ladder
    }
    package.loaded["mp.msg"] = { info = function() end, warn = function() end, error = function() end }
    package.loaded["mp.options"] = { read_options = function() end }
    package.loaded["mp.input"] = { select = function() end, get = function() end, terminate = function() end }
    package.loaded["main"] = nil
    dofile("portable_config/scripts/framegen/main.lua")
    return E
end

local VP = { w = 1920, h = 1080, colormatrix = "bt.709", colorlevels = "limited" }

-- test_engines_missing_plays_plain
local E = make_env({})
E.props["container-fps"] = 23.976
E.props["display-fps"] = 144
E.observers["video-params"]("video-params", VP)
for _, c in ipairs(E.cmds) do assert(not c:find("^vf add"), "no filter before engines exist: " .. c) end
eq(#E.async, 1, "one engine build started")
assert(E.osd[1]:find("Preparing"), E.osd[1])
E.observers["video-params"]("video-params", VP)  -- same file again: no second build
eq(#E.async, 1, "build not restarted")

-- test_apply_quotes_user_data
E = make_env({ ["portable_config/engines/READY"] = { is_file = true } })
E.props["container-fps"] = 23.976
E.props["display-fps"] = 144
E.observers["video-params"]("video-params", VP)
local vf = E.cmds[#E.cmds]
assert(vf:find("^vf add @framegen:vapoursynth=file=%%%d+%%"), vf)
local n, js = vf:match("user%-data=%%(%d+)%%(.*)$")
eq(tonumber(n), #js, "user-data length prefix")
assert(js:find('"num":48000') and js:find('"den":1001') and js:find('"level":1'), js)
assert(js:find('"matrix":"709"') and js:find('"range":"limited"'), js)

-- test_set_fps_message
E.messages["set-fps"]("60")
vf = E.cmds[#E.cmds]
assert(vf:find('"num":60,') and vf:find('"den":1,'), vf)

-- test_failure_disables
E.events["log-message"]({ prefix = "vapoursynth", level = "error", text = "TensorRT: out of memory\n" })
eq(E.cmds[#E.cmds], "vf remove @framegen", "filter removed")
assert(E.osd[#E.osd]:find("Interpolation turned off: TensorRT: out of memory"), E.osd[#E.osd])
local before = #E.cmds
E.events["log-message"]({ prefix = "vapoursynth", level = "error", text = "again" })
eq(#E.cmds, before, "no repeat after disable")

-- test_hdr_matrix
E = make_env({ ["portable_config/engines/READY"] = { is_file = true } })
E.props["container-fps"] = 24
E.observers["video-params"]("video-params", { w = 3840, h = 2160, colormatrix = "bt.2020-ncl", colorlevels = "limited" })
assert(E.cmds[#E.cmds]:find('"matrix":"2020ncl"'), E.cmds[#E.cmds])

print("test_main ok")
