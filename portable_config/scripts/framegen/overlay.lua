-- Debug overlay: ASS text rows + small area graphs. Pure, no mp.
local M = {}

local function num(v)
    if math.abs(v - math.floor(v + 0.5)) < 1e-9 then return string.format("%d", math.floor(v + 0.5)) end
    return string.format("%.1f", v)
end

-- Filled area path for samples inside the box (x, y, w, h); values clamped to [0, vmax].
function M.graph(samples, x, y, w, h, vmax)
    local n = #samples
    if n < 2 then return "" end
    local parts = { "m " .. num(x) .. " " .. num(y + h) }
    for i, v in ipairs(samples) do
        local f = vmax > 0 and math.max(0, math.min(v, vmax)) / vmax or 0
        parts[#parts + 1] = "l " .. num(x + (i - 1) * w / (n - 1)) .. " " .. num(y + h - f * h)
    end
    parts[#parts + 1] = "l " .. num(x + w) .. " " .. num(y + h)
    return table.concat(parts, " ")
end

local function q(v, f) if v == nil then return "?" end return string.format(f or "%s", v) end

local function maxof(t, floor)
    local m = floor
    for _, v in ipairs(t) do if v > m then m = v end end
    return m
end

local W, GH = 360, 36  -- panel width, graph height
local GRAPHS = {
    { key = "real_fps", label = "real fps", color = "&H66FF66&" },
    { key = "drops", label = "dropped/s", color = "&H6666FF&" },
    { key = "vram", label = "VRAM MB", color = "&HFFCC66&" },
}

function M.render(st)
    local h = st.hist
    local rows = {
        string.format("src %s @ %s → target %s | real %s | display %s", q(st.src_res),
            st.src_fps and string.format("%.3f", st.src_fps) or "?", q(st.target_fps, "%.3f"),
            q(st.real_fps, "%.1f"), q(st.display_fps, "%.0f")),
        string.format("%s · %s · level %s/%s", q(st.level_label), q(st.backend), q(st.auto_level), q(st.auto_total)),
        string.format("dropped %s · late %s · VRAM %s MB · seek %s ms", q(st.drops), q(st.delayed), q(st.vram_mb),
            q(st.seek_ms)),
    }
    local top = 8 + #rows * 18 + 6
    local height = top + #GRAPHS * (GH + 16)
    local ev = {
        string.format("{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H000000&\\1a&H60&\\p1}m 4 4 l %d 4 l %d %d l 4 %d{\\p0}",
            W, W, height, height),
        "{\\an7\\pos(10,8)\\fs14\\bord0\\shad0\\1c&HFFFFFF&\\fnmonospace}" .. table.concat(rows, "\\N"),
    }
    for i, g in ipairs(GRAPHS) do
        local y = top + (i - 1) * (GH + 16)
        local samples = h[g.key] or {}
        local vmax = g.key == "real_fps" and (st.target_fps or 60) * 1.2 or maxof(samples, 1) * 1.1
        ev[#ev + 1] = string.format("{\\an7\\pos(10,%d)\\fs11\\bord0\\shad0\\1c&HCCCCCC&}%s (max %s)", y, g.label,
            num(maxof(samples, 0)))
        local path = M.graph(samples, 10, y + 13, W - 20, GH, vmax)
        if path ~= "" then
            ev[#ev + 1] = string.format("{\\an7\\pos(0,0)\\bord0\\shad0\\1c%s\\1a&H40&\\p1}%s{\\p0}", g.color, path)
        end
    end
    return table.concat(ev, "\n")
end

return M
