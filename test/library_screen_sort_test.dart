import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkbloom_reader/main.dart';
import 'package:inkbloom_reader/models.dart';
import 'dart:io';

import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:inkbloom_reader/phone_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakePathProviderPlatform extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async =>
      '/tmp/inkbloom_test_docs';
}


Future<void> _cleanPhoneFiles() async {
  final dir = Directory('/tmp/inkbloom_test_docs/inkbloom_books');
  for (final name in [
    'inkbloom_data.json',
    'inkbloom_data.json.tmp',
    'library.backup.json',
    'inkbloom_stats.json',
  ]) {
    try {
      final f = File('${dir.path}/$name');
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

void main() {
  testWidgets('Saved library loads and the last-read book comes first',
      (tester) async {
    PathProviderPlatform.instance = FakePathProviderPlatform();
    // Beta was ADDED later, but Alpha was READ more recently.
    // Recent order must put Alpha first (the old default
    // sorted by added date and got this wrong). Orphan has
    // no file path and no matching sample: it must survive
    // the load instead of being dropped as a "builtin".
    final alpha = LibraryBook(
      id: 'book-alpha',
      title: 'Alpha Recently Read',
      author: 'A',
      format: 'epub',
      filePath: '/tmp/inkbloom_test_docs/inkbloom_books/book-alpha.epub',
      chapters: const [],
      progress: 0.5,
      lastChapter: 2,
      lastParagraph: 3,
      addedAt: DateTime(2026, 1, 1),
      lastReadAt: DateTime(2026, 10, 23),
    );
    final beta = LibraryBook(
      id: 'book-beta',
      title: 'Beta Added Later',
      author: 'B',
      format: 'epub',
      filePath: '/tmp/inkbloom_test_docs/inkbloom_books/book-beta.epub',
      chapters: const [],
      progress: 0.2,
      addedAt: DateTime(2026, 10, 20),
      lastReadAt: DateTime(2026, 10, 10),
    );
    final orphan = LibraryBook(
      id: 'book-orphan',
      title: 'Orphan No File',
      author: 'C',
      format: 'epub',
      chapters: const [],
      addedAt: DateTime(2026, 2, 1),
    );
    await tester.runAsync(() async {
      await _cleanPhoneFiles();
    });
    SharedPreferences.setMockInitialValues({
      'inkbloom_library_v2': jsonEncode(
          [alpha.toJson(), beta.toJson(), orphan.toJson()]),
    });

    // Tall viewport so every book card builds (a normal
    // viewport leaves later cards unbuilt inside the list).
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: LibraryScreen()));
    // _load chains several real file reads. Each step needs a
    // real event-loop turn (runAsync) for the file IO plus a
    // pump to flush the continuation, so interleave them: a
    // pump alone never turns the real loop, and a runAsync
    // alone never flushes the fake-zone continuation. Without
    // this pairing _load stalls mid-chain and its last 5s
    // timeout timer is still pending at teardown.
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();

    // Nothing dropped: 3 saved + 3 samples, 2 in progress.
    expect(find.textContaining('6 books • 2 in progress'), findsOneWidget);
    // The last-READ book renders before the last-ADDED one.
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? '')
        .toList();
    final aIdx =
        texts.indexWhere((s) => s.contains('Alpha Recently Read'));
    final bIdx = texts.indexWhere((s) => s.contains('Beta Added Later'));
    final oIdx = texts.indexWhere((s) => s.contains('Orphan No File'));
    expect(aIdx, isNot(-1));
    expect(bIdx, isNot(-1));
    expect(oIdx, isNot(-1));
    expect(aIdx, lessThan(bIdx));
  });
  testWidgets('Phone-storage file beats SharedPreferences on load',
      (tester) async {
    PathProviderPlatform.instance = FakePathProviderPlatform();
    // The phone file holds FileFirst; prefs hold a DIFFERENT,
    // older book. The file must win: prefs are only fallback.
    final booksDir =
        Directory('/tmp/inkbloom_test_docs/inkbloom_books');
    await tester.runAsync(() async {
      await booksDir.create(recursive: true);
      await _cleanPhoneFiles();
    });
    final snapFile = File('${booksDir.path}/inkbloom_data.json');
    addTearDown(() {
      try {
        if (snapFile.existsSync()) snapFile.deleteSync();
      } catch (_) {}
    });
    final fileBook = LibraryBook(
      id: 'book-filefirst',
      title: 'FileFirst Book',
      author: 'F',
      format: 'epub',
      filePath: '/tmp/inkbloom_test_docs/inkbloom_books/filefirst.epub',
      chapters: const [],
      progress: 0.3,
      addedAt: DateTime(2026, 1, 1),
      lastReadAt: DateTime(2026, 10, 23),
    );
    await tester.runAsync(() async {
      await PhoneStore.writeSnapshot(booksDir,
          books: [fileBook.toJson()]);
    });
    final prefsBook = LibraryBook(
      id: 'book-prefsonly',
      title: 'PrefsOnly Book',
      author: 'P',
      format: 'epub',
      filePath: '/tmp/inkbloom_test_docs/inkbloom_books/prefs.epub',
      chapters: const [],
      progress: 0.1,
      addedAt: DateTime(2026, 1, 2),
      lastReadAt: DateTime(2026, 10, 10),
    );
    SharedPreferences.setMockInitialValues({
      'inkbloom_library_v2': jsonEncode([prefsBook.toJson()]),
    });

    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: LibraryScreen()));
    // _load chains several real file reads. Each step needs a
    // real event-loop turn (runAsync) for the file IO plus a
    // pump to flush the continuation, so interleave them: a
    // pump alone never turns the real loop, and a runAsync
    // alone never flushes the fake-zone continuation. Without
    // this pairing _load stalls mid-chain and its last 5s
    // timeout timer is still pending at teardown.
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();

    // File book shown (plus 3 samples = 4 books, 1 in progress);
    // the prefs-only book must NOT appear.
    expect(find.textContaining('4 books • 1 in progress'), findsOneWidget);
    // FileFirst is in progress, so it renders twice (the Reading
    // section plus the full list); presence is the assertion.
    expect(find.text('FileFirst Book'), findsAtLeast(1));
    expect(find.text('PrefsOnly Book'), findsNothing);
  });
}
