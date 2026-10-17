#!/usr/bin/env python3
# Regenerates Resources/AppIcon.icns: python3 scripts/make-icon.py Resources/AppIcon (needs Pillow)
import sys
from PIL import Image, ImageDraw, ImageFilter
S = 1024
def icon():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    # macOS Big Sur+ icon grid: 824px rounded square centred, radius ~185
    inset, size, radius = 100, 824, 185
    # soft shadow
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([inset, inset + 14, inset + size, inset + size + 14], radius, fill=(0, 0, 0, 90))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(18)))
    # gradient body (Raycast-like warm red → coral)
    grad = Image.new("RGBA", (S, S))
    top, bottom = (255, 112, 102), (222, 38, 66)
    for y in range(S):
        t = y / S
        c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,)
        ImageDraw.Draw(grad).line([(0, y), (S, y)], fill=c)
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([inset, inset, inset + size, inset + size], radius, fill=255)
    img.paste(grad, (0, 0), mask)
    # four-point sparkle glyph
    d = ImageDraw.Draw(img)
    cx, cy, r, w = S // 2, S // 2, 270, 70
    pts = [(cx, cy - r), (cx + w, cy - w), (cx + r, cy), (cx + w, cy + w), (cx, cy + r), (cx - w, cy + w), (cx - r, cy), (cx - w, cy - w)]
    d.polygon(pts, fill=(255, 255, 255, 255))
    sr, sw = 95, 26
    sx, sy = cx + 215, cy - 215
    d.polygon([(sx, sy - sr), (sx + sw, sy - sw), (sx + sr, sy), (sx + sw, sy + sw), (sx, sy + sr), (sx - sw, sy + sw), (sx - sr, sy), (sx - sw, sy - sw)], fill=(255, 255, 255, 230))
    return img
out = sys.argv[1]
img = icon()

img.save(out + ".icns", sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])
