import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'converter.dart';
import 'pdf_writer.dart';
import 'platform_io.dart';

void main() => runApp(const JpegToPdfApp());

class JpegToPdfApp extends StatelessWidget {
  const JpegToPdfApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF2F6F5E);
    return MaterialApp(
      title: 'JpegToPdf',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark, useMaterial3: true),
      home: const HomePage(),
    );
  }
}

class _Source {
  _Source(this.path) : name = _displayName(path), size = File(path).lengthSync();
  final String path;
  final String name;
  final int size;

  // MainActivity сохраняет копии как <nanoTime>_<имя>
  static String _displayName(String p) {
    final base = p.split('/').last;
    final i = base.indexOf('_');
    return i > 0 ? base.substring(i + 1) : base;
  }
}

class _Result {
  _Result(this.pdfPath, this.srcBytes, this.pdfBytes, this.pages);
  final String pdfPath;
  final int srcBytes;
  final int pdfBytes;
  final int pages;
  String? savedUri;
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _sources = <_Source>[];
  double _k = 0.34;
  bool _busy = false;
  String _progress = '';
  _Result? _result;

  @override
  void initState() {
    super.initState();
    PlatformIo.onSharedImages(_takeShared);
    _takeShared();
  }

  Future<void> _takeShared() async {
    final paths = await PlatformIo.takeSharedImages();
    if (paths.isNotEmpty && mounted) _addPaths(paths);
  }

  void _addPaths(List<String> paths) {
    setState(() {
      _sources.addAll(paths.map(_Source.new));
      _result = null;
    });
  }

  Future<void> _pick() async {
    try {
      final paths = await PlatformIo.pickImages();
      if (paths.isNotEmpty) _addPaths(paths);
    } catch (e) {
      _snack('Не удалось открыть файлы: $e');
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _convert() async {
    if (_sources.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _result = null;
    });
    final sw = Stopwatch()..start();
    try {
      final pages = <PdfPage>[];
      for (var i = 0; i < _sources.length; i++) {
        setState(() => _progress = 'Страница ${i + 1} из ${_sources.length}');
        pages.add((await convertImageFile(_sources[i].path, k: _k)).page);
      }
      setState(() => _progress = 'Сборка PDF');
      final bytes = buildPdf(pages);
      final dir = await PlatformIo.cacheDir();
      final path = '$dir/${_defaultName()}';
      await File(path).writeAsBytes(bytes, flush: true);
      final src = _sources.fold<int>(0, (s, e) => s + e.size);
      setState(() => _result = _Result(path, src, bytes.length, pages.length));
      debugPrint('PDF готов за ${sw.elapsedMilliseconds} мс');
    } catch (e) {
      _snack('Ошибка: $e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = '';
        });
      }
    }
  }

  String _defaultName() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'scan_${n.year}${two(n.month)}${two(n.day)}_${two(n.hour)}${two(n.minute)}.pdf';
  }

  Future<void> _save() async {
    final r = _result;
    if (r == null) return;
    try {
      final uri = await PlatformIo.savePdf(r.pdfPath, r.pdfPath.split('/').last);
      if (uri != null) {
        setState(() => r.savedUri = uri);
        _snack('PDF сохранён');
      }
    } catch (e) {
      _snack('Не удалось сохранить: $e');
    }
  }

  Future<void> _preview(_Source s) async {
    final nav = Navigator.of(context);
    setState(() {
      _busy = true;
      _progress = 'Готовлю предпросмотр';
    });
    try {
      final c = await convertImageFile(s.path, k: _k, keepBitmap: true);
      final img = await bitmapToImage(c.bitmap!, c.page.widthPx, c.page.heightPx);
      if (!mounted) return;
      await nav.push(MaterialPageRoute<void>(
        builder: (_) => _PreviewPage(
          image: img,
          title: s.name,
          info: '${c.page.widthPx}×${c.page.heightPx}, ${c.page.dpi} dpi · '
              '${_fmt(s.size)} → ${_fmt(c.page.jbig2.length)}',
        ),
      ));
      img.dispose();
    } catch (e) {
      _snack('Ошибка: $e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = '';
        });
      }
    }
  }

  static String _fmt(int b) {
    if (b >= 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(2)} МБ';
    return '${(b / 1024).toStringAsFixed(1)} КБ';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Сканы → PDF'),
        actions: [
          if (_sources.isNotEmpty && !_busy)
            IconButton(
              tooltip: 'Очистить',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: () => setState(() {
                _sources.clear();
                _result = null;
              }),
            ),
        ],
      ),
      body: _sources.isEmpty ? _empty(cs) : _list(cs),
      floatingActionButton: _sources.isEmpty || _busy
          ? null
          : FloatingActionButton.extended(
              onPressed: _convert,
              icon: const Icon(Icons.picture_as_pdf_outlined),
              label: const Text('Создать PDF'),
            ),
    );
  }

  Widget _empty(ColorScheme cs) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.document_scanner_outlined, size: 72, color: cs.primary),
            const SizedBox(height: 16),
            const Text('Выберите сканы документов', style: TextStyle(fontSize: 18)),
            const SizedBox(height: 8),
            Text('Или поделитесь фото из галереи с этим приложением',
                textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant)),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _pick,
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: const Text('Выбрать изображения'),
            ),
          ]),
        ),
      );

  Widget _list(ColorScheme cs) {
    final total = _sources.fold<int>(0, (s, e) => s + e.size);
    return Column(children: [
      if (_busy) LinearProgressIndicator(color: cs.primary),
      if (_busy) Padding(padding: const EdgeInsets.all(8), child: Text(_progress)),
      if (_result != null) _resultCard(cs, _result!),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
        child: Row(children: [
          Expanded(child: Text('Страниц: ${_sources.length} · ${_fmt(total)}')),
          TextButton.icon(
            onPressed: _busy ? null : _pick,
            icon: const Icon(Icons.add),
            label: const Text('Добавить'),
          ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          const Text('Порог'),
          Expanded(
            child: Slider(
              value: _k,
              min: 0.15,
              max: 0.5,
              divisions: 35,
              label: _k.toStringAsFixed(2),
              onChanged: _busy ? null : (v) => setState(() => _k = v),
            ),
          ),
          SizedBox(width: 40, child: Text(_k.toStringAsFixed(2))),
        ]),
      ),
      Expanded(
        child: ReorderableListView.builder(
          padding: const EdgeInsets.only(bottom: 96),
          itemCount: _sources.length,
          onReorder: (a, b) => setState(() {
            if (b > a) b--;
            _sources.insert(b, _sources.removeAt(a));
            _result = null;
          }),
          itemBuilder: (_, i) {
            final s = _sources[i];
            return ListTile(
              key: ValueKey(s.path),
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.file(File(s.path), width: 48, height: 64, fit: BoxFit.cover, cacheWidth: 160),
              ),
              title: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('Стр. ${i + 1} · ${_fmt(s.size)}'),
              onTap: _busy ? null : () => _preview(s),
              trailing: IconButton(
                tooltip: 'Убрать',
                icon: const Icon(Icons.close),
                onPressed: _busy
                    ? null
                    : () => setState(() {
                          _sources.removeAt(i);
                          _result = null;
                        }),
              ),
            );
          },
        ),
      ),
    ]);
  }

  Widget _resultCard(ColorScheme cs, _Result r) {
    final ratio = r.srcBytes / r.pdfBytes;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      color: cs.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${_fmt(r.srcBytes)} → ${_fmt(r.pdfBytes)}',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: cs.onPrimaryContainer)),
          const SizedBox(height: 4),
          Text('В ${ratio.toStringAsFixed(1)} раза меньше · страниц: ${r.pages}',
              style: TextStyle(color: cs.onPrimaryContainer)),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save_alt),
              label: Text(r.savedUri == null ? 'Сохранить' : 'Сохранить ещё раз'),
            ),
            if (r.savedUri != null)
              OutlinedButton.icon(
                onPressed: () async {
                  if (!await PlatformIo.openPdf(r.savedUri!)) _snack('Нет приложения для просмотра PDF');
                },
                icon: const Icon(Icons.open_in_new),
                label: const Text('Открыть'),
              ),
            if (r.savedUri != null)
              OutlinedButton.icon(
                onPressed: () => PlatformIo.sharePdf(r.savedUri!),
                icon: const Icon(Icons.share_outlined),
                label: const Text('Отправить'),
              ),
          ]),
        ]),
      ),
    );
  }
}

class _PreviewPage extends StatelessWidget {
  const _PreviewPage({required this.image, required this.title, required this.info});
  final ui.Image image;
  final String title;
  final String info;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          Text(info, style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
      backgroundColor: Colors.grey.shade400,
      body: InteractiveViewer(
        maxScale: 12,
        child: Center(
          child: AspectRatio(
            aspectRatio: image.width / image.height,
            child: RawImage(image: image, fit: BoxFit.contain, filterQuality: FilterQuality.medium),
          ),
        ),
      ),
    );
  }
}
