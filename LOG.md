# LOG aktivitas - BaginCam (iOS camera app)

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

### Berikutnya (sesi 2)
- [x] Robust merge -> sesi 3.
- [x] Renderer ProfileGainTableMap -> sesi 3.
- [x] Output DNG -> sesi 3.
- [x] Kerangka app iOS + GitHub Actions -> sesi 3.

---

## 2026-11-12 - Sesi 3: robust merge, tone map Apple, DNG, log iPhone, app iOS v0.1

### 1. Robust merge (`pc-lab/robust_merge.py`, baru)
- Port logika `hdr-plus-swift/burstphoto/merge/spatial.{swift,metal}`: blur binomial 16 pada ref & frame
  pembanding -> selisih per superpixel -> bobot `clamp(1 - diff / (noise_sd / robustness), 0, 1)` ->
  `ref*(1-w) + comp*w`. Rumus robustness dari slider noise reduction Burst Photo (1..23).
- Mendukung Bayer (4 plane RGGB) dan linear RGB (ProRAW).
- `burst_merge.py`: opsi `--merge robust|simple` (default robust), `--nr` (default **18**).

| Set | nr | Bobot rata-rata | Noise turun (3 crop) | Artefak kotak |
|---|---|---|---|---|
| B | simple | 1.0 | 30 / 32 / 46 % | **ada** (rel gorden) |
| B | 13 | ~0.6 | 10 / 4 / 34 % | hilang |
| B | **18** | ~0.77 | 14 / 9 / 41 % | **hilang** |
| A | simple | 1.0 | 59 / 66 / 67 % | - |
| A | 13 | ~0.33 | 38 / 56 / 64 % | - |
| A | **18** | ~0.54 | 48 / 64 / 67 % | - |
- Gambar: `data/output/*_3way_*.jpg` (kolom: tunggal | simple | robust).
- Catatan: bobot set A (tripod, statis) masih ~0.5 -> estimasi noise dari |ref - blur(ref)| ikut menghitung
  tekstur, dan ProRAW sudah di-denoise Apple. Perbaikan nanti: noise model dari `NoiseProfile` DNG.

### 2. Tone map lokal Apple (ProfileGainTableMap)
- Tag DNG 1.6 (big-endian): grid **48x64**, **257** titik kurva per titik grid, bobot input
  (R,G,B,min,max) = (0.0031, 0.0104, 0.0011, 0, 0.0146). Didesain untuk input setelah BaselineExposure
  (headroom ~34x / ~5 EV). Implementasi: interpolasi trilinear (`grid_sample`) di `apply_pgtm()`.
- Hasil: plafon/jendela/dinding biru set B yang tadinya putih total kini ber-detail. Default ON
  (`--no-local-tm` untuk mematikan). Gambar: `data/output/set{A,B}_render_global_vs_pgtm.jpg`.

### 3. Output DNG
- `write_linear_dng()`: hasil merge -> **DNG LinearRaw 16-bit tanpa kompresi**, metadata warna,
  BaselineExposure, Orientation, NoiseProfile & ProfileGainTableMap disalin dari frame referensi.
- Validasi: dibaca **rawpy/LibRaw** (RawType.Stack 4032x3024, render OK). ~73 MB/file.
  Contoh: `data/output/iphone-20261111-setB_robust-nr18_merged.dng`.

### 4. Log / metadata kamera iPhone (ide user)
- Dipasang: **ExifTool 13.61** (winget OliverBetz.ExifTool), **pymobiledevice3** (venv).
- `pc-lab/iphone_meta.py` (baru): tabel EXIF + Apple MakerNote per frame + cek konsistensi -> `<set>/_meta.csv`.
  Hasil: kedua set **AE/AWB/AF terkunci** (ISO, shutter, fokus, Kelvin identik).
  Set A: ISO 1600 1/26 s, fokus 62, 5677 K, SNR ~24, jeda ~1 s/frame, kemiringan HP berubah s/d 1.8 deg
  (tripod bergetar saat shutter ditekan -> align tetap perlu). Set B: ISO 1250 1/25 s, SNR ~27, jeda ~1.8 s.
- `pc-lab/iphone_syslog.py` (baru): syslog live via USB, filter proses kamera
  (`cameracaptured`, `mediaserverd`, `Camera`, ... , `ModKamera`). Tes: 10 s -> 29 dari 9.757 baris.
  Akan dipakai untuk debug app sendiri dari Windows (tanpa Xcode).

### 5. App iOS v0.1 (`ios-app/`)
- SwiftUI + AVFoundation + Metal/Core Image. File: `CameraManager.swift`, `PreviewRenderer.swift`,
  `CubeLUT.swift`, `ContentView.swift`, `Log.swift`, `ModKameraApp.swift`, `project.yml` (XcodeGen).
- Fitur: preview LUT live (bawaan `SonyLook_v0.1_SOFT/STANDARD/STRONG` = OpenColorLab iPhone16PM Stock
  SonyInspired v0.1 Practical Pack, 33^3), import .cube, manual ISO/shutter(log)/WB/fokus, burst 1-16 frame
  dengan kunci AE/AWB/AF, format Bayer RAW / ProRAW / HEIF, simpan ke Photos + `Documents/Bursts/`.
- Build: `.github/workflows/ios-build.yml` (macos-15, XcodeGen, xcodebuild tanpa signing -> unsigned IPA).
- **Belum dikompilasi** (tidak ada Mac) -> build pertama di GitHub Actions akan memverifikasi.

### 6. GitHub
- Repo **public**: https://github.com/bagindev/BaginCam (lisensi **GPL-3.0**, karena robust merge turunan
  hdr-plus-swift). Commit identity: `bagindev` + email noreply GitHub (hanya untuk repo ini).
- Tidak ikut diupload (`.gitignore`): `data/`, `third_party/`, `pc-lab/.venv/`.
- Push pertama ditolak: token gh tidak punya scope `workflow` -> `gh auth refresh -s workflow` (perlu
  persetujuan user di browser).

### Berikutnya
- [ ] Push + build pertama GitHub Actions, perbaiki error kompilasi bila ada.
- [ ] Pasang IPA via Sideloadly, uji di iPhone, baca log `ModKamera` via `iphone_syslog.py`.
- [ ] Ambil burst **Bayer RAW** dari app -> uji `burst_merge.py` jalur Bayer (pipeline "GCam murni").
- [ ] Noise model dari `NoiseProfile` untuk robust merge yang lebih akurat.
- [ ] v0.2: ganti lensa, histogram/zebra/peaking; port align+merge Metal ke app.

---

## 2026-11-12 - Rename proyek -> BaginCam
- Repo GitHub: `bagindev/mod-kamera` -> **https://github.com/bagindev/BaginCam** (link lama di-redirect GitHub).
- Folder lokal: `D:\project\ios\mod-Kamera` -> `D:\project\ios\BaginCam`; semua referensi path di docs/skrip diperbarui.
- Build pertama GitHub Actions (run 43070208052): **BUILD SUCCEEDED** dalam 43 s, Xcode 16.4 / iOS SDK 18.5, 0 warning kode.
  IPA unsigned 1.5 MB (binary 488 KB + 3 LUT) -> `data/builds/ModKamera-v0.1.0-unsigned.ipa`.

- Folder lokal berhasil di-rename -> `D:\project\ios\BaginCam` (setelah tab VS Code ditutup). venv tetap jalan.
- **App di-rename ModKamera -> BaginCam**: target/scheme/`.app`, `ios-app/BaginCam/`, `BaginCamApp.swift`, bundle ID `dev.bagincam.app`, log subsystem `dev.bagincam.app`, artifact `BaginCam-ipa` / `BaginCam-unsigned.ipa`, filter syslog default `BaginCam`.


## 2026-11-12 - Bug: app crash saat dibuka (v0.1.0)
- User sideload IPA v0.1.0 (masih bernama ModKamera, bundle `dev.modkamera.app.BWDD486C8J`, signer Apple ID gratis, profil valid, Developer Mode ON) -> **crash tiap dibuka**.
- Crash log ditarik via `pymobiledevice3 crash pull` -> `data/logs/crash/` (9 file, semua sama): `EXC_CRASH SIGABRT`, NSException dari `AVCaptureFigVideoDevice deviceWhiteBalanceGains...` dipanggil dari Timer `updateReadout()`.
- Penyebab: timer readout jalan sebelum session kamera aktif -> gain WB = 0 -> konversi ke Kelvin melempar NSException (tidak bisa di-catch Swift).
- Fix v0.1.1: readout hanya saat `session.isRunning`, validasi gain > 0 & clamp ke [1, maxWhiteBalanceGain]; `applyManual` clamp suhu 2500-9000 K. Build lama (rename) dibatalkan untuk hemat kuota.


## 2026-11-12 - BaginCam v0.1.1 terpasang & bisa dibuka
- IPA `data/builds/BaginCam-v0.1.1-unsigned.ipa` (run 43072960194) di-sideload user; app terbuka normal (crash v0.1.0 teratasi).
- Berikutnya: uji fungsi di HP (LUT, manual, burst Bayer RAW) sambil rekam syslog 5 menit.


---

## 2026-11-12 - Sesi 4: uji v0.1.1 di HP + v0.2 / v0.3 / v0.4 sekaligus

### Hasil uji v0.1.1 (dari syslog USB, `data/logs/syslog_20261112-011043.txt`)
- LUT SOFT/STANDARD/STRONG dimuat OK. Burst **HEIF** 8 frame ~0.45 s/frame (ISO 1000, 1/40).
  Burst **ProRAW** 8 frame ~0.85 s/frame, ~11.5 MB/frame (ISO 6400, 1/1282 - manual).
- Bayer RAW belum dicoba user. Tidak ada error/crash.

### pc-lab: noise model dari NoiseProfile
- `robust_merge.py`: opsi `noise_profile=(S,O)` -> ambang per piksel = k x selisih yang diharapkan dari
  noise sensor (var = S*x + O, faktor blur binomial-16 = C(32,16)/2^32). CLI `--k` di burst_merge/compare.
- Hasil ProRAW: k=8 ~ setara nr18 (A: -46/-62/-66 %, B: -14/-7/-34 %), k=4 lebih konservatif.
  **Kesimpulan:** penolakan didominasi salah-align sub-piksel pada tekstur, bukan estimasi noise.
  Default tetap nr 18. Perbaikan berikut: align sub-piksel.

### App v0.4.0 (`ios-app/`)
- **v0.2**: ganti lensa 0.5x/1x/5x (deteksi otomatis), opsi 48MP (HEIF/ProRAW), histogram luminans
  (CIAreaHistogram 64 bin), zebra (>95 %, garis diagonal), focus peaking (CIEdges + threshold, merah).
- **v0.3 HDR+ di HP** (`HDRPlus.metal`, `HDRPlusMerger.swift`): mode **HDR+** = burst Bayer RAW ->
  align piramida (tile 16, +-2, coarse->fine) + spatial robust merge (blur binomial-16, nr 1..23) di GPU ->
  data hasil ditulis kembali ke DNG Apple lewat `AVCapturePhotoFileDataRepresentationCustomizer`
  (`RawReplacer`) -> metadata warna/lensa/NoiseProfile asli tetap. Opsi "+Frame" simpan frame mentah.
- **v0.4 AI Zoom** (`SRUpscaler.swift`): foto resolusi penuh (48MP di lensa utama) -> crop tengah sesuai
  zoom 1-10x -> bila < 4032 px: Real-ESRGAN **realesr-general-x4v3** (Core ML, tile 256 + overlap 16) ->
  HEIC dengan EXIF asli.
- Model: `tools/sr_model/convert_sr.py` + workflow `convert-sr-model.yml` (macOS, torch 2.5.1,
  coremltools 8.3.0). Weights SHA-256 8dc7edb9...96292 (dicek). Arsitektur diverifikasi lokal
  (1.21 M param). **Core ML fp16 vs PyTorch: PSNR 52.3 dB**. `.mlmodelc` 2.4 MB di
  `ios-app/BaginCam/Models/` + lisensi BSD-3.
- Versi 0.4.0 (build 3).

- Build v0.4.0: run 43078455490 gagal (Swift type-check timeout di HDRPlusMerger.swift:180, ekspresi dipecah) -> run **43079680665 SUCCESS**, 0 warning kode.
  IPA 3.9 MB `data/builds/BaginCam-v0.4.0-unsigned.ipa`: binary 697 KB, `default.metallib` 39 KB (kernel HDR+), model SR 2.4 MB, 3 LUT.
- **Belum diuji di HP**: HDR+ di GPU, AI Zoom, ganti lensa, zebra/peaking/histogram.
