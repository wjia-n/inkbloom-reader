import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Pure-Dart PDF text extractor.
///
/// HISTORY:
/// - v1 (2026-10-21): linear Tj/TJ scanner, Flate-only inflate.
///   Fast, but read every string as latin1 — so PDFs whose fonts
///   use a custom encoding (subset fonts, where a byte is a glyph
///   ID, not a letter) came out as garbage like "$IBQUFS".
///   That is exactly what the user photographed in a big novel
///   PDF: the app showed page after page of gibberish.
/// - v2 (2026-10-21): the fix. PDFs carry the real mapping in
///   their own font data, so the extractor now reads it:
///   * /ToUnicode CMaps (beginbfchar / beginbfrange) inside
///     inflated font streams — code -> real Unicode.
///   * /Differences arrays in font dictionaries — code ->
///     glyph name -> letter, for fonts without a CMap.
///   Each content stream is decoded both ways (with the maps,
///   and raw latin1 as before) and the more readable result
///   wins, so a wrong map can never make text worse than v1.
///   Also new: /Title + /Author from the PDF's own metadata
///   (so a downloaded "book_17925970589_10922_0.pdf" shows
///   its real title instead of its numeric filename), and the
///   first embedded JPEG as a real cover thumbnail.
///
/// Limits that stay honest: scanned/image PDFs still have no
/// text and are rejected by the caller; a PDF whose fonts carry
/// NO mapping at all cannot be decoded by any pure extractor.
String extractPdfTextFallback(Uint8List bytes) {
  final cmap = <int, String>{};
  final diff = <int, String>{};
  final contents = <String>[];
  var pos = 0;
  var streamsSeen = 0;
  while (true) {
    var streamAt = _indexOf(bytes, _streamMarker, pos);
    while (streamAt >= 3 &&
        bytes[streamAt - 3] == 101 &&
        bytes[streamAt - 2] == 110 &&
        bytes[streamAt - 1] == 100) {
      streamAt = _indexOf(bytes, _streamMarker, streamAt + _streamMarker.length);
      if (streamAt < 0) break;
    }
    if (streamAt < 0) break;
    var dataStart = streamAt + _streamMarker.length;
    if (dataStart < bytes.length && bytes[dataStart] == 13) dataStart++;
    if (dataStart < bytes.length && bytes[dataStart] == 10) dataStart++;
    final dictStart = dataStart > 1024 ? dataStart - 1024 : 0;
    final dictText = _ownDict(latin1.decode(
        bytes.sublist(dictStart, streamAt),
        allowInvalid: true));
    final isImage = dictText.contains('/Image') &&
        (dictText.contains('/Subtype') || dictText.contains('/XObject'));
    final isFont = dictText.contains('/FontFile') ||
        dictText.contains('/FontDescriptor');
    final lenMatches = RegExp(r'/Length\s+(\d+)').allMatches(dictText);
    final lenMatch = lenMatches.isEmpty ? null : lenMatches.last;
    int dataEnd;
    if (lenMatch != null) {
      final len = int.tryParse(lenMatch.group(1)!) ?? 0;
      dataEnd = dataStart + len;
      if (dataEnd > bytes.length) dataEnd = bytes.length;
    } else {
      final endAt = _indexOf(bytes, _endstreamMarker, dataStart);
      dataEnd = endAt < 0 ? bytes.length : endAt;
    }
    final streamLen = dataEnd - dataStart;
    pos = dataEnd;
    streamsSeen++;
    if (isImage || isFont) continue;
    if (streamLen <= 0 || streamLen > 1024 * 1024) continue;
    final streamBytes = bytes.sublist(dataStart, dataEnd);
    final isFlate = dictText.contains('/FlateDecode');
    String decoded;
    if (isFlate) {
      try {
        // latin1, NOT utf8: every byte must survive 1:1 so
        // CMap code lookup sees the true code values.
        decoded = latin1.decode(
            ZLibDecoder().convert(streamBytes),
            allowInvalid: true);
      } catch (_) {
        continue;
      }
    } else {
      decoded = latin1.decode(streamBytes, allowInvalid: true);
    }
    if (decoded.length > 1024 * 1024) continue;
    if (decoded.contains('beginbfchar') ||
        decoded.contains('beginbfrange')) {
      // A ToUnicode CMap: merge it, first mapping wins.
      for (final e in _parseCMap(decoded).entries) {
        cmap.putIfAbsent(e.key, () => e.value);
      }
      continue;
    }
    contents.add(decoded);
    if (streamsSeen > 20000) break;
  }
  // /Differences live in font dictionaries (plain text, not
  // streams). Scan the head of the file — font dictionaries
  // for the body fonts sit early; bound the scan for big files.
  final scanLen = bytes.length < 10 * 1024 * 1024
      ? bytes.length
      : 10 * 1024 * 1024;
  final head = latin1.decode(bytes.sublist(0, scanLen), allowInvalid: true);
  for (final m in RegExp(r'/Differences\s*\[(.*?)\]', dotAll: true)
      .allMatches(head)) {
    final body = m.group(1)!;
    if (body.length > 10000) continue;
    _parseDifferences(body, diff);
  }

  final out = StringBuffer();
  final useMaps = cmap.isNotEmpty || diff.isNotEmpty;
  for (final content in contents) {
    if (!useMaps) {
      out.write(_textFromContent(content, const {}, const {}));
    } else {
      final withMaps = _textFromContent(content, cmap, diff);
      final raw = _textFromContent(content, const {}, const {});
      out.write(_readability(withMaps) >= _readability(raw)
          ? withMaps
          : raw);
    }
    out.write('\n');
    if (out.length > 10 * 1024 * 1024) break;
  }
  if (out.toString().trim().isEmpty) {
    out.write(_textFromContent(
        latin1.decode(bytes, allowInvalid: true), const {}, const {}));
  }
  return out.toString().replaceAll(RegExp(r'[ \t]+'), ' ').trim();
}

/// How much of [text] reads like real prose: spaces, lowercase
/// letters, and non-ASCII letters (for non-English books) count;
/// uppercase gibberish, '$', and missing-glyph boxes do not.
/// Real prose scores ~0.6+; glyph-ID garbage scores near 0.
double _readability(String text) {
  if (text.isEmpty) return 0;
  var good = 0;
  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (c == 32 ||
        (c >= 97 && c <= 122) ||
        (c > 127 && c != 0xFFFD && c != 0x25A1 && c != 0x25AB)) {
      good++;
    }
  }
  return good / text.length;
}

/// Parse a ToUnicode CMap stream into code -> Unicode.
/// Handles beginbfchar pairs and beginbfrange ranges, both the
/// sequential form (<lo> <hi> <dst>) and the array form.
Map<int, String> _parseCMap(String cmap) {
  final map = <int, String>{};
  String decodeDst(List<int> b) {
    if (b.length >= 2 && b[0] == 0xFE && b[1] == 0xFF) b = b.sublist(2);
    if (b.length >= 2 && b.length.isEven) {
      final units = <int>[];
      for (var k = 0; k + 1 < b.length; k += 2) {
        units.add(b[k] * 256 + b[k + 1]);
      }
      while (units.isNotEmpty && units.last == 0) units.removeLast();
      if (units.isNotEmpty) return String.fromCharCodes(units);
    }
    if (b.length == 1) return String.fromCharCode(b[0]);
    return latin1.decode(b, allowInvalid: true);
  }

  int hexInt(String h) => int.tryParse(h, radix: 16) ?? -1;
  List<int> hexBytes(String h) {
    final bytes = <int>[];
    for (var k = 0; k + 1 < h.length; k += 2) {
      bytes.add(int.tryParse(h.substring(k, k + 2), radix: 16) ?? 32);
    }
    return bytes;
  }

  final bfchar = RegExp(r'beginbfchar(.*?)endbfchar', dotAll: true);
  for (final block in bfchar.allMatches(cmap)) {
    for (final m in RegExp(r'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>')
        .allMatches(block.group(1)!)) {
      final code = hexInt(m.group(1)!);
      if (code >= 0) {
        map.putIfAbsent(
            code, () => decodeDst(hexBytes(m.group(2)!)));
      }
    }
  }
  final bfrange = RegExp(r'beginbfrange(.*?)endbfrange', dotAll: true);
  for (final block in bfrange.allMatches(cmap)) {
    final body = block.group(1)!;
    for (final m in RegExp(
            r'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*(?:<([0-9A-Fa-f]+)>|\[([^\]]*)\])')
        .allMatches(body)) {
      final lo = hexInt(m.group(1)!);
      final hi = hexInt(m.group(2)!);
      if (lo < 0 || hi < lo || hi - lo > 10000) continue;
      if (m.group(3) != null) {
        final dst = hexBytes(m.group(3)!);
        var base = 0;
        if (dst.length >= 2 && dst.length.isEven) {
          base = dst[dst.length - 2] * 256 + dst[dst.length - 1];
        } else if (dst.length == 1) {
          base = dst[0];
        }
        for (var code = lo; code <= hi; code++) {
          final v = base + (code - lo);
          final ch = v > 0xFFFF
              ? String.fromCharCodes(
                  [0xD83D, 0xDE00 + (v - 0x10000) % 0x400])
              : String.fromCharCode(v);
          map.putIfAbsent(code, () => ch);
        }
      } else if (m.group(4) != null) {
        final dsts = RegExp(r'<([0-9A-Fa-f]+)>')
            .allMatches(m.group(4)!)
            .map((e) => decodeDst(hexBytes(e.group(1)!)))
            .toList();
        for (var code = lo; code <= hi; code++) {
          final idx = code - lo;
          if (idx < dsts.length) map.putIfAbsent(code, () => dsts[idx]);
        }
      }
    }
  }
  return map;
}

/// Parse one /Differences [...] body into code -> letter,
/// merging into [out] (first mapping wins).
void _parseDifferences(String body, Map<int, String> out) {
  var code = -1;
  final tokens = body.split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
  for (final tok in tokens) {
    if (tok.startsWith('/')) {
      if (code >= 0) {
        final ch = _glyphToChar(tok.substring(1));
        if (ch != null) out.putIfAbsent(code, () => ch);
        code++;
      }
    } else {
      code = int.tryParse(tok) ?? code;
    }
  }
}

/// Glyph name -> character for the names real PDFs use.
/// Single letters pass through; uniXXXX / uXXXX decode as hex.
String? _glyphToChar(String name) {
  if (name.length == 1) return name;
  if (name.startsWith('uni') && name.length >= 7) {
    final v = int.tryParse(name.substring(3, 7), radix: 16);
    if (v != null) return String.fromCharCode(v);
  }
  if (name.startsWith('u') && name.length >= 5) {
    final v = int.tryParse(name.substring(1), radix: 16);
    if (v != null && v <= 0x10FFFF) return String.fromCharCode(v);
  }
  const table = {
    'space': ' ', 'exclam': '!', 'quotedbl': '"', 'numbersign': '#',
    'dollar': r'$', 'percent': '%', 'ampersand': '&',
    'quotesingle': "'", 'parenleft': '(', 'parenright': ')',
    'asterisk': '*', 'plus': '+', 'comma': ',', 'hyphen': '-',
    'minus': '-', 'period': '.', 'slash': '/', 'colon': ':',
    'semicolon': ';', 'less': '<', 'equal': '=', 'greater': '>',
    'question': '?', 'at': '@', 'bracketleft': '[',
    'backslash': '\\', 'bracketright': ']', 'asciicircum': '^',
    'underscore': '_', 'grave': '`', 'braceleft': '{', 'bar': '|',
    'braceright': '}', 'asciitilde': '~', 'bullet': '•',
    'endash': '–', 'emdash': '—', 'quoteleft': '‘',
    'quoteright': '’', 'quotedblleft': '“', 'quotedblright': '”',
    'ellipsis': '…', 'Euro': '€', 'sterling': '£', 'yen': '¥',
    'copyright': '©', 'registered': '®', 'trademark': '™',
    'degree': '°', 'acute': '´', 'dieresis': '¨',
  };
  return table[name];
}

/// The PDF's own /Title and /Author, so a downloaded file with
/// a numeric name shows its real title in the library instead
/// of "book 17925970589 10922 0". Scans the head (Info objects
/// often sit early) and the tail (trailer region).
({String? title, String? author}) extractPdfMeta(Uint8List bytes) {
  String? find(String key) {
    final headLen = bytes.length < 1024 * 1024 ? bytes.length : 1024 * 1024;
    final tailStart =
        bytes.length > 512 * 1024 ? bytes.length - 512 * 1024 : 0;
    final parts = <String>[];
    parts.add(latin1.decode(bytes.sublist(0, headLen), allowInvalid: true));
    if (tailStart > headLen) {
      parts.add(latin1.decode(bytes.sublist(tailStart), allowInvalid: true));
    }
    for (final text in parts) {
      final idx = text.indexOf('/$key');
      if (idx < 0) continue;
      var i = idx + key.length + 1;
      while (i < text.length &&
          (text[i] == ' ' ||
              text[i] == '\t' ||
              text[i] == '\n' ||
              text[i] == '\r')) {
        i++;
      }
      String? value;
      if (i < text.length && text[i] == '(') {
        final atom = _readLiteral(text, i);
        if (atom != null) value = _decodeBytes(atom.$1, const {}, const {});
      } else if (i < text.length && text[i] == '<') {
        final atom = _readHex(text, i);
        if (atom != null) value = _decodeBytes(atom.$1, const {}, const {});
      }
      if (value != null) {
        value = value.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (value.isNotEmpty &&
            value != 'Untitled' &&
            value.length <= 300) {
          return value;
        }
      }
    }
    return null;
  }

  return (title: find('Title'), author: find('Author'));
}

/// First embedded JPEG in the file — the closest thing a PDF
/// has to a cover thumbnail. Returns null when the PDF has no
/// JPEG image (then the library keeps its generated cover).
Uint8List? extractPdfCover(Uint8List bytes) {
  var pos = 0;
  while (true) {
    var streamAt = _indexOf(bytes, _streamMarker, pos);
    while (streamAt >= 3 &&
        bytes[streamAt - 3] == 101 &&
        bytes[streamAt - 2] == 110 &&
        bytes[streamAt - 1] == 100) {
      streamAt =
          _indexOf(bytes, _streamMarker, streamAt + _streamMarker.length);
      if (streamAt < 0) break;
    }
    if (streamAt < 0) return null;
    var dataStart = streamAt + _streamMarker.length;
    if (dataStart < bytes.length && bytes[dataStart] == 13) dataStart++;
    if (dataStart < bytes.length && bytes[dataStart] == 10) dataStart++;
    final dictStart = dataStart > 1024 ? dataStart - 1024 : 0;
    final dictText = _ownDict(latin1.decode(
        bytes.sublist(dictStart, streamAt),
        allowInvalid: true));
    final isImage = dictText.contains('/Image') &&
        (dictText.contains('/Subtype') || dictText.contains('/XObject'));
    final isJpeg = dictText.contains('/DCTDecode');
    final lenMatches = RegExp(r'/Length\s+(\d+)').allMatches(dictText);
    final lenMatch = lenMatches.isEmpty ? null : lenMatches.last;
    int dataEnd;
    if (lenMatch != null) {
      final len = int.tryParse(lenMatch.group(1)!) ?? 0;
      dataEnd = dataStart + len;
      if (dataEnd > bytes.length) dataEnd = bytes.length;
    } else {
      final endAt = _indexOf(bytes, _endstreamMarker, dataStart);
      dataEnd = endAt < 0 ? bytes.length : endAt;
    }
    pos = dataEnd;
    if (!isImage || !isJpeg) continue;
    final len = dataEnd - dataStart;
    if (len < 1024 || len > 3 * 1024 * 1024) continue;
    if (bytes[dataStart] == 0xFF && bytes[dataStart + 1] == 0xD8) {
      return Uint8List.fromList(bytes.sublist(dataStart, dataEnd));
    }
  }
}

const _streamMarker = [115, 116, 114, 101, 97, 109]; // stream
const _endstreamMarker = [
  101, 110, 100, 115, 116, 114, 101, 97, 109
]; // endstream


/// The dictionary belonging to one stream: the << ... >> block
/// immediately before its "stream" marker. The old code used a
/// raw 1 KB window, which could reach back into the PREVIOUS
/// object's dictionary — so an uncompressed content stream
/// sitting after a Flate font stream was misread as Flate and
/// silently skipped (its ZLib inflate throws). That bug ate
/// whole pages. Matching << / >> nesting finds the real dict.
String _ownDict(String window) {
  final end = window.lastIndexOf('>>');
  if (end < 0) return window;
  var depth = 0;
  // end is the FIRST '>' of the pair, so start past both.
  var i = end + 2;
  while (i >= 2) {
    final two = window.substring(i - 2, i);
    if (two == '>>') {
      depth++;
      i -= 2;
    } else if (two == '<<') {
      depth--;
      i -= 2;
      if (depth == 0) return window.substring(i, end + 2);
    } else {
      i--;
    }
  }
  return window;
}

int _indexOf(Uint8List hay, List<int> needle, int from) {
  outer:
  for (var i = from; i + needle.length <= hay.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

/// Decode raw string bytes into text: via the font maps when
/// they have the code, otherwise the old raw behaviour (with
/// UTF-16BE BOM support for metadata-style strings).
String _decodeBytes(
    List<int> bytes, Map<int, String> cmap, Map<int, String> diff) {
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    final units = <int>[];
    for (var k = 2; k + 1 < bytes.length; k += 2) {
      units.add(bytes[k] * 256 + bytes[k + 1]);
    }
    while (units.isNotEmpty && units.last == 0) units.removeLast();
    return String.fromCharCodes(units);
  }
  if (cmap.isEmpty && diff.isEmpty) {
    return latin1.decode(bytes, allowInvalid: true);
  }
  final buf = StringBuffer();
  var i = 0;
  while (i < bytes.length) {
    if (i + 1 < bytes.length) {
      final code2 = bytes[i] * 256 + bytes[i + 1];
      final hit2 = cmap[code2];
      if (hit2 != null) {
        buf.write(hit2);
        i += 2;
        continue;
      }
    }
    final code1 = bytes[i];
    final hit1 = cmap[code1] ?? diff[code1];
    if (hit1 != null) {
      buf.write(hit1);
      i++;
      continue;
    }
    final b = code1;
    if (b >= 32 || b == 9 || b == 10 || b == 13) buf.writeCharCode(b);
    i++;
  }
  return buf.toString();
}

/// Linear Tj/TJ scanner: walks the content once, collecting
/// string atoms and emitting them only when a Tj (single),
/// TJ (array), ' or " operator follows. No regex, no
/// backtracking. Atoms are decoded through the font maps.
String _textFromContent(
    String content, Map<int, String> cmap, Map<int, String> diff) {
  final buf = StringBuffer();
  var i = 0;
  final n = content.length;
  bool isSpace(String c) =>
      c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f';
  void emit(List<int> atomBytes) {
    buf.write(_decodeBytes(atomBytes, cmap, diff));
    buf.write(' ');
  }

  bool followsShowOp() {
    var j = i;
    while (j < n && isSpace(content[j])) j++;
    if (j + 1 < n && content[j] == 'T' && content[j + 1] == 'j') {
      i = j + 2;
      return true;
    }
    if (j < n && (content[j] == "'" || content[j] == '"')) {
      i = j + 1;
      return true;
    }
    return false;
  }

  while (i < n) {
    final c = content[i];
    if (c == '%') {
      while (i < n && content[i] != '\n') i++;
      continue;
    }
    if (c == '(') {
      final atom = _readLiteral(content, i);
      if (atom == null) {
        i++;
        continue;
      }
      i = atom.$2;
      if (followsShowOp()) emit(atom.$1);
      continue;
    }
    if (c == '<' && i + 1 < n && content[i + 1] != '<') {
      final atom = _readHex(content, i);
      if (atom == null) {
        i++;
        continue;
      }
      i = atom.$2;
      if (followsShowOp()) emit(atom.$1);
      continue;
    }
    if (c == '[') {
      final atoms = <List<int>>[];
      i++;
      var ok = true;
      while (i < n && content[i] != ']') {
        final ch = content[i];
        if (ch == '(') {
          final atom = _readLiteral(content, i);
          if (atom == null) {
            ok = false;
            break;
          }
          atoms.add(atom.$1);
          i = atom.$2;
        } else if (ch == '<' &&
            i + 1 < n &&
            content[i + 1] != '<') {
          final atom = _readHex(content, i);
          if (atom == null) {
            ok = false;
            break;
          }
          atoms.add(atom.$1);
          i = atom.$2;
        } else {
          i++;
        }
      }
      if (i < n && content[i] == ']') i++;
      while (i < n && isSpace(content[i])) i++;
      if (ok && i + 1 < n && content[i] == 'T' && content[i + 1] == 'J') {
        for (final a in atoms) {
          buf.write(_decodeBytes(a, cmap, diff));
        }
        buf.write(' ');
        i += 2;
      }
      continue;
    }
    i++;
  }
  return buf.toString();
}

/// Read a PDF literal string starting at [start] ('(').
/// Returns (raw byte values, index just past ')'), or null if
/// the string is unterminated.
(List<int>, int)? _readLiteral(String s, int start) {
  final bytes = <int>[];
  var depth = 0;
  var i = start;
  final n = s.length;
  while (i < n) {
    final c = s[i];
    if (c == '\\' && i + 1 < n) {
      final e = s[i + 1];
      switch (e) {
        case 'n':
          bytes.add(10);
          break;
        case 'r':
          bytes.add(13);
          break;
        case 't':
          bytes.add(9);
          break;
        case 'b':
          bytes.add(8);
          break;
        case 'f':
          bytes.add(12);
          break;
        case '(':
        case ')':
        case '\\':
          bytes.add(e.codeUnitAt(0));
          break;
        default:
          if (e.codeUnitAt(0) >= 48 && e.codeUnitAt(0) <= 55) {
            var oct = '';
            var j = i + 1;
            while (j < n && j < i + 4 && s[j].codeUnitAt(0) >= 48 &&
                s[j].codeUnitAt(0) <= 55) {
              oct += s[j];
              j++;
            }
            bytes.add(int.tryParse(oct, radix: 8) ?? 32);
            i = j - 1;
          } else {
            bytes.add(e.codeUnitAt(0));
          }
      }
      i += 2;
      continue;
    }
    if (c == '(') depth++;
    if (c == ')') {
      depth--;
      if (depth == 0) return (bytes, i + 1);
    }
    if (depth > 0 && c != '(') bytes.add(c.codeUnitAt(0));
    i++;
  }
  return null;
}

/// Read a PDF hex string starting at [start] ('<').
/// Returns (raw bytes, index just past '>'), or null.
(List<int>, int)? _readHex(String s, int start) {
  final hex = StringBuffer();
  var i = start + 1;
  final n = s.length;
  while (i < n && s[i] != '>') {
    final c = s[i];
    if (c != ' ' &&
        c != '\t' &&
        c != '\n' &&
        c != '\r' &&
        c != '\f') {
      hex.write(c);
    }
    i++;
  }
  if (i >= n) return null;
  var h = hex.toString();
  if (h.length.isOdd) h += '0';
  final bytes = <int>[];
  for (var k = 0; k + 1 < h.length; k += 2) {
    bytes.add(int.tryParse(h.substring(k, k + 2), radix: 16) ?? 32);
  }
  return (bytes, i + 1);
}
