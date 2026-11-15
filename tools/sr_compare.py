"""Bandingkan model pembesar pada sumber zoom Apple (meniru jalur app: perkecil -> x4 -> campur 50 % Lanczos)."""
import sys, os, time
import numpy as np, cv2, torch
import pillow_heif
from PIL import Image
from spandrel import ModelLoader, ImageModelDescriptor

pillow_heif.register_heif_opener()
src_path, out_dir, real_long = sys.argv[1], sys.argv[2], int(sys.argv[3])
box = [float(v) for v in sys.argv[4].split(',')]          # x0,y0,x1,y1 (fraksi) area uji
models = sys.argv[5:]
os.makedirs(out_dir, exist_ok=True)
torch.set_num_threads(max(1, os.cpu_count() - 2))

im = np.asarray(Image.open(src_path).convert('RGB'))
h, w = im.shape[:2]
k = real_long / max(h, w)
small = cv2.resize(im, (round(w * k), round(h * k)), interpolation=cv2.INTER_AREA)   # "detail asli" seperti di app
sh, sw = small.shape[:2]
x0, y0, x1, y1 = int(box[0] * sw), int(box[1] * sh), int(box[2] * sw), int(box[3] * sh)
PAD = 12
px0, py0, px1, py1 = max(0, x0 - PAD), max(0, y0 - PAD), min(sw, x1 + PAD), min(sh, y1 + PAD)
patch = small[py0:py1, px0:px1]
print('sumber', im.shape, '-> kecil', small.shape, 'area uji', patch.shape)
S = 4
plain = cv2.resize(patch, (patch.shape[1] * S, patch.shape[0] * S), interpolation=cv2.INTER_LANCZOS4)


def cut(img):
    return img[(y0 - py0) * S:(y1 - py0) * S, (x0 - px0) * S:(x1 - px0) * S]


def label(img, text):
    img = np.ascontiguousarray(img)
    for col, th in (((0, 0, 0), 5), ((255, 255, 0), 2)):
        cv2.putText(img, text, (10, 34), cv2.FONT_HERSHEY_SIMPLEX, 0.95, col, th)
    return img


# Apple 12MP apa adanya (dipotong ke area yang sama, disamakan ukurannya)
fx, fy = w / sw, h / sh
orig = im[int(y0 * fy):int(y1 * fy), int(x0 * fx):int(x1 * fx)]
ref_size = (cut(plain).shape[1], cut(plain).shape[0])
panels = [label(cv2.resize(orig, ref_size, interpolation=cv2.INTER_LANCZOS4), 'Apple murni 12MP')]
t_in = torch.from_numpy(patch.astype(np.float32) / 255.0).permute(2, 0, 1).unsqueeze(0)
for path in models:
    name = os.path.splitext(os.path.basename(path))[0]
    try:
        m = ModelLoader().load_from_file(path)
        assert isinstance(m, ImageModelDescriptor)
        m.model.eval()
        npar = sum(p.numel() for p in m.model.parameters()) / 1e6
        t0 = time.time()
        with torch.no_grad():
            out = m(t_in)
        dt = time.time() - t0
        o = (out.squeeze(0).permute(1, 2, 0).clamp(0, 1).numpy() * 255).round().astype(np.uint8)
        mix = cv2.addWeighted(plain, 0.5, o, 0.5, 0)
        print('%-34s %-14s %5.1f M param  %6.1f s CPU  skala %d' % (name, m.architecture.name, npar, dt, m.scale))
        panels.append(label(cut(mix), name.replace('4x', '')[:26] + ' 50%'))
        Image.fromarray(cut(o)).save(os.path.join(out_dir, name + '_100.jpg'), quality=92)
        Image.fromarray(cut(mix)).save(os.path.join(out_dir, name + '_50.jpg'), quality=92)
    except Exception as e:
        print('GAGAL', name, repr(e)[:200])
cols = 4
while len(panels) % cols: panels.append(np.zeros_like(panels[0]))
rows = [np.hstack(panels[i:i + cols]) for i in range(0, len(panels), cols)]
grid = np.vstack(rows)
Image.fromarray(grid).save(os.path.join(out_dir, 'banding_model.jpg'), quality=88)
print('grid', grid.shape)
