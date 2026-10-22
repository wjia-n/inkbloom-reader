import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:inkbloom_reader/book_cache.dart';
import 'package:inkbloom_reader/epub_parser.dart';

void main() {
  test('Cache round-trips chapters and rejects a changed file', () async {
    final dir = await Directory.systemTemp.createTemp('inkbloom-cache-');
    final source = File('${dir.path}/book.pdf');
    await source.writeAsString('fake pdf bytes');
    final chapters = [
      EpubChapter(title: 'One', paragraphs: ['Hello world']),
      EpubChapter(title: 'Two', paragraphs: ['Second chapter']),
    ];
    await BookCache.write(dir, 'book-1', chapters, source);
    final hit = await BookCache.read(dir, 'book-1', source);
    expect(hit, isNotNull);
    expect(hit!.length, 2);
    expect(hit[0].paragraphs.first, 'Hello world');
    // Changing the source invalidates the cache.
    await source.writeAsString('fake pdf bytes, but longer now');
    expect(await BookCache.read(dir, 'book-1', source), isNull);
    await dir.delete(recursive: true);
  });
}
