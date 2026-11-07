import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

/// Привязка к общему ядру на C (core/s2p_page.c + core/jbig2_generic.c).
/// На Android библиотека собирается Gradle/CMake как libs2p.so.
/// В тестах на ПК путь задаётся переменной окружения S2P_LIB.

typedef _EncodeC = Long Function(Pointer<Uint8>, Int32, Int32, Int32, Int32, Double,
    Int32, Pointer<Pointer<Uint8>>, Pointer<Uint8>);
typedef _EncodeDart = int Function(Pointer<Uint8>, int, int, int, int, double, int,
    Pointer<Pointer<Uint8>>, Pointer<Uint8>);
typedef _AllocC = Pointer<Void> Function(Long);
typedef _AllocDart = Pointer<Void> Function(int);
typedef _FreeC = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);

/// Результат кодирования одной страницы.
class EncodedPage {
  EncodedPage(this.jbig2, this.bitmap);

  /// Поток JBIG2 для фильтра /JBIG2Decode.
  final Uint8List jbig2;

  /// Ч/б страница (1 = чёрный), если её просили вернуть; иначе null.
  final Uint8List? bitmap;
}

class NativeCore {
  NativeCore._(DynamicLibrary lib)
      : _encode = lib.lookupFunction<_EncodeC, _EncodeDart>('s2p_encode_page'),
        _alloc = lib.lookupFunction<_AllocC, _AllocDart>('s2p_alloc'),
        _free = lib.lookupFunction<_FreeC, _FreeDart>('s2p_free');

  final _EncodeDart _encode;
  final _AllocDart _alloc;
  final _FreeDart _free;

  static NativeCore open() {
    final path = Platform.isAndroid
        ? 'libs2p.so'
        : (Platform.environment['S2P_LIB'] ?? 'libs2p.so');
    return NativeCore._(DynamicLibrary.open(path));
  }

  /// [pixels] — RGBA (channels = 4) или серый (channels = 1), строки подряд без отступов.
  EncodedPage encodePage(Uint8List pixels, int width, int height, int channels, int dpi,
      {double k = 0.34, int window = 0, bool keepBitmap = false}) {
    if (pixels.length != width * height * channels) {
      throw ArgumentError('размер буфера не совпадает с ${width}x$height x $channels');
    }
    final inPtr = _alloc(pixels.length).cast<Uint8>();
    final outPP = _alloc(sizeOf<Pointer<Uint8>>()).cast<Pointer<Uint8>>();
    final bmPtr = keepBitmap ? _alloc(width * height).cast<Uint8>() : nullptr.cast<Uint8>();
    if (inPtr == nullptr || outPP == nullptr || (keepBitmap && bmPtr == nullptr)) {
      _free(inPtr.cast());
      _free(outPP.cast());
      _free(bmPtr.cast());
      throw StateError('нет памяти');
    }
    try {
      inPtr.asTypedList(pixels.length).setAll(0, pixels);
      final n = _encode(inPtr, width, height, channels, dpi, k, window, outPP, bmPtr);
      if (n < 0) throw StateError('ошибка кодирования страницы');
      final outPtr = outPP.value;
      final jbig2 = Uint8List.fromList(outPtr.asTypedList(n));
      _free(outPtr.cast());
      final bitmap = keepBitmap ? Uint8List.fromList(bmPtr.asTypedList(width * height)) : null;
      return EncodedPage(jbig2, bitmap);
    } finally {
      _free(inPtr.cast());
      _free(outPP.cast());
      _free(bmPtr.cast());
    }
  }
}
