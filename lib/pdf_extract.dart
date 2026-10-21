import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Pure-Dart fallback PDF text extractor for simple text-based PDFs.
/// It handles uncompressed and Flate-compressed content streams and
/// the ( ... ) Tj / [ (...) ] TJ text operators. It cannot read
/// scanned/image PDFs or encrypted PDFs — those honestly need the
/// native PdfBox path used on Android, which this fallback backs up.
String extractPdfTextFallback(Uint8List bytes) {
  final out = StringBuffer();
  // Work on the raw bytes as Latin-1 so offsets stay stable.
  final raw = latin1.decode(bytes, allowInvalid: true);
  final streamRe = RegExp(r'stream\r?\n([\s\S]*?)\r?\nendstream');
  for (final m in streamRe.allMatches(raw)) {
    var data = m.group(1)!;
    String decoded;
    try {
      // FlateDecode: the stream bytes are not valid Latin-1 text, so
      // re-encode them and try zlib decompression.
      final streamBytes = latin1.encode(data);
      decoded = utf8.decode(
          ZLibDecoder().convert(streamBytes),
          allowMalformed: true);
    } catch (_) {
      decoded = data;
    }
    out.write(_textFromContent(decoded));
    out.write('\n');
  }
  if (out.isEmpty) {
    // Last resort: any literal strings in the file.
    out.write(_textFromContent(raw));
  }
  return out.toString().replaceAll(RegExp(r'[ \t]+'), ' ').trim();
}

String _textFromContent(String content) {
  final buf = StringBuffer();
  // ( ... ) Tj
  final tj = RegExp(r'\((?:\\.|[^\\()])*\)\s*Tj');
  for (final m in tj.allMatches(content)) {
    buf.write(_decodePdfString(m.group(0)!));
    buf.write(' ');
  }
  // [ (...) (...) ] TJ
  final tjArr = RegExp(r'\[((?:[^\[\]]|\([^)]*\))*)\]\s*TJ');
  for (final m in tjArr.allMatches(content)) {
    final inner = m.group(1)!;
    for (final s in RegExp(r'\((?:\\.|[^\\()])*\)').allMatches(inner)) {
      buf.write(_decodePdfString(s.group(0)!));
    }
    buf.write(' ');
  }
  // TJ/Tj markers often separate words; add line breaks on Td/TD.
  return buf.toString();
}

String _decodePdfString(String s) {
  var inner = s;
  final start = inner.indexOf('(');
  final end = inner.lastIndexOf(')');
  if (start >= 0 && end > start) inner = inner.substring(start + 1, end);
  return inner
      .replaceAllMapped(RegExp(r'\\([0-7]{1,3})'), (m) {
        final v = int.tryParse(m.group(1)!, radix: 8);
        return v == null ? '' : String.fromCharCode(v);
      })
      .replaceAll(r'\(', '(')
      .replaceAll(r'\)', ')')
      .replaceAll(r'\\', r'\')
      .replaceAll(r'\n', ' ')
      .replaceAll(r'\r', ' ');
}
