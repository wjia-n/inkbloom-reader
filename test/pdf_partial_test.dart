import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:inkbloom_reader/isolate_parse.dart';
import 'package:inkbloom_reader/pdf_extract.dart';

Uint8List buildNovelPdf(int pages) {
  final out = <int>[];
  void add(String s) => out.addAll(utf8.encode(s));
  add('%PDF-1.5\n');
  add('1 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Times /Differences [65 /A 66 /B] >>\nendobj\n');
  add('/Resources << /Font << /F1 1 0 R >> >>\n');
  for (var p = 0; p < pages; p++) {
    final lines = <String>[];
    if (p % 20 == 0) lines.add('Chapter ${p ~/ 20 + 1}');
    for (var l = 0; l < 40; l++) {
      lines.add(
          'The quick brown fox jumps over the lazy dog and runs through the forest while the sun sets behind the hills.');
    }
    final content = lines.map((s) => '/F1 12 Tf ($s) Tj').join(' ');
    final compressed = ZLibEncoder().convert(utf8.encode(content));
    add('${2 + p} 0 obj\n<< /Length ${compressed.length} /Filter /FlateDecode >>\nstream\n');
    out.addAll(compressed);
    add('\nendstream\nendobj\n');
  }
  return Uint8List.fromList(out);
}

void main() {
  test('Partial extraction stops at the first pages', () {
    final pdf = buildNovelPdf(300);
    final text = extractPdfTextPartial(pdf, 60000);
    expect(text.length, greaterThanOrEqualTo(60000));
    expect(text.length, lessThan(200000));
    expect(text, contains('Chapter 1'));
    // 60k chars is ~14 pages; Chapter 2 starts at page 20.
    expect(text, isNot(contains('Chapter 2')));
  });

  test('Partial isolate returns chapters, no cover', () {
    final pdf = buildNovelPdf(60);
    final m = parseBookIsolate(
        {'name': 'novel.pdf', 'bytes': pdf, 'partialChars': 60000});
    expect(m['partial'], isTrue);
    expect(m['cover'], isNull);
    final chapters = m['chapters'] as List;
    expect(chapters.isNotEmpty, isTrue);
    expect((chapters.first as Map)['title'], 'Chapter 1');
  });
}
