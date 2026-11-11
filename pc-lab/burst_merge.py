"""
burst_merge.py - Align + merge burst RAW (DNG) ala HDR+ di PC, memakai
third_party/hdr-plus-pytorch (MIT).

Mendukung dua jenis DNG dari iPhone:
  * Bayer RAW  (mis. dari Halide / app RAW pihak ketiga, 12MP)  -> merge di domain Bayer
  * ProRAW     (Linear DNG, sudah demosaic)                     -> merge di domain RGB linear

Contoh:
  python burst_merge.py D:\\project\\ios\\BaginCam\\data\\bursts\\burst01
  python burst_merge.py <folder> --ev 1.5 --ref 0 --tile 16 --search 2 --max-frames 8
"""
import argparse
import sys
import time
from glob import glob
from pathlib import Path

import numpy as np
import rawpy
import tifffile
import torch
import imageio.v3 as iio

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "third_party" / "hdr-plus-pytorch"))
import align  # noqa: E402
sys.path.insert(0, str(Path(__file__).resolve().parent))
import robust_merge as rm  # noqa: E402


def list_raws(folder: Path):
    exts = ("*.dng", "*.DNG", "*.arw", "*.ARW", "*.cr2", "*.CR2", "*.nef", "*.NEF")
    paths = sorted({p for e in exts for p in glob(str(folder / e))})
    if not paths:
        sys.exit(f"Tidak ada file RAW di {folder}")
    return paths


def detect_kind(path):
    try:
        with rawpy.imread(path) as raw:
            return "bayer" if raw.raw_type == rawpy.RawType.Flat else "linear"
    except rawpy.LibRawFileUnsupportedError:
        # Apple ProRAW iOS 17+: LinearRaw + kompresi JPEG XL (52546), belum didukung LibRaw
        return "proraw"


# ---------- Apple ProRAW (JPEG XL) via tifffile + imagecodecs ----------
XYZ_TO_SRGB = np.array([[3.2404542, -1.5371385, -0.4985314],
                        [-0.9692660, 1.8760108, 0.0415560],
                        [0.0556434, -0.2040259, 1.0572252]], np.float32)


def _rat(v):
    """tifffile memberi SRATIONAL sebagai deret (num, den, num, den, ...)"""
    v = np.asarray(v, np.float64)
    return v[0::2] / v[1::2]


def proraw_meta(path):
    with tifffile.TiffFile(path) as t:
        main, sub = t.pages[0], t.pages[0].pages[0]
        tg = lambda k: (sub.tags.get(k) or main.tags.get(k))
        meta = dict(
            lin=np.asarray(tg("LinearizationTable").value, np.float32) if tg("LinearizationTable") else None,
            black=np.asarray(tg("BlackLevel").value, np.float32) if tg("BlackLevel") else np.zeros(3, np.float32),
            white=np.asarray(tg("WhiteLevel").value, np.float32),
            neutral=_rat(tg("AsShotNeutral").value),
            baseline_ev=float(_rat(tg("BaselineExposure").value)[0]) if tg("BaselineExposure") else 0.0,
            orientation=int(main.tags["Orientation"].value) if "Orientation" in main.tags else 1,
        )
        # ColorMatrix2 = D65 (illuminant 21) jika ada, jika tidak ColorMatrix1
        cm = tg("ColorMatrix2") or tg("ColorMatrix1")
        meta["cm"] = _rat(cm.value).reshape(3, 3)
        npf = tg("NoiseProfile")
        meta["noise_profile"] = tuple(float(v) for v in npf.value[:2]) if npf else None
        pg = tg("ProfileGainTableMap")
        meta["pgtm"] = parse_pgtm(bytes(pg.value)) if pg else None
    return meta


def parse_pgtm(raw):
    """DNG 1.6 ProfileGainTableMap (big-endian): grid V x H, tiap titik kurva gain N titik"""
    import struct
    pv, ph = struct.unpack(">II", raw[:8])
    sv, sh, ov, oh = struct.unpack(">dddd", raw[8:40])
    n, = struct.unpack(">I", raw[40:44])
    w = np.array(struct.unpack(">5f", raw[44:64]), np.float32)
    g = np.frombuffer(raw[64:64 + pv * ph * n * 4], dtype=">f4").astype(np.float32).reshape(pv, ph, n)
    return dict(pv=pv, ph=ph, sv=sv, sh=sh, ov=ov, oh=oh, n=n, w=w, gains=g)


def apply_pgtm(cam_hwc, pg):
    """tone map lokal Apple: gain = tabel[posisi grid, kecerahan berbobot] (interpolasi trilinear)"""
    import torch.nn.functional as F
    h, w, _ = cam_hwc.shape
    x = torch.from_numpy(np.ascontiguousarray(cam_hwc))
    wt = pg["w"]
    t = (wt[0] * x[..., 0] + wt[1] * x[..., 1] + wt[2] * x[..., 2]
         + wt[3] * x.min(-1).values + wt[4] * x.max(-1).values).clamp(0, 1)
    ys = ((torch.arange(h, dtype=torch.float32) + 0.5) / h - pg["ov"]) / pg["sv"]
    xs = ((torch.arange(w, dtype=torch.float32) + 0.5) / w - pg["oh"]) / pg["sh"]
    gy = (ys.clamp(0, pg["pv"] - 1) / (pg["pv"] - 1) * 2 - 1)[:, None].expand(h, w)
    gx = (xs.clamp(0, pg["ph"] - 1) / (pg["ph"] - 1) * 2 - 1)[None, :].expand(h, w)
    gz = t * 2 - 1
    vol = torch.from_numpy(pg["gains"]).permute(2, 0, 1)[None, None]  # 1,1,N,V,H
    grid = torch.stack([gx, gy, gz], -1)[None, None]                    # 1,1,h,w,3
    gain = F.grid_sample(vol, grid, mode="bilinear", align_corners=True)[0, 0, 0]
    return (x * gain[..., None]).numpy()


def load_proraw(paths):
    meta = proraw_meta(paths[0])
    frames = []
    for p in paths:
        with tifffile.TiffFile(p) as t:
            a = t.pages[0].pages[0].asarray()
        a = meta["lin"][np.minimum(a, len(meta["lin"]) - 1)] if meta["lin"] is not None else a.astype(np.float32)
        a = (a - meta["black"]) / (meta["white"] - meta["black"])
        frames.append(np.clip(a, 0, None).astype(np.float32).transpose(2, 0, 1))
    return torch.from_numpy(np.stack(frames)), meta  # N,3,H,W  (linear, camera RGB, sudah WB)


def render_proraw(lin_chw, meta, ev, local_tm=True):
    cam = lin_chw.transpose(1, 2, 0) * np.float32(2.0 ** (meta["baseline_ev"] + ev))
    use_pg = local_tm and meta.get("pgtm") is not None
    if use_pg:
        cam = apply_pgtm(cam, meta["pgtm"])
    # kamera -> XYZ: inverse ColorMatrix, dinormalisasi supaya neutral -> putih D65
    cam2xyz = np.linalg.inv(meta["cm"])
    d65 = np.array([0.95047, 1.0, 1.08883])
    scale = d65 / (cam2xyz @ meta["neutral"])
    cam2srgb = (XYZ_TO_SRGB @ (np.diag(scale) @ cam2xyz)).astype(np.float32)
    rgb = np.clip(cam @ cam2srgb.T, 0, None)
    if not use_pg:
        # tanpa gain map: tone curve sederhana (soft shoulder) supaya highlight tidak clip keras
        rgb = rgb / (1.0 + 0.25 * rgb)
        rgb = rgb * (1.0 + 0.25)
    rgb = np.clip(rgb, 0, 1)
    rgb = np.where(rgb <= 0.0031308, 12.92 * rgb, 1.055 * np.power(rgb, 1 / 2.4) - 0.055)
    out = (rgb * 65535).astype(np.uint16)
    o = meta["orientation"]
    if o == 6:
        out = np.rot90(out, -1)
    elif o == 8:
        out = np.rot90(out, 1)
    elif o == 3:
        out = np.rot90(out, 2)
    return np.ascontiguousarray(out)


def load_bayer(paths):
    frames = []
    for p in paths:
        with rawpy.imread(p) as raw:
            frames.append(raw.raw_image_visible.astype(np.float32).copy())
    return torch.from_numpy(np.stack(frames))[:, None]  # N,1,H,W


def load_linear(paths):
    frames = []
    for p in paths:
        with rawpy.imread(p) as raw:
            rgb = raw.postprocess(gamma=(1, 1), no_auto_bright=True, output_bps=16,
                                  use_camera_wb=True, user_flip=0)
        frames.append(rgb.astype(np.float32).transpose(2, 0, 1) / 65535.0)
    return torch.from_numpy(np.stack(frames))  # N,3,H,W


def render_bayer(ref_path, bayer, ev):
    with rawpy.imread(ref_path) as raw:
        vis = raw.raw_image_visible
        maxv = np.iinfo(vis.dtype).max if np.issubdtype(vis.dtype, np.integer) else vis.max()
        vis[:] = np.clip(np.rint(bayer), 0, maxv).astype(vis.dtype)
        return raw.postprocess(use_camera_wb=True, no_auto_bright=True,
                               bright=2.0 ** ev, output_bps=16)


def render_linear(rgb_lin, ev):
    x = np.clip(rgb_lin.transpose(1, 2, 0) * (2.0 ** ev), 0, 1)
    # sRGB OETF
    x = np.where(x <= 0.0031308, 12.92 * x, 1.055 * np.power(x, 1 / 2.4) - 0.055)
    return (x * 65535).astype(np.uint16)


def to8(img16):
    return (img16 >> 8).astype(np.uint8)


def side_by_side_crop(a, b, size=600):
    h, w = a.shape[:2]
    y0, x0 = max(0, h // 2 - size // 2), max(0, w // 2 - size // 2)
    ca, cb = a[y0:y0 + size, x0:x0 + size], b[y0:y0 + size, x0:x0 + size]
    gap = np.full((ca.shape[0], 8, 3), 255, np.uint8)
    return np.concatenate([ca, gap, cb], axis=1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("folder", type=Path)
    ap.add_argument("--out", type=Path, default=ROOT / "data" / "output")
    ap.add_argument("--ref", type=int, default=0, help="index frame referensi")
    ap.add_argument("--tile", type=int, default=16)
    ap.add_argument("--search", type=int, default=2)
    ap.add_argument("--ev", type=float, default=0.0, help="boost exposure (stop)")
    ap.add_argument("--max-frames", type=int, default=0)
    ap.add_argument("--merge", choices=["robust", "simple"], default="robust")
    ap.add_argument("--nr", type=float, default=18,
                    help="noise reduction 1..23 (robust merge). Default 18 (hasil uji ProRAW iPhone, sesi 3)")
    ap.add_argument("--k", type=float, default=0,
                    help="robust merge pakai NoiseProfile DNG, ambang k x noise (mis. 4). 0 = pakai --nr")
    ap.add_argument("--no-local-tm", action="store_true", help="ProRAW: jangan pakai ProfileGainTableMap")
    args = ap.parse_args()

    paths = list_raws(args.folder)
    if args.max_frames:
        paths = paths[: args.max_frames]
    kind = detect_kind(paths[0])
    print(f"{len(paths)} frame, jenis: {kind}")

    t0 = time.time()
    meta = None
    if kind == "bayer":
        images = load_bayer(paths)
    elif kind == "proraw":
        images, meta = load_proraw(paths)
    else:
        images = load_linear(paths)
    print(f"load {list(images.shape)} {time.time() - t0:.1f}s")

    t0 = time.time()
    if args.merge == "robust":
        merged, wts, nsd = rm.align_and_robust_merge(images, ref_idx=args.ref, noise_reduction=args.nr,
                                                     tile_size=args.tile, search_dist=args.search,
                                                     return_weights=True,
                                                     noise_profile=(meta or {}).get("noise_profile") if args.k else None,
                                                     k_sigma=args.k or 4.0)
        print(f"robust merge nr={args.nr:g} k={args.k:g}: bobot rata-rata per frame {[round(w, 2) for w in wts]}")
    else:
        merged = align.align_and_merge(images, ref_idx=args.ref, tile_size=args.tile,
                                       search_dist=args.search)
    print(f"align+merge ({args.merge}) {time.time() - t0:.1f}s")

    ref_path = paths[args.ref]
    if kind == "bayer":
        ref16 = render_bayer(ref_path, images[args.ref, 0].numpy(), args.ev)
        mer16 = render_bayer(ref_path, merged[0].numpy(), args.ev)
    elif kind == "proraw":
        ref16 = render_proraw(images[args.ref].numpy(), meta, args.ev, not args.no_local_tm)
        mer16 = render_proraw(merged.numpy(), meta, args.ev, not args.no_local_tm)
    else:
        ref16 = render_linear(images[args.ref].numpy(), args.ev)
        mer16 = render_linear(merged.numpy(), args.ev)

    args.out.mkdir(parents=True, exist_ok=True)
    name = f"{args.folder.name}_{args.merge}" + (f"-k{args.k:g}" if args.k else f"-nr{args.nr:g}" if args.merge == "robust" else "")
    tifffile.imwrite(args.out / f"{name}_merged_16bit.tiff", mer16)
    iio.imwrite(args.out / f"{name}_ref.jpg", to8(ref16), quality=92)
    iio.imwrite(args.out / f"{name}_merged.jpg", to8(mer16), quality=92)
    iio.imwrite(args.out / f"{name}_compare_crop.jpg", side_by_side_crop(to8(ref16), to8(mer16)), quality=92)
    if kind == "proraw":
        write_linear_dng(args.out / f"{name}_merged.dng", merged.numpy(), ref_path)
    print(f"hasil di {args.out}")


# tag DNG yang disalin dari file sumber (warna, exposure, tone map Apple, info kamera)
DNG_COPY_TAGS = ["Make", "Model", "Orientation", "DateTime", "UniqueCameraModel",
                 "ColorMatrix1", "ColorMatrix2", "CalibrationIlluminant1", "CalibrationIlluminant2",
                 "ForwardMatrix1", "ForwardMatrix2", "AsShotNeutral", "BaselineExposure",
                 "BaselineNoise", "BaselineSharpness", "LinearResponseLimit", "ProfileName",
                 "ProfileGainTableMap", "DefaultBlackRender", "NoiseProfile",
                 "DefaultCropOrigin", "DefaultCropSize"]


def write_linear_dng(out_path, lin_chw, src_path):
    """Tulis hasil merge (linear RGB 0..1) sebagai DNG LinearRaw 16-bit tanpa kompresi.
    Metadata warna + ProfileGainTableMap disalin dari frame referensi, jadi Lightroom/ACR
    me-render dengan profil Apple yang sama."""
    data = (np.clip(lin_chw.transpose(1, 2, 0), 0, 1) * 65535 + 0.5).astype(np.uint16)
    extratags = [
        (50706, "B", 4, (1, 6, 0, 0), True),   # DNGVersion 1.6 (wajib untuk ProfileGainTableMap)
        (50707, "B", 4, (1, 4, 0, 0), True),   # DNGBackwardVersion
        (50714, "H", 3, (0, 0, 0), True),      # BlackLevel
        (50717, "H", 3, (65535,) * 3, True),   # WhiteLevel
    ]
    with tifffile.TiffFile(src_path) as t:
        main, sub = t.pages[0], t.pages[0].pages[0]
        for name in DNG_COPY_TAGS:
            tag = sub.tags.get(name) or main.tags.get(name)
            if tag is None:
                continue
            v = tag.value
            if isinstance(v, bytes) or tag.dtype == 7:      # UNDEFINED
                extratags.append((tag.code, 7, len(bytes(v)), bytes(v), True))
            elif isinstance(v, str):
                extratags.append((tag.code, "s", 0, v, True))
            else:
                extratags.append((tag.code, int(tag.dtype), tag.count,
                                  v if isinstance(v, (tuple, list)) else (v,), True))
    tifffile.imwrite(out_path, data, photometric=34892, planarconfig="contig",
                     subfiletype=0, extratags=extratags, metadata=None,
                     software="BaginCam burst_merge (HDR+ robust merge)")


if __name__ == "__main__":
    main()
