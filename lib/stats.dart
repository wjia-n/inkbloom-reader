import 'dart:convert';

/// Local reading stats: minutes per day, streak, totals.
/// No account, no server — everything lives on the phone and is
/// included in a transfer backup via the library state file.
class ReadingStats {
  final Map<String, double> minutesByDay; // '2026-10-21' -> minutes
  final int booksFinished;

  const ReadingStats({this.minutesByDay = const {}, this.booksFinished = 0});

  static String _today() {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  double get todayMinutes => minutesByDay[_today()] ?? 0;
  double get totalMinutes =>
      minutesByDay.values.fold(0, (a, b) => a + b);

  /// Consecutive days with any reading, ending today or yesterday.
  int get streak {
    var count = 0;
    var day = DateTime.now();
    // Allow today to be empty so far: start counting from yesterday
    // if today has no minutes yet.
    if ((minutesByDay[_key(day)] ?? 0) <= 0) {
      day = day.subtract(const Duration(days: 1));
    }
    while ((minutesByDay[_key(day)] ?? 0) > 0) {
      count++;
      day = day.subtract(const Duration(days: 1));
    }
    return count;
  }

  static String _key(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  ReadingStats recordMinutes(double minutes, {bool finishedBook = false}) {
    final map = Map<String, double>.from(minutesByDay);
    final key = _today();
    map[key] = (map[key] ?? 0) + minutes;
    return ReadingStats(
      minutesByDay: map,
      booksFinished: booksFinished + (finishedBook ? 1 : 0),
    );
  }

  Map<String, dynamic> toJson() => {
        'minutesByDay': minutesByDay,
        'booksFinished': booksFinished,
      };

  static ReadingStats fromJsonString(String? s) {
    if (s == null) return const ReadingStats();
    try {
      final j = jsonDecode(s) as Map<String, dynamic>;
      final raw = j['minutesByDay'] as Map<String, dynamic>? ?? {};
      return ReadingStats(
        minutesByDay: raw.map(
            (k, v) => MapEntry(k, (v as num).toDouble())),
        booksFinished: (j['booksFinished'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return const ReadingStats();
    }
  }
}
