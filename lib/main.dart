import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_lang.dart';
import 'custom_fonts.dart';
import 'file_read.dart';
import 'isolate_parse.dart';
import 'dictionary.dart';
import 'extra_screens.dart';
import 'formats.dart';
import 'book_cache.dart';
import 'books_screens.dart';
import 'brightness.dart';
import 'share_review.dart';
import 'squishy.dart';
import 'models.dart';
import 'reader_prefs.dart';
import 'stats.dart';
import 'transfer.dart';

// InkBloom theme: forest + terracotta + sage + cream. Own identity,
// deliberately unlike the blue/white look of other readers.
const forest = Color(0xFF173F35);
const forestDark = Color(0xFF122E28);
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

/// Watches route changes so the library can dismiss the
/// keyboard whenever the user comes back to it.
final RouteObserver<ModalRoute<void>> routeObserver =
    RouteObserver<ModalRoute<void>>();

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
      navigatorObservers: [routeObserver],
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

/// Small white tool card used on the library home (Stitch reference).
class _ToolCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _ToolCard(
      {required this.icon, required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return Squishy(
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(children: [
          Icon(icon, color: forest),
          const SizedBox(height: 6),
          Text(label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11)),
        ]),
      ),
    ));
  }
}

// ── Library ─────────────────────────────────────────────────────────────

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> with RouteAware {
  List<LibraryBook> _books = [];
  ReaderSettings _settings = const ReaderSettings();
  ReadingStats _stats = const ReadingStats();
  String _query = '';
  String _sort = 'Recent';
  String _shelfFilter = 'All';
  bool _grid = true;
  bool _loading = true;
  /// True once _load() has read the saved library. _persist()
  /// must NEVER write the library before this: on a slow
  /// start the 5-second safety net shows sample books, and a
  /// persist in that window used to overwrite the real saved
  /// library with samples — books gone after reopening.
  bool _libraryLoaded = false;
  final _searchFocus = FocusNode();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) routeObserver.subscribe(this, route);
  }

  @override
  void didPopNext() {
    // Coming back to the main screen must never pop the
    // keyboard up for a search the user did not ask for.
    _searchFocus.unfocus();
    FocusScope.of(context).unfocus();
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _load();
    // Safety net: the library must NEVER sit on a spinner forever.
    // If loading is still unfinished after 5 seconds, show the
    // sample books and let the user in — saved books load on open.
    Future.delayed(const Duration(seconds: 5), () {
      if (mounted && _loading) {
        // Merge samples IN, never replace: replacing _books
        // here used to let a later persist overwrite the real
        // library (still loading) with samples only.
        setState(() {
          final ids = _books.map((b) => b.id).toSet();
          _books = [
            ..._books,
            ...sampleBooks().where((b) => !ids.contains(b.id)),
          ];
          _loading = false;
        });
      }
    });
  }

  Future<void> _load() async {
    // FAST + SAFE: show the library immediately from what was saved.
    // The old code re-parsed every imported file on every launch
    // (including slow PDF extraction), so one big or slow book froze
    // the whole library on a spinner and imported books never appeared.
    // Chapters are now parsed lazily, only when a book is opened.
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
    // Books imported while _load() was still running (or
    // shown by the safety net) must survive it: merge any
    // in-memory book the disk result does not already have.
    final result = <LibraryBook>[];
    for (final s in saved) {
      if (s.isBuiltin) {
        final sample = builtIns.where((b) => b.id == s.id).firstOrNull;
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
      } else {
        // Keep the book exactly as saved. Its file is parsed on open.
        result.add(s);
      }
    }
    final seen = result.map((b) => b.id).toSet();
    result.addAll(builtIns.where((b) => !seen.contains(b.id)));
    final kept = _books
        .where((b) => !result.any((r) => r.id == b.id))
        .toList();
    final merged = [...kept, ...result];
    // Corrupt-save guard: saved JSON existed and mentioned
    // real files, but nothing parsed out of it. Do not mark
    // the library loaded — a later persist would overwrite
    // the (possibly recoverable) save with samples only.
    final corrupt = raw != null &&
        raw.trim().isNotEmpty &&
        saved.where((b) => !b.isBuiltin).isEmpty &&
        RegExp(r'"filePath"\s*:\s*"').hasMatch(raw);
    if (!mounted) return;
    setState(() {
      _books = merged;
      _loading = false;
      // On a corrupt save, _libraryLoaded stays false, so
      // library writes stay blocked (see the field comment).
      _libraryLoaded = !corrupt;
    });
    if (kept.isNotEmpty) await _persist();
    if (corrupt && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Your saved books could not be read. Your book files are still on this phone — re-import them to restore the library.'),
          duration: Duration(seconds: 8)));
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    // Never write the library before it has been read (see
    // _libraryLoaded): an early persist would wipe the saved
    // books with whatever partial list is in memory.
    if (_libraryLoaded) {
      await prefs.setString(
          'inkbloom_library_v2', jsonEncode(_books.map((b) => b.toJson()).toList()));
    }
    await prefs.setString(
        'inkbloom_settings', jsonEncode(_settings.toJson()));
    // NOTE: stats are deliberately NOT written here. The
    // library's _stats is a snapshot from before the reader
    // opened; writing it would wipe the minutes the reader
    // just recorded (the "goal never moves" bug). The reader
    // owns 'inkbloom_stats' and writes it itself.
  }

  void _updateSettings(ReaderSettings s) {
    setState(() => _settings = s);
    _persist();
  }

  Future<void> _importFiles({bool multiple = true}) async {
    // Batch import, always: the picker lets you tick several
    // books at once (long-press / Select in the system picker).
    // The old single-file Import button is what made batch
    // import look broken — it now picks many too.
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: [
        'epub', 'pdf', 'txt', 'md', 'markdown', 'html', 'htm', 'fb2', 'rtf',
        'docx', 'odt'
      ],
    );
    if (files.isEmpty) return;
    // Instant import: no blocking dialog, no parsing here.
    // Books appear in the library right away; content parses
    // in the background. If a file cannot be read at all, it
    // is counted as failed with a reason, never silently lost.
    var added = 0;
    var failed = 0;
    var firstError = '';
    try {
      final dir = await _booksDir();
      final covers = await _coversDir();
      for (var i = 0; i < files.length; i++) {
        final f = files[i];
        Uint8List bytes;
        try {
          bytes = await readPickedFile(f);
        } catch (e) {
          failed++;
          if (firstError.isEmpty) firstError = e.toString();
          continue;
        }
        if (bytes.isEmpty) {
          failed++;
          if (firstError.isEmpty) {
            firstError = 'No data could be read from ${f.name}';
          }
          continue;
        }
        final lowerName = f.name.toLowerCase();
        if (lowerName.endsWith('.mobi') ||
            lowerName.endsWith('.azw') ||
            lowerName.endsWith('.azw3') ||
            lowerName.endsWith('.azw4')) {
          failed++;
          if (firstError.isEmpty) {
            firstError =
                'MOBI/AZW are Amazon formats and are not supported. Convert that book to EPUB first, then import it.';
          }
          continue;
        }
        _importDuplicate = null;
        final ok = await _storeBookInstant(f.name, bytes, dir, covers, i);
        if (ok != null) {
          added++;
        } else {
          failed++;
          if (firstError.isEmpty) {
            firstError = _importDuplicate != null
                ? '$_importDuplicate already exists in your library'
                : 'Could not save ${f.name}';
          }
        }
      }
    } catch (e) {
      if (firstError.isEmpty) firstError = e.toString();
    }
    await _persist();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(failed == 0
              ? 'Added $added book${added == 1 ? '' : 's'} — tap one to read, content loads in the background'
              : firstError.isEmpty
                  ? 'Added $added, $failed could not be saved'
                  : 'Added $added, $failed could not be saved. Reason: $firstError'),
          duration: const Duration(seconds: 6)));
    }
  }

  String _cleanTitle(String name) {
    final base = name.split('/').last;
    final dot = base.lastIndexOf('.');
    final n = dot > 0 ? base.substring(0, dot) : base;
    final cleaned = n.replaceAll(RegExp(r'[-_]+'), ' ').trim();
    return cleaned.isEmpty ? 'Untitled Book' : cleaned;
  }

  /// INSTANT import: writes the file and shows the book in the
  /// library immediately — no parsing, no waiting. Parsing runs
  /// afterwards in a background isolate (see _parseInBackground).
  /// This is what makes import take seconds, not minutes: the
  /// old code parsed every book before showing anything, so one
  /// big PDF froze the whole import. Returns the new book id.
  String? _importDuplicate;

  Future<String?> _storeBookInstant(String name, Uint8List bytes,
      Directory dir, Directory covers, int index) async {
    try {
      final ext = name.split('/').last.split('.').last.toLowerCase();
      // Neat-style duplicate guard: importing the same book
      // twice used to silently double it. Now it is skipped
      // with a plain "already exists" message instead.
      final clean = _cleanTitle(name).toLowerCase();
      if (_books.any((b) =>
          b.title.toLowerCase() == clean && b.format == ext)) {
        _importDuplicate = _cleanTitle(name);
        return null;
      }
      final id = 'book-${DateTime.now().microsecondsSinceEpoch}-$index';
      final file = File('${dir.path}/$id.$ext');
      await file.writeAsBytes(bytes);
      // PDFs show the EXACT imported name (see parsePdfBytes);
      // other formats keep the cleaned title as before.
      final instantTitle = ext == 'pdf'
          ? BookParser.fileTitleExact(name)
          : _cleanTitle(name);
      final book = LibraryBook(
        id: id,
        title: instantTitle,
        author: 'Unknown Author',
        format: ext,
        filePath: file.path,
        originalName: name,
        chapters: const [],
        addedAt: DateTime.now(),
      );
      if (mounted) {
        setState(() => _books.insert(0, book));
      } else {
        _books.insert(0, book);
      }
      // Save RIGHT NOW, not only at the end of the import
      // loop: closing the app mid-import used to lose every
      // book inserted so far, because nothing had persisted
      // them yet. (Guarded: before _load finishes this skips
      // the library write, and _load merges these books in.)
      await _persist();
      // Parse in the background, without blocking the UI.
      // ignore: unawaited_futures
      _parseInBackground(id, name, bytes, covers);
      return id;
    } catch (_) {
      return null;
    }
  }

  Future<void> _parseInBackground(String id, String name, Uint8List bytes,
      Directory covers) async {
    try {
      final parsed = parsedBookFromIsolate(
        await compute(parseBookIsolate, {'name': name, 'bytes': bytes})
            .timeout(const Duration(seconds: 300)),
      );
      String? coverPath;
      if (parsed.coverBytes != null) {
        final cf = File('${covers.path}/$id.cover');
        await cf.writeAsBytes(parsed.coverBytes!);
        coverPath = cf.path;
      }
      if (!mounted) return;
      final i = _books.indexWhere((b) => b.id == id);
      if (i < 0) return;
      final old = _books[i];
      setState(() {
        _books[i] = LibraryBook(
          id: old.id,
          title: parsed.title,
          author: parsed.author,
          format: parsed.format,
          filePath: old.filePath,
          originalName: old.originalName ?? name,
          coverPath: coverPath ?? old.coverPath,
          chapters: parsed.chapters,
          progress: old.progress,
          lastChapter: old.lastChapter,
          lastParagraph: old.lastParagraph,
          bookmarks: old.bookmarks,
          highlights: old.highlights,
          shelf: old.shelf,
          isFavourite: old.isFavourite,
          tags: old.tags,
          addedAt: old.addedAt,
        );
      });
      await _persist();
      // Cache the background parse too, so the first open
      // after import is instant even for a big PDF.
      if (old.filePath != null) {
        await BookCache.write(await _booksDir(), id, parsed.chapters,
            File(old.filePath!));
      }
    } catch (_) {
      // Chapter parsing failed, but the book is NOT lost — and
      // it should still get its real cover. Try cover-only:
      // most "no cover, won't open" EPUBs have a perfectly
      // good cover image even when their text is unusual.
      try {
        final cover = await compute(
                coverBookIsolate, {'name': name, 'bytes': bytes})
            .timeout(const Duration(seconds: 60));
        final coverBytes = cover['cover'] as Uint8List?;
        if (coverBytes != null && mounted) {
          final cf = File('${covers.path}/$id.cover');
          await cf.writeAsBytes(coverBytes);
          final i = _books.indexWhere((b) => b.id == id);
          if (i >= 0) {
            setState(() {
              _books[i] = _books[i].copyWith(coverPath: cf.path);
            });
            await _persist();
          }
        }
      } catch (_) {}
      // Book stays in the library with its file name as title.
      // Opening it retries the parse and shows the real reason
      // if it fails again — the book is never silently lost.
    }
  }
  /// "Find books on my phone" — the user picks ONE folder (for
  /// example Downloads or a Books folder) and InkBloom imports
  /// every supported book in it by itself. Nothing is forced:
  /// the user chooses the folder, and can still pick single
  /// files with Import book instead.
  Future<void> _findBooksOnPhone() async {
    final dirPath = await FilePicker.getDirectoryPath(
      dialogTitle: 'Choose a folder with books',
    );
    if (dirPath == null) return;
    const exts = {
      'epub', 'pdf', 'txt', 'md', 'markdown', 'html', 'htm', 'fb2', 'rtf',
      'docx', 'odt'
    };
    final found = <File>[];
    try {
      await for (final e in Directory(dirPath).list(
          recursive: true, followLinks: false)) {
        if (e is File &&
            exts.contains(e.path.split('.').last.toLowerCase())) {
          found.add(e);
          if (found.length >= 200) break;
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Could not read that folder ($e). Try another folder, or tap Import book to pick files directly.'),
            duration: const Duration(seconds: 6)));
      }
      return;
    }
    if (found.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'No books found in that folder. Try another folder, or tap Import book to pick files directly.')));
      }
      return;
    }
    var added = 0;
    var failed = 0;
    var firstError = '';
    try {
      final dir = await _booksDir();
      final covers = await _coversDir();
      for (var i = 0; i < found.length; i++) {
        final f = found[i];
        try {
          final bytes = await f.readAsBytes();
          _importDuplicate = null;
          if (await _storeBookInstant(
                  f.path.split('/').last, bytes, dir, covers, i) !=
              null) {
            added++;
          } else {
            failed++;
            if (firstError.isEmpty && _importDuplicate != null) {
              firstError =
                  '$_importDuplicate already exists in your library';
            }
          }
        } catch (e) {
          failed++;
          if (firstError.isEmpty) firstError = e.toString();
        }
      }
    } catch (e) {
      if (firstError.isEmpty) firstError = e.toString();
    }
    await _persist();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(failed == 0
              ? 'Found and added $added book${added == 1 ? '' : 's'} from your phone — tap one to read'
              : 'Added $added, $failed could not be saved${firstError.isEmpty ? '' : '. Reason: $firstError'}'),
          duration: const Duration(seconds: 6)));
    }
  }

  Future<void> _setCover(LibraryBook book) async {
    final picked = await FilePicker.pickFile(type: FileType.image);
    if (picked == null) return;
    final covers = await _coversDir();
    final file = File('${covers.path}/${book.id}.cover');
    await file.writeAsBytes(await readPickedFile(picked));
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
    // Fast path: a previous parse is cached on disk (see
    // BookCache). A big PDF then opens in milliseconds instead
    // of re-running the whole extraction every time.
    if (book.chapters.isEmpty && !book.isBuiltin && book.filePath != null) {
      final cached = await BookCache.read(
          await _booksDir(), book.id, File(book.filePath!));
      if (cached != null && cached.isNotEmpty) {
        final withCached =
            book.copyWith(chapters: cached, lastReadAt: DateTime.now());
        setState(() {
          final i = _books.indexWhere((b) => b.id == book.id);
          if (i >= 0) _books[i] = withCached;
        });
        book = withCached;
        _persist();
      }
    }
    // Lazy parse: a saved imported book has no chapters in memory
    // until it is opened. Parse here, with a real error if it fails,
    // instead of opening an empty reader or dropping the book.
    if (book.chapters.isEmpty && !book.isBuiltin && book.filePath != null) {
      if (!mounted) return;
      // Cancellable: the old dialog trapped the user for the
      // full 2-minute timeout with no way out. Cancel now
      // just closes the dialog; the parse finishing later is
      // ignored, and tapping the book again retries.
      var openCancelled = false;
      showDialog(
        context: context,
        barrierDismissible: true,
        builder: (ctx) => AlertDialog(
          content: const Row(children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Expanded(child: Text('Opening your book…')),
          ]),
          actions: [
            TextButton(
              onPressed: () {
                openCancelled = true;
                Navigator.pop(ctx);
              },
              child: const Text('Cancel'),
            ),
          ],
        ),
      ).then((_) => openCancelled = true);
      try {
        // Original imported name when we have it; the stored
        // file itself lives under an internal id name.
        final name =
            book.originalName ?? book.filePath!.split('/').last;
        final bytes = await File(book.filePath!).readAsBytes();
        final parsed = parsedBookFromIsolate(
          await compute(parseBookIsolate, {'name': name, 'bytes': bytes})
              .timeout(const Duration(seconds: 300)),
        );
        if (openCancelled) return;
        String? coverPath = book.coverPath;
        if (parsed.coverBytes != null && coverPath == null) {
          final covers = await _coversDir();
          final cf = File('${covers.path}/${book.id}.cover');
          await cf.writeAsBytes(parsed.coverBytes!);
          coverPath = cf.path;
        }
        // For a PDF without a stored original name (imported
        // before originalName existed), the fresh parse title
        // would be the internal id name — keep the saved title
        // instead. With an original name, parsed.title is its
        // exact stem, which is what the user wants to see.
        final lazyTitle =
            (parsed.format == 'pdf' && book.originalName == null)
                ? book.title
                : parsed.title;
        final lazyAuthor = book.author != 'Unknown Author'
            ? book.author
            : parsed.author;
        final withChapters = LibraryBook(
          id: book.id,
          title: lazyTitle,
          author: lazyAuthor,
          format: parsed.format,
          filePath: book.filePath,
          originalName: book.originalName,
          coverPath: coverPath,
          chapters: parsed.chapters,
          progress: book.progress,
          lastChapter: book.lastChapter,
          lastParagraph: book.lastParagraph,
          bookmarks: book.bookmarks,
          highlights: book.highlights,
          shelf: book.shelf,
          isFavourite: book.isFavourite,
          tags: book.tags,
          addedAt: book.addedAt,
          lastReadAt: DateTime.now(),
        );
        setState(() {
          final i = _books.indexWhere((b) => b.id == book.id);
          if (i >= 0) _books[i] = withChapters;
        });
        book = withChapters;
        _persist();
        // Cache this parse so the next open is instant.
        final cacheDir = await _booksDir();
        // ignore: unawaited_futures
        BookCache.write(cacheDir, book.id, parsed.chapters,
            File(book.filePath!));
      } catch (e) {
        if (openCancelled) return;
        if (mounted) Navigator.pop(context);
        if (mounted) {
          await showDialog(
            context: context,
            builder: (_) => AlertDialog(
              title: const Text('Could not open this book'),
              content: Text(
                  'The file may have been moved or deleted, or it may be in a format InkBloom cannot read yet. If it opens in another reader, it is almost certainly a format InkBloom parses badly — please tell us the file type and we will fix that format.\n\nReason: $e'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('OK')),
                FilledButton(
                    onPressed: () {
                      Navigator.pop(context);
                      _openBook(book);
                    },
                    child: const Text('Try again')),
              ],
            ),
          );
        }
        return;
      }
      if (!openCancelled && mounted) Navigator.pop(context);
    }
    // Opening a book counts as reading history, even if its
    // chapters were already parsed on a previous open.
    final opened = book.copyWith(lastReadAt: DateTime.now());
    if (opened != book) {
      setState(() {
        final i = _books.indexWhere((b) => b.id == book.id);
        if (i >= 0) _books[i] = opened;
      });
      _persist();
      book = opened;
    }
    // Books parsed before originalName existed (or before
    // PDF covers) get fixed here, on open, without a
    // re-import: exact PDF title + a cover refresh if the
    // book has none. The cover fetch runs in the background
    // and never blocks opening the book.
    if (book.format == 'pdf') {
      if (book.originalName != null) {
        final exact = BookParser.fileTitleExact(book.originalName!);
        if (exact != book.title) {
          book = book.copyWith(title: exact);
          setState(() {
            final i = _books.indexWhere((b) => b.id == book.id);
            if (i >= 0) _books[i] = book;
          });
          _persist();
        }
      }
      final coverMissing = book.coverPath == null ||
          !File(book.coverPath!).existsSync();
      if (coverMissing && book.filePath != null) {
        // ignore: unawaited_futures
        _refreshPdfCover(book);
      }
    }
    if (book.shelf == 'To Read') {
      final moved = book.copyWith(shelf: 'Reading');
      setState(() {
        final i = _books.indexWhere((b) => b.id == book.id);
        if (i >= 0) _books[i] = moved;
      });
      _persist();
      book = moved;
    }
    final readStart = DateTime.now();
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
    // Refresh stats FIRST, before _updateBook persists the
    // library: the reader recorded minutes while you read, and
    // the library must not persist its stale snapshot over them.
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _stats =
            ReadingStats.fromJsonString(prefs.getString('inkbloom_stats'));
      });
    }
    if (updated != null) _updateBook(updated);
    // Support / share / review prompts: only after a real
    // read (5+ minutes in this book), at most one per day,
    // never twice after "Don't show again". Never on open,
    // never mid-read, never annoying.
    final readSeconds = DateTime.now().difference(readStart).inSeconds;
    if (readSeconds >= 300 && mounted) {
      await _maybeShowClosePopup();
    }
  }

  /// Fetch a missing PDF cover in the background (books
  /// imported before PDF covers existed never got one, and
  /// opening them never refreshed it — so they showed the
  /// generated letter cover forever).
  Future<void> _refreshPdfCover(LibraryBook book) async {
    try {
      if (book.filePath == null) return;
      final bytes = await File(book.filePath!).readAsBytes();
      final name = book.originalName ?? book.filePath!.split('/').last;
      final cover = await compute(
              coverBookIsolate, {'name': name, 'bytes': bytes})
          .timeout(const Duration(seconds: 120));
      final coverBytes = cover['cover'] as Uint8List?;
      if (coverBytes == null || !mounted) return;
      final covers = await _coversDir();
      final cf = File('${covers.path}/${book.id}.cover');
      await cf.writeAsBytes(coverBytes);
      final i = _books.indexWhere((b) => b.id == book.id);
      if (i < 0) return;
      setState(() {
        _books[i] = _books[i].copyWith(coverPath: cf.path);
      });
      await _persist();
    } catch (_) {}
  }

  Future<void> _maybeShowClosePopup() async {
    final prefs = await SharedPreferences.getInstance();
    final today = DateTime.now().toIso8601String().substring(0, 10);
    if (prefs.getString('inkbloom_popup_last_date') == today) return;
    var closes = prefs.getInt('inkbloom_popup_close_count') ?? 0;
    closes++;
    await prefs.setInt('inkbloom_popup_close_count', closes);
    if (!(prefs.getBool('inkbloom_popup_dont_support') ?? false)) {
      await prefs.setString('inkbloom_popup_last_date', today);
      if (!mounted) return;
      final action = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Enjoying InkBloom?'),
          content: const Text(
              'If this app makes reading better for you, a small tip keeps it growing. Totally optional — and it unlocks nothing, it is just a thank-you.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, 'coffee'),
                child: const Text('Buy me a coffee')),
            TextButton(
                onPressed: () => Navigator.pop(context, 'headphone'),
                child: const Text('Buy me a headphone')),
            TextButton(
                onPressed: () => Navigator.pop(context, 'later'),
                child: const Text('Not now')),
            TextButton(
                onPressed: () => Navigator.pop(context, 'never'),
                child: const Text("Don't show again")),
          ],
        ),
      );
      if (action == 'never') {
        await prefs.setBool('inkbloom_popup_dont_support', true);
      } else if (action == 'coffee' || action == 'headphone') {
        if (mounted) {
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const SupportScreen()),
          );
        }
      }
      return;
    }
    if (!(prefs.getBool('inkbloom_popup_dont_share') ?? false) &&
        closes % 3 == 0) {
      await prefs.setString('inkbloom_popup_last_date', today);
      if (!mounted) return;
      final action = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Tell a reader?'),
          content: const Text(
              'If InkBloom is earning its place on your phone, sharing it with one friend — or a quick rating — helps more than you would think.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, 'share'),
                child: const Text('Share InkBloom')),
            TextButton(
                onPressed: () => Navigator.pop(context, 'rate'),
                child: const Text('Rate on Play Store')),
            TextButton(
                onPressed: () => Navigator.pop(context, 'later'),
                child: const Text('Not now')),
            TextButton(
                onPressed: () => Navigator.pop(context, 'never'),
                child: const Text("Don't show again")),
          ],
        ),
      );
      if (action == 'never') {
        await prefs.setBool('inkbloom_popup_dont_share', true);
      } else if (action == 'share') {
        await shareApp();
      } else if (action == 'rate') {
        await reviewApp();
      }
    }
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

  Future<void> _pickLanguage() async {
    final lang = AppLang.fromCode(_settings.languageCode);
    final chosen = await showDialog<String>(
      context: context,
      builder: (_) => SimpleDialog(
        title: Text(lang.t('chooseLanguage')),
        children: AppLang.all
            .map((l) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, l.code),
                  child: Text(
                      '${l.nativeName}${l.code == _settings.languageCode ? ' ✓' : ''}'),
                ))
            .toList(),
      ),
    );
    if (chosen != null) {
      _updateSettings(_settings.copyWith(languageCode: chosen));
    }
  }

  Future<void> _openSettings() async {
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
  }

  @override
  Widget build(BuildContext context) {
    final lang = AppLang.fromCode(_settings.languageCode);
    return Directionality(
      textDirection: lang.rtl ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
      appBar: AppBar(
        title: Row(children: [
          const InkBloomLogo(size: 28),
          const SizedBox(width: 8),
          Flexible(
            child: const Text('Ink Bloom',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 18)),
          ),
        ]),
        actions: [
          IconButton(
            icon: const Icon(Icons.language),
            tooltip: lang.t('language'),
            onPressed: _pickLanguage,
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings & transfer',
            onPressed: _openSettings,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            tooltip: 'More',
            onSelected: (v) async {
              if (v == 'grid') {
                setState(() => _grid = !_grid);
              } else if (v.startsWith('sort:')) {
                setState(() => _sort = v.substring(5));
              } else if (v == 'dictionary') {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const DictionaryScreen()),
                );
              } else if (v == 'support') {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const SupportScreen()),
                );
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'grid', child: Text('Grid / list view')),
              PopupMenuItem(value: 'sort:Recent', child: Text('Sort: Recent')),
              PopupMenuItem(value: 'sort:Title', child: Text('Sort: Title')),
              PopupMenuItem(value: 'sort:Author', child: Text('Sort: Author')),
              PopupMenuItem(
                  value: 'dictionary', child: Text('Dictionary (offline)')),
              PopupMenuItem(value: 'support', child: Text('Support')),
            ],
          ),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed,
        currentIndex: 0,
        selectedItemColor: terracotta,
        unselectedItemColor: forest,
        onTap: (i) {
          if (i == 0) {
            Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => BooksScreen(
                      getBooks: () => _books,
                      onOpen: _openBook,
                      onFavourite: (b) => _updateBook(
                          b.copyWith(isFavourite: !b.isFavourite)),
                      onAdd: () => _importFiles(multiple: true))),
            );
          } else if (i == 1) {
            Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => HistoryScreen(
                      getBooks: () => _books, onOpen: _openBook)),
            );
          } else if (i == 2) {
            _findBooksOnPhone();
          } else if (i == 3) {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const DictionaryScreen()),
            );
          } else if (i == 4) {
            Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => StatsScreen(
                      settings: _settings,
                      stats: _stats,
                      onSettingsChanged: _updateSettings)),
            );
          } else if (i == 5) {
            _openSettings();
          }
        },
        items: [
          BottomNavigationBarItem(
              icon: const Icon(Icons.menu_book), label: lang.t('books')),
          BottomNavigationBarItem(
              icon: const Icon(Icons.history), label: 'History'),
          BottomNavigationBarItem(
              icon: const Icon(Icons.search), label: lang.t('find')),
          BottomNavigationBarItem(
              icon: const Icon(Icons.book), label: lang.t('dictionary')),
          BottomNavigationBarItem(
              icon: const Icon(Icons.bar_chart), label: lang.t('goals')),
          BottomNavigationBarItem(
              icon: const Icon(Icons.settings), label: lang.t('settings')),
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
            label: Text(lang.t('importBook')),
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                CircularProgressIndicator(),
                SizedBox(height: 12),
                Text('Opening your library…'),
              ]))
          // Books fill the screen: the whole library scrolls as
          // one page, so the header scrolls away and the grid
          // gets the full screen instead of a squeezed strip at
          // the bottom (user complaint 2026-10-21).
          : CustomScrollView(
              keyboardDismissBehavior:
                  ScrollViewKeyboardDismissBehavior.onDrag,
              slivers: [
              SliverToBoxAdapter(
                child: Column(children: [
              // ── Stitch reference: "Warm Paper Editorial" library ──
              // 1. One-tap Add a Book banner, 2. Currently Reading hero,
              // 3. Quick tools. Anyone should understand the app in
              //    one glance: add a book, resume reading, or use a tool.
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: InkWell(
                  onTap: () => _importFiles(multiple: true),
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: terracotta,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(children: [
                      const Icon(Icons.add_circle,
                          color: Colors.white, size: 36),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(lang.t('importBook'),
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold)),
                            const Text(
                              'EPUB, PDF, DOCX, ODT, TXT and more — ready in seconds',
                              style: TextStyle(color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.arrow_forward_ios,
                          color: Colors.white, size: 18),
                    ]),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _findBooksOnPhone,
                    icon: const Icon(Icons.search),
                    label: const Text(
                        'Or find books already on my phone — you pick the folder, it imports them'),
                  ),
                ),
              ),
              if (_books.any((b) => b.progress > 0)) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Builder(builder: (_) {
                    final current = _books.firstWhere((b) => b.progress > 0);
                    return Card(
                      color: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(children: [
                          coverWidget(current, width: 62, height: 88),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Currently reading',
                                    style: TextStyle(
                                        color: terracotta,
                                        fontWeight: FontWeight.bold)),
                                Text(current.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontSize: 17,
                                        fontWeight: FontWeight.bold)),
                                Text(current.author,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                const SizedBox(height: 6),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: LinearProgressIndicator(
                                    value: current.progress.clamp(0.0, 1.0),
                                    color: terracotta,
                                    backgroundColor: sage.withValues(alpha: 0.4),
                                    minHeight: 6,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                FilledButton(
                                  onPressed: () => _openBook(current),
                                  child: Text(lang.t('continueReading')),
                                ),
                              ],
                            ),
                          ),
                        ]),
                      ),
                    );
                  }),
                ),
              ],
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Row(children: [
                  Expanded(
                    child: _ToolCard(
                      icon: Icons.book,
                      label: lang.t('dictionary'),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const DictionaryScreen()),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ToolCard(
                      icon: Icons.search,
                      label: 'Find books',
                      onTap: _findBooksOnPhone,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ToolCard(
                      icon: Icons.phone_android,
                      label: 'New phone',
                      onTap: _openSettings,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ToolCard(
                      icon: Icons.language,
                      label: lang.t('language'),
                      onTap: _pickLanguage,
                    ),
                  ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: TextField(
                  focusNode: _searchFocus,
                  autofocus: false,
                  onTapOutside: (_) => _searchFocus.unfocus(),
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    hintText: lang.t('searchHint'),
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
                      '${_books.length} books • ${_books.where((b) => b.progress > 0).length} in progress • EPUB, PDF, DOCX, ODT, TXT, MD, HTML, FB2, RTF',
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
                    final label = switch (s) {
                      'All' => lang.t('all'),
                      'Favourites' => lang.t('favourites'),
                      'To Read' => lang.t('toRead'),
                      'Reading' => lang.t('reading'),
                      'Finished' => lang.t('finished'),
                      _ => s,
                    };
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(label),
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
                ]),
              ),
              _visible.isEmpty
                  ? SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.menu_book,
                                  size: 64, color: forest),
                              const SizedBox(height: 16),
                              Text(
                                _books.isEmpty
                                    ? lang.t('noBooksYet')
                                    : lang.t('noBooksMatch'),
                                style: const TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.bold,
                                    color: forest),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                _books.isEmpty
                                    ? lang.t('importHelp')
                                    : lang.t('showAllBooks'),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 20),
                              if (_books.isEmpty)
                                FilledButton.icon(
                                  onPressed: () =>
                                      _importFiles(multiple: true),
                                  icon: const Icon(Icons.add),
                                  label: Text(lang.t('importBook')),
                                )
                              else
                                OutlinedButton(
                                  onPressed: () => setState(() {
                                    _query = '';
                                    _shelfFilter = 'All';
                                  }),
                                  child: const Text('Show all books'),
                                ),
                            ],
                          ),
                        ),
                      ))
                    : _grid
                        ? SliverPadding(
                            padding: const EdgeInsets.fromLTRB(
                                16, 8, 16, 180),
                            sliver: SliverGrid.builder(
                              // NOTE: do NOT use LayoutBuilder here.
                              // SliverPadding's child must be a sliver;
                              // a LayoutBuilder (a box widget) crashed
                              // the whole library into a grey screen
                              // in v1.0.8. Column count comes from
                              // MediaQuery width instead.
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount:
                                    MediaQuery.sizeOf(context).width < 600
                                        ? 2
                                        : MediaQuery.sizeOf(context).width <
                                                900
                                            ? 3
                                            : 4,
                                childAspectRatio: 0.62,
                                crossAxisSpacing: 12,
                                mainAxisSpacing: 12,
                              ),
                              itemCount: _visible.length,
                              itemBuilder: (_, i) =>
                                  _gridCard(_visible[i]),
                            ),
                          )
                        : SliverPadding(
                            padding: const EdgeInsets.fromLTRB(
                                16, 8, 16, 180),
                            sliver: SliverList.builder(
                              itemCount: _visible.length,
                              itemBuilder: (_, i) =>
                                  _listCard(_visible[i]),
                            ),
                          ),
            ]),
      ),
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
      // The cache is regenerable; leaving it would orphan
      // megabytes per deleted book.
      // ignore: unawaited_futures
      _booksDir().then((dir) => BookCache.delete(dir, book.id));
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
    return Squishy(
      onTap: () => _openBook(book),
      child: Card(
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
    ));
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
    final lang = AppLang.fromCode(settings.languageCode);
    return Scaffold(
      appBar: AppBar(title: Text(lang.t('settings'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Your navigation, your way',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          const SizedBox(height: 4),
          const Text(
              'These are the defaults for every book. You can still change them inside any book. Every switch and button here actually works and saves.'),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => ReaderPreferencesScreen(
                      settings: settings,
                      onSettingsChanged: onSettingsChanged)),
            ),
            icon: const Icon(Icons.tune),
            label: const Text(
                'Reader preferences — text, theme, voice, navigation'),
          ),
          const SizedBox(height: 8),
          ListTile(
            leading: const Icon(Icons.language),
            title: Text(lang.t('language')),
            subtitle: Text(AppLang.fromCode(settings.languageCode).nativeName),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final chosen = await showDialog<String>(
                context: context,
                builder: (_) => SimpleDialog(
                  title: Text(lang.t('chooseLanguage')),
                  children: AppLang.all
                      .map((l) => SimpleDialogOption(
                            onPressed: () => Navigator.pop(context, l.code),
                            child: Text(
                                '${l.nativeName}${l.code == settings.languageCode ? ' ✓' : ''}'),
                          ))
                      .toList(),
                ),
              );
              if (chosen != null) {
                onSettingsChanged(settings.copyWith(languageCode: chosen));
              }
            },
          ),
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
                    await readPickedFile(picked));
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
                subtitle: const Text('Use the sliders below to change the hours.'),
              ),
              _sliderTile('Night starts (hour)',
                  settings.nightStartHour.toDouble(), 0, 23,
                  (v) => onSettingsChanged(
                      settings.copyWith(nightStartHour: v.round()))),
              _sliderTile('Night ends (hour)',
                  settings.nightEndHour.toDouble(), 0, 23,
                  (v) => onSettingsChanged(
                      settings.copyWith(nightEndHour: v.round()))),
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text('Colour themes — tap one to use it',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: readerThemes.asMap().entries.map((e) {
                  final sel = settings.themeIndex == e.key;
                  return GestureDetector(
                    onTap: () => onSettingsChanged(
                        settings.copyWith(themeIndex: e.key)),
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
            ],
          ),
          ExpansionTile(
            title: const Text('Read aloud'),
            children: [
              ListTile(
                title: Text(
                    'Speech speed ${settings.ttsRate.toStringAsFixed(1)}× • pitch ${settings.ttsPitch.toStringAsFixed(1)}'),
                subtitle: Text(settings.ttsVoiceName.isEmpty
                    ? 'Voice: device default'
                    : 'Voice: ${settings.ttsVoiceName}'),
              ),
              _sliderTile('Speech speed', settings.ttsRate, 0.3, 1.5,
                  (v) => onSettingsChanged(settings.copyWith(ttsRate: v))),
              _sliderTile('Speech pitch', settings.ttsPitch, 0.5, 2.0,
                  (v) => onSettingsChanged(settings.copyWith(ttsPitch: v))),
              TextButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => ReaderPreferencesScreen(
                          settings: settings,
                          onSettingsChanged: onSettingsChanged)),
                ),
                icon: const Icon(Icons.record_voice_over),
                label: const Text('Choose a voice & test it'),
              ),
            ],
          ),
          ExpansionTile(
            title: const Text('Stats & goals'),
            children: [
              _sliderTile('Daily goal (minutes)',
                  settings.goalMinutes.toDouble(), 5, 120,
                  (v) => onSettingsChanged(
                      settings.copyWith(goalMinutes: v.round()))),
              TextButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => StatsScreen(
                          settings: settings,
                          stats: ReadingStats.fromJsonString(statsJson),
                          onSettingsChanged: onSettingsChanged)),
                ),
                icon: const Icon(Icons.bar_chart),
                label: const Text('Open goals & stats screen'),
              ),
              const ListTile(
                subtitle: Text('Streaks and totals are local only.'),
              ),
            ],
          ),
          ExpansionTile(
            title: const Text('Fonts'),
            children: [
              Wrap(
                spacing: 8,
                children: ['Serif', 'Sans', 'Mono'].asMap().entries.map((e) {
                  final sel = settings.fontIndex == e.key;
                  return ChoiceChip(
                    label: Text(e.value),
                    selected: sel,
                    onSelected: (_) => onSettingsChanged(
                        settings.copyWith(fontIndex: e.key)),
                  );
                }).toList(),
              ),
              Wrap(
                spacing: 8,
                children: settings.customFonts.asMap().entries.map((e) {
                  final sel = settings.fontIndex == 3 + e.key;
                  return ChoiceChip(
                    label: Text(e.value),
                    selected: sel,
                    onSelected: (_) => onSettingsChanged(
                        settings.copyWith(fontIndex: 3 + e.key)),
                  );
                }).toList(),
              ),
              TextButton.icon(
                onPressed: () async {
                  final picked = await FilePicker.pickFile(
                    type: FileType.custom,
                    allowedExtensions: ['ttf', 'otf'],
                  );
                  if (picked == null) return;
                  final family = await CustomFonts.importFont(
                      picked.name, await readPickedFile(picked));
                  if (family == null) return;
                  final fonts = [...settings.customFonts];
                  if (!fonts.contains(family)) fonts.add(family);
                  onSettingsChanged(settings.copyWith(
                      customFonts: fonts,
                      fontIndex: 3 + fonts.indexOf(family)));
                },
                icon: const Icon(Icons.font_download),
                label: const Text('Import your own font (.ttf / .otf)'),
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

  Widget _sliderTile(String label, double value, double min, double max,
      ValueChanged<double> onChanged) {
    return Row(children: [
      SizedBox(width: 150, child: Text(label)),
      Expanded(
        child: Slider(value: value, min: min, max: max, onChanged: onChanged),
      ),
      SizedBox(
          width: 44,
          child: Text(value.toStringAsFixed(value < 10 ? 1 : 0))),
    ]);
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

/// Small centred hint shown once, on the very first book
/// open, while the controls are hidden.
class _TapHint extends StatelessWidget {
  const _TapHint();
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(24),
      ),
      child: const Text('Tap the page to show controls',
          style: TextStyle(color: Colors.white, fontSize: 15)),
    );
  }
}

class _ReaderScreenState extends State<ReaderScreen> {
  late ReaderSettings _s;
  late int _chapter;
  late List<int> _bookmarks;
  late List<Highlight> _highlights;
  late bool _barsVisible;
  // NOTE: page lock was removed 2026-10-21 at the user's request:
  // Neat-style full screen has no lock pill, no lock notice,
  // and no big Controls button — tap the page to show/hide
  // controls, and nothing sits on the page while reading.
  String _searchTerm = '';
  List<SearchHit> _searchHits = [];
  int _searchHitIndex = 0;
  final Map<String, GlobalKey> _paraKeys = {};
  final Map<int, GlobalKey> _chapterKeys = {};
  bool _showTapHint = true;
  final _scroll = ScrollController();
  final _pageController = PageController();
  final _scaffoldKey = GlobalKey<ScaffoldState>();
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
    // Controls start HIDDEN: the page is clean on open, and
    // a single tap brings the bars, the -/+ pill and the
    // chapter bar up. Nothing sits on the text otherwise.
    _barsVisible = false;
    applyBrightness(_s.brightness);
    _chapter =
        widget.book.lastChapter.clamp(0, widget.book.chapters.length - 1);
    _bookmarks = [...widget.book.bookmarks];
    _highlights = [...widget.book.highlights];
    _applySystemUi();
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
      _showTapHint = !(prefs.getBool('inkbloom_tap_hint_shown') ?? false);
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
    if (_s.ttsVoiceName.isNotEmpty) {
      await _tts.setVoice({
        'name': _s.ttsVoiceName,
        'locale': _s.ttsVoiceLocale.isEmpty ? 'en-US' : _s.ttsVoiceLocale,
      });
    } else {
      await _tts.setLanguage('en-US');
    }
    // Pauses between paragraphs: joining with spaces made
    // even a slow speed feel like one breathless rush.
    final text =
        widget.book.chapters[_chapter].paragraphs.join('\n\n');
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
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
        overlays: SystemUiOverlay.values);
    resetBrightness();
    _tts.stop();
    _scroll.dispose();
    _pageController.dispose();
    super.dispose();
  }

  /// True immersive full screen while reading with bars hidden:
  /// status + navigation bars disappear (immersiveSticky), so
  /// Android's top bar and its notifications stop hanging over
  /// the page. Bars visible = normal edge-to-edge again.
  void _applySystemUi() {
    if (_barsVisible) {
      // Normal mode: system bars opaque, content padded above
      // them — the old edge-to-edge mode pushed the chapter
      // bar and the -/+ pill under the system navigation bar.
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
          overlays: SystemUiOverlay.values);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  void _setBarsVisible(bool v) {
    setState(() => _barsVisible = v);
    _applySystemUi();
  }

  void _setSettings(ReaderSettings s) {
    if (s.brightness != _s.brightness) {
      applyBrightness(s.brightness);
    }
    final voiceChanged = s.ttsRate != _s.ttsRate ||
        s.ttsPitch != _s.ttsPitch ||
        s.ttsVoiceName != _s.ttsVoiceName ||
        s.ttsVoiceLocale != _s.ttsVoiceLocale;
    setState(() => _s = s);
    widget.onSettingsChanged(s);
    if (voiceChanged && _isSpeaking) {
      // Apply the new voice/speed right away, not on the next chapter.
      _stopTts().then((_) => _speakChapter());
    }
  }

  void _jumpToHit(int idx) {
    if (_searchHits.isEmpty) return;
    final hit = _searchHits[idx.clamp(0, _searchHits.length - 1)];
    setState(() {
      _searchHitIndex = idx.clamp(0, _searchHits.length - 1);
      _chapter = hit.chapter;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final key = _paraKeys['${hit.chapter}:${hit.paragraph}'];
      final ctx = key?.currentContext;
      if (ctx != null) Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300));
    });
  }

  void _guarded(VoidCallback action) => action();

  void _go(int chapter) {
    if (chapter < 0 || chapter >= widget.book.chapters.length) return;
    setState(() {
      _chapter = chapter;
    });
    if (_s.readingMode == 0) {
      // Continuous scroll: jump to this chapter's heading.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final key = _chapterKeys[chapter];
        final ctx = key?.currentContext;
        if (ctx != null) Scrollable.ensureVisible(ctx,
            duration: const Duration(milliseconds: 300));
      });
      return;
    }
    if (_scroll.hasClients) _scroll.jumpTo(0);
    if (_pageController.hasClients) _pageController.jumpToPage(0);
  }

  /// In continuous scroll mode, the chapter shown in the bar
  /// follows the heading nearest the top of the screen.
  void _updateChapterFromScroll() {
    if (_s.readingMode != 0 || !_scroll.hasClients) return;
    var found = _chapter;
    for (var i = 0; i < widget.book.chapters.length; i++) {
      final ctx = _chapterKeys[i]?.currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final dy = box.localToGlobal(Offset.zero).dy;
      if (dy <= 140) found = i;
    }
    if (found != _chapter && mounted) setState(() => _chapter = found);
  }

  LibraryBook _bookToReturn() {
    final total = widget.book.chapters.length;
    double progress;
    if (_s.readingMode == 0 &&
        _scroll.hasClients &&
        _scroll.position.maxScrollExtent > 0) {
      progress = (_scroll.offset / _scroll.position.maxScrollExtent)
          .clamp(0.0, 1.0);
    } else {
      progress = total <= 1 ? 1.0 : _chapter / (total - 1);
    }
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
    return KeyedSubtree(
      key: _paraKeys.putIfAbsent('$chapterIdx:$paraIdx', () => GlobalKey()),
      child: GestureDetector(
      onLongPress: _s.enableHighlights
          ? () => _guarded(() => _highlightSheet(chapterIdx, paraIdx, hl, text))
          : null,
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
                      final term = controller.text;
                      Navigator.pop(context);
                      setState(() {
                        _searchTerm = term;
                        _searchHits = searchBook(widget.book, term);
                        _searchHitIndex = i;
                      });
                      _jumpToHit(i);
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
    // Continuous scroll (mode 0): the WHOLE book in one
    // list, chapter after chapter, so scrolling never stops
    // dead at the end of a short chapter. A "Next chapter"
    // button sits at each chapter's end for readers who
    // prefer jumping. (Mode 2, horizontal scroll, keeps the
    // old single-chapter list.)
    if (_s.readingMode == 0) {
      final all = <Widget>[];
      for (var ci = 0; ci < widget.book.chapters.length; ci++) {
        final ch = widget.book.chapters[ci];
        all.add(Text(ch.title,
            key: _chapterKeys.putIfAbsent(ci, () => GlobalKey()),
            style: TextStyle(
                color: theme.fg,
                fontSize: _s.fontSize + 6,
                fontWeight: FontWeight.bold,
                height: 1.3)));
        all.add(const SizedBox(height: 20));
        for (var pi = 0; pi < ch.paragraphs.length; pi++) {
          all.add(Padding(
            padding: EdgeInsets.only(bottom: _s.paragraphSpacing),
            child: _paragraphWidget(ci, pi, ch.paragraphs[pi]),
          ));
        }
        all.add(const SizedBox(height: 24));
        if (ci < widget.book.chapters.length - 1) {
          all.add(Center(
            child: FilledButton.icon(
              onPressed: () => _go(ci + 1),
              icon: const Icon(Icons.arrow_forward),
              label: Text(
                  'Next chapter: ${widget.book.chapters[ci + 1].title}'),
            ),
          ));
          all.add(const SizedBox(height: 24));
        } else {
          all.add(Center(
            child: Text('— End of book —',
                style: TextStyle(color: theme.fg.withValues(alpha: 0.6))),
          ));
        }
      }
      return NotificationListener<ScrollNotification>(
        onNotification: (_) {
          _updateChapterFromScroll();
          return false;
        },
        child: ListView(
          controller: _scroll,
          padding: EdgeInsets.all(_s.pageMargin),
          children: all,
        ),
      );
    }
    // Single-chapter list (horizontal scroll, mode 2).
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
    if (widget.book.chapters.isEmpty) {
      // Never a blank/black page: a book with no content yet gets
      // a clear message and a way back, instead of an empty screen.
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pop(context),
          ),
          title: Text(widget.book.title),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.menu_book, size: 64, color: forest),
              const SizedBox(height: 16),
              const Text('This book is not ready yet',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center),
              const SizedBox(height: 8),
              const Text(
                  'Its content is still loading in the background, or it could not be read. Go back and tap the book again — opening it will try again and tell you the real reason if it fails.',
                  textAlign: TextAlign.center),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Back to my books'),
              ),
            ]),
          ),
        ),
      );
    }
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
        if (_s.showSearchButton)
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => _guarded(_searchSheet),
            tooltip: 'Search in book',
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
        // ONE clear settings icon (tune), not a text-size icon:
        // this opens text, theme, voice, navigation — everything.
        IconButton(
          icon: const Icon(Icons.tune),
          onPressed: () => _guarded(_settingsSheet),
          tooltip: 'Reading settings — text, theme, voice, navigation',
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          tooltip: 'More',
          onSelected: (v) {
            if (v == 'chapters') {
              _guarded(() => _scaffoldKey.currentState?.openDrawer());
            } else if (v == 'notes') {
              _guarded(_notesSheet);
            } else if (v == 'bookmark') {
              _guarded(() {
                setState(() {
                  if (_bookmarks.contains(_chapter)) {
                    _bookmarks.remove(_chapter);
                  } else {
                    _bookmarks.add(_chapter);
                  }
                });
              });
            }
          },
          itemBuilder: (_) => [
            if (_s.showTocButton)
              const PopupMenuItem(value: 'chapters', child: Text('Chapters')),
            const PopupMenuItem(
                value: 'notes', child: Text('Highlights & notes')),
            PopupMenuItem(
                value: 'bookmark',
                child: Text(_bookmarks.contains(_chapter)
                    ? 'Remove bookmark'
                    : 'Bookmark this chapter')),
          ],
        ),
      ],
    );
    // Drawer needs a Scaffold context, so wrap the app bar actions that
    // open it in a Builder below; the list button above is replaced
    // by using a Builder in the body instead — see _drawerButton.
    return Scaffold(
      key: _scaffoldKey,
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
      bottomNavigationBar:
          (_s.showBottomBar && showBars && _s.navPosition == 0)
              ? _chapterBar()
              : null,
      // System back button must save progress too, not just the
      // AppBar back arrow: without this, closing a book with
      // the phone's back button popped with null and the
      // library kept showing "Not started".
      body: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) Navigator.pop(context, _bookToReturn());
        },
        child: Builder(
          builder: (scaffoldContext) => GestureDetector(
          onTap: _s.autoHideBars
              ? () async {
                  if (_showTapHint) {
                    setState(() => _showTapHint = false);
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setBool(
                        'inkbloom_tap_hint_shown', true);
                  }
                  _setBarsVisible(!_barsVisible);
                }
              : null,
          child: Stack(children: [
            Column(children: [
              if (_s.showBottomBar && showBars && _s.navPosition == 1)
                _chapterBar(),
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
                      vertical: 2, horizontal: 8),
                  child: Row(children: [
                    Expanded(
                        child: Text(
                            '"$_searchTerm" — ${_searchHitIndex + 1} of ${_searchHits.length} matches',
                            style: TextStyle(color: theme.fg),
                            overflow: TextOverflow.ellipsis)),
                    IconButton(
                      icon: const Icon(Icons.chevron_left),
                      color: theme.fg,
                      tooltip: 'Previous match',
                      onPressed: _searchHits.isEmpty
                          ? null
                          : () => _jumpToHit(_searchHitIndex - 1),
                    ),
                    IconButton(
                      icon: const Icon(Icons.chevron_right),
                      color: theme.fg,
                      tooltip: 'Next match',
                      onPressed: _searchHits.isEmpty
                          ? null
                          : () => _jumpToHit(_searchHitIndex + 1),
                    ),
                    IconButton(
                      icon: const Icon(Icons.list),
                      color: theme.fg,
                      tooltip: 'All matches',
                      onPressed: () => _guarded(_searchSheet),
                    ),
                    TextButton(
                      onPressed: () => setState(() {
                        _searchTerm = '';
                        _searchHits = [];
                      }),
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
            // First-run hint: the page starts clean, so tell
            // the reader once how to bring controls back.
            if (_showTapHint && !showBars)
              const IgnorePointer(
                child: Center(
                  child: _TapHint(),
                ),
              ),
            // Text size - / + buttons, Neat-style (user
            // reference, 2026-10-21): a small white pill in the
            // exact bottom-right corner, just above the bottom
            // bar — NOT floating 88px above it. The bottom bar
            // is the Scaffold's bottomNavigationBar, OUTSIDE
            // this Stack, so the Stack's own bottom edge is
            // already the bar's top edge: bottom 16 sits the
            // pill right on the bar. Only the floating pill
            // bar (navPosition 2) lives INSIDE this Stack, so
            // only it needs the 88px clearance.
            if (_s.showTextSizeButtons && showBars)
              Positioned(
                right: 16,
                bottom: (_s.showBottomBar && _s.navPosition == 2)
                    ? 88
                    : 16,
                child: Squishy(
                  child: Card(
                    elevation: 6,
                    color: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                        icon: const Icon(Icons.remove, color: forest),
                        tooltip: 'Smaller text',
                        onPressed: () => _guarded(() => _setSettings(
                            _s.copyWith(
                                fontSize: (_s.fontSize - 1).clamp(12.0, 32.0)))),
                      ),
                      Text('${_s.fontSize.round()}',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, color: forest)),
                      IconButton(
                        icon: const Icon(Icons.add, color: forest),
                        tooltip: 'Bigger text',
                        onPressed: () => _guarded(() => _setSettings(
                            _s.copyWith(
                                fontSize: (_s.fontSize + 1).clamp(12.0, 32.0)))),
                      ),
                    ]),
                  ),
                ),
              ),
            // Edge tap zones, when enabled: left edge = previous
            // chapter, right edge = next chapter. Kept clear of the
            // top/bottom bars so scrolling in the middle still works.
            if (_s.tapZones) ...[
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
          ]),
        ),
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
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => ReaderPreferencesScreen(
                              settings: _s,
                              onSettingsChanged: _setSettings)),
                    );
                  },
                  icon: const Icon(Icons.tune),
                  label: const Text(
                      'Open full Reader preferences — voices, navigation, everything'),
                ),
                const Text(
                    'Everything here also lives on the Reader preferences page, and applies to all books.',
                    style: TextStyle(color: Colors.grey)),
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
                        picked.name, await readPickedFile(picked));
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
                _sliderRow('Speech speed', _s.ttsRate, 0.3, 2.0,
                    (v) => update(_s.copyWith(ttsRate: v))),
                _sliderRow('Speech pitch', _s.ttsPitch, 0.5, 2.0,
                    (v) => update(_s.copyWith(ttsPitch: v))),
                const Text(
                    'Tap the speaker icon in the top bar to start or stop reading aloud. Speed and pitch apply right away, even while a chapter is playing.'),
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
                    'Scroll (top to bottom)',
                    'Paged swipe (left / right)',
                  ].asMap().entries.map((e) {
                    final sel = _s.readingMode == e.key;
                    return ChoiceChip(
                      label: Text(e.value),
                      selected: sel,
                      onSelected: (_) =>
                          update(_s.copyWith(readingMode: e.key)),
                    );
                  }).toList(),
                ),
                const Text(
                  'Scroll means the page moves up and down with your finger. Paged swipe means pages turn left and right. Pick one — the other one will not happen.',
                  style: TextStyle(color: Colors.grey),
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
                const Text('Text size buttons', style: TextStyle(fontWeight: FontWeight.bold)),
                SwitchListTile(
                    title: const Text('Show - / + text size buttons while reading'),
                    value: _s.showTextSizeButtons,
                    onChanged: (v) =>
                        update(_s.copyWith(showTextSizeButtons: v))),
                Row(children: [
                  IconButton(
                    icon: const Icon(Icons.remove),
                    onPressed: () => update(_s.copyWith(
                        fontSize: (_s.fontSize - 1).clamp(12.0, 32.0))),
                  ),
                  Text('Text size ${_s.fontSize.round()}',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  IconButton(
                    icon: const Icon(Icons.add),
                    onPressed: () => update(_s.copyWith(
                        fontSize: (_s.fontSize + 1).clamp(12.0, 32.0))),
                  ),
                ]),
                const Text('Highlights', style: TextStyle(fontWeight: FontWeight.bold)),
                SwitchListTile(
                    title: const Text('Highlights: long-press a paragraph to highlight it in colour and add a note'),
                    subtitle: const Text('Turn off if you do not want highlights at all — long-press will do nothing.'),
                    value: _s.enableHighlights,
                    onChanged: (v) =>
                        update(_s.copyWith(enableHighlights: v))),
                const Text('These settings apply to all books, not just this one.',
                    style: TextStyle(color: Colors.grey)),
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

// ── Reader Preferences — one page for EVERYTHING ──────────────────────
// The user asked for this explicitly: a Reader Preferences page where
// every reader setting lives, works, and applies to all books.
// It is reachable from Settings, from the reader's tune (⚙) sheet,
// and from the library. Every control here actually changes the
// setting and saves it (ReaderSettings.toJson now saves all fields).
class ReaderPreferencesScreen extends StatefulWidget {
  final ReaderSettings settings;
  final ValueChanged<ReaderSettings> onSettingsChanged;
  const ReaderPreferencesScreen(
      {super.key, required this.settings, required this.onSettingsChanged});
  @override
  State<ReaderPreferencesScreen> createState() =>
      _ReaderPreferencesScreenState();
}

class _ReaderPreferencesScreenState extends State<ReaderPreferencesScreen> {
  late ReaderSettings _s;
  final _tts = FlutterTts();
  List<Map<String, String>> _voices = [];
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    _s = widget.settings;
    _loadVoices();
  }

  @override
  void dispose() {
    _tts.stop();
    super.dispose();
  }

  Future<void> _loadVoices() async {
    try {
      final raw = await _tts.getVoices;
      final list = <Map<String, String>>[];
      for (final v in (raw as List? ?? [])) {
        if (v is Map) {
          list.add({
            'name': (v['name'] ?? '').toString(),
            'locale': (v['locale'] ?? '').toString(),
          });
        }
      }
      list.removeWhere((v) => v['name']!.isEmpty);
      list.sort((a, b) => (a['locale']! + a['name']!)
          .compareTo(b['locale']! + b['name']!));
      if (mounted) setState(() => _voices = list);
    } catch (_) {}
  }

  void _update(ReaderSettings s) {
    setState(() => _s = s);
    widget.onSettingsChanged(s);
  }

  Future<void> _testVoice() async {
    if (_testing) {
      await _tts.stop();
      if (mounted) setState(() => _testing = false);
      return;
    }
    await _tts.setSpeechRate(_s.ttsRate);
    await _tts.setPitch(_s.ttsPitch);
    if (_s.ttsVoiceName.isNotEmpty) {
      await _tts.setVoice({
        'name': _s.ttsVoiceName,
        'locale': _s.ttsVoiceLocale.isEmpty ? 'en-US' : _s.ttsVoiceLocale,
      });
    } else {
      await _tts.setLanguage('en-US');
    }
    await _tts.speak('Hello, this is InkBloom Reader. How does this voice sound?');
    if (mounted) setState(() => _testing = true);
    _tts.setCompletionHandler(() {
      if (mounted) setState(() => _testing = false);
    });
  }

  Widget _slider(String label, double value, double min, double max,
      ValueChanged<double> onChanged) {
    return Row(children: [
      SizedBox(width: 130, child: Text(label)),
      Expanded(
        child: Slider(
            value: value, min: min, max: max, onChanged: onChanged),
      ),
      SizedBox(
          width: 44,
          child: Text(value.toStringAsFixed(value < 10 ? 1 : 0))),
    ]);
  }

  Widget _switch(String title, String? subtitle, bool value,
      ValueChanged<bool> onChanged) {
    return SwitchListTile(
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle),
        value: value,
        onChanged: onChanged);
  }

  Widget _heading(String text) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 4),
        child: Text(text,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
      );

  @override
  Widget build(BuildContext context) {
    final lang = AppLang.fromCode(_s.languageCode);
    return Scaffold(
      appBar: AppBar(title: Text(lang.t('settings'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text(
            'These settings apply to ALL books, not just one. Change them here, or inside any book with the tune icon — it is the same setting, saved everywhere.'),
        _heading('Text size — with + and -'),
        Row(children: [
          IconButton(
            icon: const Icon(Icons.remove),
            onPressed: () => _update(
                _s.copyWith(fontSize: (_s.fontSize - 1).clamp(12.0, 32.0))),
          ),
          Text('Size ${_s.fontSize.round()}',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => _update(
                _s.copyWith(fontSize: (_s.fontSize + 1).clamp(12.0, 32.0))),
          ),
          const Expanded(
              child: Text('Tap - / + any time while reading, too.')),
        ]),
        _switch('Show - / + buttons while reading',
            'Turn off to hide the size buttons in the reader.',
            _s.showTextSizeButtons,
            (v) => _update(_s.copyWith(showTextSizeButtons: v))),
        _slider('Text size', _s.fontSize, 12, 32,
            (v) => _update(_s.copyWith(fontSize: v))),
        _slider('Line height', _s.lineHeight, 1.2, 2.2,
            (v) => _update(_s.copyWith(lineHeight: v))),
        _slider('Letter spacing', _s.letterSpacing, 0, 3,
            (v) => _update(_s.copyWith(letterSpacing: v))),
        _slider('Paragraph spacing', _s.paragraphSpacing, 4, 32,
            (v) => _update(_s.copyWith(paragraphSpacing: v))),
        _slider('Page margin', _s.pageMargin, 12, 40,
            (v) => _update(_s.copyWith(pageMargin: v))),
        _heading('Font'),
        Wrap(
          spacing: 8,
          children: ['Serif', 'Sans', 'Mono'].asMap().entries.map((e) {
            final sel = _s.fontIndex == e.key;
            return ChoiceChip(
              label: Text(e.value),
              selected: sel,
              onSelected: (_) => _update(_s.copyWith(fontIndex: e.key)),
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
                  _update(_s.copyWith(fontIndex: 3 + e.key)),
            );
          }).toList(),
        ),
        TextButton.icon(
          onPressed: () async {
            final picked = await FilePicker.pickFile(
              type: FileType.custom,
              allowedExtensions: ['ttf', 'otf'],
            );
            if (picked == null) return;
            final family = await CustomFonts.importFont(
                picked.name, await readPickedFile(picked));
            if (family == null) return;
            final fonts = [..._s.customFonts];
            if (!fonts.contains(family)) fonts.add(family);
            _update(_s.copyWith(
                customFonts: fonts, fontIndex: 3 + fonts.indexOf(family)));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Font "$family" imported')));
            }
          },
          icon: const Icon(Icons.font_download),
          label: const Text('Import your own font (.ttf / .otf)'),
        ),
        _heading('Colour themes & night'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: readerThemes.asMap().entries.map((e) {
            final sel = _s.themeIndex == e.key;
            return GestureDetector(
              onTap: () => _update(_s.copyWith(themeIndex: e.key)),
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
                      style: TextStyle(color: e.value.fg, fontSize: 10)),
                ),
              ),
            );
          }).toList(),
        ),
        _switch('Auto night theme by time of day',
            'Switches to the Midnight (dark) theme at night, back in the morning.',
            _s.autoNight, (v) => _update(_s.copyWith(autoNight: v))),
        _slider('Night starts (hour)', _s.nightStartHour.toDouble(), 0, 23,
            (v) => _update(_s.copyWith(nightStartHour: v.round()))),
        _slider('Night ends (hour)', _s.nightEndHour.toDouble(), 0, 23,
            (v) => _update(_s.copyWith(nightEndHour: v.round()))),
        _heading('Brightness'),
        const Text(
            'In-app only: this changes brightness inside InkBloom while you read. It never changes your phone\'s system brightness.'),
        _switch('Auto brightness',
            'Use your phone\'s brightness instead of a fixed level.',
            _s.brightness < 0,
            (v) => _update(_s.copyWith(
                brightness: v ? -1 : (_s.brightness < 0 ? 0.7 : _s.brightness)))),
        if (_s.brightness >= 0)
          _slider('Brightness', _s.brightness, 0.05, 1.0,
              (v) => _update(_s.copyWith(brightness: v))),
        if (_s.brightness >= 0)
          Text('${(_s.brightness * 100).round()}%',
              style: const TextStyle(fontWeight: FontWeight.bold)),
        _heading('Read aloud — voices & speed'),
        const Text(
            'Pick a voice below, then tap Test to hear it. The voice you pick is used in every book, and you can change it any time — while reading, or here. No robotic default is forced on you.'),
        if (_voices.isEmpty)
          const Text('Loading voices from your phone…')
        else
          DropdownButton<String>(
            isExpanded: true,
            value: _s.ttsVoiceName.isEmpty ? null : _s.ttsVoiceName,
            hint: const Text('Device default voice'),
            items: [
              const DropdownMenuItem<String>(
                  value: null, child: Text('Device default voice')),
              ..._voices.map((v) => DropdownMenuItem<String>(
                    value: v['name'],
                    child: Text('${v['name']} (${v['locale']})'),
                  )),
            ],
            onChanged: (name) {
              if (name == null) {
                _update(_s.copyWith(ttsVoiceName: '', ttsVoiceLocale: ''));
              } else {
                final v =
                    _voices.firstWhere((e) => e['name'] == name);
                _update(_s.copyWith(
                    ttsVoiceName: name, ttsVoiceLocale: v['locale'] ?? ''));
              }
            },
          ),
        Row(children: [
          FilledButton.icon(
            onPressed: _testVoice,
            icon: Icon(_testing ? Icons.stop : Icons.play_arrow),
            label: Text(_testing ? 'Stop test' : 'Test this voice'),
          ),
          const SizedBox(width: 12),
          const Expanded(
              child: Text('Speed is saved and locked for all books until you change it.')),
        ]),
        _slider('Speech speed', _s.ttsRate, 0.3, 1.5,
            (v) => _update(_s.copyWith(ttsRate: v))),
        _slider('Speech pitch', _s.ttsPitch, 0.5, 2.0,
            (v) => _update(_s.copyWith(ttsPitch: v))),
        _heading('How the book moves'),
        Wrap(
          spacing: 8,
          children: [
            'Scroll (top to bottom)',
            'Paged swipe (left / right)',
          ].asMap().entries.map((e) {
            final sel = _s.readingMode == e.key;
            return ChoiceChip(
              label: Text(e.value),
              selected: sel,
              onSelected: (_) => _update(_s.copyWith(readingMode: e.key)),
            );
          }).toList(),
        ),
        const Text(
            'Scroll means the page moves up and down with your finger. Paged swipe means pages turn left and right. Pick one — the other one will not happen.',
            style: TextStyle(color: Colors.grey)),
        _heading('Navigation — set it up your way'),
        _switch('Show top bar', null, _s.showTopBar,
            (v) => _update(_s.copyWith(showTopBar: v))),
        _switch('Show bottom chapter bar', null, _s.showBottomBar,
            (v) => _update(_s.copyWith(showBottomBar: v))),
        _switch('Show chapter slider', null, _s.showChapterSlider,
            (v) => _update(_s.copyWith(showChapterSlider: v))),
        _switch('Show prev / next buttons', null, _s.showPrevNext,
            (v) => _update(_s.copyWith(showPrevNext: v))),
        _switch('Show bookmark button', null, _s.showBookmarkButton,
            (v) => _update(_s.copyWith(showBookmarkButton: v))),
        _switch('Show search button', null, _s.showSearchButton,
            (v) => _update(_s.copyWith(showSearchButton: v))),
        _switch('Show chapter-list button', null, _s.showTocButton,
            (v) => _update(_s.copyWith(showTocButton: v))),
        _switch('Tap once to hide / show controls',
            'Scrolling with your finger never shows or hides controls — only a tap does. Tap once to show them, tap again to hide them and keep reading undisturbed.',
            _s.autoHideBars, (v) => _update(_s.copyWith(autoHideBars: v))),
        _switch('Edge tap zones', 'Left edge = previous chapter, right edge = next chapter.',
            _s.tapZones, (v) => _update(_s.copyWith(tapZones: v))),
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
              onChanged: (v) => _update(_s.copyWith(navPosition: v ?? 0)),
            )),
        _heading('Highlights'),
        _switch(
            'Highlights: long-press a paragraph to highlight it in colour and add a note',
            'Turn off if you do not want highlights at all — long-press will then do nothing.',
            _s.enableHighlights,
            (v) => _update(_s.copyWith(enableHighlights: v))),
        _heading('Text style'),
        Wrap(
          spacing: 8,
          children: ['Left', 'Justified', 'Centre'].asMap().entries.map((e) {
            final sel = _s.alignIndex == e.key;
            return ChoiceChip(
              label: Text(e.value),
              selected: sel,
              onSelected: (_) => _update(_s.copyWith(alignIndex: e.key)),
            );
          }).toList(),
        ),
        _switch('Bold text', null, _s.boldText,
            (v) => _update(_s.copyWith(boldText: v))),
      ]),
    );
  }
}

// ── Reading goals & stats — its own screen ──────────────────────────────
// Previously stats only lived in a small card on the library, and the
// library did not refresh it after reading, so it looked unimplemented.
class StatsScreen extends StatelessWidget {
  final ReaderSettings settings;
  final ReadingStats stats;
  final ValueChanged<ReaderSettings> onSettingsChanged;
  const StatsScreen(
      {super.key,
      required this.settings,
      required this.stats,
      required this.onSettingsChanged});

  static String _key(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    return Scaffold(
      appBar: AppBar(title: const Text('Reading goals & stats')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${stats.streak} day streak',
                      style: const TextStyle(
                          fontSize: 24, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text(
                      'Today ${stats.todayMinutes.toStringAsFixed(0)} / ${settings.goalMinutes} minutes'),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: settings.goalMinutes == 0
                          ? 0
                          : (stats.todayMinutes / settings.goalMinutes)
                              .clamp(0.0, 1.0),
                      color: terracotta,
                      minHeight: 8,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                      'Total ${stats.totalMinutes.toStringAsFixed(0)} minutes • ${stats.booksFinished} books finished'),
                ]),
          ),
        ),
        const SizedBox(height: 16),
        const Text('Daily goal',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        Row(children: [
          const Expanded(child: Text('How many minutes a day?')),
          Text('${settings.goalMinutes} min',
              style: const TextStyle(fontWeight: FontWeight.bold)),
        ]),
        Slider(
          value: settings.goalMinutes.toDouble(),
          min: 5,
          max: 120,
          divisions: 23,
          onChanged: (v) => onSettingsChanged(
              settings.copyWith(goalMinutes: v.round())),
        ),
        const Text(
            'Your goal is saved and shows on the library card. Reading time is counted while a book is open, and everything stays on this phone only.',
            style: TextStyle(color: Colors.grey)),
        const SizedBox(height: 16),
        const Text('Last 7 days',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        ...List.generate(7, (i) {
          final d = today.subtract(Duration(days: i));
          final mins = stats.minutesByDay[_key(d)] ?? 0;
          return ListTile(
            title: Text(i == 0
                ? 'Today'
                : i == 1
                    ? 'Yesterday'
                    : '${d.day}/${d.month}/${d.year}'),
            trailing: Text('${mins.toStringAsFixed(0)} min'),
          );
        }),
      ]),
    );
  }
}
