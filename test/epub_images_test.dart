import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkbloom_reader/epub_parser.dart';

Uint8List buildEpub(String xhtml, {Map<String, Uint8List> extra = const {}}) {
  final archive = Archive();
  void add(String name, List<int> bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  add(
    'META-INF/container.xml',
    utf8.encode(
        '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'),
  );
  add(
    'OEBPS/content.opf',
    utf8.encode(
        '<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Art Book</dc:title><dc:creator>Author</dc:creator></metadata><manifest><item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>${extra.keys.map((k) => '<item id="img-$k" href="$k" media-type="image/png"/>').join()}</manifest><spine><itemref idref="ch1"/></spine></package>'),
  );
  add('OEBPS/ch1.xhtml', utf8.encode(xhtml));
  for (final e in extra.entries) {
    add('OEBPS/${e.key}', e.value);
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

void main() {
  test('Illustrations stay in order and bytes reach the reader', () {
    final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]);
    final epub = buildEpub(
      '<html><body><h1>Ch 1</h1><p>Before art.</p>'
      '<p><img src="pic.png" alt="art"/></p><p>After art.</p></body></html>',
      extra: {'pic.png': png},
    );
    final parsed = EpubParser.parseBytes(epub);
    expect(parsed.chapters.length, 1);
    expect(parsed.chapters.first.paragraphs, [
      'Ch 1',
      'Before art.',
      '${kEpubImageMarker}0',
      'After art.',
    ]);
    expect(parsed.images.length, 1);
    expect(parsed.images.first, png);
  });

  test('An image file that is missing is skipped, not a broken marker', () {
    final epub = buildEpub(
      '<html><body><p>Text.</p><p><img src="gone.png"/></p></body></html>',
    );
    final parsed = EpubParser.parseBytes(epub);
    expect(parsed.chapters.first.paragraphs, ['Text.']);
    expect(parsed.images, isEmpty);
  });

  test('An image-only chapter is kept as an art chapter', () {
    final png = Uint8List.fromList([9, 9, 9]);
    final epub = buildEpub(
      '<html><body><p><img src="pic.png"/></p></body></html>',
      extra: {'pic.png': png},
    );
    final parsed = EpubParser.parseBytes(epub);
    expect(parsed.chapters.length, 1);
    expect(parsed.chapters.first.title, 'Images');
    expect(parsed.chapters.first.paragraphs, ['${kEpubImageMarker}0']);
    expect(parsed.images.length, 1);
  });
}
