# ModKamera (iOS) - v0.1

App kamera iPhone 16 Pro Max: preview LUT live, kontrol manual, burst RAW untuk HDR+ di PC.

## Fitur v0.1
- Preview **LUT live** (Core Image + Metal). Bawaan: `SonyLook_v0.1_SOFT/STANDARD/STRONG` (OpenColorLab,
  input iPhone stock Rec.709). Import `.cube` sendiri dari Files.
- **Manual**: ISO, shutter (skala log), WB (Kelvin), fokus. Mode Auto = AE/AWB/AF kontinu.
- **Burst** 1-16 frame, AE/AWB/AF otomatis dikunci selama burst.
- Format: **Bayer RAW** (DNG sensor asli, cocok untuk `pc-lab/burst_merge.py`), **ProRAW**, HEIF.
- Simpan ke **Photos** + `Documents/Bursts/<tanggal-jam>/` (bisa dilihat di Files app / Apple Devices).
- Log `os.Logger` subsystem `dev.modkamera.app` -> baca di Windows: `python pc-lab\iphone_syslog.py --proses ModKamera`.

## Build (tanpa Mac)
GitHub Actions `.github/workflows/ios-build.yml`: XcodeGen -> xcodebuild (tanpa signing) -> artifact
`ModKamera-ipa` berisi `ModKamera-unsigned.ipa`.

## Pasang di iPhone (Apple ID gratis)
1. Download artifact dari tab Actions (atau `gh run download`), ekstrak `.ipa`.
2. Sideloadly (Windows) -> pilih `.ipa`, isi Apple ID -> Start.
3. iPhone: Settings > General > VPN & Device Management -> trust profil Apple ID.
4. iOS 16+: aktifkan **Developer Mode** (Settings > Privacy & Security > Developer Mode) lalu restart.
5. Re-sign ulang tiap 7 hari (Sideloadly bisa auto-refresh bila PC & iPhone satu Wi-Fi).

## Struktur
| File | Isi |
|---|---|
| `project.yml` | spesifikasi XcodeGen (iOS 17+, bundle `dev.modkamera.app`) |
| `ModKamera/CameraManager.swift` | AVCaptureSession, manual exposure/WB/fokus, burst RAW, simpan |
| `ModKamera/PreviewRenderer.swift` | MTKView + Core Image, LUT di GPU |
| `ModKamera/CubeLUT.swift` | parser `.cube` + library LUT (bawaan + import) |
| `ModKamera/ContentView.swift` | UI SwiftUI |
| `ModKamera/LUTs/` | LUT bawaan |

## Belum ada (rencana)
- Ganti lensa (0.5x / 5x), histogram, focus peaking, zebra.
- Port align+merge Metal (hdr-plus-swift) -> HDR+ langsung di HP.
- AI zoom / super-resolution (Core ML).
