"""Draws the SkyFindr launcher icon (magnifying glass with a plane in the lens, on a sky-blue gradient).

    backend\\.venv\\Scripts\\python app\\tool\\make_icon.py
    cd app; flutter pub run flutter_launcher_icons

Writes assets/icon/icon.png (full icon), icon_foreground.png + icon_background.png (Android adaptive).
"""
import os
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

S = 1024
SS = 4  # supersampling for smooth edges
OUT = Path(__file__).resolve().parent.parent / "assets" / "icon"
FONT = Path(os.environ.get("FLUTTER_ROOT", r"C:\src\flutter")) / "bin/cache/artifacts/material_fonts/materialicons-regular.otf"
FLIGHT = "\ue297"  # Icons.flight
TOP, BOTTOM = (0x4C, 0x8D, 0xF6), (0x1E, 0x4F, 0xC9)  # theme primary #1E5BD7, lighter at the top


def background(size: int) -> Image.Image:
    img = Image.new("RGB", (size, size))
    d = ImageDraw.Draw(img)
    for y in range(size):
        t = y / (size - 1)
        d.line([(0, y), (size, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM)))
    return img


def glyph(scale: float) -> Image.Image:
    """White magnifier + plane on transparent, `scale` = fraction of the canvas the drawing spans."""
    n = S * SS
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    u = n * scale / 1000  # drawing units: the artwork is designed on a 1000-unit box
    ox = oy = (n - 1000 * u) / 2

    def P(x, y):
        return (ox + x * u, oy + y * u)

    cx, cy, r, ring = 410, 410, 300, 78
    # Handle (drawn first so the ring covers its end), with a rounded tip.
    hw = 120
    a, b = P(cx + 0.70 * r, cy + 0.70 * r), P(905, 905)
    d.line([a, b], fill="white", width=round(hw * u))
    d.ellipse([b[0] - hw * u / 2, b[1] - hw * u / 2, b[0] + hw * u / 2, b[1] + hw * u / 2], fill="white")
    # Lens ring.
    d.ellipse([*P(cx - r, cy - r), *P(cx + r, cy + r)], outline="white", width=round(ring * u))
    # Plane, heading up-right inside the lens.
    font = ImageFont.truetype(str(FONT), round(400 * u))
    plane = Image.new("RGBA", (round(500 * u),) * 2, (0, 0, 0, 0))
    ImageDraw.Draw(plane).text((plane.width / 2, plane.height / 2), FLIGHT, font=font, fill="white", anchor="mm")
    plane = plane.rotate(-45, resample=Image.BICUBIC)
    px, py = P(cx, cy)
    img.alpha_composite(plane, (round(px - plane.width / 2), round(py - plane.height / 2)))
    return img.resize((S, S), Image.LANCZOS)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    # Full icon (iOS, Windows, web, legacy Android): rounded corners are applied by the OS where needed.
    full = background(S).convert("RGBA")
    shadow = glyph(0.66)
    tint = Image.new("RGBA", (S, S), (10, 30, 90, 0))
    tint.putalpha(shadow.getchannel("A").point(lambda v: v * 0.25))
    full.alpha_composite(tint, (0, 14))  # soft drop shadow
    full.alpha_composite(shadow)
    full.convert("RGB").save(OUT / "icon.png")
    # Android adaptive icon: artwork inside the 66% safe zone, background separate.
    glyph(0.46).save(OUT / "icon_foreground.png")
    background(S).save(OUT / "icon_background.png")
    print("wrote", ", ".join(p.name for p in OUT.iterdir()))


if __name__ == "__main__":
    main()
