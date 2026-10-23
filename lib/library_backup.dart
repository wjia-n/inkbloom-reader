import 'dart:convert';
import 'dart:io';

/// Second copy of the library JSON, in its own file.
///
/// SharedPreferences is a single XML file: one torn write
/// during a kill (freeze, crash, swipe-away) can corrupt
/// the whole library key. The old code then blocked all
/// future saves, so every later import and reading session
/// lived only in memory and vanished on the next
/// swipe-away — the library looked freshly installed.
/// This file is written via temp + atomic rename, so it
/// is never torn itself, and a corrupt prefs value heals
/// from it on the next load.
class LibraryBackup {
  static const _name = 'library.backup.json';
  static const _tmpName = 'library.backup.json.tmp';

  /// Store [json] (library JSON) atomically. Only parseable
  /// library JSON is ever stored; anything else is ignored
  /// so a bad write can never poison the backup.
  static Future<void> write(Directory dir, String json) async {
    try {
      final decoded = jsonDecode(json);
      if (decoded is! List) return;
      final tmp = File('${dir.path}/$_tmpName');
      await tmp.writeAsString(json, flush: true);
      await tmp.rename('${dir.path}/$_name');
    } catch (_) {}
  }

  /// The stored library JSON, or null when there is none
  /// or it does not parse as a library list.
  static Future<String?> read(Directory dir) async {
    try {
      final file = File('${dir.path}/$_name');
      if (!await file.exists()) return null;
      final content = await file.readAsString();
      final decoded = jsonDecode(content);
      if (decoded is! List) return null;
      return content;
    } catch (_) {
      return null;
    }
  }
}
