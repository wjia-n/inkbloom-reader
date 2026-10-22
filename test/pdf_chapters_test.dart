import 'package:flutter_test/flutter_test.dart';
import 'package:inkbloom_reader/formats.dart';

void main() {
  test('Spaced-letter headings become real chapters', () {
    const text = 'C h a p t e r 1\n'
        'The first time Jian met Li Yu was in his family living room.\n'
        'He walked through the front door with a cigarette hanging loosely.\n'
        'C h a p t e r 2\n'
        'The next morning brought rain and a letter no one expected.\n';
    final chapters = BookParser.splitPdfChapters(text, 'My Book');
    expect(chapters.length, 2);
    expect(chapters[0].title, 'Chapter 1');
    expect(chapters[1].title, 'Chapter 2');
    expect(chapters[0].paragraphs.first, contains('Jian met Li Yu'));
  });

  test('Heading glued to its first sentence splits cleanly', () {
    const text = 'Chapter 1 The first time Jian met Li Yu was in his '
        'family living room and the rain had only just stopped falling.\n'
        'He walked through the front door with a cigarette hanging loosely.\n'
        'Chapter 2\n'
        'The next morning brought rain.\n';
    final chapters = BookParser.splitPdfChapters(text, 'My Book');
    expect(chapters.length, 2);
    expect(chapters[0].title, 'Chapter 1');
    expect(chapters[0].paragraphs.first, startsWith('The first time'));
  });

  test('Short heading line keeps its subtitle', () {
    const text = 'Chapter 12: The Inn\n'
        'The inn was warm and the fire was lit.\n';
    final chapters = BookParser.splitPdfChapters(text, 'My Book');
    expect(chapters.length, 1);
    expect(chapters[0].title, 'Chapter 12: The Inn');
  });

  test('No headings falls back to 45-paragraph sections', () {
    // Blank lines make each line its own paragraph.
    final lines = List.generate(100, (i) => 'Plain paragraph number $i.');
    final text = lines.join('\n\n');
    final chapters = BookParser.splitPdfChapters(text, 'My Book');
    expect(chapters.length, 3);
    expect(chapters[0].title, 'Chapter 1');
    expect(chapters[2].paragraphs.length, 10);
  });

  test('Splitting a prefix gives a prefix of the full split', () {
    final lines = <String>['Chapter 1', 'Alpha paragraph one.'];
    for (var i = 0; i < 30; i++) {
      lines.add('Filler paragraph $i with enough words to read.');
    }
    lines.add('Chapter 2');
    lines.add('Beta paragraph one.');
    for (var i = 0; i < 30; i++) {
      lines.add('More filler paragraph $i with enough words to read.');
    }
    final full = lines.join('\n');
    final partial = lines.sublist(0, 20).join('\n');
    final fullCh = BookParser.splitPdfChapters(full, 'My Book');
    final partCh = BookParser.splitPdfChapters(partial, 'My Book');
    expect(fullCh.length, 2);
    expect(partCh.length, 1);
    expect(partCh[0].title, fullCh[0].title);
    // Every partial paragraph except the last is identical;
    // the last one is a string-prefix of the full paragraph
    // (the cut falls mid-paragraph, so it grows downwards on
    // swap — nothing above the reader's position moves).
    final n = partCh[0].paragraphs.length;
    for (var i = 0; i < n - 1; i++) {
      expect(fullCh[0].paragraphs[i], partCh[0].paragraphs[i]);
    }
    expect(fullCh[0].paragraphs[n - 1],
        startsWith(partCh[0].paragraphs[n - 1]));
  });
}
