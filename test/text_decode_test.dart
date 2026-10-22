import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:inkbloom_reader/formats.dart';
import 'package:inkbloom_reader/pdf_extract.dart';

void main() {
  test('TXT saved as UTF-16LE reads correctly, not as spaced garbage', () {
    // "Hi there" in UTF-16LE with a BOM.
    final units = <int>[0xFF, 0xFE];
    for (final ch in 'Hi there'.codeUnits) {
      units.addAll([ch, 0]);
    }
    final text = BookParser.decodeTextBytes(Uint8List.fromList(units));
    expect(text, 'Hi there');
  });

  test('Windows-1252 smart quotes survive instead of becoming boxes', () {
    // 0x93/0x94/0x97 are “ ” — in latin1 they are control chars.
    final bytes = Uint8List.fromList([
      ...'He said '.codeUnits,
      0x93,
      ...'hello'.codeUnits,
      0x94,
      ...' and paused'.codeUnits,
      0x97,
    ]);
    final text = BookParser.decodeTextBytes(bytes);
    expect(text, contains('“hello”'));
    expect(text, contains('—'));
  });

  test('RTF keeps unicode letters, smart quotes, and paragraphs', () {
    const rtf = r"{\rtf1\ansi\deff0"
        r"{\fonttbl{\f0 Times New Roman;}}"
        r"{\info{\title Hidden Title}}"
        r"\f0 Hello \'93world\'94\par "
        r"Caf\uc1\u233x and more\par}";
    final book = BookParser.parse('note.rtf', Uint8List.fromList(rtf.codeUnits));
    final all = book.chapters.expand((c) => c.paragraphs).join('\n');
    expect(all, contains('Hello “world”'));
    expect(all, contains('Café'));
    expect(all, isNot(contains('Times')));
    expect(all, isNot(contains('Hidden Title')));
    expect(book.chapters.expand((c) => c.paragraphs).length,
        greaterThanOrEqualTo(2));
  });

  test('PDF without a font map still shows WinAnsi punctuation', () {
    // Literal string with octal escapes for 0x93/0x94.
    const content = r'BT /F1 12 Tf (He said \223hi\224) Tj ET';
    final out = <int>[];
    void add(String s) => out.addAll(utf8.encode(s));
    add('%PDF-1.4\n');
    add('1 0 obj << /Length ${content.length} >>\nstream\n');
    add(content);
    add('\nendstream\nendobj\n');
    final text = extractPdfTextFallback(Uint8List.fromList(out));
    expect(text, contains('“hi”'));
  });
}
