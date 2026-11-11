# LOG aktivitas - mod-Kamera (iOS camera app)

Format: tanggal - apa yang dikerjakan - hasil / file.

---

## 2026-11-11 - Sesi 1: riset + setup PC lab (Langkah 1)

### Keputusan arsitektur (dari diskusi)
- iPhone **tidak bisa dimod seperti GCam**: kamera bawaan tertutup & di-sign Apple, belum ada jailbreak publik
  untuk iPhone 16 PM (A18). Jalannya: **bikin app kamera sendiri** (Swift + AVFoundation + Metal + Core ML).
- **Blackmagic Camera tidak bisa jadi base**: closed source + terenkripsi FairPlay. (Bisa dipakai apa adanya
  untuk preview LUT .cube di video.)
- **Emulator tidak dipakai**: iOS Simulator hanya ada di macOS & **tidak punya kamera**. macOS di VM melanggar
  lisensi Apple + rapuh (CPU AMD). -> Build via **GitHub Actions (runner macOS)**, install via **Sideloadly**,
  tes langsung di iPhone.
- Base open source yang dipilih:
  - `hdr-plus-pytorch` (MIT) - eksperimen/tuning di PC.
  - `hdr-plus-swift` / Burst Photo (GPL-3.0) - kode Metal align+merge untuk di-port ke iOS.
  - Sampel Apple AVCam / AVCamFilter / AVCamManual - kerangka app, preview LUT, kontrol manual.
- Rencana tahap: (1) PC lab -> (2) kerangka app + LUT live -> (3) port align/merge Metal -> (4) AI zoom / super-res.

### Cek repo hdr-plus-swift (GitHub API)
- `martin-marek/hdr-plus-swift`, 245 bintang, GPL-3.0, rilis terakhir **v1.7 (2024-09-02)**, tidak di-archive
  tapi sudah tidak aktif. Fork aktif tidak signifikan.
- App **macOS** (bukan iOS), proses DNG post-capture, pakai Adobe DNG SDK (C++).
- Modul yang berguna: `burstphoto/align`, `merge`, `exposure`, `denoise.swift`, `texture` (file .metal + .swift).
- **Super-resolution belum ada** (masih "List of Ideas") -> harus dibangun sendiri.

### Spesifikasi PC
- CPU AMD Ryzen AI 7 350, iGPU Radeon 860M (tanpa NVIDIA / CUDA), RAM 15 GB.
- Python 3.13.14, git 2.54, torch 2.13.0+cpu, numpy 2.4.4.
- Konsekuensi: training model AI berat tidak realistis di PC ini -> pakai model pretrained / Colab nanti.

### Setup
- Folder dibuat: `third_party/`, `pc-lab/`, `data/bursts/`, `data/output/`, `docs/`.
- Clone (depth 1): `third_party/hdr-plus-pytorch` (commit e7091c3, 2024-09-08), `third_party/hdr-plus-swift`.
- venv: `pc-lab/.venv` (`--system-site-packages`, pakai torch global) + `rawpy 0.28.0`, `imageio`, `matplotlib`, `tifffile`.
  `functorch.dim` jalan di torch 2.13.
- Sampel burst resmi (r2.dev, Sony RX100) **gagal diunduh**: sertifikat SSL hostname mismatch -> kemungkinan
  diblokir/di-intercept ISP. Verifikasi SSL sengaja **tidak** dimatikan.

### File dibuat
- `pc-lab/burst_merge.py` - align+merge burst DNG. Otomatis deteksi **Bayer** (merge di domain Bayer) atau
  **ProRAW/Linear DNG** (merge di RGB linear). Output: `<nama>_merged_16bit.tiff`, `_ref.jpg`, `_merged.jpg`,
  `_compare_crop.jpg` di `data/output/`.
- `pc-lab/test_synthetic.py` - uji sintetis: scene -> mosaik RGGB -> 8 frame tergeser + noise shot/read.

### Hasil uji
| Uji | Resolusi | Frame | Waktu (CPU) | PSNR frame tunggal | PSNR merge | PSNR rata-rata tanpa align |
|---|---|---|---|---|---|---|
| Sintetis | 2000x1500 | 8 | 2.4 s | 20.58 dB | **28.14 dB** | 19.73 dB |
| Sintetis | 4032x3024 (12MP) | 8 | 13.8 s | 20.59 dB | **27.96 dB** | 20.34 dB |

- Merge memberi **+7.5 dB** (batas teoretis 8 frame = +9.0 dB). Tanpa align malah lebih buruk (blur) ->
  align bekerja. Gambar: `data/output/synthetic_compare.jpg`
  (urutan: frame tunggal | rata-rata tanpa align | merge HDR+ | ground truth).
- Tes jalur Bayer dengan DNG asli (salinan 3 file `D:\Backup\gcam-taoyao\foto-uji\dng-macro`, Xiaomi, 1600x1200):
  jalan end-to-end 0.5 s. **Catatan:** 3 file itu bukan burst sungguhan (exposure/warna beda, dinding polos) ->
  hanya membuktikan kode jalan, bukan kualitas.
- Jalur **ProRAW/Linear DNG belum teruji** - menunggu file dari iPhone.

### Berikutnya (sesi 1)
- [x] User ambil burst DNG dari iPhone 16 PM -> lihat sesi 2.
- [x] Akun: **Apple ID gratis** (Sideloadly, re-sign tiap 7 hari, maks 3 app sideload).

---

## 2026-11-12 - Sesi 2: burst ProRAW asli dari iPhone

### Transfer
- iPhone terhubung USB (muncul sebagai "Apple iPhone" / MTP). Perlu iPhone di-unlock + "Trust/Allow" dulu.
- Disalin via Shell.Application dari `Internal Storage\202611__` (file di iPhone **tidak diubah/dihapus**):
  - `data/bursts/iphone-20261111-setA/` IMG_6585-6595 - **11 frame**, 2026-11-11 16:59, ISO 1600, 1/26 s, lensa utama 24mm f/1.78, ruangan gelap, pakai tripod.
  - `data/bursts/iphone-20261111-setB/` IMG_6596-6600 - **5 frame**, 17:00, ISO 1250, 1/25 s, ruangan lebih terang.

### Temuan format
- File = **Apple ProRAW**, iOS 18.7.8, DNG 1.7: `LinearRaw` (sudah demosaic), **10-bit + LinearizationTable**,
  **kompresi JPEG XL (52546)**, tile 1008x1008, ~6.5 MB/frame. `AsShotNeutral`=1,1,1 (WB sudah diterapkan Apple),
  `BaselineExposure` +2.0 EV, `Orientation`=6, ada `ProfileGainTableMap` (tone map lokal Apple).
- **LibRaw/rawpy 0.28 tidak bisa baca** (Unsupported file format) -> tambah `imagecodecs 2026.10.10`
  (JPEG XL decode via tifffile, 0.1 s/frame).

### Perubahan kode
- `pc-lab/burst_merge.py`: jenis baru **`proraw`** - `load_proraw()` (decode JXL, LinearizationTable,
  black/white level) + `render_proraw()` (inverse ColorMatrix2 -> XYZ -> sRGB, BaselineExposure, soft shoulder,
  gamma sRGB, rotasi sesuai Orientation).
- `pc-lab/compare.py` (baru): 3 crop ref vs merge, zoom 2x + boost EV, estimasi noise sigma (Immerkaer).
- `pc-lab/requirements.txt`: + imagecodecs.

### Hasil
| Set | Frame | Load | Align+merge (CPU) | Noise turun (tengah / bawah / atas) | Teori |
|---|---|---|---|---|---|
| A (gelap) | 11 | 5.8 s | 18.7 s | **58.5% / 65.7% / 67.4%** | 69.8% |
| B (terang) | 5 | 2.2 s | 6.8 s | 38.7% / 45.9% / 28.4% | 55.3% |

- **Set A: berhasil** - noise di bayangan turun mendekati teori, detail ukiran/teks tetap tajam, tanpa ghosting.
  File: `data/output/iphone-20261111-setA_compare_ev+2.jpg`, `_merged.jpg`, `_merged_16bit.tiff`.
- **Set B: ada masalah**
  1. **Artefak kotak-kotak** di tepi gorden dekat jendela yang clip (`setB_compare_ev+2.jpg` baris 3) ->
     keterbatasan merge sederhana hdr-plus-pytorch (rata-rata biasa, alignment per tile integer, tanpa robust merge).
  2. Render terlalu terang / highlight putih -> renderer kita hanya global (BaselineExposure + kurva sederhana),
     belum pakai `ProfileGainTableMap`. Masalah tampilan, bukan merge.
  3. Ada jari di pojok kanan bawah frame.
- Catatan penting: **ProRAW sudah diproses multi-frame oleh Apple** sebelum disimpan. Merge kita = stacking di atas
  hasil Apple. Untuk pipeline "GCam murni" nanti app kita perlu ambil **Bayer RAW** (tersedia di AVFoundation).

### Berikutnya
- [ ] Robust merge (bobot per tile berdasarkan selisih, ala HDR+ / hdr-plus-swift `merge/`) -> hilangkan artefak set B.
- [ ] Renderer lebih baik: tone map lokal / terapkan ProfileGainTableMap, auto-exposure dari histogram.
- [ ] Simpan hasil merge sebagai **DNG** (bisa diedit di Lightroom) - bukan cuma TIFF.
- [ ] Langkah 2: kerangka app iOS (Apple ID gratis + Sideloadly) + workflow GitHub Actions -> butuh akun GitHub.
