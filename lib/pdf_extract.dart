import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Pure-Dart PDF text extractor.
///
/// WHY THIS VERSION EXISTS (user bug, 2026-10-21): a real 2.6 MB
/// lecture PDF spun "Opening your book…" for 2 minutes and then
/// died with a TimeoutException. Root cause, not a guess: the
/// previous version tried to ZLib-inflate EVERY stream — including
/// huge JPEG image streams and font streams — and then ran a
/// backtracking regex over the resulting binary garbage, and
/// over the whole file again as a last resort. On a slide-heavy
/// PDF that is quadratic work on megabytes of junk.
///
/// This version is linear and selective:
/// - Image streams (/Subtype /Image) and embedded font streams
///   (/FontFile) are skipped outright — they contain no text.
/// - ZLib inflation is only attempted for /FlateDecode streams.
///   Uncompressed text streams are read as-is.
/// - Streams over 1 MB that are not Flate text are skipped.
/// - Text is pulled with a small linear scanner over Tj/TJ
///   operators, never a backtracking regex over binary data.
/// - The whole-file last resort uses the same linear scanner,
///   so it is O(file size), not O(file size squared).
/// Scanned/image PDFs still have no text and are honestly
/// rejected by the caller.
String extractPdfTextFallback(Uint8List bytes) {
  final out = StringBuffer();
  var pos = 0;
  var streamsSeen = 0;
  while (true) {
    var streamAt = _indexOf(bytes, _streamMarker, pos);
    // "endstream" contains "stream": skip those false hits.
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
    // Dictionary just before this stream (up to 1 KB back).
    final dictStart = dataStart > 1024 ? dataStart - 1024 : 0;
    final dictText = latin1.decode(bytes.sublist(dictStart, streamAt),
        allowInvalid: true);
    final isImage = dictText.contains('/Image') &&
        (dictText.contains('/Subtype') || dictText.contains('/XObject'));
    final isFont = dictText.contains('/FontFile') ||
        dictText.contains('/FontDescriptor');
    // LAST /Length in the window: the window can reach back into
    // the previous object's dictionary, and this stream's own
    // /Length is the one closest to the stream marker.
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
        decoded = utf8.decode(ZLibDecoder().convert(streamBytes),
            allowMalformed: true);
      } catch (_) {
        continue;
      }
    } else {
      // Uncompressed content stream: text operators live here.
      // Binary junk without Tj/TJ is skipped cheaply by the
      // scanner (it only emits on Tj/TJ), so no regex cost.
      try {
        decoded = utf8.decode(streamBytes, allowMalformed: true);
      } catch (_) {
        decoded = latin1.decode(streamBytes, allowInvalid: true);
      }
    }
    if (decoded.length > 1024 * 1024) continue;
    out.write(_textFromContent(decoded));
    out.write('\n');
    // Safety valve for pathological files: 10M chars of text is
    // far beyond any real book chapter set the reader shows.
    if (out.length > 10 * 1024 * 1024) break;
    if (streamsSeen > 20000) break;
  }
  if (out.toString().trim().isEmpty) {
    // Last resort, linear: any literal/hex strings in the file.
    out.write(_textFromContent(latin1.decode(bytes, allowInvalid: true)));
  }
  return out.toString().replaceAll(RegExp(r'[ \t]+'), ' ').trim();
}

const _streamMarker = [115, 116, 114, 101, 97, 109]; // stream
const _endstreamMarker = [
  101, 110, 100, 115, 116, 114, 101, 97, 109
]; // endstream

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

/// Linear Tj/TJ scanner: walks the content once, collecting
/// string atoms and emitting them only when a Tj (single) or
/// TJ (array) operator follows. No regex, no backtracking.
String _textFromContent(String content) {
  final buf = StringBuffer();
  var i = 0;
  final n = content.length;
  bool isSpace(String c) =>
      c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f';
  while (i < n) {
    final c = content[i];
    if (c == '%') {
      // Comment to end of line.
      while (i < n && content[i] != '\n') i++;
      continue;
    }
    if (c == '(') {
      final atom = _readLiteral(content, i);
      if (atom == null) {
        i++;
        continue;
      }
      final text = atom.$1;
      i = atom.$2;
      while (i < n && isSpace(content[i])) i++;
      if (i + 1 < n && content[i] == 'T' && content[i + 1] == 'j') {
        buf.write(text);
        buf.write(' ');
        i += 2;
      }
      continue;
    }
    if (c == '<' && i + 1 < n && content[i + 1] != '<') {
      final atom = _readHex(content, i);
      if (atom == null) {
        i++;
        continue;
      }
      final text = atom.$1;
      i = atom.$2;
      while (i < n && isSpace(content[i])) i++;
      if (i + 1 < n && content[i] == 'T' && content[i + 1] == 'j') {
        buf.write(text);
        buf.write(' ');
        i += 2;
      }
      continue;
    }
    if (c == '[') {
      // TJ array: atoms until ], then TJ emits them all.
      final atoms = <String>[];
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
          buf.write(a);
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
/// Returns (decoded text, index just past ')'), or null if
/// the string is unterminated.
(String, int)? _readLiteral(String s, int start) {
  final buf = StringBuffer();
  var depth = 0;
  var i = start;
  final n = s.length;
  while (i < n) {
    final c = s[i];
    if (c == '\\' && i + 1 < n) {
      final e = s[i + 1];
      switch (e) {
        case 'n':
          buf.write('\n');
          break;
        case 'r':
          buf.write('\r');
          break;
        case 't':
          buf.write('\t');
          break;
        case 'b':
          buf.write('\b');
          break;
        case 'f':
          buf.write('\f');
          break;
        case '(':
        case ')':
        case '\\':
          buf.write(e);
          break;
        default:
          // Octal escapes \ddd, otherwise the char itself.
          if (e.codeUnitAt(0) >= 48 && e.codeUnitAt(0) <= 55) {
            var oct = '';
            var j = i + 1;
            while (j < n && j < i + 4 && s[j].codeUnitAt(0) >= 48 &&
                s[j].codeUnitAt(0) <= 55) {
              oct += s[j];
              j++;
            }
            buf.writeCharCode(int.tryParse(oct, radix: 8) ?? 32);
            i = j - 1;
          } else {
            buf.write(e);
          }
      }
      i += 2;
      continue;
    }
    if (c == '(') depth++;
    if (c == ')') {
      depth--;
      if (depth == 0) return (buf.toString(), i + 1);
    }
    if (depth > 0 && c != '(') buf.write(c);
    i++;
  }
  return null;
}

/// Read a PDF hex string starting at [start] ('<').
/// Returns (decoded text, index just past '>'), or null.
(String, int)? _readHex(String s, int start) {
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
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    // UTF-16BE.
    final units = <int>[];
    for (var k = 2; k + 1 < bytes.length; k += 2) {
      units.add(bytes[k] * 256 + bytes[k + 1]);
    }
    return (String.fromCharCodes(units), i + 1);
  }
  return (latin1.decode(bytes, allowInvalid: true), i + 1);
}
