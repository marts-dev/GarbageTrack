/// Calendar-day helpers for scheduled pickups.
///
/// The API exchanges scheduled days as ISO YYYY-MM-DD strings — a day, not
/// an instant — so parsing and formatting stay in local calendar terms and
/// never shift across timezones. No intl dependency needed.
library;

const monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

const monthShortNames = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// Sunday-start weekday headers, matching the device locale default.
const weekdayLabels = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

/// Parses an ISO day ('2026-12-25', full ISO strings tolerated) into a
/// local-midnight [DateTime]. Returns null for missing values so legacy
/// payloads without a scheduled day still parse.
DateTime? tryParseDay(Object? raw) {
  if (raw == null) return null;
  if (raw is DateTime) return DateTime(raw.year, raw.month, raw.day);
  if (raw is! String || raw.isEmpty) return null;
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) return null;
  return DateTime(parsed.year, parsed.month, parsed.day);
}

/// '2026-12-25' for API bodies.
String toIsoDay(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-'
    '${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

/// '25 Dec 2026'.
String formatDay(DateTime day) =>
    '${day.day} ${monthShortNames[day.month - 1]} ${day.year}';

/// 'December 2026'.
String formatMonthYear(DateTime month) =>
    '${monthNames[month.month - 1]} ${month.year}';

bool sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// Today's date at local midnight.
DateTime todayDay() {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
}

/// 'Today', 'Tomorrow', 'In 5 days', 'Yesterday', '3 days ago'.
/// [today] is injectable so tests don't depend on the wall clock.
String relativeDay(DateTime day, {DateTime? today}) {
  final base = today ?? todayDay();
  final delta = DateTime(day.year, day.month, day.day)
      .difference(DateTime(base.year, base.month, base.day))
      .inDays;
  if (delta == 0) return 'Today';
  if (delta == 1) return 'Tomorrow';
  if (delta == -1) return 'Yesterday';
  if (delta > 1) return 'In $delta days';
  return '${-delta} days ago';
}
