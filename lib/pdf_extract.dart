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
/// - v2 (2026-10-21): read the font mappings: /ToUnicode CMaps
///   and /Differences arrays, merged into ONE global map, and
///   every content stream decoded twice (with maps, raw) with
///   the more readable result winning.
/// - v3 (2026-10-22): the two fixes the user demanded after
///   v1.1.2 — speed, and text that is right in ANY language:
///   * PER-FONT maps. v2's global union was the remaining
///     correctness bug: a book's regular, bold and italic
///     fonts are DIFFERENT subset fonts, each with its own
///     glyph-ID mapping, so glyph 1 can mean 'a' in regular
///     and 'b' in bold. Merging them decoded every bold or
///     italic passage wrong. Now the extractor tracks the Tf
///     operator (which font is active) and decodes each string
///     with THAT font's own CMap / Differences / embedded
///     TrueType cmap. The global union stays only as a
///     fallback for streams whose font is unknown.
///   * Font dictionaries hidden in Object Streams (PDF 1.5+,
///     where most modern tools put them) are now decompressed
///     and read, so /Differences there are no longer missed.
///   * Embedded TrueType cmaps are read as a last-resort map
///     for CID fonts with no ToUnicode table at all.
///   * Speed: single-pass decode (the raw re-decode only runs
///     when the mapped result is clearly garbage), content
///     collection stops once 12 MB of decoded text is banked
///     (output is capped at 10 MB anyway), and per-stream cap
///     raised 1 MB -> 8 MB so big pages are no longer dropped.
///
/// Limits that stay honest: scanned/image PDFs still have no
/// text and are rejected by the caller; a PDF whose fonts carry
/// NO mapping at all (no ToUnicode, no Differences, no
/// embedded font cmap) cannot be decoded by any pure extractor,
/// and non-Identity CIDToGIDMaps are not followed.

/// One byte decoded as Windows-1252 (the encoding most
/// Western PDFs and RTFs actually use). Unlike latin1, bytes
/// 0x80-0x9F become real punctuation (smart quotes, dashes,
/// euro) instead of invisible control characters — the old
/// latin1 path turned those into missing/garbled glyphs.
String win1252Char(int v) {
  if (v < 0x80 || v >= 0xA0) return String.fromCharCode(v);
  const table = [
    0x20AC, 0x0000, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x0000, 0x017D, 0x0000,
    0x0000, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x0000, 0x017E, 0x0178,
  ];
  final mapped = table[v - 0x80];
  return mapped == 0 ? '' : String.fromCharCode(mapped);
}

/// One font's decoding maps, resolved from its dictionary.
/// [cmap] is its /ToUnicode table, [diff] its /Differences,
/// [ttf] is glyph-ID -> character from its embedded TrueType
/// cmap (inverted), used for CID fonts with no ToUnicode.
class _PdfFont {
  final Map<int, String> cmap;
  final Map<int, String> diff;
  final Map<int, String> ttf;
  const _PdfFont({
    this.cmap = const {},
    this.diff = const {},
    this.ttf = const {},
  });
  bool get hasMaps =>
      cmap.isNotEmpty || diff.isNotEmpty || ttf.isNotEmpty;
}

/// A font dictionary found in the file: its object number
/// (null when it could not be linked), its /ToUnicode stream
/// reference, its /Differences body, and its /FontFile2
/// (embedded TrueType) reference.
class _FontDict {
  final int? objNum;
  final int? toUnicodeRef;
  final String? diffBody;
  final int? fontDescriptorRef;
  // Resolved after scanning: direct /FontFile2, or via the
  // font descriptor object the font points at (the normal
  // real-world layout: font -> descriptor -> FontFile2).
  int? fontFile2Ref;
  _FontDict({
    this.objNum,
    this.toUnicodeRef,
    this.diffBody,
    this.fontDescriptorRef,
    this.fontFile2Ref,
  });
}

String extractPdfTextFallback(Uint8List bytes) {
  // ---- Pass 1: streams. Collect CMaps (by object number),
  // embedded TrueType font programs (by object number),
  // Object Stream bodies, and decoded content streams.
  final cmapByObj = <int, Map<int, String>>{};
  // CMaps whose stream carried no object number (rare):
  // they join the global fallback map directly.
  final unnumberedCmap = <int, String>{};
  final ttfByObj = <int, Uint8List>{};
  final objStmBodies = <String>[];
  final objStmCounts = <int?>[];
  // Every stream's location, by object number: font programs
  // are found by REFERENCE from their font descriptor (their
  // own dict is just a Length), so they are resolved in pass
  // 2 from this metadata instead of by dict sniffing.
  final streamMeta = <int, ({int start, int end, bool flate})>{};
  final contents = <({int? objNum, String text})>[];
  var contentsLen = 0;
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
    final windowText =
        latin1.decode(bytes.sublist(dictStart, streamAt), allowInvalid: true);
    final dictText = _ownDict(windowText);
    final objNum = _objNumBefore(windowText);
    final isImage = dictText.contains('/Image') &&
        (dictText.contains('/Subtype') || dictText.contains('/XObject'));
    final isObjStm = dictText.contains('/ObjStm');
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
    if (objNum != null) {
      streamMeta[objNum] =
          (start: dataStart, end: dataEnd, flate: dictText.contains('/FlateDecode'));
    }
    if (isImage) continue;
    if (streamLen <= 0 || streamLen > 8 * 1024 * 1024) continue;
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
    if (isObjStm) {
      objStmCounts.add(int.tryParse(
          RegExp(r'/N\s+(\d+)').firstMatch(dictText)?.group(1) ?? ''));
      objStmBodies.add(decoded);
      continue;
    }
    if (decoded.length > 8 * 1024 * 1024) continue;
    if (decoded.contains('beginbfchar') ||
        decoded.contains('beginbfrange')) {
      // A ToUnicode CMap: keep it under its object number so
      // it can be tied to its font; unnumbered ones join the
      // global fallback map directly.
      final parsed = _parseCMap(decoded);
      if (objNum != null) cmapByObj[objNum] = parsed;
      // Also a global fallback (first mapping wins, as in
      // v2): a CMap that cannot be tied to a font — minimal
      // synthetic PDFs, or a font dict the scan missed —
      // must still decode text instead of raw garbage. A
      // font's OWN cmap always wins over this union when the
      // font is known (see _decodeBytes lookup order).
      for (final e in parsed.entries) {
        unnumberedCmap.putIfAbsent(e.key, () => e.value);
      }
      continue;
    }
    contents.add((objNum: objNum, text: decoded));
    contentsLen += decoded.length;
    // Output is capped at 10 MB anyway; banking more decoded
    // text only burns time and memory on huge PDFs.
    if (contentsLen > 12 * 1024 * 1024) break;
    if (streamsSeen > 20000) break;
  }

  // ---- Pass 2: font dictionaries + resource font mappings.
  // Head text covers classic PDFs; Object Stream bodies cover
  // modern (1.5+) PDFs whose dictionaries are compressed.
  final scanLen =
      bytes.length < 10 * 1024 * 1024 ? bytes.length : 10 * 1024 * 1024;
  final head = latin1.decode(bytes.sublist(0, scanLen), allowInvalid: true);
  final fontDicts = <_FontDict>[];
  final resourceFonts = <String, int>{};
  final descriptors = <int, int>{};
  _scanFontDicts(head, fontDicts, descriptors: descriptors);
  _scanResourceFonts(head, resourceFonts);
  final objStmObjects = <({int objNum, String text})>[];
  for (final body in objStmBodies) {
    final objs = _parseObjStm(body, n: objStmCounts.removeAt(0));
    objStmObjects.addAll(objs);
    for (final o in objs) {
      _scanFontDicts(o.text, fontDicts,
          fixedObjNum: o.objNum, descriptors: descriptors);
      _scanResourceFonts(o.text, resourceFonts);
    }
  }
  // Resolve indirect font programs: font -> descriptor -> File.
  for (final fd in fontDicts) {
    fd.fontFile2Ref ??= fd.fontDescriptorRef != null
        ? descriptors[fd.fontDescriptorRef]
        : null;
  }

  // /Differences in plain text (old fallback): keep scanning
  // the head, merged into the global map.
  final globalDiff = <int, String>{};
  for (final m in RegExp(r'/Differences\s*\[(.*?)\]', dotAll: true)
      .allMatches(head)) {
    final body = m.group(1)!;
    if (body.length > 10000) continue;
    _parseDifferences(body, globalDiff);
  }
  final globalCmap = Map<int, String>.from(unnumberedCmap);

  // Font programs, resolved by reference from pass-1 stream
  // metadata (their own dicts carry no identifying marks).
  final fontProgramObjs = <int>{};
  for (final fd in fontDicts) {
    final ref = fd.fontFile2Ref;
    if (ref == null) continue;
    fontProgramObjs.add(ref);
    if (ttfByObj.containsKey(ref)) continue;
    final meta = streamMeta[ref];
    if (meta == null) continue;
    final len = meta.end - meta.start;
    if (len <= 0 || len >= 5 * 1024 * 1024) continue;
    final raw = bytes.sublist(meta.start, meta.end);
    if (meta.flate) {
      try {
        ttfByObj[ref] = Uint8List.fromList(ZLibDecoder().convert(raw));
      } catch (_) {
        continue;
      }
    } else {
      ttfByObj[ref] = raw;
    }
  }

  // ---- Build fonts: resource name -> font, with its maps.
  final fontsByResource = <String, _PdfFont>{};
  for (final fd in fontDicts) {
    final cmap = fd.toUnicodeRef != null
        ? (cmapByObj[fd.toUnicodeRef] ?? <int, String>{})
        : <int, String>{};
    final diff = <int, String>{};
    if (fd.diffBody != null) _parseDifferences(fd.diffBody!, diff);
    var ttf = const <int, String>{};
    if (fd.fontFile2Ref != null) {
      final program = ttfByObj[fd.fontFile2Ref];
      if (program != null) ttf = _parseTtfCmap(program) ?? ttf;
    }
    final font = _PdfFont(cmap: cmap, diff: diff, ttf: ttf);
    if (font.hasMaps) {
      for (final e in font.cmap.entries) {
        globalCmap.putIfAbsent(e.key, () => e.value);
      }
      for (final e in font.diff.entries) {
        globalDiff.putIfAbsent(e.key, () => e.value);
      }
    }
    // Link by object number through the resource mapping.
    if (fd.objNum != null) {
      for (final e in resourceFonts.entries) {
        if (e.value == fd.objNum) fontsByResource[e.key] = font;
      }
    }
  }

  // ---- Pass 3: decode content streams, tracking Tf.
  // Font program streams are not content, even though their
  // dicts look exactly like content streams' dicts.
  final out = StringBuffer();
  for (final entry in contents) {
    if (entry.objNum != null && fontProgramObjs.contains(entry.objNum)) {
      continue;
    }
    final content = entry.text;
    var decoded = _textFromContent(
        content, (name) => fontsByResource[name], globalCmap, globalDiff);
    // Safety net only: if the mapped result is clearly
    // garbage, try raw and keep whichever reads better. This
    // used to run on EVERY stream (2x work); now it runs
    // only on streams that actually look broken.
    if (_readability(decoded) < 0.2 &&
        (globalCmap.isNotEmpty || globalDiff.isNotEmpty)) {
      final raw = _textFromContent(
          content, (_) => null, const {}, const {});
      if (_readability(raw) > _readability(decoded)) decoded = raw;
    }
    out.write(decoded);
    out.write('\n');
    if (out.length > 10 * 1024 * 1024) break;
  }
  if (out.toString().trim().isEmpty) {
    out.write(_textFromContent(
        latin1.decode(bytes, allowInvalid: true),
        (_) => null,
        const {},
        const {}));
  }
  return out.toString().replaceAll(RegExp(r'[ \t]+'), ' ').trim();
}

/// The object number of the `N 0 obj` header just before a
/// stream's dictionary, or null when it cannot be linked.
int? _objNumBefore(String windowText) {
  final matches =
      RegExp(r'(\d+)\s+0\s+obj').allMatches(windowText).toList();
  if (matches.isEmpty) return null;
  return int.tryParse(matches.last.group(1)!);
}

/// Find every top-level << ... >> block in [text] that looks
/// like a font dictionary, and record its mappings. When
/// [fixedObjNum] is given (Object Stream objects), it is the
/// dictionary's object number; otherwise it is recovered from
/// the `N 0 obj` header before the block, if there is one.
void _scanFontDicts(String text, List<_FontDict> out,
    {int? fixedObjNum, Map<int, int>? descriptors}) {
  var i = 0;
  final n = text.length;
  while (i < n) {
    final start = text.indexOf('<<', i);
    if (start < 0) break;
    var depth = 0;
    var j = start;
    var end = -1;
    while (j + 1 < n) {
      final two = text.substring(j, j + 2);
      if (two == '<<') {
        depth++;
        j += 2;
      } else if (two == '>>') {
        depth--;
        j += 2;
        if (depth == 0) {
          end = j;
          break;
        }
      } else {
        j++;
      }
    }
    if (end < 0) break;
    final block = text.substring(start, end);
    if (block.contains('/BaseFont') ||
        block.contains('/FontDescriptor') ||
        (block.contains('/Type') && block.contains('/Font'))) {
      final toUnicode = RegExp(r'/ToUnicode\s+(\d+)\s+0\s+R')
          .firstMatch(block)
          ?.group(1);
      final diffMatch =
          RegExp(r'/Differences\s*\[(.*?)\]', dotAll: true)
              .firstMatch(block);
      final fontFile2 = RegExp(r'/FontFile2\s+(\d+)\s+0\s+R')
          .firstMatch(block)
          ?.group(1);
      final descriptorRef =
          RegExp(r'/FontDescriptor\s+(\d+)\s+0\s+R')
              .firstMatch(block)
              ?.group(1);
      int? objNum = fixedObjNum;
      objNum ??= _objNumBefore(
          text.substring(start > 200 ? start - 200 : 0, start));
      final file2 =
          fontFile2 != null ? int.tryParse(fontFile2) : null;
      if (file2 != null && objNum != null) {
        descriptors?[objNum] = file2;
      }
      out.add(_FontDict(
        objNum: objNum,
        toUnicodeRef:
            toUnicode != null ? int.tryParse(toUnicode) : null,
        diffBody: diffMatch?.group(1),
        fontDescriptorRef: descriptorRef != null
            ? int.tryParse(descriptorRef)
            : null,
        fontFile2Ref: file2,
      ));
    }
    i = end;
  }
}

/// Resource font mappings: /Font << /F1 12 0 R /F2 13 0 R >>.
/// The Font dict itself is flat, so a simple regex is safe.
void _scanResourceFonts(String text, Map<String, int> out) {
  for (final m in
      RegExp(r'/Font\s*<<(.*?)>>', dotAll: true).allMatches(text)) {
    final body = m.group(1)!;
    for (final pair
        in RegExp(r'/([A-Za-z0-9]+)\s+(\d+)\s+0\s+R').allMatches(body)) {
      final num = int.tryParse(pair.group(2)!);
      if (num != null) out.putIfAbsent(pair.group(1)!, () => num);
    }
  }
}

/// Parse one inflated Object Stream body into its objects.
/// The header is N pairs of (object number, byte offset);
/// offsets count from the first object, whose offset is the
/// header size (the first pair's offset).
List<({int objNum, String text})> _parseObjStm(String body, {int? n}) {
  final result = <({int objNum, String text})>[];
  final tokens = body.split(RegExp(r'\s+'));
  // The header is pairs of integers. When the dict's /N is
  // known, take exactly 2*N tokens: an object that starts
  // with a digit must not be swallowed into the header.
  // Otherwise stop at the first non-integer token.
  final nums = <int>[];
  for (final tok in tokens) {
    if (n != null && nums.length >= 2 * n) break;
    final v = int.tryParse(tok);
    if (v == null) break;
    nums.add(v);
  }
  if (nums.length < 2 || nums.length.isOdd) return result;
  final count = nums.length ~/ 2;
  final objNums = <int>[];
  final offsets = <int>[];
  for (var k = 0; k < count; k++) {
    objNums.add(nums[k * 2]);
    offsets.add(nums[k * 2 + 1]);
  }
  // Re-find the object section: the header ends right where
  // the first object starts, i.e. after the header tokens.
  // Walk the body counting tokens to locate that boundary.
  var pos = 0;
  var seen = 0;
  while (seen < nums.length && pos < body.length) {
    while (pos < body.length &&
        (body[pos] == ' ' ||
            body[pos] == '\t' ||
            body[pos] == '\n' ||
            body[pos] == '\r')) {
      pos++;
    }
    while (pos < body.length &&
        body[pos] != ' ' &&
        body[pos] != '\t' &&
        body[pos] != '\n' &&
        body[pos] != '\r') {
      pos++;
    }
    seen++;
  }
  // The first object starts AFTER the whitespace following
  // the header; offsets count from there, per spec.
  while (pos < body.length &&
      (body[pos] == ' ' ||
          body[pos] == '\t' ||
          body[pos] == '\n' ||
          body[pos] == '\r')) {
    pos++;
  }
  final sectionStart = pos;
  for (var k = 0; k < count; k++) {
    final start = sectionStart + offsets[k];
    final end = k + 1 < count
        ? sectionStart + offsets[k + 1]
        : body.length;
    if (start < 0 || start > body.length || end < start) continue;
    result.add((objNum: objNums[k], text: body.substring(start, end)));
  }
  return result;
}

/// Invert an embedded TrueType cmap into glyph-ID -> character.
/// Handles format 12 (preferred) and format 4. Returns null for
/// non-TrueType programs (CFF / OTTO) and malformed tables.
Map<int, String>? _parseTtfCmap(Uint8List bytes) {
  if (bytes.length < 12) return null;
  int u16(int o) => (bytes[o] << 8) | bytes[o + 1];
  int u32(int o) =>
      (bytes[o] << 24) | (bytes[o + 1] << 16) | (bytes[o + 2] << 8) | bytes[o + 3];
  String charOf(int v) {
    if (v <= 0xFFFF) return String.fromCharCode(v);
    final high = 0xD800 + ((v - 0x10000) >> 10);
    final low = 0xDC00 + ((v - 0x10000) & 0x3FF);
    return String.fromCharCodes([high, low]);
  }

  final sfnt = u32(0);
  if (sfnt != 0x00010000 && sfnt != 0x74727565) return null;
  final numTables = u16(4);
  int? cmapOff;
  for (var k = 0; k < numTables; k++) {
    final rec = 12 + k * 16;
    if (rec + 16 > bytes.length) break;
    final tag = String.fromCharCodes(bytes.sublist(rec, rec + 4));
    if (tag == 'cmap') {
      cmapOff = u32(rec + 8);
      break;
    }
  }
  if (cmapOff == null || cmapOff + 4 > bytes.length) return null;
  final numSub = u16(cmapOff + 2);
  int? fmt12;
  int? fmt4;
  for (var k = 0; k < numSub; k++) {
    final rec = cmapOff + 4 + k * 8;
    if (rec + 8 > bytes.length) break;
    final off = u32(rec + 4);
    final sub = cmapOff + off;
    if (sub + 2 > bytes.length) continue;
    final fmt = u16(sub);
    if (fmt == 12 && fmt12 == null) fmt12 = sub;
    if (fmt == 4 && fmt4 == null) fmt4 = sub;
  }
  final map = <int, String>{};
  var budget = 200000;
  if (fmt12 != null) {
    if (fmt12 + 16 > bytes.length) return null;
    final nGroups = u32(fmt12 + 12);
    for (var g = 0; g < nGroups && budget > 0; g++) {
      final rec = fmt12 + 16 + g * 12;
      if (rec + 12 > bytes.length) break;
      final startChar = u32(rec);
      final endChar = u32(rec + 4);
      final startGlyph = u32(rec + 8);
      if (endChar < startChar) continue;
      for (var ch = startChar; ch <= endChar && budget > 0; ch++) {
        final glyph = startGlyph + (ch - startChar);
        map.putIfAbsent(glyph, () => charOf(ch));
        budget--;
      }
    }
    return map.isEmpty ? null : map;
  }
  if (fmt4 != null) {
    if (fmt4 + 14 > bytes.length) return null;
    final segCount = u16(fmt4 + 6) ~/ 2;
    final endBase = fmt4 + 14;
    final startBase = endBase + 2 * segCount + 2;
    final deltaBase = startBase + 2 * segCount;
    final rangeBase = deltaBase + 2 * segCount;
    int s16(int o) {
      final v = u16(o);
      return v >= 0x8000 ? v - 0x10000 : v;
    }

    for (var s = 0; s < segCount && budget > 0; s++) {
      if (rangeBase + 2 * segCount > bytes.length) break;
      final endCode = u16(endBase + 2 * s);
      final startCode = u16(startBase + 2 * s);
      final delta = s16(deltaBase + 2 * s);
      final rangeOffset = u16(rangeBase + 2 * s);
      if (endCode < startCode) continue;
      for (var c = startCode; c <= endCode && budget > 0; c++) {
        int glyph;
        if (rangeOffset == 0) {
          glyph = (c + delta) % 65536;
        } else {
          final addr = rangeBase + 2 * s + rangeOffset + 2 * (c - startCode);
          if (addr + 2 > bytes.length) continue;
          final gid = u16(addr);
          if (gid == 0) continue;
          glyph = (gid + delta) % 65536;
        }
        if (glyph != 0) map.putIfAbsent(glyph, () => charOf(c));
        budget--;
      }
    }
    return map.isEmpty ? null : map;
  }
  return null;
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
    'quoteright': '’', 'quotedblleft': '“',
    'quotedblright': '”',
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
        if (atom != null) value = _decodeBytes(atom.$1, null, const {}, const {});
      } else if (i < text.length && text[i] == '<') {
        final atom = _readHex(text, i);
        if (atom != null) value = _decodeBytes(atom.$1, null, const {}, const {});
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

/// The LARGEST embedded JPEG in the file — the closest thing
/// a PDF has to a cover thumbnail. Largest, not first: the
/// first JPEG in a book PDF is often a tiny logo, while the
/// cover is the big picture. Returns null when the PDF has no
/// JPEG image (then the library keeps its generated cover).
Uint8List? extractPdfCover(Uint8List bytes) {
  Uint8List? best;
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
    if (streamAt < 0) return best;
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
    if (len < 256 || len > 3 * 1024 * 1024) continue;
    if (bytes[dataStart] == 0xFF && bytes[dataStart + 1] == 0xD8) {
      if (best == null || len > best.length) {
        best = Uint8List.fromList(bytes.sublist(dataStart, dataEnd));
      }
    }
  }
  // Unreachable: the loop only exits via the return above.
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

/// Decode raw string bytes into text through the ACTIVE font's
/// maps (its CMap, then Differences, then its embedded TrueType
/// cmap), falling back to the global maps, then to raw WinAnsi.
/// [font] is null for metadata strings and unknown fonts.
String _decodeBytes(List<int> bytes, _PdfFont? font,
    Map<int, String> globalCmap, Map<int, String> globalDiff) {
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    final units = <int>[];
    for (var k = 2; k + 1 < bytes.length; k += 2) {
      units.add(bytes[k] * 256 + bytes[k + 1]);
    }
    while (units.isNotEmpty && units.last == 0) units.removeLast();
    return String.fromCharCodes(units);
  }
  final cmap = font?.cmap ?? const <int, String>{};
  final diff = font?.diff ?? const <int, String>{};
  final ttf = font?.ttf ?? const <int, String>{};
  if (cmap.isEmpty &&
      diff.isEmpty &&
      ttf.isEmpty &&
      globalCmap.isEmpty &&
      globalDiff.isEmpty) {
    // No font map: the bytes are most likely WinAnsi
    // (Windows-1252). latin1 turned its smart quotes and
    // dashes into control characters; 1252 keeps them.
    return bytes.map(win1252Char).join();
  }
  final buf = StringBuffer();
  var i = 0;
  while (i < bytes.length) {
    if (i + 1 < bytes.length) {
      final code2 = bytes[i] * 256 + bytes[i + 1];
      final hit2 = cmap[code2] ?? ttf[code2] ?? globalCmap[code2];
      if (hit2 != null) {
        buf.write(hit2);
        i += 2;
        continue;
      }
    }
    final code1 = bytes[i];
    final hit1 = cmap[code1] ?? diff[code1] ?? globalCmap[code1] ?? globalDiff[code1];
    if (hit1 != null) {
      buf.write(hit1);
      i++;
      continue;
    }
    final b = code1;
    if (b >= 32 || b == 9 || b == 10 || b == 13) {
      buf.write(b >= 0x80 ? win1252Char(b) : String.fromCharCode(b));
    }
    i++;
  }
  return buf.toString();
}

/// Linear Tj/TJ scanner: walks the content once, collecting
/// string atoms and emitting them only when a Tj (single),
/// TJ (array), ' or " operator follows. No regex, no
/// backtracking. Atoms are decoded through the ACTIVE font's
/// maps: the scanner tracks the Tf operator, so a string set
/// in bold decodes with the bold font's mapping, not the
/// regular font's. Unknown fonts fall back to the global maps.
String _textFromContent(String content, _PdfFont? Function(String name) resolveFont,
    Map<int, String> globalCmap, Map<int, String> globalDiff) {
  final buf = StringBuffer();
  var i = 0;
  final n = content.length;
  _PdfFont? currentFont;
  bool isSpace(String c) =>
      c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f';
  bool isNameChar(String c) =>
      !isSpace(c) &&
      c != '(' &&
      c != ')' &&
      c != '<' &&
      c != '>' &&
      c != '[' &&
      c != ']' &&
      c != '{' &&
      c != '}' &&
      c != '/' &&
      c != '%';
  bool isDigit(String c) => c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57;
  void emit(List<int> atomBytes) {
    buf.write(_decodeBytes(atomBytes, currentFont, globalCmap, globalDiff));
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
    if (c == '/') {
      // A name: maybe a font selection (/F1 12 Tf). Read the
      // name, skip an optional size number, and only act when
      // Tf follows; other names (colors, XObjects) are just
      // skipped, never treated as text.
      var j = i + 1;
      while (j < n && isNameChar(content[j])) j++;
      final name = content.substring(i + 1, j);
      var k = j;
      while (k < n && isSpace(content[k])) k++;
      while (k < n && (isDigit(content[k]) || content[k] == '.' || content[k] == '-')) {
        k++;
      }
      while (k < n && isSpace(content[k])) k++;
      if (k + 1 < n && content[k] == 'T' && content[k + 1] == 'f') {
        currentFont = resolveFont(name);
        i = k + 2;
      } else {
        i = j;
      }
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
          buf.write(_decodeBytes(a, currentFont, globalCmap, globalDiff));
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
            // j sits just past the last octal digit; the shared
            // i += 2 below must land exactly on j, so the next
            // character (often the closing ')') is not skipped.
            // The old j - 1 skipped one char too many: a ')'
            // right after an octal escape was eaten, the string
            // never closed, and the whole page came out empty.
            i = j - 2;
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
