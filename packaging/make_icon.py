"""Draws the app icon: packaging/icon.png (512 px) and packaging/icon.ico (16-256 px).
Run on any OS with Pillow:  python3 packaging/make_icon.py
A play mark with two fading "in-between" copies behind it: the frames Midframe generates."""
import os

from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
S = 1024  # drawn at 2x, downsampled for clean edges
BG0, BG1 = (0x14, 0x12, 0x1B), (0x27, 0x20, 0x3A)  # tile gradient (same family as the UI theme)
ACCENT = (0x8B, 0x6C, 0xFF)                        # UI accent (ASS &HFF6C8B& in BGR)
WHITE = (0xF7, 0xF4, 0xF2)


def tri(d, cx, cy, size, fill):
    h = size * 0.95
    d.polygon([(cx - size * 0.42, cy - h / 2), (cx - size * 0.42, cy + h / 2), (cx + size * 0.58, cy)], fill=fill)


def draw():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    # tile with vertical gradient and rounded corners
    tile = Image.new("RGBA", (S, S))
    td = ImageDraw.Draw(tile)
    for y in range(S):
        t = y / (S - 1)
        td.line([(0, y), (S, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(BG0, BG1)) + (255,))
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=S * 0.22, fill=255)
    img.paste(tile, mask=mask)
    # soft accent glow behind the mark
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([S * 0.22, S * 0.22, S * 0.86, S * 0.78], fill=ACCENT + (110,))
    glow = glow.filter(ImageFilter.GaussianBlur(S * 0.09))
    img.alpha_composite(glow)
    # two ghost frames trailing, then the solid play mark
    d = ImageDraw.Draw(img, "RGBA")
    cx, cy, size = S * 0.56, S * 0.5, S * 0.44
    tri(d, cx - size * 0.34, cy, size, ACCENT + (70,))
    tri(d, cx - size * 0.17, cy, size, ACCENT + (150,))
    tri(d, cx, cy, size, WHITE + (255,))
    return img


def main():
    img = draw()
    png = img.resize((512, 512), Image.LANCZOS)
    png.save(os.path.join(HERE, "icon.png"))
    sizes = [(s, s) for s in (16, 24, 32, 48, 64, 128, 256)]
    img.resize((256, 256), Image.LANCZOS).save(os.path.join(HERE, "icon.ico"), sizes=sizes)
    print("wrote icon.png, icon.ico")


if __name__ == "__main__":
    main()
