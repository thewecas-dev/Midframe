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
        string.format("{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H000000&\\1a&H60&\\p1}%s{\\p0}", M.rrect(4, 4, W - 4, height - 4, 10)),
        "{\\an7\\pos(14,10)\\fs14\\bord0\\shad0\\1c&HF7F4F2&\\fnConsolas}" .. table.concat(rows, "\\N"),
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

-- Theme (ASS colours are BGR), matching the Figma tokens.
local C = {
    accent = "&HFF6C8B&", surface = "&H1B1614&", raised = "&H27201D&", border = "&H382F2A&",
    text = "&HF7F4F2&", muted = "&HAFA39A&", good = "&H97DC3D&", warn = "&H20B0FF&", bad = "&H6C5CFF&",
}
M.C = C

local function ulen(s) return select(2, s:gsub("[^\128-\191]", "")) end

-- Rounded rectangle drawing path.
function M.rrect(x, y, w, h, r)
    r = math.min(r, w / 2, h / 2)
    local x2, y2 = x + w, y + h
    return table.concat({
        "m", num(x + r), num(y), "l", num(x2 - r), num(y), "b", num(x2), num(y), num(x2), num(y), num(x2), num(y + r),
        "l", num(x2), num(y2 - r), "b", num(x2), num(y2), num(x2), num(y2), num(x2 - r), num(y2),
        "l", num(x + r), num(y2), "b", num(x), num(y2), num(x), num(y2), num(x), num(y2 - r),
        "l", num(x), num(y + r), "b", num(x), num(y), num(x), num(y), num(x + r), num(y),
    }, " ")
end

local function shape(path, fill, alpha, border)
    local b = border and ("\\bord1\\3c" .. border) or "\\bord0"
    return string.format("{\\an7\\pos(0,0)%s\\shad0\\1c%s\\1a&H%02X&\\p1}%s{\\p0}", b, fill, alpha or 0, path)
end

local function label(x, y, an, size, color, txt, bold)
    return string.format("{\\an%d\\pos(%s,%s)\\fs%d\\bord0\\shad0\\b%d\\1c%s}%s", an, num(x), num(y), size,
        bold and 1 or 0, color, txt)
end

-- Top-center notice pill. kind: "info" | "warn" | "good" | "bad".
function M.toast(w, txt, kind)
    local fs, h = 16, 40
    local tw = math.floor(ulen(txt) * fs * 0.54 + 52)
    local x, y = math.floor((w - tw) / 2), 24
    local dot = ({ info = C.accent, warn = C.warn, good = C.good, bad = C.bad })[kind] or C.accent
    return table.concat({
        shape(M.rrect(x, y, tw, h, 12), C.surface, 0x10, C.border),
        shape(M.rrect(x + 16, y + 15, 10, 10, 5), dot),
        label(x + 36, y + h / 2, 4, fs, C.text, txt),
    }, "\n")
end

-- Idle start screen. engine: "ready" | "building" | "missing". Returns ASS and click boxes.
function M.idle(w, h, engine)
    local cw, ch = 600, 270
    local cx, cy = math.floor((w - cw) / 2), math.floor((h - ch) / 2) - 20
    local mid = cx + cw / 2
    local bw, bh, gap = 190, 46, 14
    local b1x, by = mid - bw - gap / 2, cy + 180
    local b2x = mid + gap / 2
    local status = ({
        ready = { C.good, "RIFE ready · TensorRT" },
        building = { C.warn, "Preparing RIFE (first run, several minutes)…" },
        missing = { C.warn, "RIFE not prepared yet" },
    })[engine] or { C.muted, "RIFE status unknown" }
    local sw = math.floor(ulen(status[2]) * 13 * 0.54 + 44)
    local sx, sy = math.floor((w - sw) / 2), h - 64
    local arrow = string.format("m %s %s l %s %s l %s %s l %s %s l %s %s l %s %s l %s %s l %s %s l %s %s",
        num(mid - 3), num(cy + 34), num(mid + 3), num(cy + 34), num(mid + 3), num(cy + 54), num(mid + 10), num(cy + 47),
        num(mid + 14), num(cy + 51), num(mid), num(cy + 65), num(mid - 14), num(cy + 51), num(mid - 10), num(cy + 47),
        num(mid - 3), num(cy + 54))
    local ev = {
        shape(M.rrect(cx, cy, cw, ch, 20), C.surface, 0x18, C.border),
        shape(arrow, C.text),
        shape(M.rrect(mid - 18, cy + 72, 36, 4, 2), C.text),
        label(mid, cy + 112, 5, 28, C.text, "Drop a video here", true),
        label(mid, cy + 148, 5, 16, C.muted, "Local files or a YouTube link — streamed, never downloaded"),
        shape(M.rrect(b1x, by, bw, bh, 10), C.accent),
        label(b1x + bw / 2, by + bh / 2, 5, 16, C.text, "Open file   {\\b0\\alpha&H50&}Ctrl+O", true),
        shape(M.rrect(b2x, by, bw, bh, 10), C.raised),
        label(b2x + bw / 2, by + bh / 2, 5, 16, C.text, "Paste link   {\\b0\\1c" .. C.muted .. "}Ctrl+V", true),
        shape(M.rrect(sx, sy, sw, 32, 16), C.surface),
        shape(M.rrect(sx + 14, sy + 12, 8, 8, 4), status[1]),
        label(sx + 30, sy + 16, 4, 13, C.muted, status[2]),
    }
    return table.concat(ev, "\n"), {
        open = { b1x, by, b1x + bw, by + bh },
        paste = { b2x, by, b2x + bw, by + bh },
    }
end

function M.hit(box, x, y) return box ~= nil and x >= box[1] and x <= box[3] and y >= box[2] and y <= box[4] end

return M
