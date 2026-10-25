-- Debug overlay (top-right panel) and notice toast. Pure, no mp.
local ui = require "ui"
local C = ui.C
local M = {}

local function q(v, f) if v == nil then return "?" end return string.format(f or "%s", v) end
local function maxof(t, floor)
    local m = floor
    for _, v in ipairs(t) do if v > m then m = v end end
    return m
end

-- Filled area path for samples inside the box (x, y, w, h); values clamped to [0, vmax].
function M.graph(samples, x, y, w, h, vmax)
    local n = #samples
    if n < 2 then return "" end
    local parts = { "m " .. ui.num(x) .. " " .. ui.num(y + h) }
    for i, v in ipairs(samples) do
        local f = vmax > 0 and math.max(0, math.min(v, vmax)) / vmax or 0
        parts[#parts + 1] = "l " .. ui.num(x + (i - 1) * w / (n - 1)) .. " " .. ui.num(y + h - f * h)
    end
    parts[#parts + 1] = "l " .. ui.num(x + w) .. " " .. ui.num(y + h)
    return table.concat(parts, " ")
end

local PW, GH = 360, 36
local GRAPHS = {
    { key = "real_fps", label = "real fps", color = C.good },
    { key = "drops", label = "dropped / s", color = C.bad },
    { key = "vram", label = "VRAM MB", color = C.accent },
}

-- st: see main.lua draw(). res_w: canvas width in design units.
function M.render(st)
    local W = st.res_w or ui.W
    local c = ui.canvas(W, st.res_h or ui.H)
    local x0, y0 = W - PW - 20, 76
    local rows = {
        { "source", string.format("%s · %s", q(st.src_res), st.src_fps and string.format("%.3f", st.src_fps) or "?") },
        { "target", string.format("%s · real %s", q(st.target_fps, "%.3f"), q(st.real_fps, "%.1f")) },
        { "level", string.format("%s/%s · %s · %s", q(st.auto_level), q(st.auto_total), q(st.level_label), q(st.backend)) },
        { "dropped", string.format("%s · late %s · seek %s ms", q(st.drops), q(st.delayed), q(st.seek_ms)) },
        { "gpu", string.format("%s / %s MHz · %s · %s MB", q(st.gpu_mhz), q(st.gpu_max_mhz), q(st.gpu_pstate), q(st.vram_mb)) },
        { "display", string.format("%s Hz · measured %s", q(st.display_fps, "%.0f"), q(st.measured_display_fps, "%.1f")) },
        { "shaders", st.shaders or "none" },
    }
    if st.fill then  -- wrap onto a second line when long
        local f = st.fill
        if ui.textw(f, 12) > PW - 124 then
            local cut = f:find(" · ", math.floor(#f / 2)) or f:find(" · ", 1, true)
            if cut then rows[#rows + 1] = { "picture", f:sub(1, cut - 1) }; rows[#rows + 1] = { "", f:sub(cut + 3) } else rows[#rows + 1] = { "picture", f } end
        else rows[#rows + 1] = { "picture", f } end
    end
    local low_clock = st.gpu_mhz and st.gpu_max_mhz and st.gpu_mhz < st.gpu_max_mhz * 0.5
    local out = st.target_fps or st.src_fps
    local off = st.display_fps and st.measured_display_fps and math.abs(st.display_fps - st.measured_display_fps) > 2
    local vrr = off and out and math.abs(st.measured_display_fps - out) < 1.5  -- locked to the video = variable refresh
    local h = 12 + 16 + 10 + #rows * 18 + 10 + #GRAPHS * (GH + 20) + 6
    c:rect(x0, y0, PW, h, 12, C.black, 0x58, C.white, 1)
    c:text(x0 + 14, y0 + 18, 4, 10, C.muted, "DEBUG", { bold = true })
    c:text(x0 + PW - 14, y0 + 18, 6, 10, C.faint, "D to hide")
    local y = y0 + 12 + 16 + 10
    for _, r in ipairs(rows) do
        local tone = C.text
        if r[1] == "gpu" and low_clock then tone = C.warn end
        if r[1] == "display" then tone = vrr and C.warn or (off and C.muted or C.good) end
        c:text(x0 + 14, y + 8, 4, 12, C.muted, r[1])
        c:text(x0 + 110, y + 8, 4, 12, tone, r[2], { font = ui.MONO })
        y = y + 18
    end
    if low_clock then c:text(x0 + 110, y + 5, 4, 11, C.warn, "GPU parked in power saving, see README"); y = y + 16 end
    if vrr then c:text(x0 + 110, y + 5, 4, 11, C.warn, "variable refresh: turn off G-SYNC / Dynamic rate"); y = y + 16 end
    y = y + 10
    for _, g in ipairs(GRAPHS) do
        local samples = (st.hist or {})[g.key] or {}
        local vmax = g.key == "real_fps" and (st.target_fps or 60) * 1.2 or maxof(samples, 1) * 1.1
        c:text(x0 + 14, y + 6, 4, 11, C.muted, g.label .. " (max " .. ui.num(maxof(samples, 0)) .. ")")
        c:rect(x0 + 14, y + 15, PW - 28, GH, 4, C.white, 0xF0)
        local path = M.graph(samples, x0 + 14, y + 15, PW - 28, GH, vmax)
        if path ~= "" then c:shape(path, g.color, 0x50) end
        y = y + GH + 20
    end
    return c:render()
end

-- Top-centre notice. kind: "info" | "warn" | "good" | "bad". w: canvas width in design units.
function M.toast(w, txt, kind)
    local c = ui.canvas(w, ui.H)
    txt = tostring(txt):gsub("[%c]", " ")
    txt = ui.fit(txt, 13, w - 160)
    local tw = ui.textw(txt, 13) + 54
    local x, y = math.floor((w - tw) / 2), 84
    c:shadow(x, y, tw, 40, 10, 10)
    c:rect(x, y, tw, 40, 10, C.surface, 0x10, C.border_strong, 1)
    c:circle(x + 20, y + 20, 4, C[({ info = "accent", warn = "warn", good = "good", bad = "bad" })[kind] or "accent"])
    c:text(x + 34, y + 20, 4, 13, C.text, txt, { bold = true })
    return c:render()
end

return M
