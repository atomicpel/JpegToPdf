import 'dart:convert';
import 'dart:typed_data';

/// Страница PDF: картинка JBIG2 на весь лист.
class PdfPage {
  PdfPage(this.jbig2, this.widthPx, this.heightPx, this.dpi);
  final Uint8List jbig2;
  final int widthPx;
  final int heightPx;
  final int dpi;
}

/// Минимальный писатель PDF 1.5 — та же структура, что в scan2pdf.py.
Uint8List buildPdf(List<PdfPage> pages) {
  if (pages.isEmpty) throw ArgumentError('нет страниц');
  final bodies = <List<int>>[];
  int add(List<int> body) {
    bodies.add(body);
    return bodies.length;
  }

  List<int> a(String s) => latin1.encode(s);
  String f(double v) => v.toStringAsFixed(3);

  final catalog = add(const []);
  final pagesObj = add(const []);
  final kids = <int>[];
  for (final p in pages) {
    final pw = p.widthPx * 72.0 / p.dpi, ph = p.heightPx * 72.0 / p.dpi;
    final img = add([
      ...a('<< /Type /XObject /Subtype /Image /Width ${p.widthPx} /Height ${p.heightPx} '
          '/ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /JBIG2Decode '
          '/Length ${p.jbig2.length} >>\nstream\n'),
      ...p.jbig2,
      ...a('\nendstream'),
    ]);
    final content = a('q ${f(pw)} 0 0 ${f(ph)} 0 0 cm /Im0 Do Q');
    final cont = add([
      ...a('<< /Length ${content.length} >>\nstream\n'),
      ...content,
      ...a('\nendstream'),
    ]);
    kids.add(add(a('<< /Type /Page /Parent $pagesObj 0 R /MediaBox [0 0 ${f(pw)} ${f(ph)}] '
        '/Resources << /XObject << /Im0 $img 0 R >> >> /Contents $cont 0 R >>')));
  }
  bodies[catalog - 1] = a('<< /Type /Catalog /Pages $pagesObj 0 R >>');
  bodies[pagesObj - 1] =
      a('<< /Type /Pages /Count ${kids.length} /Kids [${kids.map((k) => '$k 0 R').join(' ')}] >>');

  final out = BytesBuilder(copy: false)
    ..add(a('%PDF-1.5\n'))
    ..add(const [0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]);
  final offsets = <int>[];
  for (var i = 0; i < bodies.length; i++) {
    offsets.add(out.length);
    out
      ..add(a('${i + 1} 0 obj\n'))
      ..add(bodies[i])
      ..add(a('\nendobj\n'));
  }
  final xref = out.length;
  final sb = StringBuffer('xref\n0 ${bodies.length + 1}\n0000000000 65535 f \n');
  for (final off in offsets) {
    sb.write('${off.toString().padLeft(10, '0')} 00000 n \n');
  }
  sb.write('trailer\n<< /Size ${bodies.length + 1} /Root $catalog 0 R >>\nstartxref\n$xref\n%%EOF\n');
  out.add(a(sb.toString()));
  return out.takeBytes();
}
