import 'package:flutter_test/flutter_test.dart';
import 'package:inkbloom_reader/formats.dart';

void main() {
  test('Paragraph maps to its page, boundaries and overflow clamp', () {
    // Pages of 2, 3 and 1 paragraphs: para 0-1 -> 0, 2-4 -> 1, 5 -> 2.
    final pages = [
      ['a', 'b'],
      ['c', 'd', 'e'],
      ['f'],
    ];
    expect(pageIndexForParagraph(pages, 0), 0);
    expect(pageIndexForParagraph(pages, 1), 0);
    expect(pageIndexForParagraph(pages, 2), 1);
    expect(pageIndexForParagraph(pages, 4), 1);
    expect(pageIndexForParagraph(pages, 5), 2);
    // Beyond the end clamps to the last page, never crashes.
    expect(pageIndexForParagraph(pages, 99), 2);
    expect(pageIndexForParagraph([], 5), 0);
  });
}
