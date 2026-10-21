import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkbloom_reader/formats.dart';
import 'package:inkbloom_reader/models.dart';
import 'package:inkbloom_reader/reader_prefs.dart';
import 'package:inkbloom_reader/transfer.dart';

void main() {
  test('TXT splits into chapters and search finds hits', () {
    final book = BookParser.parse(
      'my-book.txt',
      Uint8List.fromList(utf8.encode(
          'CHAPTER ONE\n\nThe garden was quiet.\n\nCHAPTER TWO\n\nThe garden bloomed again.')),
    );
    expect(book.format, 'txt');
    expect(book.chapters.length, 2);
    final lib = LibraryBook(
      id: 't1',
      title: book.title,
      author: book.author,
      format: book.format,
      chapters: book.chapters,
      addedAt: DateTime.now(),
    );
    final hits = searchBook(lib, 'garden');
    expect(hits.length, 2);
    expect(hits.first.snippet.contains('garden'), isTrue);
  });

  test('Markdown headings become chapters', () {
    final book = BookParser.parse(
      'notes.md',
      Uint8List.fromList(
          utf8.encode('# Start\n\nHello world.\n\n# Later\n\nGoodbye.')),
    );
    expect(book.chapters.length, 2);
    expect(book.chapters[1].title, 'Later');
  });

  test('paginate shrinks pages as font grows', () {
    final paras = List.generate(20, (i) => 'Word ' * 100);
    final small = paginate(paras, 14);
    final large = paginate(paras, 28);
    expect(large.length, greaterThan(small.length));
  });

  test('12 themes exist and settings round-trip through JSON', () {
    expect(readerThemes.length, 12);
    const s = ReaderSettings(fontSize: 22, themeIndex: 5, navPosition: 2);
    final back =
        ReaderSettings.fromJsonString(jsonEncode(s.toJson()));
    expect(back.fontSize, 22);
    expect(back.themeIndex, 5);
    expect(back.navPosition, 2);
  });

  test('transfer bundle round-trips books and settings', () {
    final book = LibraryBook(
      id: 'b1',
      title: 'Test',
      author: 'Author',
      chapters: const [],
      progress: 0.5,
      highlights: const [],
      addedAt: DateTime.now(),
    );
    final zip = TransferBundle.buildZip(
        books: [book], settingsJson: '{"fontSize":20}');
    final parsed = TransferBundle.parseZip(zip);
    expect(parsed.books.length, 1);
    expect(parsed.books.first.progress, 0.5);
    expect(parsed.settingsJson, '{"fontSize":20}');
  });
}
