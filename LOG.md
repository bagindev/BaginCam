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

## 2026-11-12 - Sesi 5: bug HDR+ & AI Zoom, v0.5.0

### Temuan uji v0.4.0 (file DCIM 6627-6648, `data/bursts/app-v040-test/`)
- **HDR+ tidak bekerja**: DNG hasil (IMG_6638) identik byte-per-byte dengan frame referensi (IMG_6629) -> `replacementRawPixelBuffer` diabaikan iOS untuk Bayer RAW.
- Merge Bayer yang sama di PC (9 frame ultra-wide ISO 400, `app-hdrplus-uw-9f`): bobot ~0.82, noise turun 39-58 % -> algoritma benar, masalah di penulisan file.
- **AI Zoom 2MP**: IMG_6642/6643/6644/6648 = 1608x1208 (crop 2.5x lensa 5x) -> SR gagal tanpa pesan, crop disimpan apa adanya. Penyebab Core ML belum diketahui (log 3 menit kosong, app tidak dibuka).
- Foto kamera bawaan: IMG_6627 (ProRAW UW), IMG_6641 (ProRAW 5x), IMG_6647 (HEIC zoom 14x). AI Zoom IMG_6640 (1x) sebanding dengan stock.
- Burst Bayer di app sangat cepat: 9-10 frame dalam ~0.75 s. Bayer ultra-wide 4224x3024, white 4095, black 528.

### Perbaikan v0.5.0 (run 43124958841 SUCCESS)
- `DNGWriter.swift`: tulis ulang DNG Apple dengan CFA hasil merge (uncompressed, byte order asli, EXIF/GPS/MakerNote/opcode disalin). Diuji di PC dengan port Python 1:1 (`tools/dng_rewrite_check.py`): rewrite identitas **byte-exact** di rawpy; versi merged noise 2.61 -> 1.10; ExifTool hanya 1 warning minor bawaan.
- `RawDeveloper.swift`: output HDR+ **HEIF (default) / JPEG / DNG / DNG+HEIF** via CIRAWFilter (NR Apple x0.4), orientasi dinormalisasi.
- **Bake LUT** opsional untuk HDR+, HEIF, AI Zoom.
- **Kamera depan** (dicerminkan), orientasi foto dari `RotationCoordinator` (potret/lanskap).
- AI Zoom: error Core ML dicatat & ditampilkan, fallback compute unit (ANE -> GPU -> CPU), konversi format output, bila tetap gagal -> resize biasa ke 12MP.
- IPA `data/builds/BaginCam-v0.5.0-unsigned.ipa`.

## 2026-11-12 - Sesi 6: uji v0.5.0 di HP, perbandingan dengan kamera bawaan

- Terpasang v0.5.0 build 4 (dicek via pymobiledevice3). Syslog baru mulai 07:18:36 (sebagian tes sebelumnya).
- File app diambil langsung dari container (`pymobiledevice3 apps pull --documents ... /Documents/Bursts`
  -> `data/bursts/app-docs/`), foto DCIM -> `data/bursts/app-v050-test/`.
- **Koreksi diagnosis "AI Zoom 2MP"**: nama file `AIZOOM_10.0x_SR.heic` -> SR **berhasil**. Ukuran ~1608x1208
  karena zoom 10x di lensa 5x (= 50x, crop 403x302) dan kode membatasi SR maks 4x (desain, bukan crash).
- Log AI Zoom 3x (IMG_6663): sumber 48MP 8064x6048, crop 2654x1990, SR 108 tile **2.91 s** (Neural Engine,
  output BGRA), simpan 4032x3023.
- Kamera depan: burst HEIF 8 frame OK (IMG_6650-6657). HDR+ v0.5.0 **belum diuji**.
- Perbandingan (gambar `data/output/cmp_3x_full.jpg`, `cmp_3x_crop100.jpg`, `cmp_50x.jpg`):
  - **3x** (BaginCam AI IMG_6663 vs stock 73mm IMG_6664): **stock lebih baik** - tekstur dinding natural & tajam;
    BaginCam terlihat seperti lukisan cat air (Real-ESRGAN general menghapus tekstur halus).
  - **50x** BaginCam (IMG_6661) vs stock 28x di-crop ke FOV sama (IMG_6662): keduanya jelek; BaginCam
    berhalusinasi pola palsu + artefak blok di tepi kiri/kanan; stock blur tapi natural.
- Kesimpulan: SR GAN satu-frame tidak cocok untuk zoom rendah (<=5x) dan berlebihan di zoom ekstrem.
  Rencana: zoom total 1-25x dengan pindah lensa otomatis (seperti stock), <=2x crop 48MP tanpa SR,
  SR lebih halus (blend / denoise strength rendah) hanya di atas 5x/10x, multi-frame super-resolution,
  perbaiki artefak tepi, output selalu 12MP.

## 2026-11-12 - Sesi 7: v0.6.0 (AI Zoom pilih lensa otomatis, x4plus, 24MP)

### Analisa lensa kamera bawaan (permintaan user)
EXIF foto stock (`data/bursts/app-v040-test`, `app-v050-test`):
| Foto | Zoom | Lensa fisik | Jarak fokus | BV |
|---|---|---|---|---|
| IMG_6641 | 5x | Tele 15.7mm | 0.30-1.12 m | -3.2 |
| IMG_6645/6646 | 20x | **Utama 6.8mm, crop** | 0.06-0.96 m | -0.4 |
| IMG_6647/6659/6662 | 28x | **Utama 6.8mm, crop** | 0.07-0.66 m | -0.4..-0.7 |
| IMG_6664 | 3x | Utama crop | 0.20-0.59 m | -0.2 |
- Kesimpulan: iOS pakai **crop lensa utama bila subjek lebih dekat dari jarak fokus minimum tele**
  (bahkan di 28x); di gelap tapi subjek jauh tetap tele. BaginCam v0.5 memaksa tele >= 5x -> tele
  tidak bisa fokus pada dinding dekat -> hasil 50x buruk (SR "melukis" blur).

### Perubahan v0.6.0 (run 43128720663 SUCCESS, 0 warning kode, IPA 35 MB)
- **AI Zoom pakai kamera virtual Apple** (`builtInTripleCamera`, switching `.auto`): iOS memilih tele
  vs crop lensa utama (jarak fokus/cahaya). Saat memotret: lensa dikunci (`.locked`), zoom diset ke
  native lensa itu -> foto resolusi penuh (48MP lensa utama), crop + upscale oleh BaginCam.
- **Penanda lensa** di preview (`activePrimaryConstituent`): "Tele 5x", "Utama 1x · crop 7.0x" (oranye bila crop).
- Zoom total **1-25x** (slider log + tombol 1/2/5/10/25x).
- Model **Cepat** (general-x4v3) / **Detail** (RealESRGAN_x4plus, RRDBNet 16.7 M param, Core ML 33 MB,
  PSNR **46.0 dB** vs PyTorch, weights SHA-256 4fa0d389...82f1).
- AI hanya bila pembesaran >= 1.4x, dicampur Lanczos (**Kekuatan AI**, default 50 %).
- **Multi-frame zoom**: tele (atau crop >= 3x) -> burst Bayer 8 frame -> HDR+ merge -> develop -> crop -> SR.
- SR: tile memakai piksel asli di luar crop (fix artefak blok tepi), output langsung ke skala akhir
  (tanpa kanvas x4 raksasa), ruang warna sumber (P3) dipertahankan.
- **Resolusi output 12/24/48MP**: HEIF (ambil 48MP, 24MP = diperkecil dari 48MP), ProRAW (48MP),
  HDR+ HEIF/JPEG (Bayer 12MP diperbesar AI Cepat + Lanczos), AI Zoom.
- IPA: `data/builds/BaginCam-v0.6.0-unsigned.ipa`. **Belum diuji di HP.**

## 2026-11-12 - Sesi 8: "proses AI berhenti" (v0.6.0) -> v0.6.1

- JetsamEvent 07:50:07: memori HP penuh (cameracaptured 1.6 GB), yang dibunuh `ndoagent` & `CameraOverlayAngel`;
  **BaginCam tidak dibunuh** (puncak 1.2 GB). App Photos sempat aktif.
- Output v0.6.0 dari container app: `AIZOOM_5.0x_Tele_AID_48MP` x2 (8064x6048, **76 s / 80 s**),
  `AIZOOM_10.0x_Tele_AID_24MP` (5712x4284, **44 s**). Detail (x4plus) ~0.3 s/tile; 5x tele -> 48MP = SR 2x
  seluruh foto 12MP (~252 tile). Proses tidak berhenti, tapi lama + status hanya tiap 4 tile; bila app
  ditinggal (buka Photos) iOS membekukan app -> proses tertunda.
- Tidak ada `_MF` -> Bayer RAW tidak tersedia di kamera virtual -> multi-frame tidak jalan.
- Fix v0.6.1: progress bar + persen + sisa waktu tiap tile, peringatan "jangan tinggalkan app",
  `beginBackgroundTask` (proses lanjut ~30 s saat app ditinggal); MF: sementara pindah ke lensa fisik
  yang dipilih iOS (activePrimaryConstituent) untuk burst Bayer 8 frame, lalu kembali ke kamera virtual.
- Log 07:55 (v0.6.0, `syslog_20261112-075214.txt`): AI Zoom 10x -> iOS pilih **Utama crop 10x** (subjek dekat, benar),
  tapi sumber hanya **4032x3024** (kamera virtual tidak memberi 48MP) -> crop 402x302, SR Detail 4 tile 0.76 s,
  lalu Lanczos ke 5712 -> lembek.
- Fix v0.6.2: setiap capture AI Zoom pindah sementara ke **lensa fisik** pilihan iOS (48MP lensa utama + Bayer
  untuk MF), kembali ke kamera virtual setelahnya; kunci AE/AWB/AF setelah lensa stabil (0.9 s).

## 2026-11-12 - Sesi 9: AI Zoom luar ruangan putih/pink (v0.6.1) -> v0.6.3

- Hasil 08:00-08:01 (v0.6.1): `AIZOOM_25.0x_Tele_MF8_AI{C,D}_{12,24}MP.heic` -> hampir seluruhnya **putih + magenta**
  (mean 252/255). Gambar: `data/output/outdoor_25x.jpg`.
- Penyebab: DNG Bayer Apple = **12-bit** (WhiteLevel 4095, BlackLevel 528, IMG_6629), sedangkan data merge diambil
  dari pixel buffer kamera (format Bayer 14-bit, skala s/d 16383) dan ditulis apa adanya -> di adegan terang hampir
  semua piksel > WhiteLevel -> terpotong -> putih, WB mengubah area terpotong jadi magenta. Berlaku juga untuk HDR+
  (jalur Bayer -> merge -> DNG sama). Uji PC sebelumnya memakai data dari DNG (12-bit) sehingga tidak terdeteksi.
- Fix v0.6.3: `DNGWriter.rewrite(sourceFullScale:)` menskalakan data ke WhiteLevel DNG
  (14-bit -> x(4096/16384)); format pixel buffer (fourCC, mis. rgg4 = 14-bit), maks data, white & skala dicatat ke log
  (kategori hdrplus) untuk verifikasi.

## 2026-11-12 - Sesi 10: verifikasi v0.6.3 + menu terpotong -> v0.6.4

- Log (`syslog_20261112-081121.txt`): `RAW rgg4=14-bit, maks data 8635, DNG white 4095 -> skala 0.25` -> **diagnosis
  14-bit terkonfirmasi** (data > 4095 tidak mungkin 12-bit). Kamera virtual: Bayer false, maks 24MP (pindah ke
  lensa fisik memang perlu).
- AI Zoom 25x Tele MF8 (08:12:48): merge 0.24 s bobot ~0.85, SR Detail 12 tile 2.65 s -> **warna normal, 0 % clip**
  (`data/output/v063_aizoom_vs_tele_frame.jpg`). Cerobong lembut karena fokus di kabel depan.
- HDR+ HEIF 12MP x3 (08:11): eksposur & warna normal, clip 0-5.5 % (langit) (`data/output/v063_hdrplus.jpg`).
- User tidak menemukan menu format/+Frame (screenshot tidak sampai ke PC/iPhone DCIM): baris alat terlalu panjang ->
  tombol format & +Frame terpotong di kanan layar. Fix v0.6.4: baris alat bisa digeser, pengaturan mode di depan.

## 2026-11-12 - Sesi 11: verifikasi HDR+ final + menu baru (v0.7.0)

### Verifikasi HDR+ di HP (v0.6.3, `HDRPLUS_20261112-082117`, DNG+HEIF + 8 frame mentah)
- Kecerahan DNG hasil vs frame 1 Apple: rasio **1.001** (mean 805.0 vs 804.6, maks 2358 vs 2364) -> skala 14->12 bit benar.
- Bandingkan dengan merge PC (`robust_merge.py`, 8 frame asli Apple yang sama): beda rata-rata **0.83 DN** (skala 4095)
  -> port Metal identik dengan pipeline PC.
- Noise turun **42 / 51 / 61 %** (3 crop). Gambar: `data/output/v063_hdrplus_frame_vs_merge.jpg`.
- Screenshot user `data/screenshots/IMG_6724.PNG`: label tombol terpotong jadi "..." (bukan keluar layar).
  Catatan: daftar file iPhone via Windows Shell/MTP ter-cache -> pakai `pymobiledevice3 afc ls/pull` untuk file terbaru.

### Menu baru v0.7.0 (permintaan user: lebih interaktif / dikelompokkan)
- **Strip mode** di atas shutter: AI ZOOM · HDR+ · FOTO · PRORAW · BAYER (ketuk, otomatis ke tengah).
- **Ringkasan pengaturan + ikon gear** di kanan atas (mis. "HEIF · 12MP · 8 frame") -> buka **panel Pengaturan**
  (sheet) berkelompok: Hasil foto (format, resolusi, jumlah frame, frame mentah, bakar LUT), HDR+ (noise reduction),
  AI Zoom (model, kekuatan, multi-frame), Bantuan bidik (histogram, zebra, peaking), Info (lensa aktif, versi);
  tiap kelompok ada penjelasan singkat; hanya opsi yang relevan dengan mode aktif yang tampil.
- Baris tombol kecil dihapus; baris AI Zoom tinggal preset + slider; tombol Manual berlabel.

## 2026-11-12 - Sesi 12: sampel siang-sore (v0.7.0) -> v0.7.1

Sampel: 18 AI Zoom + 12 HDR+ di container app (`data/bursts/app-docs-v070/`), DCIM IMG_6865-6889
(`data/bursts/dcim-1112-sore/`), screenshot viewfinder IMG_6870, screen record IMG_6871/6873.MP4.
(IMG_6888 = screenshot web kerja, tidak terkait -> salinan dihapus.)

### Viewfinder vs jepretan (AI Zoom 25x, IMG_6870 vs IMG_6869)
- Pada ukuran tampilan sama, jepretan justru lebih tajam (teks "MUHAMMADIYAH 13 TIKUNG" terbaca), tapi
  artefak AI terlihat (wajah baliho rusak, halo teks, daun seperti lukisan) karena Kekuatan AI 100%.
- 25x di tele = crop ~806 px -> 24MP (5712) = pembesaran ~7x. Viewfinder = jalur video Apple (halus, alami,
  ditampilkan kecil). `data/output/vf_vs_capture_samesize.jpg`.

### HDR+ terang & "noise"
- 124749: RAW **0 % terpotong**, HEIF hasil **21 %** putih (langit/kain hilang); 125024/125036 clip 34-46 %.
  Stock: 0 % clip (Smart HDR tone map lokal). Penyebab: CIRAWFilter menerapkan BaselineExposure DNG
  (+0.5..+1.0 EV) global tanpa perlindungan highlight. `data/output/HDRPLUS_20261112-124749_heic_vs_frame.jpg`.
- "Noise": crop 100 % menunjukkan **garis kotak sambungan tile SR** (upscale 24MP, outScale 1.42: tile digambar
  pada posisi pecahan -> tepi setengah transparan). `data/output/HDRPLUS_20261112-125024_crop100.jpg`.
- Temuan: **kamera depan mendukung Bayer RAW** (HDR+ 125024 front 2.69mm).

### AI Zoom pakai apa?
- Log: jumlah `ANEProgramProcessRequestDirect` = jumlah tile SR (108/108, 4/4, 12/12, 48/48) -> **Neural Engine (NPU)**.
  Cepat ~0.03 s/tile, Detail ~0.21 s/tile. Merge HDR+ di GPU (Metal), CPU untuk persiapan/penyusunan tile.

### Fix v0.7.1
- SR: tile non-x4 digambar penuh (dengan margin) lalu di-clip ke batas piksel bulat -> tanpa garis sambungan.
- HDR+ develop: persentil 99.9 data merge -> `exposure` CIRAWFilter diturunkan agar p99.9 = 0.9 (highlight aman),
  `localToneMapAmount = 1` (angkat bayangan), NR Apple x0.6 (warna x0.8). DNGWriter juga mengembalikan black level.

## 2026-11-12 - Sesi 13: v0.8.0 (1 suara shutter, sentuh fokus, zoom FOTO/HDR+ AI on/off, zoom 50x)

- **GCam -> iOS?** Data GCam lokal (`Documents\gcam-taoyao\configs`): XML/AGC = angka tuning (lib_luma*/chroma* per ISO,
  sharpening, hdr on/off), algoritma HDR+ ada di libgcam.so (Android ARM64, tertutup) -> tidak bisa/boleh dikonversi.
  Yang bisa: implementasi metode publikasi Google (HDR+ 2016, Night Sight 2019, Super Res Zoom 2019) + pakai nilai
  tuning AGC sebagai patokan.
- **1 suara shutter**: frame 2..N `isShutterSoundSuppressionEnabled` (iOS 18, bila wilayah mengizinkan). FOTO = 1 jepretan.
- **Sentuh fokus** (sebelumnya belum diimplementasi): ketuk = fokus + eksposur di titik (mapping potret: x_s = y_v,
  y_s = 1 - x_v, depan dicerminkan; dikoreksi zoom), tekan lama = kunci AE/AF ("AE/AF TERKUNCI"), subjek berubah ->
  kembali otomatis ke tengah.
- **Zoom di FOTO & HDR+** (lensa belakang): zoom digital di atas lensa terpilih; capture resolusi penuh (FOTO 48MP,
  HDR+ merge 8 frame Bayer) -> crop -> upscale **AI atau tanpa AI (Lanczos)** (toggle "Pakai AI saat zoom" / chip
  AI di baris zoom) untuk membandingkan. Nama file `FOTO_ZOOM_*` / `HDRPLUS_ZOOM_*` (+ DNG tanpa crop).
- **Zoom maks 50x** (AI Zoom & FOTO/HDR+ lensa utama; tele 5x x10): di atas batas hardware preview di-crop tambahan.

## 2026-11-12 - Sesi 14: analisa sampel DNG per lensa + v0.8.1 (kunci lensa, EV, grid)

Analisa 18 set DNG (frame 1 Apple Bayer + hasil merge app bila ada), `tools`-skrip ad hoc:
| Lensa | ISO / shutter | RAW clip | median RAW | noise turun (HDR+) |
|---|---|---|---|---|
| Ultra-wide 2.22mm f/2.2 | 20-64, 1/41-1/1050 | 0 % | 0.7-2.4 % | 45-51 % |
| Utama 6.77mm f/1.78 | 80-125, 1/228-1/3759 | 0-0.04 % | 0.9-3.3 % | 52 % |
| Tele 15.66mm f/2.8 | 50-64, 1/165-1/914 | 0-0.13 % | 1.3-4.6 % | 50-56 % |
| Depan 2.69mm f/1.9 | 40, 1/273-1/1541 | 0.2-3.6 % | 3.7-5.8 % | 50-52 % |
- AE Apple sudah "underexpose" (median RAW 1-6 %, highlight hampir tidak pernah clip) -> rencana -1 EV ala GCam tidak
  perlu; masalah terang murni di develop (fix v0.7.1). Bayangan diangkat jauh -> noise terlihat; merge 8 frame ~50 %
  (teori 65 %) -> berikutnya: jumlah frame otomatis (12-16 di redup) + merge domain frekuensi.
- Sampel pagi sudah termasuk (BURST 08:13, HDR+ 08:21, burst 01:10-01:13; UW 9 frame 06:53 dianalisa di sesi 5).
  HDR+ 06:53 (v0.4) tidak valid (bug, identik frame tunggal).

v0.8.1: **kunci lensa di AI ZOOM** (Auto / Utama 1x / Tele 5x; terkunci = lensa fisik + zoom digital, penanda
"(kunci)"), **kompensasi EV** -3..+3 di panel Manual saat Auto, **grid 3x3** (Pengaturan > Bantuan bidik).

## 2026-11-12 - Sesi 15: v0.9.0 (merge frekuensi, frame otomatis, WB, timer, tombol volume, waterpass, preview beku) + uji Super Res Zoom

### Merge domain frekuensi (permintaan #1)
- Prototipe `pc-lab/freq_merge.py` (Wiener per tile 16x16 stride 8, Hann, noise dari NoiseProfile DNG, torch.fft
  presisi tunggal per pita - RAM PC hanya ~3 GB bebas). Center crop 2048x1536, 8 frame:
  | set | tunggal | spasial (nr18) | frek c4 | c8 | **c16** |
  |---|---|---|---|---|---|
  | utama 124839 | 1.47 | 0.72 | 0.88 | 0.79 | 0.74 |
  | tele 124926 | 1.84 | 0.83 | 0.99 | 0.86 | **0.79** |
  | depan 125024 (gerak) | 2.27 | 1.19 | 1.52 | 1.37 | 1.26 |
  Visual: frekuensi menjaga helai rambut/kulit pada subjek bergerak (spasial meng-kabur-kan); 3x lebih cepat di CPU.
  `data/output/freq_vs_spatial_*.jpg`.
- Port Metal (`HDRPlus.metal`: freq_ref / freq_add_frame / freq_inverse, threadgroup 16x16 = DFT separable,
  pita 24 baris tile, overlap-add 4 paritas). `HDRPlusMerger.merge(freq:)`; c = 2^((NR-10)/2) (NR 18 -> 16);
  NoiseProfile + black/white dari DNG referensi (`DNGWriter.info`), dikonversi ke satuan pixel buffer 14-bit.
  Default **Frekuensi**, pilihan Spasial di Pengaturan > HDR+.
- **Jumlah frame otomatis** (ISO x waktu): <0.25 -> 6, <2 -> 8, <10 -> 12, lainnya 15.

### Fitur lain
- **WB preset**: Auto / Cerah 5500K / Berawan 6500K / Teduh 7500K / Pijar 3000K / Neon 4000K / **Kunci** (terpisah
  dari AE/AF); burst tidak menimpa preset.
- **Timer** 3/10 s (hitung mundur besar, ketuk = batal) + **shutter tombol volume** (AVCaptureEventInteraction, iOS 17.2+).
- **Waterpass** (CoreMotion gravity, kuning bila +-1 derajat, potret/lanskap).
- **Fix "zoom lalu jepret jadi 1x & goyang"**: preview **dibekukan** di frame terakhir saat capture (zoom hardware
  diset 1x / ganti lensa di belakang layar), label "Memotret - tahan HP...", lepas setelah frame terakhir.

### Super Res Zoom (#7) - prototipe, BELUM dimasukkan ke app
- `pc-lab/mfsr.py`: splat sampel Bayer 8 frame ke grid 2x (Wronski 2019 disederhanakan): align global (phase corr)
  + tile SAD + parabola, opsi Lucas-Kanade, kernel isotropik lalu anisotropik (tensor struktur).
- Tele 132656 (handheld, geser 14-49 px, fase sub-piksel tersebar merata = kondisi ideal):
  lebar tepi tiang (10-90 %, px di skala 2x): HDR+ merge + Lanczos **6**, SRZ SAD 7, SRZ LK 7-8, SRZ anisotropik 7;
  noise SRZ 0.53-0.56 vs 0.66 (lebih bersih) tapi **tidak lebih tajam** -> ketajaman tele dibatasi lensa.
  Tidak di-ship agar kualitas tidak turun. Gambar `data/output/mfsr*_*.jpg`.

### Build
- v0.9.0 run 43198315588 SUCCESS (percobaan pertama). IPA `data/builds/BaginCam-v0.9.0-unsigned.ipa`. Belum diuji di HP.

## 2026-11-12 - Sesi 16: v0.9.1 (UW di AI ZOOM, FOTO seperti kamera bawaan, Fokus tulisan)

- **AI ZOOM + Ultra Wide**: kunci lensa Auto / UW .5x / Utama 1x / Tele 5x; Auto mulai 0.5x (kamera virtual).
- **FOTO = seperti kamera bawaan**: kamera virtual Apple (zoom mulus 0.5-50x, pilih lensa otomatis, Smart HDR /
  Deep Fusion Apple), kunci lensa (+ Depan); kunci Utama = 48MP. "Pakai AI saat zoom digital" mati = proses Apple
  apa adanya (termasuk zoom digital Apple); hidup = di atas zoom optik -> foto resolusi penuh di-crop + AI.
- **Fokus tulisan** (ide user): setelah SR, `VNRecognizeTextRequest` (.fast, di HP) mendeteksi area teks ->
  di area teks AI dipakai penuh (>= 95 %), area lain tetap "Kekuatan AI"; masker diperluas 35 % tinggi teks &
  dihaluskan (Gaussian). Status/log menyebut jumlah area teks. Default aktif.
- Penjelasan HDR+ "tanpa AI": merge multi-frame (6-15 frame, frekuensi) di resolusi sensor -> crop -> Lanczos.
  Bukan Super Res Zoom (MFSR menaruh sampel di grid lebih halus; prototipe sesi 15 belum lebih tajam).

## 2026-11-12 - Sesi 17: uji v0.9.1 (tulisan) -> v0.9.2

Sampel 17:42-17:43 (adegan kantor, plang "AVP SALES REGION 4A" + tulisan tangan kardus "BARU tgl 23/10"):
| File | Metode | Hasil | kardus putih R-G | kecerahan |
|---|---|---|---|---|
| IMG_6901/6902 | FOTO AI mati (Apple, 263mm ~11x, ISO 2000-2500) | 12MP | +12 | 108 |
| IMG_6903 | FOTO AI Cepat (tele crop 2x) | 24MP | **+26 (pink)** | 115 |
| IMG_6904 | AI ZOOM MF8 Detail | 12MP | +14 | **139 (terlalu terang)** |
- Tulisan terbaca di semua; Apple paling berbintik, MF paling bersih (huruf sedikit lebih lembut), AI Cepat paling
  kontras. `data/output/v091_plang.jpg`, `v091_kardus.jpg`, `v091_compare_full.jpg`.
- Penyebab pink: pindah ke lensa fisik lalu capture 0.9 s -> AWB lensa fisik belum stabil.
- Fix v0.9.2: ISO/shutter + suhu/tint WB kamera virtual (sensor sama) disalin & dikunci di lensa fisik sebelum
  capture (delay 0.5 s); develop RAW mengukur kecerahan dari pratinjau 1/8 (CIAreaAverage) dan menurunkan eksposur
  bila rata-rata linear > 0.21 (target 0.17 ~ foto Apple); tone map lokal 0.8.

## 2026-11-12 - Sesi 18: uji v0.9.2 di poster "JL. TUNJUNGAN" -> v0.9.3

Sampel 17:50-17:54 (~14x tele): IMG_6907/6909 FOTO Apple, IMG_6908 FOTO AI Detail 24MP, IMG_6905 AI ZOOM MF8 Cepat,
IMG_6906 AI ZOOM MF8 Detail (`data/bursts/dcim-1112-malam2/`, `data/output/v092_*.jpg`).
| | kecerahan | R-G | paragraf kecil |
|---|---|---|---|
| FOTO Apple | 145 | -0.7 | terbaca, berbintik |
| FOTO AI Detail | 156 | +5.3 | terbaca, tebal/kontras, sedikit belepotan |
| AI ZOOM MF Cepat | 179 | +6.2 | terbaca, bersih, tipis/pucat |
| AI ZOOM MF Detail | 179 | +5.9 | **huruf palsu** ("true beating heart of Surabaya" -> "ung beam ul uunubon") |
- Pink v0.9.1 **teratasi** (transfer WB). MF masih terlalu terang: kecerahan diukur di seluruh frame, padahal yang
  disimpan crop tengah.
- **Temuan**: Fokus tulisan + model Detail (x4plus) kekuatan 95 % -> AI mengarang huruf pada teks kecil.
- Fix v0.9.3: Fokus tulisan **berbasis OCR** - per area teks (maks 24), VNRecognizeTextRequest .accurate (+ koreksi
  bahasa) dijalankan di versi AI & versi asli (MF/Lanczos); AI dipakai hanya bila keyakinan OCR > asli + 0.03,
  selain itu area itu memakai versi asli murni. Log: jumlah area, AI menang, skor ai/asli. Kecerahan develop diukur
  di area zoom (1/crop), target linear 0.26 bila > 0.30.

## 2026-11-12 - Sesi 19: uji v0.9.3 -> v0.9.4 (HDR+ lensa otomatis)

Log `syslog_20261112-180120.txt`:
- HDR+ 1x 18:00-18:01 (gelap, ISO 800 1/15): **15 frame otomatis**, merge frekuensi **0.69 s** (GPU), NoiseProfile
  S 0.0012 O 4e-6, black 2112 / range 14268 (14-bit). Develop: baseline +2.2 EV, kecerahan diturunkan -1.2 EV ->
  hasil wajar (kecerahan 164, clip 0 %).
- HDR+ zoom 13.1x 18:04: lensa **Utama** (tombol 1x aktif) -> crop **230x306 px** -> 24MP = sangat buram (MF 12 frame,
  0.56 s). Fokus tulisan OCR: AI 0.30 vs asli 0.50 -> AI kalah, versi asli dipakai (anti huruf palsu bekerja).
- Fix v0.9.4: **HDR+ memakai kamera virtual** seperti FOTO/AI ZOOM (lensa otomatis 0.5-50x + kunci lensa Auto/UW/
  Utama/Tele/Depan). Capture: pindah ke lensa fisik pilihan iOS (transfer ISO/shutter/WB), burst Bayer (jumlah
  otomatis), merge; zoom digital hanya bila melewati lensa optik (crop > 1.05) -> crop + AI/Lanczos. Tombol lensa
  fisik kini hanya di mode BAYER/PRORAW.

## 2026-11-12 - Sesi 20: cek sampel v0.9.3 (selfie HDR+, poster AI ZOOM) -> v0.9.5

Sampel `data/bursts/dcim-1112-malam3/` (IMG_6910-6919), app `data/bursts/app-docs-v093b/`.
- **Selfie depan** HDR+ 15 frame (IMG_6910/6912/6913, ISO 640-800 1/15) vs kamera bawaan (IMG_6911/6914):
| | kecerahan | noise wajah | noise dinding | R-G |
|---|---|---|---|---|
| HDR+ (6912) | 164 | 1.19 | 1.02 | +8.3 |
| Bawaan (6911) | 163 | 0.92 | 0.77 | +5.0 |
  Kecerahan sudah sama; HDR+ sedikit lebih hangat & ~25 % lebih berbintik (Apple memakai NR + Deep Fusion wajah).
  `data/output/v093_selfie_stock_vs_hdr.jpg`.
- **AI ZOOM 13x poster** (tele crop 2.6x, MF 8): kecerahan diperbaiki (179 -> 135/133, metering area zoom -0.97/-0.87 EV).
  - IMG_6919 Cepat: SR 1.4 s, teks 1/9 AI -> paragraf lembut tapi **jujur** (tidak ada huruf karangan).
  - IMG_6918 Detail: SR 9.9 s (42 tile), teks 7/22 AI -> paragraf kedua **masih huruf palsu** ("There is no better
    place..." -> "Thoso ic on Duiiac phoon", "the legendary streets" -> "tho bypomlary muvoro").
    `data/output/v093_paragraf_detail_vs_cepat.jpg`, `v093_poster_paragraf.jpg`.
  - Penyebab: keyakinan OCR Vision (0.3/0.5/1.0 bertingkat) bisa lebih tinggi untuk huruf karangan; dan area yang
    dikarang AI sering tidak terdeteksi sebagai teks di versi AI -> tetap campuran 50 %.
- IMG_6915/6916: HDR+ 13x lensa Utama (sudah diperbaiki di v0.9.4). IMG_6917: FOTO 50x Tele AI Detail (crop 402 px).
- Fix v0.9.5 (TextBoost): kotak teks dideteksi di versi AI **dan** versi asli (gabungan, maks 32); AI dipakai hanya
  bila keyakinan OCR > asli + 0.03 **dan isi teks OCR AI mirip teks versi asli** (Levenshtein, kemiripan >= 0.75).
  Log menampilkan `ai/asli~mirip` per area.

- Build v0.9.5: run 43208302285 sukses -> `data/builds/BaginCam-v0.9.5-unsigned.ipa`.

## 2026-11-12 - Sesi 21: uji v0.9.5 -> v0.9.6

Sampel `data/bursts/dcim-1112-malam4/` (IMG_6920-6926), log `syslog_20261112-183011.txt`.
| foto | isi |
|---|---|
| IMG_6920 | AI ZOOM 13x Tele crop 2.6x MF8, Cepat (SR 1.4 s), teks 0/13 AI |
| IMG_6921 | AI ZOOM 13x, Detail (SR 9.6 s), teks 0/25 AI |
| IMG_6922 | **HDR+ 13x -> lensa Tele otomatis** (crop 2.6x, 15 frame, merge 0.70 s), Detail, teks 0/22 AI |
| IMG_6923 | HDR+ kunci Utama 1x, 15 frame ISO 500 |
| IMG_6924 | kamera bawaan ~14x (348mm-eq) |
| IMG_6925 / 6926 | selfie HDR+ depan 15 frame / bawaan |
- **HDR+ lensa otomatis (v0.9.4) berhasil**: 13x memakai Tele (dulu Utama crop 230 px). Kunci lensa Utama juga jalan.
- Fokus tulisan v0.9.5: huruf karangan parah ("Thoso ic on Duiiac") **hilang** di AI ZOOM Detail. Tapi di HDR+ 13x
  Detail masih ada baris agak aneh ("modern energy" -> "modara onoigy"): baris paragraf kecil (~30 px) tidak
  terdeteksi (minimumTextHeight 0.008) dan batas 24 kotak -> tetap campuran AI 50 %. Kemiripan OCR di log mis.
  0.90/0.50~0.73 (AI lebih yakin tapi isi beda -> ditolak).
- Pembanding: kamera bawaan 14x juga "mengarang" bentuk huruf (penajaman berat): "There is no better" -> "Tharu ls ou
  better". AI ZOOM Cepat = paling jujur. `data/output/v095_paragraf.jpg`.
- Selfie: noise HDR+ kini setara/lebih bersih (dinding 3.32 vs 3.93, pipi 2.55 vs 2.63) tapi **wajah lebih gelap**
  (linear 0.15 vs 0.28, ~0.9 EV): latar AC/plafon terang -> metering menurunkan -1.07 EV. `data/output/v095_selfie.jpg`.
- Hasil 12MP: pengaturan tidak disimpan -> tiap buka app kembali ke default 12MP.
- Fix v0.9.6:
  - TextBoost: minimumTextHeight 0.004, tanpa batas 24; kotak dari versi AI + asli digabung jadi **blok paragraf**
    (baris berdekatan & seukuran), OCR + keputusan per paragraf (maks 40 blok).
  - RawDeveloper: **metering wajah** (VNDetectFaceRectangles di pratinjau 1/8, tengah wajah terbesar): target
    linear 0.24, koreksi -1.2..+0.8 EV, mengalahkan metering rata-rata (hanya bila tidak zoom crop).
  - Pengaturan disimpan (UserDefaults): resolusi, format, LUT bake, NR, frame, model AI, kekuatan, fokus tulisan,
    multi-frame, AI zoom on/off, metode merge, frame otomatis, timer.

- Build v0.9.6: run 43211070140 sukses -> `data/builds/BaginCam-v0.9.6-unsigned.ipa`.

## 2026-11-12 - Sesi 22: uji v0.9.6

Sampel `data/bursts/dcim-1112-malam5/` (IMG_6927 HDR+ 13x Tele Cepat 24MP, IMG_6928 selfie HDR+ depan 24MP).
- **Pengaturan tersimpan**: 24MP tetap setelah app dibuka ulang (4282x5712).
- Fokus tulisan per paragraf: 17 blok, AI 0 -> semua baris paragraf memakai versi asli; tidak ada huruf karangan
  (bandingkan v0.9.5 "modara onoigy"). Masih lembut (Cepat, crop 2.6x). `data/output/v096_paragraf.jpg`.
- **Metering wajah**: wajah linear 0.32 (eksposur -0.43 EV, dulu -1.07) vs Apple 0.28 (v0.9.5: 0.15) -> wajah tidak
  gelap lagi. Warna sedikit lebih hangat (R-G +8.4 vs +4.8). `data/output/v096_selfie.jpg`.
- Catatan: kamera depan 12MP -> 24MP lewat SR Cepat 252 tile 8.1 s.
- Pertanyaan pengguna: kenapa FOTO dan HDR+ dipisah padahal isinya sama -> dijelaskan (lihat chat); usulan gabung
  jadi satu mode FOTO dengan pilihan proses.
- Studi UI GCam (screenshot AGC 9.4/9.6 dari proyek gcam-taoyao): mode = niat (Photo/Night Sight/Portrait), HDR+ &
  Super Res Zoom selalu otomatis, chip cepat atas, zoom chip di atas shutter, laci Pro bawah, settings berkelompok.
  Usulan susunan baru BaginCam (MALAM · FOTO · PRO, chip proses HDR+/Apple/Auto, AI zoom otomatis):
  `docs/usulan-ui-gcam.md`. Menunggu keputusan pengguna sebelum eksekusi.
- Inventaris fitur v0.9.6 untuk penggabungan menu ditulis ke `docs/usulan-ui-gcam.md`.

## 2026-11-12 - Sesi 23: v0.10.0 - susunan UI ala GCam + zoom fleksibel

Keputusan pengguna: mode MALAM · FOTO · PRO; semua proses tetap bisa dipilih; bar info gabungan (GCam + buatan
sendiri + kamera bawaan); thumbnail + penampil; laci Pro ala GCam. Pesan tambahan: cara zoom (Apple / Super Res)
dan AI dipisah supaya bisa ditumpuk.
- **Mode** (strip bawah): MALAM · FOTO · PRO. Mesin internal tetap (`Mode`), dipetakan:
  FOTO+HDR+/Auto -> hdrplus, FOTO+Apple -> heif, MALAM -> hdrplus+malam, PRO -> HDR+ / ProRAW / Bayer.
- **Baris 1 (chip cepat)**: Proses (Auto/HDR+/Apple; di PRO: HDR+/ProRAW/Bayer) · LUT (+bake, import) · WB
  (preset / Kelvin manual) · resolusi·format · rasio 4:3/16:9/1:1 · flash · Live (dua terakhir hanya proses Apple) · ⚙.
- **Baris 2 (di preview)**: lensa aktif + crop (+ikon makro bila iOS pindah ke UW), chip zoom "cara + AI" (menu),
  perkiraan frame HDR+ / rencana MALAM (mis. 12×1/4), saran "MALAM?" saat gelap (ISO×t >= 10), ikon kunci AE/AF,
  timer, EV.
- **Zoom** (melewati lensa optik): cara = Auto / Apple / Super Res (burst RAW + merge) / Crop penuh (1 foto
  48MP/12MP); **AI terpisah** (nyala/mati, model, fokus tulisan) bisa di atas cara mana pun. Apple + AI: hasil Apple
  diperkecil ke detail aslinya (sisi panjang sensor / crop) lalu diperbesar AI. AI ZOOM lama = Super Res/Crop + AI.
- **Auto**: HDR+ bila ISO×t >= 2 (redup), Apple bila terang atau Live / flash nyala; dipilih saat shutter.
- **MALAM**: shutter genggam 1/4 s (tele 1/8 s), HP diam (gyro < 0.02 rad/s ~1 s) sampai 1 s, ISO diturunkan
  (total eksposur sama), 6-15 frame (anggaran 3 s genggam / 6 s diam), develop dicerahkan maks +1 EV bila gelap;
  zoom selalu Super Res. Teks "MALAM: tahan HP ~N s".
- **Laci Pro** (ikon slider kanan bawah): EV · ISO · Shutter · WB · Fokus · Timer, penggaris + tombol A per
  bagian; manual per bagian (eksposur / WB / fokus terpisah), tetap terjaga saat ganti lensa & setelah burst.
- **Baris shutter**: thumbnail foto terakhir (ketuk = penampil layar penuh, cubit/ketuk 2x zoom, tombol buka Foto) ·
  shutter (bulan di MALAM) · balik kamera depan/belakang.
- Rasio: crop tengah untuk HEIF/JPEG (Apple, HDR+, zoom); RAW tetap 4:3; preview diberi masker.
- Live Photo: hanya foto Apple 12MP; dimatikan sementara saat capture lensa fisik (RAW/resolusi penuh).
- Nama file baru: MALAM_*, SUPERRES_*, CROPZOOM_*, APPLEZOOM_*.
- Build v0.10.0: run 43217992417 sukses -> `data/builds/BaginCam-v0.10.0-unsigned.ipa`.

## 2026-11-12 - Sesi 24: uji v0.10.0 -> v0.10.1

Sampel `data/bursts/dcim-1112-v0100/` (IMG_6929-6937), log `syslog_20261112-192918.txt`, `data/output/v0100_zoom.jpg`.
| foto | isi | hasil |
|---|---|---|
| 6929 | FOTO 13x zoom Apple (lensa Utama) | lembut, terbaca sebagian |
| 6930 | Apple + AI | **rusak**: diperkecil ke 621 px lalu AI -> huruf jadi balok |
| 6931 | Super Res 12 frame (Utama crop 13x, sumber 232x310) | buram |
| 6932 | Crop penuh Utama 48MP (620 px) | **tidak fokus** |
| 6933 | Crop penuh Tele dikunci + AI (crop 2.6x) | bagus, paragraf terbaca jujur |
| 6934-6937 | MALAM 12 x 1/4 s (ISO 3200-12500), 6937 rasio 16:9 (3213x5712 benar) | 6934 wajar; 6935-37 ruang tanpa lampu masih sangat gelap (+1 EV maks) |
- Penyebab 13x di lensa Utama: **bug** - saat app dibuka, `configure` hanya memasang kamera virtual untuk .aiZoom;
  HDR+/FOTO (mode awal) memasang lensa utama fisik -> tidak ada "pindah ke lensa fisik", zoom = crop utama, dan
  untuk Crop penuh zoom di-reset ke 1x tanpa waktu AF (0.3 s) -> buram.
- **Live tidak muncul**: tombol Live/flash hanya tampil bila proses Apple/Auto; proses pengguna HDR+ -> tersembunyi
  (log: semua `live false`).
- MALAM: HP tidak pernah terdeteksi diam (`diam false`).
- Fix v0.10.1:
  - kamera virtual dipasang saat app dibuka untuk semua mode virtual (HDR+/FOTO).
  - lensa terkunci: setelah zoom di-reset 1x, AF dipicu ulang di tengah + jeda 0.7 s.
  - Apple + AI: diperkecil ke 2x sensor/crop (mis. 1240 px di 13x utama), bukan 1x.
  - Live & flash selalu tampil di FOTO; bila nyala, jepretan memakai proses Apple (chip proses: "HDR+ → Apple"),
    lalu kembali ke proses pilihan.
  - MALAM: pencerahan maks +3 EV (target linear 0.16), genggam 4 s (15 x 1/4 s); deteksi diam dilonggarkan
    (gyro < 0.035 rad/s, 0.8 s) dan nilai gyro dicatat di log.
- Build v0.10.1: run 43221009152 sukses -> `data/builds/BaginCam-v0.10.1-unsigned.ipa`.

## 2026-11-12 - Sesi 25: v0.10.1 gagal dibuka -> v0.10.2

- Pengguna: app gagal dibuka. Crash report (`data/crash/20261112/BaginCam-2026-11-12-200357.ips`, juga v0.10.0
  19:40:29): EXC_BREAKPOINT di `CameraManager.nightPlan` <- `ContentView.framesText` <- `infoRow` (render UI).
- Penyebab: mode MALAM tersimpan (Prefs) -> saat dibuka UI langsung menghitung rencana MALAM dari nilai live
  kamera yang belum valid (shutter NaN/0) -> `Int(NaN)` trap. v0.10.0 juga crash 4x berturut-turut saat masuk MALAM.
- Fix v0.10.2: masukan nightPlan disaring (shutter/ISO/minISO NaN atau 0 -> nilai aman, frame dari n terbatas);
  nilai live (ISO, shutter, fokus, suhu WB) disaring isFinite di sumbernya (updateReadout).
- Build v0.10.2: run 43224020401 sukses -> `data/builds/BaginCam-v0.10.2-unsigned.ipa`.

## 2026-11-12 - Sesi 26: v0.11.0 - mode VIDEO ala Blackmagic Camera + GCam

Permintaan: fitur video seperti Blackmagic Camera, tambah H.265, campur fitur GCam, LUT bisa dibakar ke video.
Sela sesi: C: penuh (0,4 GB) -> gcam-taoyao (83,6 GB) & OpenColorLab (9,4 GB) dipindah ke D:\project (junction di
lokasi lama), C: kosong 95 GB, D: sisa 6 GB. Semua pekerjaan selanjutnya di D:\project.
- Mode strip: MALAM · FOTO · **VIDEO** · PRO. VIDEO = kamera virtual (lensa otomatis / kunci, flip depan).
- Perekam: `VideoRecorder.swift` (AVAssetWriter, input pixel buffer + audio AAC), file `Documents/Videos/BaginCam_<waktu>_<res><fps>_<codec>_<warna>.mov`,
  simpan ke Foto / Files (app) / keduanya.
- Pilihan (chip atas + Pengaturan > Video, tersimpan):
  - resolusi 4K / 1080p; fps Auto (GCam: 60 terang / 30 gelap, saat mulai rekam), 24/25/30/50/60,
    slow-mo 120/240 (diputar 24/30 fps, waktu diregangkan, tanpa suara), time-lapse 5/10/30/60/120x (diputar 30 fps).
  - codec HEVC (H.265) / H.264 / ProRes 422 HQ / 422 / LT / Proxy (H.264 + 10-bit -> HEVC).
  - warna Rec.709 / HDR HLG / Apple Log (format kamera 10-bit x420, activeColorSpace); preview Log dikonversi ke
    Rec.709 dengan cube 33^3 dari kurva Apple Log + matriks 2020->709 + tone map.
  - stabilisasi Mati / Standard / Cinematic / Cinematic Extended; shutter 180° otomatis (shutter 1/(2 fps), ISO
    mengikuti exposureTargetOffset, maks 1/3 EV per 0,25 s); laci Pro tetap untuk ISO/shutter/WB/fokus manual.
  - LUT: di preview, opsional dibakar ke file (render CI -> BGRA -> Rec.709; dari Log dikonversi dulu).
  - frame guide 2.39 / 1.85 / 16:9 / 4:3 / 1:1 / 9:16 (ikut orientasi HP), meter level mikrofon (dB), senter,
    timer rekam, sisa menit (dari ruang kosong & bitrate).
- Sesi: photo output dilepas saat VIDEO (format video bebas), mikrofon + audio output dipasang; keluar VIDEO =
  kembali preset .photo. Zoom video dibatasi zoom hardware (crop preview tidak ikut terekam).
- Build v0.11.0: run 43246034454 sukses -> `data/builds/BaginCam-v0.11.0-unsigned.ipa`. Belum diuji di HP.

## Sesi 27 — 2026-11-13 · v0.11.1 (perbaikan crash VIDEO)
- Keluhan: "eror" — v0.11.0 crash saat masuk VIDEO dan langsung crash lagi tiap dibuka (mode VIDEO tersimpan).
- Crash report: `data/crash/20261113/BaginCam-2026-11-13-032252.ips`, `...-032254.ips`
  - EXC_CRASH SIGABRT, NSException dari `-[AVCaptureFigVideoDevice setExposureModeCustomWithDuration:ISO:]`
    dipanggil `CameraManager.videoReadout()` (auto-ISO shutter 180°).
  - Penyebab: lensa Auto di VIDEO = kamera virtual (triple camera) yang tidak mendukung eksposur custom.
- Perbaikan (CameraManager.swift):
  - `videoReadout`: cek `isExposureModeSupported(.custom)`; bila tidak, 180° dilewati + status
    "180° aktif hanya bila lensa dikunci (UW/Utama/Tele)" (sekali per masuk VIDEO).
  - Durasi di-clamp dengan `CMTimeClampToRange` ke min/max format; fps minimal 1.
  - `supportsFps()` baru: fps harus masuk rentang format sebelum set `activeVideoMin/MaxFrameDuration`
    (dipakai di pickVideoFormat, applyVideoFormat, FPS Auto saat mulai rekam).
- Versi 0.11.1 (build 25). Build run 43300383606 sukses -> `data/builds/BaginCam-v0.11.1-unsigned.ipa`.

## Sesi 28 — 2026-11-13 · v0.12.0 (zoom video: native, halus, tajam, peaking/zebra, AI Upscale)
- Permintaan: "menu video bisa ditambah zoom AI agar lebih bagus?" -> AI real-time tidak mungkin (~1-10 s/frame),
  dipilih user: (1) titik zoom native + tajam, (2) peaking/zebra/zoom halus, (3) AI Upscale setelah rekam.
- CameraManager.swift:
  - `updateNativePoints()`: titik tanpa crop digital = basis tiap lensa + `secondaryNativeResolutionZoomFactors`
    format yang sama di tiap lensa (mis. 2x crop sensor 48 MP). Log "VIDEO: titik zoom native [...]".
  - `setTotalZoom` di video: menempel ke titik native (<3 %), zoom halus `ramp(toVideoZoomFactor:withRate:)`
    (Mati/Lambat 0.6/Sedang 1.6/Cepat 4 pangkat-2 per detik).
  - `updateZoomQuality()`: label "Native" / "Digital 1.4x" + kekuatan penajaman 0.25..0.9 (preview + rekaman).
  - Mulai rekam: lensa Auto + 180° -> kunci otomatis ke lensa aktif (kembali Auto setelah selesai);
    tanpa kunci: switching `.restricted [.videoZoomChanged]` selama rekam (lensa tidak lompat karena cahaya/fokus).
  - Fix: kembali ke Auto di video kini memasang ulang format video.
- VideoRecorder.swift: enum `SmoothZoom`; `sharpen` (CISharpenLuminance r=1.6) untuk keluaran 8-bit
  (Rec.709 tanpa manajemen warna / setelah LUT); HLG & Log 10-bit tidak disentuh.
- PreviewRenderer.swift: penajaman sama dengan rekaman, warna peaking bisa dipilih.
- ContentView.swift: chip bantuan bidik (peaking 5 warna, zebra 70-100 %), chip ✨ AI, preset zoom video dari
  titik native (tanda ✦), pill kualitas zoom; zebra/peaking kini tersimpan (@AppStorage).
- VideoUpscaler.swift (baru): AI Upscale video (PhotosPicker / Files app) -> Real-ESRGAN per frame,
  Perbesar 2x (maks 4K) / Pertajam, kekuatan, "kurangi kedip" (detail AI dirata-rata dgn frame sebelumnya di area
  diam, mask selisih luminans), HLG -> Rec.709 lewat video composition, Apple Log ditolak, audio disalin,
  HEVC, simpan Foto/Files, perkiraan waktu, batal. Kamera dihentikan selama proses.
- SettingsSheet.swift: Zoom halus, Tajamkan zoom digital, Kunci lensa otomatis saat rekam.
- Versi 0.12.0 (build 26). Build run 43340922805 sukses -> `data/builds/BaginCam-v0.12.0-unsigned.ipa`. Belum diuji di HP.

## Sesi 29 — 2026-11-13 · v0.12.1 (video terbakar, panas, tombol AI, HDR+ 2x)
- Keluhan: (1) tombol on/off AI di video tidak ada, (2) rekaman terbakar/terlalu cerah, (3) HDR+ 2x aneh,
  (4) suhu langsung naik saat rekam.
- Data: DCIM IMG_6948-6960 -> `data/bursts/dcim-1113-v012/`, preview & crop -> `data/output/v0120/`.
  Log `data/logs/syslog_20261113-075833.txt` (filter -pn BaginCam) hanya 08:03-08:08 (tes setelahnya tidak terekam).
  Log 1.2 GB tanpa filter dari sesi 27 dihapus (disisakan baris BaginCam: `syslog_20261113-032904_bagincam.txt`).
- (2) IMG_6948-6951 (1080p HEVC 709): rata-rata luma 217-236/255, **60-76 % piksel putih**, gerak buram.
  Penyebab: saat rekam lensa dikunci otomatis -> 180° memaksa 1/60 s di siang terik; ISO sudah minimum 54 ->
  lebih ~5 stop. Fix: 180° dihitung dari "jumlah cahaya" ISO x t; bila ISO minimum masih terlalu terang shutter
  dipercepat (status + pill "ND"). Log "VIDEO: terlalu terang untuk 180°".
- (4) Preview menjalankan LUT/histogram/peaking/zebra di frame 4K penuh 30x/detik. Fix: frame diperkecil ke ukuran
  layar dulu (`highQualityDownsample`), baru filter. Pill suhu "Panas/Kritis" (ProcessInfo.thermalState) + log.
  Catatan: rekam 4K di bawah matahari langsung tetap membuat HP panas (encoder + sensor + layar).
- (1) Chip ✨ AI ada di ujung kanan bar chip (harus digeser). Fix: chip dipindah ke depan jadi menu
  "AI setelah rekam" (nyala/mati) + "Buka AI Upscale", plus tombol AI di baris zoom video. AI setelah rekam: file
  asli ditahan, layar AI Upscale terbuka otomatis dengan video itu; salinan dihapus saat ditutup (simpan ke Foto).
- (3) IMG_6958 (HDR+ 6 frame, DNG IMG_6957 = 1x penuh 4032x3024) -> crop 2x hanya ~2016 px lalu AI 2.8x ->
  tekstur seperti lukisan, huruf "U" berubah. Fix: Super Res di lensa utama < 3x saat terang (ISO x t < 0.25)
  -> Crop penuh sensor 48 MP (detail asli 2x lipat). Log "Super Res -> Crop penuh 48MP".
- Titik zoom native: 0.89 (crop UW tepat sebelum 1x) dibuang (titik < 85 % titik berikutnya).
- Versi 0.12.1 (build 27). Build run 43373476177 sukses -> `data/builds/BaginCam-v0.12.1-unsigned.ipa`. Belum diuji di HP.

## Sesi 30 — 2026-11-13 · v0.12.2 (pilihan AI Upscale diingat, video 720p)
- Keluhan: "pilihan AI tidak bisa disimpan". Penyebab: `VideoUpscaleView` memakai `@State UpscaleOptions()` dan
  onAppear menimpa model/simpan-ke -> cara, model, kekuatan, kurangi kedip, simpan-ke kembali ke bawaan tiap layar dibuka.
  Fix: `UpscaleOptions.load()/store()` (UserDefaults: upModel, upMode, upStrength, upStabilize, upSaveTo), disimpan
  tiap pilihan berubah. (Toggle "AI setelah rekam" sudah tersimpan sejak v0.12.1.)
- Permintaan: resolusi video 720p. `VideoRes.hd` (1280x720), bitrate HEVC 8 / H.264 12 Mbps @30, ProRes x0.111,
  nama file "720p". Bila lensa/warna tidak punya format 720p -> otomatis 1080p (status "720p tidak tersedia...").
- Log syslog (filter -pn BaginCam) baru: `data/logs/syslog_20261113-140001.txt` (yang 124138 kosong, dihapus).
- Versi 0.12.2 (build 28). Build run 43382529510 sukses -> `data/builds/BaginCam-v0.12.2-unsigned.ipa`. Belum diuji di HP.

## Sesi 31 — 2026-11-13 · v0.12.3 (AI Upscale bisa dijeda & dilanjutkan)
- "cek" v0.12.2: DCIM IMG_6961-6980 -> `data/bursts/dcim-1113-v0122/` (6980 = screenshot game, bukan app).
  Tidak ada crash baru. Log `data/logs/syslog_20261113-140001.txt`.
- 720p jalan: IMG_6977/6978 720x1280 HEVC ~8 Mbps. Kecerahan video normal (luma 114-135, clip 0-0.3 %) ->
  fix "terbakar" v0.12.1 berhasil. Rekam 14:05:05 lensa dikunci otomatis ke UW (kamera virtual sedang pakai UW
  untuk jarak dekat/makro) -> zoom 1x = crop UW 2x.
- AI Upscale: 1080p 27.9 s (838 frame) mode Pertajam, model Cepat = 45 tile/frame ~1.35-1.6 s/frame
  (melambat ke 2.6-3.5 s saat panas) -> perkiraan ~20 menit. App ditinggal setelah ~20 frame (14:07:52) ->
  proses mati, file `..._AIsharp_C.mov` 1.4 MB tanpa moov (rusak), tidak ada yang tersimpan.
- Fix v0.12.3: pekerjaan AI = `Documents/AIJob/job.json` + potongan video (seg*.mov). Saat app ditinggal
  (willResignActive) proses dijeda, potongan disimpan (background task), lanjut otomatis saat kembali; bila app
  sempat dimatikan iOS -> bagian "Belum selesai" dengan Lanjutkan/Buang. Reader mulai dari `nextTime`.
  Selesai -> potongan digabung + audio asli (AVMutableComposition, ekspor passthrough). Video galeri dipindah ke
  folder AIJob agar tidak hilang. Hasil AI rusak lama (tidak bisa diputar) di Videos dihapus otomatis.
  Tombol Batal -> Jeda.
- Versi 0.12.3 (build 29). Build run 43386786395 sukses -> `data/builds/BaginCam-v0.12.3-unsigned.ipa`. Belum diuji di HP.

## Sesi 32 — 2026-11-13 · v0.12.4 (UI video dikelompokkan, timer, lensa Auto saat rekam)
- Keluhan: 720p "hanya di Ultra Wide"; saat rekam lensa Auto tidak bisa pindah; UI video susah; timer belum muncul.
- Analisis log 14:05: 720p ada di semua lensa (Auto/virtual, Utama, UW). Yang terjadi: "kunci lensa otomatis saat
  rekam" (bawaan nyala sejak v0.12.0, agar 180° jalan) mengunci ke lensa yang sedang aktif saat tombol rekam
  ditekan; kamera virtual sedang memakai UW (subjek dekat) -> rekaman terkunci di UW.
- Fix: pref baru `lockLensOnRecord2` bawaan MATI -> Auto tetap kamera virtual saat rekam, pindah lensa lewat tombol
  zoom (.5/1/2/5, switching .restricted [videoZoomChanged]). Tombol kunci lensa dinonaktifkan selama rekam
  (+ teks "ganti lensa: tombol zoom"). 180° hanya aktif bila lensa dikunci manual / opsi di Pengaturan dinyalakan.
- Timer: `shutterPressed` di VIDEO langsung rekam (timer 3/10 s diabaikan). Fix: hitung mundur juga untuk mulai
  rekam; tekan lagi saat hitung mundur = batal. Pill jam timer di baris info video.
- UI video: 10 chip -> 6: Format (submenu Resolusi / Frame rate / Time-lapse / Codec / Warna / Stabilisasi, label
  "1080p · 30 · HEVC · 709"), LUT, WB, Bantu (peaking, zebra, garis bingkai, grid, waterpass, histogram), AI, senter.
  Timer rekam besar di tengah atas (merah saat rekam, 00:00 saat siap). Baris info jadi 2 baris; histogram turun.
  Tombol AI dobel di baris zoom dihapus (sudah di chip AI).
- Versi 0.12.4 (build 30). Build run 43392967378 sukses -> `data/builds/BaginCam-v0.12.4-unsigned.ipa`. Belum diuji di HP.

## Sesi 33 — 2026-11-13 · v0.13.0 (AI Komposisi "Susun ulang")
- Permintaan: AI komposisi foto seperti video Shorts "Si paling jago framing" (Sobat HAPE) - file pengguna
  `C:\Users\ASUS\Downloads\Si paling jago framing.mp4` (frame contoh di scratchpad, tidak disalin ke proyek).
  Isinya OPPO Find X10 "Susun ulang": tombol di preview -> pindai (bingkai pelangi, "jaga perangkat agar tidak
  goyang") -> bingkai saran bercahaya + titik oranye + "Pindahkan ponsel ke posisi yang disarankan" + 1-2 thumbnail
  pilihan -> zoom otomatis (1.4x/1.6x/2.8x) -> jepret. Keterangan adegan di atas (VLM).
- Pilihan pengguna: kotak target + panah, auto zoom/crop saran, petunjuk pose/lurus, crop ulang setelah jepret,
  + tombol on/off.
- CompositionAI.swift (baru, offline Vision): wajah (VNDetectFaceRectangles) + badan (VNDetectHumanRectangles) +
  saliency (attention). Komposisi: mata di sepertiga atas, subjek muat + margin, sepertiga horizontal (penalti
  tengah), objek di titik sepertiga. 3 varian: Sepertiga / Dekat (kepala-dada) / Lebar (tanpa zoom), duplikat
  dibuang, thumbnail dari frame pindai. Keterangan adegan dari VNClassifyImageRequest (label -> Indonesia).
  Panduan ~4x/detik, dihaluskan (EMA), titik oranye + lingkaran tengah, "Pas! Jepret" (bingkai hijau).
  Zoom otomatis saat posisi pas (setTotalZoom x saran, maks 2x dari zoom sekarang). Tanpa Susun ulang: petunjuk
  ringan "Kepala terpotong" / "Ruang di atas kepala terlalu banyak".
- Setelah jepret (HEIC/JPG, bukan video): versi kedua `<nama>_CROP.heic` = horizon diluruskan (VNDetectHorizon
  0.7-8°) + crop komposisi (maks 1.6x). Foto asli tetap. Log "Komposisi: ..._CROP.heic".
- UI: chip "Komposisi" di FOTO (on/off AI Komposisi, on/off versi crop, Susun ulang sekarang); tombol
  "Susun ulang" di kanan bawah preview. Prefs compAI / compCrop (bawaan nyala).
- PreviewRenderer.onAnalysis: frame ukuran layar sebelum LUT tiap 8 frame. onChange komposisi dipindah ke
  ViewModifier CompHooks (build pertama gagal: body ContentView "unable to type-check in reasonable time").
- Versi 0.13.0 (build 31). Build run 43396019918 sukses -> `data/builds/BaginCam-v0.13.0-unsigned.ipa`
  (run 43395628709 gagal type-check). Belum diuji di HP. Termasuk perubahan v0.12.4.
