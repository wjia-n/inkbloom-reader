import 'package:flutter/services.dart';

/// In-app brightness only: it changes this app's window, never
/// the phone's system brightness. -1 means Auto (system).
/// On non-Android platforms the call simply does nothing.
Future<void> applyBrightness(double brightness) async {
  try {
    await const MethodChannel('inkbloom/content')
        .invokeMethod('setBrightness', {'brightness': brightness});
  } catch (_) {}
}

/// Restore system brightness when leaving the reader.
Future<void> resetBrightness() => applyBrightness(-1);
