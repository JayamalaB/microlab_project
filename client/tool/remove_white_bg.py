"""Removes only the outer white background surrounding the logo, via a
flood-fill that starts at the image border and only travels through
near-white pixels. Anything white INSIDE the logo (the MICROBES lettering,
the flask outlines) is never touched because it's enclosed by green/black
pixels and is never reached by a fill that starts from the outside.
"""
from PIL import Image
from collections import deque
import numpy as np

SRC = r"D:\microlab_project\client\assets\icon\app_icon.png"
OUT = r"D:\microlab_project\client\assets\icon\app_icon.png"
PREVIEW_ON_BLACK = r"D:\microlab_project\client\assets\icon\_preview_on_black.png"
PREVIEW_ON_BLUE  = r"D:\microlab_project\client\assets\icon\_preview_on_blue.png"

WHITE_THRESHOLD = 235  # a pixel counts as "background white" if every RGB channel >= this

img = Image.open(SRC).convert("RGBA")
w, h = img.size
arr = np.array(img)

rgb = arr[:, :, :3].astype(int)
is_white = np.all(rgb >= WHITE_THRESHOLD, axis=2)

visited = np.zeros((h, w), dtype=bool)
q = deque()

for x in range(w):
    for y in (0, h - 1):
        if is_white[y, x] and not visited[y, x]:
            visited[y, x] = True
            q.append((x, y))
for y in range(h):
    for x in (0, w - 1):
        if is_white[y, x] and not visited[y, x]:
            visited[y, x] = True
            q.append((x, y))

while q:
    x, y = q.popleft()
    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        nx, ny = x + dx, y + dy
        if 0 <= nx < w and 0 <= ny < h and not visited[ny, nx] and is_white[ny, nx]:
            visited[ny, nx] = True
            q.append((nx, ny))

removed = int(visited.sum())
arr[:, :, 3] = np.where(visited, 0, arr[:, :, 3])

out_img = Image.fromarray(arr, "RGBA")
out_img.save(OUT, "PNG")
print(f"Removed {removed} background pixels ({removed / (w*h):.1%} of {w}x{h} image). Saved to {OUT}")

# Visual-verification composites (so I can actually SEE the transparent areas
# and confirm no internal logo detail got punched through).
bg_black = Image.new("RGBA", (w, h), (0, 0, 0, 255))
bg_black.alpha_composite(out_img)
bg_black.convert("RGB").save(PREVIEW_ON_BLACK)

bg_blue = Image.new("RGBA", (w, h), (30, 90, 200, 255))
bg_blue.alpha_composite(out_img)
bg_blue.convert("RGB").save(PREVIEW_ON_BLUE)

print(f"Preview composites saved: {PREVIEW_ON_BLACK} and {PREVIEW_ON_BLUE}")
