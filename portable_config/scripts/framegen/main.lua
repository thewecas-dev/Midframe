-- FrameGen: wires RIFE interpolation (vs/rife.vpy) into mpv with an fps menu,
-- auto step-down, failure fallback, crash-resume state and a debug overlay.
local mp = require "mp"
local utils = require "mp.utils"
local msg = require "mp.msg"
local input = require "mp.input"
local fps = require "fps"
local auto = require "auto"
local overlay = require "overlay"

local o = {
    enabled = true,
    choice = "x2",
    anime = true,
    python = "~~exe_dir/vs-runtime/python.exe",
    engines = "~~/engines",
}
require("mp.options").read_options(o, "framegen")

local function expand(p) return mp.command_native({ "expand-path", p }) end

local VPY = expand("~~/vs/rife.vpy")
local BUILDER = expand("~~/vs/build_engines.py")
local ENGINES = expand(o.engines)
local STATE_FILE = expand("~~/framegen-last.json")
local LADDER = (function()
    local f = assert(io.open(expand("~~/vs/ladder.json"), "r"))
    local t = utils.parse_json(f:read("*a"))
    f:close()
    return t
end)()
local MATRIX = { ["bt.709"] = "709", ["bt.601"] = "170m", ["bt.2020-ncl"] = "2020ncl" }

local S = {
    enabled = o.enabled, choice = o.choice,
    added = false, building = false, failed_msg = nil,
    hist = { real_fps = {}, drops = {}, vram = {} },
}

local function notice(text, secs) mp.osd_message(text, secs or 4) end

local function remove()
    if S.added then mp.commandv("vf", "remove", "@framegen") end
    S.added = false
end

local function quoted(s) return "%" .. #s .. "%" .. s end  -- mpv option quoting, safe for C:\ paths and JSON

local function engines_ready() return utils.file_info(ENGINES .. "/READY") ~= nil end

local function current()
    if not (S.auto and S.levels) then return nil end
    return S.levels[S.auto.level]
end

local apply

local function prepare()
    notice("Preparing RIFE (first run, several minutes)… playing without interpolation", 6)
    if S.building then return end
    S.building = true
    mp.command_native_async({
        name = "subprocess", args = { expand(o.python), BUILDER, ENGINES },
        playback_only = false, capture_stdout = true, capture_stderr = true,
    }, function(ok, res)
        S.building = false
        if ok and res.status == 0 and engines_ready() then
            notice("RIFE ready", 3)
            apply()
        else
            local err = (res and res.stderr or ""):match("([^\n]+)\n*$") or "unknown error"
            msg.error("engine build failed: " .. ((res and res.stderr) or ""))
            notice("RIFE setup failed: " .. err, 8)
        end
    end)
end

apply = function()
    local lv = current()
    if not (S.enabled and lv and not lv.off) then return remove() end
    if not engines_ready() then return prepare() end
    local step = S.fps_steps[lv.fps]
    local json = utils.format_json({
        num = step.num, den = step.den, level = lv.rife, anime = o.anime,
        engines = ENGINES, matrix = S.matrix, range = S.range,
    })
    S.added = true
    mp.commandv("vf", "add", "@framegen:vapoursynth=file=" .. quoted(VPY) ..
        ":buffered-frames=8:concurrent-frames=4:user-data=" .. quoted(json))
end

local function retarget()
    if not S.src_num then return end
    local tn, td, err = fps.resolve(S.choice, S.src_num, S.src_den, fps.cap(mp.get_property_number("display-fps")))
    if not tn then
        msg.info("no interpolation: " .. err)
        S.levels = nil
        return remove()
    end
    S.fps_steps = auto.fps_steps(tn, td, S.src_num, S.src_den)
    S.levels = auto.levels(#LADDER, S.fps_steps)
    S.auto = auto.new(S.levels, mp.get_time())
    apply()
end

local function setup(vp)
    local n, d = fps.snap(mp.get_property_number("container-fps"))
    if not n then n, d = 30000, 1001 end  -- same fallback as fg_vs.source_fps
    S.src_num, S.src_den = n, d
    S.matrix = MATRIX[vp.colormatrix] or (vp.h and vp.h <= 576 and "170m" or "709")
    S.range = (vp.colorlevels == "full" or vp.colorlevels == "pc") and "full" or "limited"
    retarget()
end

-- File lifecycle: set up once per file when decoder params are known.
mp.observe_property("video-params", "native", function(_, vp)
    if vp and vp.w and not S.src_num then setup(vp) end
end)
mp.register_event("end-file", function()
    remove()
    S.src_num, S.levels, S.auto = nil, nil, nil
    S.enabled = o.enabled  -- a failure only disables interpolation for the file it happened on
end)

-- Any filter error: turn interpolation off, keep playing.
mp.enable_messages("error")
mp.register_event("log-message", function(e)
    if not S.added then return end
    local p, t = e.prefix or "", e.text or ""
    if p:find("vapoursynth") or t:find("vapoursynth") or t:find("Disabling filter") or t:find("Python exception") then
        S.enabled = false
        remove()
        local line = t:gsub("%s+$", "")
        notice("Interpolation turned off: " .. line, 6)
        msg.warn("interpolation disabled after: " .. line)
    end
end)

-- Seek latency + fresh warm-up for auto mode (the .vpy reloads on every seek).
mp.register_event("seek", function() S.seek_t = mp.get_time() end)
mp.register_event("playback-restart", function()
    if S.seek_t then S.seek_ms = math.floor((mp.get_time() - S.seek_t) * 1000 + 0.5) end
    S.seek_t = nil
    if S.auto then auto.rewarm(S.auto, mp.get_time()) end
end)

local function push(t, v)
    t[#t + 1] = v
    if #t > 120 then table.remove(t, 1) end
end

-- Auto mode + overlay history, once a second.
local last_drops = 0
mp.add_periodic_timer(1, function()
    local drops = mp.get_property_number("frame-drop-count", 0)
    local delayed = mp.get_property_number("vo-delayed-frame-count", 0)
    local vf_fps = mp.get_property_number("estimated-vf-fps")
    local dps = math.max(0, drops - last_drops)
    last_drops = drops
    S.real_fps = vf_fps and math.max(0, vf_fps - dps)
    push(S.hist.real_fps, S.real_fps or 0)
    push(S.hist.drops, dps)

    local lv = current()
    if not (S.added and lv and not lv.off) or mp.get_property_bool("pause") then return end
    local step = S.fps_steps[lv.fps]
    local action = auto.tick(S.auto, { drops = drops, delayed = delayed, vf_fps = vf_fps, target = step.num / step.den },
        mp.get_time())
    if not action then return end
    lv = current()
    if lv.off then
        notice("Too heavy for real-time: playing original fps", 5)
    else
        msg.info("auto " .. action .. " -> level " .. S.auto.level)
    end
    apply()
end)

-- Crash-resume state for the launcher.
local function save_state()
    local path = mp.get_property("path")
    if not path then return end
    local f = io.open(STATE_FILE, "w")
    if not f then return end
    f:write(utils.format_json({ path = path, pos = mp.get_property_number("time-pos", 0) }))
    f:close()
end
mp.add_periodic_timer(5, save_state)
mp.register_event("shutdown", save_state)

-- FPS menu.
local function set_choice(choice)
    S.choice, S.enabled = choice, true
    retarget()
    local lv = current()
    if lv then
        local s = S.fps_steps[1]
        notice("Frame rate: " .. fps.fmt(S.src_num / S.src_den) .. " → " .. fps.fmt(s.num / s.den) .. " fps", 3)
    end
end
mp.register_script_message("set-fps", set_choice)

mp.add_key_binding("F", "fps-menu", function()
    if not S.src_num then return notice("No video loaded", 2) end
    local opts = fps.options(S.src_num, S.src_den, fps.cap(mp.get_property_number("display-fps")))
    local items, default = {}, nil
    for i, op in ipairs(opts) do
        items[i] = op.label
        if op.choice == S.choice then default = i end
    end
    items[#items + 1] = "Custom…"
    items[#items + 1] = S.enabled and "Turn interpolation off" or "Turn interpolation on"
    input.select({
        prompt = "Frame rate:", items = items, default_item = default,
        submit = function(i)
            if opts[i] then return set_choice(opts[i].choice) end
            if i == #opts + 1 then
                return mp.add_timeout(0.05, function()
                    input.get({
                        prompt = "Target fps:",
                        submit = function(text)
                            local n, _, err = fps.resolve(text, S.src_num, S.src_den,
                                fps.cap(mp.get_property_number("display-fps")))
                            input.terminate()
                            if n then set_choice(text) else notice("Invalid fps: " .. err, 4) end
                        end,
                    })
                end)
            end
            S.enabled = not S.enabled
            notice("Interpolation " .. (S.enabled and "on" or "off"), 2)
            if S.enabled then retarget() else remove() end
        end,
    })
end)

-- Debug overlay (toggle with D).
local ov = mp.create_osd_overlay("ass-events")
ov.res_x, ov.res_y = 1280, 720
local ov_timer, vram_timer
local function draw()
    local vp = mp.get_property_native("video-params") or {}
    local lv = current()
    local step = lv and not lv.off and S.fps_steps[lv.fps]
    ov.data = overlay.render({
        src_res = vp.w and (vp.w .. "×" .. vp.h),
        src_fps = S.src_num and S.src_num / S.src_den,
        target_fps = step and step.num / step.den,
        real_fps = S.real_fps,
        display_fps = mp.get_property_number("display-fps"),
        level_label = (not S.added and "interpolation off") or (lv and LADDER[lv.rife].label),
        backend = "TensorRT",
        auto_level = S.auto and S.auto.level, auto_total = S.levels and #S.levels,
        drops = mp.get_property_number("frame-drop-count"),
        delayed = mp.get_property_number("vo-delayed-frame-count"),
        vram_mb = S.vram_mb, seek_ms = S.seek_ms, hist = S.hist,
    })
    ov:update()
end
local function poll_vram()
    mp.command_native_async({
        name = "subprocess", playback_only = false, capture_stdout = true,
        args = { "nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits" },
    }, function(ok, res)
        S.vram_mb = ok and tonumber((res.stdout or ""):match("%d+")) or nil
        if S.vram_mb then push(S.hist.vram, S.vram_mb) end
    end)
end
mp.add_key_binding("D", "debug", function()
    if ov_timer then
        ov_timer:kill(); vram_timer:kill()
        ov_timer, vram_timer = nil, nil
        ov:remove()
        return
    end
    draw(); poll_vram()
    ov_timer = mp.add_periodic_timer(0.25, draw)
    vram_timer = mp.add_periodic_timer(2, poll_vram)
end)
