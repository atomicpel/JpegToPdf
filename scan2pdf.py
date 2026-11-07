#!/usr/bin/env python3
"""
scan2pdf — прототип: JPEG-сканы документов -> компактный PDF (JBIG2, без потерь при кодировании).

Конвейер:
  1. JPEG -> оттенки серого
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
import struct
import subprocess
import sys
import time

import numpy as np
from PIL import Image, ImageOps

HERE = os.path.dirname(os.path.abspath(__file__))
CORE_SRC = os.path.join(HERE, "core", "jbig2_generic.c")
CORE_LIB = os.path.join(HERE, "core", "libjbig2gen.so")


# ---------- ядро на C ----------

def load_core():
    if not os.path.exists(CORE_LIB) or os.path.getmtime(CORE_LIB) < os.path.getmtime(CORE_SRC):
        subprocess.run(["gcc", "-O2", "-shared", "-fPIC", "-o", CORE_LIB, CORE_SRC], check=True)
    lib = ctypes.CDLL(CORE_LIB)
    lib.jbig2_encode_generic.restype = ctypes.c_long
    lib.jbig2_encode_generic.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int,
                                         ctypes.c_int, ctypes.POINTER(ctypes.c_void_p)]
    lib.jbig2_free.argtypes = [ctypes.c_void_p]
    return lib


def mq_encode(lib, bitmap):
    """bitmap: uint8 HxW, 1 = чёрный."""
    bm = np.ascontiguousarray(bitmap, dtype=np.uint8)
    h, w = bm.shape
    out = ctypes.c_void_p()
    n = lib.jbig2_encode_generic(bm.ctypes.data, w, h, 1, ctypes.byref(out))
    if n < 0:
        raise RuntimeError("JBIG2: ошибка кодирования")
    data = ctypes.string_at(out, n)
    lib.jbig2_free(out)
    return data


# ---------- бинаризация ----------

def sauvola(gray, window, k=0.34, r=128.0):
    """Адаптивный порог Sauvola через интегральные изображения. Возвращает 1 = чёрный."""
    g = gray.astype(np.float64)
    h, w = g.shape
    half = window // 2
    p = np.pad(g, ((half + 1, half), (half + 1, half)), mode="edge")
    s1 = p.cumsum(0).cumsum(1)
    s2 = (p * p).cumsum(0).cumsum(1)

    def box(s):
        return s[window:window + h, window:window + w] - s[:h, window:window + w] \
             - s[window:window + h, :w] + s[:h, :w]

    n = float(window * window)
    mean = box(s1) / n
    var = np.maximum(box(s2) / n - mean * mean, 0.0)
    thr = mean * (1.0 + k * (np.sqrt(var) / r - 1.0))
    return (g < thr).astype(np.uint8)


# ---------- JBIG2-сегменты для PDF (встраиваемый формат, без заголовка файла) ----------

def segment(num, seg_type, data, page=1):
    hdr = struct.pack(">IBBBI", num, seg_type & 0x3F, 0x00, page, len(data))
    return hdr + data


def jbig2_page_stream(lib, bitmap, dpi):
    h, w = bitmap.shape
    ppm = int(round(dpi / 0.0254))  # точек на метр
    page_info = struct.pack(">IIIIBH", w, h, ppm, ppm, 0x01, 0)  # флаг: lossless
    region_info = struct.pack(">IIIIB", w, h, 0, 0, 0)
    gen_flags = 0x08  # MMR=0, GBTEMPLATE=0, TPGDON=1
    at = struct.pack(">8b", 3, -1, -3, -1, 2, -2, -2, -2)
    mq = mq_encode(lib, bitmap)
    # Сегмент «конец страницы» (49) в PDF не нужен: poppler на него ругается, jbig2enc его тоже не пишет
    return (segment(0, 48, page_info)
            + segment(1, 38, region_info + bytes([gen_flags]) + at + mq))


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
        win = a.window or (int(dpi / 300 * 41) | 1)
        bm = sauvola(gray, win, a.k)
        if a.save_bitmaps:
            os.makedirs(a.save_bitmaps, exist_ok=True)
            Image.fromarray((1 - bm) * 255).convert("1").save(
                os.path.join(a.save_bitmaps, "page%03d.png" % (i + 1)))
        data = jbig2_page_stream(lib, bm, dpi)
        pages.append((data, bm.shape[1], bm.shape[0], dpi))
    write_pdf(a.out, pages)

    src = sum(os.path.getsize(p) for p in a.images)
    dst = os.path.getsize(a.out)
    print("страниц: %d  исходные JPEG: %.1f КБ  PDF: %.1f КБ  сжатие: ×%.1f  (%.1f с)"
          % (len(pages), src / 1024, dst / 1024, src / dst, time.time() - t0))


if __name__ == "__main__":
    main()
