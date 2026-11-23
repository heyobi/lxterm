# Draws the LxTerm app icon (1024x1024, no alpha): a terminal prompt on a dark tile.
# Usage: python scripts/icon.py lxios/AppIcon.png
from PIL import Image, ImageDraw, ImageFilter
import sys

S = 1024
img = Image.new('RGB', (S, S))
d = ImageDraw.Draw(img)
for y in range(S):
    t = y / S
    d.line([(0, y), (S, y)], fill=(int(14 + 10 * t), int(16 + 14 * t), int(24 + 26 * t)))

glow = Image.new('RGBA', (S, S), (0, 0, 0, 0))
gd = ImageDraw.Draw(glow)
gd.ellipse([140, 220, 880, 900], fill=(60, 230, 140, 60))
glow = glow.filter(ImageFilter.GaussianBlur(150))
img.paste(glow, (0, 0), glow)
d = ImageDraw.Draw(img)

# terminal window
d.rounded_rectangle([120, 190, 904, 834], radius=70, fill=(22, 24, 32), outline=(70, 76, 92), width=10)
d.rounded_rectangle([120, 190, 904, 300], radius=70, fill=(40, 43, 56))
d.rectangle([120, 250, 904, 300], fill=(40, 43, 56))
for i, col in enumerate([(236, 95, 90), (245, 190, 80), (98, 200, 100)]):
    cx = 200 + i * 70
    d.ellipse([cx - 22, 223, cx + 22, 267], fill=col)

# ">" chevron and "_" cursor
G = (80, 235, 140)
d.line([(250, 430), (420, 545), (250, 660)], fill=G, width=62, joint='curve')
d.rounded_rectangle([480, 640, 760, 700], radius=18, fill=G)

img.save(sys.argv[1])
