import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
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
  /// EPUB illustrations, in marker order (see kEpubImageMarker
  /// in epub_parser.dart). Other formats leave this empty.
  final List<Uint8List> images;
  const ParsedBook({
    required this.title,
    required this.author,
    required this.format,
    required this.chapters,
    this.coverBytes,
    this.images = const [],
  });
}

/// Multi-format parser: EPUB (real, with cover), PDF (pure-Dart
/// text extraction — the native pdf_text plugin is incompatible
/// with AGP 9/Gradle 9, so it was removed),
/// TXT, Markdown, HTML, FictionBook (.fb2), RTF, Word (.docx)
/// and OpenDocument (.odt). Both office formats are ZIPs of
/// XML, so they parse with the same archive+xml tools as EPUB.
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
        images: e.images,
      );
    }
    if (lower.endsWith('.fb2')) {
      return _parseFb2(_fileTitle(fileName), bytes);
    }
    if (lower.endsWith('.docx')) {
      return _parseDocx(_fileTitle(fileName), bytes);
    }
    if (lower.endsWith('.odt')) {
      return _parseOdt(_fileTitle(fileName), bytes);
    }
    if (lower.endsWith('.rtf')) {
      final plain = _rtfToText(decodeTextBytes(bytes));
      return _parseTxt(_fileTitle(fileName), plain)
          .copyFormat('rtf');
    }
    if (lower.endsWith('.pdf')) {
      // PDF is async — use parsePdfFile instead.
      throw const FormatException(
          'PDF needs async parsing: use BookParser.parsePdfFile.');
    }
    final text = decodeTextBytes(bytes);
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

  /// Exact imported filename stem: no cleaning at all, so a
  /// PDF shows precisely the name it had when downloaded.
  static String fileTitleExact(String fileName) {
    final base = fileName.split('/').last.split('\\').last;
    final dot = base.lastIndexOf('.');
    final stem = dot > 0 ? base.substring(0, dot) : base;
    return stem.isEmpty ? 'Untitled Book' : stem;
  }

  static String _fileTitleExact(String fileName) =>
      fileTitleExact(fileName);

  /// Decode book text bytes the way real files are actually
  /// saved: UTF-8 (with or without BOM), UTF-16 with a BOM or
  /// by shape (every second byte zero), and Windows-1252 as
  /// the last resort. The old code used utf8 with
  /// allowMalformed, which turned every non-UTF-8 byte — smart
  /// quotes, accented letters, whole non-English passages —
  /// into replacement characters, i.e. unreadable words.
  static String decodeTextBytes(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
      return utf8.decode(bytes.sublist(3), allowMalformed: true);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return _decodeUtf16(bytes.sublist(2), littleEndian: true);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return _decodeUtf16(bytes.sublist(2), littleEndian: false);
    }
    // UTF-16 without a BOM: ASCII text with a zero byte
    // between every letter is the giveaway.
    if (bytes.length >= 40 && bytes.length.isEven) {
      var zerosEven = 0;
      var zerosOdd = 0;
      final sample = bytes.length < 400 ? bytes.length : 400;
      for (var k = 0; k < sample; k++) {
        if (bytes[k] == 0) {
          if (k.isEven) {
            zerosEven++;
          } else {
            zerosOdd++;
          }
        }
      }
      if (zerosEven > sample * 0.35) {
        return _decodeUtf16(bytes, littleEndian: true);
      }
      if (zerosOdd > sample * 0.35) {
        return _decodeUtf16(bytes, littleEndian: false);
      }
    }
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return bytes.map(win1252Char).join();
    }
  }

  static String _decodeUtf16(Uint8List bytes,
      {required bool littleEndian}) {
    final units = <int>[];
    for (var k = 0; k + 1 < bytes.length; k += 2) {
      units.add(littleEndian
          ? bytes[k] + bytes[k + 1] * 256
          : bytes[k] * 256 + bytes[k + 1]);
    }
    return String.fromCharCodes(units);
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
    final bytes = await file.readAsBytes();
    return parsePdfBytes(bytes, fileName);
  }

  /// PDF from raw bytes (used by the isolate import path, which has
  /// no File access on the worker side).
  static ParsedBook parsePdfBytes(Uint8List bytes, String fileName) {
    // Display title = the EXACT name the user imported, stem
    // only (no underscore cleaning, no metadata override).
    // v1.1.1 used the PDF's metadata title here, and the user
    // rightly read that as "the app renamed my book": she
    // knows her downloads by their filenames. Metadata is
    // still used for the author, which never renames anything.
    final meta = extractPdfMeta(bytes);
    final title = _fileTitleExact(fileName);
    final text = extractPdfTextFallback(bytes);
    if (text.isEmpty) {
      throw const FormatException(
          'Could not read this PDF. Scanned/image PDFs have no text to extract.');
    }
    return ParsedBook(
      title: title,
      author: meta.author ?? 'Unknown Author',
      format: 'pdf',
      chapters: splitPdfChapters(text, title),
      coverBytes: extractPdfCover(bytes),
    );
  }

  /// Word .docx: ZIP, text lives in word/document.xml as
  /// <w:t> runs inside <w:p> paragraphs. Heading styles
  /// (Heading 1) start a new chapter, like an EPUB.
  static ParsedBook _parseDocx(String title, Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    String? findXml(String path) {
      for (final f in archive.files) {
        if (f.name == path) {
          return utf8.decode(f.content as List<int>, allowMalformed: true);
        }
      }
      return null;
    }
    var bookTitle = title;
    var author = 'Unknown Author';
    final core = findXml('docProps/core.xml');
    if (core != null) {
      try {
        final doc = XmlDocument.parse(core);
        final t = doc.findAllElements('dc:title').firstOrNull;
        if (t != null && t.innerText.trim().isNotEmpty) {
          bookTitle = t.innerText.trim();
        }
        final a = doc.findAllElements('dc:creator').firstOrNull;
        if (a != null && a.innerText.trim().isNotEmpty) {
          author = a.innerText.trim();
        }
      } catch (_) {}
    }
    final xml = findXml('word/document.xml');
    if (xml == null) {
      throw const FormatException('This DOCX has no document text.');
    }
    final doc = XmlDocument.parse(xml);
    final chapters = <EpubChapter>[];
    var curTitle = bookTitle;
    var cur = <String>[];
    void flush() {
      if (cur.isNotEmpty) {
        chapters.add(EpubChapter(title: curTitle, paragraphs: cur));
        cur = <String>[];
      }
    }
    for (final para in doc.findAllElements('w:p')) {
      final text = para
          .findAllElements('w:t')
          .map((e) => e.innerText)
          .join('');
      if (text.trim().isEmpty) continue;
      final style = para
          .findElements('w:pPr')
          .firstOrNull
          ?.findElements('w:pStyle')
          .firstOrNull
          ?.getAttribute('w:val');
      if (style != null && style.toLowerCase().contains('heading1')) {
        flush();
        curTitle = text.trim();
      } else {
        cur.add(text);
      }
    }
    flush();
    if (chapters.isEmpty) {
      throw const FormatException('This DOCX has no readable text.');
    }
    return ParsedBook(
        title: bookTitle,
        author: author,
        format: 'docx',
        chapters: chapters);
  }

  /// OpenDocument .odt: ZIP, text lives in content.xml as
  /// <text:p> paragraphs and <text:h> headings. Headings
  /// start a new chapter.
  static ParsedBook _parseOdt(String title, Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    String? xml;
    for (final f in archive.files) {
      if (f.name == 'content.xml') {
        xml = utf8.decode(f.content as List<int>, allowMalformed: true);
        break;
      }
    }
    if (xml == null) {
      throw const FormatException('This ODT has no document text.');
    }
    final doc = XmlDocument.parse(xml);
    final chapters = <EpubChapter>[];
    var curTitle = title;
    var cur = <String>[];
    void flush() {
      if (cur.isNotEmpty) {
        chapters.add(EpubChapter(title: curTitle, paragraphs: cur));
        cur = <String>[];
      }
    }
    for (final el in doc.descendants.whereType<XmlElement>()) {
      if (el.name.local == 'h') {
        final text = el.innerText.trim();
        if (text.isEmpty) continue;
        flush();
        curTitle = text;
      } else if (el.name.local == 'p') {
        final text = el.innerText.trim();
        if (text.isNotEmpty) cur.add(text);
      }
    }
    flush();
    if (chapters.isEmpty) {
      throw const FormatException('This ODT has no readable text.');
    }
    return ParsedBook(
        title: title,
        author: 'Unknown Author',
        format: 'odt',
        chapters: chapters);
  }

  static ParsedBook _parseFb2(String title, Uint8List bytes) {
    try {
      final doc = XmlDocument.parse(decodeTextBytes(bytes));
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

  /// RTF -> plain text, done with a real scanner, not regexes.
  /// Why it had to be rewritten (user bug, 2026-10-22): the old
  /// version dropped every \\uN unicode escape as if it were a
  /// formatting word, decoded \\'xx hex escapes as latin1
  /// (so smart quotes and dashes became control characters),
  /// let font-table names, info metadata and PICTURE BINARY
  /// leak into the book as garbage words, and collapsed all
  /// paragraph breaks into one giant paragraph. Non-English
  /// RTF books came out as unreadable words — or lost letters.
  /// This version: \\uN unicode (with \\ucN fallback skipping),
  /// \\'xx as Windows-1252, font/colour/stylesheet/info/picture
  /// groups skipped whole, paragraph breaks kept.
  static String _rtfToText(String rtf) {
    const skipGroups = {
      'fonttbl', 'colortbl', 'stylesheet', 'info', 'pict', 'object',
      'header', 'footer', 'footnote', 'generator', 'themedata',
      'colorschememapping', 'latentstyles', 'datastore',
    };
    final out = StringBuffer();
    var i = 0;
    final n = rtf.length;
    var ucSkip = 1;
    var skipDepth = 0;
    final groupSkipped = <bool>[];
    bool isLetter(String c) =>
        (c.codeUnitAt(0) >= 65 && c.codeUnitAt(0) <= 90) ||
        (c.codeUnitAt(0) >= 97 && c.codeUnitAt(0) <= 122);
    while (i < n) {
      final c = rtf[i];
      if (c == '{') {
        var skipped = false;
        if (i + 1 < n && rtf[i + 1] == '\\') {
          if (i + 2 < n && rtf[i + 2] == '*') {
            skipped = true; // destination group (\*\generator...)
          } else {
            final m =
                RegExp(r'\\([a-zA-Z]+)').matchAsPrefix(rtf, i + 1);
            if (m != null && skipGroups.contains(m.group(1))) {
              skipped = true;
            }
          }
        }
        groupSkipped.add(skipped);
        if (skipped) skipDepth++;
        i++;
        continue;
      }
      if (c == '}') {
        if (groupSkipped.isNotEmpty && groupSkipped.removeLast()) {
          skipDepth--;
        }
        i++;
        continue;
      }
      if (skipDepth > 0) {
        i++;
        continue;
      }
      if (c == '\\') {
        if (i + 1 >= n) break;
        final nx = rtf[i + 1];
        if (nx == "'") {
          if (i + 3 < n) {
            final v = int.tryParse(rtf.substring(i + 2, i + 4), radix: 16);
            if (v != null) out.write(win1252Char(v));
            i += 4;
          } else {
            i += 2;
          }
          continue;
        }
        if (!isLetter(nx)) {
          if (nx == '~') {
            out.write(' ');
          } else if (nx == '_') {
            out.write('-');
          } else if (nx != '-' && nx != '\n' && nx != '\r') {
            out.write(nx);
          }
          i += 2;
          continue;
        }
        final m =
            RegExp(r"\\([a-zA-Z]+)(-?\d*) ?").matchAsPrefix(rtf, i);
        if (m == null) {
          i++;
          continue;
        }
        final word = m.group(1)!;
        final arg = m.group(2);
        i = m.end;
        switch (word) {
          case 'par':
          case 'line':
            out.write('\n\n');
            break;
          case 'tab':
            out.write('\t');
            break;
          case 'uc':
            ucSkip = int.tryParse(arg ?? '') ?? 1;
            if (ucSkip < 0) ucSkip = 0;
            break;
          case 'u':
            var v = int.tryParse(arg ?? '') ?? 0;
            if (v < 0) v += 65536;
            out.writeCharCode(v);
            var left = ucSkip;
            while (left > 0 && i < n) {
              if (rtf[i] == '\\' && i + 1 < n && rtf[i + 1] == "'") {
                i += 4;
              } else {
                i++;
              }
              left--;
            }
            break;
          default:
            break;
        }
        continue;
      }
      if (c == '\n' || c == '\r') {
        out.write(' ');
        i++;
        continue;
      }
      out.write(c);
      i++;
    }
    var text = out.toString().replaceAll(RegExp(r'[ \t]+'), ' ');
    text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return text.trim();
  }


  /// Split PDF extractor output into real chapters.
  ///
  /// The extractor emits one line per text show operation, so
  /// blank-line paragraph splitting (used for TXT) sees a whole
  /// PDF as a single paragraph — which is why PDFs used to show
  /// "Chapter 1 of 1" and why the reader had to lay out one
  /// million-character paragraph (slow to open). This splitter
  /// works line by line: a line that looks like a chapter
  /// heading starts a new chapter, and the lines inside a
  /// chapter are grouped into readable paragraphs.
  ///
  /// Headings come in three shapes, all seen in real novels:
  /// "Chapter 12", "Chapter 12: The Inn", "Chapter 12 The first
  /// time…" (heading glued to the first sentence), and the
  /// letter-spaced form the extractor produces when a PDF
  /// spaces its glyphs: "C h a p t e r 1 …". Prologue and
  /// Epilogue count as chapters too. A book with no headings
  /// at all falls back to 45-paragraph sections, the same rule
  /// TXT already uses, so the chapters menu is never empty.
  /// The split is prefix-safe: splitting a prefix of the text
  /// (the fast first-pages preview) gives chapters that are a
  /// prefix of splitting the whole text, so swapping the preview
  /// for the full parse never moves text the reader already
  /// shows above the current position.
  static List<EpubChapter> splitPdfChapters(String text, String bookTitle) {
    final chapters = <EpubChapter>[];
    var paras = <String>[];
    String? curTitle;
    var foundHeading = false;
    final curPara = StringBuffer();
    void flushPara() {
      if (curPara.isNotEmpty) {
        paras.add(curPara.toString());
        curPara.clear();
      }
    }

    void flushChapter() {
      if (paras.isNotEmpty) {
        chapters.add(EpubChapter(
            title: curTitle ?? bookTitle, paragraphs: [...paras]));
        paras = [];
      }
    }

    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) {
        flushPara();
        continue;
      }
      final heading = _pdfHeading(line);
      if (heading != null) {
        flushPara();
        flushChapter();
        curTitle = heading.title;
        foundHeading = true;
        if (heading.rest.isNotEmpty) curPara.write(heading.rest);
        continue;
      }
      if (curPara.isNotEmpty) curPara.write(' ');
      curPara.write(line);
      if (curPara.length > 900) flushPara();
    }
    flushPara();
    flushChapter();
    if (chapters.isEmpty) {
      return [EpubChapter(title: bookTitle, paragraphs: const [])];
    }
    if (!foundHeading) {
      // No headings: section the book so the chapters menu
      // still lets the reader jump around, mirroring _parseTxt.
      final all = chapters.expand((c) => c.paragraphs).toList();
      if (all.length > 45) {
        final sections = <EpubChapter>[];
        for (var i = 0; i < all.length; i += 45) {
          sections.add(EpubChapter(
              title: 'Chapter ${sections.length + 1}',
              paragraphs: all.sublist(
                  i, i + 45 > all.length ? all.length : i + 45)));
        }
        return sections;
      }
      return [EpubChapter(title: bookTitle, paragraphs: all)];
    }
    return chapters;
  }

  static const _numberWords = {
    'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight',
    'nine', 'ten', 'eleven', 'twelve', 'thirteen', 'fourteen',
    'fifteen', 'sixteen', 'seventeen', 'eighteen', 'nineteen',
    'twenty',
  };

  static bool _isRoman(String s) =>
      s.isNotEmpty && RegExp(r'^[ivxlcdm]+$').hasMatch(s);

  static String _normalizeNumber(String num) {
    if (RegExp(r'^[0-9]+$').hasMatch(num)) return num;
    if (_isRoman(num.toLowerCase())) return num.toUpperCase();
    return num[0].toUpperCase() + num.substring(1).toLowerCase();
  }

  static String _collapseSpaces(String s) =>
      s.replaceAll(RegExp(r'\s+'), ' ').trim();

  /// A chapter heading line, or null. Returns the heading title
  /// and any text after the heading on the same line (a heading
  /// glued to its first sentence).
  static ({String title, String rest})? _pdfHeading(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return null;
    // Normal style: "Chapter 12", "Chapter 12: The Inn",
    // "Chapter 12 The first time…" (long line: split it).
    final normal = RegExp(
            r'^(chapter|part|section|prologue|epilogue)\s+([0-9]+|[ivxlcdm]+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty)\b',
            caseSensitive: false)
        .firstMatch(trimmed);
    if (normal != null) {
      final word = normal.group(1)!;
      final titleWord =
          word[0].toUpperCase() + word.substring(1).toLowerCase();
      final num = _normalizeNumber(normal.group(2)!);
      final rest = trimmed
          .substring(normal.end)
          .trim()
          .replaceFirst(RegExp(r'^[:.\-\u2013\u2014]\s*'), '');
      if (trimmed.length <= 80) {
        // Short line: the whole line is the heading, subtitle
        // and all ("Chapter 12: The Inn").
        return (title: _collapseSpaces(trimmed), rest: '');
      }
      return (title: '$titleWord $num', rest: rest);
    }
    // Bare "Prologue" / "Epilogue" on its own line.
    final flat = trimmed.replaceAll(RegExp(r'\s+'), '').toLowerCase();
    if (flat == 'prologue' || flat == 'epilogue') {
      return (title: flat[0].toUpperCase() + flat.substring(1), rest: '');
    }
    // Letter-spaced style: "C h a p t e r 1 …". Walk single
    // letters until the chapter word is spelled out, then take
    // the number (digits, or a spelled number word).
    final tokens = trimmed.split(RegExp(r'\s+'));
    var i = 0;
    var buf = '';
    while (i < tokens.length && tokens[i].length == 1) {
      buf += tokens[i];
      i++;
      final low = buf.toLowerCase();
      if (low == 'chapter' || low == 'part' || low == 'section') break;
    }
    final spelled = buf.toLowerCase();
    if (spelled == 'chapter' || spelled == 'part' || spelled == 'section') {
      String? num;
      if (i < tokens.length && RegExp(r'^[0-9]+$').hasMatch(tokens[i])) {
        num = tokens[i];
        i++;
      } else {
        var j = i;
        var buf2 = '';
        while (j < tokens.length && tokens[j].length == 1) {
          buf2 += tokens[j];
          j++;
        }
        final w = buf2.toLowerCase();
        if (_numberWords.contains(w) || _isRoman(w)) {
          num = buf2;
          i = j;
        }
      }
      if (num != null) {
        final titleWord =
            spelled[0].toUpperCase() + spelled.substring(1);
        return (
          title: '$titleWord ${_normalizeNumber(num)}',
          rest: tokens.sublist(i).join(' '),
        );
      }
    }
    return null;
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

/// Page holding paragraph [para] in [pages] (from paginate).
/// Out-of-range paragraphs clamp to the last page; empty
/// input gives page 0. Used both for the initial page on
/// open and for re-jumping when the full PDF text lands.
int pageIndexForParagraph(List<List<String>> pages, int para) {
  if (pages.isEmpty) return 0;
  var cum = 0;
  for (var pi = 0; pi < pages.length; pi++) {
    if (cum + pages[pi].length > para) return pi;
    cum += pages[pi].length;
  }
  return pages.length - 1;
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
