import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkbloom_reader/epub_parser.dart';

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

  test('rejects a zip with no OPF', () {
    final a = Archive();
    a.addFile(ArchiveFile('hello.txt', 5, utf8.encode('hello')));
    expect(
      () => EpubParser.parseBytes(Uint8List.fromList(ZipEncoder().encode(a)!)),
      throwsFormatException,
    );
  });
}
