"""BaginCam AI video di Google Colab (GPU): pertajam / perbesar video dari folder Google Drive.

Dipakai notebook tools/colab_video/BaginCam_AI_video.ipynb (isi file ini disalin utuh ke sel %%writefile oleh
make_notebook.py). Bisa juga dijalankan lokal untuk uji (CPU, sangat lambat):
  python bagincam_ai_video.py MASUK SELESAI --model vsr --input 256 --test-seconds 0.5 --weights DIR

Model (bobot diunduh dari rilis resminya, hash SHA-256 dicek; arsitektur ditulis ulang di sini, identik dengan
mmagic / basicsr, supaya tidak perlu memasang mmcv / basicsr yang sering rusak di Colab):
- vsr    : RealBasicVSR (Chan dkk., CVPR 2022). Model VIDEO: membaca banyak frame sekaligus (aliran optik SPyNet,
           propagasi maju + mundur), jadi detail konsisten antar frame dan tidak berkedip. Bobot OpenMMLab.
- cepat  : Real-ESRGAN realesr-general-x4v3 (= "Cepat" di app), per frame + kurangi kedip.
- detail : Real-ESRGAN x4plus (= "Detail" di app), per frame + kurangi kedip.

Alur per video: ffmpeg decode (RGB 16-bit, sudah tegak) -> GPU -> hasil = asli + kekuatan x (AI - asli) ->
ffmpeg encode HEVC 10-bit (NVENC bila ada) + audio & metadata (tanggal, lokasi) disalin dari file asli.
Warna (SDR Rec.709 / HDR HLG) dipertahankan: nilai sinyal diproses apa adanya lalu ditandai sama dengan sumber.
"""
import argparse
import contextlib
import glob
import hashlib
import json
import os
import queue
import re
import shutil
import subprocess
import threading
import time
import urllib.request

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

FFMPEG = 'ffmpeg'
FFPROBE = 'ffprobe'
WEIGHTS_DIR = os.path.expanduser('~/.cache/bagincam')
VIDEO_EXT = ('.mov', '.mp4', '.m4v')

MODELS = {
    'vsr': dict(name='RealBasicVSR (video)', tag='AIV', file='realbasicvsr_x4.pth',
                url='https://download.openmmlab.com/mmediting/restorers/real_basicvsr/'
                    'realbasicvsr_c64b20_1x30x8_lr5e-5_150k_reds_20211104-52f77c2c.pth',
                sha='52f77c2c835aaa3fe675b3959b2f85010a6c6f63f77f7e279394646e55a4e376'),
    'cepat': dict(name='Real-ESRGAN Cepat (general-x4v3)', tag='AIC', file='realesr-general-x4v3.pth',
                  url='https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-general-x4v3.pth',
                  sha='8dc7edb9ac80ccdc30c3a5dca6616509367f05fbc184ad95b731f05bece96292'),
    'detail': dict(name='Real-ESRGAN Detail (x4plus)', tag='AID', file='RealESRGAN_x4plus.pth',
                   url='https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth',
                   sha='4fa0d38905f75ac06eb49a7951b426670021be3018265fd191d2125df9d682f1'),
}


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for b in iter(lambda: f.read(1 << 20), b''):
            h.update(b)
    return h.hexdigest()


def fetch(key):
    m = MODELS[key]
    os.makedirs(WEIGHTS_DIR, exist_ok=True)
    path = os.path.join(WEIGHTS_DIR, m['file'])
    if os.path.exists(path) and sha256(path) == m['sha']:
        return path
    tmp = path + '.part'
    print(f"Unduh model {m['name']} ...", flush=True)
    urllib.request.urlretrieve(m['url'], tmp)
    got = sha256(tmp)
    if got != m['sha']:
        os.remove(tmp)
        raise RuntimeError(f'Hash model {key} tidak cocok ({got}); file ditolak')
    os.replace(tmp, path)
    return path


# ---------------------------------------------------------------- arsitektur RealBasicVSR (mmagic)

def lrelu(x):
    return F.leaky_relu(x, 0.1, inplace=True)


class ResidualBlockNoBN(nn.Module):
    def __init__(self, c=64):
        super().__init__()
        self.conv1 = nn.Conv2d(c, c, 3, 1, 1)
        self.conv2 = nn.Conv2d(c, c, 3, 1, 1)

    def forward(self, x):
        return x + self.conv2(F.relu(self.conv1(x)))


class ResidualBlocksWithInputConv(nn.Module):
    def __init__(self, cin, c, n):
        super().__init__()
        self.main = nn.Sequential(nn.Conv2d(cin, c, 3, 1, 1), nn.LeakyReLU(0.1, inplace=True),
                                  nn.Sequential(*[ResidualBlockNoBN(c) for _ in range(n)]))

    def forward(self, x):
        return self.main(x)


class PixelShufflePack(nn.Module):
    def __init__(self, cin, cout, s):
        super().__init__()
        self.s = s
        self.upsample_conv = nn.Conv2d(cin, cout * s * s, 3, 1, 1)

    def forward(self, x):
        return F.pixel_shuffle(self.upsample_conv(x), self.s)


def flow_warp(x, flow, padding_mode='zeros'):
    """x (n,c,h,w), flow (n,h,w,2) dalam piksel. Grid dihitung fp32 (fp16 tidak cukup teliti di 1080p)."""
    n, _, h, w = x.shape
    flow = flow.float()
    gy, gx = torch.meshgrid(torch.arange(h, device=x.device, dtype=torch.float32),
                            torch.arange(w, device=x.device, dtype=torch.float32), indexing='ij')
    g = torch.stack((gx, gy), 2) + flow
    g = torch.stack((2.0 * g[..., 0] / max(w - 1, 1) - 1.0, 2.0 * g[..., 1] / max(h - 1, 1) - 1.0), 3)
    with torch.autocast(x.device.type, enabled=False):
        out = F.grid_sample(x.float(), g, mode='bilinear', padding_mode=padding_mode, align_corners=True)
    return out.to(x.dtype)


class ConvModule(nn.Module):
    """mmcv ConvModule tanpa norm: conv 7x7 + ReLU (opsional)"""

    def __init__(self, cin, cout, act):
        super().__init__()
        self.conv = nn.Conv2d(cin, cout, 7, 1, 3)
        self.act = act

    def forward(self, x):
        x = self.conv(x)
        return F.relu(x) if self.act else x


class SPyNetBasicModule(nn.Module):
    def __init__(self):
        super().__init__()
        ch = [8, 32, 64, 32, 16, 2]
        self.basic_module = nn.Sequential(*[ConvModule(ch[i], ch[i + 1], i < 4) for i in range(5)])

    def forward(self, x):
        return self.basic_module(x)


class SPyNet(nn.Module):
    def __init__(self):
        super().__init__()
        self.basic_module = nn.ModuleList([SPyNetBasicModule() for _ in range(6)])
        self.register_buffer('mean', torch.Tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1))
        self.register_buffer('std', torch.Tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1))

    def compute_flow(self, ref, supp):
        n, _, h, w = ref.shape
        ref = [(ref - self.mean) / self.std]
        supp = [(supp - self.mean) / self.std]
        for _ in range(5):
            ref.append(F.avg_pool2d(ref[-1], 2, 2, count_include_pad=False))
            supp.append(F.avg_pool2d(supp[-1], 2, 2, count_include_pad=False))
        ref, supp = ref[::-1], supp[::-1]
        flow = ref[0].new_zeros(n, 2, h // 32, w // 32, dtype=torch.float32)
        for lv in range(len(ref)):
            up = flow if lv == 0 else F.interpolate(flow, scale_factor=2, mode='bilinear', align_corners=True) * 2.0
            res = self.basic_module[lv](torch.cat(
                [ref[lv], flow_warp(supp[lv], up.permute(0, 2, 3, 1), padding_mode='border'), up.to(ref[lv].dtype)], 1))
            flow = up + res.float()
        return flow

    def forward(self, ref, supp):
        h, w = ref.shape[2:4]
        wu, hu = (w + 31) // 32 * 32, (h + 31) // 32 * 32
        ref = F.interpolate(ref, size=(hu, wu), mode='bilinear', align_corners=False)
        supp = F.interpolate(supp, size=(hu, wu), mode='bilinear', align_corners=False)
        flow = F.interpolate(self.compute_flow(ref, supp), size=(h, w), mode='bilinear', align_corners=False)
        flow[:, 0] *= w / wu
        flow[:, 1] *= h / hu
        return flow


class BasicVSRNet(nn.Module):
    def __init__(self, c=64, nb=20):
        super().__init__()
        self.mid = c
        self.spynet = SPyNet()
        self.backward_resblocks = ResidualBlocksWithInputConv(c + 3, c, nb)
        self.forward_resblocks = ResidualBlocksWithInputConv(c + 3, c, nb)
        self.fusion = nn.Conv2d(c * 2, c, 1, 1, 0)
        self.upsample1 = PixelShufflePack(c, c, 2)
        self.upsample2 = PixelShufflePack(c, 64, 2)
        self.conv_hr = nn.Conv2d(64, 64, 3, 1, 1)
        self.conv_last = nn.Conv2d(64, 3, 3, 1, 1)

    def head(self, feat, lr):
        out = lrelu(self.fusion(feat))
        out = lrelu(self.upsample1(out))
        out = lrelu(self.upsample2(out))
        out = lrelu(self.conv_hr(out))
        out = self.conv_last(out).float()
        return out + F.interpolate(lr.float(), scale_factor=4, mode='bilinear', align_corners=False)

    def head_tiled(self, feat, lr, rows=96, pad=4):
        """kepala upsample (4x) per pita baris: hemat memori di 1080p+ (medan reseptif 2 px LR < pad)"""
        h = feat.shape[2]
        if h <= rows + 2 * pad:
            return self.head(feat, lr)
        outs = []
        for y0 in range(0, h, rows):
            y1 = min(h, y0 + rows)
            a, b = max(0, y0 - pad), min(h, y1 + pad)
            o = self.head(feat[:, :, a:b], lr[:, :, a:b])
            outs.append(o[:, :, (y0 - a) * 4:(y1 - a) * 4])
        return torch.cat(outs, 2)

    def flows(self, lrs, bs=2):
        a, b = lrs[:-1], lrs[1:]
        fb = torch.cat([self.spynet(a[k:k + bs], b[k:k + bs]) for k in range(0, len(a), bs)])
        ff = torch.cat([self.spynet(b[k:k + bs], a[k:k + bs]) for k in range(0, len(a), bs)])
        return ff, fb

    def run(self, lrs, emit):
        """lrs (t,3,h,w) 0..1. emit(i, hr (1,3,4h,4w)) dipanggil berurutan i = 0..t-1."""
        t, _, h, w = lrs.shape
        ff, fb = self.flows(lrs) if t > 1 else (None, None)
        back = [None] * t
        feat = lrs.new_zeros(1, self.mid, h, w)
        for i in range(t - 1, -1, -1):
            if i < t - 1:
                feat = flow_warp(feat, fb[i:i + 1].permute(0, 2, 3, 1))
            feat = self.backward_resblocks(torch.cat([lrs[i:i + 1].to(feat.dtype), feat], 1))
            back[i] = feat
        feat = torch.zeros_like(feat)
        for i in range(t):
            if i > 0:
                feat = flow_warp(feat, ff[i - 1:i].permute(0, 2, 3, 1))
            feat = self.forward_resblocks(torch.cat([lrs[i:i + 1].to(feat.dtype), feat], 1))
            emit(i, self.head_tiled(torch.cat([back[i], feat.to(back[i].dtype)], 1), lrs[i:i + 1]))
            back[i] = None


class RealBasicVSRNet(nn.Module):
    def __init__(self):
        super().__init__()
        self.image_cleaning = nn.Sequential(ResidualBlocksWithInputConv(3, 64, 20), nn.Conv2d(64, 3, 3, 1, 1))
        self.basicvsr = BasicVSRNet(64, 20)
        self.thres = 5 / 255.0            # dynamic_refine_thres konfigurasi uji RealBasicVSR
        self.n_clean = None               # jumlah putaran pembersih, dikunci per video (hindari lompatan antar potongan)

    def clean(self, lrs, bs=4):
        rounds = self.n_clean or 3
        for r in range(rounds):
            tot, outs = 0.0, []
            for k in range(0, len(lrs), bs):
                res = self.image_cleaning(lrs[k:k + bs]).float()
                tot += res.abs().sum().item()
                outs.append(lrs[k:k + bs] + res)
            lrs = torch.cat(outs)
            if self.n_clean is None and tot / lrs.numel() < self.thres:
                self.n_clean = r + 1
                break
        if self.n_clean is None:
            self.n_clean = rounds
        return lrs


# ---------------------------------------------------------------- arsitektur Real-ESRGAN (basicsr)

class SRVGGNetCompact(nn.Module):
    def __init__(self, num_feat=64, num_conv=32, upscale=4):
        super().__init__()
        self.upscale = upscale
        self.body = nn.ModuleList([nn.Conv2d(3, num_feat, 3, 1, 1), nn.PReLU(num_parameters=num_feat)])
        for _ in range(num_conv):
            self.body.append(nn.Conv2d(num_feat, num_feat, 3, 1, 1))
            self.body.append(nn.PReLU(num_parameters=num_feat))
        self.body.append(nn.Conv2d(num_feat, 3 * upscale * upscale, 3, 1, 1))

    def forward(self, x):
        out = x
        for layer in self.body:
            out = layer(out)
        return F.pixel_shuffle(out, self.upscale).float() + F.interpolate(x.float(), scale_factor=self.upscale, mode='nearest')


class ResidualDenseBlock(nn.Module):
    def __init__(self, nf=64, gc=32):
        super().__init__()
        self.conv1 = nn.Conv2d(nf, gc, 3, 1, 1)
        self.conv2 = nn.Conv2d(nf + gc, gc, 3, 1, 1)
        self.conv3 = nn.Conv2d(nf + 2 * gc, gc, 3, 1, 1)
        self.conv4 = nn.Conv2d(nf + 3 * gc, gc, 3, 1, 1)
        self.conv5 = nn.Conv2d(nf + 4 * gc, nf, 3, 1, 1)

    def forward(self, x):
        x1 = lrelu(self.conv1(x))
        x2 = lrelu(self.conv2(torch.cat((x, x1), 1)))
        x3 = lrelu(self.conv3(torch.cat((x, x1, x2), 1)))
        x4 = lrelu(self.conv4(torch.cat((x, x1, x2, x3), 1)))
        return self.conv5(torch.cat((x, x1, x2, x3, x4), 1)) * 0.2 + x


class RRDB(nn.Module):
    def __init__(self, nf=64, gc=32):
        super().__init__()
        self.rdb1, self.rdb2, self.rdb3 = ResidualDenseBlock(nf, gc), ResidualDenseBlock(nf, gc), ResidualDenseBlock(nf, gc)

    def forward(self, x):
        return self.rdb3(self.rdb2(self.rdb1(x))) * 0.2 + x


class RRDBNet(nn.Module):
    def __init__(self, nf=64, nb=23, gc=32):
        super().__init__()
        self.conv_first = nn.Conv2d(3, nf, 3, 1, 1)
        self.body = nn.Sequential(*[RRDB(nf, gc) for _ in range(nb)])
        self.conv_body = nn.Conv2d(nf, nf, 3, 1, 1)
        self.conv_up1 = nn.Conv2d(nf, nf, 3, 1, 1)
        self.conv_up2 = nn.Conv2d(nf, nf, 3, 1, 1)
        self.conv_hr = nn.Conv2d(nf, nf, 3, 1, 1)
        self.conv_last = nn.Conv2d(nf, 3, 3, 1, 1)

    def forward(self, x):
        feat = self.conv_first(x)
        feat = feat + self.conv_body(self.body(feat))
        feat = lrelu(self.conv_up1(F.interpolate(feat, scale_factor=2, mode='nearest')))
        feat = lrelu(self.conv_up2(F.interpolate(feat, scale_factor=2, mode='nearest')))
        return self.conv_last(lrelu(self.conv_hr(feat))).float()


def load_model(key, dev):
    sd = torch.load(fetch(key), map_location='cpu', weights_only=True)
    if key == 'vsr':
        sd = sd['state_dict']
        pre = 'generator_ema.' if any(k.startswith('generator_ema.') for k in sd) else 'generator.'
        sd = {k[len(pre):]: v for k, v in sd.items() if k.startswith(pre)}
        net = RealBasicVSRNet()
    else:
        sd = sd.get('params_ema') or sd['params']
        net = SRVGGNetCompact() if key == 'cepat' else RRDBNet()
    net.load_state_dict(sd, strict=True)
    return net.eval().to(dev)


def tiled(net, x, tile=384, pad=16):
    """model gambar 4x per ubin (Real-ESRGAN)"""
    _, _, h, w = x.shape
    if h <= tile and w <= tile:
        return net(x)
    out = x.new_zeros(1, 3, h * 4, w * 4, dtype=torch.float32)
    for y0 in range(0, h, tile):
        for x0 in range(0, w, tile):
            y1, x1 = min(h, y0 + tile), min(w, x0 + tile)
            a, b, c, d = max(0, y0 - pad), min(h, y1 + pad), max(0, x0 - pad), min(w, x1 + pad)
            o = net(x[:, :, a:b, c:d])
            out[:, :, y0 * 4:y1 * 4, x0 * 4:x1 * 4] = o[:, :, (y0 - a) * 4:(y1 - a) * 4, (x0 - c) * 4:(x1 - c) * 4]
    return out


# ---------------------------------------------------------------- video (ffmpeg)

MATRIX = {'bt709': 'bt709', 'bt2020nc': 'bt2020', 'bt2020c': 'bt2020', 'smpte170m': 'bt601', 'bt470bg': 'bt601'}


def probe(path):
    """dimensi tegak (rotasi diperhitungkan), fps, jumlah frame, warna, bitrate"""
    if shutil.which(FFPROBE) or os.path.exists(FFPROBE):
        j = json.loads(subprocess.run([FFPROBE, '-v', 'error', '-select_streams', 'v:0', '-show_streams',
                                       '-show_format', '-of', 'json', path], capture_output=True, text=True, check=True).stdout)
        s, fmt = j['streams'][0], j.get('format', {})
        rot = 0
        for sd in s.get('side_data_list', []):
            if 'rotation' in sd:
                rot = int(float(sd['rotation']))
        rot = int(s.get('tags', {}).get('rotate', rot))
        num, den = map(int, (s.get('r_frame_rate') or '30/1').split('/'))
        info = dict(w=int(s['width']), h=int(s['height']), rot=rot, fps=f'{num}/{den}', fpsf=num / max(den, 1),
                    dur=float(s.get('duration') or fmt.get('duration') or 0), pix=s.get('pix_fmt', ''),
                    range=s.get('color_range', ''), space=s.get('color_space', ''),
                    prim=s.get('color_primaries', ''), trc=s.get('color_transfer', ''),
                    br=int(s.get('bit_rate') or fmt.get('bit_rate') or 0))
    else:   # cadangan tanpa ffprobe: baca keluaran `ffmpeg -i`
        e = subprocess.run([FFMPEG, '-hide_banner', '-i', path], capture_output=True, text=True).stderr
        m = re.search(r'Stream #\S+.*?Video: .*?, (\w+)\(([^)]*)\), (\d+)x(\d+)[^\n]*', e)
        col = [c.strip() for c in m.group(2).split(',')]
        trip = (col[1] if len(col) > 1 else '').split('/')
        d = re.search(r'Duration: (\d+):(\d+):([\d.]+)', e)
        tbr = re.search(r'([\d.]+) tbr', m.group(0))
        br = re.search(r'(\d+) kb/s', m.group(0))
        r = re.search(r'rotation of (-?[\d.]+) degrees', e)
        fpsf = float(tbr.group(1)) if tbr else 30.0
        info = dict(w=int(m.group(3)), h=int(m.group(4)), rot=int(float(r.group(1))) if r else 0,
                    fps=f'{fpsf:g}', fpsf=fpsf,
                    dur=int(d.group(1)) * 3600 + int(d.group(2)) * 60 + float(d.group(3)) if d else 0.0,
                    pix=m.group(1), range=col[0] if col else '', space=trip[0],
                    prim=trip[1] if len(trip) > 1 else trip[0], trc=trip[2] if len(trip) > 2 else trip[0],
                    br=int(br.group(1)) * 1000 if br else 0)
    if abs(info['rot']) % 180 == 90:
        info['w'], info['h'] = info['h'], info['w']
    info['hdr'] = info['trc'] in ('arib-std-b67', 'smpte2084')
    return info


_ENC = None


def pick_encoder():
    """HEVC 10-bit: NVENC (GPU Colab) bila jalan, kalau tidak libx265, terakhir libx264 8-bit"""
    global _ENC
    if _ENC:
        return _ENC
    for enc, pix, args in (('hevc_nvenc', 'p010le', ['-preset', 'p5']), ('libx265', 'yuv420p10le', ['-preset', 'fast']),
                           ('libx264', 'yuv420p', ['-preset', 'fast'])):
        r = subprocess.run([FFMPEG, '-v', 'error', '-f', 'lavfi', '-i', 'color=c=gray:s=256x256:d=0.2', '-pix_fmt', pix,
                            '-c:v', enc, *args, '-f', 'null', '-'], capture_output=True)
        if r.returncode == 0:
            _ENC = (enc, pix, args)
            return _ENC
    raise RuntimeError('ffmpeg tidak punya encoder HEVC / H.264')


def even(x):
    return max(2, int(round(x / 2)) * 2)


class Reader:
    def __init__(self, path, info, seconds):
        self.n = info['w'] * info['h'] * 3 * 2
        mat = MATRIX.get(info['space'], 'bt709')
        rng = 'pc' if info['range'] == 'pc' or info['pix'].startswith('yuvj') else 'tv'
        cmd = [FFMPEG, '-v', 'error', '-i', path, '-map', '0:v:0']
        if seconds:
            cmd += ['-t', str(seconds)]
        cmd += ['-vsync', 'cfr', '-r', info['fps'],
                '-vf', f'scale=in_color_matrix={mat}:in_range={rng}:flags=accurate_rnd+full_chroma_int,format=rgb48le',
                '-f', 'rawvideo', '-pix_fmt', 'rgb48le', '-']
        self.p = subprocess.Popen(cmd, stdout=subprocess.PIPE, bufsize=self.n * 2)
        self.q = queue.Queue(maxsize=8)
        self.shape = (info['h'], info['w'], 3)
        threading.Thread(target=self._loop, daemon=True).start()

    def _loop(self):
        while True:
            b = self.p.stdout.read(self.n)
            if len(b) < self.n:
                break
            self.q.put(np.frombuffer(b, np.uint16).reshape(self.shape))
        self.q.put(None)

    def __iter__(self):
        while True:
            f = self.q.get()
            if f is None:
                break
            yield f
        self.p.wait()


class Writer:
    def __init__(self, src, out, info, w, h, seconds):
        enc, pix, args = pick_encoder()
        mat = MATRIX.get(info['space'], 'bt709')
        br = max(info['br'], 8_000_000) * (w * h) / max(1, info['w'] * info['h']) * 1.15
        br = int(min(max(br, 8e6), 150e6))
        rate = ['-crf', '18'] if enc != 'hevc_nvenc' else ['-rc', 'vbr', '-cq', '19', '-b:v', str(br),
                                                            '-maxrate', str(int(br * 1.5)), '-bufsize', str(br * 2)]
        cmd = [FFMPEG, '-v', 'error', '-y', '-f', 'rawvideo', '-pix_fmt', 'rgb48le', '-s', f'{w}x{h}',
               '-framerate', info['fps'], '-i', '-', '-i', src,
               '-map', '0:v:0', '-map', '1:a:0?', '-c:a', 'copy', '-map_metadata', '1']
        if seconds:
            cmd += ['-t', str(seconds)]
        # tag warna = sumber. Lewat setparams (properti frame) + opsi encoder: ffmpeg baru mengabaikan -color_* saja.
        tags = [(flag, info[key]) for flag, key in (('color_primaries', 'prim'), ('color_trc', 'trc'), ('colorspace', 'space'))
                if info[key] and info[key] != 'unknown']
        sp = ':'.join(f'{k}={v}' for k, v in tags)
        cmd += ['-vf', f'scale=out_color_matrix={mat}:out_range=tv:flags=accurate_rnd+full_chroma_int,format={pix},'
                       f'setparams=range=tv' + (':' + sp if sp else ''),
                '-c:v', enc, *args, *rate]
        if enc == 'libx265':
            cmd += ['-x265-params', 'log-level=error']
        if enc != 'libx264':
            cmd += ['-tag:v', 'hvc1']
        for k, v in tags:
            cmd += ['-' + k, v]
        cmd += ['-color_range', 'tv', '-movflags', '+faststart+use_metadata_tags', out]
        self.p = subprocess.Popen(cmd, stdin=subprocess.PIPE)
        self.q = queue.Queue(maxsize=6)
        self.err = None
        self.t = threading.Thread(target=self._loop, daemon=True)
        self.t.start()

    def _loop(self):
        try:
            while True:
                b = self.q.get()
                if b is None:
                    break
                self.p.stdin.write(b)
        except Exception as e:   # noqa: BLE001
            self.err = e
        finally:
            with contextlib.suppress(Exception):
                self.p.stdin.close()

    def put(self, frame_u16):
        self.q.put(frame_u16.tobytes())

    def close(self):
        self.q.put(None)
        self.t.join()
        rc = self.p.wait()
        if rc != 0 or self.err:
            raise RuntimeError(f'ffmpeg encode gagal (kode {rc}) {self.err or ""}')


# ---------------------------------------------------------------- proses

class Job:
    def __init__(self, key, dev, mode, strength, input_max, chunk=None, overlap=4, deflicker=True):
        self.key, self.dev, self.mode, self.strength = key, dev, mode, strength
        self.input_max, self.chunk, self.overlap, self.deflicker = input_max, chunk, overlap, deflicker
        self.net = load_model(key, dev)
        self.amp = torch.autocast('cuda', dtype=torch.float16) if dev.type == 'cuda' else contextlib.nullcontext()

    def sizes(self, info):
        w, h = info['w'], info['h']
        long = max(w, h)
        s = max(1.0, min(2.0, 3840 / long)) if self.mode == 'perbesar' else 1.0
        k = min(1.0, self.input_max / long)
        return (even(w * s), even(h * s)), (max(64, int(round(w * k))), max(64, int(round(h * k))))

    def to_gpu(self, f):
        return torch.from_numpy(f.astype(np.float32) / 65535.0).to(self.dev).permute(2, 0, 1).unsqueeze(0)

    @staticmethod
    def resize(x, w, h):
        if x.shape[-1] == w and x.shape[-2] == h:
            return x
        return F.interpolate(x, size=(h, w), mode='bicubic', align_corners=False, antialias=True)

    def finish(self, orig, hr):
        tw, th = self.tsize
        ref = self.resize(orig, tw, th)
        out = ref + self.strength * (self.resize(hr.float(), tw, th) - ref)
        return out, ref

    @staticmethod
    def to_u16(x):
        return (x.clamp(0, 1)[0].permute(1, 2, 0) * 65535.0 + 0.5).to(torch.int32).cpu().numpy().astype(np.uint16)

    # --- RealBasicVSR: potongan L frame, tumpang tindih O frame, dicampur linear di daerah tumpang tindih
    def run_vsr(self, frames, put, tick):
        net, (iw, ih) = self.net, self.isize
        net.n_clean = None
        if self.chunk:
            L = self.chunk
        elif self.dev.type == 'cuda':
            budget = torch.cuda.get_device_properties(self.dev).total_memory * 0.40
            L = int(min(40, max(10, budget / (64 * iw * ih * 2))))
        else:
            L = 12
        O = min(self.overlap, max(0, (L - 2) // 2))
        print(f'  potongan {L} frame, tumpang tindih {O}', flush=True)
        it = iter(frames)
        buf, pending, eof, idx = [], {}, False, 0
        while True:
            while len(buf) < L and not eof:
                f = next(it, None)
                if f is None:
                    eof = True
                else:
                    buf.append((idx, f))
                    idx += 1
            if not buf:
                break
            if eof and all(i in pending for i, _ in buf):
                for i, _ in buf:
                    put(self.to_u16(pending.pop(i)[0]))
                    tick()
                break
            last = eof and len(buf) <= L
            n = len(buf)
            keep = n if last else n - O
            with torch.inference_mode(), self.amp:
                lrs = torch.cat([self.resize(self.to_gpu(f), iw, ih) for _, f in buf])
                lrs = net.clean(lrs)

                def emit(i, hr, chunk=buf, keep=keep):
                    gi, f = chunk[i]
                    out, _ = self.finish(self.to_gpu(f), hr)
                    if gi in pending:
                        old, j = pending.pop(gi)
                        wn = (j + 1) / (O + 1)
                        out = old * (1 - wn) + out * wn
                    if i < keep:
                        put(self.to_u16(out))
                        tick()
                    else:
                        pending[gi] = (out, i - keep)
                net.basicvsr.run(lrs, emit)
            buf = [] if last else buf[n - O:]
            if last:
                break

    # --- Real-ESRGAN per frame + kurangi kedip (detail AI dirata-rata dengan frame sebelumnya di area diam)
    def run_frames(self, frames, put, tick):
        iw, ih = self.isize
        prev_ref = prev_d = None
        for f in frames:
            with torch.inference_mode(), self.amp:
                orig = self.to_gpu(f)
                hr = tiled(self.net, self.resize(orig, iw, ih))
                out, ref = self.finish(orig, hr)
                if self.deflicker:
                    d = out - ref
                    if prev_ref is not None:
                        diff = F.avg_pool2d((ref - prev_ref).abs().mean(1, keepdim=True), 9, 1, 4)
                        still = (1 - diff / 0.02).clamp(0, 1) * 0.6
                        d = d * (1 - still) + prev_d * still
                        out = ref + d
                    prev_ref, prev_d = ref, d
            put(self.to_u16(out))
            tick()

    def process(self, src, out, seconds=0):
        info = probe(src)
        self.tsize, self.isize = self.sizes(info)
        dur = min(info['dur'], seconds) if seconds else info['dur']
        total = max(1, int(round(dur * info['fpsf'])))
        warn = ''
        if info['prim'] == 'bt2020' and not info['hdr']:
            warn = ' (bt2020 tanpa HLG/PQ: mungkin Apple Log - bakar LUT dulu supaya AI melihat warna normal)'
        print(f"  {info['w']}x{info['h']} {info['fpsf']:.2f} fps {dur:.1f} s ({total} frame), "
              f"{'HDR ' + info['trc'] if info['hdr'] else 'SDR'}{warn}", flush=True)
        print(f'  input model {self.isize[0]}x{self.isize[1]} -> hasil {self.tsize[0]}x{self.tsize[1]}, '
              f'encoder {pick_encoder()[0]}', flush=True)
        rd = Reader(src, info, seconds)
        wr = Writer(src, out, info, *self.tsize, seconds)
        t0, done, last = time.time(), [0], [0.0]

        def tick():
            done[0] += 1
            now = time.time()
            if now - last[0] > 10 or done[0] == total:
                last[0] = now
                el = now - t0
                spf = el / done[0]
                eta = max(0, total - done[0]) * spf
                print(f'  {done[0]}/{total} frame  {spf:.2f} s/frame  sisa ~{eta / 60:.1f} menit', flush=True)
        try:
            (self.run_vsr if self.key == 'vsr' else self.run_frames)(rd, wr.put, tick)
        finally:
            wr.close()
        return dict(frames=done[0], seconds=time.time() - t0, w=self.tsize[0], h=self.tsize[1])


def run(inbox, outbox, model='vsr', mode='pertajam', strength=0.8, input_max=1920, test_seconds=0,
        move_done=True, workdir='/content/kerja', chunk=None, log_name='_catatan.txt'):
    dev = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
    if dev.type == 'cuda':
        torch.backends.cudnn.benchmark = True
        print('GPU:', torch.cuda.get_device_name(dev), flush=True)
    else:
        print('PERINGATAN: tidak ada GPU - sangat lambat. Colab: Runtime > Change runtime type > T4 GPU', flush=True)
    os.makedirs(outbox, exist_ok=True)
    os.makedirs(workdir, exist_ok=True)
    vids = sorted(p for p in glob.glob(os.path.join(inbox, '*')) if p.lower().endswith(VIDEO_EXT))
    if not vids:
        print(f'Tidak ada video di {inbox}. Taruh file .MOV / .MP4 di folder itu lalu jalankan lagi.')
        return []
    job = Job(model, dev, mode, strength, input_max, chunk=chunk)
    tag = MODELS[model]['tag'] + ('2x' if mode == 'perbesar' else '') + (f'_uji{test_seconds:g}s' if test_seconds else '')
    results = []
    for i, src in enumerate(vids, 1):
        stem = os.path.splitext(os.path.basename(src))[0]
        final = os.path.join(outbox, f'{stem}_{tag}.mov')
        if os.path.exists(final):
            print(f'[{i}/{len(vids)}] {stem}: sudah ada hasilnya, dilewati')
            continue
        print(f'[{i}/{len(vids)}] {stem} - {MODELS[model]["name"]}, {mode}, kekuatan {strength:g}', flush=True)
        local = os.path.join(workdir, os.path.basename(src))
        tmp = os.path.join(workdir, f'{stem}_{tag}.mov')
        try:
            shutil.copy2(src, local)
            r = job.process(local, tmp, test_seconds)
            shutil.copy2(tmp, final + '.part')
            os.replace(final + '.part', final)
            mb = os.path.getsize(final) / 1e6
            msg = (f"{time.strftime('%Y-%m-%d %H:%M')} {stem} -> {os.path.basename(final)} {r['w']}x{r['h']} "
                   f"{r['frames']} frame {r['seconds'] / 60:.1f} menit ({r['seconds'] / max(1, r['frames']):.2f} s/frame) {mb:.0f} MB")
            print('  SELESAI:', msg, flush=True)
            results.append(final)
            if move_done and not test_seconds:
                done_dir = os.path.join(inbox, '_sudah')
                os.makedirs(done_dir, exist_ok=True)
                shutil.move(src, os.path.join(done_dir, os.path.basename(src)))
        except Exception as e:   # noqa: BLE001
            msg = f"{time.strftime('%Y-%m-%d %H:%M')} {stem} GAGAL: {e}"
            print('  ' + msg, flush=True)
        finally:
            for p in (local, tmp):
                with contextlib.suppress(OSError):
                    os.remove(p)
            if dev.type == 'cuda':
                torch.cuda.empty_cache()
        with open(os.path.join(outbox, log_name), 'a', encoding='utf-8') as f:
            f.write(msg + '\n')
    return results


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('inbox')
    ap.add_argument('outbox')
    ap.add_argument('--model', default='vsr', choices=list(MODELS))
    ap.add_argument('--mode', default='pertajam', choices=['pertajam', 'perbesar'])
    ap.add_argument('--strength', type=float, default=0.8)
    ap.add_argument('--input', type=int, default=1920, help='sisi panjang maksimum input model')
    ap.add_argument('--test-seconds', type=float, default=0)
    ap.add_argument('--chunk', type=int, default=None)
    ap.add_argument('--workdir', default=None)
    ap.add_argument('--weights', default=None)
    ap.add_argument('--ffmpeg', default=None)
    a = ap.parse_args()
    if a.weights:
        WEIGHTS_DIR = a.weights
    if a.ffmpeg:
        FFMPEG = a.ffmpeg
    run(a.inbox, a.outbox, a.model, a.mode, a.strength, a.input, a.test_seconds, move_done=False,
        workdir=a.workdir or os.path.join(a.outbox, '_kerja'), chunk=a.chunk)
