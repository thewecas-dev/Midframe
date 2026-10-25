-- Settings drawer (right side). Pure: model in, canvas out.
-- m = { W, H, tab = "playback"|"engines"|"system"|"keys",
--       playback = { ask_yt, ask_local, rate_label, quality_label, anime, even, headroom_label, audio_label },
--       engines = {{ name, dim, w, h, state = "ready"|"partial"|"none"|"building", vals = {..}|nil }}, ladder,
--       checks = {{ label, ok = true|false|nil, hint }}, keys = {{ key, what }}, version }
local ui = require "ui"
local C = ui.C
local M = {}

M.TABS = { { "playback", "Playback" }, { "engines", "Engines" }, { "system", "System" }, { "keys", "Keys" } }
local DW = 460

local function select_box(c, x, y, label, action, right, open)
    local w = ui.textw(label, 13) + 40
    local bx = right and (x - w) or x
    c:rect(bx, y, w, 32, 8, C.raised, 0, open and C.accent or C.border_strong, 1)
    c:text(bx + 12, y + 16, 4, 13, C.text, label, { bold = true })
    ui.icon(c, "chevron", bx + w - 24, y + 8, 16, C.muted)
    c:box(bx, y, w, 32, action)
    c.anchors = c.anchors or {}
    c.anchors[action.key] = { bx, y, w, 32 }
    return w
end

-- Dropdown list for an open select: drawn last (on top, unclipped), opens downward unless it would leave the drawer.
local function dropdown(c, m, H)
    local d = m.dropdown
    local a = c.anchors and c.anchors[d.key]
    if not a then return end
    local ih, pad = 34, 6
    local w = math.max(a[3], 220)
    local h = #d.options * ih + pad * 2
    local x = a[1] + a[3] - w
    local y = a[2] + a[4] + 6
    if y + h > H - 78 then y = a[2] - 6 - h end          -- open upward when there is no room below
    y = math.max(108, math.min(y, H - 78 - h))            -- and never leave the drawer either way
    c:box(0, 0, c.w, H, { kind = "dropdown_close" })  -- anything outside the list closes it
    c:shadow(x, y, w, h, 10, 10)
    c:rect(x, y, w, h, 10, C.overlay, 0, C.border_strong, 1)
    for i, opt in ipairs(d.options) do
        local iy = y + pad + (i - 1) * ih
        local sel = opt.value == d.selected
        if sel then c:rect(x + pad, iy, w - pad * 2, ih, 6, C.accent_soft) end
        c:text(x + pad + 12, iy + ih / 2, 4, 13, sel and C.accent_text or C.text, opt.label, { bold = sel })
        if sel then ui.icon(c, "check", x + w - pad - 28, iy + 9, 16, C.accent_text) end
        c:box(x + pad, iy, w - pad * 2, ih, { kind = "pick", key = d.key, value = opt.value })
    end
end

local function row(c, x, w, y, label, sub, kind)
    c:text(x, y + 10, 4, 14, C.text, label, { bold = true })
    if sub and sub ~= "" then c:text(x, y + 30, 4, 12, C.muted, ui.fit(sub, 12, w - 160)) end
    return (sub and sub ~= "") and 56 or 40
end

function M.render(m)
    local W, H = m.W or ui.W, m.H or ui.H
    local c = ui.canvas(W, H)
    c:rect(0, 0, W, H, 0, C.black, 0x80)
    c:box(0, 0, W, H, { kind = "close" })
    local dx = W - DW
    c:rect(dx, 0, DW, H, 0, C.surface, 0, C.border_strong, 1)
    c:box(dx, 0, DW, H, { kind = "none" })
    local x, w = dx + 24, DW - 48
    c:text(x, 36, 4, 18, C.text, "Settings", { bold = true })
    c:text(dx + DW - 20, 36, 6, 12, C.faint, "Esc")
    c:box(dx + DW - 60, 20, 56, 32, { kind = "close" })
    -- tabs
    local tx = x
    for _, t in ipairs(M.TABS) do
        local tw = ui.textw(t[2], 13, true) + 24
        local active = m.tab == t[1]
        c:text(tx + tw / 2, 78, 5, 13, active and C.text or C.muted, t[2], { bold = active })
        if active then c:rect(tx + tw / 2 - 14, 92, 28, 2, 1, C.accent) end
        c:box(tx, 62, tw, 36, { kind = "tab", value = t[1] })
        tx = tx + tw + 4
    end
    c:rect(dx, 100, DW, 1, 0, C.border)
    -- scrollable content between the tab strip and the footer
    local top, bottom = 101, H - 70
    local scroll = m.scroll or 0
    c:setclip(dx, top, DW, bottom - top)
    local y = 122 - scroll
    local function group(title) c:text(x, y + 6, 4, 11, C.muted, title, { bold = true }); y = y + 26 end

    if m.tab == "playback" then
        local p = m.playback
        group("BEFORE PLAYBACK")
        local h = row(c, x, w, y, "Ask before YouTube videos", "Shows the setup sheet (quality + frame rate) before a link plays")
        ui.toggle(c, x + w - 40, y + 4, p.ask_yt); c:box(x, y, w, h, { kind = "toggle", key = "ask_yt" }); y = y + h + 6
        h = row(c, x, w, y, "Ask before local files", "Shows the frame-rate sheet before a file plays")
        ui.toggle(c, x + w - 40, y + 4, p.ask_local); c:box(x, y, w, h, { kind = "toggle", key = "ask_local" }); y = y + h + 6
        h = row(c, x, w, y, "Default frame rate", "Pre-selected in the sheet and used when not asking")
        select_box(c, x + w, y, p.rate_label, { kind = "cycle", key = "choice" }, true, m.dropdown and m.dropdown.key == "choice"); y = y + h + 6
        h = row(c, x, w, y, "Default YouTube quality", "")
        select_box(c, x + w, y, p.quality_label, { kind = "cycle", key = "quality" }, true, m.dropdown and m.dropdown.key == "quality"); y = y + h + 6
        h = row(c, x, w, y, "YouTube sign-in", "cookies.txt: export youtube.com cookies with the \"Get cookies.txt LOCALLY\" extension to portable_config\\youtube-cookies.txt")
        select_box(c, x + w, y, p.cookies_label or "None", { kind = "cycle", key = "yt_cookies" }, true, m.dropdown and m.dropdown.key == "yt_cookies"); y = y + h + 14
        group("INTERPOLATION")
        h = row(c, x, w, y, "Faithful anime mode", "Keeps held drawings held and never blends across a cut")
        ui.toggle(c, x + w - 40, y + 4, p.anime); c:box(x, y, w, h, { kind = "toggle", key = "anime" }); y = y + h + 6
        h = row(c, x, w, y, "Protect static text and logos", "Pixels that don't move between frames (burned-in subtitles, logos) are kept from the source, not interpolated")
        ui.toggle(c, x + w - 40, y + 4, p.guard ~= false); c:box(x, y, w, h, { kind = "toggle", key = "guard" }); y = y + h + 6
        h = row(c, x, w, y, "Prefer even frame rates", "Pre-selects a rate that divides your display refresh")
        ui.toggle(c, x + w - 40, y + 4, p.even); c:box(x, y, w, h, { kind = "toggle", key = "even" }); y = y + h + 6
        h = row(c, x, w, y, "Headroom", "How much faster than needed an engine must measure")
        select_box(c, x + w, y, p.headroom_label, { kind = "cycle", key = "headroom" }, true, m.dropdown and m.dropdown.key == "headroom"); y = y + h + 6
        h = row(c, x, w, y, "Best RIFE model", "Auto starts here and steps down to faster models when needed. Heavy is sharper but 2–3× slower")
        select_box(c, x + w, y, p.model_label or "", { kind = "cycle", key = "top_level" }, true, m.dropdown and m.dropdown.key == "top_level"); y = y + h + 14
        group("PICTURE")
        h = row(c, x, w, y, "Fill mode for new videos", "Fit shows the file as encoded; Fill blends zoom and stretch to remove black bars")
        select_box(c, x + w, y, p.fill_label or "Fit", { kind = "cycle", key = "fill_mode" }, true, m.dropdown and m.dropdown.key == "fill_mode"); y = y + h + 6
        h = row(c, x, w, y, "Zoom / stretch balance", "How Fill splits the difference. Press z or use the bar button per video")
        select_box(c, x + w, y, p.balance_label or "50% zoom · 50% stretch", { kind = "cycle", key = "fill_balance" }, true, m.dropdown and m.dropdown.key == "fill_balance"); y = y + h + 6
        h = row(c, x, w, y, "Anime4K upscaling", "GLSL shaders on the rendered picture, after interpolation. Costs GPU time at the output frame rate")
        select_box(c, x + w, y, p.anime4k_label or "Off", { kind = "cycle", key = "anime4k" }, true, m.dropdown and m.dropdown.key == "anime4k"); y = y + h + 14
        group("AUDIO")
        h = row(c, x, w, y, "Audio offset", "Positive delays audio. Ctrl+− / Ctrl++ during playback")
        select_box(c, x + w, y, p.audio_label, { kind = "cycle", key = "audio" }, true, m.dropdown and m.dropdown.key == "audio"); y = y + h
    elseif m.tab == "engines" then
        c:text(x, y + 8, 4, 12, C.muted, "Each frame size needs its own TensorRT engines, built once and")
        c:text(x, y + 26, 4, 12, C.muted, "measured on this GPU. Numbers are output fps at 2×.")
        y = y + 48
        local req = 0
        for _, l in ipairs(m.ladder or {}) do if not l.optional then req = req + 1 end end
        for _, e in ipairs(m.engines or {}) do
            local ch = e.vals and 108 or 60
            c:rect(x, y, w, ch, 12, C.raised, 0, C.border, 1)
            c:text(x + 14, y + 22, 4, 14, C.text, e.name, { bold = true })
            c:text(x + 14 + ui.textw(e.name, 14, true) + 10, y + 22, 4, 12, C.faint, e.dim)
            if e.state == "ready" or e.state == "partial" then
                local l = e.state == "ready" and ("All " .. req .. " levels measured") or (e.count .. " of " .. req .. " built")
                local pw = ui.textw(l, 12) + 34
                ui.pill(c, x + w - 14 - pw, y + 9, l, e.state == "ready" and "good" or "warn")
                if e.optional then  -- heavy model not built for this size: build it ahead of time
                    local bl = "Build " .. e.optional.label
                    local bw = ui.textw(bl, 13, true) + 28
                    local bx = x + w - 14 - pw - 10 - bw
                    ui.button(c, bx, y + 6, bw, 32, bl, "ghost")
                    c:box(bx, y + 6, bw, 32, { kind = "prepare", w = e.w, h = e.h, level = e.optional.level })
                end
            elseif e.state == "building" then
                local pw = ui.textw("Building…", 12) + 34
                ui.pill(c, x + w - 14 - pw, y + 9, "Building…", "accent")
            else
                ui.button(c, x + w - 14 - 110, y + 6, 110, 32, "Prepare now", "ghost")
                c:box(x + w - 14 - 110, y + 6, 110, 32, { kind = "prepare", w = e.w, h = e.h })
            end
            if e.vals then
                local n = #m.ladder
                local cw = (w - 28 - 6 * (n - 1)) / n
                for i = 1, n do
                    local cx = x + 14 + (i - 1) * (cw + 6)
                    c:rect(cx, y + 48, cw, 46, 8, C.surface)
                    local v = e.vals[i]
                    c:text(cx + 10, y + 63, 4, 13, v and C.text or C.faint, v and (v .. " fps") or "—", { bold = true })
                    c:text(cx + 10, y + 81, 4, 10, C.muted, ui.fit(m.ladder[i].label:gsub("^RIFE ", ""), 10, cw - 14))
                end
            end
            y = y + ch + 10
        end
    elseif m.tab == "system" then
        group("SYSTEM CHECK")
        for _, k in ipairs(m.checks or {}) do
            c:circle(x + 4, y + 10, 4, k.ok == true and C.good or (k.ok == false and C.warn or C.faint))
            c:text(x + 18, y + 10, 4, 13, C.text, k.label, { bold = true })
            local h = 24
            if k.hint and k.hint ~= "" then
                c:text(x + 18, y + 30, 4, 11, k.ok == false and C.warn or C.muted, ui.fit(k.hint, 11, w - 40))
                h = 44
            end
            y = y + h + 6
        end
        y = y + 10
        c:text(x, y + 8, 4, 12, C.muted, "These are read when Midframe starts and while a video plays.")
        c:text(x, y + 26, 4, 12, C.muted, "The README lists the exact Windows settings.")
    else
        group("KEYS")
        for _, k in ipairs(m.keys or {}) do
            local kw = ui.kbd(c, x, y + 2, k[1])
            c:text(x + kw + 12, y + 11, 4, 13, C.text, k[2])
            y = y + 30
        end
    end
    c:setclip(nil)
    c.scroll_max = math.max(0, (y + scroll) - bottom + 16)  -- how far the content extends past the visible area
    if c.scroll_max > 0 then  -- thin scrollbar
        local track_h = bottom - top - 16
        local th = math.max(24, track_h * (bottom - top) / ((y + scroll) - 122 + (bottom - top)))
        local ty = top + 8 + (track_h - th) * (scroll / c.scroll_max)
        c:rect(dx + DW - 6, ty, 3, th, 1.5, C.border_strong)
    end
    -- footer
    local fy = H - 56
    c:rect(dx, fy - 14, DW, 1, 0, C.border)
    c:text(x, fy + 14, 4, 11, C.faint, m.version or "")
    local bw = ui.textw("Open config folder", 14, true) + 24
    ui.button(c, dx + DW - 24 - bw, fy - 6, bw, 40, "Open config folder", "ghost")
    c:box(dx + DW - 24 - bw, fy - 6, bw, 40, { kind = "config" })
    if m.dropdown then dropdown(c, m, H) end
    return c
end

return M
