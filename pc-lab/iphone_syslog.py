"""
iphone_syslog.py - Rekam syslog live iPhone via USB (pymobiledevice3), difilter untuk proses kamera.

Dipakai untuk:
  1. Mengintip pipeline kamera Apple saat memotret (cameracaptured, mediaserverd, Camera, ...).
  2. Debug app kita sendiri dari Windows tanpa Xcode (filter nama proses app: ModKamera).

Syarat: iPhone terhubung USB, unlock, sudah "Trust". Aplikasi Apple Devices (driver) terpasang.

Contoh:
  python iphone_syslog.py --detik 60                     # filter kamera default
  python iphone_syslog.py --detik 120 --proses ModKamera  # log app kita
  python iphone_syslog.py --detik 30 --semua              # tanpa filter (besar!)
Output: data\\logs\\syslog_<tanggal-jam>.txt
"""
import argparse
import re
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_PROC = ["cameracaptured", "mediaserverd", "Camera", "deferredmediad", "mediaanalysisd",
                "AppleCameraInterface", "ModKamera", "photoanalysisd", "assetsd"]
LINE_RE = re.compile(r"^\S+ \S+ ([^\{\[ ]+)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--detik", type=int, default=60)
    ap.add_argument("--proses", nargs="*", default=DEFAULT_PROC)
    ap.add_argument("--cari", default="", help="regex tambahan (case-insensitive) yang harus muncul di baris")
    ap.add_argument("--semua", action="store_true")
    args = ap.parse_args()

    out_dir = ROOT / "data" / "logs"
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / f"syslog_{datetime.now():%Y%m%d-%H%M%S}.txt"
    procs = set(args.proses)
    pat = re.compile(args.cari, re.I) if args.cari else None

    p = subprocess.Popen([sys.executable, "-m", "pymobiledevice3", "syslog", "live"],
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True, encoding="utf-8", errors="replace")
    t_end = time.time() + args.detik
    kept = total = 0
    keep_cont = False  # baris lanjutan (multi-line) ikut proses sebelumnya
    print(f"merekam {args.detik} s -> {out}  (Ctrl+C untuk berhenti)")
    try:
        with open(out, "w", encoding="utf-8") as f:
            for line in p.stdout:
                total += 1
                m = LINE_RE.match(line)
                if m:
                    keep_cont = args.semua or m.group(1) in procs
                    if keep_cont and pat and not pat.search(line):
                        keep_cont = False
                if keep_cont:
                    f.write(line)
                    kept += 1
                if time.time() > t_end:
                    break
    except KeyboardInterrupt:
        pass
    finally:
        p.terminate()
    print(f"selesai: {kept} dari {total} baris disimpan -> {out}")


if __name__ == "__main__":
    main()
