import 'dart:typed_data';
import 'epub_parser.dart';
import 'formats.dart';

/// Parses a book OFF the UI thread.
///
/// Heavy parsing (EPUB zip decode, PDF text extraction) used to run
/// on the main thread, so importing a big book froze the whole app
/// and Android showed it as stuck. `compute()` runs this in an
/// isolate, so the UI stays alive and shows progress instead.
///
/// Input: {'name': file name, 'bytes': file bytes}
/// Output: {'title', 'author', 'format',
///          'chapters': [{'title', 'paragraphs': [...]}],
///          'cover': Uint8List?}
Map<String, dynamic> parseBookIsolate(Map<String, dynamic> args) {
  final name = args['name'] as String;
  final bytes = args['bytes'] as Uint8List;
  final lower = name.toLowerCase();
  final ParsedBook parsed;
  if (lower.endsWith('.pdf')) {
    parsed = BookParser.parsePdfBytes(bytes, name);
  } else {
    parsed = BookParser.parse(name, bytes);
  }
  return {
    'title': parsed.title,
    'author': parsed.author,
    'format': parsed.format,
    'chapters': parsed.chapters
        .map((c) => {'title': c.title, 'paragraphs': c.paragraphs})
        .toList(),
    'cover': parsed.coverBytes,
  };
}

ParsedBook parsedBookFromIsolate(Map<String, dynamic> m) {
  final chapters = ((m['chapters'] as List?) ?? [])
      .map((c) => EpubChapter(
            title: (c as Map)['title'] as String? ?? '',
            paragraphs:
                ((c['paragraphs'] as List?) ?? []).map((e) => e.toString()).toList(),
          ))
      .toList();
  return ParsedBook(
    title: m['title'] as String? ?? 'Untitled Book',
    author: m['author'] as String? ?? 'Unknown Author',
    format: m['format'] as String? ?? 'txt',
    chapters: chapters,
    coverBytes: m['cover'] as Uint8List?,
  );
}

/// Cover-only isolate: used when chapter parsing fails, so the
/// book still gets its real thumbnail instead of a generated cover.
Map<String, dynamic> coverBookIsolate(Map<String, dynamic> args) {
  final name = (args['name'] as String).toLowerCase();
  final bytes = args['bytes'] as Uint8List;
  if (!name.endsWith('.epub')) return {'cover': null};
  return {'cover': EpubParser.coverBytesOnly(bytes)};
}
