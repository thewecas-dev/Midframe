"""Draws packaging/banner.png (1280x640, GitHub social-preview size) in the icon's style.
Run on macOS with Pillow:  python3 packaging/make_banner.py   (fonts: Helvetica Neue, Menlo)"""
import os

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
W, H = 2560, 1280  # drawn at 2x
BG0, BG1 = (0x14, 0x12, 0x1B), (0x27, 0x20, 0x3A)
ACCENT = (0x8B, 0x6C, 0xFF)
WHITE = (0xF7, 0xF4, 0xF2)
MUTED = (0xA8, 0xA2, 0xBA)


def font(name, size, index=0):
    return ImageFont.truetype(f"/System/Library/Fonts/{name}", size, index=index)


def tri(d, cx, cy, size, fill):
    h = size * 0.95
    d.polygon([(cx - size * 0.42, cy - h / 2), (cx - size * 0.42, cy + h / 2), (cx + size * 0.58, cy)], fill=fill)


def draw():
    img = Image.new("RGBA", (W, H))
    d = ImageDraw.Draw(img)
    for y in range(H):  # diagonal-ish gradient: vertical blend, same family as the icon
        t = y / (H - 1)
        d.line([(0, y), (W, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(BG0, BG1)) + (255,))
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([W * 0.02, H * 0.05, W * 0.42, H * 0.95], fill=ACCENT + (90,))
    img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(160)))

    # mark (left)
    d = ImageDraw.Draw(img, "RGBA")
    cx, cy, size = W * 0.20, H * 0.46, 380
    tri(d, cx - size * 0.34, cy, size, ACCENT + (70,))
    tri(d, cx - size * 0.17, cy, size, ACCENT + (150,))
    tri(d, cx, cy, size, WHITE + (255,))

    # wordmark + tagline (right)
    x = W * 0.38
    d.text((x, H * 0.27), "Midframe", font=font("HelveticaNeue.ttc", 230, index=1), fill=WHITE, anchor="ls")
    d.text((x + 8, H * 0.27 + 90), "Watch 24 fps films at 144.", font=font("HelveticaNeue.ttc", 76), fill=WHITE, anchor="ls")
    d.text((x + 8, H * 0.27 + 180), "Real-time AI frame interpolation for Windows. Free.",
           font=font("HelveticaNeue.ttc", 54), fill=MUTED, anchor="ls")

    # frame strip: solid source frames with generated (ghost accent) frames in between
    y0, fh, fw, gap = H * 0.66, 190, 118, 20
    sx = x + 8
    n = int((W * 0.955 - sx + gap) // (fw + gap))
    n -= (n - 1) % 3  # end on a source frame
    strip_w = n * fw + (n - 1) * gap
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ld = ImageDraw.Draw(layer)
    for i in range(n):
        fx = sx + i * (fw + gap)
        if i % 3 == 0:
            ld.rounded_rectangle([fx, y0, fx + fw, y0 + fh], radius=18, fill=WHITE + (255,))
        else:
            ld.rounded_rectangle([fx, y0, fx + fw, y0 + fh], radius=18, outline=ACCENT + (230,), width=5, fill=ACCENT + (80,))
    img.alpha_composite(layer)
    d = ImageDraw.Draw(img, "RGBA")
    mono = font("Menlo.ttc", 38, index=1)
    d.text((sx, y0 + fh + 52), "24 fps source", font=mono, fill=WHITE, anchor="ls")
    d.text((sx + strip_w, y0 + fh + 52), "+ frames generated live by RIFE = 72 fps", font=mono, fill=ACCENT, anchor="rs")
    return img


def main():
    out = os.path.join(HERE, "banner.png")
    draw().resize((W // 2, H // 2), Image.LANCZOS).convert("RGB").save(out)
    print("wrote", out)


if __name__ == "__main__":
    main()
