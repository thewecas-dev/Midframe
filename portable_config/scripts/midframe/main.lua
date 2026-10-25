-- Midframe (script id "midframe"): wires RIFE interpolation (vs/rife.vpy) into mpv with the UI v2 surfaces
-- (home, setup sheet, fps quick menu, settings, debug overlay), per-resolution TensorRT engines built on demand,
-- auto step-down, failure fallback and crash-resume state.
local mp = require "mp"
local utils = require "mp.utils"
local msg = require "mp.msg"
local input = require "mp.input"
local fps = require "fps"
local auto = require "auto"
local ui = require "ui"
local overlay = require "overlay"
local sheet = require "sheet"
local home = require "home"
local settings = require "settings"

local o = {
    enabled = true,
    choice = "x2",       -- default frame-rate choice (overridden by the last pick, see PREFS)
    quality = "auto",    -- default YouTube quality: auto | 2160 | 1440 | 1080 | 720 | 480
    ask = true,          -- ask quality/frame rate before each video starts (per kind in PREFS)
    anime = true,
    python = "~~exe_dir/vs-runtime/python.exe",
    engines = "~~/engines",
}
require("mp.options").read_options(o, "midframe")

local function expand(p) return mp.command_native({ "expand-path", p }) end

local VERSION = "0.2.0"
local VPY = expand("~~/vs/rife.vpy")
local BUILDER = expand("~~/vs/build_engines.py")
local ENGINES = expand(o.engines)
local STATE_FILE = expand("~~/midframe-last.json")
local PREFS = expand("~~/midframe-prefs.json")
local RECENT = expand("~~/midframe-recent.json")
local ERROR_LOG = expand("~~/midframe-error.log")
local REF_W, REF_H = 1920, 1080  -- reference size: every level is built + measured here at setup
local PROMPT_TIMEOUT = 120       -- seconds before an unanswered sheet lets playback continue
local SIZES = { { "720p", 1280, 720 }, { "1080p", 1920, 1080 }, { "1440p", 2560, 1440 }, { "4K", 3840, 2160 } }
local QUALITY_SIZE = { ["2160"] = { 3840, 2160 }, ["1440"] = { 2560, 1440 }, ["1080"] = { 1920, 1080 }, ["720"] = { 1280, 720 }, ["480"] = { 854, 480 } }
local CHOICES = { "x1.5", "x2", "x2.5", "x3", "60", "72", "90", "120", "144" }
local HEADROOMS = { 1.2, 1.5, 2 }

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

local LADDER = assert(read_json(expand("~~/vs/ladder.json")), "midframe: vs/ladder.json missing")
local MATRIX = { ["bt.709"] = "709", ["bt.601"] = "170m", ["bt.2020-ncl"] = "2020ncl" }
local prefs = read_json(PREFS) or {}
local function pref(k, default) if prefs[k] == nil then return default end return prefs[k] end

local S = {
    enabled = o.enabled, choice = pref("choice", o.choice), quality = pref("quality", o.quality),
    ask_yt = pref("ask_yt", o.ask), ask_local = pref("ask_local", o.ask), anime = pref("anime", o.anime),
    even = pref("even", true), headroom = pref("headroom", auto.HEADROOM), audio_delay = pref("audio_delay", 0),
    added = false, debug = false, builds = {}, building = nil,
    hist = { real_fps = {}, drops = {}, vram = {} },
    recents = read_json(RECENT) or {},
    checks = {},  -- gpu_pref = true|false|nil, refresh = true|false|nil
}
auto.HEADROOM = S.headroom

local function save_prefs()
    write_json(PREFS, { choice = S.choice, quality = S.quality, ask_yt = S.ask_yt, ask_local = S.ask_local,
        anime = S.anime, even = S.even, headroom = S.headroom, audio_delay = S.audio_delay })
end

local function osd_size()
    local d = mp.get_property_native("osd-dimensions") or {}
    return (d.w and d.w > 0) and d.w or 1280, (d.h and d.h > 0) and d.h or 720
end
-- Everything is drawn in design units (1440x900) and scaled to the window through the overlay resolution.
-- Scale follows the Windows display scaling and the window size, but never shrinks text below ~90% of the
-- design: a small window gets a narrower canvas (layouts reflow on W/H), not a tiny one.
local function design_size()
    local w, h = osd_size()
    local dpi = mp.get_property_number("display-hidpi-scale") or 1
    local s = 1.15 * dpi * math.max(0.9, math.min(2, math.min(w / ui.W, h / ui.H)))  -- 1.15: comfortable from a couch
    s = math.min(s, w / 980, h / 600)  -- keep at least 980x600 design units so the sheet and home still fit
    s = math.max(s, 0.5)
    return math.floor(w / s + 0.5), math.floor(h / s + 0.5), s
end
-- Height of uosc's bottom bar in design units (timeline + controls), so popovers sit above it.
local function bar_height()
    local _, _, s = design_size()
    local dpi = mp.get_property_number("display-hidpi-scale") or 1
    return math.floor(96 * dpi / s + 0.5)
end

-- Notices: one styled pill at the top centre.
local ov_toast = mp.create_osd_overlay("ass-events")
local toast_timer
local function notice(text, secs, kind)
    local W, H = design_size()
    ov_toast.res_x, ov_toast.res_y = W, H
    ov_toast.data = overlay.toast(W, text, kind)
    ov_toast:update()
    if toast_timer then toast_timer:kill() end
    toast_timer = mp.add_timeout(secs or 4, function() ov_toast:remove() end)
end

local function remove()
    if S.added then mp.commandv("vf", "remove", "@midframe") end
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
local function cal_count(w, h) local n = 0 for _ in pairs(cal(w, h)) do n = n + 1 end return n end
local function ref_ready() return cal_count(REF_W, REF_H) >= #LADDER end

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
local function is_url(p) return p ~= nil and (p:find("^https?://") or p:find("^ytdl://")) ~= nil end
local function cap() return fps.cap(mp.get_property_number("display-fps")) end

local function set_button(name, t) mp.commandv("script-message-to", "uosc", "set-button", name, utils.format_json(t)) end

-- Keep uosc's buttons and the top-bar status line in sync.
local function sync_ui()
    local t, lv = target()
    local src = S.src_num and fps.fmt(S.src_num / S.src_den)
    set_button("midframe_fps", {
        icon = "bolt", active = t ~= nil, badge = t and string.format("%d", math.floor(t + 0.5)) or nil,
        tooltip = t and ("Frame rate: " .. src .. " → " .. fps.fmt(t) .. " fps (F)") or "Frame rate (F)",
        command = "script-binding midframe/fps-menu",
    })
    local w, h = video_size()
    set_button("midframe_quality", {
        icon = "high_quality", badge = h and tostring(h) or nil, tooltip = h and (h .. "p · quality and frame rate") or "Quality and frame rate",
        command = "script-binding midframe/setup",
    })
    set_button("midframe_debug", { icon = "show_chart", active = S.debug, tooltip = "Debug overlay (D)", command = "script-binding midframe/debug" })
    set_button("midframe_settings", { icon = "settings", tooltip = "Settings (Ctrl+,)", command = "script-binding midframe/settings" })
    set_button("midframe_play", { icon = mp.get_property_bool("pause") and "play_arrow" or "pause", tooltip = "Play / pause (Space)", command = "cycle pause" })
    local status = ""
    if w and src then
        local title = mp.get_property("media-title")
        status = (title and (ui.fit(title, 13, 520) .. "   ·   ") or "") .. size_label(w, h) .. " · " .. src .. " fps"
        if t then
            status = status .. " → " .. fps.fmt(t) .. " fps · " .. LADDER[lv.rife].label
        elseif S.building then
            status = status .. " · preparing " .. (S.building.level and LADDER[S.building.level].label or "RIFE") .. "…"
        else
            status = status .. " · interpolation off"
        end
    end
    mp.set_property_native("user-data/midframe/status", status)
end

local apply, draw_home, retarget, modal_redraw

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
    draw_home(); modal_redraw(); sync_ui()
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
        draw_home(); modal_redraw()
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
        num = step.num, den = step.den, level = lv.rife, anime = S.anime,
        engines = ENGINES, matrix = S.matrix, range = S.range,
    })
    S.added = true
    mp.commandv("vf", "add", "@midframe:vapoursynth=file=" .. quoted(VPY) ..
        ":buffered-frames=8:concurrent-frames=8:user-data=" .. quoted(json))
    sync_ui()
end

retarget = function()
    if not S.src_num then return end
    local tn, td = fps.resolve(S.choice, S.src_num, S.src_den, cap())
    if not tn then
        msg.info("no interpolation: " .. tostring(td))  -- td carries the reason when tn is nil
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

-- ---------- recents ----------
local function save_recents() write_json(RECENT, S.recents) end
local function recent_upsert(path, fields)
    if not path then return end
    local r
    for i, x in ipairs(S.recents) do if x.path == path then r = table.remove(S.recents, i); break end end
    r = r or { path = path }
    for k, v in pairs(fields) do r[k] = v end
    table.insert(S.recents, 1, r)
    while #S.recents > 12 do table.remove(S.recents) end
    save_recents()
end
local function join(parts, sep)  -- table.concat that skips nils
    local out = {}
    for i = 1, 8 do if parts[i] then out[#out + 1] = parts[i] end end
    return table.concat(out, sep or " · ")
end
local function fmt_dur(sec)
    if not sec or sec <= 0 then return nil end
    sec = math.floor(sec + 0.5)
    local h, m = math.floor(sec / 3600), math.floor(sec % 3600 / 60)
    if h > 0 then return string.format("%dh %02dm", h, m) end
    return string.format("%dm %02ds", m, sec % 60)
end
local function recent_meta(r)
    local where = is_url(r.path) and (r.path:match("^https?://([^/]+)") or "link"):gsub("^www%.", "") or (r.path:match("^(.*)[/\\]") or "")
    local parts = { ui.fit(where, 11, 160) }
    if r.duration then parts[#parts + 1] = fmt_dur(r.duration) end
    if r.fps then parts[#parts + 1] = r.fps .. " fps" end
    return table.concat(parts, " · ")
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
    recent_upsert(mp.get_property("path"), { fps = fps.fmt(n / d) })
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
mp.register_event("file-loaded", function()
    local path = mp.get_property("path")
    recent_upsert(path, { title = mp.get_property("media-title") or path, duration = mp.get_property_number("duration") })
    mp.set_property_number("audio-delay", (S.audio_delay or 0) / 1000)
    sync_ui()
end)
mp.observe_property("pause", "bool", function() sync_ui() end)
mp.register_script_message("uosc-version", function() sync_ui() end)

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
        notice("Interpolation turned off: " .. line .. " (details: portable_config\\midframe-error.log)", 8, "bad")
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

-- Auto mode + overlay history + display check, once a second.
local last_drops, playing_since = 0, nil
mp.add_periodic_timer(1, function()
    local drops = mp.get_property_number("frame-drop-count", 0)
    local delayed = mp.get_property_number("vo-delayed-frame-count", 0)
    local vf_fps = mp.get_property_number("estimated-vf-fps")
    local dps = math.max(0, drops - last_drops)
    last_drops = drops
    S.real_fps = vf_fps and math.max(0, vf_fps - dps)
    push(S.hist.real_fps, S.real_fps or 0)
    push(S.hist.drops, dps)
    -- refresh-rate check: the measured vsync rate should sit on the nominal one once playback has settled
    if mp.get_property("path") and not mp.get_property_bool("pause") then
        playing_since = playing_since or mp.get_time()
        local nominal, measured = mp.get_property_number("display-fps"), mp.get_property_number("estimated-display-fps")
        if nominal and measured and measured > 1 and mp.get_time() - playing_since > 8 then
            S.checks.refresh = math.abs(nominal - measured) < 2
            S.checks.refresh_detail = string.format("%.0f Hz nominal, %.1f measured", nominal, measured)
        end
    else
        playing_since = nil
    end

    local t = target()
    if not t or mp.get_property_bool("pause") then return end
    local action = auto.tick(S.auto, { drops = drops, delayed = delayed, vf_fps = vf_fps, target = t }, mp.get_time())
    if not action then return end
    local lv = current()
    if lv.off then
        notice("Too heavy for real-time: playing original fps", 5, "warn")
    else
        notice("Stepped down to " .. LADDER[lv.rife].label .. " to stay smooth", 4, "warn")
    end
    apply()
end)

-- Crash-resume state for the launcher + resume position for recents.
local function save_state()
    local path = mp.get_property("path")
    if not path then return end
    local pos = mp.get_property_number("time-pos", 0)
    write_json(STATE_FILE, { path = path, pos = pos })
    for _, r in ipairs(S.recents) do
        if r.path == path then r.pos, r.duration = pos, mp.get_property_number("duration") or r.duration; save_recents(); break end
    end
end
mp.add_periodic_timer(5, save_state)
mp.register_event("shutdown", save_state)

-- Frame-rate choice (from the sheet, the quick menu or a script message). "off" = play original.
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

-- ---------- quality (YouTube formats are loaded as tracks: ytdl_hook-all_formats=yes) ----------
local function video_tracks()
    local out = {}
    for _, t in ipairs(mp.get_property_native("track-list") or {}) do
        if t.type == "video" then out[#out + 1] = t end
    end
    return out
end
local function height_of(t) return t["demux-h"] or 0 end
-- Pick the track for a quality value: highest height <= wanted (auto = AUTO_MAX_HEIGHT), else the lowest.
local function track_for(q)
    local want = q == "auto" and sheet.AUTO_MAX_HEIGHT or tonumber(q)
    local best, lowest
    for _, t in ipairs(video_tracks()) do
        local h = height_of(t)
        if h <= want + 20 and (not best or h > height_of(best)) then best = t end
        if not lowest or h < height_of(lowest) then lowest = t end
    end
    return best or lowest
end
local function available_qualities()
    local hs = {}
    for _, t in ipairs(video_tracks()) do hs[#hs + 1] = height_of(t) end
    local items = {}
    for _, q in ipairs(sheet.QUALITIES) do
        local ok = q.value == "auto"
        for _, h in ipairs(hs) do if math.abs(h - (tonumber(q.value) or 0)) <= (tonumber(q.value) or 0) * 0.12 then ok = true end end
        items[#items + 1] = { value = q.value, label = q.label, muted = not ok }
    end
    local max = 0
    for _, h in ipairs(hs) do max = math.max(max, h) end
    return items, max
end
local function apply_quality()
    local t = track_for(S.quality)
    if t and #video_tracks() > 1 then mp.set_property_number("vid", t.id) end
end

-- ---------- modal overlays (one at a time): home | sheet | quick | settings ----------
local Modal = { ov = mp.create_osd_overlay("ass-events"), kind = nil, scale = 1, canvas = nil }
local KEYS = { "ESC", "ENTER", "KP_ENTER", "BS", "LEFT", "RIGHT", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", ".", "KP_DEC" }
local handle_action  -- forward
local function mouse_design()
    local m = mp.get_property_native("mouse-pos") or {}
    return (m.x or -1) / Modal.scale, (m.y or -1) / Modal.scale
end
local function modal_unbind()
    mp.remove_key_binding("mf-click"); mp.remove_key_binding("mf-rclick")
    for _, k in ipairs(KEYS) do mp.remove_key_binding("mf-key-" .. k) end
end
local function modal_close()
    if not Modal.kind then return end
    local kind = Modal.kind
    Modal.kind, Modal.build, Modal.canvas = nil, nil, nil
    Modal.ov:remove()
    modal_unbind()
    if kind ~= "home" then draw_home() end  -- the home screen may be underneath
end
modal_redraw = function()
    if not Modal.kind then return end
    local W, H, s = design_size()
    Modal.scale = s
    Modal.ov.res_x, Modal.ov.res_y = W, H
    Modal.canvas = Modal.build(W, H)
    Modal.ov.data = Modal.canvas:render()
    Modal.ov:update()
end
local function modal_show(kind, build)
    if Modal.kind and Modal.kind ~= kind then modal_unbind() end
    Modal.kind, Modal.build = kind, build
    modal_redraw()
    mp.add_forced_key_binding("MBTN_LEFT", "mf-click", function()
        local x, y = mouse_design()
        local a = Modal.canvas and Modal.canvas:hit(x, y)
        if a and a.kind ~= "none" then handle_action(a) end
    end)
    mp.add_forced_key_binding("MBTN_RIGHT", "mf-rclick", function()
        local x, y = mouse_design()
        local a = Modal.canvas and Modal.canvas:hit(x, y)
        if a and a.kind == "recent" then handle_action({ kind = "recent_remove", index = a.index }) end
    end)
    if kind ~= "home" then
        for _, k in ipairs(KEYS) do
            mp.add_forced_key_binding(k, "mf-key-" .. k, function() handle_action({ kind = "key", key = k }) end, { repeatable = true })
        end
    end
end
mp.observe_property("osd-dimensions", "native", function() modal_redraw() end)

-- ---------- setup sheet ----------
local SH  -- { kind, title, meta, hook, custom = {text, valid, focus}, src_num, src_den, w, h, timer }
local function sheet_dims()
    if SH.w then return SH.w, SH.h end
    local q = S.quality == "auto" and "1440" or S.quality
    local sz = QUALITY_SIZE[q] or QUALITY_SIZE["1080"]
    if SH.max_h and SH.max_h > 0 then
        local best = QUALITY_SIZE["480"]
        for _, s in pairs(QUALITY_SIZE) do if s[2] <= math.min(sz[2], SH.max_h) + 20 and s[2] > best[2] then best = s end end
        sz = best
    end
    return sz[1], sz[2]
end
local function sheet_args()
    local w, h = sheet_dims()
    return { src_num = SH.src_num, src_den = SH.src_den, cap = cap(), exact = cal(w, h), ref = cal(REF_W, REF_H),
        ref_w = REF_W, ref_h = REF_H, w = w, h = h, ladder = LADDER }
end
local function custom_valid(text)
    if not SH or text == "" then return false end
    return sheet.resolve(text, sheet_args()) ~= nil
end
local function sheet_finish()
    if not SH then return end
    local sh = SH
    SH = nil
    if sh.timer then sh.timer:kill() end
    modal_close()
    if sh.hook then sh.hook:cont() end
end
-- Even-rate preference: when the saved choice isn't even on this display, pre-select the nearest even one.
local function prefer_even(a)
    if not S.even then return end
    local r = sheet.resolve(S.choice, a)
    local even = sheet.rates(a)
    if not r or #even == 0 then return end
    local cur = r.num / r.den
    for _, e in ipairs(even) do if math.abs(e.num / e.den - cur) < 0.5 then return end end
    local best
    for _, e in ipairs(even) do
        if e.state ~= "muted" and (not best or math.abs(e.num / e.den - cur) < math.abs(best.num / best.den - cur)) then best = e end
    end
    if best then S.choice = best.choice end
end
local function sheet_model(W, H)
    local a = sheet_args()
    local even, other = sheet.rates(a)
    local choice = SH.custom.valid and SH.custom.text or S.choice
    local r = sheet.resolve(choice, a)
    local p = sheet.preview(r, a)
    local qualities, quality_label
    if SH.kind == "yt" then
        qualities = SH.qualities
        local _, h = sheet_dims()
        quality_label = h .. "p"
    end
    return sheet.render({
        kind = SH.kind, title = SH.title, meta = SH.meta, quality = S.quality, qualities = qualities, quality_label = quality_label,
        quality_note = "Auto picks the best stream up to " .. sheet.AUTO_MAX_HEIGHT .. "p. Higher qualities need more GPU for the same frame rate.",
        choice = choice, custom = SH.custom, even = even, other = other, preview = p,
        remember = SH.kind == "yt" and not S.ask_yt or SH.kind == "local" and not S.ask_local,
        remember_label = SH.kind == "yt" and "Don't ask again for YouTube" or "Don't ask again for local files",
        src_label = fps.fmt(SH.src_num / SH.src_den), cap = a.cap,
        play_label = r and ("Play at " .. fps.fmt(math.floor(r.num / r.den + 0.5)) .. " fps") or "Play",
        original_label = "Play original", W = W, H = H,
    })
end
local function open_sheet(kind, hook)
    local track
    for _, t in ipairs(video_tracks()) do if not track or t.selected then track = t end end
    local n, d = fps.snap(track and track["demux-fps"])
    if not n then return false end
    local path = mp.get_property("path") or ""
    local title = mp.get_property("media-title") or path:match("[^/\\]+$") or path
    local dur = fmt_dur(mp.get_property_number("duration"))
    local meta
    SH = { kind = kind, hook = hook, src_num = n, src_den = d, custom = { text = "", valid = false, focus = false } }
    if kind == "yt" then
        local items, max_h = available_qualities()
        SH.qualities, SH.max_h = items, max_h
        local host = (path:match("^https?://([^/]+)") or "link"):gsub("^www%.", "")
        meta = join({ host:find("youtu") and "YouTube" or host, dur, "source " .. fps.fmt(n / d) .. " fps",
            max_h > 0 and ("up to " .. max_h .. "p") or nil })
    else
        SH.w, SH.h = track and track["demux-w"], track and track["demux-h"]
        local codec = track and track.codec and track.codec:upper():gsub("HEVC", "HEVC"):gsub("H264", "H.264") or nil
        meta = join({ ui.fit(path:match("^(.*)[/\\]") or "", 13, 220), dur,
            SH.w and size_label(SH.w, SH.h) or nil, fps.fmt(n / d) .. " fps", codec })
    end
    SH.title, SH.meta = title, meta
    prefer_even(sheet_args())
    if hook then SH.timer = mp.add_timeout(PROMPT_TIMEOUT, sheet_finish) end
    modal_show("sheet", sheet_model)
    return true
end

-- ---------- quick menu ----------
local function quick_model(W, H)
    local w, h = video_size()
    local a = { src_num = S.src_num, src_den = S.src_den, cap = cap(), exact = cal(w or REF_W, h or REF_H), ref = cal(REF_W, REF_H),
        ref_w = REF_W, ref_h = REF_H, w = w, h = h, ladder = LADDER }
    local even, other = sheet.rates(a)
    local t = target()
    return sheet.quick({ even = even, other = other, choice = S.choice, custom = S.qcustom, enabled = S.enabled,
        src_label = fps.fmt(S.src_num / S.src_den), target_label = t and (fps.fmt(t) .. " fps") or "original",
        cap = a.cap, W = W, H = H, bottom = H - bar_height() })
end

-- ---------- settings ----------
local TAB = "playback"
local function label_choice(c)
    if c:sub(1, 1) == "x" then return c:sub(2) .. "× source" end
    return c .. " fps"
end
local function label_quality(q) return q == "auto" and ("Auto · up to " .. sheet.AUTO_MAX_HEIGHT .. "p") or (q .. "p") end
local function engines_model()
    local out = {}
    for _, s in ipairs(SIZES) do
        local c = cal(s[2], s[3])
        local n = 0
        local vals = {}
        for i = 1, #LADDER do if c[i] then n = n + 1; vals[i] = string.format("%d", math.floor(c[i] + 0.5)) end end
        local state = (S.building and S.building.w == s[2] and S.building.h == s[3]) and "building"
            or (n >= #LADDER and "ready") or (n > 0 and "partial") or "none"
        out[#out + 1] = { name = s[1], dim = size_label(s[2], s[3]), w = s[2], h = s[3], state = state, count = n, vals = n > 0 and vals or nil }
    end
    return out
end
local function checks_model()
    local function tri(v, yes, no, unknown) if v == true then return yes elseif v == false then return no end return unknown end
    return {
        { label = "mpv.exe set to High performance GPU", ok = S.checks.gpu_pref,
          hint = tri(S.checks.gpu_pref, "", "Settings → System → Display → Graphics → add mpv.exe → High performance", "Could not read the Windows graphics preference") },
        { label = "Fixed refresh rate, G-SYNC off", ok = S.checks.refresh,
          hint = tri(S.checks.refresh, S.checks.refresh_detail or "", (S.checks.refresh_detail or "") .. " · variable refresh: turn off G-SYNC and the Dynamic refresh rate",
              "Measured while a video plays") },
        { label = "RIFE engines for 1080p", ok = ref_ready(), hint = ref_ready() and "" or "Built on first launch; see the Engines tab" },
        { label = S.gpu_name and ("GPU: " .. S.gpu_name) or "NVIDIA driver", ok = S.gpu_name ~= nil and true or nil,
          hint = S.driver and ("driver " .. S.driver) or "nvidia-smi did not answer" },
    }
end
local function settings_model(W, H)
    return settings.render({
        W = W, H = H, tab = TAB, ladder = LADDER,
        playback = { ask_yt = S.ask_yt, ask_local = S.ask_local, rate_label = label_choice(S.choice), quality_label = label_quality(S.quality),
            anime = S.anime, even = S.even, headroom_label = string.format("%.1f×", S.headroom) .. (S.headroom == 1.5 and " (recommended)" or ""),
            audio_label = string.format("%d ms", S.audio_delay or 0) },
        engines = engines_model(), checks = checks_model(),
        keys = { { "Ctrl+O", "Open a file" }, { "Ctrl+V", "Play the link in the clipboard" }, { "F", "Frame-rate menu" },
            { "D", "Debug overlay" }, { "Ctrl+,", "Settings" }, { "Space", "Play / pause" }, { "← →", "Seek 5 s" }, { "f", "Fullscreen" },
            { "Ctrl+− / Ctrl++", "Audio offset ±100 ms" } },
        version = "Midframe " .. VERSION .. " · TensorRT",
    })
end
local function cycle(list, cur, eq)
    for i, v in ipairs(list) do if (eq and eq(v, cur)) or v == cur then return list[i % #list + 1] end end
    return list[1]
end

-- ---------- home ----------
local function home_model(W, H)
    local status
    if S.building then status = { label = "Preparing RIFE engines…", tone = "warn" }
    elseif ref_ready() then status = { label = "RIFE ready" .. (S.gpu_name and (" · " .. S.gpu_name) or "") .. " · " .. cap() .. " Hz", tone = "good" }
    else status = { label = "RIFE not prepared yet", tone = "warn" } end
    local recents = {}
    for _, r in ipairs(S.recents) do
        recents[#recents + 1] = { title = r.title or r.path, meta = recent_meta(r), fps = r.fps and (r.fps .. " fps") or nil,
            progress = (r.pos and r.duration and r.duration > 0) and r.pos / r.duration or 0 }
    end
    local ready = {}
    for _, s in ipairs(SIZES) do if cal_count(s[2], s[3]) > 0 then ready[#ready + 1] = s[1] end end
    local strip = {
        "Engines: " .. (#ready > 0 and (table.concat(ready, ", ") .. " ready · others build on first play") or "building on first launch"),
        "GPU: " .. (S.checks.gpu_pref == true and "high performance ✓" or S.checks.gpu_pref == false and "not set to high performance !" or "preference unknown"),
        "Display: " .. (S.checks.refresh == true and ("fixed " .. cap() .. " Hz ✓") or S.checks.refresh == false and "variable refresh !" or (cap() .. " Hz · checked during playback")),
    }
    return home.render({ W = W, H = H, status = status, recents = recents, url = S.url_text, url_focus = S.url_focus, strip = strip, version = "v" .. VERSION })
end
draw_home = function()
    local idle = mp.get_property_bool("idle-active")
    if not idle then
        if Modal.kind == "home" then modal_close() end
        return
    end
    if Modal.kind == nil or Modal.kind == "home" then modal_show("home", home_model) end
end
mp.observe_property("idle-active", "bool", draw_home)

-- ---------- opening files / links ----------
local function play_path(path, pos)
    if not path or path == "" then return end
    if pos and pos > 5 then mp.commandv("loadfile", path, "replace", "start=" .. string.format("%.1f", pos))
    else mp.commandv("loadfile", path, "replace") end
end
local function open_file_dialog()
    local ps = "Add-Type -AssemblyName System.Windows.Forms; $d = New-Object System.Windows.Forms.OpenFileDialog; " ..
        "$d.Title = 'Open video'; $d.Filter = 'Video files|*.mkv;*.mp4;*.m4v;*.webm;*.mov;*.avi;*.ts;*.m2ts;*.wmv;*.flv;*.mpg|All files|*.*'; " ..
        "if ($d.ShowDialog() -eq 'OK') { [Console]::Out.Write($d.FileName) }"
    ps = ps:gsub("%$d%.ShowDialog%(%)", "$d.ShowDialog((New-Object System.Windows.Forms.Form -Property @{TopMost = $true}))")
    mp.command_native_async({ name = "subprocess", playback_only = false, capture_stdout = true,
        args = { "powershell", "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-STA", "-Command", ps } }, function(ok, res)
        local path = ok and res.stdout and res.stdout:gsub("%s+$", "") or ""
        if path ~= "" then play_path(path) end
    end)
end
local function clipboard_text()
    local t = mp.get_property("clipboard/text")
    return t and t:gsub("^%s+", ""):gsub("%s+$", "") or ""
end
local function play_clipboard()
    if mp.get_property("clipboard/text") == nil then return mp.commandv("script-binding", "uosc/paste") end  -- older mpv
    local t = clipboard_text()
    if t == "" then return notice("Clipboard is empty", 3, "warn") end
    if not (is_url(t) or utils.file_info(t)) then return notice("Clipboard has no link or file path", 3, "warn") end
    play_path(t)
end
local function type_link()
    S.url_focus = true; modal_redraw()
    input.get({
        prompt = "Link:",
        submit = function(text)
            input.terminate()
            S.url_focus = false; S.url_text = nil; modal_redraw()
            if text and text ~= "" then play_path((text:gsub("^%s+", ""):gsub("%s+$", ""))) end
        end,
        closed = function() S.url_focus = false; modal_redraw() end,
    })
end
mp.add_key_binding("ctrl+o", "open-file", open_file_dialog)
mp.add_key_binding("ctrl+v", "paste", play_clipboard)

-- ---------- actions from every surface ----------
handle_action = function(a)
    local kind = Modal.kind
    if kind == "home" then
        if a.kind == "open" then open_file_dialog()
        elseif a.kind == "field" then type_link()
        elseif a.kind == "play_link" then if S.url_text and S.url_text ~= "" then play_path(S.url_text) else play_clipboard() end
        elseif a.kind == "recent" then local r = S.recents[a.index]; if r then play_path(r.path, r.pos) end
        elseif a.kind == "recent_remove" then table.remove(S.recents, a.index); save_recents(); modal_redraw()
        elseif a.kind == "clear" then S.recents = {}; save_recents(); modal_redraw()
        elseif a.kind == "settings" then TAB = "playback"; modal_show("settings", settings_model) end
    elseif kind == "sheet" then
        if not SH then return modal_close() end
        if a.kind == "quality" then
            S.quality = a.value; save_prefs(); apply_quality(); modal_redraw()
        elseif a.kind == "rate" then
            SH.custom = { text = "", valid = false, focus = false }  -- a tile wins over a half-typed custom value
            set_choice(a.choice, true); modal_redraw()
        elseif a.kind == "custom" then
            SH.custom.focus = true; modal_redraw()
        elseif a.kind == "remember" then
            if SH.kind == "yt" then S.ask_yt = not S.ask_yt else S.ask_local = not S.ask_local end
            save_prefs(); modal_redraw()
        elseif a.kind == "original" then
            set_choice("off", true); sheet_finish()
        elseif a.kind == "play" or (a.kind == "key" and (a.key == "ENTER" or a.key == "KP_ENTER")) then
            if SH.custom.valid then set_choice(SH.custom.text, true) end
            if SH.custom.focus and not SH.custom.valid and SH.custom.text ~= "" then return notice("That frame rate is out of range", 3, "bad") end
            sheet_finish()
        elseif a.kind == "close" or (a.kind == "key" and a.key == "ESC") then
            sheet_finish()
        elseif a.kind == "key" then
            if not SH.custom.focus then return end
            local k = a.key == "KP_DEC" and "." or a.key
            if k == "BS" then SH.custom.text = SH.custom.text:sub(1, -2)
            elseif #k == 1 and #SH.custom.text < 6 then SH.custom.text = SH.custom.text .. k end
            SH.custom.valid = custom_valid(SH.custom.text)
            modal_redraw()
        end
    elseif kind == "quick" then
        S.qcustom = S.qcustom or { text = "", valid = false, focus = false }
        if a.kind == "rate" then S.qcustom = { text = "", valid = false, focus = false }; set_choice(a.choice, true); modal_redraw()
        elseif a.kind == "toggle" then if S.enabled then set_choice("off", true) else set_choice(S.choice, true) end; modal_redraw()
        elseif a.kind == "custom" then S.qcustom.focus = true; modal_redraw()
        elseif a.kind == "close" or (a.kind == "key" and a.key == "ESC") then S.qcustom = nil; modal_close()
        elseif a.kind == "key" and (a.key == "ENTER" or a.key == "KP_ENTER") then
            if S.qcustom.valid then set_choice(S.qcustom.text, true) end
            S.qcustom = nil; modal_close()
        elseif a.kind == "key" and S.qcustom.focus then
            local k = a.key == "KP_DEC" and "." or a.key
            if k == "BS" then S.qcustom.text = S.qcustom.text:sub(1, -2)
            elseif #k == 1 and #S.qcustom.text < 6 then S.qcustom.text = S.qcustom.text .. k end
            local n = fps.resolve(S.qcustom.text, S.src_num, S.src_den, cap())
            S.qcustom.valid = n ~= nil
            modal_redraw()
        end
    elseif kind == "settings" then
        if a.kind == "tab" then TAB = a.value; modal_redraw()
        elseif a.kind == "toggle" then
            S[a.key] = not S[a.key]; save_prefs()
            if a.key == "anime" and S.added then retarget() end
            modal_redraw()
        elseif a.kind == "cycle" then
            if a.key == "choice" then S.choice = cycle(CHOICES, S.choice); if S.src_num then retarget() end
            elseif a.key == "quality" then
                local vals = {} for _, q in ipairs(sheet.QUALITIES) do vals[#vals + 1] = q.value end
                S.quality = cycle(vals, S.quality)
            elseif a.key == "headroom" then S.headroom = cycle(HEADROOMS, S.headroom, function(v, c) return math.abs(v - c) < 0.01 end); auto.HEADROOM = S.headroom
            elseif a.key == "audio" then
                S.audio_delay = cycle({ -200, -150, -100, -50, 0, 50, 100, 150, 200 }, S.audio_delay or 0)
                mp.set_property_number("audio-delay", S.audio_delay / 1000)
            end
            save_prefs(); modal_redraw()
        elseif a.kind == "prepare" then start_build({ w = a.w, h = a.h }); modal_redraw()
        elseif a.kind == "config" then
            mp.command_native_async({ name = "subprocess", playback_only = false, args = { "explorer", expand("~~/") } }, function() end)
        elseif a.kind == "close" or (a.kind == "key" and a.key == "ESC") then modal_close() end
    end
end

mp.register_script_message("show", function(kind)
    if kind == "home" then modal_show("home", home_model) elseif kind == "settings" then modal_show("settings", settings_model) end
end)
-- Scriptable UI actions (tests, automation): script-message-to midframe action '{"kind":"rate","choice":"x2"}'
mp.register_script_message("action", function(json) local a = utils.parse_json(json); if type(a) == "table" then handle_action(a) end end)

mp.add_key_binding("F", "fps-menu", function()
    if Modal.kind == "quick" then return modal_close() end
    if not S.src_num then return notice("Open a video first", 2, "info") end
    modal_show("quick", quick_model)
end)
mp.add_key_binding(nil, "setup", function()
    if Modal.kind == "sheet" then return sheet_finish() end
    if not mp.get_property("path") then return notice("Open a video first", 2, "info") end
    if not open_sheet(is_url(mp.get_property("path")) and "yt" or "local", nil) then notice("Source frame rate not known yet", 3, "warn") end
end)
mp.add_key_binding("ctrl+,", "settings", function()
    if Modal.kind == "settings" then return modal_close() end
    modal_show("settings", settings_model)
end)

-- Before-playback sheet: once the demuxer knows the tracks (quality list, source fps), before decoding starts.
-- hook:defer() pauses loading until the sheet is answered, dismissed, or PROMPT_TIMEOUT passes.
mp.add_hook("on_preloaded", 50, function(hook)
    local path = mp.get_property("path")
    local url = is_url(path)
    if url then apply_quality() end  -- the remembered quality, before any frame decodes
    if not (url and S.ask_yt or not url and S.ask_local) then return end
    if S.last_prompt_path == path and mp.get_time() - (S.ended_at or -1e9) < 15 then return end  -- immediate reload
    S.last_prompt_path = path
    hook:defer()
    if not open_sheet(url and "yt" or "local", hook) then hook:cont() end
end)

-- Debug overlay (toggle with D).
local ov = mp.create_osd_overlay("ass-events")
local ov_timer, vram_timer
local function draw()
    local W, H = design_size()
    ov.res_x, ov.res_y = W, H
    local w, h = video_size()
    local t, lv = target()
    ov.data = overlay.render({
        res_w = W, res_h = H,
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

-- ---------- system checks (once at start) ----------
local function probe_system()
    mp.command_native_async({ name = "subprocess", playback_only = false, capture_stdout = true,
        args = { "nvidia-smi", "--query-gpu=name,driver_version", "--format=csv,noheader" } }, function(ok, res)
        local name, drv = (ok and res.stdout or ""):match("^%s*([^,\n]-)%s*,%s*([%d%.]+)")
        if name then S.gpu_name, S.driver = name:gsub("^NVIDIA ", ""), drv end
        draw_home()
    end)
    -- Windows per-app GPU preference lives in the registry: GpuPreference=2 means "High performance".
    local exe = expand("~~exe_dir/mpv.exe")
    mp.command_native_async({ name = "subprocess", playback_only = false, capture_stdout = true,
        args = { "reg", "query", "HKCU\\Software\\Microsoft\\DirectX\\UserGpuPreferences" } }, function(ok, res)
        if not ok or not res.stdout or res.status ~= 0 then return end
        local want = exe:lower():gsub("/", "\\")
        local found = false
        for line in res.stdout:gmatch("[^\r\n]+") do
            local l = line:lower()
            if l:find(want, 1, true) then found = l:find("gpupreference=2", 1, true) ~= nil end
        end
        S.checks.gpu_pref = found
        draw_home()
    end)
end

-- First launch: build + measure every level at the reference size before any video needs it.
ensure_ref()
probe_system()
draw_home()
sync_ui()
