"""BaginCam app icon generator (offline, Pillow + numpy).

Membuat ikon 1024x1024 untuk iOS (terang / gelap / tinted iOS 18-27) + gambar Logo untuk dalam app
+ preview. Jalankan:  python tools/brand/make_icon.py
Output:
  ios-app/BaginCam/Assets.xcassets/AppIcon.appiconset/AppIcon{,-dark,-tinted}.png
  ios-app/BaginCam/Assets.xcassets/Logo.imageset/Logo.png
  data/brand/preview.png
Konsep: lensa kamera dengan bilah aperture 6 kuning-oranye (warna aksen tombol app = kuning),
bukaan heksagon gelap seperti kaca, latar biru-arang.
"""
import json
import math
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ASSETS = os.path.join(ROOT, "ios-app", "BaginCam", "Assets.xcassets")
S = 2048  # supersample, diperkecil ke 1024
C = S / 2


def radial_bg(c0, c1, center=(0.5, 0.38), power=1.25):
    y, x = np.mgrid[0:S, 0:S].astype(np.float32) / S
    d = np.sqrt((x - center[0]) ** 2 + (y - center[1]) ** 2) / 0.85
    t = np.clip(d, 0, 1) ** power
    a, b = np.array(c0, np.float32), np.array(c1, np.float32)
    img = a * (1 - t[..., None]) + b * t[..., None]
    return Image.fromarray(img.astype(np.uint8), "RGB")


def circle(draw, r, fill=None, outline=None, width=0, cx=C, cy=C):
    draw.ellipse((cx - r, cy - r, cx + r, cy + r), fill=fill, outline=outline, width=width)


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def ray_circle(p, d, r):
    """titik potong sinar p + s*d (s>0) dengan lingkaran radius r di pusat C."""
    px, py = p[0] - C, p[1] - C
    dx, dy = d
    n = math.hypot(dx, dy)
    dx, dy = dx / n, dy / n
    b = px * dx + py * dy
    cc = px * px + py * py - r * r
    s = -b + math.sqrt(b * b - cc)
    return (C + px + s * dx, C + py + s * dy)


def foreground(mono=False):
    """lensa + aperture di atas latar transparan (RGBA, ukuran S)."""
    fg = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(fg)
    R_body, R_ring, R_blade, R_open = 0.385 * S, 0.335 * S, 0.300 * S, 0.118 * S
    # badan lensa: cincin logam
    ring = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    rd = ImageDraw.Draw(ring)
    steps = 60
    for i in range(steps):
        t = i / (steps - 1)
        r = R_body - (R_body - R_ring) * t
        col = lerp((96, 102, 114), (22, 25, 31), t ** 0.7)
        circle(rd, r, fill=col + (255,))
    fg.alpha_composite(ring)
    circle(d, R_body, outline=(150, 158, 170, 255), width=int(0.006 * S))
    circle(d, R_ring, fill=(6, 7, 10, 255))

    # bilah aperture
    rot = math.radians(-12)
    V = [(C + R_open * math.cos(rot + k * math.pi / 3), C + R_open * math.sin(rot + k * math.pi / 3)) for k in range(6)]
    P = []
    for k in range(6):
        prev = V[k - 1]
        P.append(ray_circle(V[k], (V[k][0] - prev[0], V[k][1] - prev[1]), R_blade))
    c_hi, c_lo = (255, 214, 10), (255, 140, 0)        # kuning Apple -> oranye
    blades = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    bd = ImageDraw.Draw(blades)
    for k in range(6):
        k2 = (k + 1) % 6
        a0 = math.atan2(P[k2][1] - C, P[k2][0] - C)
        a1 = math.atan2(P[k][1] - C, P[k][0] - C)
        da = (a1 - a0) % (2 * math.pi)
        if da > math.pi:
            da -= 2 * math.pi
        arc = [(C + R_blade * math.cos(a0 + da * j / 40), C + R_blade * math.sin(a0 + da * j / 40)) for j in range(41)]
        poly = [V[k], V[k2]] + arc + [V[k]]
        mid = math.atan2(sum(p[1] for p in poly) / len(poly) - C, sum(p[0] for p in poly) / len(poly) - C)
        t = 0.5 + 0.5 * math.cos(mid - math.radians(-135))      # cahaya dari kiri atas
        col = lerp(c_lo, c_hi, t)
        bd.polygon(poly, fill=col + (255,))
    # bayangan ke arah bukaan (radial)
    y, x = np.mgrid[0:S, 0:S].astype(np.float32)
    rr = np.sqrt((x - C) ** 2 + (y - C) ** 2)
    shade = np.clip((rr - R_open) / (R_blade - R_open), 0, 1)
    shade = 0.78 + 0.22 * np.sqrt(shade)
    arr = np.array(blades).astype(np.float32)
    arr[..., :3] *= shade[..., None]
    blades = Image.fromarray(arr.clip(0, 255).astype(np.uint8), "RGBA")
    bd = ImageDraw.Draw(blades)
    for k in range(6):
        bd.line([V[k], P[k]], fill=(70, 34, 0, 255), width=int(0.007 * S))
    fg.alpha_composite(blades)

    # bukaan: kaca gelap + pantulan
    glass = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glass)
    gd.polygon(V, fill=(10, 14, 28, 255))
    g = np.array(glass).astype(np.float32)
    tt = np.clip(((x - (C - R_open)) + (y - (C - R_open))) / (4 * R_open), 0, 1)
    tint = np.stack([18 + 20 * tt, 30 + 40 * tt, 60 + 70 * tt], -1)
    m = g[..., 3:] / 255
    g[..., :3] = tint * m
    glass = Image.fromarray(g.clip(0, 255).astype(np.uint8), "RGBA")
    fg.alpha_composite(glass)
    glint = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(glint).ellipse((C - 0.075 * S, C - 0.080 * S, C - 0.020 * S, C - 0.045 * S), fill=(255, 255, 255, 200))
    fg.alpha_composite(glint.filter(ImageFilter.GaussianBlur(0.006 * S)))
    small = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    circle(ImageDraw.Draw(small), 0.012 * S, fill=(255, 255, 255, 150), cx=C + 0.045 * S, cy=C + 0.040 * S)
    fg.alpha_composite(small.filter(ImageFilter.GaussianBlur(0.004 * S)))
    # kilau tipis di cincin luar (kiri atas)
    hl = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(hl).arc((C - R_body + 0.012 * S, C - R_body + 0.012 * S, C + R_body - 0.012 * S, C + R_body - 0.012 * S),
                           200, 250, fill=(255, 255, 255, 120), width=int(0.010 * S))
    fg.alpha_composite(hl.filter(ImageFilter.GaussianBlur(0.004 * S)))

    if mono:
        a = np.array(fg).astype(np.float32)
        lum = a[..., 0] * 0.299 + a[..., 1] * 0.587 + a[..., 2] * 0.114
        a[..., 0] = a[..., 1] = a[..., 2] = np.clip(lum * 1.15, 0, 255)
        fg = Image.fromarray(a.astype(np.uint8), "RGBA")
    return fg


def finish(img):
    return img.resize((1024, 1024), Image.LANCZOS)


def squircle_mask(n):
    m = Image.new("L", (n * 4, n * 4), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, n * 4 - 1, n * 4 - 1), radius=int(n * 4 * 0.2237), fill=255)
    return m.resize((n, n), Image.LANCZOS)


def main():
    fg = foreground()
    light = radial_bg((38, 48, 68), (8, 10, 15))
    light.paste(fg, (0, 0), fg)
    dark = Image.new("RGB", (S, S), (0, 0, 0))
    dark.paste(fg, (0, 0), fg)
    fgm = foreground(mono=True)
    tinted = Image.new("RGB", (S, S), (0, 0, 0))
    tinted.paste(fgm, (0, 0), fgm)

    icon_dir = os.path.join(ASSETS, "AppIcon.appiconset")
    logo_dir = os.path.join(ASSETS, "Logo.imageset")
    os.makedirs(icon_dir, exist_ok=True)
    os.makedirs(logo_dir, exist_ok=True)
    out = {"AppIcon.png": light, "AppIcon-dark.png": dark, "AppIcon-tinted.png": tinted}
    for n, im in out.items():
        finish(im).save(os.path.join(icon_dir, n), optimize=True)
    json.dump({"images": [
        {"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        {"appearances": [{"appearance": "luminosity", "value": "dark"}],
         "filename": "AppIcon-dark.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        {"appearances": [{"appearance": "luminosity", "value": "tinted"}],
         "filename": "AppIcon-tinted.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
    ], "info": {"author": "xcode", "version": 1}}, open(os.path.join(icon_dir, "Contents.json"), "w"), indent=2)
    # logo dalam app (Pengaturan > Info): ikon bermasker, latar transparan
    logo = finish(light).resize((360, 360), Image.LANCZOS)
    logo.putalpha(squircle_mask(360))
    logo.save(os.path.join(logo_dir, "Logo.png"), optimize=True)
    json.dump({"images": [{"filename": "Logo.png", "idiom": "universal"}], "info": {"author": "xcode", "version": 1}},
              open(os.path.join(logo_dir, "Contents.json"), "w"), indent=2)
    json.dump({"info": {"author": "xcode", "version": 1}}, open(os.path.join(ASSETS, "Contents.json"), "w"), indent=2)

    # preview: terang / gelap / tinted di latar wallpaper
    pv = Image.new("RGB", (3 * 300 + 4 * 40, 380), (210, 214, 222))
    ImageDraw.Draw(pv).rectangle((0, 190, pv.width, pv.height), fill=(28, 28, 30))
    for i, im in enumerate([light, dark, tinted]):
        t = finish(im).resize((240, 240), Image.LANCZOS).convert("RGBA")
        t.putalpha(squircle_mask(240))
        pv.paste(t, (40 + i * 340, 70), t)
    os.makedirs(os.path.join(ROOT, "data", "brand"), exist_ok=True)
    pv.save(os.path.join(ROOT, "data", "brand", "preview.png"))
    finish(light).save(os.path.join(ROOT, "data", "brand", "BaginCam-icon-1024.png"))
    print("ok", icon_dir)


if __name__ == "__main__":
    main()
