-- Loads main.lua against a recording stub of mpv's Lua API.
local function eq(a, b, msg) assert(a == b, (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a)) end

local ENGINES = "portable_config/engines"
local PREFS = "portable_config/midframe-prefs.json"
local UOSC = "portable_config/scripts/uosc/main.lua"

-- Minimal JSON decoder (objects, arrays, strings, numbers, true/false/null) for the stub.
local function decode(s)
    local i = 1
    local function ws() i = s:find("%S", i) or #s + 1 end
    local val
    local function str()
        local out = ""
        i = i + 1
        while true do
            local c = s:sub(i, i)
            if c == '"' then i = i + 1; return out end
            if c == "\\" then
                local n = s:sub(i + 1, i + 1)
                out = out .. (({ n = "\n", t = "\t" })[n] or n)
                i = i + 2
            else
                out = out .. c; i = i + 1
            end
        end
    end
    val = function()
        ws()
        local c = s:sub(i, i)
        if c == "{" then
            local t = {}
            i = i + 1; ws()
            if s:sub(i, i) == "}" then i = i + 1; return t end
            while true do
                ws(); local k = str(); ws(); i = i + 1  -- ':'
                t[k] = val(); ws()
                local d = s:sub(i, i); i = i + 1
                if d == "}" then return t end
            end
        elseif c == "[" then
            local t = {}
            i = i + 1; ws()
            if s:sub(i, i) == "]" then i = i + 1; return t end
            while true do
                t[#t + 1] = val(); ws()
                local d = s:sub(i, i); i = i + 1
                if d == "]" then return t end
            end
        elseif c == '"' then return str()
        elseif s:sub(i, i + 3) == "true" then i = i + 4; return true
        elseif s:sub(i, i + 4) == "false" then i = i + 5; return false
        elseif s:sub(i, i + 3) == "null" then i = i + 4; return nil
        else
            local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
            i = i + #num
            return tonumber(num)
        end
    end
    local ok, r = pcall(val)
    return ok and r or nil
end

local function json(v)
    if type(v) == "table" then
        if #v > 0 then
            local parts = {}
            for _, x in ipairs(v) do parts[#parts + 1] = json(x) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do parts[#parts + 1] = string.format('"%s":%s', k, json(v[k])) end
        return "{" .. table.concat(parts, ",") .. "}"
    elseif type(v) == "string" then return '"' .. v:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
    elseif type(v) == "number" and v == math.floor(v) then return string.format("%d", v) end
    return tostring(v)
end

local function write(path, content)
    local f = assert(io.open(path, "w"))
    f:write(content); f:close()
end
local function clean()
    os.execute("rm -rf " .. ENGINES .. " " .. PREFS)
end

-- opts.cal = { ["1920x1080"] = {42.6, 26.1, 105, 120.9} or {[3]=105} }, opts.uosc (default true)
local function make_env(opts)
    opts = opts or {}
    clean()
    os.execute("mkdir -p " .. ENGINES)
    for size, levels in pairs(opts.cal or {}) do
        local w, h = size:match("(%d+)x(%d+)")
        local lv = {}
        for k, v in pairs(levels) do lv[tostring(k)] = v end
        write(ENGINES .. "/cal_" .. w .. "x" .. h .. ".json", json({ w = tonumber(w), h = tonumber(h), levels = lv }))
    end
    local E = { cmds = {}, async = {}, osd = {}, events = {}, observers = {}, bindings = {}, messages = {},
        props = {}, forced = {}, set = {}, hooks = {}, timers = {} }
    local timer = { kill = function() end, resume = function() end }
    local mp = {
        command_native = function(c) if c[1] == "expand-path" then return (c[2]:gsub("^~~/", "portable_config/")) end end,
        command_native_async = function(c, cb) E.async[#E.async + 1] = { cmd = c, cb = cb } end,
        commandv = function(...) E.cmds[#E.cmds + 1] = table.concat({ ... }, " ") end,
        get_property_number = function(p, def) local v = E.props[p]; if v == nil then return def end return v end,
        get_property_native = function(p) return E.props[p] end,
        get_property_bool = function(p) return E.props[p] end,
        get_property = function(p) return E.props[p] end,
        set_property = function(p, v) E.set[p] = v end,
        set_property_native = function(p, v) E.set[p] = v end,
        get_script_name = function() return "midframe" end,
        get_time = function() return 0 end,
        register_event = function(n, f) E.events[n] = f end,
        observe_property = function(n, _, f) E.observers[n] = f end,
        add_hook = function(n, _, f) E.hooks[n] = f end,
        add_periodic_timer = function() return timer end,
        add_timeout = function(_, f) E.timers[#E.timers + 1] = f; return timer end,
        add_key_binding = function(_, n, f) E.bindings[n] = f end,
        add_forced_key_binding = function(_, n, f) E.forced[n] = f end,
        remove_key_binding = function(n) E.forced[n] = nil end,
        register_script_message = function(n, f) E.messages[n] = f end,
        enable_messages = function() end,
        create_osd_overlay = function()
            local ov = {}
            ov.update = function(self) E.osd[#E.osd + 1] = self.data end
            ov.remove = function() end
            return ov
        end,
    }
    package.loaded["mp"] = mp
    package.loaded["mp.utils"] = {
        file_info = function(p)
            if p == UOSC then return opts.uosc ~= false and { is_file = true } or nil end
            local f = io.open(p, "r")
            if f then f:close(); return { is_file = true } end
            return nil
        end,
        format_json = json,
        parse_json = decode,
    }
    package.loaded["mp.msg"] = { info = function() end, warn = function() end, error = function() end }
    package.loaded["mp.options"] = { read_options = function() end }
    package.loaded["mp.input"] = { select = function() end, get = function() end, terminate = function() end }
    dofile("portable_config/scripts/midframe/main.lua")
    return E
end

local VP = { w = 1920, h = 1080, colormatrix = "bt.709", colorlevels = "limited" }
local FULL = { 400, 300, 200, 100 }                -- a fast GPU: every level keeps up
local RTX4050 = { 42.6, 26.1, 105.0, 120.9 }       -- the user's measured numbers
local function last_vf(E)
    for i = #E.cmds, 1, -1 do if E.cmds[i]:find("^vf ") then return E.cmds[i] end end
end
local function last_osd(E) return E.osd[#E.osd] or "" end
local function last_cmd(E, pat)
    for i = #E.cmds, 1, -1 do if E.cmds[i]:find(pat) then return E.cmds[i] end end
end
local function play(E, vp, cfps)
    E.props["display-fps"] = 144
    E.props["container-fps"] = cfps
    E.props["video-params"] = vp
    E.observers["video-params"]()
end
local function build_args(E, i) return table.concat(E.async[i].cmd.args, " ", 3) end  -- drop python + script

-- test_first_launch_builds_reference: no calibration -> one build of every level at 1080p
local E = make_env({})
eq(#E.async, 1, "reference build started at launch")
eq(build_args(E, 1), ENGINES .. " 1920 1080", "all levels at the reference size")
play(E, VP, 23.976)
eq(last_vf(E), nil, "no filter while nothing is calibrated")
eq(#E.async, 1, "no second build while one runs")
E.props["idle-active"] = true; E.props["osd-dimensions"] = { w = 1440, h = 810 }
E.observers["idle-active"]()
assert(last_osd(E):find("Preparing RIFE", 1, true), "idle screen shows building")

-- test_no_interpolation_while_building: calibration written by bench.py mid-build must not start the
-- filter while the build still owns the GPU; when the build ends, the video is re-planned.
write(ENGINES .. "/cal_1920x1080.json", json({ w = 1920, h = 1080, levels = FULL }))
E.messages["set-fps"]("60")
eq(last_vf(E), nil, "no filter while the reference build runs")
assert(E.set["user-data/midframe/status"]:find("preparing RIFE", 1, true), E.set["user-data/midframe/status"])
E.async[1].cb(true, { status = 0 })
assert(last_vf(E) and last_vf(E):find('"num":60,'), "interpolation starts once the build is done")
assert(last_osd(E):find("RIFE ready", 1, true), last_osd(E))

-- test_apply_quotes_user_data
E = make_env({ cal = { ["1920x1080"] = FULL } })
eq(#E.async, 0, "calibrated: nothing to build")
play(E, VP, 23.976)
local vf = last_vf(E)
assert(vf:find("^vf add @midframe:vapoursynth=file=%%%d+%%"), vf)
local n, js = vf:match("user%-data=%%(%d+)%%(.*)$")
eq(tonumber(n), #js, "user-data length prefix")
assert(js:find('"num":48000') and js:find('"den":1001') and js:find('"level":1'), js)
assert(js:find('"matrix":"709"') and js:find('"range":"limited"'), js)
assert(vf:find("concurrent%-frames=8"), "8 frames in flight")

-- test_set_fps_message + prefs persisted
E.messages["set-fps"]("60")
vf = last_vf(E)
assert(vf:find('"num":60,') and vf:find('"den":1,'), vf)
assert(io.open(PREFS):read("*a"):find('"choice":"60"'), "last choice saved")

-- test_failure_disables
E.events["log-message"]({ prefix = "vapoursynth", level = "error", text = "TensorRT: out of memory\n" })
eq(last_vf(E), "vf remove @midframe", "filter removed")
assert(last_osd(E):find("Interpolation turned off: TensorRT: out of memory", 1, true), last_osd(E))
local before = #E.cmds
E.events["log-message"]({ prefix = "vapoursynth", level = "error", text = "again" })
eq(#E.cmds, before, "no repeat after disable")

-- test_hdr_matrix
E = make_env({ cal = { ["3840x2160"] = FULL, ["1920x1080"] = FULL } })
play(E, { w = 3840, h = 2160, colormatrix = "bt.2020-ncl", colorlevels = "limited" }, 24)
assert(last_vf(E):find('"matrix":"2020ncl"'), last_vf(E))

-- test_start_level_from_reference: 1080p on the RTX 4050 starts at 4.6 half
E = make_env({ cal = { ["1920x1080"] = RTX4050 } })
play(E, VP, 23.976)
assert(last_vf(E):find('"level":3'), "starts at level 3: " .. last_vf(E))
assert(last_cmd(E, "set%-button midframe_fps"):find('"badge":"48"'), "fps button shows 48")
eq(E.set["user-data/midframe/status"], "1920×1080 · 23.976 fps → 47.952 fps · RIFE 4.6 half", "status line")

-- test_new_size_builds_on_demand: 720p has no engines yet -> build the estimated level only, play plain
E = make_env({ cal = { ["1920x1080"] = RTX4050 } })
play(E, { w = 1280, h = 720, colormatrix = "bt.709", colorlevels = "limited" }, 23.976)
eq(last_vf(E), nil, "no filter without an engine")
eq(#E.async, 1, "one on-demand build")
eq(build_args(E, 1), ENGINES .. " 1280 720 1", "720p fits level 1 by estimate")
assert(last_osd(E):find("Preparing RIFE 4.26 for 1280×720", 1, true), last_osd(E))
assert(E.set["user-data/midframe/status"]:find("preparing RIFE 4.26", 1, true), E.set["user-data/midframe/status"])
write(ENGINES .. "/cal_1280x720.json", json({ w = 1280, h = 720, levels = { ["1"] = 90 } }))
E.async[1].cb(true, { status = 0 })
assert(last_vf(E) and last_vf(E):find('"level":1'), "filter added once the engine exists")

-- test_build_queue: a second size while one build runs waits its turn
E = make_env({ cal = { ["1920x1080"] = RTX4050 } })
play(E, { w = 1280, h = 720, colormatrix = "bt.709", colorlevels = "limited" }, 23.976)
play(E, { w = 2560, h = 1440, colormatrix = "bt.709", colorlevels = "limited" }, 23.976)
eq(#E.async, 1, "second build queued, not started")
write(ENGINES .. "/cal_1280x720.json", json({ w = 1280, h = 720, levels = { ["1"] = 90 } }))
E.async[1].cb(true, { status = 0 })
eq(#E.async, 2, "queued build starts after the first")
assert(build_args(E, 2):find("^" .. ENGINES .. " 2560 1440 %d$"), build_args(E, 2))

-- test_fps_menu: uosc menu with sections, active choice and toggle
E = make_env({ cal = { ["1920x1080"] = FULL } })
play(E, VP, 23.976)
E.bindings["fps-menu"]()
local menu = last_cmd(E, "open%-menu")
assert(menu and menu:find('"title":"Frame rate"'), menu)
assert(menu:find('"title":"Multiply"') and menu:find('"title":"Fixed"'), "sections")
assert(menu:find('"title":"Custom…"') and menu:find('"title":"Interpolation"'), "custom + toggle")
assert(menu:find('"active":true'), "current choice marked")
assert(not menu:find('"hint":"60 fps"', 1, true), "fixed items have no duplicate hint")
assert(menu:find('"hint":"RIFE 4.26"', 1, true), "toggle shows running model")

-- test_url_prompts: quality before yt-dlp, then frame rate once the fps is known
E = make_env({ cal = { ["1920x1080"] = FULL } })
local hook = { deferred = 0, continued = 0 }
function hook:defer() self.deferred = self.deferred + 1 end
function hook:cont() self.continued = self.continued + 1 end
E.props["path"] = "https://www.youtube.com/watch?v=abc"
E.props["display-fps"] = 144
E.hooks["on_load"](hook)
eq(hook.deferred, 1, "loading paused for the quality prompt")
menu = last_cmd(E, "open%-menu")
assert(menu:find('"title":"Video quality"') and menu:find('"title":"1080p"') and menu:find('"value":"q:1080"'), menu)
assert(menu:find('"callback":%["midframe","prompt%-event"%]'), "callback mode")
E.messages["prompt-event"]('{"type":"activate","value":"q:1080","index":4}')
eq(last_cmd(E, "close%-menu"), "script-message-to uosc close-menu midframe_prompt", "menu closed by us")
eq(hook.continued, 0, "waits for the close event")
E.messages["prompt-event"]('{"type":"close"}')
eq(hook.continued, 1, "loading continues")
eq(E.set["file-local-options/ytdl-format"], "bestvideo[height<=?1080]+bestaudio/best", "quality applied")
assert(io.open(PREFS):read("*a"):find('"quality":"1080"'), "quality remembered")
E.props["track-list"] = { { type = "audio" }, { type = "video", selected = true, ["demux-fps"] = 29.97 } }
E.hooks["on_preloaded"](hook)
eq(hook.deferred, 2, "loading paused for the frame-rate prompt")
menu = last_cmd(E, "open%-menu")
assert(menu:find('"title":"Frame rate for this video"') and menu:find('"value":"f:x2"'), menu)
assert(menu:find('"title":"Play original"') and menu:find('"value":"f:off"'), "play original offered")
assert(menu:find("Source 29.970 fps", 1, true), "footnote has the source fps")
E.messages["prompt-event"]('{"type":"activate","value":"f:60"}')
E.messages["prompt-event"]('{"type":"close"}')
eq(hook.continued, 2, "loading continues after the fps prompt")
play(E, VP, 29.97)
assert(last_vf(E):find('"num":60,'), "chosen fps used: " .. last_vf(E))
-- same URL reloaded right away (quality switch from uosc): no prompts again
E.events["end-file"]()
E.hooks["on_load"](hook); E.hooks["on_preloaded"](hook)
eq(hook.deferred, 2, "no re-prompt on reload")
-- the same URL opened again much later: ask again
local real_time = package.loaded["mp"].get_time
package.loaded["mp"].get_time = function() return 100 end
E.hooks["on_load"](hook)
eq(hook.deferred, 3, "re-prompt after a while")
package.loaded["mp"].get_time = real_time
E.messages["prompt-event"]('{"type":"close"}')

-- test_local_prompts_fps_only, and Escape keeps the previous choice
E = make_env({ cal = { ["1920x1080"] = FULL } })
hook = { deferred = 0, continued = 0 }
function hook:defer() self.deferred = self.deferred + 1 end
function hook:cont() self.continued = self.continued + 1 end
E.props["path"] = "D:\\movies\\film.mkv"
E.props["display-fps"] = 144
E.hooks["on_load"](hook)
eq(hook.deferred, 0, "no quality prompt for local files")
E.props["track-list"] = { { type = "video", ["demux-fps"] = 23.976 } }
E.hooks["on_preloaded"](hook)
eq(hook.deferred, 1, "frame-rate prompt")
E.messages["prompt-event"]('{"type":"close"}')  -- Escape
eq(hook.continued, 1, "continues on dismiss")
play(E, VP, 23.976)
assert(last_vf(E):find('"num":48000'), "default 2x kept: " .. last_vf(E))
-- "Play original" disables interpolation for this file
E.messages["prompt-event"]('{"type":"activate","value":"f:off"}')
eq(last_vf(E), "vf remove @midframe", "original playback")

-- test_prompt_timeout: an unanswered prompt continues loading
E = make_env({ cal = { ["1920x1080"] = FULL } })
hook = { deferred = 0, continued = 0 }
function hook:defer() self.deferred = self.deferred + 1 end
function hook:cont() self.continued = self.continued + 1 end
E.props["path"] = "https://youtu.be/x"
E.hooks["on_load"](hook)
E.timers[#E.timers]()  -- the prompt timeout fires
eq(hook.continued, 1, "timeout continues loading")

-- test_no_uosc_no_prompts
E = make_env({ cal = { ["1920x1080"] = FULL }, uosc = false })
hook = { deferred = 0 }
function hook:defer() self.deferred = self.deferred + 1 end
E.props["path"] = "https://youtu.be/x"
E.hooks["on_load"](hook)
eq(hook.deferred, 0, "without uosc, never block loading")

-- test_idle_click: start screen buttons route to uosc
E = make_env({ cal = { ["1920x1080"] = FULL } })
E.props["idle-active"] = true
E.props["osd-dimensions"] = { w = 1440, h = 810 }
E.observers["idle-active"]("idle-active", true)
assert(last_osd(E):find("Drop a video here", 1, true) and last_osd(E):find("RIFE ready", 1, true), "idle drawn")
assert(E.forced["mf-idle-click"], "click bound while idle")
local _, boxes = require("overlay").idle(1440, 810, "ready")
E.props["mouse-pos"] = { x = boxes.paste[1] + 10, y = boxes.paste[2] + 10 }
E.forced["mf-idle-click"]()
eq(E.cmds[#E.cmds], "script-binding uosc/paste", "paste clicked")
E.props["idle-active"] = false
E.observers["idle-active"]("idle-active", false)
eq(E.forced["mf-idle-click"], nil, "click unbound when playing")

-- test_waits_for_stream_fps: no filter until the real fps is known, then re-plans when it changes
E = make_env({ cal = { ["1920x1080"] = FULL } })
E.props["display-fps"] = 144
E.props["video-params"] = VP
E.observers["video-params"]()
eq(last_vf(E), nil, "no filter while fps unknown")
E.props["container-fps"] = 29.97
E.observers["container-fps"]()
assert(last_vf(E):find('"num":60000') and last_vf(E):find('"den":1001'), last_vf(E))
E.props["container-fps"] = 59.94
E.observers["container-fps"]()
assert(last_vf(E):find('"num":120000'), "re-planned for the real fps: " .. last_vf(E))
local count = #E.cmds
E.observers["container-fps"]()
eq(#E.cmds, count, "same fps again changes nothing")

clean()
print("test_main ok")
