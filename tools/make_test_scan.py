#!/usr/bin/env python3
"""Синтетический «скан» A4 300 dpi для тестов: текст, таблица, неровная бумага, шум, JPEG q=90."""
import sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter

W, H, DPI = 2480, 3508, 300
rng = np.random.default_rng(7)

TEXT = (
    "Настоящим сообщаю, что в соответствии с распоряжением от 14 октября 2026 года "
    "проведена проверка технического состояния оборудования. По результатам проверки "
    "установлено следующее: сетевые коммутаторы находятся в рабочем состоянии, "
    "источники бесперебойного питания требуют замены аккумуляторных батарей, "
    "резервное копирование выполняется по расписанию. Цифры для проверки чёткости: "
    "0123456789, 6 8 3 5 9 0. Мелкий шрифт и тонкие линии должны сохраниться без искажений."
)

def wrap(draw, text, font, width):
    words, lines, cur = text.split(), [], ""
    for wd in words:
        t = (cur + " " + wd).strip()
        if draw.textlength(t, font=font) > width:
            lines.append(cur); cur = wd
        else:
            cur = t
    lines.append(cur)
    return lines

def main(out):
    page = Image.new("L", (W, H), 255)
    d = ImageDraw.Draw(page)
    serif = "/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf"
    bold = "/usr/share/fonts/truetype/dejavu/DejaVuSerif-Bold.ttf"
    f_title, f_body, f_small = ImageFont.truetype(bold, 58), ImageFont.truetype(serif, 46), ImageFont.truetype(serif, 30)

    y = 260
    d.text((W // 2, y), "АКТ ПРОВЕРКИ № 17/2026", font=f_title, fill=20, anchor="mt"); y += 160
    for _ in range(3):
        for line in wrap(d, TEXT, f_body, W - 2 * 250):
            d.text((250, y), line, font=f_body, fill=25); y += 64
        y += 40
    # таблица
    cols, rows, x0, cw, rh = 4, 8, 250, (W - 500) // 4, 70
    for r in range(rows + 1):
        d.line([(x0, y + r * rh), (x0 + cols * cw, y + r * rh)], fill=30, width=3)
    for c in range(cols + 1):
        d.line([(x0 + c * cw, y), (x0 + c * cw, y + rows * rh)], fill=30, width=3)
    for r in range(rows):
        for c in range(cols):
            d.text((x0 + c * cw + 20, y + r * rh + 15), f"Поз. {r + 1}.{c + 1}", font=f_small, fill=30)
    y += rows * rh + 80
    for line in wrap(d, TEXT, f_small, W - 500)[:4]:
        d.text((250, y), line, font=f_small, fill=35); y += 44
    y += 120
    d.text((250, y), "Ответственный: ____________________  П. А. Дудин", font=f_body, fill=25)

    # «скан»: лёгкая размытость оптики, неровная бумага, шум, слегка тёплый оттенок
    page = page.filter(ImageFilter.GaussianBlur(0.9))
    g = np.asarray(page).astype(np.float32)
    yy, xx = np.mgrid[0:H, 0:W]
    paper = 238 + 10 * np.sin(xx / 900.0) * np.cos(yy / 1300.0) - 12 * (yy / H)
    ink = 1.0 - g / 255.0
    g = paper * (1 - ink) + 30 * ink + rng.normal(0, 4.5, g.shape)
    g = np.clip(g, 0, 255)
    rgb = np.stack([g * 1.0, g * 0.985, g * 0.95], -1).clip(0, 255).astype(np.uint8)
    Image.fromarray(rgb, "RGB").save(out, "JPEG", quality=90, dpi=(DPI, DPI))

if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "test_scan.jpg")
