import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkbloom_reader/main.dart';
import 'package:inkbloom_reader/models.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakePathProviderPlatform extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async =>
      '/tmp/inkbloom_test_docs';
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
    for (var i = 0; i < 10; i++) {
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
}
