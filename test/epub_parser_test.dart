import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkbloom_reader/epub_parser.dart';
import 'package:inkbloom_reader/models.dart';
import 'package:inkbloom_reader/pdf_extract.dart';

Uint8List makeEpub() {
  final a = Archive();
  void add(String name, String text) {
    a.addFile(ArchiveFile(name, text.length, utf8.encode(text)));
  }

  add('mimetype', 'application/epub+zip');
  add(
    'META-INF/container.xml',
    '<?xml version="1.0"?><container version="1.0">'
    '<rootfiles><rootfile full-path="OEBPS/content.opf" '
    'media-type="application/oebps-package+xml"/></rootfiles></container>',
  );
  add(
    'OEBPS/content.opf',
    '<?xml version="1.0"?><package xmlns:dc="http://purl.org/dc/elements/1.1/">'
    '<metadata><dc:title>Test Garden</dc:title>'
    '<dc:creator>Test Author</dc:creator></metadata>'
    '<manifest>'
    '<item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>'
    '<item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>'
    '</manifest>'
    '<spine><itemref idref="c1"/><itemref idref="c2"/></spine>'
    '</package>',
  );
  add(
    'OEBPS/ch1.xhtml',
    '<html><body><h1>One</h1><p>Hello world.</p>'
    '<p>Second paragraph &amp; more.</p></body></html>',
  );
  add(
    'OEBPS/ch2.xhtml',
    '<html><body><h1>Two</h1><p>Final chapter.</p></body></html>',
  );
  return Uint8List.fromList(ZipEncoder().encode(a)!);
}

void main() {
  test('parses title, author, spine order and paragraphs', () {
    final book = EpubParser.parseBytes(makeEpub());
    expect(book.title, 'Test Garden');
    expect(book.author, 'Test Author');
    expect(book.chapters.length, 2);
    expect(book.chapters[0].title, 'One');
    expect(book.chapters[0].paragraphs, contains('Hello world.'));
    expect(book.chapters[0].paragraphs, contains('Second paragraph & more.'));
    expect(book.chapters[1].title, 'Two');
  });

  test('cover found via EPUB 2 meta tag with encoded hrefs', () {
    final a = Archive();
    void add(String name, List<int> data) {
      a.addFile(ArchiveFile(name, data.length, data));
    }
    add('mimetype', utf8.encode('application/epub+zip'));
    add('META-INF/container.xml', utf8.encode(
        '<?xml version="1.0"?><container><rootfiles>'
        '<rootfile full-path="OEBPS/content.opf"/>'
        '</rootfiles></container>'));
    add('OEBPS/content.opf', utf8.encode(
        '<?xml version="1.0"?><package>'
        '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
        '<dc:title>Meta Cover Book</dc:title>'
        '<meta name="cover" content="cov"/></metadata>'
        '<manifest>'
        '<item id="cov" href="images/my%20cover.png" media-type="image/png"/>'
        '<item id="ch1" href="ch%201.xhtml" media-type="application/xhtml+xml"/>'
        '</manifest><spine><itemref idref="ch1"/></spine></package>'));
    add('OEBPS/ch 1.xhtml', utf8.encode('<html><body><p>Hello world</p></body></html>'));
    add('OEBPS/images/my cover.png', [1, 2, 3, 4]);
    final book = EpubParser.parseBytes(Uint8List.fromList(ZipEncoder().encode(a)!));
    expect(book.title, 'Meta Cover Book');
    expect(book.coverBytes, isNotNull);
    expect(book.chapters.first.paragraphs, contains('Hello world'));
  });

  test('pdf hex utf16 text is read', () {
    final pdf = utf8.encode(
        '%PDF-1.4\n1 0 obj<</Length 40>>stream\n'
        'BT /F1 12 Tf <FEFF004800690020> Tj ET\nendstream\nendobj\n');
    // Note: stream length above is intentionally loose; the
    // extractor falls back to endstream when Length is off.
    final text = extractPdfTextFallback(Uint8List.fromList(pdf));
    expect(text, contains('Hi'));
  });

  test('history sorts by last read, current book first', () {
    final now = DateTime.now();
    final a = LibraryBook(
        id: 'a', title: 'Old', author: 'A', chapters: const [],
        addedAt: now.subtract(const Duration(days: 5)),
        lastReadAt: now.subtract(const Duration(days: 2)), progress: 0.5);
    final b = LibraryBook(
        id: 'b', title: 'New', author: 'B', chapters: const [],
        addedAt: now.subtract(const Duration(days: 4)),
        lastReadAt: now, progress: 0.2);
    final history = [a, b]
      ..sort((x, y) => (y.lastReadAt ?? y.addedAt)
          .compareTo(x.lastReadAt ?? x.addedAt));
    expect(history.first.id, 'b');
  });

  test('rejects a zip with no OPF', () {
    final a = Archive();
    a.addFile(ArchiveFile('hello.txt', 5, utf8.encode('hello')));
    expect(
      () => EpubParser.parseBytes(Uint8List.fromList(ZipEncoder().encode(a)!)),
      throwsFormatException,
    );
  });
}
