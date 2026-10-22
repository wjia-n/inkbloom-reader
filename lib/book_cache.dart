import 'dart:convert';
import 'dart:io';

import 'epub_parser.dart';

/// Disk cache for parsed book chapters, so a big PDF is
/// extracted ONCE and reopened instantly afterwards.
///
/// The user reported PDF opens taking "minutes and minutes":
/// parsed chapters were never saved anywhere, so every open
/// after an app restart re-ran the whole pure-Dart PDF
/// extraction. Now the first successful parse writes its
/// chapters here, and later opens load them in milliseconds.
/// The cache is validated against the source file's size and
/// modification time, so a changed file is re-parsed instead
/// of serving stale chapters. A missing, stale or corrupt
/// cache simply means one more parse — never an error.
class BookCache {
  static String _fileName(String bookId) => '$bookId.cache.json';

  static Future<void> write(Directory dir, String bookId,
      List<EpubChapter> chapters, File source) async {
    try {
      final stat = await source.stat();
      final data = {
        'size': stat.size,
        'mtimeMs': stat.modified.millisecondsSinceEpoch,
        'chapters': chapters
            .map((c) => {'title': c.title, 'paragraphs': c.paragraphs})
            .toList(),
      };
      final file = File('${dir.path}/${_fileName(bookId)}');
      await file.writeAsString(jsonEncode(data));
    } catch (_) {
      // Cache is best-effort; a failed write must never
      // break opening or importing the book.
    }
  }

  static Future<List<EpubChapter>?> read(
      Directory dir, String bookId, File source) async {
    try {
      final file = File('${dir.path}/${_fileName(bookId)}');
      if (!await file.exists()) return null;
      final stat = await source.stat();
      final data = jsonDecode(await file.readAsString()) as Map;
      if (data['size'] != stat.size ||
          data['mtimeMs'] != stat.modified.millisecondsSinceEpoch) {
        return null;
      }
      final chapters = <EpubChapter>[];
      for (final c in (data['chapters'] as List)) {
        final m = c as Map;
        chapters.add(EpubChapter(
          title: m['title'] as String? ?? '',
          paragraphs: ((m['paragraphs'] as List?) ?? [])
              .map((e) => e.toString())
              .toList(),
        ));
      }
      return chapters.isEmpty ? null : chapters;
    } catch (_) {
      return null;
    }
  }

  static Future<void> delete(Directory dir, String bookId) async {
    try {
      final file = File('${dir.path}/${_fileName(bookId)}');
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
