import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'custom_fonts.dart';
import 'dictionary.dart';
import 'extra_screens.dart';
import 'formats.dart';
import 'models.dart';
import 'reader_prefs.dart';
import 'stats.dart';
import 'transfer.dart';

// InkBloom theme: forest + terracotta + sage + cream. Own identity,
// deliberately unlike the blue/white look of other readers.
const forest = Color(0xFF173F35);
const forestDark = Color(0xFF122E28);
const sage = Color(0xFFA8C3A0);
const terracotta = Color(0xFFE07A5F);
const cream = Color(0xFFFFF8E7);

const highlightColors = <int>[
  0xFFFFFF00, // yellow
  0xFFFFC0CB, // pink
  0xFF90EE90, // green
  0xFFADD8E6, // blue
  0xFFFFA500, // orange
];

void main() => runApp(const InkBloomApp());

class InkBloomApp extends StatelessWidget {
  const InkBloomApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'InkBloom Reader',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: forest,
          primary: forest,
          secondary: terracotta,
        ),
        scaffoldBackgroundColor: cream,
        appBarTheme: const AppBarTheme(
          backgroundColor: forest,
          foregroundColor: Colors.white,
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: terracotta,
          foregroundColor: Colors.white,
        ),
        useMaterial3: true,
      ),
      home: SplashScreen(home: (_) => const LibraryScreen()),
    );
  }
}

// ── Shared helpers ──────────────────────────────────────────────────────

Widget coverWidget(LibraryBook book, {double width = 62, double height = 88}) {
  final file = book.coverPath != null ? File(book.coverPath!) : null;
  if (file != null && file.existsSync()) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.file(file,
          width: width, height: height, fit: BoxFit.cover),
    );
  }
  // Beautiful generated cover when a book has no embedded cover:
  // forest gradient, big initial, title and format badge.
  return Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [forest, forestDark],
      ),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Stack(children: [
      Center(
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Text(
            book.title.isNotEmpty ? book.title[0] : 'B',
            style: const TextStyle(
                color: Colors.white,
                fontSize: 30,
                fontWeight: FontWeight.bold),
          ),
        ),
      ),
      Positioned(
        bottom: 4,
        right: 4,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          decoration: BoxDecoration(
            color: terracotta,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(book.formatLabel,
              style: const TextStyle(color: Colors.white, fontSize: 8)),
        ),
      ),
    ]),
  );
}

Future<Directory> _booksDir() async {
  final dir = await getApplicationDocumentsDirectory();
  final d = Directory('${dir.path}/inkbloom_books');
  if (!await d.exists()) await d.create(recursive: true);
  return d;
}

Future<Directory> _coversDir() async {
  final dir = await getApplicationDocumentsDirectory();
  final d = Directory('${dir.path}/inkbloom_covers');
  if (!await d.exists()) await d.create(recursive: true);
  return d;
}

// ── Library ─────────────────────────────────────────────────────────────

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<LibraryBook> _books = [];
  ReaderSettings _settings = const ReaderSettings();
  ReadingStats _stats = const ReadingStats();
  String _query = '';
  String _sort = 'Recent';
  String _shelfFilter = 'All';
  bool _grid = true;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _settings =
        ReaderSettings.fromJsonString(prefs.getString('inkbloom_settings'));
    _stats = ReadingStats.fromJsonString(prefs.getString('inkbloom_stats'));
    final raw = prefs.getString('inkbloom_library_v2');
    final saved = <LibraryBook>[];
    if (raw != null) {
      try {
        for (final e in jsonDecode(raw) as List) {
          final b = LibraryBook.fromJson(e as Map<String, dynamic>);
          if (b != null) saved.add(b);
        }
      } catch (_) {}
    }
    final builtIns = sampleBooks();
    final result = <LibraryBook>[];
    for (final s in saved) {
      if (s.isBuiltin) {
        final sample =
            builtIns.where((b) => b.id == s.id).firstOrNull;
        if (sample != null) {
          result.add(LibraryBook(
            id: sample.id,
            title: sample.title,
            author: sample.author,
            format: sample.format,
            chapters: sample.chapters,
            progress: s.progress,
            lastChapter: s.lastChapter.clamp(0, sample.chapters.length - 1),
            lastParagraph: s.lastParagraph,
            bookmarks: s.bookmarks,
            highlights: s.highlights,
            shelf: s.shelf,
            isFavourite: s.isFavourite,
            tags: s.tags,
            addedAt: s.addedAt,
          ));
        }
      } else if (s.filePath != null) {
        try {
          final name = s.filePath!.split('/').last;
          final ParsedBook parsed;
          if (name.toLowerCase().endsWith('.pdf')) {
            parsed = await BookParser.parsePdfFile(File(s.filePath!), name);
          } else {
            final bytes = await File(s.filePath!).readAsBytes();
            parsed = BookParser.parse(name, bytes);
          }
          result.add(LibraryBook(
            id: s.id,
            title: parsed.title,
            author: parsed.author,
            format: parsed.format,
            filePath: s.filePath,
            coverPath: s.coverPath,
            chapters: parsed.chapters,
            progress: s.progress,
            lastChapter:
                s.lastChapter.clamp(0, parsed.chapters.length - 1),
            lastParagraph: s.lastParagraph,
            bookmarks: s.bookmarks,
            highlights: s.highlights,
            shelf: s.shelf,
            isFavourite: s.isFavourite,
            tags: s.tags,
            addedAt: s.addedAt,
          ));
        } catch (_) {}
      }
    }
    final seen = result.map((b) => b.id).toSet();
    result.addAll(builtIns.where((b) => !seen.contains(b.id)));
    if (!mounted) return;
    setState(() {
      _books = result;
      _loading = false;
    });
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'inkbloom_library_v2', jsonEncode(_books.map((b) => b.toJson()).toList()));
    await prefs.setString(
        'inkbloom_settings', jsonEncode(_settings.toJson()));
    await prefs.setString(
        'inkbloom_stats', jsonEncode(_stats.toJson()));
  }

  void _updateSettings(ReaderSettings s) {
    setState(() => _settings = s);
    _persist();
  }

  Future<void> _importFiles({bool multiple = false}) async {
    // file_picker 13: pickFiles() is multi, pickFile() is single.
    // Both return PlatformFile(s) read via readAsBytes().
    final files = multiple
        ? await FilePicker.pickFiles(
            type: FileType.custom,
            allowedExtensions: [
              'epub', 'pdf', 'txt', 'md', 'markdown', 'html', 'htm', 'fb2', 'rtf'
            ],
          )
        : [
            if (await FilePicker.pickFile(
              type: FileType.custom,
              allowedExtensions: [
                'epub', 'pdf', 'txt', 'md', 'markdown', 'html', 'htm', 'fb2', 'rtf'
              ],
            ) case final single?)
              single
          ];
    if (files.isEmpty) return;
    final dir = await _booksDir();
    final covers = await _coversDir();
    var added = 0;
    var failed = 0;
    for (final f in files) {
      final bytes = await f.readAsBytes();
      if (bytes.isEmpty) {
        failed++;
        continue;
      }
      final lowerName = f.name.toLowerCase();
      if (lowerName.endsWith('.mobi') || lowerName.endsWith('.azw') ||
          lowerName.endsWith('.azw3') || lowerName.endsWith('.azw4')) {
        failed++;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text(
                  'MOBI/AZW are Amazon formats and are not supported. Convert that book to EPUB first, then import it.')));
        }
        continue;
      }
      try {
        final ext = f.name.split('.').last.toLowerCase();
        final id = 'book-${DateTime.now().millisecondsSinceEpoch}-$added';
        final file = File('${dir.path}/$id.$ext');
        await file.writeAsBytes(bytes);
        final ParsedBook parsed;
        if (ext == 'pdf') {
          parsed = await BookParser.parsePdfFile(file, f.name);
        } else {
          parsed = BookParser.parse(f.name, bytes);
        }
        String? coverPath;
        if (parsed.coverBytes != null) {
          final cf = File('${covers.path}/$id.cover');
          await cf.writeAsBytes(parsed.coverBytes!);
          coverPath = cf.path;
        }
        setState(() {
          _books.insert(
            0,
            LibraryBook(
              id: id,
              title: parsed.title,
              author: parsed.author,
              format: parsed.format,
              filePath: file.path,
              coverPath: coverPath,
              chapters: parsed.chapters,
              addedAt: DateTime.now(),
            ),
          );
        });
        added++;
      } catch (_) {
        failed++;
      }
    }
    await _persist();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(failed == 0
              ? 'Added $added book${added == 1 ? '' : 's'}'
              : 'Added $added, $failed could not be opened')));
    }
  }

  Future<void> _setCover(LibraryBook book) async {
    final picked = await FilePicker.pickFile(type: FileType.image);
    if (picked == null) return;
    final covers = await _coversDir();
    final file = File('${covers.path}/${book.id}.cover');
    await file.writeAsBytes(await picked.readAsBytes());
    setState(() {
      final i = _books.indexWhere((b) => b.id == book.id);
      if (i >= 0) _books[i] = book.copyWith(coverPath: file.path);
    });
    await _persist();
  }

  void _updateBook(LibraryBook updated) {
    setState(() {
      final i = _books.indexWhere((b) => b.id == updated.id);
      if (i >= 0) _books[i] = updated;
    });
    _persist();
  }

  Future<void> _openBook(LibraryBook book) async {
    if (book.shelf == 'To Read') {
      final moved = book.copyWith(shelf: 'Reading');
      setState(() {
        final i = _books.indexWhere((b) => b.id == book.id);
        if (i >= 0) _books[i] = moved;
      });
      _persist();
      book = moved;
    }
    final updated = await Navigator.push<LibraryBook>(
      context,
      MaterialPageRoute(
        builder: (_) => ReaderScreen(
          book: book,
          settings: _settings,
          onSettingsChanged: _updateSettings,
        ),
      ),
    );
    if (updated != null) _updateBook(updated);
  }

  List<LibraryBook> get _visible {
    var list = _books.where((b) {
      if (_shelfFilter == 'Favourites' && !b.isFavourite) return false;
      if (_shelfFilter != 'All' &&
          _shelfFilter != 'Favourites' &&
          b.shelf != _shelfFilter) {
        return false;
      }
      if (_query.isEmpty) return true;
      final q = _query.toLowerCase();
      return b.title.toLowerCase().contains(q) ||
          b.author.toLowerCase().contains(q);
    }).toList();
    switch (_sort) {
      case 'Title':
        list.sort((a, b) => a.title.compareTo(b.title));
        break;
      case 'Author':
        list.sort((a, b) => a.author.compareTo(b.author));
        break;
      default:
        list.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(children: [
          Icon(Icons.menu_book_rounded),
          SizedBox(width: 10),
          Text('InkBloom Reader'),
        ]),
        actions: [
          IconButton(
            icon: Icon(_grid ? Icons.view_list : Icons.grid_view),
            onPressed: () => setState(() => _grid = !_grid),
            tooltip: 'Grid / list view',
          ),
          PopupMenuButton<String>(
            onSelected: (v) => setState(() => _sort = v),
            itemBuilder: (_) => ['Recent', 'Title', 'Author']
                .map((s) => PopupMenuItem(value: s, child: Text('Sort: $s')))
                .toList(),
            icon: const Icon(Icons.sort),
          ),
          IconButton(
            icon: const Icon(Icons.book),
            tooltip: 'Dictionary (offline)',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const DictionaryScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.coffee),
            tooltip: 'Support InkBloom — 2 tips only',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SupportScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => AppSettingsScreen(
                    settings: _settings,
                    statsJson: jsonEncode(_stats.toJson()),
                    books: _books,
                    onSettingsChanged: _updateSettings,
                    onRestore: (books, settings) {
                      setState(() {
                        _books = books;
                        _settings = settings;
                      });
                      _persist();
                    },
                  ),
                ),
              );
            },
            tooltip: 'Settings & transfer',
          ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.small(
            heroTag: 'batch',
            onPressed: () => _importFiles(multiple: true),
            tooltip: 'Batch import',
            child: const Icon(Icons.library_add),
          ),
          const SizedBox(height: 8),
          FloatingActionButton.extended(
            heroTag: 'import',
            onPressed: () => _importFiles(),
            icon: const Icon(Icons.add),
            label: const Text('Import book'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: TextField(
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    hintText: 'Search your library…',
                    prefixIcon: const Icon(Icons.search),
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(children: [
                  const Icon(Icons.spa_outlined, color: forest, size: 18),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${_books.length} books • ${_books.where((b) => b.progress > 0).length} in progress • EPUB, PDF, TXT, MD, HTML, FB2, RTF',
                      style: const TextStyle(color: forest),
                    ),
                  ),
                ]),
              ),
              // Reading stats, all local: streak, today vs goal, total.
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: Card(
                  color: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(children: [
                      Row(children: [
                        const Icon(Icons.local_fire_department,
                            color: terracotta),
                        const SizedBox(width: 6),
                        Text('${_stats.streak} day streak',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold)),
                        const Spacer(),
                        Text(
                            'Today ${_stats.todayMinutes.toStringAsFixed(0)} / ${_settings.goalMinutes} min'),
                      ]),
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: _settings.goalMinutes == 0
                              ? 0
                              : (_stats.todayMinutes /
                                      _settings.goalMinutes)
                                  .clamp(0.0, 1.0),
                          backgroundColor: sage.withValues(alpha: 0.4),
                          color: terracotta,
                          minHeight: 6,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(children: [
                        Text(
                            'Total ${_stats.totalMinutes.toStringAsFixed(0)} min • ${_stats.booksFinished} finished'),
                        const Spacer(),
                        TextButton(
                          onPressed: () async {
                            var goal = _settings.goalMinutes.toDouble();
                            await showDialog(
                              context: context,
                              builder: (_) => AlertDialog(
                                title: const Text('Daily reading goal'),
                                content: StatefulBuilder(
                                  builder: (ctx, setD) => Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text('${goal.round()} minutes a day'),
                                      Slider(
                                        value: goal,
                                        min: 5,
                                        max: 120,
                                        divisions: 23,
                                        onChanged: (v) =>
                                            setD(() => goal = v),
                                      ),
                                    ],
                                  ),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () {
                                      _updateSettings(_settings.copyWith(
                                          goalMinutes: goal.round()));
                                      Navigator.pop(context);
                                    },
                                    child: const Text('Save'),
                                  ),
                                ],
                              ),
                            );
                          },
                          child: const Text('Set goal'),
                        ),
                      ]),
                    ]),
                  ),
                ),
              ),
              // Shelves filter chips.
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: Row(
                  children: [
                    'All',
                    'Favourites',
                    'To Read',
                    'Reading',
                    'Finished'
                  ].map((s) {
                    final sel = _shelfFilter == s;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(s),
                        selected: sel,
                        selectedColor: terracotta,
                        labelStyle: TextStyle(
                            color: sel ? Colors.white : Colors.black),
                        onSelected: (_) =>
                            setState(() => _shelfFilter = s),
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: _visible.isEmpty
                    ? const Center(
                        child: Text('No books match. Import a book to begin.'))
                    : _grid
                        ? LayoutBuilder(
                            builder: (context, constraints) {
                              final w = constraints.maxWidth;
                              final cols = w < 600
                                  ? 2
                                  : w < 900
                                      ? 3
                                      : 4;
                              return GridView.builder(
                                padding: const EdgeInsets.fromLTRB(
                                    16, 8, 16, 110),
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: cols,
                                  childAspectRatio: 0.62,
                                  crossAxisSpacing: 12,
                                  mainAxisSpacing: 12,
                                ),
                                itemCount: _visible.length,
                                itemBuilder: (_, i) =>
                                    _gridCard(_visible[i]),
                              );
                            },
                          )
                        : ListView.builder(
                            padding:
                                const EdgeInsets.fromLTRB(16, 8, 16, 110),
                            itemCount: _visible.length,
                            itemBuilder: (_, i) =>
                                _listCard(_visible[i]),
                          ),
              ),
            ]),
    );
  }


  void _bookMenuAction(LibraryBook book, String v) {
    if (v == 'cover') {
      _setCover(book);
      return;
    }
    if (v == 'delete' && !book.isBuiltin) {
      setState(() => _books.removeWhere((b) => b.id == book.id));
      _persist();
      return;
    }
    if (v == 'fav') {
      _updateBook(book.copyWith(isFavourite: !book.isFavourite));
      return;
    }
    if (v.startsWith('shelf:')) {
      _updateBook(book.copyWith(shelf: v.substring(6)));
      return;
    }
    if (v == 'tags') {
      final controller =
          TextEditingController(text: book.tags.join(', '));
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Tags (comma separated)'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
                hintText: 'e.g. fantasy, classic, night read'),
          ),
          actions: [
            TextButton(
              onPressed: () {
                _updateBook(book.copyWith(
                    tags: controller.text
                        .split(',')
                        .map((e) => e.trim())
                        .where((e) => e.isNotEmpty)
                        .toList()));
                Navigator.pop(context);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      );
    }
  }

  List<PopupMenuItem<String>> _bookMenuItems(LibraryBook book) => [
        PopupMenuItem(
            value: book.isFavourite ? 'fav' : 'fav',
            child: Text(book.isFavourite
                ? 'Remove from Favourites'
                : 'Add to Favourites')),
        const PopupMenuItem(value: 'shelf:To Read', child: Text('Shelf: To Read')),
        const PopupMenuItem(value: 'shelf:Reading', child: Text('Shelf: Reading')),
        const PopupMenuItem(value: 'shelf:Finished', child: Text('Shelf: Finished')),
        const PopupMenuItem(value: 'tags', child: Text('Edit tags')),
        const PopupMenuItem(value: 'cover', child: Text('Set custom cover')),
        if (!book.isBuiltin)
          const PopupMenuItem(
              value: 'delete', child: Text('Remove from library')),
      ];

  Widget _gridCard(LibraryBook book) {
    final pct = (book.progress * 100).round();
    return Card(
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openBook(book),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(children: [
                Center(
                    child: coverWidget(book,
                        width: double.infinity, height: double.infinity)),
                Positioned(
                  top: 6,
                  right: 6,
                  child: PopupMenuButton<String>(
                    onSelected: (v) => _bookMenuAction(book, v),
                    itemBuilder: (_) => _bookMenuItems(book),
                    icon: const Icon(Icons.more_vert,
                        color: Colors.white, size: 18),
                  ),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(book.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  Text(book.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.grey[600], fontSize: 12)),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: book.progress,
                      backgroundColor: sage.withValues(alpha: 0.4),
                      color: terracotta,
                      minHeight: 5,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(children: [
                    if (book.isFavourite)
                      const Icon(Icons.favorite,
                          size: 12, color: terracotta),
                    Expanded(
                      child: Text(
                        pct == 0
                            ? 'Not started • Format: ${book.formatLabel}'
                            : '$pct% read • Format: ${book.formatLabel}',
                        style:
                            const TextStyle(fontSize: 11, color: forest),
                      ),
                    ),
                  ]),
                  if (book.tags.isNotEmpty)
                    Text(book.tags.join(' • '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 10, color: Colors.grey[600])),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _listCard(LibraryBook book) {
    final pct = (book.progress * 100).round();
    return Card(
      color: Colors.white,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _openBook(book),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            coverWidget(book),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(book.title,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 16)),
                  Text(book.author,
                      style: TextStyle(color: Colors.grey[600])),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: book.progress,
                      backgroundColor: sage.withValues(alpha: 0.4),
                      color: terracotta,
                      minHeight: 6,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(children: [
                    Expanded(
                      child: Text(
                        pct == 0
                            ? 'Not started • ${book.formatLabel}'
                            : '$pct% read • Ch ${book.lastChapter + 1}/${book.chapters.length}',
                        style:
                            const TextStyle(fontSize: 12, color: forest),
                      ),
                    ),
                    if (book.highlights.isNotEmpty)
                      const Icon(Icons.highlight,
                          size: 16, color: terracotta),
                    TextButton(
                      onPressed: () => _openBook(book),
                      child: Text(pct == 0 ? 'Read' : 'Continue'),
                    ),
                  ]),
                ],
              ),
            ),
            PopupMenuButton<String>(
              onSelected: (v) => _bookMenuAction(book, v),
              itemBuilder: (_) => _bookMenuItems(book),
            ),
          ]),
        ),
      ),
    );
  }
}

// ── App settings + transfer ─────────────────────────────────────────────

class AppSettingsScreen extends StatelessWidget {
  final ReaderSettings settings;
  final String statsJson;
  final List<LibraryBook> books;
  final ValueChanged<ReaderSettings> onSettingsChanged;
  final void Function(List<LibraryBook>, ReaderSettings) onRestore;
  const AppSettingsScreen({
    super.key,
    required this.settings,
    this.statsJson = '',
    required this.books,
    required this.onSettingsChanged,
    required this.onRestore,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings & Transfer')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Your navigation, your way',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          const SizedBox(height: 4),
          const Text(
              'These are the defaults for every book. You can still change them inside any book.'),
          const SizedBox(height: 12),
          _switchTile('Show top bar', settings.showTopBar,
              (v) => onSettingsChanged(settings.copyWith(showTopBar: v))),
          _switchTile('Show bottom chapter bar', settings.showBottomBar,
              (v) => onSettingsChanged(settings.copyWith(showBottomBar: v))),
          _switchTile('Show chapter slider', settings.showChapterSlider,
              (v) => onSettingsChanged(settings.copyWith(showChapterSlider: v))),
          _switchTile('Show prev / next buttons', settings.showPrevNext,
              (v) => onSettingsChanged(settings.copyWith(showPrevNext: v))),
          _switchTile('Show bookmark button', settings.showBookmarkButton,
              (v) => onSettingsChanged(settings.copyWith(showBookmarkButton: v))),
          _switchTile('Show search button', settings.showSearchButton,
              (v) => onSettingsChanged(settings.copyWith(showSearchButton: v))),
          _switchTile('Show chapter-list button', settings.showTocButton,
              (v) => onSettingsChanged(settings.copyWith(showTocButton: v))),
          _switchTile('Tap centre to hide / show bars', settings.autoHideBars,
              (v) => onSettingsChanged(settings.copyWith(autoHideBars: v))),
          _switchTile('Edge tap zones (left = back, right = next)',
              settings.tapZones,
              (v) => onSettingsChanged(settings.copyWith(tapZones: v))),
          _switchTile('Double-tap to lock / unlock', settings.doubleTapLockEnabled,
              (v) => onSettingsChanged(
                  settings.copyWith(doubleTapLockEnabled: v))),
          const SizedBox(height: 8),
          const Text('Navigation position',
              style: TextStyle(fontWeight: FontWeight.bold)),
          ...[
            (0, 'Bottom (classic)'),
            (1, 'Top, under the title bar'),
            (2, 'Floating pill at the bottom'),
          ].map((e) => RadioListTile<int>(
                title: Text(e.$2),
                value: e.$1,
                groupValue: settings.navPosition,
                onChanged: (v) => onSettingsChanged(
                    settings.copyWith(navPosition: v ?? 0)),
              )),
          const Divider(height: 32),
          const Text('Move everything to a new phone — fully offline',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          const SizedBox(height: 4),
          const Text(
              'One backup file holds every imported book, cover, progress, bookmark, highlight and note, plus your settings. No account, no internet.'),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () async {
              final zip = TransferBundle.buildZip(
                books: books,
                settingsJson: jsonEncode(settings.toJson()),
                statsJson: statsJson,
              );
              final uri = await FilePicker.saveFile(
                fileName: 'inkbloom-backup.inkbloom',
                bytes: zip,
              );
              final path = uri?.toString();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(path == null
                        ? 'Export cancelled'
                        : 'Backup saved — move this file to your new phone')));
              }
            },
            icon: const Icon(Icons.upload),
            label: const Text('Export all — backup file'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () async {
              final picked = await FilePicker.pickFile(type: FileType.any);
              if (picked == null) return;
              try {
                final bundle = TransferBundle.parseZip(
                    await picked.readAsBytes());
                final dir = await _booksDir();
                final covers = await _coversDir();
                final restored = <LibraryBook>[];
                for (final entry in bundle.files.entries) {
                  if (entry.key.startsWith('books/')) {
                    final id = entry.key
                        .split('/').last
                        .split('.').first;
                    final format =
                        entry.key.split('.').last;
                    await File('${dir.path}/$id.$format')
                        .writeAsBytes(entry.value);
                  }
                  if (entry.key.startsWith('covers/')) {
                    final id =
                        entry.key.split('/').last.split('.').first;
                    await File('${covers.path}/$id.cover')
                        .writeAsBytes(entry.value);
                  }
                }
                final samples = sampleBooks();
                for (final s in bundle.books) {
                  if (s.isBuiltin) {
                    final sample = samples
                        .where((b) => b.id == s.id)
                        .firstOrNull;
                    if (sample == null) continue;
                    restored.add(LibraryBook(
                      id: sample.id,
                      title: sample.title,
                      author: sample.author,
                      format: sample.format,
                      chapters: sample.chapters,
                      progress: s.progress,
                      lastChapter: s.lastChapter
                          .clamp(0, sample.chapters.length - 1),
                      lastParagraph: s.lastParagraph,
                      bookmarks: s.bookmarks,
                      highlights: s.highlights,
                      addedAt: s.addedAt,
                    ));
                  } else {
                    final file = File(
                        '${dir.path}/${s.id}.${s.format}');
                    if (!await file.exists()) continue;
                    final parsed = BookParser.parse(
                        file.path.split('/').last,
                        await file.readAsBytes());
                    final coverFile =
                        File('${covers.path}/${s.id}.cover');
                    restored.add(LibraryBook(
                      id: s.id,
                      title: parsed.title,
                      author: parsed.author,
                      format: parsed.format,
                      filePath: file.path,
                      coverPath: await coverFile.exists()
                          ? coverFile.path
                          : null,
                      chapters: parsed.chapters,
                      progress: s.progress,
                      lastChapter: s.lastChapter
                          .clamp(0, parsed.chapters.length - 1),
                      lastParagraph: s.lastParagraph,
                      bookmarks: s.bookmarks,
                      highlights: s.highlights,
                      addedAt: s.addedAt,
                    ));
                  }
                }
                final restoredSettings =
                    ReaderSettings.fromJsonString(bundle.settingsJson);
                if (bundle.statsJson.isNotEmpty) {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setString('inkbloom_stats', bundle.statsJson);
                }
                onRestore(restored, restoredSettings);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(
                          'Restored ${restored.length} books with all progress, highlights and notes')));
                }
              } catch (_) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text(
                              'That file is not an InkBloom backup.')));
                }
              }
            },
            icon: const Icon(Icons.download),
            label: const Text('Import backup on this phone'),
          ),
          const Divider(height: 32),
          const Text('More settings, neatly grouped',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          ExpansionTile(
            title: const Text('Colour & night'),
            children: [
              _switchTile('Auto night theme by time of day',
                  settings.autoNight,
                  (v) => onSettingsChanged(settings.copyWith(autoNight: v))),
              ListTile(
                title: Text(
                    'Night from ${settings.nightStartHour}:00 to ${settings.nightEndHour}:00'),
                subtitle: const Text(
                    'Change the hours inside any book: Text & theme → Auto night theme.'),
              ),
            ],
          ),
          ExpansionTile(
            title: const Text('Read aloud'),
            children: [
              ListTile(
                title: Text(
                    'Speech speed ${settings.ttsRate.toStringAsFixed(1)}× • pitch ${settings.ttsPitch.toStringAsFixed(1)}'),
                subtitle: const Text(
                    'Change speed and pitch inside any book: Text & theme → Read aloud. Tap the speaker icon to play.'),
              ),
            ],
          ),
          ExpansionTile(
            title: const Text('Stats & goals'),
            children: [
              ListTile(
                title: Text('Daily goal: ${settings.goalMinutes} minutes'),
                subtitle: const Text(
                    'Change it from the stats card on the library screen. Streaks and totals are local only.'),
              ),
            ],
          ),
          ExpansionTile(
            title: const Text('Fonts'),
            children: [
              ListTile(
                title: Text(settings.customFonts.isEmpty
                    ? 'No custom fonts yet'
                    : 'Custom fonts: ${settings.customFonts.join(', ')}'),
                subtitle: const Text(
                    'Import a .ttf/.otf inside any book: Text & theme → Import your own font.'),
              ),
            ],
          ),
          ExpansionTile(
            title: const Text('Dictionary & support'),
            children: [
              ListTile(
                leading: const Icon(Icons.book),
                title: const Text('Offline dictionary'),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const DictionaryScreen()),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.coffee),
                title: const Text('Support InkBloom — only 2 tips'),
                subtitle: const Text('Buy me a coffee • Buy me a headphone'),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const SupportScreen()),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: () => onSettingsChanged(const ReaderSettings()),
            child: const Text('Reset all settings to defaults'),
          ),
          const SizedBox(height: 8),
          const Text(
            'Package: com.wajiha.inkbloomreader • Fully offline • No account needed',
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _switchTile(
      String title, bool value, ValueChanged<bool> onChanged) {
    return SwitchListTile(
      title: Text(title),
      value: value,
      onChanged: onChanged,
    );
  }
}

// ── Reader ──────────────────────────────────────────────────────────────

class ReaderScreen extends StatefulWidget {
  final LibraryBook book;
  final ReaderSettings settings;
  final ValueChanged<ReaderSettings> onSettingsChanged;
  const ReaderScreen({
    super.key,
    required this.book,
    required this.settings,
    required this.onSettingsChanged,
  });
  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  late ReaderSettings _s;
  late int _chapter;
  late List<int> _bookmarks;
  late List<Highlight> _highlights;
  late bool _barsVisible;
  late bool _locked;
  String _searchTerm = '';
  final _scroll = ScrollController();
  final _pageController = PageController();
  final _tts = FlutterTts();
  bool _isSpeaking = false;
  DateTime _lastTick = DateTime.now();
  Timer? _statsTimer;
  ReadingStats _stats = const ReadingStats();
  Map<String, String> _customDict = {};

  @override
  void initState() {
    super.initState();
    _s = widget.settings;
    _chapter =
        widget.book.lastChapter.clamp(0, widget.book.chapters.length - 1);
    _bookmarks = [...widget.book.bookmarks];
    _highlights = [...widget.book.highlights];
    _barsVisible = true;
    _locked = false;
    _lastTick = DateTime.now();
    _loadReaderExtras();
    _tts.setCompletionHandler(() {
      if (mounted) setState(() => _isSpeaking = false);
    });
    _statsTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _recordReadingTime();
    });
  }

  Future<void> _loadReaderExtras() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _stats =
          ReadingStats.fromJsonString(prefs.getString('inkbloom_stats'));
      try {
        final raw = prefs.getString('inkbloom_custom_dict');
        if (raw != null) {
          final j = jsonDecode(raw) as Map<String, dynamic>;
          _customDict = j.map((k, v) => MapEntry(k, v.toString()));
        }
      } catch (_) {}
    });
  }

  Future<void> _recordReadingTime() async {
    final now = DateTime.now();
    final minutes = now.difference(_lastTick).inSeconds / 60.0;
    _lastTick = now;
    if (minutes <= 0) return;
    _stats = _stats.recordMinutes(minutes);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('inkbloom_stats', jsonEncode(_stats.toJson()));
  }

  Future<void> _speakChapter() async {
    await _tts.setSpeechRate(_s.ttsRate);
    await _tts.setPitch(_s.ttsPitch);
    await _tts.setLanguage('en-US');
    final text = widget.book.chapters[_chapter].paragraphs.join(' ');
    final result = await _tts.speak(text);
    if (mounted) setState(() => _isSpeaking = result == 1);
  }

  Future<void> _stopTts() async {
    await _tts.stop();
    if (mounted) setState(() => _isSpeaking = false);
  }

  @override
  void dispose() {
    _statsTimer?.cancel();
    _recordReadingTime();
    _tts.stop();
    _scroll.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _setSettings(ReaderSettings s) {
    setState(() => _s = s);
    widget.onSettingsChanged(s);
  }

  void _guarded(VoidCallback action) {
    if (_locked) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Locked — double-tap the page to unlock')));
      return;
    }
    action();
  }

  void _go(int chapter) {
    if (chapter < 0 || chapter >= widget.book.chapters.length) return;
    setState(() {
      _chapter = chapter;
      });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    if (_pageController.hasClients) _pageController.jumpToPage(0);
  }

  LibraryBook _bookToReturn() {
    final total = widget.book.chapters.length;
    final progress = total <= 1 ? 1.0 : _chapter / (total - 1);
    return widget.book.copyWith(
      progress: progress,
      lastChapter: _chapter,
      bookmarks: _bookmarks,
      highlights: _highlights,
    );
  }

  Widget _paragraphWidget(int chapterIdx, int paraIdx, String text) {
    final hl = _highlights
        .where((h) => h.chapter == chapterIdx && h.paragraph == paraIdx)
        .firstOrNull;
    final isSearchHit = _searchTerm.isNotEmpty &&
        text.toLowerCase().contains(_searchTerm.toLowerCase());
    final theme = _s.effectiveTheme;
    Widget content;
    if (_searchTerm.isNotEmpty && isSearchHit) {
      // Highlight every match of the search term inside this paragraph.
      final term = _searchTerm.toLowerCase();
      final lower = text.toLowerCase();
      final spans = <TextSpan>[];
      var start = 0;
      while (true) {
        final idx = lower.indexOf(term, start);
        if (idx < 0) {
          spans.add(TextSpan(text: text.substring(start)));
          break;
        }
        if (idx > start) spans.add(TextSpan(text: text.substring(start, idx)));
        spans.add(TextSpan(
          text: text.substring(idx, idx + term.length),
          style: TextStyle(
              backgroundColor: theme.accent.withValues(alpha: 0.55),
              fontWeight: FontWeight.bold),
        ));
        start = idx + term.length;
      }
      content = RichText(
        textAlign: _s.align,
        text: TextSpan(
          style: TextStyle(
            color: theme.fg,
            fontSize: _s.fontSize,
            height: _s.lineHeight,
            letterSpacing: _s.letterSpacing,
            fontFamily: _s.fontFamily,
            fontWeight: _s.boldText ? FontWeight.bold : FontWeight.normal,
          ),
          children: spans,
        ),
      );
    } else {
      content = Text(
        text,
        textAlign: _s.align,
        style: TextStyle(
          color: theme.fg,
          fontSize: _s.fontSize,
          height: _s.lineHeight,
          letterSpacing: _s.letterSpacing,
          fontFamily: _s.fontFamily,
          fontWeight: _s.boldText ? FontWeight.bold : FontWeight.normal,
        ),
      );
    }
    return GestureDetector(
      onLongPress: () =>
          _guarded(() => _highlightSheet(chapterIdx, paraIdx, hl, text)),
      child: Container(
        width: double.infinity,
        color: hl != null
            ? Color(hl.color).withValues(alpha: 0.45)
            : Colors.transparent,
        padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: content),
            if (hl != null && hl.note.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.note, size: 18),
                color: theme.accent,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () => showDialog(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('Your note'),
                    content: Text(hl.note),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Close'))
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _highlightSheet(
      int chapterIdx, int paraIdx, Highlight? existing, String text) async {
    final noteController = TextEditingController(text: existing?.note ?? '');
    var chosen = existing?.color ?? highlightColors.first;
    await showModalBottomSheet(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setSheet) => Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Highlight & note',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: highlightColors
                  .map((c) => GestureDetector(
                        onTap: () => setSheet(() => chosen = c),
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: Color(c),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: chosen == c ? forest : Colors.grey,
                              width: chosen == c ? 3 : 1,
                            ),
                          ),
                        ),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: noteController,
              decoration: const InputDecoration(
                labelText: 'Add a note (optional)',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
            const SizedBox(height: 12),
            const Text('Dictionary — tap a word in this paragraph',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: text
                  .split(RegExp(r'\s+'))
                  .map((w) => w
                      .toLowerCase()
                      .replaceAll(RegExp(r"[^a-z']"), ''))
                  .where((w) => w.length > 2)
                  .toSet()
                  .take(18)
                  .map((w) => ActionChip(
                        label: Text(w),
                        onPressed: () {
                          final def = lookupWord(w, _customDict);
                          showDialog(
                            context: context,
                            builder: (_) => AlertDialog(
                              title: Text(w),
                              content: Text(def ??
                                  'No offline definition for "$w" yet. The app does not invent definitions — add your own in Dictionary (top bar, book icon).'),
                              actions: [
                                TextButton(
                                    onPressed: () =>
                                        Navigator.pop(context),
                                    child: const Text('Close')),
                              ],
                            ),
                          );
                        },
                      ))
                  .toList(),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: FilledButton(
                  onPressed: () {
                    setState(() {
                      _highlights.removeWhere((h) =>
                          h.chapter == chapterIdx &&
                          h.paragraph == paraIdx);
                      _highlights.add(Highlight(
                        chapter: chapterIdx,
                        paragraph: paraIdx,
                        color: chosen,
                        note: noteController.text.trim(),
                      ));
                    });
                    Navigator.pop(context);
                  },
                  child: const Text('Save highlight'),
                ),
              ),
              if (existing != null) ...[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () {
                    setState(() => _highlights.removeWhere((h) =>
                        h.chapter == chapterIdx &&
                        h.paragraph == paraIdx));
                    Navigator.pop(context);
                  },
                  child: const Text('Remove'),
                ),
              ],
            ]),
          ]),
        ),
      ),
    );
  }

  Future<void> _searchSheet() async {
    final controller = TextEditingController(text: _searchTerm);
    var hits = _searchTerm.isEmpty
        ? <SearchHit>[]
        : searchBook(widget.book, _searchTerm);
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (context, setSheet) => Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(context).viewInsets.bottom + 16,
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Search inside this book',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setSheet(
                  () => hits = searchBook(widget.book, v)),
            ),
            const SizedBox(height: 12),
            Text('${hits.length} match${hits.length == 1 ? '' : 'es'}'),
            SizedBox(
              height: 300,
              child: ListView.builder(
                itemCount: hits.length,
                itemBuilder: (_, i) {
                  final h = hits[i];
                  return ListTile(
                    title: Text(h.snippet),
                    subtitle: Text(
                        '${widget.book.chapters[h.chapter].title} • paragraph ${h.paragraph + 1}'),
                    onTap: () {
                      setState(() {
                        _searchTerm = controller.text;
                        _chapter = h.chapter;
                                          });
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text(
                                  'Matches are highlighted in this chapter')));
                    },
                  );
                },
              ),
            ),
          ]),
        ),
      ),
    );
  }

  void _notesSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Highlights & notes',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          SizedBox(
            height: 400,
            child: _highlights.isEmpty
                ? const Center(
                    child: Text(
                        'Nothing yet. Long-press any paragraph to highlight it or add a note.'))
                : ListView.builder(
                    itemCount: _highlights.length,
                    itemBuilder: (_, i) {
                      final h = _highlights[i];
                      final text =
                          widget.book.chapters[h.chapter].paragraphs[h.paragraph];
                      return ListTile(
                        leading: Container(
                            width: 20,
                            height: 20,
                            color: Color(h.color)),
                        title: Text(text,
                            maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text(h.note.isEmpty
                            ? widget.book.chapters[h.chapter].title
                            : '${widget.book.chapters[h.chapter].title} • ${h.note}'),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () {
                            setState(() => _highlights.removeAt(i));
                            Navigator.pop(context);
                          },
                        ),
                        onTap: () {
                          Navigator.pop(context);
                          _go(h.chapter);
                        },
                      );
                    },
                  ),
          ),
        ]),
      ),
    );
  }

  Widget _chapterBar() {
    final theme = _s.effectiveTheme;
    return Container(
      color: theme.bg,
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
      child: Row(children: [
        if (_s.showPrevNext)
          IconButton(
            icon: const Icon(Icons.chevron_left),
            color: theme.fg,
            onPressed:
                _chapter > 0 ? () => _guarded(() => _go(_chapter - 1)) : null,
          ),
        Expanded(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(
              'Chapter ${_chapter + 1} of ${widget.book.chapters.length}',
              style: TextStyle(color: theme.fg, fontSize: 12),
            ),
            if (_s.showChapterSlider)
              Slider(
                value: _chapter.toDouble(),
                min: 0,
                max: (widget.book.chapters.length - 1).toDouble(),
                divisions: widget.book.chapters.length - 1 > 0
                    ? widget.book.chapters.length - 1
                    : null,
                activeColor: theme.accent,
                onChanged: (v) => _guarded(() => _go(v.round())),
              ),
          ]),
        ),
        if (_s.showPrevNext)
          IconButton(
            icon: const Icon(Icons.chevron_right),
            color: theme.fg,
            onPressed: _chapter < widget.book.chapters.length - 1
                ? () => _guarded(() => _go(_chapter + 1))
                : null,
          ),
      ]),
    );
  }

  Widget _body() {
    final theme = _s.effectiveTheme;
    final chapter = widget.book.chapters[_chapter];
    if (_s.readingMode == 1) {
      final pages = paginate(chapter.paragraphs, _s.fontSize);
      return PageView.builder(
        controller: _pageController,
        itemCount: pages.length,
        onPageChanged: (i) => setState(() {}),
        itemBuilder: (_, pi) => ListView(
          padding: EdgeInsets.all(_s.pageMargin),
          children: [
            if (pi == 0)
              Padding(
                padding: EdgeInsets.only(bottom: _s.paragraphSpacing),
                child: Text(chapter.title,
                    style: TextStyle(
                        color: theme.fg,
                        fontSize: _s.fontSize + 6,
                        fontWeight: FontWeight.bold)),
              ),
            ...pages[pi].asMap().entries.map((e) {
              // Paragraph index within the chapter for this page.
              var idx = 0;
              for (var p = 0; p < pi; p++) {
                idx += pages[p].length;
              }
              return Padding(
                padding: EdgeInsets.only(bottom: _s.paragraphSpacing),
                child: _paragraphWidget(
                    _chapter, idx + e.key, e.value),
              );
            }),
            Center(
              child: Text('Page ${pi + 1} of ${pages.length}',
                  style: TextStyle(
                      color: theme.fg.withValues(alpha: 0.6),
                      fontSize: 12)),
            ),
          ],
        ),
      );
    }
    // Continuous scroll (mode 0) and horizontal scroll (mode 2 uses
    // the same list; swipe paging is mode 1).
    return ListView(
      controller: _scroll,
      padding: EdgeInsets.all(_s.pageMargin),
      children: [
        Text(chapter.title,
            style: TextStyle(
                color: theme.fg,
                fontSize: _s.fontSize + 6,
                fontWeight: FontWeight.bold,
                height: 1.3)),
        const SizedBox(height: 20),
        ...chapter.paragraphs.asMap().entries.map((e) => Padding(
              padding: EdgeInsets.only(bottom: _s.paragraphSpacing),
              child: _paragraphWidget(_chapter, e.key, e.value),
            )),
        const SizedBox(height: 24),
        Center(
          child: Text('— End of chapter —',
              style: TextStyle(color: theme.fg.withValues(alpha: 0.6))),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = _s.effectiveTheme;
    final showBars = _barsVisible;
    final appBar = AppBar(
      backgroundColor: forest,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () => Navigator.pop(context, _bookToReturn()),
      ),
      title: Text(widget.book.title,
          style: const TextStyle(fontSize: 16),
          overflow: TextOverflow.ellipsis),
      actions: [
        if (_s.showTocButton)
          Builder(
            builder: (btnContext) => IconButton(
              icon: const Icon(Icons.list),
              onPressed: () => _guarded(
                  () => Scaffold.of(btnContext).openDrawer()),
              tooltip: 'Chapters',
            ),
          ),
        if (_s.showSearchButton)
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => _guarded(_searchSheet),
            tooltip: 'Search in book',
          ),
        IconButton(
          icon: const Icon(Icons.highlight),
          onPressed: () => _guarded(_notesSheet),
          tooltip: 'Highlights & notes',
        ),
        if (_s.showBookmarkButton)
          IconButton(
            icon: Icon(_bookmarks.contains(_chapter)
                ? Icons.bookmark
                : Icons.bookmark_border),
            onPressed: () => _guarded(() {
              setState(() {
                if (_bookmarks.contains(_chapter)) {
                  _bookmarks.remove(_chapter);
                } else {
                  _bookmarks.add(_chapter);
                }
              });
            }),
            tooltip: 'Bookmark chapter',
          ),
        IconButton(
          icon: Icon(_locked ? Icons.lock : Icons.lock_open),
          onPressed: () {
            if (_s.doubleTapLockEnabled) {
              setState(() => _locked = !_locked);
            }
          },
          tooltip: 'Lock / unlock',
        ),
        IconButton(
          icon: Icon(_isSpeaking ? Icons.stop : Icons.volume_up),
          onPressed: () => _guarded(() {
            if (_isSpeaking) {
              _stopTts();
            } else {
              _speakChapter();
            }
          }),
          tooltip: 'Read aloud',
        ),
        IconButton(
          icon: const Icon(Icons.text_fields),
          onPressed: () => _guarded(_settingsSheet),
          tooltip: 'Text, theme & navigation',
        ),
      ],
    );
    // Drawer needs a Scaffold context, so wrap the app bar actions that
    // open it in a Builder below; the list button above is replaced
    // by using a Builder in the body instead — see _drawerButton.
    return Scaffold(
      backgroundColor: theme.bg,
      appBar: (_s.showTopBar && showBars) ? appBar : null,
      drawer: Drawer(
        child: ListView(children: [
          DrawerHeader(
            decoration: const BoxDecoration(color: forest),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                const Icon(Icons.menu_book_rounded,
                    color: Colors.white, size: 32),
                const SizedBox(height: 8),
                Text(widget.book.title,
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold)),
                Text(widget.book.author,
                    style: const TextStyle(color: Colors.white70)),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: terracotta,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('Format: ${widget.book.formatLabel}',
                      style: const TextStyle(
                          color: Colors.white, fontSize: 12)),
                ),
              ],
            ),
          ),
          ...List.generate(widget.book.chapters.length, (i) {
            final c = widget.book.chapters[i];
            return ListTile(
              selected: i == _chapter,
              selectedTileColor: sage.withValues(alpha: 0.3),
              leading: _bookmarks.contains(i)
                  ? const Icon(Icons.bookmark, color: terracotta, size: 18)
                  : Text('${i + 1}'),
              title: Text(c.title),
              onTap: () {
                Navigator.pop(context);
                _guarded(() => _go(i));
              },
            );
          }),
        ]),
      ),
      floatingActionButton:
          (!_s.showTopBar || !_s.showBottomBar || !showBars)
              ? FloatingActionButton.small(
                  onPressed: () => setState(() => _barsVisible = true),
                  tooltip: 'Show navigation',
                  child: const Icon(Icons.menu),
                )
              : null,
      bottomNavigationBar:
          (_s.showBottomBar && showBars && _s.navPosition == 0)
              ? _chapterBar()
              : null,
      body: Builder(
        builder: (scaffoldContext) => GestureDetector(
          onDoubleTap: _s.doubleTapLockEnabled
              ? () => setState(() => _locked = !_locked)
              : null,
          onTap: _s.autoHideBars
              ? () => setState(() => _barsVisible = !_barsVisible)
              : null,
          child: Stack(children: [
            Column(children: [
              if (_s.showBottomBar && showBars && _s.navPosition == 1)
                _chapterBar(),
              if (_locked)
                Container(
                  width: double.infinity,
                  color: terracotta,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.lock, size: 16, color: Colors.white),
                      SizedBox(width: 6),
                      Text('Locked — double-tap the page to unlock',
                          style: TextStyle(color: Colors.white)),
                    ],
                  ),
                ),
              if (_isSpeaking)
                Container(
                  width: double.infinity,
                  color: forest,
                  padding: const EdgeInsets.symmetric(
                      vertical: 6, horizontal: 12),
                  child: Row(children: [
                    const Icon(Icons.volume_up,
                        color: Colors.white, size: 18),
                    const SizedBox(width: 8),
                    const Expanded(
                        child: Text('Reading aloud…',
                            style: TextStyle(color: Colors.white))),
                    TextButton(
                      onPressed: _stopTts,
                      child: const Text('Stop',
                          style: TextStyle(color: Colors.white)),
                    ),
                  ]),
                ),
              if (_searchTerm.isNotEmpty)
                Container(
                  width: double.infinity,
                  color: theme.accent.withValues(alpha: 0.25),
                  padding: const EdgeInsets.symmetric(
                      vertical: 6, horizontal: 12),
                  child: Row(children: [
                    Expanded(
                        child: Text('Searching: "$_searchTerm"',
                            style: TextStyle(color: theme.fg))),
                    TextButton(
                      onPressed: () => setState(() => _searchTerm = ''),
                      child: const Text('Clear'),
                    ),
                  ]),
                ),
              Expanded(child: _body()),
            ]),
            if (_s.showBottomBar && showBars && _s.navPosition == 2)
              Positioned(
                left: 16,
                right: 16,
                bottom: 16,
                child: Card(
                  elevation: 6,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24)),
                  child: _chapterBar(),
                ),
              ),
            // Edge tap zones, when enabled: left edge = previous
            // chapter, right edge = next chapter. Kept clear of the
            // top/bottom bars so scrolling in the middle still works.
            if (_s.tapZones && !_locked) ...[
              Positioned(
                left: 0,
                top: 120,
                bottom: 120,
                width: 44,
                child: GestureDetector(
                  onTap: () =>
                      _guarded(() => _go(_chapter - 1)),
                  child: Container(color: Colors.transparent),
                ),
              ),
              Positioned(
                right: 0,
                top: 120,
                bottom: 120,
                width: 44,
                child: GestureDetector(
                  onTap: () =>
                      _guarded(() => _go(_chapter + 1)),
                  child: Container(color: Colors.transparent),
                ),
              ),
            ],
            // Chapter-list button when the top bar is hidden: the
            // Scaffold drawer still needs a context, provided here.
            if (!_s.showTopBar || !showBars)
              Positioned(
                top: 12,
                left: 12,
                child: FloatingActionButton.small(
                  heroTag: 'toc',
                  onPressed: () => _guarded(
                      () => Scaffold.of(scaffoldContext).openDrawer()),
                  child: const Icon(Icons.list),
                ),
              ),
          ]),
        ),
      ),
    );
  }

  void _settingsSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (context, setSheet) {
          void update(ReaderSettings s) {
            setSheet(() {});
            _setSettings(s);
          }

          return DraggableScrollableSheet(
            initialChildSize: 0.85,
            expand: false,
            builder: (_, scrollController) => ListView(
              controller: scrollController,
              padding: const EdgeInsets.all(20),
              children: [
                const Text('Text, theme & navigation',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                const SizedBox(height: 16),
                _sliderRow('Text size', _s.fontSize, 12, 32,
                    (v) => update(_s.copyWith(fontSize: v))),
                _sliderRow('Line height', _s.lineHeight, 1.2, 2.2,
                    (v) => update(_s.copyWith(lineHeight: v))),
                _sliderRow('Letter spacing', _s.letterSpacing, 0, 3,
                    (v) => update(_s.copyWith(letterSpacing: v))),
                _sliderRow('Paragraph spacing', _s.paragraphSpacing, 4, 32,
                    (v) => update(_s.copyWith(paragraphSpacing: v))),
                _sliderRow('Page margin', _s.pageMargin, 12, 40,
                    (v) => update(_s.copyWith(pageMargin: v))),
                const SizedBox(height: 8),
                const Text('Font',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                Wrap(
                  spacing: 8,
                  children: ['Serif', 'Sans', 'Mono'].asMap().entries.map((e) {
                    final sel = _s.fontIndex == e.key;
                    return ChoiceChip(
                      label: Text(e.value),
                      selected: sel,
                      onSelected: (_) =>
                          update(_s.copyWith(fontIndex: e.key)),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 8),
                const Text('Your imported fonts',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                Wrap(
                  spacing: 8,
                  children: _s.customFonts.asMap().entries.map((e) {
                    final sel = _s.fontIndex == 3 + e.key;
                    return ChoiceChip(
                      label: Text(e.value),
                      selected: sel,
                      onSelected: (_) =>
                          update(_s.copyWith(fontIndex: 3 + e.key)),
                    );
                  }).toList(),
                ),
                TextButton.icon(
                  onPressed: () async {
                    final picked = await FilePicker.pickFile(
                      type: FileType.custom,
                      allowedExtensions: ['ttf', 'otf'],
                    );
                    if (picked == null) {
                      return;
                    }
                    final family = await CustomFonts.importFont(
                        picked.name, await picked.readAsBytes());
                    if (family == null) return;
                    final fonts = [..._s.customFonts];
                    if (!fonts.contains(family)) fonts.add(family);
                    update(_s.copyWith(
                        customFonts: fonts,
                        fontIndex: 3 + fonts.indexOf(family)));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                              content: Text('Font "$family" imported')));
                    }
                  },
                  icon: const Icon(Icons.font_download),
                  label: const Text('Import your own font (.ttf / .otf)'),
                ),
                const SizedBox(height: 8),
                const Text('Auto night theme',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                SwitchListTile(
                  title: const Text('Auto night theme by time of day'),
                  subtitle: Text(
                      'Midnight theme from ${_s.nightStartHour}:00 to ${_s.nightEndHour}:00'),
                  value: _s.autoNight,
                  onChanged: (v) => update(_s.copyWith(autoNight: v)),
                ),
                _sliderRow('Night starts (hour)', _s.nightStartHour.toDouble(),
                    0, 23, (v) => update(
                        _s.copyWith(nightStartHour: v.round()))),
                _sliderRow('Night ends (hour)', _s.nightEndHour.toDouble(), 0,
                    23, (v) =>
                        update(_s.copyWith(nightEndHour: v.round()))),
                const SizedBox(height: 8),
                const Text('Read aloud',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                _sliderRow('Speech speed', _s.ttsRate, 0.5, 2.0,
                    (v) => update(_s.copyWith(ttsRate: v))),
                _sliderRow('Speech pitch', _s.ttsPitch, 0.5, 2.0,
                    (v) => update(_s.copyWith(ttsPitch: v))),
                const Text(
                    'Tap the speaker icon in the top bar to start or stop reading aloud. Speed and pitch apply to the next chapter you play.'),
                const SizedBox(height: 8),
                const Text('Alignment',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                Wrap(
                  spacing: 8,
                  children: ['Left', 'Justified', 'Centre']
                      .asMap()
                      .entries
                      .map((e) {
                    final sel = _s.alignIndex == e.key;
                    return ChoiceChip(
                      label: Text(e.value),
                      selected: sel,
                      onSelected: (_) =>
                          update(_s.copyWith(alignIndex: e.key)),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  title: const Text('Bold text'),
                  value: _s.boldText,
                  onChanged: (v) => update(_s.copyWith(boldText: v)),
                ),
                const SizedBox(height: 8),
                const Text('Reading mode',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                Wrap(
                  spacing: 8,
                  children: [
                    'Continuous scroll',
                    'Paged swipe',
                    'Scroll (simple)',
                  ].asMap().entries.map((e) {
                    final sel = _s.readingMode == e.key;
                    return ChoiceChip(
                      label: Text(e.value),
                      selected: sel,
                      onSelected: (_) => update(
                          _s.copyWith(readingMode: e.key == 2 ? 0 : e.key)),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 12),
                const Text('Colour themes — 12',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: readerThemes.asMap().entries.map((e) {
                    final sel = _s.themeIndex == e.key;
                    return GestureDetector(
                      onTap: () => update(_s.copyWith(themeIndex: e.key)),
                      child: Container(
                        width: 64,
                        height: 48,
                        decoration: BoxDecoration(
                          color: e.value.bg,
                          border: Border.all(
                            color: sel ? terracotta : Colors.grey,
                            width: sel ? 3 : 1,
                          ),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Center(
                          child: Text(e.value.name.split(' ').first,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: e.value.fg, fontSize: 10)),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
                const Text('Navigation — set it up your way',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                SwitchListTile(
                    title: const Text('Show top bar'),
                    value: _s.showTopBar,
                    onChanged: (v) => update(_s.copyWith(showTopBar: v))),
                SwitchListTile(
                    title: const Text('Show bottom chapter bar'),
                    value: _s.showBottomBar,
                    onChanged: (v) => update(_s.copyWith(showBottomBar: v))),
                SwitchListTile(
                    title: const Text('Show chapter slider'),
                    value: _s.showChapterSlider,
                    onChanged: (v) =>
                        update(_s.copyWith(showChapterSlider: v))),
                SwitchListTile(
                    title: const Text('Show prev / next buttons'),
                    value: _s.showPrevNext,
                    onChanged: (v) => update(_s.copyWith(showPrevNext: v))),
                SwitchListTile(
                    title: const Text('Show bookmark button'),
                    value: _s.showBookmarkButton,
                    onChanged: (v) =>
                        update(_s.copyWith(showBookmarkButton: v))),
                SwitchListTile(
                    title: const Text('Show search button'),
                    value: _s.showSearchButton,
                    onChanged: (v) =>
                        update(_s.copyWith(showSearchButton: v))),
                SwitchListTile(
                    title: const Text('Show chapter-list button'),
                    value: _s.showTocButton,
                    onChanged: (v) => update(_s.copyWith(showTocButton: v))),
                SwitchListTile(
                    title: const Text('Tap centre to hide / show bars'),
                    value: _s.autoHideBars,
                    onChanged: (v) => update(_s.copyWith(autoHideBars: v))),
                SwitchListTile(
                    title: const Text('Edge tap zones'),
                    value: _s.tapZones,
                    onChanged: (v) => update(_s.copyWith(tapZones: v))),
                SwitchListTile(
                    title: const Text('Double-tap lock'),
                    value: _s.doubleTapLockEnabled,
                    onChanged: (v) =>
                        update(_s.copyWith(doubleTapLockEnabled: v))),
                const SizedBox(height: 8),
                const Text('Navigation position',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                ...[
                  (0, 'Bottom (classic)'),
                  (1, 'Top, under the title bar'),
                  (2, 'Floating pill at the bottom'),
                ].map((e) => RadioListTile<int>(
                      title: Text(e.$2),
                      value: e.$1,
                      groupValue: _s.navPosition,
                      onChanged: (v) => update(
                          _s.copyWith(navPosition: v ?? 0)),
                    )),
                const SizedBox(height: 8),
                const Text(
                  'How to use: long-press any paragraph to highlight it or add a note. Double-tap the page to lock it, double-tap again to unlock.',
                  style: TextStyle(color: Colors.grey),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _sliderRow(String label, double value, double min, double max,
      ValueChanged<double> onChanged) {
    return Row(children: [
      SizedBox(width: 130, child: Text(label)),
      Expanded(
        child: Slider(
          value: value,
          min: min,
          max: max,
          activeColor: terracotta,
          onChanged: onChanged,
        ),
      ),
      SizedBox(
          width: 44,
          child: Text(value.toStringAsFixed(value < 10 ? 1 : 0))),
    ]);
  }
}
