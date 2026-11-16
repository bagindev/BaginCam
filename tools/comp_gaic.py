"""Uji model komposisi GAIC (Grid Anchor based Image Cropping, Zeng dkk., kode MIT) pada foto sendiri, di CPU.

Model & bobot: implementasi bo-zhang-cs/GAIC-Pytorch (MIT). RoIAlign / RoDAlign ditulis ulang dengan torch murni
(aslinya ekstensi C++/CUDA) mengikuti untils/roi_align/src/roi_align.cpp dan rod_align.cpp.

Pakai: python comp_gaic.py <folder_bobot> <folder_foto> <folder_hasil> [backbone ...]
"""
import os, sys, time
import numpy as np, cv2, torch
import torch.nn as nn
import torch.nn.functional as F
import torchvision
import pillow_heif
from PIL import Image, ImageOps

pillow_heif.register_heif_opener()
MEAN = np.array([0.485, 0.456, 0.406], np.float32)
STD = np.array([0.229, 0.224, 0.225], np.float32)


def bilinear(feat, h, w):
    """feat [C,H,W]; h,w [N,P] koordinat piksel -> [N,C,P] (rumus sama dengan kode C aslinya)."""
    C, H, W = feat.shape
    hs = torch.clamp(torch.floor(h), 0, H - 2)
    ws = torch.clamp(torch.floor(w), 0, W - 2)
    hr, wr = (h - hs).unsqueeze(1), (w - ws).unsqueeze(1)
    hs, ws = hs.long(), ws.long()
    flat = feat.reshape(C, H * W)

    def take(idx):
        return flat[:, idx.reshape(-1)].reshape(C, *idx.shape).permute(1, 0, 2)

    ul, ur = take(hs * W + ws), take(hs * W + ws + 1)
    dl, dr = take((hs + 1) * W + ws), take((hs + 1) * W + ws + 1)
    return ul * (1 - hr) * (1 - wr) + ur * (1 - hr) * wr + dl * hr * (1 - wr) + dr * hr * wr


def roi_align_avg(feat, rois, size, scale):
    """feat [C,H,W], rois [N,4] (x1,y1,x2,y2 piksel gambar) -> [N,C,size,size]"""
    C, H, W = feat.shape
    A = size + 1
    r = rois * scale
    x1, y1, x2, y2 = r[:, 0:1], r[:, 1:2], r[:, 2:3], r[:, 3:4]
    bw = torch.clamp(x2 - x1 + 1, min=0) / (A - 1)
    bh = torch.clamp(y2 - y1 + 1, min=0) / (A - 1)
    k = torch.arange(A, dtype=torch.float32)
    hh = (k[None, :] * bh + y1)[:, :, None].expand(-1, A, A).reshape(-1, A * A)
    ww = (k[None, :] * bw + x1)[:, None, :].expand(-1, A, A).reshape(-1, A * A)
    out = bilinear(feat, hh, ww)
    bad = ((hh < 0) | (hh >= H) | (ww < 0) | (ww >= W)).unsqueeze(1)
    out = out.masked_fill(bad, 0).reshape(-1, C, A, A)
    return F.avg_pool2d(out, kernel_size=2, stride=1)


def rod_align_avg(feat, rois, size, scale):
    C, H, W = feat.shape
    A = size + 1
    r = rois * scale
    x1, y1, x2, y2 = r[:, 0:1], r[:, 1:2], r[:, 2:3], r[:, 3:4]
    k = torch.arange(A, dtype=torch.float32)
    hh = (k * ((H - 1.001) / (A - 1)))[None, :, None].expand(len(r), A, A).reshape(-1, A * A)
    ww = (k * ((W - 1.001) / (A - 1)))[None, None, :].expand(len(r), A, A).reshape(-1, A * A)
    out = bilinear(feat, hh, ww)
    inside = ((hh >= y1) & (hh <= y2) & (ww >= x1) & (ww <= x2)).unsqueeze(1)
    out = out.masked_fill(inside, 0).reshape(-1, C, A, A)
    return F.avg_pool2d(out, kernel_size=2, stride=1)


class Backbone(nn.Module):
    def __init__(self, name):
        super().__init__()
        if name == 'mobilenetv2':
            m = torchvision.models.mobilenet_v2(weights=None)
            self.feature3, self.feature4, self.feature5 = (nn.Sequential(m.features[:7]), nn.Sequential(m.features[7:14]),
                                                           nn.Sequential(m.features[14:-1]))
        elif name == 'shufflenetv2':
            m = torchvision.models.shufflenet_v2_x1_0(weights=None)
            self.feature3 = nn.Sequential(m.conv1, m.maxpool, m.stage2)
            self.feature4, self.feature5 = nn.Sequential(m.stage3), nn.Sequential(m.stage4)
        else:
            m = torchvision.models.vgg16(weights=None)
            self.feature3, self.feature4, self.feature5 = (nn.Sequential(m.features[:23]), nn.Sequential(m.features[23:30]),
                                                           nn.Sequential(m.features[30:]))

    def forward(self, x):
        f3 = self.feature3(x)
        f4 = self.feature4(f3)
        return f3, f4, self.feature5(f4)


class GAIC(nn.Module):
    DIMS = {'mobilenetv2': (448, 16), 'shufflenetv2': (812, 32), 'vgg16': (1536, 32)}

    def __init__(self, name, align=9):
        super().__init__()
        cin, red = self.DIMS[name]
        self.align = align
        self.Feat_ext = Backbone(name)
        self.DimRed = nn.Conv2d(cin, red, 1)
        self.FC_layers = nn.Sequential(nn.Sequential(nn.Conv2d(red * 2, 768, align), nn.ReLU(True)),
                                       nn.Sequential(nn.Conv2d(768, 128, 1), nn.ReLU(True)), nn.Conv2d(128, 1, 1))

    def features(self, im):
        f3, f4, f5 = self.Feat_ext(im)
        f3 = F.interpolate(f3, size=f4.shape[2:], mode='bilinear', align_corners=True)
        f5 = F.interpolate(f5, size=f4.shape[2:], mode='bilinear', align_corners=True)
        return self.DimRed(torch.cat((f3, f4, 0.5 * f5), 1))[0]

    def score(self, feat, boxes):
        roi = roi_align_avg(feat, boxes, self.align, 1 / 16)
        rod = rod_align_avg(feat, boxes, self.align, 1 / 16)
        return self.FC_layers(torch.cat((roi, rod), 1)).reshape(-1)


def anchors_ratio(W, H, ratio, bins=20):
    """kandidat crop dengan rasio tetap (w:h), sama dengan generate_anchors_aspect_ratio_specific aslinya"""
    ws, hs = int(ratio[0]), int(ratio[1])
    mx = int(min(W / ws, H / hs))
    if mx > bins:
        sc = int(max(W / ws / bins, H / hs / bins))
        ws, hs = ws * sc, hs * sc
        mx = int(min(W / ws, H / hs))
    out = []
    for i in range(int(mx / 2. - 1), mx):
        oh, ow = hs * i, ws * i
        if oh < H and ow < W and ow * oh > 0.4 * W * H:
            for x in range(0, W - ow, ws):
                for y in range(0, H - oh, hs):
                    out.append([x, y, x + ow - 1, y + oh - 1])
    return np.array(out, np.float32).reshape(-1, 4)


def load_image(path, long_side=2000):
    im = ImageOps.exif_transpose(Image.open(path)).convert('RGB')
    k = long_side / max(im.size)
    if k < 1:
        im = im.resize((round(im.width * k), round(im.height * k)), Image.LANCZOS)
    return im


def label(img, text, scale=0.7):
    for col, th in (((0, 0, 0), 4), ((255, 255, 0), 2)):
        cv2.putText(img, text, (8, 26), cv2.FONT_HERSHEY_SIMPLEX, scale, col, th)
    return img


def main():
    wdir, idir, odir = sys.argv[1:4]
    names = sys.argv[4:] or ['mobilenetv2', 'shufflenetv2', 'vgg16']
    os.makedirs(odir, exist_ok=True)
    torch.set_num_threads(max(1, os.cpu_count() - 2))
    nets = {}
    for n in names:
        net = GAIC(n).eval()
        sd = torch.load(os.path.join(wdir, 'GAIC-%s-reddim%d.pth' % (n, GAIC.DIMS[n][1])), map_location='cpu', weights_only=True)
        missing, unexpected = net.load_state_dict(sd, strict=False)
        assert not missing, missing
        print(n, 'bobot dimuat,', sum(p.numel() for p in net.parameters()) // 1000, 'ribu parameter, kunci lebih:', len(unexpected))
        nets[n] = net
    files = sorted(f for f in os.listdir(idir) if f.lower().endswith(('.heic', '.jpg', '.jpeg', '.png')))
    COL = {'mobilenetv2': (0, 255, 0), 'shufflenetv2': (0, 200, 255), 'vgg16': (255, 80, 80)}
    for f in files:
        im = load_image(os.path.join(idir, f))
        W0, H0 = im.size
        sc = 256. / min(W0, H0)
        w, h = round(W0 * sc / 32.0) * 32, round(H0 * sc / 32.0) * 32
        x = (np.asarray(im.resize((w, h), Image.LANCZOS), np.float32) / 255 - MEAN) / STD
        x = torch.from_numpy(x).permute(2, 0, 1).unsqueeze(0)
        ratio = (4, 3) if W0 >= H0 else (3, 4)                    # crop dengan rasio foto itu sendiri
        anc = anchors_ratio(w, h, ratio)
        full = np.array([[0, 0, w - 1, h - 1]], np.float32)       # bingkai asli ikut dinilai
        boxes = torch.from_numpy(np.vstack([full, anc]))
        src = np.array(im)
        vis = src.copy()
        tiles, line = [], []
        for n, net in nets.items():
            t0 = time.time()
            with torch.no_grad():
                s = net.score(net.features(x), boxes).numpy()
            dt = time.time() - t0
            order = np.argsort(-s[1:]) + 1
            b = boxes[order[0]].numpy()
            x1, y1, x2, y2 = int(b[0] / w * W0), int(b[1] / h * H0), int(b[2] / w * W0), int(b[3] / h * H0)
            area = (x2 - x1) * (y2 - y1) / (W0 * H0)
            rank_full = int((s[1:] > s[0]).sum()) + 1
            line.append('%s: asli %.2f (peringkat %d/%d), terbaik %.2f luas %.0f%% [%.1f s]' % (
                n[:7], s[0], rank_full, len(s), s[order[0]], area * 100, dt))
            cv2.rectangle(vis, (x1, y1), (x2, y2), COL[n], max(3, W0 // 300))
            crop = cv2.resize(src[y1:y2, x1:x2], (W0, H0), interpolation=cv2.INTER_AREA)
            tiles.append(label(np.ascontiguousarray(crop), '%s  skor %.2f (asli %.2f)' % (n, s[order[0]], s[0]), W0 / 900))
        print(f, '%dx%d' % (W0, H0), len(anc), 'kandidat |', ' | '.join(line))
        row = np.hstack([label(vis, 'asli + kotak pilihan', W0 / 900)] + tiles)
        k = 2400 / row.shape[1]
        row = cv2.resize(row, (2400, round(row.shape[0] * k)), interpolation=cv2.INTER_AREA)
        Image.fromarray(row).save(os.path.join(odir, os.path.splitext(f)[0] + '_gaic.jpg'), quality=88)


if __name__ == '__main__':
    main()
