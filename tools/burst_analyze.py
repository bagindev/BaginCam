"""Bedah burst zoom 75x: frame tunggal vs gabungan sederhana vs hasil app vs Apple."""
import sys, glob, os
import numpy as np, cv2, rawpy
import pillow_heif
from PIL import Image

pillow_heif.register_heif_opener()
frames_dir, app_heic, apple_heic, out_dir, crop = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], float(sys.argv[5])
os.makedirs(out_dir, exist_ok=True)
files = sorted(glob.glob(os.path.join(frames_dir, '*.dng')))
print(len(files), 'frames')

MARGIN = 1.25   # ambil sedikit lebih lebar dari bidang 75x


def develop(path):
    with rawpy.imread(path) as raw:
        if path == files[0]:
            print('raw', raw.raw_image_visible.shape, 'black', raw.black_level_per_channel, 'white', raw.white_level,
                  'flip', raw.sizes.flip)
        rgb = raw.postprocess(use_camera_wb=True, no_auto_bright=True, output_bps=16, gamma=(2.222, 4.5),
                              demosaic_algorithm=rawpy.DemosaicAlgorithm.AHD, user_flip=0)
    return rgb.astype(np.float32) / 65535.0


def center(img, frac):
    h, w = img.shape[:2]
    ch, cw = int(h * frac), int(w * frac)
    y, x = (h - ch) // 2, (w - cw) // 2
    return img[y:y + ch, x:x + cw]


crops = []
for f in files:
    crops.append(center(develop(f), MARGIN / crop))
ref = crops[0]
print('crop px', ref.shape)

UP = 8
H, W = ref.shape[:2]
gray0 = cv2.cvtColor(ref, cv2.COLOR_RGB2GRAY)
win = cv2.createHanningWindow((W, H), cv2.CV_32F)
acc = np.zeros((H * UP, W * UP, 3), np.float32)
shifts = []
for c in crops:
    g = cv2.cvtColor(c, cv2.COLOR_RGB2GRAY)
    (dx, dy), resp = cv2.phaseCorrelate(gray0, g, win)
    shifts.append((dx, dy, resp))
    # c(x) = ref(x - d)  ->  ambil c di (x + d)
    M = np.float32([[1.0 / UP, 0, dx], [0, 1.0 / UP, dy]])
    acc += cv2.warpAffine(c, M, (W * UP, H * UP), flags=cv2.INTER_LANCZOS4 | cv2.WARP_INVERSE_MAP,
                          borderMode=cv2.BORDER_REPLICATE)
print('geseran (px) :', ' '.join('%.2f,%.2f' % (s[0], s[1]) for s in shifts))
print('respons      :', ' '.join('%.2f' % s[2] for s in shifts))
avg = acc / len(crops)
single = cv2.resize(ref, (W * UP, H * UP), interpolation=cv2.INTER_LANCZOS4)


def sharpen(img, amount=1.2, sigma=UP * 0.6):
    b = cv2.GaussianBlur(img, (0, 0), sigma)
    return np.clip(img + amount * (img - b), 0, 1)


def load(path):
    return np.asarray(Image.open(path).convert('RGB')).astype(np.float32) / 255.0


def to_landscape(img):
    return img if img.shape[1] >= img.shape[0] else cv2.rotate(img, cv2.ROTATE_90_COUNTERCLOCKWISE)


def fit(img):
    img = to_landscape(img)
    img = center(img, 1.0)   # hasil app/Apple = persis bidang 75x; frame kita dipotong MARGIN -> samakan
    return cv2.resize(img, (int(W * UP / MARGIN), int(H * UP / MARGIN)), interpolation=cv2.INTER_AREA)


def field(img):               # buang margin supaya bidangnya sama dengan hasil app / Apple
    return center(img, 1.0 / MARGIN)


panels = [('1 frame RAW', field(single)), ('1 frame RAW + tajamkan', field(sharpen(single))),
          ('20 frame geser+rata', field(avg)), ('20 frame + tajamkan', field(sharpen(avg, 1.6))),
          ('hasil app (HDR+ drizzle AI)', fit(load(app_heic))), ('Apple zoom + AI', fit(load(apple_heic)))]
h0 = min(p[1].shape[0] for p in panels)
w0 = min(p[1].shape[1] for p in panels)
tiles = []
for name, im in panels:
    im = np.ascontiguousarray((np.clip(im[:h0, :w0], 0, 1) * 255).astype(np.uint8))
    cv2.putText(im, name, (12, 34), cv2.FONT_HERSHEY_SIMPLEX, 0.9, (0, 0, 0), 5)
    cv2.putText(im, name, (12, 34), cv2.FONT_HERSHEY_SIMPLEX, 0.9, (255, 255, 0), 2)
    tiles.append(im)
    Image.fromarray(im).save(os.path.join(out_dir, name.split('(')[0].strip().replace(' ', '_').replace('+', 'plus') + '.jpg'), quality=92)
grid = np.vstack([np.hstack(tiles[0:3]), np.hstack(tiles[3:6])])
Image.fromarray(grid).save(os.path.join(out_dir, 'banding.jpg'), quality=88)
print('grid', grid.shape)


# ketajaman: energi gradien / kontras (di area tengah)
def score(im):
    g = cv2.cvtColor(im, cv2.COLOR_RGB2GRAY).astype(np.float32)
    g = cv2.GaussianBlur(g, (0, 0), 1.0)
    lap = cv2.Laplacian(g, cv2.CV_32F, ksize=3)
    return float(lap.var() / (g.std() ** 2 + 1e-6))


for (name, _), t in zip(panels, tiles):
    print('%-30s ketajaman %.4f' % (name, score(t)))
