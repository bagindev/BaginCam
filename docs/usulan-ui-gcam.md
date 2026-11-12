# Usulan UI BaginCam ala GCam (2026-11-12)

Sumber: screenshot AGC 9.4 / 9.6 di `Documents\gcam-taoyao\data-hp\screens\` dan `foto-uji\...` (viewfinder Photo,
Night Sight, laci Pro, halaman Camera settings).

## Prinsip GCam yang dipelajari

1. **Mode = niat memotret, bukan mesin proses.** Carousel GCam: Portrait · Photo · Night Sight · Panorama ...
   HDR+ tidak pernah jadi mode: ia *selalu* jalan di Photo. Super Res Zoom juga otomatis saat zoom.
2. **Night Sight dipisah** karena perilaku capture-nya beda (eksposur panjang, "tahan HP"), dan GCam
   menyarankannya otomatis (ikon bintang "A" di kiri atas) saat gelap.
3. **Tombol cepat di atas** (chip bulat): LUT (Leica), AWB, profil Lib, config. Hal yang sering diganti, satu tap.
4. **Zoom chip horizontal di atas shutter** (.6 / 1x / 2), lensa per-aux di kolom kanan.
5. **Baris shutter tetap**: thumbnail foto terakhir · shutter (ikon ikut mode) · balik kamera.
6. **Kontrol manual di laci bawah** (ikon slider kanan bawah): Exposure · Focus · Shutter speed · ISO · WB,
   masing-masing membuka satu penggaris (ruler) di atas shutter. Bar info atas: lensa, fokus, 1/19s, ISO.
7. **Settings berkelompok jelas**: Global · Custom (per lensa, image processing, file) · General · Composition
   (grid, framing hints) · Manual controls · Photo (resolusi) · Video · Help.

## Masalah BaginCam sekarang

- 5 mode (AI ZOOM · HDR+ · FOTO · PRORAW · BAYER) bercampur antara *niat* (zoom), *mesin* (HDR+ vs Apple) dan
  *format file* (ProRAW / Bayer). Sejak v0.9.4 FOTO, HDR+ dan AI ZOOM memakai lensa & zoom yang sama.
- Pengaturan penting (proses, AI, format) tersembunyi di sheet; chip ringkasan atas sulit dibaca.

## Usulan susunan

```
 ┌──────────────────────────────────────────┐
 │ (★A)        [HDR+] [LUT] [WB] [24MP·HEIF]⚙│  <- chip cepat (tap = ganti / buka pilihan)
 │ Tele 5x · crop 2.6x · AI   1/30  ISO 640  │  <- bar info (lensa aktif, AI aktif, exp)
 │                                           │
 │                 preview                   │      kolom kanan: kunci lensa
 │                                         A │      A(uto) / UW / 1x / 5x
 │                                        UW │
 │                                        1x │
 │                                        5x │
 │        ( .5 · 1 · 2 · 5 · 10 · 25 )       │  <- zoom chip; geser = slider log
 │   [penggaris EV / fokus / ISO bila dibuka]│
 │                                           │
 │   [thumb]        ( SHUTTER )       [⟲]   │  <- thumb = buka hasil terakhir di app
 │                                           │
 │        MALAM ·  FOTO  · PRO               │  <- mode = niat
 │   ⚙                                [🎚]   │  <- laci Pro: EV·Fokus·Shutter·ISO·WB·Timer
 └──────────────────────────────────────────┘
```

| Sekarang | Usulan |
|---|---|
| HDR+ (mode) | **FOTO** dengan proses HDR+ (default, seperti GCam) |
| FOTO (Apple) | chip proses di FOTO: **HDR+ / Apple / Auto** |
| AI ZOOM (mode) | otomatis di FOTO saat zoom melewati lensa (seperti Super Res Zoom); chip "AI" di bar info, on/off + model di chip/Settings |
| PRORAW, BAYER (mode) | **PRO**: manual penuh + chip format RAW (ProRAW / Bayer DNG / tanpa RAW) |
| (belum ada) | **MALAM** (opsional): HDR+ dengan frame lebih panjang (mis. 1/8-1/4 s x 6-8), hitung mundur "tahan HP", saran otomatis ★A saat gelap |
| tombol Manual | laci Pro 🎚 (juga tersedia di FOTO untuk EV / kunci fokus / WB) |

Settings dikelompokkan ulang: **Foto** (resolusi, format, bake LUT) · **Proses HDR+** (NR, metode merge, frame) ·
**Zoom & AI** (model, kekuatan, fokus tulisan, multi-frame) · **Bantuan bidik** (grid, level, histogram, zebra,
peaking) · **Tombol** (volume = shutter, timer) · **Info**.

## Saran tambahan

- **Badge proses** seperti ShotBadge di GCam taoyao: "Memproses... jangan keluar" lalu centang "Tersimpan".
- **Thumbnail** hasil terakhir + penampil di dalam app (lihat hasil AI tanpa buka Galeri; iOS tidak bisa membuka
  foto tertentu di app Foto).
- **Auto**: HDR+ saat gelap / zoom melewati lensa / ada wajah backlit, Apple saat terang & 1x (instan).
- Haptic saat ganti lensa; semua kontrol di separuh bawah (satu tangan).
- Tidak bisa: Night Mode Apple (tidak dibuka untuk app pihak ketiga); Portrait bokeh mungkin nanti (depth data).

## Inventaris fitur yang sudah berjalan (v0.9.6)

### Mesin proses
| Proses | Cara kerja | Dipakai di |
|---|---|---|
| HDR+ BaginCam | burst Bayer RAW 6-15 frame -> align piramida (tile 16) -> merge GPU (Frekuensi/Spasial) -> DNG sendiri -> develop RAW Apple (lindung highlight, tone map lokal, metering zoom/wajah) | mode HDR+, AI ZOOM (MF) |
| Apple (Smart HDR / Deep Fusion) | 1 jepretan diproses Apple | mode FOTO |
| Apple ProRAW | DNG komputasional Apple 12/24/48MP | mode PRORAW |
| Bayer mentah | DNG per frame tanpa proses | mode BAYER (untuk PC) |

### Pembesaran saat zoom melewati lensa optik
Apple digital zoom (FOTO, AI mati) · Lanczos/tanpa AI (HDR+, AI mati) · AI Cepat (x4v3, ~1.4 s) · AI Detail
(x4plus, ~10 s/12MP) · Multi-frame + AI (AI ZOOM, tele atau crop >= 3x) · Fokus tulisan (OCR per paragraf).
Semua AI di Neural Engine; kekuatan AI 0-100 % (campuran dengan Lanczos).

### Opsi per mode (sekarang)
- HDR+: format HEIF/JPEG/DNG/DNG+HEIF, resolusi 12/24/48MP, frame otomatis atau 2-16, simpan frame mentah, bake LUT,
  metode merge, NR 1-23, AI saat zoom + model + kekuatan + fokus tulisan.
- FOTO: resolusi, AI saat zoom digital + model + kekuatan + fokus tulisan, bake LUT.
- AI ZOOM: model, kekuatan, multi-frame, fokus tulisan, resolusi, bake LUT.
- PRORAW: resolusi, jumlah frame. BAYER: jumlah frame. Keduanya: pilih lensa fisik UW/Utama/Tele/Depan.
- Semua: WB preset (Auto/Cerah/Berawan/Teduh/Pijar/Neon/Kunci), timer 0/3/10, tombol volume, panel Manual (Auto,
  EV, ISO, shutter, suhu WB, fokus), ketuk fokus / tekan lama kunci AE/AF, LUT (3 SonyLook + import .cube).
- Zoom: preset .5/1/2/5/10/25/50, slider log, maks 50x, kunci lensa Auto/UW/Utama/Tele/Depan, badge lensa (oranye
  bila crop), preview dibekukan saat capture.
- Bantuan bidik: histogram, zebra, peaking, grid 3x3, waterpass, readout ISO/shutter/K/fokus.

## Status: diterapkan di v0.10.0 (2026-11-12)
Lihat LOG.md sesi 23. Tambahan dari pengguna: cara zoom (Auto / Apple / Super Res / Crop penuh) dan AI dipisah.
Saran metode lanjutan (belum dibuat): Super Res Zoom sub-piksel sejati (prototipe pc-lab/mfsr.py: lebih bersih,
belum lebih tajam), penajaman adaptif tanpa AI (anti-halusinasi), AI pada RAW sebelum demosaic, gabung tele + utama.
