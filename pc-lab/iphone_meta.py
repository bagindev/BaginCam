"""
iphone_meta.py - Baca metadata kamera iPhone (EXIF + Apple MakerNote) per frame via ExifTool,
lalu cek konsistensi burst: exposure terkunci? fokus sama? HP bergerak?

Contoh:
  python iphone_meta.py D:\\project\\ios\\mod-Kamera\\data\\bursts\\iphone-20261111-setA
Output: tabel di layar + <folder>\\_meta.csv
"""
import csv
import io
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np

FIELDS = ["FileName", "ISO", "ExposureTime", "BrightnessValue", "ExposureCompensation",
          "Apple:AETarget", "Apple:AEAverage", "Apple:AEStable", "Apple:AFStable",
          "Apple:FocusPosition", "Apple:FocusDistanceRange", "Apple:ColorTemperature",
          "Apple:SignalToNoiseRatio", "Apple:HDRGain", "Apple:HDRHeadroom",
          "Apple:AccelerationVector", "Apple:ImageCaptureType", "Apple:CameraType", "Apple:RunTimeValue"]


def find_exiftool():
    p = shutil.which("exiftool")
    if p:
        return p
    cand = Path.home() / "AppData/Local/Programs/ExifTool/ExifTool.exe"
    if cand.exists():
        return str(cand)
    sys.exit("ExifTool tidak ditemukan (winget install OliverBetz.ExifTool)")


def read_meta(folder):
    files = sorted(list(folder.glob("*.DNG")) + list(folder.glob("*.dng")) + list(folder.glob("*.HEIC")))
    files = list(dict.fromkeys(files))
    cmd = [find_exiftool(), "-csv", "-n"] + [f"-{f}" for f in FIELDS] + [str(f) for f in files]
    out = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8").stdout
    return list(csv.DictReader(io.StringIO(out)))


def main():
    folder = Path(sys.argv[1])
    rows = read_meta(folder)
    if not rows:
        sys.exit("tidak ada file")
    t0 = float(rows[0].get("RunTimeValue") or 0)
    acc0 = None
    print(f"{'file':14s} {'ISO':>5s} {'shutter':>8s} {'BV':>6s} {'AEavg':>5s} {'fokus':>5s} {'K':>5s} "
          f"{'SNR':>6s} {'HDRgain':>7s} {'t(s)':>6s} {'gerak':>6s}")
    for r in rows:
        acc = np.array([float(v) for v in (r.get("AccelerationVector") or "0 0 0").split()])
        acc0 = acc if acc0 is None else acc0
        tilt = np.degrees(np.arccos(np.clip(np.dot(acc, acc0) / (np.linalg.norm(acc) * np.linalg.norm(acc0) + 1e-9), -1, 1)))
        dt = (float(r.get("RunTimeValue") or 0) - t0) / 1e9
        sh = float(r.get("ExposureTime") or 0)
        print(f"{r['FileName']:14s} {r.get('ISO', ''):>5s} {'1/' + str(round(1 / sh)) if sh else '-':>8s} "
              f"{float(r.get('BrightnessValue') or 0):6.2f} {r.get('AEAverage', ''):>5s} {r.get('FocusPosition', ''):>5s} "
              f"{r.get('ColorTemperature', ''):>5s} {float(r.get('SignalToNoiseRatio') or 0):6.2f} "
              f"{float(r.get('HDRGain') or 0):7.3f} {dt:6.2f} {tilt:5.2f}°")
    # ringkasan konsistensi
    def uniq(k):
        return sorted({r.get(k, "") for r in rows})
    print("\nRingkasan:")
    print("  ISO unik         :", uniq("ISO"), "  shutter unik:", uniq("ExposureTime"))
    print("  fokus unik       :", uniq("FocusPosition"), "  suhu warna unik:", uniq("ColorTemperature"))
    print("  AE terkunci?     :", "YA" if len(uniq("ISO")) == 1 and len(uniq("ExposureTime")) == 1 else "TIDAK (exposure berubah antar frame)")
    print("  jenis capture    :", uniq("ImageCaptureType"), " kamera:", uniq("CameraType"))
    out = folder / "_meta.csv"
    with open(out, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    print("  csv              :", out)


if __name__ == "__main__":
    main()
