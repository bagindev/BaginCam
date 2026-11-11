"""
robust_merge.py - Align + *robust* merge ala HDR+ (port dari hdr-plus-swift
burstphoto/merge/spatial.{swift,metal}, GPL-3.0 -> logika diadaptasi ke PyTorch).

Beda dengan align.align_and_merge (rata-rata biasa):
  per frame pembanding, area yang selisihnya (setelah blur) jauh di atas noise
  -> bobotnya turun ke 0 -> pakai frame referensi. Menghilangkan ghosting /
  artefak kotak akibat tile yang salah align.

Representasi "planes":
  * Bayer (N,1,H,W)  -> 4 plane R,G1,G2,B setengah resolusi  (= superpixel Bayer)
  * Linear (N,3,H,W) -> 3 plane RGB resolusi penuh
"""
import math
import sys
from pathlib import Path

import torch
import torch.nn.functional as F

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "third_party" / "hdr-plus-pytorch"))
import align  # noqa: E402


# ---------- helpers ----------
def to_planes(img, bayer):
    if not bayer:
        return img
    x = img[0]
    return torch.stack([x[0::2, 0::2], x[0::2, 1::2], x[1::2, 0::2], x[1::2, 1::2]])


def from_planes(p, bayer):
    if not bayer:
        return p
    c, h, w = p.shape
    out = torch.empty((1, h * 2, w * 2), dtype=p.dtype)
    out[0, 0::2, 0::2], out[0, 0::2, 1::2], out[0, 1::2, 0::2], out[0, 1::2, 1::2] = p
    return out


def binomial_kernel(size=16):
    k = torch.tensor([math.comb(size, i) for i in range(size + 1)], dtype=torch.float32)
    return k / k.sum()


def blur(planes, size=16):
    """blur binomial separable per plane (sama seperti blur() di hdr-plus-swift, kernel_size 16)"""
    k = binomial_kernel(size)
    c = planes.shape[0]
    x = planes[None]
    pad = size // 2
    x = F.pad(x, (pad, pad, 0, 0), mode="reflect")
    x = F.conv2d(x, k.view(1, 1, 1, -1).repeat(c, 1, 1, 1), groups=c)
    x = F.pad(x, (0, 0, pad, pad), mode="reflect")
    x = F.conv2d(x, k.view(1, 1, -1, 1).repeat(c, 1, 1, 1), groups=c)
    return x[0]


def color_difference(a, b):
    """jumlah |a-b| atas semua plane -> (H,W) per superpixel"""
    return (a - b).abs().sum(0)


def robustness_from_nr(noise_reduction):
    """rumus asli Burst Photo: slider noise_reduction 1..23 (default 13)"""
    rev = 0.5 * (36.0 - int(noise_reduction + 0.5))
    return 0.12 * 1.3 ** rev - 0.4529822


def align_frame(ref_pyramid, comp, downscale_factor_list, tile_size, search_dist, W, H):
    comp_pyramid = align.build_pyramid(comp, downscale_factor_list)
    alignment = torch.zeros([2, 1, 1], dtype=torch.int32)
    for layer_idx in torch.flip(torch.arange(len(ref_pyramid)), [0]):
        dsf = downscale_factor_list[min(layer_idx + 1, len(ref_pyramid) - 1)]
        alignment = align.align_layers(ref_pyramid[layer_idx], comp_pyramid[layer_idx],
                                       alignment, tile_size, search_dist, dsf)
    alignment = align.upscale_previous_alignment(alignment, downscale_factor_list[0], W, H)
    return align.warp_image(comp, alignment)


# ---------- main ----------
# std noise sisa setelah blur binomial-16 2D: sum(k^2) per dimensi = C(32,16)/2^32 ~0.140
_BLUR_SD_FACTOR = math.comb(32, 16) / 2 ** 32
_EXPECTED_ABS = math.sqrt(2 / math.pi)                    # E|N(0,1)|


def expected_blur_diff(ref_blur, noise_profile, data_scale=1.0):
    """
    Selisih |blur(ref) - blur(comp)| yang DIHARAPKAN bila hanya ada noise sensor (tanpa gerakan),
    dari model DNG NoiseProfile: var(x) = S*x + O  (x ternormalisasi 0..1).
    data_scale: pengali data -> ternormalisasi (mis. 1/(white-black) untuk Bayer mentah).
    """
    S, O = noise_profile
    x = (ref_blur * data_scale).clamp(min=0)
    sd = torch.sqrt(S * x + O) / data_scale               # kembali ke satuan data
    sd_diff = sd * _BLUR_SD_FACTOR * math.sqrt(2)          # selisih 2 frame independen
    return (sd_diff * _EXPECTED_ABS).sum(0)                # dijumlah atas plane (seperti color_difference)


def align_and_robust_merge(images, ref_idx=0, noise_reduction=13, tile_size=16, search_dist=2,
                           min_layer_res=64, return_weights=False,
                           noise_profile=None, data_scale=1.0, k_sigma=4.0):
    """
    images: (N,C,H,W) float. C=1 -> Bayer RGGB, C=3 -> linear RGB.
    noise_reduction: 1..23 (lebih tinggi = merge lebih agresif, lebih sedikit penolakan)
                     None/0 -> rata-rata biasa (robustness off)
    noise_profile: (S, O) dari tag DNG NoiseProfile -> ambang penolakan PER PIKSEL =
                   k_sigma x selisih yang diharapkan dari noise sensor. Menggantikan estimasi global
                   |ref - blur(ref)| (yang ikut menghitung tekstur). noise_reduction lalu diabaikan.
    """
    N, C, H, W = images.shape
    bayer = C == 1
    robustness = robustness_from_nr(noise_reduction) if noise_reduction else 0.0

    n_layers = math.ceil(math.log2(min(H, W) / min_layer_res))
    dsf_list = n_layers * [2]
    ref = images[ref_idx]
    ref_pyramid = align.build_pyramid(ref, dsf_list)

    ref_p = to_planes(ref, bayer)
    ref_blur = blur(ref_p)
    # estimasi noise: rata-rata selisih antara referensi dan versi blur-nya
    noise_sd = color_difference(ref_p, ref_blur).mean()
    max_diff_map = None
    if noise_profile is not None:
        max_diff_map = k_sigma * expected_blur_diff(ref_blur, noise_profile, data_scale)
        robustness = 1.0  # pastikan jalur robust aktif

    acc = ref_p.clone() / N
    weights = []
    for i in range(N):
        if i == ref_idx:
            continue
        aligned = align_frame(ref_pyramid, images[i], dsf_list, tile_size, search_dist, W, H)
        comp_p = to_planes(aligned, bayer)
        if robustness > 0:
            diff = color_difference(ref_blur, blur(comp_p))
            max_diff = max_diff_map if max_diff_map is not None else noise_sd / robustness
            w = (1 - diff / max_diff).clamp(0, 1)
        else:
            w = torch.ones(ref_p.shape[1:])
        weights.append(w.mean().item())
        # add_texture_weighted: ref*(1-w) + comp*w
        acc += (ref_p * (1 - w) + comp_p * w) / N

    out = from_planes(acc, bayer)
    return (out, weights, float(noise_sd)) if return_weights else out
