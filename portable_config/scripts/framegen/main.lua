-- FrameGen: wires RIFE interpolation (vs/rife.vpy) into mpv with before-playback prompts
-- (YouTube quality, frame rate), per-resolution TensorRT engines built on demand, auto step-down,
-- failure fallback, crash-resume state, start screen, notices and a debug overlay.
local mp = require "mp"
local utils = require "mp.utils"
local msg = require "mp.msg"
local input = require "mp.input"
local fps = require "fps"
local auto = require "auto"
local overlay = require "overlay"

local o = {
    enabled = true,
    choice = "x2",       -- default frame-rate choice (overridden by the last pick, see PREFS)
    quality = "auto",    -- default YouTube quality: auto | 2160 | 1440 | 1080 | 720 | 480
    ask = true,          -- ask quality/frame rate before each video starts
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
local PREFS = expand("~~/framegen-prefs.json")
local ERROR_LOG = expand("~~/framegen-error.log")
local REF_W, REF_H = 1920, 1080  -- reference size: every level is built + measured here at setup
local PROMPT_TIMEOUT = 90        -- seconds before an unanswered prompt lets playback continue
local QUALITIES = { "auto", "2160", "1440", "1080", "720", "480" }
local AUTO_MAX_HEIGHT = 1440

local function read_json(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local t = utils.parse_json(f:read("*a") or "")
    f:close()
    return type(t) == "table" and t or nil
end
local function write_json(path, t)
    local f = io.open(path, "w")
    if not f then return end
    f:write(utils.format_json(t))
    f:close()
end

local LADDER = assert(read_json(expand("~~/vs/ladder.json")), "framegen: vs/ladder.json missing")
local MATRIX = { ["bt.709"] = "709", ["bt.601"] = "170m", ["bt.2020-ncl"] = "2020ncl" }
local prefs = read_json(PREFS) or {}

local S = {
    enabled = o.enabled, choice = prefs.choice or o.choice, quality = prefs.quality or o.quality,
    added = false, debug = false, builds = {}, building = nil,
    uosc = utils.file_info(expand("~~/scripts/uosc/main.lua")) ~= nil,
    hist = { real_fps = {}, drops = {}, vram = {} },
}

local function save_prefs() write_json(PREFS, { choice = S.choice, quality = S.quality }) end

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

-- Calibration written by build_engines.py: {level = output fps at 2x} per frame size.
local function cal(w, h)
    local t = read_json(ENGINES .. "/cal_" .. w .. "x" .. h .. ".json")
    local out = {}
    for k, v in pairs(t and t.levels or {}) do
        if type(v) == "number" then out[tonumber(k)] = v end
    end
    return out
end
local function ref_ready()
    local r = cal(REF_W, REF_H)
    for i = 1, #LADDER do if not r[i] then return false end end
    return true
end

local function video_size()
    local vp = mp.get_property_native("video-params") or {}
    return vp.w, vp.h
end

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

local function size_label(w, h) return w .. "×" .. h end

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
    local w, h = video_size()
    local status = ""
    if w and src then
        status = size_label(w, h) .. " · " .. src .. " fps"
        if t then
            status = status .. " → " .. fps.fmt(t) .. " fps · " .. LADDER[lv.rife].label
        elseif S.building then
            status = status .. " · preparing " .. (S.building.level and LADDER[S.building.level].label or "RIFE") .. "…"
        else
            status = status .. " · interpolation off"
        end
    end
    mp.set_property_native("user-data/framegen/status", status)
end

local apply, draw_idle, retarget

-- Engine builds run one at a time in a subprocess (minutes each); playback stays plain meanwhile.
local function start_build(job)
    local function same(j) return j.w == job.w and j.h == job.h and j.level == job.level end
    if S.building then
        if same(S.building) then return end
        for _, j in ipairs(S.builds) do if same(j) then return end end
        S.builds[#S.builds + 1] = job
        return
    end
    S.building = job
    if draw_idle then draw_idle() end
    sync_ui()
    local args = { expand(o.python), BUILDER, ENGINES, tostring(job.w), tostring(job.h) }
    if job.level then args[#args + 1] = tostring(job.level) end
    mp.command_native_async({
        name = "subprocess", args = args, playback_only = false, capture_stdout = true, capture_stderr = true,
    }, function(ok, res)
        S.building = nil
        local full = (res and ((res.stdout or "") .. (res.stderr or ""))) or ""
        if ok and res.status == 0 then
            if not job.level then notice("RIFE ready", 3, "good") end
        else
            local err = (full:match("([^\n]*%S)%s*$") or "unknown error"):gsub("%s+$", "")
            msg.error("engine build failed: " .. full)
            local f = io.open(ENGINES .. "/build-error.log", "w")
            if f then f:write(full); f:close() end
            notice("RIFE setup failed (details: portable_config\\engines\\build-error.log): " .. err, 10, "bad")
        end
        draw_idle()
        local nxt = table.remove(S.builds, 1)
        if nxt then start_build(nxt) else retarget() end  -- GPU free again: plan from the new calibration
        sync_ui()
    end)
end

local function ensure_ref()
    if not ref_ready() then start_build({ w = REF_W, h = REF_H }) end
end

apply = function()
    local lv = current()
    if not (S.enabled and lv and not lv.off) then
        remove()
        return sync_ui()
    end
    if S.building then  -- a build owns the GPU: playing alongside it only stutters and trips auto mode
        remove()
        return sync_ui()
    end
    local w, h = video_size()
    if not cal(w, h)[lv.rife] then
        -- No engine for this frame size yet: build it now, play the original meanwhile.
        remove()
        start_build({ w = w, h = h, level = lv.rife })
        notice("Preparing " .. LADDER[lv.rife].label .. " for " .. size_label(w, h) ..
            " (first time, a few minutes)… playing original fps", 6, "warn")
        return sync_ui()
    end
    local step = S.fps_steps[lv.fps]
    local json = utils.format_json({
        num = step.num, den = step.den, level = lv.rife, anime = o.anime,
        engines = ENGINES, matrix = S.matrix, range = S.range,
    })
    S.added = true
    mp.commandv("vf", "add", "@framegen:vapoursynth=file=" .. quoted(VPY) ..
        ":buffered-frames=8:concurrent-frames=8:user-data=" .. quoted(json))
    sync_ui()
end

retarget = function()
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
    local w, h = video_size()
    local start = 1
    if w then
        start = auto.start_level(cal(w, h), cal(REF_W, REF_H), REF_W, REF_H, w, h,
            auto.rife_per_s(tn, td, S.src_num, S.src_den), #LADDER)
    end
    S.auto = auto.new(S.levels, mp.get_time(), start)
    apply()
end

-- Set up once decoder params AND the real source fps are known; redo it if either changes
-- (streams often report fps a moment after playback starts, and may switch resolution).
local function try_setup()
    local vp = mp.get_property_native("video-params")
    local n, d = fps.snap(mp.get_property_number("container-fps"))
    if not (vp and vp.w and n) then return end
    if S.src_num == n and S.src_den == d and S.w == vp.w and S.h == vp.h then return end
    S.src_num, S.src_den, S.w, S.h = n, d, vp.w, vp.h
    S.matrix = MATRIX[vp.colormatrix] or (vp.h and vp.h <= 576 and "170m" or "709")
    S.range = (vp.colorlevels == "full" or vp.colorlevels == "pc") and "full" or "limited"
    retarget()
end
mp.observe_property("video-params", "native", try_setup)
mp.observe_property("container-fps", "number", try_setup)
mp.register_event("end-file", function()
    S.ended_at = mp.get_time()
    remove()
    S.src_num, S.w, S.h, S.levels, S.auto = nil, nil, nil, nil, nil
    S.enabled = o.enabled  -- a failure only disables interpolation for the file it happened on
    sync_ui()
end)
mp.register_script_message("uosc-version", function() S.uosc = true; sync_ui() end)

-- Any filter error: turn interpolation off, keep playing. The full traceback goes to ERROR_LOG.
mp.enable_messages("error")
mp.register_event("log-message", function(e)
    local p, t = e.prefix or "", e.text or ""
    if S.added or (S.fail_until and mp.get_time() < S.fail_until) then
        local f = io.open(ERROR_LOG, "a")
        if f then f:write("[", p, "] ", t, t:sub(-1) == "\n" and "" or "\n"); f:close() end
    end
    if not S.added then return end
    if p:find("vapoursynth") or t:find("vapoursynth") or t:find("Disabling filter") or t:find("Python exception")
        or t:find("Script evaluation failed") then
        S.fail_until = mp.get_time() + 3
        S.enabled = false
        remove()
        sync_ui()
        local line = t:gsub("%s+$", "")
        notice("Interpolation turned off: " .. line .. " (details: portable_config\\framegen-error.log)", 8, "bad")
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
    else
        notice("Auto: stepped down to " .. LADDER[lv.rife].label .. " to stay smooth", 4, "warn")
    end
    apply()
end)

-- Crash-resume state for the launcher.
local function save_state()
    local path = mp.get_property("path")
    if not path then return end
    write_json(STATE_FILE, { path = path, pos = mp.get_property_number("time-pos", 0) })
end
mp.add_periodic_timer(5, save_state)
mp.register_event("shutdown", save_state)

-- Frame-rate choice (from the prompt, the F menu or a script message). "off" = play original.
local function set_choice(choice, quiet)
    if choice == "off" then
        S.enabled = false
        remove()
        sync_ui()
    else
        S.choice, S.enabled = choice, true
        save_prefs()
        retarget()
    end
    if quiet then return end
    local t = target()
    if t then
        notice("Frame rate: " .. fps.fmt(S.src_num / S.src_den) .. " → " .. fps.fmt(t) .. " fps", 3, "info")
    elseif not S.enabled then
        notice("Interpolation off", 2, "info")
    end
end
mp.register_script_message("set-fps", function(choice) set_choice(choice) end)
mp.register_script_message("toggle", function()
    if S.enabled then set_choice("off") else set_choice(S.choice) end
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

-- Menu rows shared by the before-playback prompt and the F menu. `val(choice)` makes each row's value.
local function fps_items(src_num, src_den, cap, val)
    local items = { header("Multiply") }
    local fixed_started = false
    for _, op in ipairs(fps.options(src_num, src_den, cap)) do
        local is_fixed = op.choice:sub(1, 1) ~= "x"
        if is_fixed and not fixed_started then
            items[#items + 1] = header("Fixed")
            fixed_started = true
        end
        local t = op.num / op.den
        items[#items + 1] = {
            title = is_fixed and (op.choice .. " fps") or (op.choice:sub(2) .. "×"),
            hint = (not is_fixed and fps.fmt(t) .. " fps") or (math.abs(t - cap) < 0.5 and "matches display") or nil,
            value = val(op.choice),
            active = S.enabled and op.choice == S.choice or nil,
        }
    end
    return items
end

mp.add_key_binding("F", "fps-menu", function()
    if not S.src_num then return notice("Open a video first", 2, "info") end
    local cap = fps.cap(mp.get_property_number("display-fps"))
    local items = fps_items(S.src_num, S.src_den, cap,
        function(c) return { "script-message-to", "framegen", "set-fps", c } end)
    items[#items].separator = true
    items[#items + 1] = { title = "Custom…", hint = "type a value", value = "script-message-to framegen fps-custom" }
    local t, lv = target()
    items[#items + 1] = {
        title = "Interpolation", value = "script-message-to framegen toggle",
        icon = S.enabled and "toggle_on" or "toggle_off",
        hint = (not S.enabled and "off") or (t and LADDER[lv.rife].label) or (S.building and "preparing…")
            or "on · not running",
    }
    mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json({
        type = "framegen_fps", title = "Frame rate", items = items, search_style = "disabled",
        footnote = "Source " .. fps.fmt(S.src_num / S.src_den) .. " fps · Display " .. cap .. " Hz",
    }))
end)

-- Before-playback prompts. Each one pauses mpv's file loading (hook:defer) until answered,
-- dismissed, or PROMPT_TIMEOUT passes, so loading can never hang.
local prompt  -- { done = fn, timer = timer }
local function finish_prompt()
    if not prompt then return end
    local p = prompt
    prompt = nil
    if p.timer then p.timer:kill() end
    p.done()
end
local function open_prompt(menu, done)
    finish_prompt()
    menu.type = "framegen_prompt"
    menu.callback = { mp.get_script_name(), "prompt-event" }
    menu.search_style = "disabled"
    prompt = { done = done, timer = mp.add_timeout(PROMPT_TIMEOUT, finish_prompt) }
    mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json(menu))
end
mp.register_script_message("prompt-event", function(json)
    local e = utils.parse_json(json) or {}
    if e.type == "activate" and type(e.value) == "string" then
        local kind, v = e.value:match("^(%a+):(.+)$")
        if kind == "q" then
            S.quality = v
            save_prefs()
        elseif kind == "f" then
            set_choice(v, true)
        end
        mp.commandv("script-message-to", "uosc", "close-menu", "framegen_prompt")
    elseif e.type == "close" then
        finish_prompt()
    end
end)

local function ytdl_format(q)
    local h = q == "auto" and AUTO_MAX_HEIGHT or tonumber(q)
    return "bestvideo[height<=?" .. h .. "]+bestaudio/best"
end
local function is_url(p) return p ~= nil and (p:find("^https?://") or p:find("^ytdl://")) ~= nil end
local function asking() return o.ask and S.uosc end

-- YouTube quality: asked before yt-dlp runs (ytdl_hook is on_load priority 10) and applied as a
-- file-local option, so switching quality later from uosc's menu still works.
mp.add_hook("on_load", 5, function(hook)
    local path = mp.get_property("path")
    if not (asking() and is_url(path)) then return end
    -- The same URL reloading right away is a quality switch from uosc's menu: keep the answers.
    if path == S.last_url and mp.get_time() - (S.ended_at or -1e9) < 15 then return end
    S.last_url = path
    hook:defer()
    local items = {}
    for _, q in ipairs(QUALITIES) do
        items[#items + 1] = {
            title = q == "auto" and "Auto" or (q .. "p"),
            hint = q == "auto" and ("best up to " .. AUTO_MAX_HEIGHT .. "p") or nil,
            value = "q:" .. q, active = q == S.quality or nil,
        }
    end
    open_prompt({ title = "Video quality", items = items, footnote = "Picks the closest available stream" },
        function()
            mp.set_property("file-local-options/ytdl-format", ytdl_format(S.quality))
            msg.info("quality " .. S.quality .. " -> ytdl-format " .. ytdl_format(S.quality))
            hook:cont()
        end)
end)

-- Frame rate: asked once the demuxer knows the source fps, before decoding starts.
mp.add_hook("on_preloaded", 50, function(hook)
    if not asking() then return end
    local path = mp.get_property("path")
    if is_url(path) and S.last_fps_url == path and mp.get_time() - (S.ended_at or -1e9) < 15 then return end
    local track
    for _, t in ipairs(mp.get_property_native("track-list") or {}) do
        if t.type == "video" and (not track or t.selected) then track = t end
    end
    local n, d
    if track then n, d = fps.snap(track["demux-fps"]) end
    if not n then return end
    if is_url(path) then S.last_fps_url = path end
    local cap = fps.cap(mp.get_property_number("display-fps"))
    local items = fps_items(n, d, cap, function(c) return "f:" .. c end)
    items[#items].separator = true
    items[#items + 1] = { title = "Play original", hint = fps.fmt(n / d) .. " fps, no interpolation",
        value = "f:off", active = not S.enabled or nil }
    hook:defer()
    open_prompt({
        title = "Frame rate for this video", items = items,
        footnote = "Source " .. fps.fmt(n / d) .. " fps · Display " .. cap .. " Hz · F changes it later",
    }, function() hook:cont() end)
end)

-- Debug overlay (toggle with D).
local ov = mp.create_osd_overlay("ass-events")
ov.res_x, ov.res_y = 1280, 720
local ov_timer, vram_timer
local function draw()
    local w, h = video_size()
    local t, lv = target()
    ov.data = overlay.render({
        src_res = w and size_label(w, h),
        src_fps = S.src_num and S.src_num / S.src_den,
        target_fps = t,
        real_fps = S.real_fps,
        display_fps = mp.get_property_number("display-fps"),
        measured_display_fps = mp.get_property_number("estimated-display-fps"),
        level_label = lv and LADDER[lv.rife].label or "interpolation off",
        backend = "TensorRT",
        auto_level = S.auto and S.auto.level, auto_total = S.levels and #S.levels,
        drops = mp.get_property_number("frame-drop-count"),
        delayed = mp.get_property_number("vo-delayed-frame-count"),
        vram_mb = S.vram_mb, gpu_mhz = S.gpu_mhz, gpu_max_mhz = S.gpu_max_mhz, gpu_pstate = S.gpu_pstate,
        seek_ms = S.seek_ms, hist = S.hist,
    })
    ov:update()
end
local function poll_vram()
    mp.command_native_async({
        name = "subprocess", playback_only = false, capture_stdout = true,
        args = { "nvidia-smi", "--query-gpu=memory.used,clocks.sm,clocks.max.sm,pstate", "--format=csv,noheader,nounits" },
    }, function(ok, res)
        local mem, clk, max, ps = (ok and res.stdout or ""):match("(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*,%s*(P%d+)")
        S.vram_mb, S.gpu_mhz, S.gpu_max_mhz, S.gpu_pstate = tonumber(mem), tonumber(clk), tonumber(max), ps
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
    local state = (S.building and "building") or (ref_ready() and "ready") or "missing"
    ov_idle.res_x, ov_idle.res_y = w, h
    ov_idle.data, idle_boxes = overlay.idle(w, h, state)
    ov_idle:update()
    mp.add_forced_key_binding("MBTN_LEFT", "fg-idle-click", idle_click)
end
mp.observe_property("idle-active", "bool", draw_idle)
mp.observe_property("osd-dimensions", "native", function() draw_idle() end)

-- First launch: build + measure every level at the reference size before any video needs it.
ensure_ref()
sync_ui()
