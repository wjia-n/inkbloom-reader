package com.wajiha.inkbloomreader

import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Reads content:// URIs (Files, Drive, WhatsApp, ...) that Dart's
        // File cannot open. Used by the file picker import path.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "inkbloom/content")
            .setMethodCallHandler { call, result ->
                if (call.method == "readUri") {
                    try {
                        val uri = Uri.parse(call.argument<String>("uri"))
                        val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
                        if (bytes != null) result.success(bytes) else result.error("EMPTY", "No bytes", null)
                    } catch (e: Exception) {
                        result.error("READ_FAILED", e.message, null)
                    }
                } else {
                    result.notImplemented()
                }
            }
    }
}
