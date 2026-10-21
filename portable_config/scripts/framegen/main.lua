-- FrameGen: wires RIFE interpolation (vs/rife.vpy) into mpv with an fps menu,
-- auto step-down, failure fallback, crash-resume state, start screen, notices and a debug overlay.
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
    added = false, building = false, debug = false,
    hist = { real_fps = {}, drops = {}, vram = {} },
}

local function osd_size()
    local d = mp.get_property_native("osd-dimensions") or {}
    return (d.w and d.w > 0) and d.w or 1280, (d.h and d.h > 0) and d.h or 720
end

-- Notices: one styled pill at the top centre (replaces mpv's plain OSD text).
local ov_toast = mp.create_osd_overlay("ass-events")
local toast_timer
local function notice(text, secs, kind)
    local w, h = osd_size()
    ov_toast.res_x, ov_toast.res_y = w, h
    ov_toast.data = overlay.toast(w, text, kind)
    ov_toast:update()
    if toast_timer then toast_timer:kill() end
    toast_timer = mp.add_timeout(secs or 4, function() ov_toast:remove() end)
end

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

local function target()
    local lv = current()
    if not (S.added and lv and not lv.off) then return nil end
    local s = S.fps_steps[lv.fps]
    return s.num / s.den, lv
end

-- Keep uosc's FPS / debug buttons and the top-bar status line in sync.
local function sync_ui()
    local t, lv = target()
    local src = S.src_num and fps.fmt(S.src_num / S.src_den)
    local tip = t and ("Frame rate: " .. src .. " → " .. fps.fmt(t) .. " fps (F)") or "Frame rate (F)"
    mp.commandv("script-message-to", "uosc", "set-button", "framegen_fps", utils.format_json({
        icon = "bolt", active = t ~= nil, badge = t and string.format("%d", math.floor(t + 0.5)) or nil,
        tooltip = tip, command = "script-binding framegen/fps-menu",
    }))
    mp.commandv("script-message-to", "uosc", "set-button", "framegen_debug", utils.format_json({
        icon = "show_chart", active = S.debug, tooltip = "Debug overlay (D)", command = "script-binding framegen/debug",
    }))
    local vp = mp.get_property_native("video-params") or {}
    local status = ""
    if vp.w and src then
        status = vp.w .. "×" .. vp.h .. " · " .. src .. " fps"
        if t then status = status .. " → " .. fps.fmt(t) .. " fps · " .. LADDER[lv.rife].label
        else status = status .. " · interpolation off" end
    end
    mp.set_property_native("user-data/framegen/status", status)
end

local apply, draw_idle

local function prepare()
    if not mp.get_property_bool("idle-active") then
        notice("Preparing RIFE (first run, several minutes)… playing without interpolation", 6, "warn")
    end
    if S.building then return end
    S.building = true
    if draw_idle then draw_idle() end
    mp.command_native_async({
        name = "subprocess", args = { expand(o.python), BUILDER, ENGINES },
        playback_only = false, capture_stdout = true, capture_stderr = true,
    }, function(ok, res)
        S.building = false
        draw_idle()
        if ok and res.status == 0 and engines_ready() then
            notice("RIFE ready", 3, "good")
            apply()
        else
            local err = ((res and res.stderr or ""):match("([^\n]*%S)%s*$") or "unknown error"):gsub("%s+$", "")
            msg.error("engine build failed: " .. ((res and res.stderr) or ""))
            notice("RIFE setup failed: " .. err, 8, "bad")
        end
    end)
end

apply = function()
    local lv = current()
    if not (S.enabled and lv and not lv.off) then
        remove()
        return sync_ui()
    end
    if not engines_ready() then return prepare() end
    local step = S.fps_steps[lv.fps]
    local json = utils.format_json({
        num = step.num, den = step.den, level = lv.rife, anime = o.anime,
        engines = ENGINES, matrix = S.matrix, range = S.range,
    })
    S.added = true
    mp.commandv("vf", "add", "@framegen:vapoursynth=file=" .. quoted(VPY) ..
        ":buffered-frames=8:concurrent-frames=4:user-data=" .. quoted(json))
    sync_ui()
end

local function retarget()
    if not S.src_num then return end
    local tn, td, err = fps.resolve(S.choice, S.src_num, S.src_den, fps.cap(mp.get_property_number("display-fps")))
    if not tn then
        msg.info("no interpolation: " .. err)
        S.levels = nil
        remove()
        return sync_ui()
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
    sync_ui()
end)
mp.register_script_message("uosc-version", sync_ui)  -- uosc (re)loaded: re-send our buttons

-- Any filter error: turn interpolation off, keep playing.
mp.enable_messages("error")
mp.register_event("log-message", function(e)
    if not S.added then return end
    local p, t = e.prefix or "", e.text or ""
    if p:find("vapoursynth") or t:find("vapoursynth") or t:find("Disabling filter") or t:find("Python exception") then
        S.enabled = false
        remove()
        sync_ui()
        local line = t:gsub("%s+$", "")
        notice("Interpolation turned off: " .. line, 6, "bad")
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

    local t = target()
    if not t or mp.get_property_bool("pause") then return end
    local action = auto.tick(S.auto, { drops = drops, delayed = delayed, vf_fps = vf_fps, target = t }, mp.get_time())
    if not action then return end
    local lv = current()
    if lv.off then
        notice("Too heavy for real-time: playing original fps", 5, "warn")
    elseif action == "down" then
        notice("Auto: stepped down to " .. LADDER[lv.rife].label .. " to stay smooth", 4, "warn")
    else
        msg.info("auto up -> level " .. S.auto.level)
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

-- Frame-rate menu (uosc menu).
local function set_choice(choice)
    S.choice, S.enabled = choice, true
    retarget()
    local t = target()
    if t then notice("Frame rate: " .. fps.fmt(S.src_num / S.src_den) .. " → " .. fps.fmt(t) .. " fps", 3, "info") end
end
mp.register_script_message("set-fps", set_choice)

mp.register_script_message("toggle", function()
    S.enabled = not S.enabled
    notice("Interpolation " .. (S.enabled and "on" or "off"), 2, "info")
    if S.enabled then retarget() else remove(); sync_ui() end
end)

mp.register_script_message("fps-custom", function()
    input.get({
        prompt = "Target fps:",
        submit = function(text)
            local n, _, err = fps.resolve(text, S.src_num, S.src_den, fps.cap(mp.get_property_number("display-fps")))
            input.terminate()
            if n then set_choice(text) else notice("Invalid fps: " .. err, 4, "bad") end
        end,
    })
end)

local function header(title) return { title = title, value = "ignore", muted = true, bold = true, selectable = false } end

mp.add_key_binding("F", "fps-menu", function()
    if not S.src_num then return notice("Open a video first", 2, "info") end
    local cap = fps.cap(mp.get_property_number("display-fps"))
    local items = { header("Multiply") }
    local fixed_started = false
    for _, op in ipairs(fps.options(S.src_num, S.src_den, cap)) do
        local is_fixed = op.choice:sub(1, 1) ~= "x"
        if is_fixed and not fixed_started then
            items[#items + 1] = header("Fixed")
            fixed_started = true
        end
        local t = op.num / op.den
        items[#items + 1] = {
            title = is_fixed and (op.choice .. " fps") or (op.choice:sub(2) .. "×"),
            hint = (not is_fixed and fps.fmt(t) .. " fps") or (math.abs(t - cap) < 0.5 and "matches display") or nil,
            value = { "script-message-to", "framegen", "set-fps", op.choice },
            active = S.enabled and op.choice == S.choice or nil,
        }
    end
    items[#items].separator = true
    items[#items + 1] = { title = "Custom…", hint = "type a value", value = "script-message-to framegen fps-custom" }
    local t, lv = target()
    items[#items + 1] = {
        title = "Interpolation", value = "script-message-to framegen toggle",
        icon = S.enabled and "toggle_on" or "toggle_off",
        hint = (not S.enabled and "off") or (t and LADDER[lv.rife].label) or "on · not running",
    }
    mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json({
        type = "framegen_fps", title = "Frame rate", items = items, search_style = "disabled",
        footnote = "Source " .. fps.fmt(S.src_num / S.src_den) .. " fps · Display " .. cap .. " Hz",
    }))
end)

-- Debug overlay (toggle with D).
local ov = mp.create_osd_overlay("ass-events")
ov.res_x, ov.res_y = 1280, 720
local ov_timer, vram_timer
local function draw()
    local vp = mp.get_property_native("video-params") or {}
    local t, lv = target()
    ov.data = overlay.render({
        src_res = vp.w and (vp.w .. "×" .. vp.h),
        src_fps = S.src_num and S.src_num / S.src_den,
        target_fps = t,
        real_fps = S.real_fps,
        display_fps = mp.get_property_number("display-fps"),
        level_label = lv and LADDER[lv.rife].label or "interpolation off",
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
    S.debug = not S.debug
    if S.debug then
        draw(); poll_vram()
        ov_timer = mp.add_periodic_timer(0.25, draw)
        vram_timer = mp.add_periodic_timer(2, poll_vram)
    else
        ov_timer:kill(); vram_timer:kill()
        ov:remove()
    end
    sync_ui()
end)

-- Start screen while nothing is loaded.
local ov_idle = mp.create_osd_overlay("ass-events")
local idle_boxes
local function idle_click()
    local m = mp.get_property_native("mouse-pos") or {}
    if overlay.hit(idle_boxes and idle_boxes.open, m.x or -1, m.y or -1) then
        mp.commandv("script-binding", "uosc/open-file")
    elseif overlay.hit(idle_boxes and idle_boxes.paste, m.x or -1, m.y or -1) then
        mp.commandv("script-binding", "uosc/paste")
    end
end
draw_idle = function()
    if not mp.get_property_bool("idle-active") then
        ov_idle:remove()
        mp.remove_key_binding("fg-idle-click")
        return
    end
    local w, h = osd_size()
    local state = (S.building and "building") or (engines_ready() and "ready") or "missing"
    ov_idle.res_x, ov_idle.res_y = w, h
    ov_idle.data, idle_boxes = overlay.idle(w, h, state)
    ov_idle:update()
    mp.add_forced_key_binding("MBTN_LEFT", "fg-idle-click", idle_click)
end
mp.observe_property("idle-active", "bool", draw_idle)
mp.observe_property("osd-dimensions", "native", function() draw_idle() end)

-- Build the TensorRT engines right away on first launch instead of waiting for a video.
if not engines_ready() then prepare() end
sync_ui()
