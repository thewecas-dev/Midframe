-- Home / start screen. Pure: model in, canvas out.
-- m = { W, H, status = {label, tone}, recents = {{title, meta, fps, progress}}, url = "", strip = {"..."}, version }
local ui = require "ui"
local C = ui.C
local M = {}

function M.render(m)
    local W, H = m.W or ui.W, m.H or ui.H
    local c = ui.canvas(W, H)
    c:rect(0, 0, W, H, 0, C.bg)
    -- top bar
    ui.mark(c, 24, 13, 28)
    c:text(62, 27, 4, 15, C.text, "Midframe", { bold = true })
    local gx = W - 16 - 34
    ui.icon(c, "gear", gx + 8, 18, 18, C.muted)
    c:box(gx, 10, 34, 34, { kind = "settings" })
    if m.status then
        local pw = ui.textw(m.status.label, 12) + 34
        ui.pill(c, gx - 12 - pw, 14, m.status.label, m.status.tone)
    end
    -- body geometry
    local top, bottom = 54 + 36, H - 44 - 32
    local lx, rx_w = 64, 400
    local lw = W - 64 * 2 - 48 - rx_w
    local rx = lx + lw + 48
    -- headline
    c:text(lx, top + 18, 4, 30, C.text, "Play something smoother.", { bold = true })
    c:text(lx, top + 54, 4, 15, C.muted, "A film or a YouTube link. Midframe fills in the frames between, live.")
    -- drop zone
    local dy = top + 84
    local url_h = 44
    local dh = bottom - dy - 20 - url_h
    c:rect(lx, dy, lw, dh, 16, C.surface, 0, C.border_strong, 1.5)
    c:box(lx, dy, lw, dh, { kind = "open" })
    local mid, cy = lx + lw / 2, dy + dh / 2
    c:rect(mid - 28, cy - 84, 56, 56, 16, C.accent_soft)
    ui.icon(c, "upload", mid - 12, cy - 68, 24, C.accent_text)
    c:text(mid, cy - 6, 5, 18, C.text, "Drop a video here", { bold = true })
    c:text(mid, cy + 18, 5, 13, C.muted, "MKV, MP4, WebM, anything mpv plays")
    local bw = 112
    local kw = ui.textw("Ctrl+O", 11) + 12
    local bx = mid - (bw + 10 + kw) / 2
    ui.button(c, bx, cy + 44, bw, 40, "Open file…", "primary")
    c:box(bx, cy + 44, bw, 40, { kind = "open" })
    ui.kbd(c, bx + bw + 10, cy + 55, "Ctrl+O")
    -- url field
    local uy = bottom - url_h
    local play_w = 92
    local fw = lw - 10 - play_w
    c:rect(lx, uy, fw, url_h, 10, C.surface, 0, m.url_focus and C.accent or C.border_strong, 1)
    ui.icon(c, "link", lx + 14, uy + 13, 18, C.muted)
    if m.url and m.url ~= "" then
        c:text(lx + 42, uy + 22, 4, 14, C.text, ui.fit(m.url .. (m.url_focus and "|" or ""), 14, fw - 120))
    else
        c:text(lx + 42, uy + 22, 4, 14, C.faint, m.url_focus and "|" or "Paste a YouTube or video link")
    end
    local kw2 = ui.textw("Ctrl+V", 11) + 12
    ui.kbd(c, lx + fw - 14 - kw2, uy + 13, "Ctrl+V")
    c:box(lx, uy, fw, url_h, { kind = "field" })
    ui.button(c, lx + fw + 10, uy, play_w, url_h, "Play link", "secondary")
    c:box(lx + fw + 10, uy, play_w, url_h, { kind = "play_link" })
    -- recent
    c:text(rx, top + 14, 4, 13, C.muted, "Recent", { bold = true })
    if #(m.recents or {}) > 0 then
        c:text(rx + rx_w, top + 14, 6, 12, C.faint, "Clear")
        c:box(rx + rx_w - 50, top, 50, 28, { kind = "clear" })
    end
    local ry = top + 36
    for i, r in ipairs(m.recents or {}) do
        if i > 6 then break end
        local ch = 64
        c:rect(rx, ry, rx_w, ch, 12, C.surface, 0, C.border, 1)
        c:rect(rx + 10, ry + 10, 72, 44, 6, C.overlay)
        if r.progress and r.progress > 0 then c:rect(rx + 10, ry + 51, 72 * math.min(1, r.progress), 3, 1, C.accent) end
        local fw2 = ui.textw(r.fps or "", 11, true) + 16
        local tw = rx_w - 94 - 12 - fw2 - 10
        c:text(rx + 94, ry + 24, 4, 13, C.text, ui.fit(r.title or "", 13, tw))
        c:text(rx + 94, ry + 43, 4, 11, C.muted, ui.fit(r.meta or "", 11, tw))
        if r.fps and r.fps ~= "" then ui.badge(c, rx + rx_w - 12 - fw2, ry + 22, r.fps) end
        c:box(rx, ry, rx_w, ch, { kind = "recent", index = i })
        ry = ry + ch + 10
    end
    if #(m.recents or {}) == 0 then
        c:text(rx, top + 50, 4, 12, C.faint, "Nothing yet. Videos you open show up here.")
    else
        c:text(rx, ry + 8, 4, 11, C.faint, "Picks up where you left off. Right-click a card to remove it.")
    end
    -- status strip
    local sy = H - 44
    c:rect(0, sy, W, 1, 0, C.border)
    local sx = 24
    for _, s in ipairs(m.strip or {}) do
        c:text(sx, sy + 22, 4, 12, C.muted, s)
        sx = sx + ui.textw(s, 12) + 18
    end
    c:text(W - 24, sy + 22, 6, 12, C.faint, m.version or "")
    return c
end

-- Loading screen while yt-dlp resolves a link (the window would otherwise sit black for a few seconds).
-- m = { W, H, url, elapsed }
function M.loading(m)
    local W, H = m.W or ui.W, m.H or ui.H
    local c = ui.canvas(W, H)
    c:rect(0, 0, W, H, 0, C.bg)
    c:box(0, 0, W, H, { kind = "none" })
    local cy = H / 2
    ui.mark(c, W / 2 - 20, cy - 92, 40)
    c:text(W / 2, cy - 18, 5, 20, C.text, "Fetching video info…", { bold = true })
    c:text(W / 2, cy + 10, 5, 13, C.muted, ui.fit(m.url or "", 13, W * 0.6))
    -- progress strip: a dot that walks across, driven by elapsed time
    local bw, bh = 220, 4
    local bx = W / 2 - bw / 2
    c:rect(bx, cy + 36, bw, bh, 2, C.overlay)
    local t = (m.elapsed or 0) % 1.6 / 1.6
    c:rect(bx + (bw - 48) * (t < 0.5 and t * 2 or (1 - t) * 2), cy + 36, 48, bh, 2, C.accent)
    c:text(W / 2, cy + 64, 5, 12, C.faint, "yt-dlp is reading the formats · Esc cancels")
    local kw = ui.textw("Cancel", 13, true) + 28
    ui.button(c, W / 2 - kw / 2, cy + 84, kw, 32, "Cancel", "ghost")
    c:box(W / 2 - kw / 2, cy + 84, kw, 32, { kind = "cancel" })
    return c
end

return M
