// Тесты, которые не требуют телефона. Запускаются в CI:
//   S2P_LIB=путь/к/libs2p.so  S2P_PGM=скан.pgm  S2P_OUT=каталог  flutter test
// Ядро на C собирается gcc из core/*.c, результат затем проверяется декодером poppler.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jpeg_to_pdf/native_core.dart';
import 'package:jpeg_to_pdf/page_geometry.dart';
import 'package:jpeg_to_pdf/pdf_writer.dart';

/// Читает бинарный PGM (P5, 8 бит).
(Uint8List, int, int) readPgm(String path) {
  final b = File(path).readAsBytesSync();
  final tokens = <String>[];
  var i = 0;
  while (tokens.length < 4) {
    while (b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09) {
      i++;
    }
    if (b[i] == 0x23) {
      while (b[i] != 0x0A) {
        i++;
      }
      continue;
    }
    final s = i;
    while (!(b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09)) {
      i++;
    }
    tokens.add(String.fromCharCodes(b.sublist(s, i)));
  }
  i++; // один пробельный символ после maxval
  final w = int.parse(tokens[1]), h = int.parse(tokens[2]);
  return (Uint8List.sublistView(b, i, i + w * h), w, h);
}

void main() {
  test('JFIF: DPI из заголовка', () {
    final jfif = Uint8List.fromList([
      0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, //
      0x01, 0x01, 0x2C, 0x01, 0x2C, 0x00, 0x00, 0xFF, 0xD9,
    ]);
    expect(jfifDpi(jfif), 300);
    expect(jfifDpi(Uint8List.fromList([1, 2, 3])), isNull);
  });

  test('Геометрия: скан со своим DPI не меняется', () {
    final g = choosePageGeometry(2480, 3508, 300);
    expect([g.width, g.height, g.dpi], [2480, 3508, 300]);
  });

  test('Геометрия: снимок 200 Мп уменьшается до 300 dpi A4', () {
    final g = choosePageGeometry(12240, 16320, 72);
    expect(g.dpi, 300);
    expect(g.height, closeTo(3507, 3));
  });

  test('Ядро C: страница -> JBIG2 -> PDF', () {
    final lib = Platform.environment['S2P_LIB'];
    if (lib == null) {
      markTestSkipped('S2P_LIB не задан');
      return;
    }
    final core = NativeCore.open();

    Uint8List gray;
    int w, h;
    final pgm = Platform.environment['S2P_PGM'];
    if (pgm != null) {
      (gray, w, h) = readPgm(pgm);
    } else {
      w = 600;
      h = 800;
      gray = Uint8List(w * h)..fillRange(0, w * h, 230);
      for (var y = 100; y < 700; y += 40) {
        for (var x = 50; x < 550; x++) {
          if ((x ~/ 7) % 3 != 0) {
            for (var t = 0; t < 12; t++) {
              gray[(y + t) * w + x] = 30;
            }
          }
        }
      }
    }

    final enc = core.encodePage(gray, w, h, 1, 300, keepBitmap: true);
    expect(enc.jbig2.length, greaterThan(30));
    // RGBA даёт ровно тот же результат, что и серый
    final rgba = Uint8List(w * h * 4);
    for (var i = 0; i < w * h; i++) {
      rgba[i * 4] = rgba[i * 4 + 1] = rgba[i * 4 + 2] = gray[i];
      rgba[i * 4 + 3] = 255;
    }
    expect(core.encodePage(rgba, w, h, 4, 300).jbig2, enc.jbig2);

    final pdf = buildPdf([PdfPage(enc.jbig2, w, h, 300), PdfPage(enc.jbig2, w, h, 300)]);
    expect(String.fromCharCodes(pdf.sublist(0, 8)), '%PDF-1.5');

    final out = Platform.environment['S2P_OUT'];
    if (out != null) {
      File('$out/dart.pdf').writeAsBytesSync(pdf);
      // эталон для сравнения с декодером poppler: PBM, 1 = чёрный
      final rowBytes = (w + 7) >> 3;
      final pbm = BytesBuilder()..add('P4\n$w $h\n'.codeUnits);
      final row = Uint8List(rowBytes);
      for (var y = 0; y < h; y++) {
        row.fillRange(0, rowBytes, 0);
        for (var x = 0; x < w; x++) {
          if (enc.bitmap![y * w + x] == 1) row[x >> 3] |= 0x80 >> (x & 7);
        }
        pbm.add(row);
      }
      File('$out/dart_bitmap.pbm').writeAsBytesSync(pbm.takeBytes());
    }
  });
}
