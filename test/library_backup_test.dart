import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:inkbloom_reader/library_backup.dart';

void main() {
  test('Backup round-trips library JSON', () async {
    final dir = await Directory.systemTemp.createTemp('inkbloom_backup_');
    try {
      final json = jsonEncode([
        {'id': 'a', 'title': 'A'},
        {'id': 'b', 'title': 'B'},
      ]);
      await LibraryBackup.write(dir, json);
      expect(await LibraryBackup.read(dir), json);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('A torn temp file is ignored, the good backup survives', () async {
    final dir = await Directory.systemTemp.createTemp('inkbloom_backup_');
    try {
      final json = jsonEncode([
        {'id': 'a', 'title': 'A'},
      ]);
      await LibraryBackup.write(dir, json);
      // Simulate a kill mid-write: a half-written temp file.
      await File('${dir.path}/library.backup.json.tmp')
          .writeAsString('[{"id": "x", "ti');
      expect(await LibraryBackup.read(dir), json);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('Non-list and malformed values are never stored or read', () async {
    final dir = await Directory.systemTemp.createTemp('inkbloom_backup_');
    try {
      await LibraryBackup.write(dir, '{"not": "a list"}');
      expect(await LibraryBackup.read(dir), isNull);
      await LibraryBackup.write(dir, 'not json at all');
      expect(await LibraryBackup.read(dir), isNull);
      await File('${dir.path}/library.backup.json')
          .writeAsString('corrupt{{{');
      expect(await LibraryBackup.read(dir), isNull);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
