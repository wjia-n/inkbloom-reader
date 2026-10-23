import 'package:flutter_test/flutter_test.dart';
import 'package:inkbloom_reader/models.dart';

LibraryBook book(String id, DateTime added, DateTime? read) {
  return LibraryBook(
    id: id,
    title: id,
    author: 'A',
    chapters: const [],
    addedAt: added,
    lastReadAt: read,
  );
}

void main() {
  test('Last-read book sorts first, never-opened books last', () {
    final readOld = book('old', DateTime(2026, 1, 1), DateTime(2026, 10, 10));
    final readNew = book('new', DateTime(2026, 1, 2), DateTime(2026, 10, 23));
    final never = book('never', DateTime(2026, 10, 22), null);
    final list = [never, readOld, readNew];
    list.sort(compareBooksRecent);
    expect(list.map((b) => b.id).toList(), ['new', 'old', 'never']);
  });

  test('Never-opened books fall back to added date', () {
    final a = book('a', DateTime(2026, 1, 1), null);
    final b = book('b', DateTime(2026, 5, 1), null);
    final list = [a, b];
    list.sort(compareBooksRecent);
    expect(list.map((x) => x.id).toList(), ['b', 'a']);
  });
}
