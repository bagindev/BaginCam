# BaginCam - app kamera iPhone 16 Pro Max "ala GCam"

App kamera iOS buatan sendiri: kontrol manual, preview LUT live (Sony-look dari OpenColorLab),
ProRAW / Apple Log, stacking burst ala HDR+, lalu AI zoom / super-resolution.

Riwayat & hasil kerja: **[LOG.md](LOG.md)**

## Struktur
| Folder | Isi |
|---|---|
| `pc-lab/` | Eksperimen di PC Windows (Python). `burst_merge.py`, `test_synthetic.py`, venv `.venv` |
| `third_party/hdr-plus-pytorch` | HDR+ PyTorch (MIT) - dipakai pc-lab |
| `third_party/hdr-plus-swift` | Burst Photo, Swift/Metal (GPL-3.0) - referensi untuk port ke iOS |
| `data/bursts/` | Burst RAW input, satu subfolder per set |
| `data/output/` | Hasil merge |
| `docs/` | Panduan (`panduan-capture-burst.md`) |
| `ios-app/` | (Langkah 2, belum dibuat) proyek Xcode + workflow GitHub Actions |

## Tahapan
1. **PC lab** - align+merge di PC, tuning parameter dengan burst dari iPhone. *(sedang berjalan)*
2. Kerangka app iOS (AVCam + LUT live via Metal), build GitHub Actions, install Sideloadly.
3. Port align/merge Metal dari hdr-plus-swift.
4. AI zoom: multi-frame super-res + model Core ML.

## Lisensi
Kode dari hdr-plus-swift = GPL-3.0: aman untuk pemakaian pribadi; kalau app dibagikan, seluruh kode wajib GPL.
