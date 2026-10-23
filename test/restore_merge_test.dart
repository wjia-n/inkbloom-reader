import 'package:flutter_test/flutter_test.dart';
import 'package:inkbloom_reader/models.dart';

LibraryBook book(String id,
    {double progress = 0, DateTime? lastReadAt}) {
  return LibraryBook(
    id: id,
    title: id,
    author: 'A',
    format: 'pdf',
    chapters: const [],
    progress: progress,
    lastReadAt: lastReadAt,
    addedAt: DateTime(2026, 1, 1),
  );
}

void main() {
  test('Restore never removes current books', () {
    final now = DateTime(2026, 10, 23, 10, 0);
    final current = [book('a', progress: 0.8, lastReadAt: now), book('b')];
    final restored = [book('a', progress: 0.2)];
    final merged = mergeRestoredBooks(current, restored);
    expect(merged.map((b) => b.id).toSet(), {'a', 'b'});
    // Current copy is newer, so it wins.
    expect(merged.firstWhere((b) => b.id == 'a').progress, 0.8);
  });

  test('Newer restored copy wins, new books are added', () {
    final old = DateTime(2026, 10, 20);
    final now = DateTime(2026, 10, 23, 10, 0);
    final current = [book('a', progress: 0.2, lastReadAt: old)];
    final restored = [
      book('a', progress: 0.9, lastReadAt: now),
      book('c', progress: 0.5, lastReadAt: now),
    ];
    final merged = mergeRestoredBooks(current, restored);
    expect(merged.map((b) => b.id).toSet(), {'a', 'c'});
    expect(merged.firstWhere((b) => b.id == 'a').progress, 0.9);
  });
}
