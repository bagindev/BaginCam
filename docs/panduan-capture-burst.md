# Panduan ambil burst RAW di iPhone 16 Pro Max (untuk PC lab)

Tujuan: 6-10 frame RAW dari scene yang **sama**, exposure **sama**, supaya bisa di-merge.

## Setting
1. **Settings > Camera > Formats > Apple ProRAW** = ON, resolusi ProRAW **12 MP** (lebih ringan dari 48 MP).
2. Di app Kamera, nyalakan **RAW**.
3. **Tekan lama** subjek sampai muncul **AE/AF LOCK** -> exposure & fokus terkunci untuk semua frame.
4. Matikan Night mode & Live Photo (supaya tiap frame tidak diproses beda).

## Ambil
- Pegang biasa (goyangan tangan kecil itu bagus - nanti berguna untuk super-res), tekan shutter 8x secepatnya.
- Scene yang bagus untuk uji: **ruangan agak gelap** dengan tekstur (buku, kain, rak). Noise jelas, efek merge kelihatan.
- Ambil 2-3 set: gelap, sedang, dan satu dengan sedikit gerakan (orang/daun) untuk uji ketahanan gerak.

## (Opsional) Bayer RAW asli
ProRAW sudah di-demosaic + diproses Apple (multi-frame juga). Untuk pipeline ala GCam yang paling murni
perlu **Bayer RAW** - butuh app pihak ketiga yang menyimpan RAW Bayer (mis. Halide mode RAW non-ProRAW,
atau app kita sendiri nanti). Kalau ada, ambil set yang sama juga.

## Tips dari sesi 2 (2026-11-12)
- 8-11 frame paling efektif; 5 frame hanya turun noise ~40%.
- Hindari jendela/lampu yang clip di frame -> memicu artefak di merge sederhana.
- Jaga jari jauh dari pinggir lensa.
- ProRAW iOS 18 = DNG terkompresi JPEG XL (~6.5 MB). Sudah didukung `burst_merge.py` (perlu `imagecodecs`).

## Pindah ke PC
- Kabel USB -> Windows "Import from device" / File Explorer `Apple iPhone\Internal Storage\DCIM`.
- File ProRAW berekstensi `.DNG` (~25 MB per 12MP).
- Taruh per set di `D:\project\ios\BaginCam\data\bursts\<nama-set>\`.

## Proses
```
D:\project\ios\BaginCam\pc-lab\.venv\Scripts\python.exe D:\project\ios\BaginCam\pc-lab\burst_merge.py D:\project\ios\BaginCam\data\bursts\<nama-set> --ev 1
```
Hasil di `data\output\`.
