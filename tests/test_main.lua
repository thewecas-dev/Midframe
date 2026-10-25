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
        set_property_number = function(p, v) E.set[p] = v end,
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
local function osd_has(E, s) for i = #E.osd, math.max(1, #E.osd - 3), -1 do if E.osd[i]:find(s, 1, true) then return true end end return false end
local function last_cmd(E, pat)
    for i = #E.cmds, 1, -1 do if E.cmds[i]:find(pat) then return E.cmds[i] end end
end
local function play(E, vp, cfps)
    E.props["display-fps"] = 144
    E.props["container-fps"] = cfps
    E.props["video-params"] = vp
    E.observers["video-params"]()
end
-- engine builds among the async subprocesses (the others are system probes, dialogs)
local function builds(E)
    local out = {}
    for _, a in ipairs(E.async) do if a.cmd.args and tostring(a.cmd.args[2]):find("build_engines") then out[#out + 1] = a end end
    return out
end
local function build_args(E, i) return table.concat(builds(E)[i].cmd.args, " ", 3) end  -- drop python + script
local function act(E, t) E.messages["action"](json(t)) end
local function new_hook() local h = { deferred = 0, continued = 0 }; function h:defer() self.deferred = self.deferred + 1 end; function h:cont() self.continued = self.continued + 1 end; return h end
local TRACKS_YT = { { type = "audio", id = 1 }, { type = "video", id = 1, ["demux-h"] = 2160, ["demux-w"] = 3840, ["demux-fps"] = 29.97 },
    { type = "video", id = 2, ["demux-h"] = 1080, ["demux-w"] = 1920, ["demux-fps"] = 29.97, selected = true },
    { type = "video", id = 3, ["demux-h"] = 720, ["demux-w"] = 1280, ["demux-fps"] = 29.97 } }

-- test_first_launch_builds_reference: no calibration -> one build of every level at 1080p
local E = make_env({})
eq(#builds(E), 1, "reference build started at launch")
eq(build_args(E, 1), ENGINES .. " 1920 1080", "all levels at the reference size")
play(E, VP, 23.976)
eq(last_vf(E), nil, "no filter while nothing is calibrated")
eq(#builds(E), 1, "no second build while one runs")
E.props["idle-active"] = true; E.props["osd-dimensions"] = { w = 1440, h = 900 }
E.observers["idle-active"]()
assert(osd_has(E, "Preparing RIFE engines"), "home shows building")
assert(osd_has(E, "Play something smoother."), "home drawn")

-- test_no_interpolation_while_building: calibration appearing mid-build must not start the filter;
-- when the build ends, the video is re-planned.
write(ENGINES .. "/cal_1920x1080.json", json({ w = 1920, h = 1080, levels = FULL }))
E.messages["set-fps"]("60")
eq(last_vf(E), nil, "no filter while the reference build runs")
assert(E.set["user-data/midframe/status"]:find("preparing RIFE", 1, true), E.set["user-data/midframe/status"])
builds(E)[1].cb(true, { status = 0 })
assert(last_vf(E) and last_vf(E):find('"num":60,'), "interpolation starts once the build is done")
assert(osd_has(E, "RIFE ready"), last_osd(E))

-- test_apply_quotes_user_data
E = make_env({ cal = { ["1920x1080"] = FULL } })
eq(#builds(E), 0, "calibrated: nothing to build")
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
assert(osd_has(E, "Interpolation turned off: TensorRT: out of memory"), last_osd(E))
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
assert(last_cmd(E, "set%-button midframe_fps"):find('"active":true') and not last_cmd(E, "set%-button midframe_fps"):find("badge"), "fps button lights up, no badge")
eq(E.set["user-data/midframe/status"], "1920×1080 · 23.976 fps → 47.952 fps · RIFE 4.6 half", "status line")

-- test_new_size_builds_on_demand: 720p has no engines yet -> build the estimated level only, play plain
E = make_env({ cal = { ["1920x1080"] = RTX4050 } })
play(E, { w = 1280, h = 720, colormatrix = "bt.709", colorlevels = "limited" }, 23.976)
eq(last_vf(E), nil, "no filter without an engine")
eq(#builds(E), 1, "one on-demand build")
eq(build_args(E, 1), ENGINES .. " 1280 720 1", "720p fits level 1 by estimate")
assert(osd_has(E, "Preparing RIFE 4.26 for 1280×720"), last_osd(E))
assert(E.set["user-data/midframe/status"]:find("preparing RIFE 4.26", 1, true), E.set["user-data/midframe/status"])
write(ENGINES .. "/cal_1280x720.json", json({ w = 1280, h = 720, levels = { ["1"] = 90 } }))
builds(E)[1].cb(true, { status = 0 })
assert(last_vf(E) and last_vf(E):find('"level":1'), "filter added once the engine exists")

-- test_build_queue: a second size while one build runs waits its turn
E = make_env({ cal = { ["1920x1080"] = RTX4050 } })
play(E, { w = 1280, h = 720, colormatrix = "bt.709", colorlevels = "limited" }, 23.976)
play(E, { w = 2560, h = 1440, colormatrix = "bt.709", colorlevels = "limited" }, 23.976)
eq(#builds(E), 1, "second build queued, not started")
write(ENGINES .. "/cal_1280x720.json", json({ w = 1280, h = 720, levels = { ["1"] = 90 } }))
builds(E)[1].cb(true, { status = 0 })
eq(#builds(E), 2, "queued build starts after the first")
assert(build_args(E, 2):find("^" .. ENGINES .. " 2560 1440 %d$"), build_args(E, 2))

-- test_quick_menu: F opens the tile menu; a tile applies; toggle turns interpolation off; Esc closes
E = make_env({ cal = { ["1920x1080"] = FULL } })
E.props["osd-dimensions"] = { w = 1440, h = 900 }
play(E, VP, 23.976)
E.bindings["fps-menu"]()
assert(osd_has(E, "Frame rate") and osd_has(E, "Even on 144 Hz") and osd_has(E, "Interpolation"), "quick menu drawn")
assert(E.forced["mf-click"] and E.forced["mf-key-ESC"], "menu captures clicks and keys")
act(E, { kind = "rate", choice = "x3" })
assert(last_vf(E):find('"num":72000'), "3x applied from the tile: " .. last_vf(E))
act(E, { kind = "custom" }); act(E, { kind = "key", key = "9" }); act(E, { kind = "key", key = "0" }); act(E, { kind = "key", key = "ENTER" })
assert(last_vf(E):find('"num":90,'), "custom 90 typed + Enter: " .. last_vf(E))
eq(E.forced["mf-click"], nil, "menu closed on Enter")
E.bindings["fps-menu"]()
act(E, { kind = "toggle" })
eq(last_vf(E), "vf remove @midframe", "toggle turned interpolation off")
act(E, { kind = "key", key = "ESC" })
eq(E.forced["mf-key-ESC"], nil, "Esc closes")

-- test_yt_sheet: one sheet at on_preloaded with quality + frame rate; quality switches the video track
E = make_env({ cal = { ["1920x1080"] = FULL } })
E.props["osd-dimensions"] = { w = 1440, h = 900 }
local hook = new_hook()
E.props["path"] = "https://www.youtube.com/watch?v=abc"
E.props["media-title"] = "Jailer Climax Scene"
E.props["display-fps"] = 144
E.props["track-list"] = TRACKS_YT
E.props["duration"] = 544
E.hooks["on_preloaded"](hook)
eq(hook.deferred, 1, "loading paused for the sheet")
eq(E.set["vid"], 2, "Auto quality (up to 1440p) picked the 1080p track before any decode")
assert(osd_has(E, "QUALITY") and osd_has(E, "Jailer Climax Scene") and osd_has(E, "up to 2160p"), "yt sheet drawn")
assert(osd_has(E, "Even on your 144 Hz display"), "even group")
assert(E.forced["mf-key-WHEEL_UP"] and E.forced["mf-key-SPACE"] and E.forced["mf-key-UP"], "sheet owns wheel, space and arrows")
act(E, { kind = "key", key = "UP" })        -- auto -> stays at the first entry
act(E, { kind = "key", key = "DOWN" })      -- auto -> 2160
eq(E.set["vid"], 1, "Down arrow moved quality to 2160p")
act(E, { kind = "quality", value = "2160" })
eq(E.set["vid"], 1, "2160p track selected immediately")
act(E, { kind = "rate", choice = "x2" })
act(E, { kind = "key", key = "RIGHT" })
assert(io.open(PREFS):read("*a"):find('"choice":"x2.5"'), "Right arrow moves to the next tile in display order (29.97 source: 2x -> 2.5x)")
act(E, { kind = "key", key = "LEFT" })
assert(io.open(PREFS):read("*a"):find('"choice":"x2"'), "Left arrow back to 2x")
assert(io.open(PREFS):read("*a"):find('"quality":"2160"'), "quality remembered")
act(E, { kind = "rate", choice = "60" })
eq(hook.continued, 0, "still waiting for Play")
act(E, { kind = "play" })
eq(hook.continued, 1, "loading continues on Play")
eq(E.forced["mf-click"], nil, "sheet closed")
play(E, VP, 29.97)
assert(last_vf(E):find('"num":60,'), "chosen fps used: " .. last_vf(E))
-- same URL reloaded right away: no sheet again; much later: sheet again
E.events["end-file"]()
E.hooks["on_preloaded"](hook)
eq(hook.deferred, 1, "no re-prompt on reload")
local real_time = package.loaded["mp"].get_time
package.loaded["mp"].get_time = function() return 100 end
E.hooks["on_preloaded"](hook)
eq(hook.deferred, 2, "re-prompt after a while")
package.loaded["mp"].get_time = real_time
act(E, { kind = "key", key = "ESC" })
eq(hook.continued, 2, "Esc continues")

-- test_local_sheet: frame rate only; Esc keeps the previous choice; Play original disables; remember toggle persists
E = make_env({ cal = { ["1920x1080"] = FULL } })
E.props["osd-dimensions"] = { w = 1440, h = 900 }
hook = new_hook()
E.props["path"] = "D:\\movies\\film.mkv"
E.props["media-title"] = "film"
E.props["display-fps"] = 144
E.props["track-list"] = { { type = "video", id = 1, ["demux-fps"] = 23.976, ["demux-w"] = 1920, ["demux-h"] = 1080, codec = "hevc" } }
E.hooks["on_preloaded"](hook)
eq(hook.deferred, 1, "local sheet")
assert(not osd_has(E, "QUALITY"), "no quality section for local files")
assert(osd_has(E, "1920×1080") and osd_has(E, "HEVC"), "local meta line")
act(E, { kind = "key", key = "ESC" })
eq(hook.continued, 1, "continues on Esc")
play(E, VP, 23.976)
assert(last_vf(E):find('"num":48000'), "default 2x kept: " .. last_vf(E))
E.hooks["on_preloaded"](new_hook())  -- reopened later (different path) to test Play original + remember
E.props["path"] = "D:\\movies\\other.mkv"
hook = new_hook()
E.hooks["on_preloaded"](hook)
act(E, { kind = "remember" })
assert(io.open(PREFS):read("*a"):find('"ask_local":false'), "don't ask again persisted")
act(E, { kind = "original" })
eq(last_vf(E), "vf remove @midframe", "original playback")
eq(hook.continued, 1)
E.props["path"] = "D:\\movies\\third.mkv"
hook = new_hook()
E.hooks["on_preloaded"](hook)
eq(hook.deferred, 0, "no sheet once asked not to")

-- test_prompt_timeout: an unanswered sheet continues loading
E = make_env({ cal = { ["1920x1080"] = FULL } })
E.props["osd-dimensions"] = { w = 1440, h = 900 }
hook = new_hook()
E.props["path"] = "https://youtu.be/x"
E.props["track-list"] = TRACKS_YT
E.hooks["on_preloaded"](hook)
eq(hook.deferred, 1)
E.timers[#E.timers]()  -- the sheet timeout fires
eq(hook.continued, 1, "timeout continues loading")

-- test_home_actions: open file -> native dialog; recent -> resume; settings -> drawer
E = make_env({ cal = { ["1920x1080"] = FULL } })
E.props["idle-active"] = true
E.props["osd-dimensions"] = { w = 1440, h = 900 }
E.observers["idle-active"]("idle-active", true)
assert(osd_has(E, "Drop a video here") and osd_has(E, "RIFE ready"), "home drawn")
assert(E.forced["mf-click"], "clicks bound on home")
local n_async = #E.async
act(E, { kind = "open" })
assert(#E.async == n_async + 1 and E.async[#E.async].cmd.args[1] == "powershell", "native dialog launched")
E.async[#E.async].cb(true, { status = 0, stdout = "D:\\Movies\\x.mkv\r\n" })
eq(E.cmds[#E.cmds], "loadfile D:\\Movies\\x.mkv replace", "picked file loads")
E.props["clipboard/text"] = "https://youtu.be/abc"
act(E, { kind = "play_link" })
eq(E.cmds[#E.cmds], "loadfile https://youtu.be/abc replace", "clipboard link loads")
act(E, { kind = "settings" })
assert(osd_has(E, "Settings") and osd_has(E, "BEFORE PLAYBACK"), "settings drawer")
act(E, { kind = "tab", value = "engines" })
assert(osd_has(E, "All 4 levels measured"), "engines tab shows the 1080p calibration")
act(E, { kind = "prepare", w = 3840, h = 2160 })
eq(build_args(E, 1), ENGINES .. " 3840 2160", "Prepare now builds that size")
act(E, { kind = "tab", value = "playback" })
act(E, { kind = "cycle", key = "choice" })
assert(io.open(PREFS):read("*a"):find('"choice":"x2.5"'), "default rate cycles and persists")
act(E, { kind = "key", key = "ESC" })
assert(osd_has(E, "Drop a video here"), "back to home after settings")
E.props["idle-active"] = false
E.observers["idle-active"]("idle-active", false)
eq(E.forced["mf-click"], nil, "home unbound when playing")

-- test_recents: a played file is remembered with its title and resumes from its position
E = make_env({ cal = { ["1920x1080"] = FULL } })
os.remove("portable_config/midframe-recent.json")
E = make_env({ cal = { ["1920x1080"] = FULL } })
E.props["path"] = "D:\\Movies\\Sinners.mkv"; E.props["media-title"] = "Sinners (2025)"; E.props["duration"] = 8260; E.props["time-pos"] = 3100
E.events["file-loaded"]()
play(E, VP, 23.976)
E.events["shutdown"]()  -- position saved on the 5 s timer / at exit
local rec = io.open("portable_config/midframe-recent.json"):read("*a")
assert(rec:find("Sinners %(2025%)") and rec:find('"fps":"23.976"'), rec)
E.props["path"] = nil
E.props["idle-active"] = true; E.props["osd-dimensions"] = { w = 1440, h = 900 }
E.observers["idle-active"]("idle-active", true)
assert(osd_has(E, "Sinners (2025)"), "recent card on home")
act(E, { kind = "recent", index = 1 })
assert(E.cmds[#E.cmds]:find("^loadfile D:\\Movies\\Sinners%.mkv replace %-1 start=%d"), E.cmds[#E.cmds])
os.remove("portable_config/midframe-recent.json")

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
