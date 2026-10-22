import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:inkbloom_reader/pdf_extract.dart';

/// Builds a tiny PDF from object bodies. Each body is wrapped as
/// `N 0 obj ... endobj` with N assigned in order.
Uint8List pdfOf(List<String> bodies,
    {String trailer = '', List<Uint8List> binaries = const []}) {
  final out = <int>[];
  void add(String s) => out.addAll(utf8.encode(s));
  add('%PDF-1.5\n');
  for (var k = 0; k < bodies.length; k++) {
    add('${k + 1} 0 obj\n');
    add(bodies[k]);
    add('\nendobj\n');
  }
  add(trailer);
  for (final b in binaries) {
    out.addAll(b);
  }
  return Uint8List.fromList(out);
}

String streamObj(String dict, String content) {
  final len = utf8.encode(content).length;
  return '$dict /Length $len >>\nstream\n$content\nendstream';
}

void main() {
  test('Two fonts with colliding glyph IDs decode per font, not merged', () {
    // F1 maps code 1 -> 'a', F2 maps code 1 -> 'b'. A global
    // union would decode both strings as 'a'. Per-font Tf
    // tracking must give 'a b'.
    // NOTE: the resource line is trailing text, not an object,
    // so the font dicts really are objects 1 and 2 and the
    // CMaps really are 3 and 4 (an earlier version of this
    // test put the resource line first as object 1, which
    // shifted every reference by one and proved nothing).
    final pdf = pdfOf([
      '<< /Type /Font /Subtype /Type0 /BaseFont /F1Font /ToUnicode 3 0 R >>',
      '<< /Type /Font /Subtype /Type0 /BaseFont /F2Font /ToUnicode 4 0 R >>',
      streamObj('<<', 'beginbfchar <01> <0061> endbfchar'),
      streamObj('<<', 'beginbfchar <01> <0062> endbfchar'),
      streamObj('<<', '/F1 12 Tf <01> Tj /F2 12 Tf <01> Tj'),
    ], trailer: '/Resources << /Font << /F1 1 0 R /F2 2 0 R >> >>\n');
    final text = extractPdfTextFallback(pdf);
    expect(text.trim(), 'a b');
  });

  test('Font dict hidden in an Object Stream still supplies Differences', () {
    // Modern PDFs compress font dicts into ObjStm. The font
    // dict (obj 10) and the resource map (obj 11) live inside
    // one Flate-compressed object stream; the content stream
    // uses /F1 and literal (AB) with Differences [65 /A 66 /B].
    final obj10 = '<< /Type /Font /BaseFont /F /Differences [65 /A 66 /B] >>';
    final obj11 = '<< /Font << /F1 10 0 R >> >>';
    final header = '10 0 11 ${obj10.length} ';
    final first = header.length;
    final body = header + obj10 + obj11;
    final compressed = ZLibEncoder().convert(utf8.encode(body));
    final objStmDict =
        '<< /Type /ObjStm /N 2 /First $first /Length ${compressed.length} /Filter /FlateDecode >>';
    final out = <int>[];
    void add(String s) => out.addAll(utf8.encode(s));
    add('%PDF-1.5\n');
    add('1 0 obj\n$objStmDict\nstream\n');
    out.addAll(compressed);
    add('\nendstream\nendobj\n');
    final content = '/F1 12 Tf (AB) Tj';
    add('2 0 obj\n<< /Length ${content.length} >>\nstream\n$content\nendstream\nendobj\n');
    final text = extractPdfTextFallback(Uint8List.fromList(out));
    expect(text.trim(), 'AB');
  });

  test('Embedded TrueType cmap decodes a CID font with no ToUnicode', () {
    // Hand-built minimal TTF: one cmap subtable, format 4,
    // one segment 0x41-0x42 with delta -60, so glyph 5 -> 'A'
    // and glyph 6 -> 'B'. The PDF links font -> descriptor ->
    // FontFile2, the normal real-world layout.
    final ttf = buildTtf();
    final out = <int>[];
    void add(String s) => out.addAll(utf8.encode(s));
    add('%PDF-1.5\n');
    add('/Resources << /Font << /F1 1 0 R >> >>\n');
    add('1 0 obj\n<< /Type /Font /Subtype /TrueType /BaseFont /TestFont /FontDescriptor 2 0 R >>\nendobj\n');
    add('2 0 obj\n<< /Type /FontDescriptor /FontName /TestFont /FontFile2 3 0 R >>\nendobj\n');
    add('3 0 obj\n<< /Length ${ttf.length} >>\nstream\n');
    out.addAll(ttf);
    add('\nendstream\nendobj\n');
    final content = '/F1 12 Tf <00050006> Tj';
    add('4 0 obj\n<< /Length ${content.length} >>\nstream\n$content\nendstream\nendobj\n');
    final text = extractPdfTextFallback(Uint8List.fromList(out));
    expect(text.trim(), 'AB');
  });
}

/// Minimal TrueType file: one 'cmap' table, one format-4
/// subtable (platform 3, encoding 1), segment 0x41-0x42 with
/// delta -60 (glyph 5 -> 'A', glyph 6 -> 'B') plus the 0xFFFF
/// sentinel segment. All integers big-endian.
Uint8List buildTtf() {
  final b = <int>[];
  void u16(int v) => b.addAll([v >> 8 & 0xFF, v & 0xFF]);
  void u32(int v) =>
      b.addAll([v >> 24 & 0xFF, v >> 16 & 0xFF, v >> 8 & 0xFF, v & 0xFF]);
  void tag(String s) => b.addAll(s.codeUnits);
  u32(0x00010000); // sfnt version
  u16(1); // numTables
  u16(16); // searchRange
  u16(0); // entrySelector
  u16(0); // rangeShift
  tag('cmap');
  u32(0); // checksum (ignored by the parser)
  u32(28); // offset: header 12 + record 16
  u32(44); // length: cmap header 4 + record 8 + format-4 32
  // cmap table
  u16(0); // version
  u16(1); // numSubtables
  u16(3); // platform: Windows
  u16(1); // encoding: Unicode BMP
  u32(12); // offset from cmap start
  // format-4 subtable
  u16(4); // format
  u16(32); // length
  u16(0); // language
  u16(4); // segCountX2 (2 segments)
  u16(4); // searchRange
  u16(1); // entrySelector
  u16(0); // rangeShift
  u16(0x0042); // endCodes[0]
  u16(0xFFFF); // endCodes[1] sentinel
  u16(0); // reservedPad
  u16(0x0041); // startCodes[0]
  u16(0xFFFF); // startCodes[1] sentinel
  u16(0xFFC4); // idDeltas[0]: -60
  u16(1); // idDeltas[1]
  u16(0); // idRangeOffsets[0]
  u16(0); // idRangeOffsets[1]
  return Uint8List.fromList(b);
}
