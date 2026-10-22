import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:inkbloom_reader/formats.dart';
import 'package:inkbloom_reader/pdf_extract.dart';
import 'package:inkbloom_reader/stats.dart';

/// Builds a tiny PDF whose body font uses glyph-ID codes, not
/// letters — the exact failure the user photographed: without
/// the ToUnicode CMap, the text reads as gibberish.
Uint8List garbledFontPdf() {
  const cmap = '''
/CIDInit /ProcSet findresource begin
12 dict begin
begincmap
1 begincodespacerange
<0000> <FFFF>
endcodespacerange
8 beginbfchar
<0001> <0048>
<0002> <0065>
<0003> <006C>
<0004> <006F>
<0005> <0020>
<0006> <0077>
<0007> <0072>
<0008> <0064>
endbfchar
endcmap
''';
  final cmapBytes = ZLibEncoder().convert(utf8.encode(cmap));
  // Hex codes spell "Hello world" through the CMap:
  // 1=H 2=e 3=l 4=o 5=space 6=w 7=r 8=d.
  const content =
      'BT /F1 12 Tf <00010002000300030004> Tj <000500060004000700030008> Tj ET';
  final out = <int>[];
  void add(String s) => out.addAll(utf8.encode(s));
  void addBytes(List<int> b) => out.addAll(b);
  add('%PDF-1.4\n');
  add('1 0 obj << /Length ${cmapBytes.length} /Filter /FlateDecode >>\n'
      'stream\n');
  addBytes(cmapBytes);
  add('\nendstream\nendobj\n');
  add('2 0 obj << /Length ${content.length} >>\nstream\n');
  add(content);
  add('\nendstream\nendobj\n');
  add('3 0 obj << /Title (The Real Novel) /Author (Jane Writer) >>\n'
      'endobj\n');
  return Uint8List.fromList(out);
}

Uint8List differencesPdf() {
  // Simple font with a /Differences array: codes 65-68 -> H e l o.
  const content = 'BT /F1 12 Tf (ABCD) Tj ET';
  final out = <int>[];
  void add(String s) => out.addAll(utf8.encode(s));
  add('%PDF-1.4\n');
  add('1 0 obj << /Type /Font /BaseFont /Custom '
      '/Encoding << /Differences [65 /H /e /l /o] >> >>\nendobj\n');
  add('2 0 obj << /Length ${content.length} >>\nstream\n');
  add(content);
  add('\nendstream\nendobj\n');
  return Uint8List.fromList(out);
}

Uint8List jpegCoverPdf() {
  final jpg = List<int>.filled(1500, 0);
  jpg[0] = 0xFF;
  jpg[1] = 0xD8;
  jpg[1498] = 0xFF;
  jpg[1499] = 0xD9;
  final out = <int>[];
  void add(String s) => out.addAll(utf8.encode(s));
  add('%PDF-1.4\n');
  add('1 0 obj << /Subtype /Image /XObject /Filter /DCTDecode '
      '/Length ${jpg.length} >>\nstream\n');
  out.addAll(jpg);
  add('\nendstream\nendobj\n');
  return Uint8List.fromList(out);
}

void main() {
  test('ToUnicode CMap turns glyph-ID garbage into real text', () {
    final text = extractPdfTextFallback(garbledFontPdf());
    expect(text, contains('Hello'));
    expect(text, contains('world'));
  });

  test('PDF metadata is still read for the author', () {
    final meta = extractPdfMeta(garbledFontPdf());
    expect(meta.title, 'The Real Novel');
    expect(meta.author, 'Jane Writer');
  });

  test('PDF shows the EXACT imported name, never a renamed title', () {
    final book = BookParser.parsePdfBytes(
        garbledFontPdf(), 'book_17925970589_10922_0.pdf');
    // Underscores kept, metadata title NOT substituted:
    // the user reads any change as "the app renamed my book".
    expect(book.title, 'book_17925970589_10922_0');
    expect(book.author, 'Jane Writer');
  });

  test('PDF cover is the largest JPEG, not the first tiny one', () {
    final small = List<int>.filled(300, 0);
    small[0] = 0xFF;
    small[1] = 0xD8;
    final big = List<int>.filled(2000, 0);
    big[0] = 0xFF;
    big[1] = 0xD8;
    final out = <int>[];
    void add(String s) => out.addAll(utf8.encode(s));
    add('%PDF-1.4\n');
    add('1 0 obj << /Subtype /Image /XObject /Filter /DCTDecode '
        '/Length ${small.length} >>\nstream\n');
    out.addAll(small);
    add('\nendstream\nendobj\n');
    add('2 0 obj << /Subtype /Image /XObject /Filter /DCTDecode '
        '/Length ${big.length} >>\nstream\n');
    out.addAll(big);
    add('\nendstream\nendobj\n');
    final cover = extractPdfCover(Uint8List.fromList(out));
    expect(cover, isNotNull);
    expect(cover!.length, 2000);
  });

  test('Differences array decodes a custom-encoded font', () {
    final text = extractPdfTextFallback(differencesPdf());
    expect(text, contains('Helo'));
  });

  test('first embedded JPEG is returned as the PDF cover', () {
    final cover = extractPdfCover(jpegCoverPdf());
    expect(cover, isNotNull);
    expect(cover![0], 0xFF);
    expect(cover[1], 0xD8);
  });

  test('stats accumulate instead of resetting', () {
    var s = const ReadingStats();
    s = s.recordMinutes(12.5);
    s = s.recordMinutes(7.5);
    expect(s.todayMinutes, 20.0);
    expect(s.totalMinutes, 20.0);
    expect(s.streak, 1);
  });
}
