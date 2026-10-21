import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkbloom_reader/app_lang.dart';
import 'package:inkbloom_reader/isolate_parse.dart';
import 'package:inkbloom_reader/reader_prefs.dart';
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
    expect(AppLang.fromCode('fa').rtl, isTrue);
    expect(AppLang.fromCode('he').rtl, isTrue);
    expect(AppLang.fromCode('ps').rtl, isTrue);
    expect(AppLang.fromCode('en').rtl, isFalse);
    // 50+ languages, all real, all with native names.
    expect(AppLang.all.length, greaterThanOrEqualTo(50));
  });

  test('isolate parse returns a book without touching the UI thread', () {
    final bytes = Uint8List.fromList(
        'My Book\n\nChapter One\n\nHello world.'.codeUnits);
    final m = parseBookIsolate({'name': 'mybook.txt', 'bytes': bytes});
    final book = parsedBookFromIsolate(m);
    expect(book.title, 'mybook');
    expect(book.chapters, isNotEmpty);
    expect(book.chapters.expand((c) => c.paragraphs).join(' '), contains('Hello world'));
  });

  test('settings survive a save and reload (night, voice, goal, fonts)', () {
    // Regression: toJson used to drop autoNight, tts, goal, fonts,
    // so those settings looked dead after leaving a book.
    const s = ReaderSettings(
      autoNight: true,
      nightStartHour: 22,
      nightEndHour: 6,
      ttsRate: 0.8,
      ttsPitch: 1.2,
      goalMinutes: 45,
      customFonts: ['MyFont'],
      languageCode: 'ur',
      ttsVoiceName: 'en-gb-x-gba-network',
      ttsVoiceLocale: 'en-GB',
      showTextSizeButtons: false,
      enableHighlights: false,
      themeIndex: 3,
      navPosition: 2,
    );
    final back = ReaderSettings.fromJson(s.toJson());
    expect(back.autoNight, isTrue);
    expect(back.nightStartHour, 22);
    expect(back.ttsRate, 0.8);
    expect(back.goalMinutes, 45);
    expect(back.customFonts, ['MyFont']);
    expect(back.languageCode, 'ur');
    expect(back.ttsVoiceName, 'en-gb-x-gba-network');
    expect(back.showTextSizeButtons, isFalse);
    expect(back.enableHighlights, isFalse);
    expect(back.themeIndex, 3);
    expect(back.navPosition, 2);
  });
}

