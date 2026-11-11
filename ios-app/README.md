# BaginCam (iOS) - v0.1

App kamera iPhone 16 Pro Max: preview LUT live, kontrol manual, burst RAW untuk HDR+ di PC.

## Fitur (v0.4.0)
- Mode: **HDR+** (burst Bayer RAW -> align + robust merge di GPU -> 1 DNG), **Bayer RAW**, **ProRAW**,
  **HEIF**, **AI Zoom** (crop resolusi penuh + super-resolution x4 Core ML).
- Lensa 0.5x / 1x / 5x, opsi 48MP (HEIF/ProRAW).
- Preview **LUT live**: `SonyLook_v0.1_SOFT/STANDARD/STRONG` (OpenColorLab) + import `.cube`.
- Bantu exposure/fokus: **histogram**, **zebra** (>95 %), **focus peaking**.
- Manual ISO / shutter (log) / WB (K) / fokus; burst 2-16 frame dengan kunci AE/AWB/AF.
- Simpan ke **Photos** + `Documents/Bursts/<MODE>_<tanggal-jam>/`.
- Log `os.Logger` subsystem `dev.bagincam.app` (kategori camera, lut, hdrplus, aizoom).

## Build (tanpa Mac)
GitHub Actions `.github/workflows/ios-build.yml`: XcodeGen -> xcodebuild (tanpa signing) -> artifact
`BaginCam-ipa` berisi `BaginCam-unsigned.ipa`.

## Pasang di iPhone (Apple ID gratis)
1. Download artifact dari tab Actions (atau `gh run download`), ekstrak `.ipa`.
2. Sideloadly (Windows) -> pilih `.ipa`, isi Apple ID -> Start.
3. iPhone: Settings > General > VPN & Device Management -> trust profil Apple ID.
4. iOS 16+: aktifkan **Developer Mode** (Settings > Privacy & Security > Developer Mode) lalu restart.
5. Re-sign ulang tiap 7 hari (Sideloadly bisa auto-refresh bila PC & iPhone satu Wi-Fi).

## Struktur
| File | Isi |
|---|---|
| `project.yml` | spesifikasi XcodeGen (iOS 17+, bundle `dev.bagincam.app`) |
| `BaginCam/CameraManager.swift` | session, lensa, manual, burst, HDR+ / AI Zoom pipeline, simpan |
| `BaginCam/PreviewRenderer.swift` | MTKView + Core Image: zoom, LUT, peaking, zebra, histogram |
| `BaginCam/HDRPlus.metal` + `HDRPlusMerger.swift` | align + robust merge Bayer di GPU, tulis DNG |
| `BaginCam/SRUpscaler.swift` + `Models/` | AI Zoom Core ML (Real-ESRGAN x4v3, BSD-3) |
| `BaginCam/CubeLUT.swift` | parser `.cube` + library LUT (bawaan + import) |
| `BaginCam/ContentView.swift` | UI SwiftUI |
| `BaginCam/LUTs/` | LUT bawaan |

## Belum ada (rencana)
- Align sub-piksel + merge domain frekuensi (kualitas HDR+ lebih tinggi, penolakan lebih sedikit).
- Multi-frame super-resolution (pakai goyangan tangan) untuk AI Zoom.
- Video / Apple Log + LUT.
