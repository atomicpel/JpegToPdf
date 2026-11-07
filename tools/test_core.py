#!/usr/bin/env python3
"""Проверка ядра: бинаризация C == эталон numpy, PDF декодируется poppler бит в бит."""
import glob, os, subprocess, sys, tempfile
import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import scan2pdf as s2p  # noqa: E402


def sauvola_ref(gray, window, k=0.34, r=128.0):
    g = gray.astype(np.float64); h, w = g.shape; half = window // 2
    p = np.pad(g, ((half + 1, half), (half + 1, half)), mode="edge")
    s1 = p.cumsum(0).cumsum(1); s2 = (p * p).cumsum(0).cumsum(1)
    box = lambda s: s[window:window+h, window:window+w] - s[:h, window:window+w] - s[window:window+h, :w] + s[:h, :w]
    n = float(window * window); m = box(s1) / n
    sd = np.sqrt(np.maximum(box(s2) / n - m * m, 0)); t = m * (1 + k * (sd / r - 1))
    return (g < t).astype(np.uint8), np.abs(g - t)


def main():
    src = os.path.join(os.path.dirname(HERE), "samples", "test_scan.jpg")
    gray, dpi = s2p.load_gray(src)
    lib = s2p.load_core()
    data, bm = s2p.encode_page(lib, gray, dpi, 0.34, 0)
    ref, margin = sauvola_ref(gray, 41)
    diff = bm != ref
    # расхождения допустимы только там, где пиксель ровно на пороге (погрешность double)
    bad = int((diff & (margin > 1e-6)).sum())
    print("бинаризация: отличий от эталона %d (из них не на пороге: %d)" % (int(diff.sum()), bad))
    assert bad == 0

    with tempfile.TemporaryDirectory() as d:
        pdf = os.path.join(d, "t.pdf")
        s2p.write_pdf(pdf, [(data, bm.shape[1], bm.shape[0], dpi)] * 2)
        r = subprocess.run(["pdfimages", "-png", pdf, os.path.join(d, "x")], capture_output=True, text=True)
        assert r.returncode == 0 and not r.stderr.strip(), r.stderr
        files = sorted(glob.glob(os.path.join(d, "x*.png")))
        assert len(files) == 2
        for f in files:
            dec = np.asarray(Image.open(f).convert("L")) < 128
            n = int((dec != bm.astype(bool)).sum())
            print("poppler %s: отличий %d" % (os.path.basename(f), n))
            assert n == 0
        print("PDF %.1f КБ, исходник %.1f КБ" % (os.path.getsize(pdf) / 2048, os.path.getsize(src) / 1024))
    print("OK")


if __name__ == "__main__":
    main()
