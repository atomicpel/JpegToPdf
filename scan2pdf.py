#!/usr/bin/env python3
"""
scan2pdf — прототип: JPEG-сканы документов -> компактный PDF (JBIG2, без потерь при кодировании).

Конвейер:
  1. JPEG -> оттенки серого
  (шаги 2–3 выполняет общее ядро на C: core/s2p_page.c + core/jbig2_generic.c)
  2. Адаптивная бинаризация Sauvola (единственный шаг, где отбрасывается информация:
     серый/цвет превращаются в чёрно-белое; текст сохраняется)
  3. Собственный кодер JBIG2 generic region (core/jbig2_generic.c), без потерь
  4. Собственный минимальный PDF-писатель (фильтр /JBIG2Decode)

Использование:
  python3 scan2pdf.py out.pdf scan1.jpg [scan2.jpg ...] [--k 0.34] [--window 0]
"""
import argparse
import ctypes
import os
import subprocess
import sys
import time

import numpy as np
from PIL import Image, ImageOps

HERE = os.path.dirname(os.path.abspath(__file__))
CORE_LIB = os.path.join(HERE, "core", "libjbig2gen.so")


# ---------- ядро на C (общее с Android-приложением) ----------

CORE_SRCS = [os.path.join(HERE, "core", f) for f in ("jbig2_generic.c", "s2p_page.c")]


def load_core():
    if not os.path.exists(CORE_LIB) or os.path.getmtime(CORE_LIB) < max(map(os.path.getmtime, CORE_SRCS)):
        subprocess.run(["gcc", "-O2", "-shared", "-fPIC", "-o", CORE_LIB, *CORE_SRCS, "-lm"], check=True)
    lib = ctypes.CDLL(CORE_LIB)
    lib.s2p_encode_page.restype = ctypes.c_long
    lib.s2p_encode_page.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                                    ctypes.c_int, ctypes.c_double, ctypes.c_int,
                                    ctypes.POINTER(ctypes.c_void_p), ctypes.c_void_p]
    lib.s2p_free.argtypes = [ctypes.c_void_p]
    return lib


def encode_page(lib, gray, dpi, k, window):
    """gray: uint8 HxW. Возвращает (JBIG2-поток для PDF, ч/б страница: 1 = чёрный)."""
    g = np.ascontiguousarray(gray, dtype=np.uint8)
    h, w = g.shape
    bm = np.empty((h, w), dtype=np.uint8)
    out = ctypes.c_void_p()
    n = lib.s2p_encode_page(g.ctypes.data, w, h, 1, dpi, k, window, ctypes.byref(out), bm.ctypes.data)
    if n < 0:
        raise RuntimeError("ошибка кодирования страницы")
    data = ctypes.string_at(out, n)
    lib.s2p_free(out)
    return data, bm


# ---------- минимальный PDF-писатель ----------

def write_pdf(path, pages):
    """pages: список (jbig2_bytes, width_px, height_px, dpi)."""
    objs = []  # objs[i] — тело объекта i+1

    def add(body):
        objs.append(body)
        return len(objs)

    catalog = add(None)
    pages_obj = add(None)
    kids = []
    for data, w, h, dpi in pages:
        pw, ph = w * 72.0 / dpi, h * 72.0 / dpi
        img = add(b"<< /Type /XObject /Subtype /Image /Width %d /Height %d "
                  b"/ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /JBIG2Decode "
                  b"/Length %d >>\nstream\n" % (w, h, len(data)) + data + b"\nendstream")
        content = b"q %.3f 0 0 %.3f 0 0 cm /Im0 Do Q" % (pw, ph)
        cont = add(b"<< /Length %d >>\nstream\n" % len(content) + content + b"\nendstream")
        page = add(b"<< /Type /Page /Parent %d 0 R /MediaBox [0 0 %.3f %.3f] "
                   b"/Resources << /XObject << /Im0 %d 0 R >> >> /Contents %d 0 R >>"
                   % (pages_obj, pw, ph, img, cont))
        kids.append(page)
    objs[catalog - 1] = b"<< /Type /Catalog /Pages %d 0 R >>" % pages_obj
    objs[pages_obj - 1] = (b"<< /Type /Pages /Count %d /Kids [" % len(kids)
                           + b" ".join(b"%d 0 R" % k for k in kids) + b"] >>")

    out = bytearray(b"%PDF-1.5\n%\xe2\xe3\xcf\xd3\n")
    offsets = []
    for i, body in enumerate(objs, 1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % i + body + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
    for off in offsets:
        out += b"%010d 00000 n \n" % off
    out += b"trailer\n<< /Size %d /Root %d 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (
        len(objs) + 1, catalog, xref)
    with open(path, "wb") as f:
        f.write(out)


# ---------- главный сценарий ----------

def load_gray(path):
    im = Image.open(path)
    dpi = im.info.get("dpi", (300, 300))[0] or 300
    im = ImageOps.exif_transpose(im).convert("L")
    return np.asarray(im), int(round(dpi))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out")
    ap.add_argument("images", nargs="+")
    ap.add_argument("--k", type=float, default=0.34, help="чувствительность Sauvola (0.2–0.5)")
    ap.add_argument("--window", type=int, default=0, help="окно Sauvola в px (0 = авто по DPI)")
    ap.add_argument("--save-bitmaps", help="папка для сохранения ч/б страниц (для проверки)")
    a = ap.parse_args()

    lib = load_core()
    pages = []
    t0 = time.time()
    for i, p in enumerate(a.images):
        gray, dpi = load_gray(p)
        data, bm = encode_page(lib, gray, dpi, a.k, a.window)
        if a.save_bitmaps:
            os.makedirs(a.save_bitmaps, exist_ok=True)
            Image.fromarray((1 - bm) * 255).convert("1").save(
                os.path.join(a.save_bitmaps, "page%03d.png" % (i + 1)))
        pages.append((data, bm.shape[1], bm.shape[0], dpi))
    write_pdf(a.out, pages)

    src = sum(os.path.getsize(p) for p in a.images)
    dst = os.path.getsize(a.out)
    print("страниц: %d  исходные JPEG: %.1f КБ  PDF: %.1f КБ  сжатие: ×%.1f  (%.1f с)"
          % (len(pages), src / 1024, dst / 1024, src / dst, time.time() - t0))


if __name__ == "__main__":
    main()
