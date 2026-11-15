"""Bandingkan hasil Colab (handheld super-res 2x) dengan panel bedah burst sebelumnya."""
import sys, os
import numpy as np, cv2
from PIL import Image

colab, out = sys.argv[1], sys.argv[2]
dirs = sys.argv[3:]
MARGIN = 1.25
c = np.asarray(Image.open(colab).convert('RGB'))
h, w = c.shape[:2]
ch, cw = int(h / MARGIN), int(w / MARGIN)                     # buang margin -> bidang 75x
c = c[(h - ch) // 2:(h - ch) // 2 + ch, (w - cw) // 2:(w - cw) // 2 + cw]
print('colab bidang 75x', c.shape)


def gray(im, size):
    g = cv2.cvtColor(cv2.resize(im, size, interpolation=cv2.INTER_AREA), cv2.COLOR_RGB2GRAY).astype(np.float32)
    return (g - g.mean()) / (g.std() + 1e-6)


best = None
for d in dirs:
    ref = np.asarray(Image.open(os.path.join(d, '1_frame_RAW.jpg')).convert('RGB'))
    for name, rot in (('ccw', cv2.ROTATE_90_COUNTERCLOCKWISE), ('cw', cv2.ROTATE_90_CLOCKWISE)):
        r = cv2.rotate(c, rot)
        size = (320, 240)
        corr = float((gray(r, size) * gray(ref, size)).mean())
        print(os.path.basename(os.path.dirname(d)), name, 'korelasi %.3f' % corr)
        if best is None or corr > best[0]:
            best = (corr, d, rot, ref.shape)
corr, d, rot, shape = best
print('cocok:', d, 'korelasi %.3f' % corr)
H, W = shape[:2]
r = cv2.rotate(c, rot)
big = cv2.resize(r, (W, H), interpolation=cv2.INTER_LANCZOS4)


def label(img, text):
    img = np.ascontiguousarray(img)
    for col, th in (((0, 0, 0), 5), ((255, 255, 0), 2)):
        cv2.putText(img, text, (12, 34), cv2.FONT_HERSHEY_SIMPLEX, 0.9, col, th)
    return img


def load(n):
    return np.asarray(Image.open(os.path.join(d, n)).convert('RGB'))[:H, :W]


panels = [load('1_frame_RAW.jpg'), label(big, 'Colab: super-res Google 20 frame'), load('Apple_zoom_plus_AI.jpg')]
grid = np.hstack(panels)
Image.fromarray(grid).save(out, quality=90)
print('grid', grid.shape)
# potongan detail (tengah) pada skala penuh
y0, y1, x0, x1 = int(H * 0.30), int(H * 0.80), int(W * 0.28), int(W * 0.72)
det = np.hstack([label(p[y0:y1, x0:x1], t) for p, t in zip(panels, ('1 frame RAW', 'Colab: super-res Google 20 frame', 'Apple zoom + AI'))])
Image.fromarray(det).save(out.replace('.jpg', '_detail.jpg'), quality=92)
print('detail', det.shape)
