import 'dart:io';

import 'package:flutter/material.dart';

import 'extra_screens.dart';
import 'models.dart';

/// Soft InkBloom look for the two new screens: warm cream
/// background, soft shadows (no hard borders), big rounded
/// corners, gentle spacing. Placements borrow the clean
/// Neat Reader layout — cover first, title underneath,
/// time above the cover, Continue on the right — but in
/// InkBloom's own forest/terracotta/cream style, and with
/// InkBloom's extras Neat does not have: progress bars,
/// last-opened times, shelves, and local history that
/// needs no cloud upload at all.
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

/// "Last opened" in the form the user asked for: minutes,
/// hours, or days ago — never just a bare date. Older than a
/// month falls back to a plain date so it stays readable.
String _lastOpenedLabel(LibraryBook book) {
  final last = book.lastReadAt;
  if (last == null) return 'Opened before this update';
  final diff = DateTime.now().difference(last);
  if (diff.inMinutes < 1) return 'Opened just now';
  if (diff.inMinutes < 60) {
    final m = diff.inMinutes;
    return 'Opened $m min${m == 1 ? '' : 's'} ago';
  }
  if (diff.inHours < 24) {
    final h = diff.inHours;
    return 'Opened $h hour${h == 1 ? '' : 's'} ago';
  }
  if (diff.inDays < 30) {
    final d = diff.inDays;
    return 'Opened $d day${d == 1 ? '' : 's'} ago';
  }
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  return 'Opened ${months[last.month - 1]} ${last.day}, ${last.year}';
}

/// Short time for the grid, Neat-style: "Just now",
/// "4 hours", "1 min", or "New" for a book added in the
/// last day that has never been opened.
String _shortTimeLabel(LibraryBook book) {
  if (book.lastReadAt == null) {
    final addedAgo = DateTime.now().difference(book.addedAt);
    if (addedAgo.inHours < 24 && book.progress == 0) return 'New';
    return 'Not opened yet';
  }
  return _lastOpenedLabel(book).replaceFirst('Opened ', '');
}

Widget _continueButton(void Function() onTap) {
  return FilledButton(
    onPressed: onTap,
    style: FilledButton.styleFrom(
      backgroundColor: terracotta,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
      ),
    ),
    child: const Text('Continue'),
  );
}

/// Books — a full, dedicated screen where ONLY books live.
/// Clean grid, Neat-style placement, InkBloom style:
/// search on top, "All books" and "Sort by" dropdowns
/// under it, three covers across, the time label above
/// each cover, the title underneath, and a + tile at the
/// end to add a book. No banner, no tools, no stats.
class BooksScreen extends StatefulWidget {
  final List<LibraryBook> Function() getBooks;
  final void Function(LibraryBook) onOpen;
  final void Function(LibraryBook) onFavourite;
  final Future<void> Function() onAdd;
  const BooksScreen(
      {super.key,
      required this.getBooks,
      required this.onOpen,
      required this.onFavourite,
      required this.onAdd});

  @override
  State<BooksScreen> createState() => _BooksScreenState();
}

class _BooksScreenState extends State<BooksScreen> {
  String _query = '';
  String _shelf = 'All';
  String _sort = 'Recent';

  @override
  Widget build(BuildContext context) {
    var shown = widget.getBooks().where((b) {
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
    if (_sort == 'Book name') {
      shown.sort((a, b) =>
          a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    } else if (_sort == 'Recently added') {
      shown.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    } else {
      // Recent: last opened first, never-opened books last.
      shown.sort((a, b) {
        final da = a.lastReadAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final db = b.lastReadAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final c = db.compareTo(da);
        return c != 0 ? c : b.addedAt.compareTo(a.addedAt);
      });
    }
    const shelves = [
      'All', 'Favourites', 'To Read', 'Reading', 'Finished'
    ];
    const sorts = ['Recent', 'Book name', 'Recently added'];
    return Scaffold(
      backgroundColor: cream,
      appBar: AppBar(title: const Text('Books')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Search books',
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                PopupMenuButton<String>(
                  onSelected: (v) => setState(() => _shelf = v),
                  itemBuilder: (_) => shelves
                      .map((s) => PopupMenuItem(
                          value: s,
                          child: Text(
                              s == 'All' ? 'All books' : s)))
                      .toList(),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _shelf == 'All' ? 'All books' : _shelf,
                        style: const TextStyle(
                            fontSize: 14, color: forest),
                      ),
                      const Icon(Icons.arrow_drop_down, color: forest),
                    ],
                  ),
                ),
                const Spacer(),
                PopupMenuButton<String>(
                  onSelected: (v) => setState(() => _sort = v),
                  itemBuilder: (_) => sorts
                      .map((s) =>
                          PopupMenuItem(value: s, child: Text(s)))
                      .toList(),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Sort by',
                          style: TextStyle(fontSize: 14, color: forest)),
                      Icon(Icons.arrow_drop_down, color: forest),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: shown.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        'No books here yet.\nTap + below to add one.',
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
                      crossAxisCount: 3,
                      mainAxisSpacing: 20,
                      crossAxisSpacing: 12,
                      childAspectRatio: 0.52,
                    ),
                    itemCount: shown.length + 1,
                    itemBuilder: (_, i) {
                      if (i == shown.length) {
                        // + tile, Neat-style: tap to add a book.
                        return InkWell(
                          onTap: () async {
                            await widget.onAdd();
                            if (mounted) setState(() {});
                          },
                          borderRadius: BorderRadius.circular(14),
                          child: Container(
                            height: 152,
                            decoration: BoxDecoration(
                              color: const Color(0xFFEDE6D3),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const Center(
                              child: Icon(Icons.add,
                                  size: 40, color: forest),
                            ),
                          ),
                        );
                      }
                      final book = shown[i];
                      final isNew = _shortTimeLabel(book) == 'New';
                      return InkWell(
                        onTap: () => widget.onOpen(book),
                        onLongPress: () => widget.onFavourite(book),
                        borderRadius: BorderRadius.circular(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                if (isNew) ...[
                                  Container(
                                    width: 7,
                                    height: 7,
                                    decoration: const BoxDecoration(
                                      color: terracotta,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                ],
                                Expanded(
                                  child: Text(
                                    _shortTimeLabel(book),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: isNew
                                            ? terracotta
                                            : forest.withValues(
                                                alpha: 0.6)),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Center(
                              child: softCoverWidget(book,
                                  width: 108, height: 152),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              book.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 13,
                                  color: forest,
                                  fontWeight: FontWeight.w500),
                            ),
                          ],
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

/// Reading Now / History — the book you are currently
/// reading at the top as a row (cover, title, time,
/// Continue button), then "Recently" underneath with the
/// same row for every other book you have opened.
/// Local only: unlike Neat, nothing here needs a cloud
/// upload to show up.
class HistoryScreen extends StatelessWidget {
  final List<LibraryBook> Function() getBooks;
  final void Function(LibraryBook) onOpen;
  const HistoryScreen(
      {super.key, required this.getBooks, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final history = getBooks().where((b) {
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
      appBar: AppBar(title: const Text('Reading Now')),
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
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
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
                                  fontSize: 17,
                                  fontWeight: FontWeight.bold,
                                  color: forest),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _lastOpenedLabel(current),
                              style: TextStyle(
                                  fontSize: 13,
                                  color: forest.withValues(alpha: 0.65)),
                            ),
                            const SizedBox(height: 10),
                            _progressBar(current.progress),
                            const SizedBox(height: 4),
                            Text(
                              '${(current.progress * 100).round()}% read',
                              style: const TextStyle(
                                  fontSize: 12, color: terracotta),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      _continueButton(() => onOpen(current)),
                    ],
                  ),
                  const SizedBox(height: 28),
                ],
                if (rest.isNotEmpty) ...[
                  const Text(
                    'Recently',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: forest),
                  ),
                  const SizedBox(height: 12),
                  ...rest.map((book) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          softCoverWidget(book, width: 56, height: 80),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
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
                                  _lastOpenedLabel(book),
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: forest.withValues(alpha: 0.65)),
                                ),
                                const SizedBox(height: 6),
                                _progressBar(book.progress),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          _continueButton(() => onOpen(book)),
                        ],
                      ),
                    );
                  }),
                ],
              ],
            ),
    );
  }
}
