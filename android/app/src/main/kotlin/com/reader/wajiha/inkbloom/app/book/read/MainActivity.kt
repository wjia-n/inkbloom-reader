package com.reader.wajiha.inkbloom.app.book.read

import android.content.Intent
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
                } else if (call.method == "share") {
                    try {
                        val send = Intent(Intent.ACTION_SEND).apply {
                            type = "text/plain"
                            putExtra(Intent.EXTRA_TEXT, "I'm reading with InkBloom Reader. Grow your reading habit.")
                        }
                        startActivity(Intent.createChooser(send, "Share InkBloom"))
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("SHARE_FAILED", e.message, null)
                    }
                } else if (call.method == "review") {
                    try {
                        val pkg = packageName
                        val market = Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=$pkg"))
                        val web = Intent(Intent.ACTION_VIEW, Uri.parse("https://play.google.com/store/apps/details?id=$pkg"))
                        try {
                            startActivity(market)
                        } catch (_: Exception) {
                            startActivity(web)
                        }
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("REVIEW_FAILED", e.message, null)
                    }
                } else if (call.method == "setBrightness") {
                    // In-app only: WindowManager.LayoutParams
                    // screenBrightness affects this window, never
                    // the system setting. -1 = use system brightness.
                    try {
                        val b = (call.argument<Double>("brightness") ?: -1.0).toFloat()
                        runOnUiThread {
                            val attrs = window.attributes
                            attrs.screenBrightness = if (b < 0) -1f else b.coerceIn(0.05f, 1.0f)
                            window.attributes = attrs
                        }
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("BRIGHTNESS_FAILED", e.message, null)
                    }
                } else {
                    result.notImplemented()
                }
            }
    }
}
