import 'dart:convert';
import 'dart:io';

/// The library's home in the phone's own storage.
///
/// SharedPreferences proved too fragile as the library's only
/// home: one torn write could take the whole key, and its
/// saves are asynchronous (a kill can outrun them). So the
/// library now lives FIRST in a real file in the app's
/// documents folder, written via temp + atomic rename with
/// a disk flush, and SharedPreferences is only a fallback
/// copy. The snapshot file is a few kilobytes; the book
/// files themselves are the megabytes, and they already
/// live in this same folder.
class PhoneSnapshot {
  final DateTime savedAt;
  final List<Map<String, dynamic>> books;
  final Map<String, dynamic>? settings;
  const PhoneSnapshot({
    required this.savedAt,
    required this.books,
    this.settings,
  });
}

class PhoneStore {
  static const snapshotName = 'inkbloom_data.json';
  static const snapshotTmpName = 'inkbloom_data.json.tmp';
  static const legacyBackupName = 'library.backup.json';
  static const statsName = 'inkbloom_stats.json';
  static const statsTmpName = 'inkbloom_stats.json.tmp';

  /// Write the snapshot atomically: temp file + flush +
  /// rename, so the file is never torn, even on a kill.
  static Future<void> writeSnapshot(
    Directory dir, {
    required List<Map<String, dynamic>> books,
    Map<String, dynamic>? settings,
  }) async {
    try {
      final data = {
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'books': books,
        if (settings != null) 'settings': settings,
      };
      final tmp = File('${dir.path}/$snapshotTmpName');
      await tmp.writeAsString(jsonEncode(data), flush: true);
      await tmp.rename('${dir.path}/$snapshotName');
    } catch (_) {}
  }

  static Future<PhoneSnapshot?> readSnapshot(Directory dir) async {
    try {
      final file = File('${dir.path}/$snapshotName');
      if (!await file.exists()) return null;
      final data = jsonDecode(await file.readAsString());
      if (data is! Map<String, dynamic>) return null;
      final booksRaw = data['books'];
      if (booksRaw is! List) return null;
      final books = <Map<String, dynamic>>[];
      for (final e in booksRaw) {
        if (e is Map<String, dynamic>) books.add(e);
      }
      final savedAtMs = data['savedAt'];
      final settingsRaw = data['settings'];
      return PhoneSnapshot(
        savedAt: savedAtMs is int
            ? DateTime.fromMillisecondsSinceEpoch(savedAtMs)
            : DateTime.fromMillisecondsSinceEpoch(0),
        books: books,
        settings: settingsRaw is Map<String, dynamic> ? settingsRaw : null,
      );
    } catch (_) {
      return null;
    }
  }

  /// Legacy v1.1.7/8 backup file: a bare list of book JSON.
  /// Still read as a fallback so those builds' saves survive.
  static Future<List<Map<String, dynamic>>?> readLegacyBackup(
      Directory dir) async {
    try {
      final file = File('${dir.path}/$legacyBackupName');
      if (!await file.exists()) return null;
      final data = jsonDecode(await file.readAsString());
      if (data is! List) return null;
      return data.whereType<Map<String, dynamic>>().toList();
    } catch (_) {
      return null;
    }
  }

  static Future<void> writeStats(Directory dir, String statsJson) async {
    try {
      final tmp = File('${dir.path}/$statsTmpName');
      await tmp.writeAsString(statsJson, flush: true);
      await tmp.rename('${dir.path}/$statsName');
    } catch (_) {}
  }

  static Future<String?> readStats(Directory dir) async {
    try {
      final file = File('${dir.path}/$statsName');
      if (!await file.exists()) return null;
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  /// What the Settings diagnostic shows: how many books are
  /// actually stored on this phone, and when last saved.
  static Future<({int count, DateTime? savedAt, bool isSnapshot})>
      storageStatus(Directory dir) async {
    final snap = await readSnapshot(dir);
    if (snap != null) {
      return (count: snap.books.length, savedAt: snap.savedAt, isSnapshot: true);
    }
    final legacy = await readLegacyBackup(dir);
    if (legacy != null) {
      return (count: legacy.length, savedAt: null, isSnapshot: false);
    }
    return (count: 0, savedAt: null, isSnapshot: false);
  }
}

/// Preference order for library sources: the phone-storage
/// snapshot first (flushed, atomic), then the legacy backup
/// file, then SharedPreferences. The first source with any
/// books wins; an empty source never beats books elsewhere
/// (a present-but-empty snapshot must not hide good prefs).
List<Map<String, dynamic>> pickLibraryJson({
  List<Map<String, dynamic>>? snapshot,
  List<Map<String, dynamic>>? legacy,
  List<Map<String, dynamic>>? prefs,
}) {
  if (snapshot != null && snapshot.isNotEmpty) return snapshot;
  if (legacy != null && legacy.isNotEmpty) return legacy;
  if (prefs != null && prefs.isNotEmpty) return prefs;
  return snapshot ?? legacy ?? prefs ?? [];
}
