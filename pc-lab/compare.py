"""
compare.py - Perbandingan frame tunggal vs simple merge vs robust merge (burst ProRAW).

* Estimasi noise (sigma) dengan metode Immerkaer (Laplacian) per crop -> angka objektif.
* Crop diperbesar 2x (nearest) + boost EV supaya noise / artefak terlihat.
  Kolom: frame tunggal | simple merge | robust merge

Contoh:
  python compare.py D:\\project\\ios\\BaginCam\\data\\bursts\\iphone-20261111-setA --ev 1 --nr 13
"""
import argparse
import sys
from pathlib import Path

import numpy as np
import imageio.v3 as iio

sys.path.insert(0, str(Path(__file__).resolve().parent))
import burst_merge as bm  # noqa: E402
import robust_merge as rm  # noqa: E402

KERNEL = np.array([[1, -2, 1], [-2, 4, -2], [1, -2, 1]], np.float64)


def sigma_immerkaer(gray):
    """estimasi std noise (pada skala data) - Immerkaer 1996"""
    g = gray.astype(np.float64)
    h, w = g.shape
    conv = sum(KERNEL[i, j] * g[i:h - 2 + i, j:w - 2 + j] for i in range(3) for j in range(3))
    return np.sqrt(np.pi / 2) * np.abs(conv).sum() / (6.0 * (w - 2) * (h - 2))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("folder", type=Path)
    ap.add_argument("--ev", type=float, default=0.0)
    ap.add_argument("--nr", type=float, default=18)
    ap.add_argument("--k", type=float, default=0, help="pakai NoiseProfile DNG dengan ambang k x noise")
    ap.add_argument("--size", type=int, default=320, help="ukuran crop (piksel output)")
    ap.add_argument("--max-frames", type=int, default=0)
    ap.add_argument("--spots", default="0.5,0.5;0.62,0.40;0.30,0.55",
                    help="pusat crop 'y,x;y,x' relatif terhadap gambar hasil (sudah dirotasi)")
    args = ap.parse_args()

    paths = bm.list_raws(args.folder)
    if args.max_frames:
        paths = paths[: args.max_frames]
    images, meta = bm.load_proraw(paths)
    simple = bm.align.align_and_merge(images, ref_idx=0)
    robust, wts, _ = rm.align_and_robust_merge(images, ref_idx=0, noise_reduction=args.nr, return_weights=True,
                                              noise_profile=meta.get("noise_profile") if args.k else None,
                                              k_sigma=args.k or 4.0)

    renders = [bm.render_proraw(x, meta, args.ev) for x in (images[0].numpy(), simple.numpy(), robust.numpy())]
    h, w = renders[0].shape[:2]
    s = args.size
    spots = [tuple(float(v) for v in sp.split(",")) for sp in args.spots.split(";")]

    rows, report = [], []
    for k, (fy, fx) in enumerate(spots):
        y0 = int(np.clip(fy * h - s // 2, 0, h - s))
        x0 = int(np.clip(fx * w - s // 2, 0, w - s))
        crops = [r[y0:y0 + s, x0:x0 + s] for r in renders]
        sig = [sigma_immerkaer(c.mean(-1)) / 65535 * 255 for c in crops]
        report.append(f"crop{k + 1} ({fy:.2f},{fx:.2f})  sigma tunggal={sig[0]:5.2f}  simple={sig[1]:5.2f} "
                      f"(-{100 * (1 - sig[1] / sig[0]):4.1f}%)  robust={sig[2]:5.2f} (-{100 * (1 - sig[2] / sig[0]):4.1f}%)")
        gap = np.full((s, 8, 3), 255, np.uint8)
        rows.append(np.concatenate([bm.to8(crops[0]), gap, bm.to8(crops[1]), gap, bm.to8(crops[2])], 1))
        rows.append(np.full((8, rows[-1].shape[1], 3), 255, np.uint8))
    grid = np.kron(np.concatenate(rows[:-1], 0), np.ones((2, 2, 1), np.uint8))

    out = bm.ROOT / "data" / "output" / f"{args.folder.name}_3way_ev{args.ev:+g}_{f"k{args.k:g}" if args.k else f"nr{args.nr:g}"}.jpg"
    iio.imwrite(out, grid, quality=92)
    print(f"{len(paths)} frame, ev {args.ev:+g}, nr {args.nr:g} | kolom: tunggal | simple | robust")
    print("bobot robust rata-rata per frame:", [round(x, 2) for x in wts])
    print("\n".join(report))
    print(f"teori (rata-rata {len(paths)} frame): turun {100 * (1 - 1 / np.sqrt(len(paths))):.1f}%")
    print("gambar:", out)


if __name__ == "__main__":
    main()
