import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Runtime custom fonts: Flutter's FontLoader can load a .ttf/.otf
/// from bytes at runtime, so a font the user imports does not need
/// to be declared in pubspec at build time.
class CustomFonts {
  static Future<Directory> fontsDir() async {
    final dir = await getApplicationDocumentsDirectory();
    final d = Directory('${dir.path}/inkbloom_fonts');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static String familyNameForFile(String fileName) {
    final base = fileName.split('/').last.split('\\').last;
    final dot = base.lastIndexOf('.');
    final name = dot > 0 ? base.substring(0, dot) : base;
    return name.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
  }

  /// Load every saved custom font. Call once at startup (splash)
  /// and again after a new font is imported.
  static Future<List<String>> loadAll() async {
    final dir = await fontsDir();
    final names = <String>[];
    for (final f in dir.listSync()) {
      if (f is! File) continue;
      final lower = f.path.toLowerCase();
      if (!lower.endsWith('.ttf') && !lower.endsWith('.otf')) continue;
      final family = familyNameForFile(f.path);
      try {
        final bytes = await f.readAsBytes();
        final loader = FontLoader(family);
        loader.addFont(Future.value(ByteData.view(bytes.buffer)));
        await loader.load();
        names.add(family);
      } catch (_) {}
    }
    return names;
  }

  static Future<String?> importFont(
      String fileName, Uint8List bytes) async {
    final dir = await fontsDir();
    final ext = fileName.split('.').last.toLowerCase();
    if (ext != 'ttf' && ext != 'otf') return null;
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(bytes);
    final family = familyNameForFile(fileName);
    try {
      final loader = FontLoader(family);
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
    } catch (_) {}
    return family;
  }
}
