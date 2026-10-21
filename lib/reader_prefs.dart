import 'dart:convert';
import 'package:flutter/material.dart';

/// One reader colour theme: background, text and accent.
class ReaderThemeDef {
  final String name;
  final Color bg;
  final Color fg;
  final Color accent;
  const ReaderThemeDef(this.name, this.bg, this.fg, this.accent);
}

/// 12 themes — the maximum useful set without becoming clutter.
const readerThemes = <ReaderThemeDef>[
  ReaderThemeDef('Paper Cream', Color(0xFFFFF8E7), Color(0xFF2B2620), Color(0xFFE07A5F)),
  ReaderThemeDef('Sepia', Color(0xFFF3E5C8), Color(0xFF4A3826), Color(0xFFB7791F)),
  ReaderThemeDef('Forest Night', Color(0xFF122E28), Color(0xFFE8EFE6), Color(0xFFA8C3A0)),
  ReaderThemeDef('Midnight', Color(0xFF121212), Color(0xFFEDEDED), Color(0xFF90CAF9)),
  ReaderThemeDef('Rose Dusk', Color(0xFFFCE4EC), Color(0xFF4A2530), Color(0xFFE91E63)),
  ReaderThemeDef('Ocean', Color(0xFFE3F2FD), Color(0xFF0D3247), Color(0xFF0288D1)),
  ReaderThemeDef('Lavender', Color(0xFFEDE7F6), Color(0xFF311B4A), Color(0xFF7E57C2)),
  ReaderThemeDef('Amber Glow', Color(0xFFFFF3E0), Color(0xFF4E342E), Color(0xFFFF8F00)),
  ReaderThemeDef('Mint Leaf', Color(0xFFE8F5E9), Color(0xFF1B3A24), Color(0xFF43A047)),
  ReaderThemeDef('Charcoal', Color(0xFF263238), Color(0xFFECEFF1), Color(0xFFFFB74D)),
  ReaderThemeDef('Blush Paper', Color(0xFFFFF0F0), Color(0xFF3E2723), Color(0xFFE57373)),
  ReaderThemeDef('Olive Grove', Color(0xFFF1F8E9), Color(0xFF33691E), Color(0xFF827717)),
];

/// Everything the user can customise about reading + navigation.
/// Persisted as JSON in SharedPreferences, so it survives restarts
/// and is included in a transfer backup.
class ReaderSettings {
  final double fontSize; // 12..32
  final double lineHeight; // 1.2..2.2
  final double letterSpacing; // 0..3
  final double paragraphSpacing; // 4..32
  final double pageMargin; // 12..40
  final int fontIndex; // 0 serif, 1 sans, 2 mono
  final int alignIndex; // 0 left, 1 justify, 2 center
  final int themeIndex;
  final int readingMode; // 0 continuous scroll, 1 paged swipe, 2 horizontal scroll
  final bool boldText;
  final bool showTopBar;
  final bool showBottomBar;
  final bool showChapterSlider;
  final bool showPrevNext;
  final bool showBookmarkButton;
  final bool showSearchButton;
  final bool showTocButton;
  final int navPosition; // 0 bottom, 1 top, 2 floating pill
  final bool autoHideBars; // tap centre to show/hide bars
  final bool tapZones; // left/right edge taps change chapter
  final bool doubleTapLockEnabled;
  final bool autoNight;
  final int nightStartHour; // 0..23
  final int nightEndHour; // 0..23
  final double ttsRate; // 0.5..2.0
  final double ttsPitch; // 0.5..2.0
  final int goalMinutes; // daily reading goal
  final String languageCode; // UI language: en, ur, ar, es, fr
  final String ttsVoiceName; // chosen TTS voice, '' = device default
  final String ttsVoiceLocale; // locale of the chosen voice
  final bool showTextSizeButtons; // show - / + text size buttons in reader
  final bool enableHighlights; // long-press paragraph to highlight
  final List<String> customFonts; // runtime-loaded font family names
  final double brightness; // -1 = Auto (system brightness), else 0.05..1.0

  const ReaderSettings({
    this.fontSize = 18,
    this.lineHeight = 1.65,
    this.letterSpacing = 0,
    this.paragraphSpacing = 16,
    this.pageMargin = 24,
    this.fontIndex = 0,
    this.alignIndex = 1,
    this.themeIndex = 0,
    this.readingMode = 0,
    this.boldText = false,
    this.showTopBar = true,
    this.showBottomBar = true,
    this.showChapterSlider = true,
    this.showPrevNext = true,
    this.showBookmarkButton = true,
    this.showSearchButton = true,
    this.showTocButton = true,
    this.navPosition = 0,
    this.autoHideBars = true,
    this.tapZones = true,
    this.doubleTapLockEnabled = true,
    this.autoNight = false,
    this.nightStartHour = 21,
    this.nightEndHour = 7,
    this.ttsRate = 0.6,
    this.ttsPitch = 1.0,
    this.goalMinutes = 30,
    this.languageCode = 'en',
    this.ttsVoiceName = '',
    this.ttsVoiceLocale = '',
    this.showTextSizeButtons = true,
    this.enableHighlights = true,
    this.customFonts = const [],
    this.brightness = -1,
  });

  String? get fontFamily {
    if (fontIndex == 0) return 'serif';
    if (fontIndex == 1) return 'sans-serif';
    if (fontIndex == 2) return 'monospace';
    final idx = fontIndex - 3;
    if (idx >= 0 && idx < customFonts.length) return customFonts[idx];
    return null;
  }

  /// The theme actually in use right now, honouring auto-night.
  ReaderThemeDef get effectiveTheme {
    if (!autoNight) return theme;
    final hour = DateTime.now().hour;
    final inNight = nightStartHour <= nightEndHour
        ? (hour >= nightStartHour && hour < nightEndHour)
        : (hour >= nightStartHour || hour < nightEndHour);
    return inNight ? readerThemes[3] : theme; // 3 = Midnight
  }
  TextAlign get align => switch (alignIndex) {
        1 => TextAlign.justify,
        2 => TextAlign.center,
        _ => TextAlign.left,
      };
  ReaderThemeDef get theme =>
      readerThemes[themeIndex.clamp(0, readerThemes.length - 1)];

  ReaderSettings copyWith({
    double? fontSize,
    double? lineHeight,
    double? letterSpacing,
    double? paragraphSpacing,
    double? pageMargin,
    int? fontIndex,
    int? alignIndex,
    int? themeIndex,
    int? readingMode,
    bool? boldText,
    bool? showTopBar,
    bool? showBottomBar,
    bool? showChapterSlider,
    bool? showPrevNext,
    bool? showBookmarkButton,
    bool? showSearchButton,
    bool? showTocButton,
    int? navPosition,
    bool? autoHideBars,
    bool? tapZones,
    bool? doubleTapLockEnabled,
    bool? autoNight,
    int? nightStartHour,
    int? nightEndHour,
    double? ttsRate,
    double? ttsPitch,
    int? goalMinutes,
    String? languageCode,
    String? ttsVoiceName,
    String? ttsVoiceLocale,
    bool? showTextSizeButtons,
    bool? enableHighlights,
    List<String>? customFonts,
    double? brightness,
  }) =>
      ReaderSettings(
        fontSize: fontSize ?? this.fontSize,
        lineHeight: lineHeight ?? this.lineHeight,
        letterSpacing: letterSpacing ?? this.letterSpacing,
        paragraphSpacing: paragraphSpacing ?? this.paragraphSpacing,
        pageMargin: pageMargin ?? this.pageMargin,
        fontIndex: fontIndex ?? this.fontIndex,
        alignIndex: alignIndex ?? this.alignIndex,
        themeIndex: themeIndex ?? this.themeIndex,
        readingMode: readingMode ?? this.readingMode,
        boldText: boldText ?? this.boldText,
        showTopBar: showTopBar ?? this.showTopBar,
        showBottomBar: showBottomBar ?? this.showBottomBar,
        showChapterSlider: showChapterSlider ?? this.showChapterSlider,
        showPrevNext: showPrevNext ?? this.showPrevNext,
        showBookmarkButton: showBookmarkButton ?? this.showBookmarkButton,
        showSearchButton: showSearchButton ?? this.showSearchButton,
        showTocButton: showTocButton ?? this.showTocButton,
        navPosition: navPosition ?? this.navPosition,
        autoHideBars: autoHideBars ?? this.autoHideBars,
        tapZones: tapZones ?? this.tapZones,
        doubleTapLockEnabled:
            doubleTapLockEnabled ?? this.doubleTapLockEnabled,
        autoNight: autoNight ?? this.autoNight,
        nightStartHour: nightStartHour ?? this.nightStartHour,
        nightEndHour: nightEndHour ?? this.nightEndHour,
        ttsRate: ttsRate ?? this.ttsRate,
        ttsPitch: ttsPitch ?? this.ttsPitch,
        goalMinutes: goalMinutes ?? this.goalMinutes,
        languageCode: languageCode ?? this.languageCode,
        ttsVoiceName: ttsVoiceName ?? this.ttsVoiceName,
        ttsVoiceLocale: ttsVoiceLocale ?? this.ttsVoiceLocale,
        showTextSizeButtons:
            showTextSizeButtons ?? this.showTextSizeButtons,
        enableHighlights: enableHighlights ?? this.enableHighlights,
        customFonts: customFonts ?? this.customFonts,
        brightness: brightness ?? this.brightness,
      );

  Map<String, dynamic> toJson() => {
        'fontSize': fontSize,
        'lineHeight': lineHeight,
        'letterSpacing': letterSpacing,
        'paragraphSpacing': paragraphSpacing,
        'pageMargin': pageMargin,
        'fontIndex': fontIndex,
        'alignIndex': alignIndex,
        'themeIndex': themeIndex,
        'readingMode': readingMode,
        'boldText': boldText,
        'showTopBar': showTopBar,
        'showBottomBar': showBottomBar,
        'showChapterSlider': showChapterSlider,
        'showPrevNext': showPrevNext,
        'showBookmarkButton': showBookmarkButton,
        'showSearchButton': showSearchButton,
        'showTocButton': showTocButton,
        'navPosition': navPosition,
        'autoHideBars': autoHideBars,
        'tapZones': tapZones,
        'doubleTapLockEnabled': doubleTapLockEnabled,
        'autoNight': autoNight,
        'nightStartHour': nightStartHour,
        'nightEndHour': nightEndHour,
        'ttsRate': ttsRate,
        'ttsPitch': ttsPitch,
        'goalMinutes': goalMinutes,
        'customFonts': customFonts,
        'languageCode': languageCode,
        'ttsVoiceName': ttsVoiceName,
        'ttsVoiceLocale': ttsVoiceLocale,
        'showTextSizeButtons': showTextSizeButtons,
        'enableHighlights': enableHighlights,
        'brightness': brightness,
      };

  static ReaderSettings fromJson(Map<String, dynamic>? j) {
    if (j == null) return const ReaderSettings();
    double d(String k, double fallback) =>
        (j[k] as num?)?.toDouble() ?? fallback;
    int i(String k, int fallback) => (j[k] as num?)?.toInt() ?? fallback;
    bool b(String k, bool fallback) => j[k] as bool? ?? fallback;
    return ReaderSettings(
      fontSize: d('fontSize', 18),
      lineHeight: d('lineHeight', 1.65),
      letterSpacing: d('letterSpacing', 0),
      paragraphSpacing: d('paragraphSpacing', 16),
      pageMargin: d('pageMargin', 24),
      fontIndex: i('fontIndex', 0),
      alignIndex: i('alignIndex', 1),
      themeIndex: i('themeIndex', 0),
      readingMode: i('readingMode', 0),
      boldText: b('boldText', false),
      showTopBar: b('showTopBar', true),
      showBottomBar: b('showBottomBar', true),
      showChapterSlider: b('showChapterSlider', true),
      showPrevNext: b('showPrevNext', true),
      showBookmarkButton: b('showBookmarkButton', true),
      showSearchButton: b('showSearchButton', true),
      showTocButton: b('showTocButton', true),
      navPosition: i('navPosition', 0),
      autoHideBars: b('autoHideBars', true),
      tapZones: b('tapZones', true),
      doubleTapLockEnabled: b('doubleTapLockEnabled', true),
      autoNight: b('autoNight', false),
      nightStartHour: i('nightStartHour', 21),
      nightEndHour: i('nightEndHour', 7),
      ttsRate: d('ttsRate', 0.6),
      ttsPitch: d('ttsPitch', 1.0),
      goalMinutes: i('goalMinutes', 30),
      customFonts: ((j['customFonts'] as List?) ?? [])
          .map((e) => e.toString())
          .toList(),
      languageCode: j['languageCode'] as String? ?? 'en',
      ttsVoiceName: j['ttsVoiceName'] as String? ?? '',
      ttsVoiceLocale: j['ttsVoiceLocale'] as String? ?? '',
      showTextSizeButtons: b('showTextSizeButtons', true),
      enableHighlights: b('enableHighlights', true),
      brightness: d('brightness', -1),
    );
  }

  static ReaderSettings fromJsonString(String? s) {
    if (s == null) return const ReaderSettings();
    try {
      return fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return const ReaderSettings();
    }
  }
}
