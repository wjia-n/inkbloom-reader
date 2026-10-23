import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:inkbloom_reader/phone_store.dart';

void main() {
  test('Snapshot round-trips books, settings and save time', () async {
    final dir = await Directory.systemTemp.createTemp('inkbloom_store_');
    try {
      final books = [
        {'id': 'a', 'title': 'A'},
        {'id': 'b', 'title': 'B'},
      ];
      await PhoneStore.writeSnapshot(dir,
          books: books, settings: {'languageCode': 'en'});
      final snap = await PhoneStore.readSnapshot(dir);
      expect(snap, isNotNull);
      expect(snap!.books, books);
      expect(snap.settings, {'languageCode': 'en'});
      expect(
        DateTime.now().difference(snap.savedAt).inMinutes.abs(),
        lessThan(2),
      );
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('A torn temp file is ignored, the good snapshot survives', () async {
    final dir = await Directory.systemTemp.createTemp('inkbloom_store_');
    try {
      await PhoneStore.writeSnapshot(dir, books: [
        {'id': 'a'}
      ]);
      await File('${dir.path}/inkbloom_data.json.tmp')
          .writeAsString('[{"id": "x", "ti');
      final snap = await PhoneStore.readSnapshot(dir);
      expect(snap!.books, [
        {'id': 'a'}
      ]);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('Malformed snapshot and legacy files read as nothing', () async {
    final dir = await Directory.systemTemp.createTemp('inkbloom_store_');
    try {
      await File('${dir.path}/inkbloom_data.json')
          .writeAsString('corrupt{{{');
      expect(await PhoneStore.readSnapshot(dir), isNull);
      await File('${dir.path}/library.backup.json')
          .writeAsString('{"not": "a list"}');
      expect(await PhoneStore.readLegacyBackup(dir), isNull);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('Legacy v1.1.7/8 backup file still reads as books', () async {
    final dir = await Directory.systemTemp.createTemp('inkbloom_store_');
    try {
      await File('${dir.path}/library.backup.json').writeAsString(
          jsonEncode([
            {'id': 'old', 'title': 'Old'}
          ]));
      expect(await PhoneStore.readLegacyBackup(dir), [
        {'id': 'old', 'title': 'Old'}
      ]);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('Stats file round-trips, missing reads as nothing', () async {
    final dir = await Directory.systemTemp.createTemp('inkbloom_store_');
    try {
      expect(await PhoneStore.readStats(dir), isNull);
      await PhoneStore.writeStats(dir, '{"minutesByDay":{}}');
      expect(await PhoneStore.readStats(dir), '{"minutesByDay":{}}');
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('Library source order: snapshot, then legacy, then prefs', () {
    final snap = [
      {'id': 's'}
    ];
    final legacy = [
      {'id': 'l'}
    ];
    final prefs = [
      {'id': 'p'}
    ];
    expect(
        pickLibraryJson(snapshot: snap, legacy: legacy, prefs: prefs), snap);
    expect(pickLibraryJson(legacy: legacy, prefs: prefs), legacy);
    expect(pickLibraryJson(prefs: prefs), prefs);
    // An empty snapshot must not hide good prefs.
    expect(pickLibraryJson(snapshot: [], prefs: prefs), prefs);
    expect(pickLibraryJson(), isEmpty);
  });
}
