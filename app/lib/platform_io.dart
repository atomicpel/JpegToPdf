import 'package:flutter/services.dart';

/// Мост к MainActivity.kt: системные окна выбора/сохранения файлов и «Поделиться».
class PlatformIo {
  static const _ch = MethodChannel('jpegtopdf/io');

  /// Вызывается, когда в приложение «поделились» изображениями, пока оно открыто.
  static void onSharedImages(void Function() callback) {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'sharedImagesAvailable') callback();
    });
  }

  /// Каталог кэша приложения (временные PDF).
  static Future<String> cacheDir() async => (await _ch.invokeMethod<String>('cacheDir'))!;

  static Future<List<String>> pickImages() async =>
      (await _ch.invokeListMethod<String>('pickImages')) ?? const [];

  static Future<List<String>> takeSharedImages() async =>
      (await _ch.invokeListMethod<String>('takeSharedImages')) ?? const [];

  /// Возвращает content:// адрес сохранённого файла или null, если пользователь отменил.
  static Future<String?> savePdf(String path, String name) =>
      _ch.invokeMethod<String>('savePdf', {'path': path, 'name': name});

  static Future<bool> openPdf(String uri) async =>
      (await _ch.invokeMethod<bool>('openPdf', {'uri': uri})) ?? false;

  static Future<bool> sharePdf(String uri) async =>
      (await _ch.invokeMethod<bool>('sharePdf', {'uri': uri})) ?? false;
}
