from PIL import Image

SRC = r"D:\microlab_project\client\assets\icon\app_icon.png"
OUT = r"D:\microlab_project\client\assets\icon\app_launcher_icon.png"
CANVAS = 1024
# Android adaptive icons guarantee only the inner ~66% diameter circle of the
# foreground layer survives any mask shape (circle, squircle, rounded square,
# teardrop...). Scaling the logo to fit within 55% of the canvas leaves a
# deliberate safety margin so NO launcher/device mask can ever clip the
# flask icon, "MICROBES" text, or the "SINCE 1977" band.
SAFE_FRACTION = 0.55

# Brand-green canvas (sampled from the logo's own green, not an arbitrary
# pick) — a white canvas looked like an unwanted white border/card around
# the logo on the home screen. iOS icons must be fully opaque (no true
# transparency), so "no border" means matching the logo's own fill color
# rather than removing the canvas color entirely.
BRAND_GREEN = (67, 122, 65)

logo = Image.open(SRC).convert("RGBA")

# Flatten the logo onto brand green BEFORE resizing, not after. Resizing an
# RGBA image with a hard transparent/opaque edge (this source has no
# anti-aliasing — a clean 0/255 alpha cutoff) and pasting the result with a
# LANCZOS filter produces visible ringing: a faint ghost outline parallel to
# the edge, which read as an unwanted "outer rounded rectangle" border once
# composited onto the green canvas. Flattening first means the background
# pixels already match the canvas exactly, so there is no edge left for the
# resize filter to ring against — only the logo's real internal edges
# (flask linework, text) get resampled, which is fine since those were
# always meant to be smoothed.
flattened = Image.new("RGB", logo.size, BRAND_GREEN)
flattened.paste(logo, (0, 0), logo)

safe_box = int(CANVAS * SAFE_FRACTION)
scale = min(safe_box / flattened.width, safe_box / flattened.height)
new_w, new_h = round(flattened.width * scale), round(flattened.height * scale)
logo_resized = flattened.resize((new_w, new_h), Image.LANCZOS)

canvas = Image.new("RGB", (CANVAS, CANVAS), BRAND_GREEN)
offset = ((CANVAS - new_w) // 2, (CANVAS - new_h) // 2)
canvas.paste(logo_resized, offset)

canvas.save(OUT, "PNG")
print(f"Saved {OUT} — logo placed at {new_w}x{new_h} within a {CANVAS}x{CANVAS} canvas "
      f"(occupies {new_w/CANVAS:.0%} x {new_h/CANVAS:.0%} of the full icon)")
