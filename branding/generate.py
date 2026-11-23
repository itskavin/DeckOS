"""Generate every DeckOS brand icon from the one source image.

    python -I branding/generate.py            # from the repo root; needs Pillow

Nothing here redraws the logo. Every output is a resize or crop of
branding/source/deckos-logo-source.png. Two operations change pixels outside the artwork:

* Transparency: the dark background around the rounded plate is removed. It is found by a
  flood fill from the image border that stops at the plate's light outline.
* Plate extension: launcher and store icons need a full-bleed square, and Android needs a
  separate background layer. For these, the plate's own diagonal gradient is fitted to the
  source and extended past the plate, and the plate's interior (without its outline) goes on top.

See branding/README.md for which file goes where.
"""

import base64
import io
import os
import re
import sys
from collections import deque

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "branding", "source", "deckos-logo-source.png")

# Below this luminance, a pixel connected to the image border is background.
# The plate's outline is 45-67, and the background is 8-18.
BG_THRESHOLD = 26
BG_LUMA = 15
OUTLINE_LUMA = 45
# How far the outline and its anti-aliasing reach into the plate, in source pixels.
OUTLINE_ERODE = 8

# Full-bleed icon (iOS, Android viewport): the visible square is this much larger than the
# plate, so the 3×3 grid stays well inside a 66 dp circle on Android (about 44 of 72 dp).
VIEWPORT_SCALE = 1.08
# Android adaptive layer: 108 dp, of which 72 dp are the viewport.
LAYER_SCALE = VIEWPORT_SCALE * 108 / 72
# Web maskable icon: the grid has to fit the central 80% circle.
MASKABLE_SCALE = 1.20
SHARPEN_MAX = 48

ANDROID_DENSITIES = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}


def rel(*parts):
    return os.path.join(ROOT, *parts)


def luma(c):
    r, g, b = c[:3]
    return (299 * r + 587 * g + 114 * b) / 1000


def resize(img, size):
    """Lanczos resize in premultiplied alpha, so transparent pixels don't darken the edges.

    At 48 px and below a light unsharp mask on the colour keeps the 3×3 grid readable
    (tray, favicons, small launcher sizes); alpha is left as resized.
    """
    if img.mode == "RGBA":
        out = img.convert("RGBa").resize((size, size), Image.LANCZOS).convert("RGBA")
    else:
        out = img.resize((size, size), Image.LANCZOS)
    if size > SHARPEN_MAX:
        return out
    rgb = out.convert("RGB").filter(ImageFilter.UnsharpMask(radius=0.6, percent=70, threshold=0))
    if out.mode == "RGBA":
        rgb.putalpha(out.getchannel("A"))
    return rgb


def save_png(img, *path):
    full = rel(*path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    img.save(full, "PNG", optimize=True)
    return full


# ---------------------------------------------------------------- source analysis


def cut_out_plate(src):
    """Source as RGBA with the background around the plate made transparent."""
    w, h = src.size
    px = src.load()
    lum = [[luma(px[x, y]) for x in range(w)] for y in range(h)]
    outside = [[False] * w for _ in range(h)]
    queue = deque()
    for x in range(w):
        queue.extend([(x, 0), (x, h - 1)])
    for y in range(h):
        queue.extend([(0, y), (w - 1, y)])
    while queue:
        x, y = queue.popleft()
        if outside[y][x] or lum[y][x] >= BG_THRESHOLD:
            continue
        outside[y][x] = True
        for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if 0 <= nx < w and 0 <= ny < h and not outside[ny][nx]:
                queue.append((nx, ny))

    filled = sum(row.count(True) for row in outside)
    if not 0.02 < filled / (w * h) < 0.2:
        sys.exit(f"flood fill leaked into the plate ({filled} of {w * h} px); check BG_THRESHOLD")

    rgba = Image.new("RGBA", src.size)
    out = rgba.load()
    bg = (15, 16, 20)
    for y in range(h):
        for x in range(w):
            r, g, b = px[x, y]
            if outside[y][x]:
                out[x, y] = (r, g, b, 0)
                continue
            edge = any(
                0 <= nx < w and 0 <= ny < h and outside[ny][nx]
                for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1))
            )
            if not edge:
                out[x, y] = (r, g, b, 255)
                continue
            # Anti-aliased rim of the outline: take the background out of the colour.
            a = min(1.0, max(0.0, (lum[y][x] - BG_LUMA) / (OUTLINE_LUMA - BG_LUMA)))
            if a == 0:
                out[x, y] = (r, g, b, 0)
                continue
            un = [min(255, max(0, round((c - (1 - a) * k) / a))) for c, k in zip((r, g, b), bg)]
            out[x, y] = (*un, round(a * 255))
    return rgba


def square_bounds(rgba):
    """Square box (float centre, side) around the visible plate."""
    x0, y0, x1, y1 = rgba.getchannel("A").getbbox()
    return (x0 + x1) / 2, (y0 + y1) / 2, max(x1 - x0, y1 - y0)


def plate_interior(rgba):
    """The plate without its outline: soft-edged alpha, source colours."""
    alpha = rgba.getchannel("A").point(lambda a: 255 if a >= 128 else 0)
    alpha = alpha.filter(ImageFilter.MinFilter(2 * OUTLINE_ERODE + 1))
    alpha = alpha.filter(ImageFilter.GaussianBlur(1.2))
    inner = rgba.copy()
    inner.putalpha(alpha)
    return inner


def fit_plate_gradient(src, rgba):
    """Least-squares c = k + gx*x + gy*y per channel on plain plate pixels (no glow, no outline)."""
    alpha = rgba.getchannel("A").point(lambda a: 255 if a >= 128 else 0)
    alpha = alpha.filter(ImageFilter.MinFilter(2 * (OUTLINE_ERODE + 6) + 1)).load()
    px = src.load()
    w, h = src.size
    rows = []
    for y in range(0, h, 2):
        for x in range(0, w, 2):
            if alpha[x, y] < 255:
                continue
            r, g, b = px[x, y]
            # The amber glow lifts red over blue; plain plate is slightly blue.
            if r - b > 2 or luma((r, g, b)) > 48:
                continue
            rows.append((x, y, (r, g, b)))
    if len(rows) < 2000:
        sys.exit("too few plain plate pixels to fit the gradient")

    def solve(ch):
        s = [[0.0] * 3 for _ in range(3)]
        t = [0.0] * 3
        for x, y, c in rows:
            v = (1.0, x, y)
            for i in range(3):
                t[i] += v[i] * c[ch]
                for j in range(3):
                    s[i][j] += v[i] * v[j]
        # Gaussian elimination on the 3×3 normal equations.
        m = [s[i] + [t[i]] for i in range(3)]
        for i in range(3):
            p = max(range(i, 3), key=lambda r: abs(m[r][i]))
            m[i], m[p] = m[p], m[i]
            for r in range(3):
                if r != i:
                    f = m[r][i] / m[i][i]
                    m[r] = [a - f * b for a, b in zip(m[r], m[i])]
        return [m[i][3] / m[i][i] for i in range(3)]

    coeffs = [solve(ch) for ch in range(3)]
    err = sum(
        abs(c[ch] - (coeffs[ch][0] + coeffs[ch][1] * x + coeffs[ch][2] * y))
        for x, y, c in rows
        for ch in range(3)
    ) / (3 * len(rows))
    return coeffs, err, len(rows)


# ---------------------------------------------------------------- layers


class Layers:
    def __init__(self):
        self.src = Image.open(SOURCE).convert("RGB")
        self.logo = cut_out_plate(self.src)
        self.cx, self.cy, self.plate = square_bounds(self.logo)
        self.inner = plate_interior(self.logo)
        self.gradient, self.gradient_err, self.gradient_n = fit_plate_gradient(self.src, self.logo)

        side = self.plate + 2
        self.master = self._place(self.logo, side, transparent=True)

        layer = round(self.plate * LAYER_SCALE)
        self.layer_side = layer
        self.foreground = self._place(self.inner, layer, transparent=True)
        self.background = self._gradient(layer)
        comp = self.background.convert("RGBA")
        comp.alpha_composite(self.foreground)
        self.composite = comp.convert("RGB")

    def _origin(self, side):
        return self.cx - side / 2, self.cy - side / 2

    def _place(self, img, side, transparent):
        canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
        ox, oy = self._origin(side)
        canvas.alpha_composite(img, (round(-ox), round(-oy)))
        return canvas

    def _gradient(self, side):
        ox, oy = self._origin(side)
        data = []
        for y in range(side):
            sy = oy + y
            for x in range(side):
                sx = ox + x
                data.append(
                    tuple(
                        min(255, max(0, round(k + gx * sx + gy * sy)))
                        for k, gx, gy in self.gradient
                    )
                )
        img = Image.new("RGB", (side, side))
        img.putdata(data)
        return img

    def crop_composite(self, scale):
        """Opaque full-bleed square, `scale` times the plate, centred on the grid."""
        side = round(self.plate * scale)
        off = (self.layer_side - side) // 2
        return self.composite.crop((off, off, off + side, off + side))

    def master_padded(self, size, content):
        """Transparent logo of `content` px centred on a `size` px canvas."""
        canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        logo = resize(self.master, content)
        off = (size - content) // 2
        canvas.alpha_composite(logo, (off, off))
        return canvas


def circle_masked(img, size, diameter):
    """`img` resized to `diameter`, cut to a circle, centred on a transparent `size` canvas."""
    ss = 4
    big = img.convert("RGBA").resize((diameter * ss, diameter * ss), Image.LANCZOS)
    mask = Image.new("L", big.size, 0)
    ImageDraw.Draw(mask).ellipse((0, 0, big.size[0] - 1, big.size[1] - 1), fill=255)
    big.putalpha(mask)
    disc = big.convert("RGBa").resize((diameter, diameter), Image.LANCZOS).convert("RGBA")
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    off = (size - diameter) // 2
    canvas.alpha_composite(disc, (off, off))
    return canvas


def ico_bytes(master, sizes):
    frames = [resize(master, s) for s in sizes]
    buf = io.BytesIO()
    frames[-1].save(buf, "ICO", sizes=[(s, s) for s in sizes], append_images=frames[:-1])
    return buf.getvalue()


# ---------------------------------------------------------------- outputs


def write_all(L):
    written = []

    def out(img, *path):
        written.append(save_png(img, *path))

    # Canonical exports.
    out(resize(L.master, 1024), "branding", "deckos-logo.png")
    out(resize(L.master, 256), "branding", "deckos-logo-256.png")
    out(resize(L.crop_composite(VIEWPORT_SCALE), 1024), "branding", "deckos-icon-1024.png")
    out(resize(L.crop_composite(VIEWPORT_SCALE), 512), "branding", "deckos-icon-512.png")

    # Flutter in-app logo (splash, onboarding, browser pairing). Drawn at up to 112 logical px,
    # so 512 covers 3x screens without decoding a 1024 px image during startup.
    out(resize(L.master, 512), "app", "assets", "images", "logo.png")

    # Android.
    res = ("app", "android", "app", "src", "main", "res")
    viewport = L.crop_composite(VIEWPORT_SCALE)
    for name, d in ANDROID_DENSITIES.items():
        mip = (*res, f"mipmap-{name}")
        out(resize(L.foreground, round(108 * d)), *mip, "ic_launcher_foreground.png")
        out(resize(L.background, round(108 * d)), *mip, "ic_launcher_background.png")
        out(L.master_padded(round(48 * d), round(46 * d)), *mip, "ic_launcher.png")
        out(circle_masked(viewport, round(48 * d), round(46 * d)), *mip, "ic_launcher_round.png")
        out(resize(L.master, round(112 * d)), *res, f"drawable-{name}", "launch_logo.png")

    # iOS: opaque full-bleed (iOS applies its own mask), plus the launch-screen logo.
    ios = ("app", "ios", "Runner", "Assets.xcassets")
    ios_icons = {
        "Icon-App-20x20@1x.png": 20, "Icon-App-20x20@2x.png": 40, "Icon-App-20x20@3x.png": 60,
        "Icon-App-29x29@1x.png": 29, "Icon-App-29x29@2x.png": 58, "Icon-App-29x29@3x.png": 87,
        "Icon-App-40x40@1x.png": 40, "Icon-App-40x40@2x.png": 80, "Icon-App-40x40@3x.png": 120,
        "Icon-App-60x60@2x.png": 120, "Icon-App-60x60@3x.png": 180,
        "Icon-App-76x76@1x.png": 76, "Icon-App-76x76@2x.png": 152,
        "Icon-App-83.5x83.5@2x.png": 167, "Icon-App-1024x1024@1x.png": 1024,
    }
    for name, size in ios_icons.items():
        out(resize(viewport, size), *ios, "AppIcon.appiconset", name)
    for name, size in {"LaunchImage.png": 112, "LaunchImage@2x.png": 224, "LaunchImage@3x.png": 336}.items():
        out(resize(L.master, size), *ios, "LaunchImage.imageset", name)

    # macOS: Big Sur grid, 824 px of artwork on a 1024 px canvas.
    mac = ("app", "macos", "Runner", "Assets.xcassets", "AppIcon.appiconset")
    for size in (16, 32, 64, 128, 256, 512, 1024):
        out(L.master_padded(size, round(size * 824 / 1024)), *mac, f"app_icon_{size}.png")

    # Web configurator (Flutter web, served by the PC app).
    maskable = L.crop_composite(MASKABLE_SCALE)
    out(resize(L.master, 32), "app", "web", "favicon.png")
    out(resize(L.master, 192), "app", "web", "icons", "Icon-192.png")
    out(resize(L.master, 512), "app", "web", "icons", "Icon-512.png")
    out(resize(maskable, 192), "app", "web", "icons", "Icon-maskable-192.png")
    out(resize(maskable, 512), "app", "web", "icons", "Icon-maskable-512.png")
    out(resize(viewport, 180), "app", "web", "icons", "apple-touch-icon.png")

    # Windows: PC app (exe, tray, installer) and the Flutter Windows runner.
    ico = ico_bytes(L.master, [16, 20, 24, 32, 40, 48, 64, 128, 256])
    for path in (("DeckOS", "deckos.ico"), ("app", "windows", "runner", "resources", "app_icon.ico")):
        with open(rel(*path), "wb") as f:
            f.write(ico)
        written.append(rel(*path))
    written.append(patch_resx(ico_bytes(L.master, [256])))

    # Marketing site, legacy landing pages and docs.
    out(resize(L.master, 32), "site", "favicon-32.png")
    out(resize(L.master, 192), "site", "logo.png")
    out(resize(L.master, 512), "site", "icon-512.png")
    out(resize(maskable, 512), "site", "icon-maskable-512.png")
    out(resize(viewport, 180), "site", "apple-touch-icon.png")
    out(resize(L.master, 192), "website", "landing", "logo.png")
    out(resize(L.master, 192), "website", "docs", "assets", "logo.png")
    written.append(patch_og(L))
    return written


def patch_resx(ico):
    """Designer icons in frmPrincipal.resx (replaced at run time by AppIcon, but shipped in the exe)."""
    path = rel("DeckOS", "frmPrincipal.resx")
    with open(path, encoding="utf-8", newline="") as f:
        text = f.read()
    nl = "\r\n" if "\r\n" in text else "\n"
    b64 = base64.b64encode(ico).decode()
    body = nl + "".join(f"        {b64[i:i + 80]}{nl}" for i in range(0, len(b64), 80))
    count = 0
    for name in ("ntiTray.Icon", "$this.Icon"):
        pattern = re.compile(r'(<data name="' + re.escape(name) + r'"[^>]*>\s*<value>)(.*?)(</value>)', re.S)
        text, n = pattern.subn(lambda m: m.group(1) + body + m.group(3), text)
        count += n
    if count != 2:
        sys.exit("frmPrincipal.resx: icon entries not found")
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)
    return path


def patch_og(L):
    """site/og.png: swap the 48 px header logo at (72, 72) on its black background."""
    path = rel("site", "og.png")
    og = Image.open(path).convert("RGB")
    box = (68, 68, 124, 124)
    px = og.load()
    # Only the old logo may live in the box; its surroundings are pure black.
    for x in range(box[0], box[2]):
        for y in (box[1], box[3] - 1):
            if max(px[x, y]) > 8:
                sys.exit("site/og.png: the header logo is not where expected")
    og.paste((0, 0, 0), box)
    canvas = og.convert("RGBA")
    canvas.alpha_composite(resize(L.master, 48), (72, 72))
    canvas.convert("RGB").save(path, "PNG", optimize=True)
    return path


def main():
    L = Layers()
    print(f"plate {L.plate}px centred at ({L.cx}, {L.cy}) in a {L.src.size} source")
    print(f"plate gradient fit: mean error {L.gradient_err:.2f}/255 over {L.gradient_n} px")
    for k, gx, gy in L.gradient:
        print(f"  {k:.1f} {gx:+.4f}x {gy:+.4f}y")
    for path in write_all(L):
        print(os.path.relpath(path, ROOT))


if __name__ == "__main__":
    main()
