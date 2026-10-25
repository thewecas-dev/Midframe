-- Fill mode: remove black bars by cropping baked-in letterbox and blending zoom with stretch.
-- Pure: math over sizes and raw frame bytes. Everything here maps to mpv VO properties
-- (video-crop, video-zoom, video-scale-x/y), so the filter chain and interpolation are untouched.
local M = {}

M.MODES = { "fit", "fill", "zoom", "stretch", "manual" }
M.LABELS = { fit = "Fit", fill = "Fill", zoom = "Zoom", stretch = "Stretch", manual = "Manual" }
M.MANUAL_MIN, M.MANUAL_MAX = 0.5, 3.0
M.BLACK = 44         -- max channel value (0..255) that still counts as a bar (streamed bars are dark grey, not black)
M.MIN_BAR = 0.015    -- bars thinner than 1.5% of the frame are noise, ignore
M.MAX_CROP = 0.30    -- bars larger than this per side are a dark scene, not letterboxing
M.MIN_KEEP = 0.55    -- the picture must keep at least this fraction of the frame on the cropped axis

-- Scan a raw BGR(A) frame for black bars. Returns {x, y, w, h} in source pixels, or nil for "no bars".
--   data: byte string, stride: bytes per row, bpp: bytes per pixel (4 for bgr0/bgra)
function M.detect(data, w, h, stride, bpp)
    bpp = bpp or 4
    local byte = string.byte
    local function row_dark(y)
        local base = y * stride
        for x = 8, w - 9, 16 do
            local o = base + x * bpp + 1
            local b, g, r = byte(data, o, o + 2)
            if b > M.BLACK or g > M.BLACK or r > M.BLACK then return false end
        end
        return true
    end
    local function col_dark(x)
        for y = 4, h - 5, 8 do
            local o = y * stride + x * bpp + 1
            local b, g, r = byte(data, o, o + 2)
            if b > M.BLACK or g > M.BLACK or r > M.BLACK then return false end
        end
        return true
    end
    local top, bottom, left, right = 0, 0, 0, 0
    while top < h * M.MAX_CROP and row_dark(top) do top = top + 2 end
    while bottom < h * M.MAX_CROP and row_dark(h - 1 - bottom) do bottom = bottom + 2 end
    while left < w * M.MAX_CROP and col_dark(left) do left = left + 2 end
    while right < w * M.MAX_CROP and col_dark(w - 1 - right) do right = right + 2 end
    if top >= h * M.MAX_CROP or bottom >= h * M.MAX_CROP then top, bottom = 0, 0 end  -- whole frame dark: no info
    if left >= w * M.MAX_CROP or right >= w * M.MAX_CROP then left, right = 0, 0 end
    if top + bottom < h * M.MIN_BAR * 2 then top, bottom = 0, 0 end
    if left + right < w * M.MIN_BAR * 2 then left, right = 0, 0 end
    -- real letterboxing is symmetric and on one axis only; anything else is scene content
    if math.abs(top - bottom) > h * 0.04 or math.abs(left - right) > w * 0.04 then return nil end
    if (top + bottom > 0) and (left + right > 0) then return nil end
    if h - top - bottom < h * M.MIN_KEEP or w - left - right < w * M.MIN_KEEP then return nil end
    if top + bottom + left + right == 0 then return nil end
    -- symmetric, even numbers (chroma alignment)
    local function even(v) return v - v % 2 end
    local vb, hb = even(math.min(top, bottom)), even(math.min(left, right))
    return { x = hb, y = vb, w = w - 2 * hb, h = h - 2 * vb }
end

-- Manual picture area: a centred crop of the frame to the given aspect (bars assumed on the shorter sides).
M.ASPECTS = { { label = "2.39:1", value = 2.39 }, { label = "2.0:1", value = 2.0 }, { label = "1.85:1", value = 1.85 }, { label = "16:9", value = 16 / 9 } }
function M.manual_crop(w, h, aspect, par)
    par = par or 1
    local va = (w * par) / h
    if math.abs(va - aspect) / aspect < 0.01 then return nil end
    local function even(v) return math.floor(v / 2) * 2 end
    if va < aspect then  -- bars top/bottom
        local ch = even(w * par / aspect)
        return { x = 0, y = even((h - ch) / 2), w = w, h = ch }
    end
    local cw = even(h * aspect / par)
    return { x = even((w - cw) / 2), y = 0, w = cw, h = h }
end

-- Combine detections over time: the picture area is the union, so a dark scene can only shrink the bars.
function M.merge(a, b)
    if not a then return b end
    if not b then return a end
    local x, y = math.min(a.x, b.x), math.min(a.y, b.y)
    local fw, fh = a.x * 2 + a.w, a.y * 2 + a.h  -- crops are symmetric, so the frame size follows
    return { x = x, y = y, w = fw - 2 * x, h = fh - 2 * y }
end

-- VO parameters for a mode. vw/vh: picture size after crop (display aspect), ww/wh: window size.
-- balance: 0 = all stretch .. 1 = all zoom (only used by "fill").
-- Returns { zoom = log2 zoom, scale_x, scale_y, bars = "none"|"top-bottom"|"left-right", ratio }.
-- manual = { zoom = factor, stretch = factor } for mode "manual" (stretch acts along the bars axis, vertical if none)
function M.params(vw, vh, ww, wh, mode, balance, manual)
    local out = { zoom = 0, scale_x = 1, scale_y = 1, bars = "none", ratio = 1 }
    if not (vw and vh and ww and wh) or vw <= 0 or vh <= 0 or ww <= 0 or wh <= 0 then return out end
    local va, wa = vw / vh, ww / wh
    if math.abs(va - wa) / wa >= 0.01 then
        out.ratio = va > wa and va / wa or wa / va
        out.bars = va > wa and "top-bottom" or "left-right"
    end
    if mode == "manual" then
        local z = math.max(M.MANUAL_MIN, math.min(M.MANUAL_MAX, manual and manual.zoom or 1))
        local st = math.max(M.MANUAL_MIN, math.min(M.MANUAL_MAX, manual and manual.stretch or 1))
        out.zoom = math.log(z) / math.log(2)
        if out.bars == "left-right" then out.scale_x = st else out.scale_y = st end
        return out
    end
    if mode == "fit" or out.bars == "none" then return out end
    local r = out.ratio
    local b = mode == "zoom" and 1 or mode == "stretch" and 0 or math.max(0, math.min(1, balance or 0.5))
    local z, st = r ^ b, r ^ (1 - b)
    out.zoom = math.log(z) / math.log(2)
    if out.bars == "top-bottom" then out.scale_y = st else out.scale_x = st end
    return out
end

-- Human summary for the status line / popover, e.g. "Fill 50% · crop 1920×800 · zoom 1.16× · stretch 1.16×"
function M.describe(mode, balance, p, crop)
    if mode == "fit" and not crop then return "Fit" end
    local parts = { M.LABELS[mode] .. (mode == "fill" and string.format(" %d%%", math.floor(balance * 100 + 0.5)) or "") }
    if crop then parts[#parts + 1] = string.format("crop %d×%d", crop.w, crop.h) end
    if p and math.abs(p.zoom) > 0.001 then parts[#parts + 1] = string.format("zoom %.2f×", 2 ^ p.zoom) end
    local st = (p and p.scale_x ~= 1) and p.scale_x or (p and p.scale_y or 1)
    if math.abs(st - 1) > 0.001 then parts[#parts + 1] = string.format("stretch %.2f×", st) end
    return table.concat(parts, " · ")
end

return M
