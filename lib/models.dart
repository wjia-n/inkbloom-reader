import 'dart:convert';
import 'epub_parser.dart';

/// One highlight / note on a single paragraph.
class Highlight {
  final int chapter;
  final int paragraph;
  final int color; // ARGB int, e.g. 0xFFFFFF00
  final String note;
  const Highlight({
    required this.chapter,
    required this.paragraph,
    required this.color,
    this.note = '',
  });

  Map<String, dynamic> toJson() => {
        'chapter': chapter,
        'paragraph': paragraph,
        'color': color,
        'note': note,
      };

  static Highlight? fromJson(Map<String, dynamic> j) {
    try {
      return Highlight(
        chapter: (j['chapter'] as num).toInt(),
        paragraph: (j['paragraph'] as num).toInt(),
        color: (j['color'] as num).toInt(),
        note: j['note'] as String? ?? '',
      );
    } catch (_) {
      return null;
    }
  }
}

/// One book in the library. Built-in books have no file path;
/// imported books store their copied file path + optional cover file.
class LibraryBook {
  final String id;
  final String title;
  final String author;
  final String format; // epub, txt, md, html
  final String? filePath;
  final String? coverPath; // extracted EPUB cover or user-set cover
  /// The exact filename the user imported, e.g.
  /// "book_17925970589_10922_0.pdf". Stored because the file
  /// itself is copied under an internal id name, so without
  /// this the original name is lost and the library can only
  /// show a cleaned-up or metadata title — which the user
  /// rightly reads as "the app renamed my book".
  final String? originalName;
  final List<EpubChapter> chapters;
  final double progress; // 0..1
  final int lastChapter;
  final int lastParagraph;
  final List<int> bookmarks; // chapter indexes
  final List<Highlight> highlights;
  final String shelf; // To Read, Reading, Finished, Favourites
  final bool isFavourite;
  final List<String> tags;
  final DateTime addedAt;
  final DateTime? lastReadAt; // null = never opened

  const LibraryBook({
    required this.id,
    required this.title,
    required this.author,
    required this.chapters,
    this.format = 'epub',
    this.filePath,
    this.coverPath,
    this.originalName,
    this.progress = 0,
    this.lastChapter = 0,
    this.lastParagraph = 0,
    this.bookmarks = const [],
    this.highlights = const [],
    this.shelf = 'To Read',
    this.isFavourite = false,
    this.tags = const [],
    required this.addedAt,
    this.lastReadAt,
  });

  bool get isBuiltin => filePath == null;
  String get formatLabel => format.toUpperCase();

  int get totalParagraphs =>
      chapters.fold(0, (s, c) => s + c.paragraphs.length);

  LibraryBook copyWith({
    String? title,
    String? author,
    double? progress,
    int? lastChapter,
    int? lastParagraph,
    List<int>? bookmarks,
    List<Highlight>? highlights,
    String? coverPath,
    String? originalName,
    String? shelf,
    bool? isFavourite,
    List<String>? tags,
    DateTime? lastReadAt,
  }) =>
      LibraryBook(
        id: id,
        title: title ?? this.title,
        author: author ?? this.author,
        format: format,
        filePath: filePath,
        coverPath: coverPath ?? this.coverPath,
        originalName: originalName ?? this.originalName,
        chapters: chapters,
        progress: progress ?? this.progress,
        lastChapter: lastChapter ?? this.lastChapter,
        lastParagraph: lastParagraph ?? this.lastParagraph,
        bookmarks: bookmarks ?? this.bookmarks,
        highlights: highlights ?? this.highlights,
        shelf: shelf ?? this.shelf,
        isFavourite: isFavourite ?? this.isFavourite,
        tags: tags ?? this.tags,
        addedAt: addedAt,
        lastReadAt: lastReadAt ?? this.lastReadAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'author': author,
        'format': format,
        'filePath': filePath,
        'coverPath': coverPath,
        'originalName': originalName,
        'progress': progress,
        'lastChapter': lastChapter,
        'lastParagraph': lastParagraph,
        'bookmarks': bookmarks,
        'highlights': highlights.map((h) => h.toJson()).toList(),
        'shelf': shelf,
        'isFavourite': isFavourite,
        'tags': tags,
        'addedAt': addedAt.toIso8601String(),
        'lastReadAt': lastReadAt?.toIso8601String(),
      };

  static LibraryBook? fromJson(Map<String, dynamic> j) {
    try {
      return LibraryBook(
        id: j['id'] as String,
        title: j['title'] as String,
        author: j['author'] as String? ?? 'Unknown Author',
        format: j['format'] as String? ?? 'epub',
        filePath: j['filePath'] as String?,
        coverPath: j['coverPath'] as String?,
        originalName: j['originalName'] as String?,
        chapters: const [],
        progress: (j['progress'] as num?)?.toDouble() ?? 0,
        lastChapter: (j['lastChapter'] as num?)?.toInt() ?? 0,
        lastParagraph: (j['lastParagraph'] as num?)?.toInt() ?? 0,
        bookmarks: ((j['bookmarks'] as List?) ?? [])
            .map((e) => (e as num).toInt())
            .toList(),
        highlights: ((j['highlights'] as List?) ?? [])
            .map((e) => Highlight.fromJson(e as Map<String, dynamic>))
            .whereType<Highlight>()
            .toList(),
        shelf: j['shelf'] as String? ?? 'To Read',
        isFavourite: j['isFavourite'] as bool? ?? false,
        tags: ((j['tags'] as List?) ?? []).map((e) => e.toString()).toList(),
        addedAt: DateTime.tryParse(j['addedAt'] as String? ?? '') ??
            DateTime.now(),
        lastReadAt:
            DateTime.tryParse(j['lastReadAt'] as String? ?? ''),
      );
    } catch (_) {
      return null;
    }
  }
}

/// One in-book search hit.
class SearchHit {
  final int chapter;
  final int paragraph;
  final String snippet;
  const SearchHit({
    required this.chapter,
    required this.paragraph,
    required this.snippet,
  });
}

List<SearchHit> searchBook(LibraryBook book, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return [];
  final hits = <SearchHit>[];
  for (var ci = 0; ci < book.chapters.length; ci++) {
    for (var pi = 0; pi < book.chapters[ci].paragraphs.length; pi++) {
      final p = book.chapters[ci].paragraphs[pi];
      final idx = p.toLowerCase().indexOf(q);
      if (idx < 0) continue;
      final start = (idx - 40).clamp(0, p.length);
      final end = (idx + q.length + 40).clamp(0, p.length);
      hits.add(SearchHit(
        chapter: ci,
        paragraph: pi,
        snippet: '${start > 0 ? '…' : ''}${p.substring(start, end)}${end < p.length ? '…' : ''}',
      ));
    }
  }
  return hits;
}

/// Three short original sample books so the app is useful on first launch.
/// Original text written for this app — no copied book content.
List<LibraryBook> sampleBooks() {
  EpubChapter ch(String t, List<String> p) =>
      EpubChapter(title: t, paragraphs: p);
  return [
    LibraryBook(
      id: 'sample-garden',
      title: 'The Garden at the End of the Lane',
      author: 'InkBloom Originals',
      addedAt: DateTime.now(),
      chapters: [
        ch('Chapter 1 — The Gate', [
          'Mara had walked past the gate a hundred times before she noticed it was open.',
          'It was not a grand gate. It was green paint over old wood, with a latch that clicked softly in the wind. Beyond it, the lane narrowed into a path lined with mint and rosemary.',
          'She stepped through because some days are made for stepping through.',
          'The garden did not look magical at first. It looked tended, which is a quieter kind of magic. Someone had weeded the beds, tied the tomatoes, and left a watering can by the tap.',
          'On the bench beneath the plum tree sat a notebook. On its first page, in careful handwriting, were the words: "For whoever finds this — please keep it growing."',
        ]),
        ch('Chapter 2 — What Grows', [
          'Mara came back the next day with gloves. And the day after that with seeds.',
          'She learned the garden the way you learn a person: slowly, by showing up. The shady corner liked ferns. The sunny wall liked beans. The plum tree liked to be left alone in spring.',
          'Neighbours began to stop at the gate. First to ask what she was doing, then to bring cuttings, then to stay and dig.',
          'By midsummer the garden fed six families, and the notebook was full of recipes, rain dates, and small drawings of bees.',
          'Mara wrote on the last page: "It was never my garden. It was the lane\'s garden. I just opened the gate."',
        ]),
      ],
    ),
    LibraryBook(
      id: 'sample-tide',
      title: 'Letters from the Tide',
      author: 'InkBloom Originals',
      addedAt: DateTime.now(),
      chapters: [
        ch('Letter One', [
          'Dear Ana, the sea was grey this morning, the honest kind of grey that makes the lighthouse look white again.',
          'I found your old postcard in the kitchen drawer. You wrote "wish you were here" and then crossed it out and wrote "glad you are there" instead. I have kept both versions.',
          'Come home when the tide turns. The kettle is already on.',
        ]),
        ch('Letter Two', [
          'Dear Ana, the tide turned at noon, right on schedule, as if it had been listening.',
          'The boats came in one by one. The fishermen waved. The gulls argued about nothing important.',
          'I am learning that home is not a place you return to once. It is a place you keep returning to, in small ways, every day.',
        ]),
      ],
    ),
    LibraryBook(
      id: 'sample-night-train',
      title: 'The Night Train to Willow Creek',
      author: 'InkBloom Originals',
      addedAt: DateTime.now(),
      chapters: [
        ch('Platform 3', [
          'The night train left at eleven, which is the best time for a train to leave if you want the world to feel a little larger.',
          'Jonas took the window seat, because window seats are for thinking, and he had a great deal of thinking to do.',
          'Outside, towns passed like chapters: a lit kitchen, a dark field, a station sign that read WILLOW CREEK in letters too small to read from a moving train.',
          'He got off anyway. Some stops you choose with your feet before your head has time to argue.',
        ]),
        ch('Willow Creek', [
          'Willow Creek smelled of rain and fresh bread, even at midnight.',
          'A woman at the station cafe poured him tea without asking what he wanted. "You look like tea," she said, and she was right.',
          'Jonas stayed one night. Then one week. Then he stopped counting, which is how you know a place has become yours.',
        ]),
      ],
    ),
  ];
}

String sampleBooksJson() => jsonEncode([]);
