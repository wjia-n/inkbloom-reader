import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkbloom_reader/app_lang.dart';
import 'package:inkbloom_reader/custom_fonts.dart';
import 'package:inkbloom_reader/dictionary.dart';
import 'package:inkbloom_reader/formats.dart';
import 'package:inkbloom_reader/pdf_extract.dart';
import 'package:inkbloom_reader/stats.dart';
import 'package:inkbloom_reader/tips.dart';

void main() {
  test('FB2 parses title, author and sections', () {
    const fb2 = '''<?xml version="1.0"?>
<FictionBook><description><title-info>
<book-title>My FB2 Book</book-title>
<author><first-name>Ana</first-name><last-name>Lee</last-name></author>
</title-info></description><body>
<section><title><p>Part One</p></title><p>Hello fb2 world.</p></section>
<section><title><p>Part Two</p></title><p>Second part.</p></section>
</body></FictionBook>''';
    final book = BookParser.parse(
        'book.fb2', Uint8List.fromList(utf8.encode(fb2)));
    expect(book.format, 'fb2');
    expect(book.title, 'My FB2 Book');
    expect(book.author, 'Ana Lee');
    expect(book.chapters.length, 2);
  });

  test('RTF strips control words to readable text', () {
    final book = BookParser.parse(
        'note.rtf',
        Uint8List.fromList(utf8.encode(
            r'{\rtf1\ansi Hello world.\par Second line.}')));
    expect(book.format, 'rtf');
    expect(book.chapters.first.paragraphs.join(' '),
        contains('Hello world'));
  });

  test('PDF fallback extracts Tj text', () {
    // Minimal hand-built PDF content stream, uncompressed.
    final pdf = Uint8List.fromList(utf8.encode(
        '%PDF-1.4\n1 0 obj\n<<>>\nstream\nBT (Hello PDF world) Tj ET\nendstream\nendobj\n'));
    final text = extractPdfTextFallback(pdf);
    expect(text, contains('Hello PDF world'));
  });

  test('dictionary finds a word and honestly misses an unknown one', () {
    expect(lookupWord('garden', {}), isNotNull);
    expect(lookupWord('garden', {})!.contains('ground'), isTrue);
    expect(lookupWord('zxqvj', {}), isNull);
    expect(lookupWord('garden', {'garden': 'My own note'}),
        'My own note');
  });

  test('stats streak counts consecutive days', () {
    final now = DateTime.now();
    String key(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final stats = ReadingStats(minutesByDay: {
      key(now): 10,
      key(now.subtract(const Duration(days: 1))): 5,
      key(now.subtract(const Duration(days: 2))): 20,
    });
    expect(stats.streak, 3);
    expect(stats.todayMinutes, 10);
    expect(stats.totalMinutes, 35);
  });

  test('custom font family name strips punctuation', () {
    expect(CustomFonts.familyNameForFile('My Font-Bold.ttf'),
        'MyFontBold');
  });

  test('only two tip products, with compliant IDs', () {
    expect(TipService.productIds.length, 2);
    expect(TipService.productIds,
        containsAll(['inkbloomcoffee', 'inkbloomheadphone']));
    for (final id in TipService.productIds) {
      expect(id.contains('.'), isFalse);
      expect(id.contains('_'), isFalse);
      expect(id.contains('inkbloom'), isTrue);
    }
  });
test('every language covers every English UI key', () {
    // Regression guard for multilingual support: a missing key must
    // fall back to English, never to a blank label.
    final enKeys = ['appTitle', 'yourBooks', 'searchHint', 'importBook',
      'noBooksYet', 'importHelp', 'showAllBooks', 'language',
      'chooseLanguage', 'all', 'favourites', 'toRead', 'reading',
      'finished', 'settings', 'dictionary', 'support', 'continueReading'];
    for (final lang in AppLang.all) {
      for (final key in enKeys) {
        expect(lang.t(key), isNotEmpty, reason: '${lang.code} $key');
      }
    }
    expect(AppLang.fromCode('ur').rtl, isTrue);
    expect(AppLang.fromCode('ar').rtl, isTrue);
    expect(AppLang.fromCode('en').rtl, isFalse);
  });
}
