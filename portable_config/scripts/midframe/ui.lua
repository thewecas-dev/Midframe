-- ASS widget kit: draws the Figma "Midframe UI v2" primitives in design units and records click boxes.
-- Pure (no mp). A Canvas collects ASS events + hit boxes; main.lua scales it to the window.
local M = {}

-- Figma tokens (hex) -> ASS "&HBBGGRR&"
local HEX = {
    bg = "0C0C10", surface = "15151B", raised = "1D1D25", overlay = "22222C", border = "2B2B37", border_strong = "3A3A48",
    text = "F3F2F7", muted = "9B99AB", faint = "65637A", accent = "8B6CFF", accent_soft = "2A2347", accent_text = "C8B8FF",
    good = "4ADE80", warn = "FBBF24", bad = "F87171", white = "FFFFFF", black = "000000",
}
local C = {}
for k, h in pairs(HEX) do C[k] = "&H" .. h:sub(5, 6) .. h:sub(3, 4) .. h:sub(1, 2) .. "&" end
M.C = C
M.FONT = "Segoe UI"
M.MONO = "Consolas"
M.W, M.H = 1440, 900  -- design size

local function num(v)
    if math.abs(v - math.floor(v + 0.5)) < 1e-9 then return string.format("%d", math.floor(v + 0.5)) end
    return string.format("%.1f", v)
end
M.num = num

function M.ulen(s) return select(2, tostring(s):gsub("[^\128-\191]", "")) end
-- Approximate rendered width of a string at a font size (Segoe UI average advance ~0.52 em).
function M.textw(s, size, bold) return M.ulen(s) * size * (bold and 0.56 or 0.52) end
function M.esc(s) return (tostring(s):gsub("[{}\\]", { ["{"] = "(", ["}"] = ")", ["\\"] = "/" })) end
-- Truncate with an ellipsis so the string fits `width` at `size`.
function M.fit(s, size, width, bold)
    s = tostring(s)
    local per = size * (bold and 0.56 or 0.52)
    local max = math.floor(width / per)
    if M.ulen(s) <= max then return s end
    local out, n = {}, 0
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        n = n + 1
        if n > max - 1 then break end
        out[#out + 1] = ch
    end
    return table.concat(out) .. "…"
end

function M.rrect(x, y, w, h, r)
    r = math.max(0, math.min(r or 0, w / 2, h / 2))
    local x2, y2 = x + w, y + h
    if r == 0 then return string.format("m %s %s l %s %s l %s %s l %s %s", num(x), num(y), num(x2), num(y), num(x2), num(y2), num(x), num(y2)) end
    return table.concat({
        "m", num(x + r), num(y), "l", num(x2 - r), num(y), "b", num(x2), num(y), num(x2), num(y), num(x2), num(y + r),
        "l", num(x2), num(y2 - r), "b", num(x2), num(y2), num(x2), num(y2), num(x2 - r), num(y2),
        "l", num(x + r), num(y2), "b", num(x), num(y2), num(x), num(y2), num(x), num(y2 - r),
        "l", num(x), num(y + r), "b", num(x), num(y), num(x), num(y), num(x + r), num(y),
    }, " ")
end

local Canvas = {}
Canvas.__index = Canvas

function M.canvas(w, h) return setmetatable({ w = w, h = h, ev = {}, boxes = {} }, Canvas) end

-- alpha: 0 (opaque) .. 255 (invisible). border: colour or nil. bw: border width.
-- Clip every following event to a rectangle (nil clears). Used for scrollable areas.
function Canvas:setclip(x, y, w, h)
    self.clipstr = x and string.format("\\clip(%s,%s,%s,%s)", num(x), num(y), num(x + w), num(y + h)) or ""
    self.cliprect = x and { x, y, x + w, y + h } or nil
    return self
end
function Canvas:shape(path, fill, alpha, border, bw)
    local b = border and string.format("\\bord%s\\3c%s\\3a&H%02X&", num(bw or 1), border, alpha or 0) or "\\bord0"
    self.ev[#self.ev + 1] = string.format("{\\an7\\pos(0,0)%s%s\\shad0\\1c%s\\1a&H%02X&\\p1}%s{\\p0}", b, self.clipstr or "", fill, alpha or 0, path)
    return self
end
function Canvas:rect(x, y, w, h, r, fill, alpha, border, bw) return self:shape(M.rrect(x, y, w, h, r), fill, alpha, border, bw) end
function Canvas:circle(cx, cy, r, fill, alpha)
    local k = 0.5523 * r
    local p = string.format("m %s %s b %s %s %s %s %s %s b %s %s %s %s %s %s b %s %s %s %s %s %s b %s %s %s %s %s %s",
        num(cx + r), num(cy), num(cx + r), num(cy + k), num(cx + k), num(cy + r), num(cx), num(cy + r),
        num(cx - k), num(cy + r), num(cx - r), num(cy + k), num(cx - r), num(cy),
        num(cx - r), num(cy - k), num(cx - k), num(cy - r), num(cx), num(cy - r),
        num(cx + k), num(cy - r), num(cx + r), num(cy - k), num(cx + r), num(cy))
    return self:shape(p, fill, alpha)
end
-- Soft shadow: a few translucent rects growing outwards.
function Canvas:shadow(x, y, w, h, r, spread)
    for i = spread or 12, 2, -3 do self:rect(x - i, y - i + 6, w + 2 * i, h + 2 * i, r + i, C.black, 0xE8) end
    return self
end
-- an: ASS alignment (7 top-left, 4 mid-left, 5 centre, 6 mid-right, 9 top-right, 8 top-centre).
function Canvas:text(x, y, an, size, color, str, o)
    o = o or {}
    self.ev[#self.ev + 1] = string.format("{\\an%d\\pos(%s,%s)%s\\fs%s\\fn%s\\b%d\\bord0\\shad0\\1c%s\\1a&H%02X&}%s",
        an, num(x), num(y), self.clipstr or "", num(size), o.font or M.FONT, o.bold and 1 or 0, color, o.alpha or 0, M.esc(str))
    return self
end
function Canvas:box(x, y, w, h, action)
    local b = { x, y, x + w, y + h, action }
    if self.cliprect then  -- intersect with the active clip; drop boxes that fall fully outside
        local c = self.cliprect
        b[1], b[2], b[3], b[4] = math.max(b[1], c[1]), math.max(b[2], c[2]), math.min(b[3], c[3]), math.min(b[4], c[4])
        if b[1] >= b[3] or b[2] >= b[4] then return self end
    end
    self.boxes[#self.boxes + 1] = b
    return self
end
function Canvas:hit(x, y)
    for i = #self.boxes, 1, -1 do
        local b = self.boxes[i]
        if x >= b[1] and x <= b[3] and y >= b[2] and y <= b[4] then return b[5] end
    end
    return nil
end
function Canvas:render() return table.concat(self.ev, "\n") end

-- ---------- widgets (all take design-unit coordinates) ----------

-- Option tile: value on top, hint below. state: "default" | "selected" | "muted" | "focus".
function M.tile(c, x, y, w, h, value, hint, state)
    if state == "selected" then
        c:rect(x, y, w, h, 10, C.accent_soft, 0, C.accent, 1.5)
    elseif state == "muted" then
        c:rect(x, y, w, h, 10, C.surface, 0x90, C.border, 1)
    elseif state == "focus" then
        c:rect(x, y, w, h, 10, C.raised, 0, C.border_strong, 1.5)
    else
        c:rect(x, y, w, h, 10, C.raised, 0, C.border, 1)
    end
    local vcol = state == "selected" and C.accent_text or (state == "muted" and C.faint or C.text)
    local hcol = state == "muted" and C.faint or C.muted
    if hint and hint ~= "" then
        c:text(x + w / 2, y + h / 2 - 8, 5, 16, vcol, value, { bold = true })
        c:text(x + w / 2, y + h / 2 + 11, 5, 11, hcol, M.fit(hint, 11, w - 12))
    else
        c:text(x + w / 2, y + h / 2, 5, 16, vcol, value, { bold = true })
    end
end

-- Button. variant: "primary" | "secondary" | "ghost". Returns nothing; caller registers the box.
function M.button(c, x, y, w, h, label, variant)
    if variant == "primary" then c:rect(x, y, w, h, 10, C.accent)
    elseif variant == "secondary" then c:rect(x, y, w, h, 10, C.raised, 0, C.border_strong, 1) end
    c:text(x + w / 2, y + h / 2, 5, 14, variant == "ghost" and C.muted or C.text, label, { bold = true })
end

-- Segmented control. items: { {label=, value=, muted=bool} ... }. Registers {kind="segment", value=}.
function M.segment(c, x, y, w, h, items, selected, kind)
    c:rect(x, y, w, h, 12, C.bg, 0, C.border, 1)
    local n, pad, gap = #items, 4, 4
    local iw = (w - 2 * pad - gap * (n - 1)) / n
    for i, it in ipairs(items) do
        local ix = x + pad + (i - 1) * (iw + gap)
        local sel = it.value == selected
        if sel then c:rect(ix, y + pad, iw, h - 2 * pad, 9, C.raised, 0, C.border_strong, 1) end
        c:text(ix + iw / 2, y + h / 2, 5, 14, sel and C.text or (it.muted and C.faint or C.text), it.label, { bold = sel, alpha = (it.muted and 0x70) or (sel and 0 or 0x30) })
        c:box(ix, y, iw, h, { kind = kind or "segment", value = it.value })
    end
end

function M.toggle(c, x, y, on)
    c:rect(x, y, 40, 22, 11, on and C.accent or C.border_strong)
    c:circle(on and x + 29 or x + 11, y + 11, 8, C.white)
end

-- Status pill with a coloured dot. tone: "good" | "warn" | "bad" | "neutral" | "accent". Returns its width.
function M.pill(c, x, y, label, tone)
    local w = M.textw(label, 12) + 34
    c:rect(x, y, w, 26, 13, C.raised, 0, C.border, 1)
    c:circle(x + 13, y + 13, 3, C[tone == "neutral" and "muted" or tone] or C.muted)
    c:text(x + 22, y + 13, 4, 12, C.text, label)
    return w
end

-- Keyboard hint chip. Returns its width.
function M.kbd(c, x, y, label)
    local w = M.textw(label, 11) + 12
    c:rect(x, y, w, 18, 5, C.overlay, 0, C.border, 1)
    c:text(x + w / 2, y + 9, 5, 11, C.muted, label)
    return w
end

-- Small accent badge like "48 fps". Returns width.
function M.badge(c, x, y, label)
    local w = M.textw(label, 11, true) + 16
    c:rect(x, y, w, 20, 6, C.accent_soft)
    c:text(x + w / 2, y + 10, 5, 11, C.accent_text, label, { bold = true })
    return w
end

-- Icons as small vector paths (24-unit grid scaled to `s`).
local ICONS = {
    play = "m 8 5 l 19 12 l 8 19",
    bolt = "m 13 2 l 4 14 l 11 14 l 10 22 l 20 10 l 13 10",
    upload = "m 11 16 l 11 8 l 8 11 l 7 10 l 12 5 l 17 10 l 16 11 l 13 8 l 13 16 l 11 16 m 5 17 l 7 17 l 7 19 l 17 19 l 17 17 l 19 17 l 19 21 l 5 21",
    link = "m 10 13 l 14 9 l 15 10 l 11 14 m 7 12 l 10 9 l 11 10 l 8 13 l 9 16 l 12 15 l 13 16 l 10 19 l 6 18 l 5 14 m 17 12 l 14 15 l 13 14 l 16 11 l 15 8 l 12 9 l 11 8 l 14 5 l 18 6 l 19 10",
    gear = "m 12 8 l 16 12 l 12 16 l 8 12 m 11 2 l 13 2 l 13 5 l 11 5 m 11 19 l 13 19 l 13 22 l 11 22 m 2 11 l 5 11 l 5 13 l 2 13 m 19 11 l 22 11 l 22 13 l 19 13",
    close = "m 6 5 l 7 4 l 12 9 l 17 4 l 18 5 l 13 10 l 18 15 l 17 16 l 12 11 l 7 16 l 6 15 l 11 10",
    check = "m 5 12 l 7 10 l 10 13 l 17 6 l 19 8 l 10 17",
    chevron = "m 8 10 l 9 9 l 12 12 l 15 9 l 16 10 l 12 14",
}
-- The app icon (packaging/icon.png) as vectors: dark tile, two fading play marks, one solid. `s` = tile size.
C.tile = "&H3A2027&"
function M.mark(c, x, y, s)
    c:rect(x, y, s, s, s * 0.22, C.tile)
    c:circle(x + s * 0.54, y + s * 0.5, s * 0.30, C.accent, 0xA8)  -- soft glow
    local function tri(cx, cy, size, fill, alpha)
        local hh = size * 0.95 / 2
        c:shape(string.format("m %s %s l %s %s l %s %s", M.num(cx - size * 0.42), M.num(cy - hh), M.num(cx - size * 0.42), M.num(cy + hh), M.num(cx + size * 0.58), M.num(cy)), fill, alpha)
    end
    local cx, cy, size = x + s * 0.56, y + s * 0.5, s * 0.44
    tri(cx - size * 0.34, cy, size, C.accent, 0xB0)
    tri(cx - size * 0.17, cy, size, C.accent, 0x60)
    tri(cx, cy, size, C.white, 0)
end

function M.icon(c, name, x, y, s, color)
    local p = ICONS[name]
    if not p then return end
    local k = s / 24
    local path = p:gsub("(%-?%d+%.?%d*) (%-?%d+%.?%d*)", function(a, b) return num(x + tonumber(a) * k) .. " " .. num(y + tonumber(b) * k) end)
    c:shape(path, color)
end

return M
