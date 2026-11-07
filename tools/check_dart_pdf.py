#!/usr/bin/env python3
"""CI: PDF, собранный Dart-кодом приложения, декодируется poppler бит в бит."""
import glob, os, subprocess, sys
import numpy as np
from PIL import Image

d = sys.argv[1]
ref = np.asarray(Image.open(os.path.join(d, "dart_bitmap.pbm")).convert("L")) < 128
r = subprocess.run(["pdfimages", "-png", os.path.join(d, "dart.pdf"), os.path.join(d, "pg")],
                   capture_output=True, text=True)
if r.returncode or r.stderr.strip():
    sys.exit("pdfimages: " + r.stderr)
files = sorted(glob.glob(os.path.join(d, "pg*.png")))
assert len(files) == 2, files
for f in files:
    dec = np.asarray(Image.open(f).convert("L")) < 128
    n = int((dec != ref).sum())
    print(os.path.basename(f), "отличий:", n)
    assert n == 0
print("Dart PDF: OK, %.1f КБ на страницу" % (os.path.getsize(os.path.join(d, "dart.pdf")) / 2048))
