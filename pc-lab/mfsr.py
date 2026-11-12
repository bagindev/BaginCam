"""
mfsr.py - Super Res Zoom (multi-frame super-resolution) prototipe, versi sederhana dari
Wronski et al. 2019 "Handheld Multi-Frame Super-Resolution" (Google Pixel Super Res Zoom).

Ide: goyangan tangan membuat tiap frame tergeser sub-piksel. Sampel Bayer semua frame
di-"splat" ke grid output yang lebih halus (scale s) dengan kernel Gaussian + alignment
sub-piksel -> RGB penuh per piksel tanpa demosaic, detail di atas resolusi 1 frame.

Langkah:
  1. ROI (crop zoom) + margin dari tiap frame Bayer.
  2. Alignment: pergeseran global (phase correlation, sub-piksel) lalu per tile
     (16 superpixel, stride 8): cari integer +-2 + fit parabola -> sub-piksel.
  3. Akumulasi per kanal: w = exp(-d^2 / 2 sigma^2) * robust, d = jarak sampel ke titik output.
  4. Normalisasi; piksel dengan bobot kecil -> isi dari demosaic bilinear frame referensi.

  python mfsr.py <folder DNG burst> [--roi 512] [--scale 2]
"""
import argparse
import glob
import subprocess
from pathlib import Path

import numpy as np
import rawpy

ET = r"C:\Users\ASUS\AppData\Local\Programs\ExifTool\ExifTool.exe"


def grey(b):
    return 0.25 * (b[0::2, 0::2] + b[0::2, 1::2] + b[1::2, 0::2] + b[1::2, 1::2])


def phase_shift(a, b):
    """geseran (dy, dx) sehingga b(x + d) ~ a(x), sub-piksel (parabola di puncak korelasi)"""
    A = np.fft.fft2(a - a.mean())
    B = np.fft.fft2(b - b.mean())
    R = A.conj() * B
    R /= np.abs(R) + 1e-9
    c = np.fft.ifft2(R).real
    py, px = np.unravel_index(np.argmax(c), c.shape)
    def sub(m1, m0, p1):
        d = m1 - 2 * m0 + p1
        return 0.0 if abs(d) < 1e-12 else 0.5 * (m1 - p1) / d
    H, W = c.shape
    dy = py + sub(c[(py - 1) % H, px], c[py, px], c[(py + 1) % H, px])
    dx = px + sub(c[py, (px - 1) % W], c[py, px], c[py, (px + 1) % W])
    if dy > H / 2: dy -= H
    if dx > W / 2: dx -= W
    return dy, dx


def tile_refine(gr, gc, g0, tile=16, stride=8, search=2):
    """per tile: SAD integer di sekitar geseran global + parabola -> medan geser (sub-piksel, satuan grey)"""
    H, W = gr.shape
    ny, nx = (H - tile) // stride + 1, (W - tile) // stride + 1
    field = np.zeros((ny, nx, 2), np.float32)
    gy0, gx0 = int(round(g0[0])), int(round(g0[1]))
    for ty in range(ny):
        for tx in range(nx):
            y0, x0 = ty * stride, tx * stride
            ref = gr[y0:y0 + tile, x0:x0 + tile]
            best, bd, cost = None, (0, 0), {}
            for dy in range(-search, search + 1):
                for dx in range(-search, search + 1):
                    yy, xx = y0 + gy0 + dy, x0 + gx0 + dx
                    if yy < 0 or xx < 0 or yy + tile > H or xx + tile > W:
                        continue
                    sad = np.abs(ref - gc[yy:yy + tile, xx:xx + tile]).sum()
                    cost[(dy, dx)] = sad
                    if best is None or sad < best:
                        best, bd = sad, (dy, dx)
            def sub(axis):
                m = (bd[0] - 1, bd[1]) if axis == 0 else (bd[0], bd[1] - 1)
                p = (bd[0] + 1, bd[1]) if axis == 0 else (bd[0], bd[1] + 1)
                if m not in cost or p not in cost: return 0.0
                d = cost[m] - 2 * best + cost[p]
                return 0.0 if d <= 0 else float(np.clip(0.5 * (cost[m] - cost[p]) / d, -0.5, 0.5))
            field[ty, tx] = (gy0 + bd[0] + sub(0), gx0 + bd[1] + sub(1))
    return field, stride, tile


def lk_refine(gr, gc, field, stride=8, tile=16, iters=4):
    """Lucas-Kanade iteratif per tile (sub-piksel presisi tinggi) mulai dari medan SAD."""
    from scipy.ndimage import map_coordinates
    H, W = gr.shape
    gy, gx = np.gradient(gr)
    out = field.copy()
    ny, nx, _ = field.shape
    yy, xx = np.mgrid[0:tile, 0:tile].astype(np.float32)
    for ty in range(ny):
        for tx in range(nx):
            y0, x0 = ty * stride, tx * stride
            R = gr[y0:y0 + tile, x0:x0 + tile]
            Iy, Ix = gy[y0:y0 + tile, x0:x0 + tile], gx[y0:y0 + tile, x0:x0 + tile]
            A = np.array([[np.sum(Ix * Ix), np.sum(Ix * Iy)], [np.sum(Ix * Iy), np.sum(Iy * Iy)]])
            if np.linalg.det(A) < 1e-6 or np.trace(A) < 1e-5:
                continue
            Ainv = np.linalg.inv(A)
            dy, dx = out[ty, tx]
            for _ in range(iters):
                C = map_coordinates(gc, [yy + y0 + dy, xx + x0 + dx], order=1, mode="nearest")
                e = C - R
                b = np.array([np.sum(Ix * e), np.sum(Iy * e)])
                ddx, ddy = -Ainv @ b
                dx, dy = dx + ddx, dy + ddy
                if abs(ddx) < 0.01 and abs(ddy) < 0.01:
                    break
            if abs(dy - field[ty, tx, 0]) < 1.5 and abs(dx - field[ty, tx, 1]) < 1.5:
                out[ty, tx] = (dy, dx)
    return out


def shift_at(field, stride, tile, ys, xs):
    """interpolasi bilinear medan geser (satuan grey) di koordinat grey (ys, xs)"""
    ny, nx, _ = field.shape
    fy = np.clip((ys - tile / 2) / stride, 0, ny - 1)
    fx = np.clip((xs - tile / 2) / stride, 0, nx - 1)
    y0, x0 = np.floor(fy).astype(int), np.floor(fx).astype(int)
    y1, x1 = np.minimum(y0 + 1, ny - 1), np.minimum(x0 + 1, nx - 1)
    wy, wx = (fy - y0)[..., None], (fx - x0)[..., None]
    f = (field[y0, x0] * (1 - wy) * (1 - wx) + field[y0, x1] * (1 - wy) * wx
         + field[y1, x0] * wy * (1 - wx) + field[y1, x1] * wy * wx)
    return f[..., 0], f[..., 1]


def mfsr(rois, cfa, scale=2.0, sigma=0.55, radius=2, robust_k=3.0, noise=None, lk=True):
    """rois: list array Bayer ternormalisasi (0..1) ukuran sama, frame 0 = referensi.
    cfa: array 2x2 indeks kanal 0=R 1=G 2=B. Return RGB (H*s, W*s, 3)."""
    H, W = rois[0].shape
    Ho, Wo = int(H * scale), int(W * scale)
    oy = (np.arange(Ho) + 0.5) / scale - 0.5
    ox = (np.arange(Wo) + 0.5) / scale - 0.5
    OY, OX = np.meshgrid(oy, ox, indexing="ij")
    acc = np.zeros((3, Ho, Wo), np.float64)
    wsum = np.zeros((3, Ho, Wo), np.float64)
    g_ref = grey(rois[0])
    # tensor struktur (Wronski 2019): kernel sempit melintang tepi, lebar sepanjang tepi
    from scipy.ndimage import gaussian_filter, zoom as nd_zoom
    gyy, gxx = np.gradient(gaussian_filter(g_ref, 0.7))
    Txx, Tyy, Txy = (gaussian_filter(gxx * gxx, 1.5), gaussian_filter(gyy * gyy, 1.5), gaussian_filter(gxx * gyy, 1.5))
    tr = Txx + Tyy
    det = Txx * Tyy - Txy * Txy
    l1 = tr / 2 + np.sqrt(np.maximum(tr * tr / 4 - det, 0))
    l2 = tr / 2 - np.sqrt(np.maximum(tr * tr / 4 - det, 0))
    coh = np.clip((np.sqrt(l1) - np.sqrt(np.maximum(l2, 0))) / (np.sqrt(l1) + np.sqrt(np.maximum(l2, 0)) + 1e-9), 0, 1)
    ang = 0.5 * np.arctan2(2 * Txy, Txx - Tyy)          # arah gradien dominan
    zf = (Ho / g_ref.shape[0], Wo / g_ref.shape[1])
    coh_o = np.clip(nd_zoom(coh, zf, order=1)[:Ho, :Wo], 0, 1)
    ca, sa = np.cos(nd_zoom(ang, zf, order=1)[:Ho, :Wo]), np.sin(nd_zoom(ang, zf, order=1)[:Ho, :Wo])
    s_across = sigma * (1 - 0.55 * coh_o)                # tepi kuat -> kernel sempit melintang
    s_along = sigma * (1 + 1.0 * coh_o)                  # ... dan lebar sepanjang tepi
    for f, b in enumerate(rois):
        if f == 0:
            dyf = np.zeros_like(OY); dxf = np.zeros_like(OX)
        else:
            gc = grey(b)
            g0 = phase_shift(g_ref, gc)
            field, st, tl = tile_refine(g_ref, gc, g0)
            if lk:
                field = lk_refine(g_ref, gc, field, st, tl)
            # koordinat grey = koordinat sensor / 2
            dyg, dxg = shift_at(field, st, tl, OY / 2, OX / 2)
            dyf, dxf = dyg * 2, dxg * 2          # geser dalam piksel sensor
        PY, PX = OY + dyf, OX + dxf              # posisi titik output di frame f
        iy0, ix0 = np.floor(PY).astype(int), np.floor(PX).astype(int)
        for ky in range(-radius + 1, radius + 1):
            for kx in range(-radius + 1, radius + 1):
                qy, qx = iy0 + ky, ix0 + kx
                valid = (qy >= 0) & (qx >= 0) & (qy < H) & (qx < W)
                qyc, qxc = np.clip(qy, 0, H - 1), np.clip(qx, 0, W - 1)
                ddx, ddy = qx - PX, qy - PY
                u = ddx * ca + ddy * sa            # komponen searah gradien (melintang tepi)
                v_ = -ddx * sa + ddy * ca          # komponen sepanjang tepi
                w = np.exp(-0.5 * (u * u / (s_across ** 2) + v_ * v_ / (s_along ** 2))) * valid
                ch = cfa[qyc % 2, qxc % 2]
                v = b[qyc, qxc]
                for c in range(3):
                    m = (ch == c)
                    acc[c] += w * v * m
                    wsum[c] += w * m
    rgb = acc / np.maximum(wsum, 1e-6)
    return np.transpose(rgb, (1, 2, 0)).astype(np.float32), np.transpose(wsum, (1, 2, 0))


def load_burst(folder, roi, cy=0.5, cx=0.5):
    paths = sorted(glob.glob(str(Path(folder) / "IMG_*.dng")))
    rois, info = [], None
    for p in paths:
        with rawpy.imread(p) as r:
            raw = r.raw_image.astype(np.float32)
            bl, wl = r.black_level_per_channel[0], r.white_level
            H, W = raw.shape
            y0 = int(H * cy - roi * 0.375) & ~1
            x0 = int(W * cx - roi / 2) & ~1
            rh, rw = int(roi * 0.75) & ~1, roi
            rois.append(np.clip((raw[y0:y0 + rh, x0:x0 + rw] - bl) / (wl - bl), 0, 1))
            if info is None:
                pat = r.raw_pattern
                desc = r.color_desc.decode()
                cfa = np.vectorize(lambda i: "RGB".index(desc[i]) if desc[i] in "RGB" else 1)(pat)
                info = dict(cfa=cfa, wb=np.array(r.camera_whitebalance[:3], np.float32), y0=y0, x0=x0, path=p)
    return rois, info


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("folder")
    ap.add_argument("--roi", type=int, default=512)
    ap.add_argument("--scale", type=float, default=2.0)
    a = ap.parse_args()
    rois, info = load_burst(a.folder, a.roi)
    out, w = mfsr(rois, info["cfa"], a.scale)
    np.save(Path(a.folder) / "_mfsr.npy", out)
    print("MFSR", out.shape, "bobot min/median", w.min(), np.median(w))
