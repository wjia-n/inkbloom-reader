import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:xml/xml.dart';
import 'epub_parser.dart';
import 'pdf_extract.dart';

/// A book parsed from any supported file format.
class ParsedBook {
  final String title;
  final String author;
  final String format;
  final List<EpubChapter> chapters;
  final Uint8List? coverBytes;
  const ParsedBook({
    required this.title,
    required this.author,
    required this.format,
    required this.chapters,
    this.coverBytes,
  });
}

/// Multi-format parser: EPUB (real, with cover), PDF (pure-Dart
/// text extraction — the native pdf_text plugin is incompatible
/// with AGP 9/Gradle 9, so it was removed),
/// TXT, Markdown, HTML, FictionBook (.fb2) and RTF.
/// MOBI/AZW are Amazon formats and are NOT supported: they are
/// usually DRM-wrapped, and the app says so instead of failing
/// silently. Convert those to EPUB first, then import.
class BookParser {
  static ParsedBook parse(String fileName, Uint8List bytes) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.epub')) {
      final e = EpubParser.parseBytes(bytes);
      return ParsedBook(
        title: e.title,
        author: e.author,
        format: 'epub',
        chapters: e.chapters,
        coverBytes: e.coverBytes,
      );
    }
    if (lower.endsWith('.fb2')) {
      return _parseFb2(_fileTitle(fileName), bytes);
    }
    if (lower.endsWith('.rtf')) {
      final plain = _rtfToText(utf8.decode(bytes, allowMalformed: true));
      return _parseTxt(_fileTitle(fileName), plain)
          .copyFormat('rtf');
    }
    if (lower.endsWith('.pdf')) {
      // PDF is async — use parsePdfFile instead.
      throw const FormatException(
          'PDF needs async parsing: use BookParser.parsePdfFile.');
    }
    final text = utf8.decode(bytes, allowMalformed: true);
    if (lower.endsWith('.md') || lower.endsWith('.markdown')) {
      return _parseMarkdown(_fileTitle(fileName), text);
    }
    if (lower.endsWith('.html') || lower.endsWith('.htm')) {
      final blocks = htmlToBlocks(text);
      final paras = blocks.map((b) => b.text).toList();
      return ParsedBook(
        title: _fileTitle(fileName),
        author: 'Unknown Author',
        format: 'html',
        chapters: [
          EpubChapter(title: _fileTitle(fileName), paragraphs: paras)
        ],
      );
    }
    // Default: .txt
    return _parseTxt(_fileTitle(fileName), text);
  }

  static String _fileTitle(String fileName) {
    final base = fileName.split('/').last.split('\\').last;
    final dot = base.lastIndexOf('.');
    final name = dot > 0 ? base.substring(0, dot) : base;
    return name.replaceAll(RegExp(r'[-_]+'), ' ').trim().isEmpty
        ? 'Untitled Book'
        : name.replaceAll(RegExp(r'[-_]+'), ' ').trim();
  }

  /// Parse a PDF file with the pure-Dart extractor (Tj/TJ text
  /// operators + Flate streams). No native plugin: pdf_text 0.5.0
  /// uses jcenter(), which Gradle 9 removed, so it breaks the
  /// AGP 9 build. Scanned/image PDFs have no text and are
  /// rejected honestly.
  static Future<ParsedBook> parsePdfFile(File file, String fileName) async {
    final title = _fileTitle(fileName);
    final bytes = await file.readAsBytes();
    final text = extractPdfTextFallback(bytes);
    if (text.isEmpty) {
      throw const FormatException(
          'Could not read this PDF. Scanned/image PDFs have no text to extract.');
    }
    return _parseTxt(title, text).copyFormat('pdf');
  }

  static ParsedBook _parseFb2(String title, Uint8List bytes) {
    try {
      final doc = XmlDocument.parse(utf8.decode(bytes, allowMalformed: true));
      var bookTitle = title;
      var author = 'Unknown Author';
      final titleInfo = doc.findAllElements('title-info').firstOrNull;
      if (titleInfo != null) {
        final bt = titleInfo.findElements('book-title').firstOrNull;
        if (bt != null && bt.innerText.trim().isNotEmpty) {
          bookTitle = bt.innerText.trim();
        }
        final au = titleInfo.findElements('author').firstOrNull;
        if (au != null) {
          final first = au.findElements('first-name').firstOrNull?.innerText ?? '';
          final last = au.findElements('last-name').firstOrNull?.innerText ?? '';
          final name = '$first $last'.trim();
          if (name.isNotEmpty) author = name;
        }
      }
      final chapters = <EpubChapter>[];
      for (final section in doc.findAllElements('section')) {
        final secTitle =
            section.findElements('title').firstOrNull?.innerText.trim() ??
                'Chapter ${chapters.length + 1}';
        final paras = section
            .findElements('p')
            .map((e) => e.innerText.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        if (paras.isNotEmpty) {
          chapters.add(EpubChapter(title: secTitle, paragraphs: paras));
        }
      }
      if (chapters.isEmpty) {
        throw const FormatException('No readable sections in this FB2 file.');
      }
      return ParsedBook(
          title: bookTitle, author: author, format: 'fb2', chapters: chapters);
    } catch (e) {
      if (e is FormatException) rethrow;
      throw const FormatException('Could not parse this FB2 file.');
    }
  }

  static String _rtfToText(String rtf) {
    var s = rtf;
    s = s.replaceAll(RegExp(r'\par\b'), '\n\n');
    s = s.replaceAllMapped(RegExp(r"'([0-9a-fA-F]{2})"), (m) {
      // RTF hex escapes are written as \'xx; the backslash is handled
      // by the control-word strip below, this handles the hex part.
      final v = int.tryParse(m.group(1)!, radix: 16);
      return v == null ? '' : String.fromCharCode(v);
    });
    // Drop control words and groups that are not text.
    s = s.replaceAll(RegExp(r'\\[a-zA-Z]+-?\d* ?'), ' ');
    s = s.replaceAll(RegExp(r'[{}]'), ' ');
    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static ParsedBook _parseMarkdown(String title, String text) {
    final chapters = <EpubChapter>[];
    var currentTitle = title;
    var current = <String>[];
    void flush() {
      if (current.isNotEmpty) {
        chapters.add(EpubChapter(title: currentTitle, paragraphs: [...current]));
        current = [];
      }
    }

    for (final rawLine in text.split('\n')) {
      final line = rawLine.trim();
      if (line.startsWith('#')) {
        flush();
        currentTitle = line.replaceAll(RegExp(r'^#+'), '').trim();
        if (currentTitle.isEmpty) currentTitle = title;
      } else if (line.isNotEmpty) {
        current.add(line);
      }
    }
    flush();
    if (chapters.isEmpty) {
      chapters.add(EpubChapter(title: title, paragraphs: [text.trim()]));
    }
    return ParsedBook(
      title: title,
      author: 'Unknown Author',
      format: 'md',
      chapters: chapters,
    );
  }

  static ParsedBook _parseTxt(String title, String text) {
    // Blank-line separated paragraphs; a new chapter every ~45 paragraphs,
    // or on a short all-caps / "Chapter N" heading line.
    final paras = text
        .split(RegExp(r'\n\s*\n'))
        .map((p) => p.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((p) => p.isNotEmpty)
        .toList();
    final chapters = <EpubChapter>[];
    var current = <String>[];
    var chapterNo = 1;
    void flush([String? heading]) {
      if (current.isNotEmpty) {
        chapters.add(EpubChapter(
            title: heading ?? 'Chapter $chapterNo', paragraphs: [...current]));
        current = [];
        chapterNo++;
      }
    }

    for (final p in paras) {
      final isHeading = RegExp(r'^(chapter|part|section)\s+\w+', caseSensitive: false)
              .hasMatch(p) ||
          (p.length < 60 && p == p.toUpperCase() && p.length > 3);
      if (isHeading && current.isNotEmpty) flush(p);
      if (current.length >= 45) flush();
      current.add(p);
    }
    flush();
    if (chapters.isEmpty) {
      chapters.add(EpubChapter(title: title, paragraphs: paras));
    }
    return ParsedBook(
      title: title,
      author: 'Unknown Author',
      format: 'txt',
      chapters: chapters,
    );
  }
}

/// Split a chapter's paragraphs into swipeable pages for Paged mode.
/// Page size shrinks as the font grows, so pages stay roughly full.
List<List<String>> paginate(List<String> paragraphs, double fontSize) {
  final budget = fontSize <= 16 ? 1400 : fontSize <= 20 ? 1000 : 700;
  final pages = <List<String>>[];
  var current = <String>[];
  var chars = 0;
  for (final p in paragraphs) {
    if (chars + p.length > budget && current.isNotEmpty) {
      pages.add([...current]);
      current = [];
      chars = 0;
    }
    current.add(p);
    chars += p.length;
  }
  if (current.isNotEmpty) pages.add(current);
  return pages;
}

extension ParsedBookFormat on ParsedBook {
  ParsedBook copyFormat(String format) => ParsedBook(
        title: title,
        author: author,
        format: format,
        chapters: chapters,
        coverBytes: coverBytes,
      );
}
