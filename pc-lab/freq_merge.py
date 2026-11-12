"""
freq_merge.py - HDR+ merge di domain frekuensi (Wiener per tile), sesuai paper Hasinoff et al. 2016
(juga dipakai hdr-plus-swift merge/frequency). Prototipe PC sebelum di-port ke Metal (HDRPlus.metal).

Per tile 16x16 (stride 8, jendela raised-cosine/Hann) di tiap plane Bayer (R, G1, G2, B):
    T_ref, T_z = FFT2(window * tile)
    D = T_ref - T_z
    A = |D|^2 / (|D|^2 + c * sigma^2 * sum(w^2))      (sigma^2 dari NoiseProfile DNG, per tile)
    merged = mean_z [ T_z + A * D ]                   (frame referensi ikut, A=1)
lalu IFFT + overlap-add (Hann 50% overlap = 1).

Pemakaian (perbandingan dengan spatial robust merge):
  python freq_merge.py <folder burst DNG Bayer> [--c 8]
"""
import argparse
import glob
import sys
from pathlib import Path

import numpy as np
import rawpy
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import robust_merge as rm  # noqa: E402

T = 16
S = 8


def hann2d():
    n = np.arange(T)
    w = 0.5 - 0.5 * np.cos(2 * np.pi * (n + 0.5) / T)   # jumlah 2 tile bergeser 8 = 1
    return np.outer(w, w).astype(np.float32)


def to_planes(b):
    return np.stack([b[0::2, 0::2], b[0::2, 1::2], b[1::2, 0::2], b[1::2, 1::2]]).astype(np.float32)


def from_planes(p):
    c, h, w = p.shape
    out = np.empty((h * 2, w * 2), np.float32)
    out[0::2, 0::2], out[0::2, 1::2], out[1::2, 0::2], out[1::2, 1::2] = p
    return out


def tiles_of(p, pad):
    """p: (C,H,W) -> (C, ny, nx, T, T) tile berjendela dengan stride S"""
    q = np.pad(p, ((0, 0), (pad, pad), (pad, pad)), mode="reflect")
    C, H, W = q.shape
    ny, nx = (H - T) // S + 1, (W - T) // S + 1
    st = q.strides
    v = np.lib.stride_tricks.as_strided(q, (C, ny, nx, T, T), (st[0], st[1] * S, st[2] * S, st[1], st[2]))
    return v, (H, W)


def overlap_add(tl, shape, pad):
    C, ny, nx, _, _ = tl.shape
    H, W = shape
    out = np.zeros((C, H, W), np.float32)
    for oy in range(T):
        for ox in range(T):
            out[:, oy:oy + ny * S:S, ox:ox + nx * S:S] += tl[:, :, :, oy, ox]
    return out[:, pad:H - pad, pad:W - pad]


def freq_merge(frames_planes, black, white, noise_profile, c=8.0, chunk=24):
    """frames_planes: list (C,H,W) sudah di-align ke referensi (index 0).
    FFT presisi tunggal (torch), diproses per potongan baris tile supaya hemat memori."""
    w = torch.from_numpy(hann2d())
    wsum2 = float((w * w).sum())
    pad = S
    rng = float(white - black)
    Sn, On = noise_profile
    views = [tiles_of(fp, pad) for fp in frames_planes]
    shape = views[0][1]
    C, ny, nx = views[0][0].shape[:3]
    out_tiles = np.empty((C, ny, nx, T, T), np.float32)
    for r0 in range(0, ny, chunk):
        r1 = min(ny, r0 + chunk)
        rt = torch.from_numpy(np.ascontiguousarray(views[0][0][:, r0:r1]))
        Fref = torch.fft.fft2(rt * w)
        x = ((rt.mean(dim=(-1, -2), keepdim=True) - black) / rng).clamp(0, 1)
        denom = c * (Sn * x + On) * rng * rng * wsum2
        acc = Fref.clone()
        for v, _ in views[1:]:
            Fz = torch.fft.fft2(torch.from_numpy(np.ascontiguousarray(v[:, r0:r1])) * w)
            D = Fref - Fz
            D2 = D.real ** 2 + D.imag ** 2
            acc += Fz + (D2 / (D2 + denom)) * D
        acc /= len(frames_planes)
        out_tiles[:, r0:r1] = torch.fft.ifft2(acc).real.numpy()
    return overlap_add(out_tiles, shape, pad)


def load(folder):
    paths = sorted(glob.glob(str(Path(folder) / "IMG_*.dng")))
    raws = []
    for p in paths:
        with rawpy.imread(p) as r:
            raws.append(r.raw_image.astype(np.float32).copy())
            black, white = r.black_level_per_channel[0], r.white_level
    import subprocess
    np_ = subprocess.run([r"C:\Users\ASUS\AppData\Local\Programs\ExifTool\ExifTool.exe", "-s3", "-NoiseProfile", paths[0]],
                         capture_output=True, text=True).stdout.split()
    return paths, raws, black, white, (float(np_[0]), float(np_[1]))


def aligned_planes(raws):
    """align (integer tile, hdr-plus-pytorch) tiap frame ke frame 0, kembalikan plane Bayer."""
    imgs = torch.from_numpy(np.stack(raws))[:, None]
    N, C, H, W = imgs.shape
    import math
    n_layers = math.ceil(math.log2(min(H, W) / 64))
    dsf = n_layers * [2]
    ref_pyr = rm.align.build_pyramid(imgs[0], dsf)
    out = [to_planes(raws[0])]
    for i in range(1, N):
        a = rm.align_frame(ref_pyr, imgs[i], dsf, 16, 2, W, H)
        out.append(to_planes(a[0].numpy()))
    return out


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("folder")
    ap.add_argument("--c", type=float, default=8.0)
    args = ap.parse_args()
    paths, raws, black, white, npf = load(args.folder)
    print(f"{len(raws)} frame, black {black} white {white} NoiseProfile {npf}")
    planes = aligned_planes(raws)
    fm = from_planes(freq_merge(planes, black, white, npf, c=args.c))
    sm = rm.align_and_robust_merge(torch.from_numpy(np.stack(raws))[:, None], noise_reduction=18)[0].numpy()
    np.save(Path(args.folder) / "_freq.npy", fm)
    np.save(Path(args.folder) / "_spatial.npy", sm)
    print("tersimpan _freq.npy / _spatial.npy")
