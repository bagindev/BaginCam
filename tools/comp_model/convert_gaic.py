"""Konversi model komposisi GAIC (PyTorch) -> Core ML untuk BaginCam.

Tiap backbone jadi dua model:
  BaginCamComp_<nama>_feat : gambar RGB (sisi pendek 256, kelipatan 32) -> peta fitur [1, C, H/16, W/16]
  BaginCamComp_<nama>_head : [32, 2C, 9, 9] (fitur RoIAlign + RoDAlign) -> skor [32]
RoIAlign / RoDAlign dikerjakan di app (CompScorer.swift), sama dengan tools/comp_gaic.py.

Pakai: python convert_gaic.py <folder_bobot> <folder_hasil>
Juga menulis gambar uji + skor acuan PyTorch (acuan.json) untuk menguji CompScorer.swift.
"""
import json, os, sys
import numpy as np, torch
import torch.nn as nn
import torch.nn.functional as F
from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import comp_gaic as G


def channel_shuffle(x, groups):
    """pengganti torchvision channel_shuffle: indeks kanal tetap, tanpa reshape yang bergantung pada tinggi/lebar
    (reshape hasil trace salah bentuk saat ukuran masukan berganti - konversi pertama: selisih 0,20 di 352x256)."""
    c = x.shape[1]
    idx = torch.arange(c).view(groups, c // groups).t().reshape(-1)
    return x.index_select(1, idx)


SHAPES = [(352, 256), (256, 352), (448, 256), (256, 448), (256, 256), (320, 256), (256, 320)]   # (tinggi, lebar)
BATCH = 32
NAMES = {'mobilenetv2': 'MobileNetV2', 'shufflenetv2': 'ShuffleNetV2', 'vgg16': 'VGG16'}


class Feat(nn.Module):
    """gambar 0..255 RGB -> peta fitur tereduksi. Sama dengan GAIC.features, tetapi resample memakai faktor tetap
    (f3 selalu 2x lebih besar dan f5 2x lebih kecil dari f4 bila sisi gambar kelipatan 32)."""

    def __init__(self, net):
        super().__init__()
        self.net = net
        self.register_buffer('mean', torch.tensor(G.MEAN).view(1, 3, 1, 1) * 255)
        self.register_buffer('std', torch.tensor(G.STD).view(1, 3, 1, 1) * 255)

    def forward(self, x):
        x = (x - self.mean) / self.std
        f3, f4, f5 = self.net.Feat_ext(x)
        f3 = F.interpolate(f3, scale_factor=0.5, mode='bilinear', align_corners=True)
        f5 = F.interpolate(f5, scale_factor=2.0, mode='bilinear', align_corners=True)
        return self.net.DimRed(torch.cat((f3, f4, 0.5 * f5), 1))


class Head(nn.Module):
    def __init__(self, net):
        super().__init__()
        self.fc = net.FC_layers

    def forward(self, x):
        return self.fc(x).reshape(-1)


def test_image(h, w):
    """gambar uji tetap: gradasi + bentuk, supaya skor antar kandidat berbeda"""
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    im = np.stack([xx / w * 200 + 30, yy / h * 180 + 40, (xx + yy) / (w + h) * 160 + 50], -1)
    cy, cx = h * 0.62, w * 0.36
    im[((yy - cy) ** 2 + (xx - cx) ** 2) < (0.16 * min(h, w)) ** 2] = (235, 60, 50)
    im[int(h * 0.10):int(h * 0.28), int(w * 0.55):int(w * 0.90)] = (40, 70, 200)
    im[int(h * 0.80):, :] = im[int(h * 0.80):, :] * 0.5
    return np.clip(im, 0, 255).astype(np.uint8)


def test_boxes(h, w):
    out = [[0, 0, w - 1, h - 1]]
    for c in (0.94, 0.82, 0.70, 0.55):
        for fx in (0.0, 0.5, 1.0):
            for fy in (0.0, 0.5, 1.0):
                x, y = fx * (1 - c) * w, fy * (1 - c) * h
                out.append([round(x, 2), round(y, 2), round(x + c * w - 1, 2), round(y + c * h - 1, 2)])
    return out


def main():
    import coremltools as ct
    wdir, odir = sys.argv[1], sys.argv[2]
    os.makedirs(odir, exist_ok=True)
    th, tw = 352, 256
    img = test_image(th, tw)
    Image.fromarray(img).save(os.path.join(odir, 'uji_256x352.png'))
    boxes = test_boxes(th, tw)
    ref = {'width': tw, 'height': th, 'boxes': boxes, 'scores': {}}
    for name in NAMES:
        net = G.GAIC(name).eval()
        sd = torch.load(os.path.join(wdir, 'GAIC-%s-reddim%d.pth' % (name, G.GAIC.DIMS[name][1])), map_location='cpu', weights_only=True)
        net.load_state_dict(sd)
        if name == 'shufflenetv2':
            import torchvision.models.shufflenetv2 as snv2
            xs = torch.randn(2, 116, 7, 5)
            assert torch.equal(snv2.channel_shuffle(xs, 2), channel_shuffle(xs, 2))
            snv2.channel_shuffle = channel_shuffle
        feat, head = Feat(net).eval(), Head(net).eval()
        red = G.GAIC.DIMS[name][1]

        # acuan PyTorch: jalur asli (interpolasi ke ukuran f4) vs pembungkus (faktor tetap) harus sama
        x255 = torch.from_numpy(img.astype(np.float32)).permute(2, 0, 1).unsqueeze(0)
        xn = torch.from_numpy((img.astype(np.float32) / 255 - G.MEAN) / G.STD).permute(2, 0, 1).unsqueeze(0)
        with torch.no_grad():
            f_ref = net.features(xn)
            f_wrap = feat(x255)[0]
            d = float((f_ref - f_wrap).abs().max())
            assert d < 1e-3, ('pembungkus berbeda dari jalur asli', d)
            s_ref = net.score(f_ref, torch.tensor(boxes, dtype=torch.float32)).numpy()
        ref['scores'][name] = [round(float(v), 5) for v in s_ref]
        print(name, 'pembungkus vs asli: selisih fitur maks %.2e, skor acuan %.3f..%.3f' % (d, s_ref.min(), s_ref.max()))

        # --- fitur ---
        ex = torch.rand(1, 3, th, tw) * 255
        traced = torch.jit.trace(feat, ex)
        shapes = ct.EnumeratedShapes(shapes=[(1, 3, h, w) for h, w in SHAPES], default=(1, 3, th, tw))
        mf = None
        for prec in (ct.precision.FLOAT16, ct.precision.FLOAT32):       # fp16 dulu; bila meleset, pakai fp32
            mf = ct.convert(traced, convert_to='mlprogram', minimum_deployment_target=ct.target.iOS17,
                            inputs=[ct.ImageType(name='image', shape=shapes, color_layout=ct.colorlayout.RGB, scale=1.0)],
                            outputs=[ct.TensorType(name='features', dtype=np.float32)],
                            compute_precision=prec)
            worst = 0.0
            for h, w in SHAPES:
                arr = test_image(h, w)
                out = mf.predict({'image': Image.fromarray(arr)})['features']
                with torch.no_grad():
                    want = feat(torch.from_numpy(arr.astype(np.float32)).permute(2, 0, 1).unsqueeze(0)).numpy()
                assert out.shape == want.shape, (out.shape, want.shape)
                err, rng = float(np.abs(out - want).max()), float(np.abs(want).max())
                worst = max(worst, err / (0.03 * rng + 0.02))
                print('  fitur %s %dx%d -> %s selisih maks %.4f (rentang %.2f)' % (prec.name, w, h, out.shape, err, rng))
            if worst < 1:
                break
            print('  ! presisi %s meleset (%.1fx batas)' % (prec.name, worst))
        assert worst < 1, worst
        mf.short_description = 'BaginCam AI Komposisi: fitur GAIC %s (MIT), sisi pendek 256' % NAMES[name]
        mf.author = 'GAIC (Zeng dkk.) - bobot bo-zhang-cs/GAIC-Pytorch, dikonversi untuk BaginCam'
        mf.license = 'MIT'
        pf = os.path.join(odir, 'BaginCamComp_%s_feat.mlpackage' % name)
        mf.save(pf)

        # --- kepala ---
        exh = torch.rand(BATCH, red * 2, 9, 9)
        mh = ct.convert(torch.jit.trace(head, exh), convert_to='mlprogram', minimum_deployment_target=ct.target.iOS17,
                        inputs=[ct.TensorType(name='aligned', shape=exh.shape, dtype=np.float32)],
                        outputs=[ct.TensorType(name='scores', dtype=np.float32)],
                        compute_precision=ct.precision.FLOAT16)
        mh.short_description = 'BaginCam AI Komposisi: penilai GAIC %s (MIT), %d kandidat per panggilan' % (NAMES[name], BATCH)
        mh.author = mf.author
        mh.license = 'MIT'
        ph = os.path.join(odir, 'BaginCamComp_%s_head.mlpackage' % name)
        mh.save(ph)

        # --- cek Core ML vs PyTorch (di macOS) ---
        with torch.no_grad():
            roi = G.roi_align_avg(f_ref, torch.tensor(boxes, dtype=torch.float32), 9, 1 / 16)
            rod = G.rod_align_avg(f_ref, torch.tensor(boxes, dtype=torch.float32), 9, 1 / 16)
            al = torch.cat((roi, rod), 1).numpy()
        pad = np.zeros((BATCH,) + al.shape[1:], np.float32)
        got = []
        for i in range(0, len(al), BATCH):
            n = min(BATCH, len(al) - i)
            pad[:] = 0
            pad[:n] = al[i:i + n]
            got.extend(mh.predict({'aligned': pad})['scores'].reshape(-1)[:n].tolist())
        err = float(np.abs(np.array(got) - s_ref).max())
        print('  kepala: selisih skor maks %.4f' % err)
        assert err < 0.05, err
    json.dump(ref, open(os.path.join(odir, 'acuan.json'), 'w'))
    print('acuan.json', len(boxes), 'kotak')


if __name__ == '__main__':
    main()
