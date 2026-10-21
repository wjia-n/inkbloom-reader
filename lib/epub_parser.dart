import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// A parsed chapter: a heading plus readable paragraphs.
class EpubChapter {
  final String title;
  final List<String> paragraphs;
  const EpubChapter({required this.title, required this.paragraphs});
}

/// A parsed EPUB book. Pure Dart, no UI, fully unit-testable.
class ParsedEpub {
  final String title;
  final String author;
  final List<EpubChapter> chapters;
  final Uint8List? coverBytes;
  const ParsedEpub({
    required this.title,
    required this.author,
    required this.chapters,
    this.coverBytes,
  });
  int get totalParagraphs =>
      chapters.fold(0, (sum, c) => sum + c.paragraphs.length);
}

/// Minimal, dependency-light EPUB 2/3 parser.
/// Reads META-INF/container.xml -> OPF -> manifest + spine -> XHTML chapters.
class EpubParser {
  static ParsedEpub parseBytes(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    ArchiveFile? find(String path) {
      for (final f in archive.files) {
        if (f.name == path) return f;
      }
      return null;
    }

    ArchiveFile? findSuffix(String suffix) {
      for (final f in archive.files) {
        if (f.name.endsWith(suffix)) return f;
      }
      return null;
    }

    // 1. Locate the OPF via container.xml (fall back to any .opf file).
    String opfPath = '';
    final container = find('META-INF/container.xml');
    if (container != null) {
      try {
        final doc = XmlDocument.parse(utf8.decode(container.content));
        final rootfile = doc.findAllElements('rootfile').firstOrNull;
        opfPath = rootfile?.getAttribute('full-path') ?? '';
      } catch (_) {}
    }
    ArchiveFile? opfFile =
        opfPath.isNotEmpty ? find(opfPath) : findSuffix('.opf');
    if (opfFile == null) {
      throw const FormatException('Not a valid EPUB: no OPF package found.');
    }
    final opfDir = opfPath.contains('/')
        ? opfPath.substring(0, opfPath.lastIndexOf('/') + 1)
        : '';

    final opf = XmlDocument.parse(utf8.decode(opfFile.content));
    String meta(String tag) {
      final el = opf.findAllElements(tag).firstOrNull;
      return el?.innerText.trim() ?? '';
    }

    var title = meta('dc:title');
    if (title.isEmpty) title = 'Untitled Book';
    var author = meta('dc:creator');
    if (author.isEmpty) author = 'Unknown Author';

    // 2. Manifest: id -> (href, media-type, properties).
    final manifest = <String, ({String href, String type, String props})>{};
    for (final item in opf.findAllElements('item')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id != null && href != null) {
        manifest[id] = (
          href: href,
          type: item.getAttribute('media-type') ?? '',
          props: item.getAttribute('properties') ?? '',
        );
      }
    }

    // 3. Cover: properties="cover-image" wins, then id="cover".
    Uint8List? coverBytes;
    for (final entry in manifest.values) {
      if (entry.props.contains('cover-image') ||
          entry.type.startsWith('image/')) {
        // Only take the first image if it looks like a cover; keep it cheap.
        if (entry.props.contains('cover-image')) {
          final f = find(opfDir + entry.href) ?? find(entry.href);
          if (f != null) {
            coverBytes = Uint8List.fromList(f.content);
            break;
          }
        }
      }
    }
    coverBytes ??= () {
      final coverId = manifest.entries
          .where((e) => e.key.toLowerCase().contains('cover'))
          .firstOrNull;
      if (coverId != null) {
        final f = find(opfDir + coverId.value.href);
        if (f != null && coverId.value.type.startsWith('image/')) {
          return Uint8List.fromList(f.content);
        }
      }
      return null;
    }();

    // 4. Spine order -> chapters.
    final chapters = <EpubChapter>[];
    final spine = opf.findAllElements('itemref');
    for (final ref in spine) {
      final idref = ref.getAttribute('idref');
      final entry = idref == null ? null : manifest[idref];
      if (entry == null) continue;
      if (!entry.type.contains('html') &&
          !entry.href.endsWith('.xhtml') &&
          !entry.href.endsWith('.html') &&
          !entry.href.endsWith('.htm')) {
        continue;
      }
      final file = find(opfDir + entry.href) ?? find(entry.href);
      if (file == null) continue;
      final html = utf8.decode(file.content, allowMalformed: true);
      final blocks = htmlToBlocks(html);
      if (blocks.isEmpty) continue;
      final heading = blocks.firstWhere(
        (b) => b.isHeading,
        orElse: () => blocks.first,
      );
      chapters.add(EpubChapter(
        title: heading.text.length > 80
            ? '${heading.text.substring(0, 77)}…'
            : heading.text,
        paragraphs: blocks.map((b) => b.text).where((t) => t.isNotEmpty).toList(),
      ));
    }
    if (chapters.isEmpty) {
      throw const FormatException('EPUB has no readable chapters.');
    }
    return ParsedEpub(
      title: title,
      author: author,
      chapters: chapters,
      coverBytes: coverBytes,
    );
  }
}

class EpubBlock {
  final String text;
  final bool isHeading;
  const EpubBlock(this.text, this.isHeading);
}

/// Converts a small XHTML fragment into heading/paragraph blocks.
/// Headings are kept as the first block so chapter titles survive.
List<EpubBlock> htmlToBlocks(String html) {
  var s = html;
  // Drop head, script and style entirely.
  s = s.replaceAll(RegExp(r'<head[\s\S]*?</head>', caseSensitive: false), ' ');
  s = s.replaceAll(
      RegExp(r'<(script|style)[\s\S]*?</\1>', caseSensitive: false), ' ');
  final blocks = <EpubBlock>[];
  // Match headings and paragraphs in document order.
  final re = RegExp(
    r'<(h[1-3]|p|div)[^>]*>([\s\S]*?)</\1>',
    caseSensitive: false,
  );
  for (final m in re.allMatches(s)) {
    final tag = m.group(1)!.toLowerCase();
    var inner = m.group(2)!;
    inner = inner.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    inner = inner.replaceAll(RegExp(r'<[^>]+>'), ' ');
    inner = _unescape(inner).replaceAll(RegExp(r'[ \t]+'), ' ').trim();
    if (inner.isEmpty) continue;
    // Split on newlines inside a block into separate paragraphs.
    final parts = inner
        .split('\n')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty);
    var first = true;
    for (final part in parts) {
      blocks.add(EpubBlock(part, tag.startsWith('h') && first));
      first = false;
    }
  }
  // Fallback: whole document as one block if no p/h tags were found.
  if (blocks.isEmpty) {
    final plain = _unescape(s.replaceAll(RegExp(r'<[^>]+>'), ' '))
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (plain.isNotEmpty) blocks.add(EpubBlock(plain, false));
  }
  return blocks;
}

String _unescape(String s) {
  return s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'");
}
