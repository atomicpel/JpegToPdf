import 'dart:math' as math;
import 'dart:typed_data';

/// Разрешение из заголовка JFIF (APP0). null — если не указано или явно «по умолчанию».
int? jfifDpi(Uint8List b) {
  if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return null; // не JPEG
  var i = 2;
  while (i + 4 <= b.length) {
    if (b[i] != 0xFF) return null;
    final marker = b[i + 1];
    if (marker == 0xD8 || (marker >= 0xD0 && marker <= 0xD7)) {
      i += 2;
      continue;
    }
    if (marker == 0xDA || marker == 0xD9) return null; // дальше пиксели
    final len = (b[i + 2] << 8) | b[i + 3];
    if (len < 2 || i + 2 + len > b.length) return null;
    // APP0 "JFIF\0": версия(2) единицы(1) Xdensity(2) Ydensity(2)
    if (marker == 0xE0 && len >= 14 &&
        b[i + 4] == 0x4A && b[i + 5] == 0x46 && b[i + 6] == 0x49 && b[i + 7] == 0x46 && b[i + 8] == 0) {
      final units = b[i + 11];
      final x = (b[i + 12] << 8) | b[i + 13];
      if (x == 0) return null;
      if (units == 1) return x;
      if (units == 2) return (x * 2.54).round();
      return null; // 0 = только пропорции
    }
    i += 2 + len;
  }
  return null;
}

/// Итоговые размеры страницы для кодирования.
class PageGeometry {
  PageGeometry(this.width, this.height, this.dpi);
  final int width;
  final int height;
  final int dpi;
}

/// Скан из сканера обычно несёт свой DPI (200–600). Снимок с телефона — нет (или 72/96),
/// тогда считаем, что длинная сторона кадра — это длинная сторона листа A4 (11,69 дюйма).
/// Слишком подробные снимки (> [maxDpi]) уменьшаем до [targetDpi]: для текста этого с запасом,
/// а память телефона не тратится на 50–200 Мп.
PageGeometry choosePageGeometry(int srcW, int srcH, int? declaredDpi,
    {int maxDpi = 400, int targetDpi = 300}) {
  const a4LongInch = 11.69;
  final longSide = math.max(srcW, srcH);
  var dpi = (declaredDpi != null && declaredDpi >= 100 && declaredDpi <= 1200 &&
          declaredDpi != 72 && declaredDpi != 96)
      ? declaredDpi
      : (longSide / a4LongInch).round().clamp(50, 2400);
  var w = srcW, h = srcH;
  if (dpi > maxDpi) {
    final scale = targetDpi / dpi;
    w = math.max(1, (srcW * scale).round());
    h = math.max(1, (srcH * scale).round());
    dpi = targetDpi;
  }
  return PageGeometry(w, h, dpi);
}
