import 'dart:io';

import 'package:flutter/material.dart';

import 'extra_screens.dart';
import 'models.dart';

/// Soft InkBloom look for the two new screens: warm cream
/// background, white cards with a soft shadow (no hard borders),
/// big rounded corners, gentle spacing. Everything sits in
/// exactly one place, nothing crammed.
const _softShadow = [
  BoxShadow(
    color: Color(0x14000000),
    blurRadius: 16,
    offset: Offset(0, 6),
  ),
];

Widget softCoverWidget(LibraryBook book,
    {double width = 62, double height = 88}) {
  final file = book.coverPath != null ? File(book.coverPath!) : null;
  if (file != null && file.existsSync()) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        boxShadow: _softShadow,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Image.file(file,
            width: width, height: height, fit: BoxFit.cover),
      ),
    );
  }
  return Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [forest, forestDark],
      ),
      borderRadius: BorderRadius.circular(14),
      boxShadow: _softShadow,
    ),
    child: Stack(children: [
      Center(
        child: Text(
          book.title.isNotEmpty ? book.title[0] : 'B',
          style: const TextStyle(
              color: Colors.white,
              fontSize: 30,
              fontWeight: FontWeight.bold),
        ),
      ),
      Positioned(
        bottom: 6,
        right: 6,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          decoration: BoxDecoration(
            color: terracotta,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(book.formatLabel,
              style: const TextStyle(color: Colors.white, fontSize: 8)),
        ),
      ),
    ]),
  );
}

Widget _progressBar(double progress) {
  return ClipRRect(
    borderRadius: BorderRadius.circular(4),
    child: LinearProgressIndicator(
      value: progress,
      minHeight: 6,
      backgroundColor: const Color(0xFFE8E0CC),
      valueColor: const AlwaysStoppedAnimation<Color>(terracotta),
    ),
  );
}

String _dateLabel(DateTime d) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = today.difference(day).inDays;
  if (diff <= 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  return '${months[d.month - 1]} ${d.day}';
}

/// Books — a full, dedicated screen where ONLY books live.
/// No banner, no tools, no stats, no settings. Just your books:
/// search at the top, shelf chips under it, then the books
/// themselves in a neat grid. Everything else stays on its
/// own page, reached from the bottom bar.
class BooksScreen extends StatefulWidget {
  final List<LibraryBook> books;
  final void Function(LibraryBook) onOpen;
  final void Function(LibraryBook) onFavourite;
  const BooksScreen(
      {super.key,
      required this.books,
      required this.onOpen,
      required this.onFavourite});

  @override
  State<BooksScreen> createState() => _BooksScreenState();
}

class _BooksScreenState extends State<BooksScreen> {
  String _query = '';
  String _shelf = 'All';
  String _sort = 'Recently added';

  @override
  Widget build(BuildContext context) {
    var shown = widget.books.where((b) {
      if (_shelf == 'Favourites' && !b.isFavourite) return false;
      if (_shelf != 'All' &&
          _shelf != 'Favourites' &&
          b.shelf != _shelf) {
        return false;
      }
      if (_query.isNotEmpty) {
        final q = _query.toLowerCase();
        if (!b.title.toLowerCase().contains(q) &&
            !b.author.toLowerCase().contains(q)) {
          return false;
        }
      }
      return true;
    }).toList();
    if (_sort == 'Title A–Z') {
      shown.sort((a, b) =>
          a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    } else if (_sort == 'Author A–Z') {
      shown.sort((a, b) =>
          a.author.toLowerCase().compareTo(b.author.toLowerCase()));
    } else {
      shown.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    }
    const shelves = [
      'All', 'Favourites', 'To Read', 'Reading', 'Finished'
    ];
    return Scaffold(
      backgroundColor: cream,
      appBar: AppBar(
        title: const Text('My Books'),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.sort),
            onSelected: (v) => setState(() => _sort = v),
            itemBuilder: (_) => const [
              PopupMenuItem(
                  value: 'Recently added', child: Text('Recently added')),
              PopupMenuItem(value: 'Title A–Z', child: Text('Title A–Z')),
              PopupMenuItem(value: 'Author A–Z', child: Text('Author A–Z')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Search your books…',
                prefixIcon: const Icon(Icons.search, color: forest),
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: shelves.map((s) {
                final selected = _shelf == s;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(s),
                    selected: selected,
                    selectedColor: forest,
                    labelStyle: TextStyle(
                        color: selected ? Colors.white : forest),
                    backgroundColor: Colors.white,
                    onSelected: (_) => setState(() => _shelf = s),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: shown.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        'No books here yet.\nImport one from the library and it will appear here.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: forest.withValues(alpha: 0.7),
                            fontSize: 16),
                      ),
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisSpacing: 16,
                      crossAxisSpacing: 16,
                      childAspectRatio: 0.62,
                    ),
                    itemCount: shown.length,
                    itemBuilder: (_, i) {
                      final book = shown[i];
                      final pct = (book.progress * 100).round();
                      return InkWell(
                        onTap: () => widget.onOpen(book),
                        onLongPress: () => widget.onFavourite(book),
                        borderRadius: BorderRadius.circular(20),
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: _softShadow,
                          ),
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Center(
                                child: softCoverWidget(book,
                                    width: 110, height: 156),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                book.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                    color: forest),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                book.author,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 12,
                                    color: forest.withValues(alpha: 0.65)),
                              ),
                              const Spacer(),
                              if (book.progress > 0) ...[
                                _progressBar(book.progress),
                                const SizedBox(height: 4),
                                Text('$pct% read',
                                    style: const TextStyle(
                                        fontSize: 11, color: terracotta)),
                              ] else
                                Text(book.formatLabel,
                                    style: TextStyle(
                                        fontSize: 11,
                                        color:
                                            forest.withValues(alpha: 0.55))),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// History — the books you were reading, in the order you
/// last read them. The book you are currently reading sits
/// at the top, big: large cover, title, author, progress
/// and one clear "Continue reading" button. The rest follow
/// as neat rows underneath.
class HistoryScreen extends StatelessWidget {
  final List<LibraryBook> books;
  final void Function(LibraryBook) onOpen;
  const HistoryScreen(
      {super.key, required this.books, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    // A book counts as history if it was opened (lastReadAt set)
    // or it already has reading progress from before history
    // tracking existed.
    final history = books.where((b) {
      return b.lastReadAt != null || b.progress > 0;
    }).toList()
      ..sort((a, b) {
        final da = a.lastReadAt ?? a.addedAt;
        final db = b.lastReadAt ?? b.addedAt;
        return db.compareTo(da);
      });
    final current = history.isEmpty ? null : history.first;
    final rest = history.length <= 1 ? <LibraryBook>[] : history.sublist(1);
    return Scaffold(
      backgroundColor: cream,
      appBar: AppBar(title: const Text('History')),
      body: history.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Nothing in your history yet.\nOpen a book and it will appear here, with the one you are reading right at the top.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16, color: forest),
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                if (current != null) ...[
                  const Text(
                    'Currently reading',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: terracotta,
                        letterSpacing: 0.5),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: _softShadow,
                    ),
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        softCoverWidget(current, width: 110, height: 156),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                current.title,
                                style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                    color: forest),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                current.author,
                                style: TextStyle(
                                    fontSize: 14,
                                    color: forest.withValues(alpha: 0.65)),
                              ),
                              const SizedBox(height: 12),
                              _progressBar(current.progress),
                              const SizedBox(height: 6),
                              Text(
                                '${(current.progress * 100).round()}% read · ${_dateLabel(current.lastReadAt ?? current.addedAt)}',
                                style: const TextStyle(
                                    fontSize: 12, color: terracotta),
                              ),
                              const SizedBox(height: 14),
                              FilledButton.icon(
                                onPressed: () => onOpen(current),
                                icon: const Icon(Icons.play_arrow),
                                label: const Text('Continue reading'),
                                style: FilledButton.styleFrom(
                                  backgroundColor: terracotta,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(24),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
                if (rest.isNotEmpty) ...[
                  const Text(
                    'Reading history',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: forest),
                  ),
                  const SizedBox(height: 10),
                  ...rest.map((book) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: InkWell(
                        onTap: () => onOpen(book),
                        borderRadius: BorderRadius.circular(20),
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: _softShadow,
                          ),
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              softCoverWidget(book, width: 56, height: 80),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      book.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          color: forest),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${book.author} · ${_dateLabel(book.lastReadAt ?? book.addedAt)}',
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: forest.withValues(
                                              alpha: 0.65)),
                                    ),
                                    const SizedBox(height: 8),
                                    _progressBar(book.progress),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '${(book.progress * 100).round()}%',
                                style: const TextStyle(
                                    fontSize: 12, color: terracotta),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }),
                ],
              ],
            ),
    );
  }
}
