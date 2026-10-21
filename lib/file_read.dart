import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

/// Reads a file the user picked, no matter where it came from.
///
/// file_picker 13 on Android can return a content:// URI (Files, Drive,
/// WhatsApp, …). Dart's File cannot open those, and PlatformFile.readAsBytes()
/// throws for them — which used to kill the whole import silently.
/// This tries, in order: a real local path, the app's native content-URI
/// reader (MainActivity), then the generic reader. It never throws
/// silently past the caller: callers show the reason to the user.
Future<Uint8List> readPickedFile(PlatformFile f) async {
  final path = f.path;
  if (path != null && path.isNotEmpty) {
    try {
      final file = File(path);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        if (bytes.isNotEmpty) return bytes;
      }
    } catch (_) {}
  }
  if (f.uri.scheme == 'content') {
    try {
      final bytes = await const MethodChannel('inkbloom/content')
          .invokeMethod<Uint8List>('readUri', {'uri': f.uri.toString()});
      if (bytes != null && bytes.isNotEmpty) return bytes;
    } catch (_) {}
  }
  // Last resort: the plugin's own reader (works for file:// picks).
  return await f.readAsBytes();
}
