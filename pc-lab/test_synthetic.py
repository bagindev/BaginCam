"""
test_synthetic.py - Uji pipeline align+merge tanpa data asli.

Membuat scene sintetis -> mosaik Bayer RGGB -> N frame dengan geseran (simulasi
goyangan tangan) + noise sensor (shot + read noise), lalu membandingkan
PSNR frame tunggal vs hasil merge. Juga mengukur waktu pada resolusi 12MP.
"""
import sys
import time
from pathlib import Path

import numpy as np
import torch
import imageio.v3 as iio

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "third_party" / "hdr-plus-pytorch"))
import align  # noqa: E402

rng = np.random.default_rng(42)


def make_scene(h, w):
    y, x = np.mgrid[0:h, 0:w].astype(np.float32)
    r = 0.5 + 0.4 * np.sin(x / 37.0) * np.cos(y / 53.0)
    g = 0.5 + 0.4 * np.sin((x + y) / 23.0)
    b = 0.5 + 0.4 * np.cos(np.hypot(x - w / 2, y - h / 2) / 19.0)
    rgb = np.stack([r, g, b])
    # tambahkan tekstur halus (detail yang mudah hilang oleh noise)
    rgb += 0.08 * np.sign(np.sin(x / 3.1) * np.sin(y / 2.7))
    # kotak-kotak tajam
    for _ in range(40):
        cy, cx = rng.integers(0, h - 80), rng.integers(0, w - 80)
        rgb[:, cy:cy + 60, cx:cx + 60] = rng.uniform(0.1, 0.9, (3, 1, 1))
    return np.clip(rgb, 0, 1)


def mosaic_rggb(rgb):
    _, h, w = rgb.shape
    bayer = np.empty((h, w), np.float32)
    bayer[0::2, 0::2] = rgb[0, 0::2, 0::2]
    bayer[0::2, 1::2] = rgb[1, 0::2, 1::2]
    bayer[1::2, 0::2] = rgb[1, 1::2, 0::2]
    bayer[1::2, 1::2] = rgb[2, 1::2, 1::2]
    return bayer


def simulate_burst(scene, n, max_shift=12, photons=60.0, read_noise=0.02):
    """geseran genap (menjaga pola Bayer) + noise; frame 0 = referensi tanpa geser"""
    _, h, w = scene.shape
    pad = max_shift + 2
    clean, noisy, shifts = [], [], []
    for i in range(n):
        dy, dx = (0, 0) if i == 0 else tuple(2 * rng.integers(-max_shift // 2, max_shift // 2 + 1, 2))
        crop = scene[:, pad + dy:pad + dy + h - 2 * pad, pad + dx:pad + dx + w - 2 * pad]
        b = mosaic_rggb(crop)
        nb = rng.poisson(b * photons) / photons + rng.normal(0, read_noise, b.shape)
        clean.append(b)
        noisy.append(nb.astype(np.float32))
        shifts.append((int(dy), int(dx)))
    return clean[0], np.stack(noisy), shifts


def psnr(a, b, margin=32):
    a, b = a[margin:-margin, margin:-margin], b[margin:-margin, margin:-margin]
    mse = np.mean((a - b) ** 2)
    return 10 * np.log10(1.0 / mse)


def preview(bayer):
    """demosaic kasar (binning 2x2) untuk gambar preview"""
    r = bayer[0::2, 0::2]
    g = (bayer[0::2, 1::2] + bayer[1::2, 0::2]) / 2
    b = bayer[1::2, 1::2]
    return (np.clip(np.stack([r, g, b], -1), 0, 1) ** (1 / 2.2) * 255).astype(np.uint8)


def run(h, w, n, save=None):
    scene = make_scene(h, w)
    ref_clean, burst, shifts = simulate_burst(scene, n)
    images = torch.from_numpy(burst)[:, None]
    t0 = time.time()
    merged = align.align_and_merge(images, ref_idx=0)[0].numpy()
    dt = time.time() - t0
    mean_naive = burst.mean(0)  # tanpa align (untuk menunjukkan pentingnya align)
    res = dict(
        size=f"{w}x{h}", frames=n, seconds=round(dt, 1),
        psnr_single=round(psnr(burst[0], ref_clean), 2),
        psnr_merge=round(psnr(merged, ref_clean), 2),
        psnr_no_align=round(psnr(mean_naive, ref_clean), 2),
    )
    if save:
        s = 400
        tiles = [preview(x)[100:100 + s // 2, 100:100 + s // 2] for x in (burst[0], mean_naive, merged, ref_clean)]
        gap = np.full((tiles[0].shape[0], 6, 3), 255, np.uint8)
        row = np.concatenate([tiles[0], gap, tiles[1], gap, tiles[2], gap, tiles[3]], 1)
        row = np.kron(row, np.ones((2, 2, 1), np.uint8))
        iio.imwrite(save, row, quality=92)
    return res


if __name__ == "__main__":
    out = ROOT / "data" / "output"
    out.mkdir(parents=True, exist_ok=True)
    print("Uji kualitas (2000x1500, 8 frame):")
    print(run(1500, 2000, 8, save=out / "synthetic_compare.jpg"))
    print("Uji waktu (4032x3024 = 12MP, 8 frame, CPU):")
    print(run(3024, 4032, 8))
