import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkbloom_reader/formats.dart';
import 'package:inkbloom_reader/pdf_extract.dart';

/// Regression for the 2026-10-21 user bug: a 2.6 MB lecture PDF
/// spun "Opening your book…" for 2 minutes, then timed out.
/// The old extractor inflated every image stream and regexed
/// the binary garbage. A slide-heavy PDF must parse in seconds.
void main() {
  test('slide-heavy pdf with many image streams parses fast', () {
    final out = <int>[];
    void add(String s) => out.addAll(utf8.encode(s));
    // 200 pages: each has a real text stream (Flate) and a
    // large fake image stream that must be skipped, not inflated.
    for (var p = 0; p < 200; p++) {
      final textStream =
          '(Hello page $p world) Tj\n(This is real text) Tj';
      // Build a Flate stream for the text.
      final compressed = ZLibCodec().encode(utf8.encode(textStream));
      add('1 0 obj<</Length ${compressed.length} /Filter /FlateDecode>>stream\n');
      out.addAll(compressed);
      add('\nendstream\nendobj\n');
      // Fake image stream: 50 KB of binary junk, no Flate.
      add('2 0 obj<</Length 51200 /Subtype /Image /Width 100 /Height 100>>stream\n');
      for (var i = 0; i < 51200; i++) {
        out.add((i * 7 + p) % 256);
      }
      add('\nendstream\nendobj\n');
    }
    final sw = Stopwatch()..start();
    final text = extractPdfTextFallback(Uint8List.fromList(out));
    sw.stop();
    expect(text, contains('Hello page 0 world'));
    expect(text, contains('Hello page 199 world'));
    expect(text, contains('This is real text'));
    // 10 MB of image junk must not take minutes.
    expect(sw.elapsed.inSeconds, lessThan(10));
  });

  test('docx paragraphs and headings parse', () {
    final doc = '''<?xml version="1.0"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body>
<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Chapter One</w:t></w:r></w:p>
<w:p><w:r><w:t>First paragraph of the chapter.</w:t></w:r></w:p>
<w:p><w:r><w:t>Second paragraph here.</w:t></w:r></w:p>
<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Chapter Two</w:t></w:r></w:p>
<w:p><w:r><w:t>Another chapter body.</w:t></w:r></w:p>
</w:body></w:document>''';
    final archive = Archive()
      ..addFile(ArchiveFile(
          'word/document.xml', doc.length, utf8.encode(doc)));
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive)!);
    final book = BookParser.parse('My Book.docx', bytes);
    expect(book.format, 'docx');
    expect(book.chapters.length, 2);
    expect(book.chapters[0].title, 'Chapter One');
    expect(book.chapters[0].paragraphs, contains('First paragraph of the chapter.'));
    expect(book.chapters[1].paragraphs, contains('Another chapter body.'));
  });

  test('odt paragraphs and headings parse', () {
    final content = '''<?xml version="1.0"?>
<office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
 xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
<office:body><office:text>
<text:h>Intro</text:h>
<text:p>Opening paragraph.</text:p>
<text:h>Next Part</text:h>
<text:p>Later paragraph.</text:p>
</office:text></office:body></office:document-content>''';
    final archive = Archive()
      ..addFile(ArchiveFile(
          'content.xml', content.length, utf8.encode(content)));
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive)!);
    final book = BookParser.parse('My Book.odt', bytes);
    expect(book.format, 'odt');
    expect(book.chapters.length, 2);
    expect(book.chapters[0].paragraphs, contains('Opening paragraph.'));
    expect(book.chapters[1].paragraphs, contains('Later paragraph.'));
  });
}
