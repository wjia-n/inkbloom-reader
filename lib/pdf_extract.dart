import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Pure-Dart PDF text extractor.
///
/// The old version scanned the whole file as Latin-1 text and only
/// understood plain ( ... ) Tj strings, so most real PDFs — hex
/// strings, UTF-16 text, Flate streams whose length the regex
/// guessed wrong — came back empty and the book refused to open,
/// even though every other reader opened it fine.
///
/// This version works on bytes: it finds each `stream` marker,
/// reads the /Length from the dictionary just before it (when
/// present) so binary data is never truncated by a stray
/// "endstream" inside it, inflates Flate streams, and reads
/// literal strings, hex strings (including UTF-16BE with BOM),
/// and Tj / TJ operators. Scanned/image PDFs still have no
/// text and are honestly rejected by the caller.
String extractPdfTextFallback(Uint8List bytes) {
  final out = StringBuffer();
  var pos = 0;
  while (true) {
    final streamAt = _indexOf(bytes, _streamMarker, pos);
    if (streamAt < 0) break;
    var dataStart = streamAt + _streamMarker.length;
    if (dataStart < bytes.length && bytes[dataStart] == 13) dataStart++;
    if (dataStart < bytes.length && bytes[dataStart] == 10) dataStart++;
    // /Length in the dictionary just before this stream.
    final dictStart = dataStart > 500 ? dataStart - 500 : 0;
    final dictText = latin1.decode(bytes.sublist(dictStart, streamAt),
        allowInvalid: true);
    final lenMatch =
        RegExp(r'/Length\s+(\d+)').firstMatch(dictText);
    int dataEnd;
    if (lenMatch != null) {
      final len = int.tryParse(lenMatch.group(1)!) ?? 0;
      dataEnd = dataStart + len;
      if (dataEnd > bytes.length) dataEnd = bytes.length;
    } else {
      final endAt = _indexOf(bytes, _endstreamMarker, dataStart);
      dataEnd = endAt < 0 ? bytes.length : endAt;
    }
    final streamBytes = bytes.sublist(dataStart, dataEnd);
    String decoded;
    try {
      decoded = utf8.decode(ZLibDecoder().convert(streamBytes),
          allowMalformed: true);
    } catch (_) {
      try {
        decoded = utf8.decode(streamBytes, allowMalformed: true);
      } catch (_) {
        decoded = latin1.decode(streamBytes, allowInvalid: true);
      }
    }
    out.write(_textFromContent(decoded));
    out.write('\n');
    pos = dataEnd;
  }
  if (out.toString().trim().isEmpty) {
    // Last resort: any literal strings in the file.
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

String _textFromContent(String content) {
  final buf = StringBuffer();
  // ( ... ) Tj and [ (...) (...) ] TJ, in document order.
  final opRe = RegExp(
      r'(\((?:\\.|[^\\()])*\)|<[0-9A-Fa-f\s]+>)\s*Tj|\[((?:[^\[\]]|\([^)]*\))*)\]\s*TJ');
  for (final m in opRe.allMatches(content)) {
    if (m.group(1) != null) {
      buf.write(_decodePdfAtom(m.group(1)!));
      buf.write(' ');
    } else if (m.group(2) != null) {
      final inner = m.group(2)!;
      for (final s in RegExp(r'\((?:\\.|[^\\()])*\)|<[0-9A-Fa-f\s]+>')
          .allMatches(inner)) {
        buf.write(_decodePdfAtom(s.group(0)!));
      }
      buf.write(' ');
    }
  }
  return buf.toString();
}

/// Decode one PDF string atom: (literal) or <hex>, including
/// UTF-16BE (FEFF BOM) text, which is how most modern PDFs
/// store non-ASCII text.
String _decodePdfAtom(String atom) {
  if (atom.startsWith('<')) {
    var hex = atom.substring(1, atom.length - 1).replaceAll(RegExp(r'\s'), '');
    if (hex.length.isOdd) hex += '0';
    final bytes = <int>[];
    for (var i = 0; i + 1 < hex.length; i += 2) {
      bytes.add(int.tryParse(hex.substring(i, i + 2), radix: 16) ?? 32);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      // UTF-16BE.
      final units = <int>[];
      for (var i = 2; i + 1 < bytes.length; i += 2) {
        units.add(bytes[i] * 256 + bytes[i + 1]);
      }
      return String.fromCharCodes(units);
    }
    // Plain bytes, with high bytes mapped through Latin-1.
    return latin1.decode(bytes, allowInvalid: true);
  }
  var inner = atom;
  final start = inner.indexOf('(');
  final end = inner.lastIndexOf(')');
  if (start >= 0 && end > start) inner = inner.substring(start + 1, end);
  // UTF-16BE in a literal string starts with FE FF.
  if (inner.length >= 2 &&
      inner.codeUnitAt(0) == 0xFE &&
      inner.codeUnitAt(1) == 0xFF) {
    final units = <int>[];
    for (var i = 2; i + 1 < inner.length; i += 2) {
      units.add(inner.codeUnitAt(i) * 256 + inner.codeUnitAt(i + 1));
    }
    return String.fromCharCodes(units);
  }
  return inner
      .replaceAllMapped(RegExp(r'\\([0-7]{1,3})'), (m) {
        final v = int.tryParse(m.group(1)!, radix: 8);
        return v == null ? '' : String.fromCharCode(v);
      })
      .replaceAll(r'\(', '(')
      .replaceAll(r'\)', ')')
      .replaceAll(r'\\', r'\')
      .replaceAll(r'\n', ' ')
      .replaceAll(r'\r', ' ');
}
