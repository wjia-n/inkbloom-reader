import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'models.dart';

/// Fully offline transfer: one .inkbloom zip holding everything —
/// library state (progress, bookmarks, highlights, notes, settings)
/// plus every imported book file and cover image.
/// No account, no server, no internet needed to move phones:
/// export on the old phone, move the file, import on the new one.
class TransferBundle {
  /// Build the zip bytes from the current library + settings JSON.
  static Uint8List buildZip({
    required List<LibraryBook> books,
    required String settingsJson,
    String statsJson = '',
  }) {
    final archive = Archive();
    final state = {
      'version': 1,
      'exportedAt': DateTime.now().toIso8601String(),
      'settings': settingsJson,
      'stats': statsJson,
      'books': books.map((b) => b.toJson()).toList(),
    };
    final stateBytes = utf8.encode(jsonEncode(state));
    archive.addFile(ArchiveFile('library.json', stateBytes.length, stateBytes));
    for (final book in books) {
      if (book.filePath != null) {
        try {
          final bytes = File(book.filePath!).readAsBytesSync();
          archive.addFile(ArchiveFile(
              'books/${book.id}.${book.format}', bytes.length, bytes));
        } catch (_) {}
      }
      if (book.coverPath != null) {
        try {
          final bytes = File(book.coverPath!).readAsBytesSync();
          archive.addFile(
              ArchiveFile('covers/${book.id}.cover', bytes.length, bytes));
        } catch (_) {}
      }
    }
    return Uint8List.fromList(ZipEncoder().encode(archive)!);
  }

  /// Parse a bundle back into (books-without-chapters, settingsJson).
  /// Callers re-parse each book file to rebuild chapters.
  static ({
    List<LibraryBook> books,
    String settingsJson,
    String statsJson,
    Map<String, Uint8List> files,
  })
      parseZip(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    Map<String, dynamic>? state;
    final files = <String, Uint8List>{};
    for (final f in archive.files) {
      if (f.name == 'library.json') {
        state = jsonDecode(utf8.decode(f.content)) as Map<String, dynamic>;
      } else {
        files[f.name] = Uint8List.fromList(f.content);
      }
    }
    if (state == null) {
      throw const FormatException('Not an InkBloom backup file.');
    }
    final books = <LibraryBook>[];
    for (final e in (state['books'] as List? ?? [])) {
      final b = LibraryBook.fromJson(e as Map<String, dynamic>);
      if (b != null) books.add(b);
    }
    return (
      books: books,
      settingsJson: state['settings'] as String? ?? '',
      statsJson: state['stats'] as String? ?? '',
      files: files,
    );
  }
}
