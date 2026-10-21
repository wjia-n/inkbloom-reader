import 'package:flutter/services.dart';

/// Share + review without new plugins: the same native
/// channel that reads content:// URIs also fires Android
/// intents. Share opens the system share sheet; review
/// opens the Play Store page (works once the app is
/// published there — until then Play shows "not found",
/// which is why the dialog labels it honestly).
Future<void> shareApp() async {
  try {
    await const MethodChannel('inkbloom/content').invokeMethod('share');
  } catch (_) {}
}

Future<void> reviewApp() async {
  try {
    await const MethodChannel('inkbloom/content').invokeMethod('review');
  } catch (_) {}
}
