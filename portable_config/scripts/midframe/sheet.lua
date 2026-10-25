-- Setup sheet (before playback) and the in-player frame-rate quick menu. Pure: model in, canvas out.
local ui = require "ui"
local fps = require "fps"
local auto = require "auto"
local C = ui.C
local M = {}

M.QUALITIES = { { value = "auto", label = "Auto" }, { value = "2160", label = "2160p" }, { value = "1440", label = "1440p" },
    { value = "1080", label = "1080p" }, { value = "720", label = "720p" }, { value = "480", label = "480p" } }
M.AUTO_MAX_HEIGHT = 1440

local function fmt_int(v) return string.format("%d", math.floor(v + 0.5)) end
local function mult_label(t, src)
    local m = t / src
    local s = string.format("%.2f", m):gsub("0+$", ""):gsub("%.$", "")
    return s .. "×"
end

-- Frame-rate candidates for a source, grouped by whether they divide the display refresh evenly.
-- a: { src_num, src_den, cap, exact, ref, ref_w, ref_h, w, h, ladder }  (exact/ref may be {}; w/h may be nil)
-- Each option: { choice, num, den, value, mult, even, refreshes, plan, hint, state }
function M.rates(a)
    local src = a.src_num / a.src_den
    local cap = a.cap
    local seen, out = {}, {}
    local function add(choice, n, d)
        local t = n / d
        if t < src * 1.2 or t > cap + 1e-6 then return end  -- within 20% of the source is not worth a tile
        local key = fmt_int(t)
        if seen[key] then return end
        seen[key] = true
        local ratio = cap / t
        local even = math.abs(ratio - math.floor(ratio + 0.5)) < 0.01
        local need = auto.rife_per_s(n, d, a.src_num, a.src_den)
        local plan = auto.plan(a.exact or {}, a.ref or {}, a.ref_w, a.ref_h, a.w or a.ref_w, a.h or a.ref_h, need, #a.ladder)
        local hint
        if not plan.measured then hint = mult_label(t, src)
        elseif not plan.fits then hint = mult_label(t, src) .. " · too heavy"
        elseif plan.level <= 2 then hint = mult_label(t, src) .. (even and (" · " .. math.floor(ratio + 0.5) .. " refreshes") or " · smooth")
        else hint = mult_label(t, src) .. " · needs " .. a.ladder[plan.level].label:gsub("^RIFE ", "") end
        out[#out + 1] = { choice = choice, num = n, den = d, value = key, mult = t / src, even = even,
            refreshes = ratio, plan = plan, hint = hint, state = (plan.measured and not plan.fits) and "muted" or "default" }
    end
    for _, op in ipairs(fps.options(a.src_num, a.src_den, cap)) do add(op.choice, op.num, op.den) end
    for _, k in ipairs({ 6, 5, 4, 3, 2, 1 }) do
        if cap % k == 0 then add(tostring(cap / k), cap / k, 1) end
    end
    table.sort(out, function(p, q) return p.num / p.den < q.num / q.den end)
    local even, other = {}, {}
    for _, r in ipairs(out) do
        if r.even then even[#even + 1] = r else other[#other + 1] = r end
    end
    return even, other
end

-- Resolve the current choice (or custom text) to an option-like record; nil if invalid.
function M.resolve(choice, a)
    local n, d = fps.resolve(choice, a.src_num, a.src_den, a.cap)
    if not n then return nil end
    local need = auto.rife_per_s(n, d, a.src_num, a.src_den)
    local plan = auto.plan(a.exact or {}, a.ref or {}, a.ref_w, a.ref_h, a.w or a.ref_w, a.h or a.ref_h, need, #a.ladder)
    return { num = n, den = d, plan = plan, need = need }
end

-- Preview strip text + tone for a resolved choice.
function M.preview(r, a)
    if not r then return { line = "—", note = "Pick a frame rate", tone = "neutral", label = "" } end
    local src = a.src_num / a.src_den
    local lv = a.ladder[r.plan.level]
    local measured = (a.exact or {})[r.plan.level] or ((a.ref or {})[r.plan.level])
    local note, tone, label
    if not r.plan.measured then
        note, tone, label = lv.label .. " · not measured on this GPU yet", "neutral", "Unknown"
    elseif r.plan.fits then
        note = string.format("%s · measured %s fps, needs %s generated/s · plays smoothly", lv.label,
            measured and fmt_int(measured) or "?", fmt_int(r.need))
        tone, label = "good", "Smooth"
    else
        note = string.format("Needs %s generated/s; fastest level measures %s · will step down to original",
            fmt_int(r.need), measured and fmt_int(measured / 2) or "?")
        tone, label = "warn", "Too heavy"
    end
    return { src = fps.fmt(src), target = fps.fmt(r.num / r.den), note = note, tone = tone, label = label }
end

local function choice_matches(choice, opt)
    if choice == opt.choice then return true end
    local n = tonumber(choice)
    return n ~= nil and math.abs(n - opt.num / opt.den) < 0.5 and opt.choice:sub(1, 1) ~= "x"
end

local function tiles(c, x, y, w, group, choice, custom, max_per_row)
    local n = #group + (custom and 1 or 0)
    if n == 0 then return y end
    local gap = 8
    local tw = (w - gap * (n - 1)) / n
    for i, r in ipairs(group) do
        local tx = x + (i - 1) * (tw + gap)
        local st = (choice_matches(choice, r) and not (custom and custom.focus)) and "selected" or r.state
        ui.tile(c, tx, y, tw, 56, r.value, r.hint, st)
        c:box(tx, y, tw, 56, { kind = "rate", choice = r.choice })
    end
    if custom then
        local tx = x + #group * (tw + gap)
        local st = custom.focus and "focus" or (custom.valid and "selected" or "default")
        if st == "selected" then c:rect(tx, y, tw, 56, 10, C.accent_soft, 0, C.accent, 1.5)
        elseif st == "focus" then c:rect(tx, y, tw, 56, 10, C.raised, 0, C.accent, 1.5)
        else c:rect(tx, y, tw, 56, 10, C.raised, 0, C.border, 1) end
        c:text(tx + 14, y + 16, 4, 11, C.muted, "Custom")
        local txt = custom.text ~= "" and custom.text or "—"
        local col = custom.text ~= "" and (custom.valid and C.accent_text or C.bad) or C.faint
        c:text(tx + 14, y + 38, 4, 16, col, txt .. (custom.focus and "|" or ""), { bold = true })
        c:text(tx + 14 + ui.textw(txt, 16, true) + (custom.focus and 8 or 4), y + 39, 4, 12, C.faint, "fps")
        c:box(tx, y, tw, 56, { kind = "custom" })
    end
    return y + 56
end

local function group_label(c, x, y, text, tone)
    if tone then
        c:circle(x + 3, y + 7, 3, C[tone])
        c:text(x + 12, y + 7, 4, 12, C.text, text)
    else
        c:text(x, y + 7, 4, 12, C.muted, text)
    end
    return y + 22
end

-- Full sheet. m = {
--   kind = "yt"|"local", title, meta, quality, qualities = {{value,label,muted}}, choice, custom = {text, valid, focus},
--   even, other (from rates()), preview (from preview()), remember = bool, remember_label, src_label, cap,
--   quality_note, W, H }
function M.render(m)
    local W, H = m.W or ui.W, m.H or ui.H
    local c = ui.canvas(W, H)
    c:rect(0, 0, W, H, 0, C.black, 0x70)
    local sw = m.kind == "yt" and 720 or 640
    local pad = 28
    -- measure height first
    local rows = 0
    local h = 24 + 50 + 18 + 1 + 22
    if m.kind == "yt" then h = h + 22 + 12 + 44 + 8 + 16 + 26 end
    h = h + 22 + 12
    if #m.even > 0 then h = h + 22 + 56 + 10 end
    h = h + 22 + 56 + 18 + 70 + 8 + 1 + 16 + 40 + 20
    local sx, sy = math.floor((W - sw) / 2), math.floor((H - h) / 2)
    c:shadow(sx, sy, sw, h, 18, 18)
    c:rect(sx, sy, sw, h, 18, C.surface, 0, C.border_strong, 1)
    c:box(sx, sy, sw, h, { kind = "none" })
    local x, y = sx + pad, sy + 24
    -- header
    if m.kind == "yt" then
        c:rect(x, y, 88, 50, 8, C.overlay)
        ui.icon(c, "play", x + 32, y + 13, 24, C.faint)
        c:text(x + 104, y + 15, 4, 17, C.text, ui.fit(m.title or "", 17, sw - pad * 2 - 104 - 60, true), { bold = true })
        c:text(x + 104, y + 38, 4, 13, C.muted, ui.fit(m.meta or "", 13, sw - pad * 2 - 104 - 60))
    else
        c:text(x, y + 15, 4, 17, C.text, ui.fit(m.title or "", 17, sw - pad * 2 - 60, true), { bold = true })
        c:text(x, y + 38, 4, 13, C.muted, ui.fit(m.meta or "", 13, sw - pad * 2 - 60))
    end
    c:text(sx + sw - pad, y + 15, 6, 12, C.faint, "Esc")
    c:box(sx + sw - pad - 40, y, 48, 30, { kind = "close" })
    y = y + 50 + 18
    c:rect(sx, y, sw, 1, 0, C.border); y = y + 1 + 22
    local cw = sw - 2 * pad
    -- quality
    if m.kind == "yt" then
        c:text(x, y + 7, 4, 12, C.muted, "QUALITY", { bold = true })
        c:text(sx + sw - pad, y + 7, 6, 12, C.faint, "Streams this video actually has")
        y = y + 22 + 12
        ui.segment(c, x, y, cw, 44, m.qualities, m.quality, "quality")
        y = y + 44 + 8
        c:text(x, y + 8, 4, 12, C.faint, m.quality_note or "")
        y = y + 16 + 26
    end
    -- frame rate
    c:text(x, y + 7, 4, 12, C.muted, "FRAME RATE", { bold = true })
    c:text(sx + sw - pad, y + 7, 6, 12, C.faint, (m.src_label and ("Source " .. m.src_label .. " fps · ") or "") .. "Display " .. (m.cap or "?") .. " Hz")
    y = y + 22 + 12
    if #m.even > 0 then
        y = group_label(c, x, y, "Even on your " .. (m.cap or "?") .. " Hz display", "good")
        y = tiles(c, x, y, cw, m.even, m.choice, nil) + 10
    end
    y = group_label(c, x, y, #m.even > 0 and "Other" or "Options")
    y = tiles(c, x, y, cw, m.other, m.choice, m.custom) + 18
    -- preview strip
    local p = m.preview
    c:rect(x, y, cw, 70, 12, C.accent_soft)
    if p.src then
        local px = x + 16
        c:text(px, y + 24, 4, 20, C.text, p.src, { bold = true }); px = px + ui.textw(p.src, 20, true) + 8
        c:text(px, y + 24, 4, 16, C.accent_text, "→"); px = px + 20
        c:text(px, y + 24, 4, 20, C.accent_text, p.target .. " fps", { bold = true }); px = px + ui.textw(p.target .. " fps", 20, true) + 8
        if m.kind == "yt" and m.quality_label then c:text(px, y + 25, 4, 14, C.muted, "at " .. m.quality_label) end
    else
        c:text(x + 16, y + 24, 4, 20, C.text, p.line or "—", { bold = true })
    end
    c:text(x + 16, y + 50, 4, 12, C.muted, ui.fit(p.note or "", 12, cw - 150))
    if p.label and p.label ~= "" then
        local pw = ui.textw(p.label, 12) + 34
        ui.pill(c, x + cw - 16 - pw, y + 22, p.label, p.tone)
    end
    y = y + 70 + 8
    c:rect(sx, y, sw, 1, 0, C.border); y = y + 1 + 16
    -- footer
    ui.toggle(c, x, y + 9, m.remember)
    c:text(x + 52, y + 20, 4, 13, C.muted, m.remember_label or "Don't ask again")
    c:box(x, y, 52 + ui.textw(m.remember_label or "", 13), 40, { kind = "remember" })
    local play_label = m.play_label or "Play"
    local pbw = math.max(150, ui.textw(play_label, 14, true) + 40)
    local ebw = ui.textw("Enter", 11) + 12
    local pbx = sx + sw - pad - ebw - 8 - pbw
    ui.button(c, pbx, y, pbw, 40, play_label, "primary"); c:box(pbx, y, pbw, 40, { kind = "play" })
    ui.kbd(c, pbx + pbw + 8, y + 11, "Enter")
    local obw = ui.textw(m.original_label or "Play original", 14, true) + 36
    ui.button(c, pbx - 10 - obw, y, obw, 40, m.original_label or "Play original", "secondary")
    c:box(pbx - 10 - obw, y, obw, 40, { kind = "original" })
    return c
end

-- Compact quick menu (during playback), bottom-right above the control bar.
-- m = { even, other, choice, custom, src_label, target_label, enabled, W, H, bottom (y of the control bar) }
function M.quick(m)
    local W, H = m.W or ui.W, m.H or ui.H
    local c = ui.canvas(W, H)
    local pw, pad = 380, 14
    local h = 14 + 20 + 10 + (#m.even > 0 and (18 + 52 + 10) or 0) + 18 + 52 + 10 + 36 + 14
    local px, py = W - 28 - pw, (m.bottom or (H - 84)) - h - 6
    c:box(0, 0, W, H, { kind = "close" })
    c:shadow(px, py, pw, h, 14, 14)
    c:rect(px, py, pw, h, 14, C.surface, 0, C.border_strong, 1)
    c:box(px, py, pw, h, { kind = "none" })
    local x, y = px + pad, py + pad
    c:text(x, y + 10, 4, 13, C.text, "Frame rate", { bold = true })
    if m.src_label then
        local tl = m.target_label or "off"
        c:text(px + pw - pad, y + 10, 6, 12, C.accent_text, tl, { bold = true })
        c:text(px + pw - pad - ui.textw(tl, 12, true) - 4, y + 10, 6, 12, C.muted, m.src_label .. " →")
    end
    y = y + 20 + 10
    local cw = pw - 2 * pad
    local function row(group, custom, label, tone)
        if #group == 0 and not custom then return end
        if tone then c:text(x, y + 7, 4, 11, C.good, label) else c:text(x, y + 7, 4, 11, C.muted, label) end
        y = y + 18
        local n = #group + (custom and 1 or 0)
        local gap = 6
        local tw = (cw - gap * (n - 1)) / n
        for i, r in ipairs(group) do
            local tx = x + (i - 1) * (tw + gap)
            local st = (m.enabled and choice_matches(m.choice, r) and not (custom and custom.focus)) and "selected" or r.state
            ui.tile(c, tx, y, tw, 52, r.value, r.hint:match("^[^·]+"):gsub("%s+$", ""), st)
            c:box(tx, y, tw, 52, { kind = "rate", choice = r.choice })
        end
        y = y + 52 + 10
    end
    row(m.even, nil, "Even on " .. (m.cap or "?") .. " Hz", "good")
    row(m.other, nil, "Other")
    -- custom field + interpolation toggle
    local cf = m.custom or { text = "", valid = false, focus = false }
    local cfw = cw - 8 - 160
    c:rect(x, y, cfw, 36, 8, C.raised, 0, cf.focus and C.accent or C.border, 1)
    local txt = cf.text ~= "" and (cf.text .. (cf.focus and "|" or "") .. " fps") or (cf.focus and "| fps" or "Custom fps")
    c:text(x + 12, y + 18, 4, 12, cf.text ~= "" and (cf.valid and C.text or C.bad) or C.faint, txt)
    c:box(x, y, cfw, 36, { kind = "custom" })
    local tx = x + cfw + 8
    c:rect(tx, y, 160, 36, 8, C.raised, 0, C.border, 1)
    c:text(tx + 12, y + 18, 4, 12, C.text, "Interpolation", { bold = true })
    c:rect(tx + 118, y + 9, 34, 18, 9, m.enabled and C.accent or C.border_strong)
    c:circle(m.enabled and tx + 118 + 25 or tx + 118 + 9, y + 18, 6.5, C.white)
    c:box(tx, y, 160, 36, { kind = "toggle" })
    return c
end

return M
