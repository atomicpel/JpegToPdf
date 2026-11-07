import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'native_core.dart';
import 'page_geometry.dart';
import 'pdf_writer.dart';

/// Одна обработанная страница.
class ConvertedPage {
  ConvertedPage(this.page, this.bitmap);
  final PdfPage page;
  final Uint8List? bitmap; // 1 = чёрный; есть только если просили предпросмотр
}

/// Файл изображения -> страница JBIG2.
/// Декодирование — системным декодером Flutter (учитывает поворот из EXIF),
/// бинаризация и кодирование — ядром на C в отдельном изоляте, чтобы не тормозил интерфейс.
Future<ConvertedPage> convertImageFile(String path,
    {double k = 0.34, bool keepBitmap = false}) async {
  final bytes = await File(path).readAsBytes();
  final declared = jfifDpi(bytes);

  PageGeometry? geo;
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final codec = await ui.instantiateImageCodecWithSize(buffer, getTargetSize: (w, h) {
    final g = choosePageGeometry(w, h, declared);
    geo = g;
    return ui.TargetImageSize(width: g.width, height: g.height);
  });
  final ui.Image image;
  try {
    image = (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
  final w = image.width, h = image.height;
  final ByteData? data;
  try {
    data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  } finally {
    image.dispose();
  }
  if (data == null) throw StateError('не удалось декодировать изображение');
  final dpi = geo?.dpi ?? 300;
  final rgba = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);

  final enc = await Isolate.run(
      () => NativeCore.open().encodePage(rgba, w, h, 4, dpi, k: k, keepBitmap: keepBitmap));
  return ConvertedPage(PdfPage(enc.jbig2, w, h, dpi), enc.bitmap);
}

/// Ч/б страница -> картинка для предпросмотра.
Future<ui.Image> bitmapToImage(Uint8List bitmap, int w, int h) async {
  final rgba = await Isolate.run(() {
    final out = Uint8List(w * h * 4);
    for (var i = 0, j = 0; i < bitmap.length; i++, j += 4) {
      final v = bitmap[i] == 1 ? 0 : 255;
      out[j] = v;
      out[j + 1] = v;
      out[j + 2] = v;
      out[j + 3] = 255;
    }
    return out;
  });
  final done = Completer<ui.Image>();
  ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, done.complete);
  return done.future;
}
