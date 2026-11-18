"""Bangun BaginCam_AI_video.ipynb dari bagincam_ai_video.py (kode yang sudah diuji lokal disalin utuh).
  python make_notebook.py
"""
import json
import os

here = os.path.dirname(os.path.abspath(__file__))
code = open(os.path.join(here, 'bagincam_ai_video.py'), encoding='utf-8').read().replace('\r\n', '\n')
assert "'''" not in code, 'kode tidak boleh berisi tiga petik tunggal'


def md(s):
    return {'cell_type': 'markdown', 'metadata': {}, 'source': s.strip('\n').splitlines(True)}


def py(s):
    return {'cell_type': 'code', 'execution_count': None, 'metadata': {}, 'outputs': [],
            'source': s.strip('\n').splitlines(True)}


intro = md("""
# BaginCam - AI pertajam video (Google Colab)

Video diproses di GPU Google, HP tetap dingin.

**Cara pakai**
1. Taruh video (.MOV / .MP4) di Google Drive folder **`BaginCam/masuk`** (dari iPhone: app Files > Simpan ke Drive, atau app Google Drive > Upload). Folder dibuat otomatis saat notebook pertama kali dijalankan.
2. Pastikan GPU aktif: menu **Runtime > Change runtime type > T4 GPU**.
3. Atur pilihan di langkah 1, lalu **Runtime > Run all**. Izinkan akses Google Drive saat diminta.
4. Hasil muncul di **`BaginCam/selesai`** (nama `..._AIV.mov`), siap diunduh / disimpan ke Foto. Video asli dipindah ke `masuk/_sudah`.

Biarkan tab ini terbuka selama proses (Colab gratis berhenti bila ditinggal lama). Audio, tanggal, dan lokasi video disalin dari file asli; warna SDR / HDR (HLG) dipertahankan.

**Model**
- **vsr** - RealBasicVSR: model khusus video, membaca banyak frame sekaligus sehingga detail stabil dan tidak berkedip. Paling bagus, paling lambat.
- **cepat / detail** - Real-ESRGAN yang sama dengan AI di app BaginCam (per frame + kurangi kedip), untuk pembanding.

Mulai dengan **UJI_DETIK = 5** untuk melihat hasil dan kecepatan, lalu set 0 untuk seluruh video.
""")

settings = py("""
#@title 1. Pengaturan { display-mode: "form" }
MODEL = "vsr - RealBasicVSR (video, stabil)" #@param ["vsr - RealBasicVSR (video, stabil)", "cepat - Real-ESRGAN Cepat (seperti di HP)", "detail - Real-ESRGAN Detail (seperti di HP)"]
MODE = "pertajam - resolusi sama" #@param ["pertajam - resolusi sama", "perbesar - 2x (maks 4K)"]
KEKUATAN = 0.8 #@param {type:"slider", min:0.3, max:1.0, step:0.05}
#@markdown KEKUATAN: campuran hasil AI dengan video asli (1 = AI penuh).
INPUT_MAKS = "1920 - paling detail" #@param ["1920 - paling detail", "1280 - lebih cepat", "960 - paling cepat"]
#@markdown INPUT_MAKS: sisi panjang gambar yang dibaca AI. Video 4K diperkecil dulu ke ukuran ini.
UJI_DETIK = 5 #@param {type:"number"}
#@markdown UJI_DETIK: proses hanya N detik pertama untuk mencoba. **0 = seluruh video.**
PINDAH_SELESAI = True #@param {type:"boolean"}
#@markdown PINDAH_SELESAI: video asli dipindah ke `masuk/_sudah` setelah berhasil (bukan saat uji).
FOLDER = "BaginCam" #@param {type:"string"}
""")

writer = py("#@title 2. Kode pemroses (tidak perlu diubah) { display-mode: \"form\" }\n"
            "CODE = r'''" + code + "'''\n"
            "open('/content/bagincam_ai_video.py', 'w', encoding='utf-8').write(CODE)\n"
            "print('kode pemroses siap')\n")

runner = py("""
#@title 3. Jalankan { display-mode: "form" }
import importlib, os, subprocess, sys
from google.colab import drive

gpu = subprocess.run(['nvidia-smi', '--query-gpu=name,memory.total', '--format=csv,noheader'],
                     capture_output=True, text=True).stdout.strip()
print('GPU:', gpu or 'TIDAK ADA - pilih Runtime > Change runtime type > T4 GPU')
drive.mount('/content/drive', force_remount=True)     # baca isi Drive terbaru (file yang baru di-upload)
import glob, time
VID = ('.mov', '.mp4', '.m4v')
my = '/content/drive/MyDrive'


def vids(d):
    return [p for p in glob.glob(f'{d}/*') if p.lower().endswith(VID)]


# cari folder masuk yang berisi video: Drive boleh punya beberapa folder bernama sama ("BaginCam" ganda)
for coba in range(3):
    roots = sorted(d for d in glob.glob(f'{my}/*') if os.path.isdir(d) and os.path.basename(d).lower().startswith(FOLDER.lower()))
    isi = [(r, len(vids(f'{r}/masuk'))) for r in roots]
    if any(n for _, n in isi):
        break
    time.sleep(10)        # sinkron Drive kadang terlambat beberapa detik setelah upload
print('Folder ditemukan:', ', '.join(f'{os.path.basename(r)} ({n} video di masuk)' for r, n in isi) or '-')
root = next((r for r, n in isi if n), roots[0] if roots else f'{my}/{FOLDER}')
masuk, selesai = f'{root}/masuk', f'{root}/selesai'
os.makedirs(masuk, exist_ok=True)
os.makedirs(selesai, exist_ok=True)
lain = sorted(os.listdir(masuk))
print(f'Isi {masuk}:', ', '.join(lain) or '(kosong)')
if not vids(masuk):
    print('\\nTIDAK ADA VIDEO. Kemungkinan ada dua folder "BaginCam" di My Drive: hapus yang kosong / pindahkan '
          'videonya ke folder yang dipakai di atas, lalu jalankan lagi sel ini.')

sys.path.insert(0, '/content')
import bagincam_ai_video as bav
importlib.reload(bav)
hasil = bav.run(masuk, selesai, model=MODEL.split(' ')[0], mode=MODE.split(' ')[0], strength=float(KEKUATAN),
                input_max=int(INPUT_MAKS.split(' ')[0]), test_seconds=float(UJI_DETIK or 0),
                move_done=bool(PINDAH_SELESAI))
drive.flush_and_unmount()      # pastikan hasil benar-benar tersimpan ke Drive sebelum tab ditutup
print(f'\\n{len(hasil)} video selesai -> Google Drive / {FOLDER} / selesai')
""")

nb = {
    'nbformat': 4, 'nbformat_minor': 0,
    'metadata': {'accelerator': 'GPU', 'colab': {'provenance': [], 'gpuType': 'T4'},
                 'kernelspec': {'name': 'python3', 'display_name': 'Python 3'}, 'language_info': {'name': 'python'}},
    'cells': [intro, settings, writer, runner],
}
out = os.path.join(here, 'BaginCam_AI_video.ipynb')
with open(out, 'w', encoding='utf-8', newline='\n') as f:
    json.dump(nb, f, ensure_ascii=False, indent=1)
print('ditulis', out)
