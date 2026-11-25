"""Report bright pixels in the band the round panel cuts off (debug helper).

A pixel counts when its luminance is > 60 and it lies farther than R - 12 px
(6 dp at density 320) from the centre of the inscribed circle.
"""
import math, sys
from PIL import Image

img = Image.open(sys.argv[1]).convert("RGB")
w, h = img.size
cx, cy, r = w / 2, h / 2, min(w, h) / 2
lim = r - 12
px = img.load()
bad = []
for y in range(h):
    for x in range(w):
        d = math.hypot(x + 0.5 - cx, y + 0.5 - cy)
        if d <= lim:
            continue
        rr, gg, bb = px[x, y]
        if 0.299 * rr + 0.587 * gg + 0.114 * bb > 60:
            bad.append((x, y))
print("rim: %d bright px outside r-12%s" % (len(bad), (" e.g. " + str(bad[:4])) if bad else ""))
