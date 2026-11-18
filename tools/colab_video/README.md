# AI pertajam video di Google Colab

Proses video berat (AI pertajam / perbesar) di GPU Google Colab, bukan di iPhone. Google Drive dipakai sebagai kotak surat:

```
iPhone --(Files / Google Drive)--> Drive/BaginCam/masuk --> Colab (GPU T4) --> Drive/BaginCam/selesai --> iPhone
```

Buka notebook langsung dari GitHub (bisa di browser iPhone atau laptop):
https://colab.research.google.com/github/bagindev/BaginCam/blob/main/tools/colab_video/BaginCam_AI_video.ipynb

Langkah pakai ada di sel pertama notebook. Ringkasnya:
1. Taruh video di `BaginCam/masuk`.
2. Pastikan runtime memakai T4 GPU.
3. Pilih **Run all**.
4. Ambil hasilnya dari `BaginCam/selesai`.

## File

| File | Isi |
|---|---|
| `bagincam_ai_video.py` | Seluruh pemroses: arsitektur model, ffmpeg decode/encode, pemotongan video, dan antrean folder. Bisa dijalankan lokal untuk uji (CPU). |
| `make_notebook.py` | Membangun `BaginCam_AI_video.ipynb` dengan menyalin `bagincam_ai_video.py` utuh. **Jalankan lagi setiap kali .py diubah.** |
| `BaginCam_AI_video.ipynb` | Notebook Colab dengan empat sel: penjelasan, pengaturan, kode, jalankan. |

## Model

Bobot diunduh dari rilis resminya dan hash SHA-256 dicek. Arsitektur ditulis ulang identik dengan mmagic/basicsr, jadi tidak perlu mmcv/basicsr.

| Kunci | Model | Catatan |
|---|---|---|
| `vsr` (bawaan) | RealBasicVSR | Model video: aliran optik SPyNet plus propagasi maju-mundur, sehingga detail stabil dan tidak berkedip. Video dipotong per 10–40 frame (sesuai memori GPU) dengan tumpang tindih 4 frame yang dicampur linear. Jumlah putaran pembersih dikunci per video. |
| `cepat` | Real-ESRGAN general-x4v3 | Sama dengan model "Cepat" di app. Diproses per frame plus kurangi kedip. |
| `detail` | Real-ESRGAN x4plus | Sama dengan model "Detail" di app. Diproses per frame plus kurangi kedip. |

Rumus hasil: `asli + kekuatan × (AI − asli)`.

Mode:
- **pertajam**: resolusi tetap.
- **perbesar**: 2x, maksimal 4K.

`INPUT_MAKS` adalah sisi panjang gambar yang dibaca AI. Nilai ini menentukan kecepatan.

Encode memakai HEVC 10-bit (NVENC kalau tersedia, kalau tidak libx265). Yang disalin dari file asli:
- audio pertama;
- metadata (tanggal, lokasi);
- tag warna (SDR Rec.709 / HDR HLG).

## Uji lokal (CPU, lambat)

```
python bagincam_ai_video.py MASUK SELESAI --model vsr --input 270 --test-seconds 0.5 --chunk 8 --weights DIR_BOBOT --ffmpeg PATH_FFMPEG
```

Hasil uji 18 Nov 2026 (lihat LOG.md):
- Pita kepala sama dengan versi utuh (selisih 4e-7).
- Rekonstruksi 4x dari 135 px masuk akal.
- Tidak ada lompatan di sambungan potongan.
- Tag warna dan audio terbawa.
