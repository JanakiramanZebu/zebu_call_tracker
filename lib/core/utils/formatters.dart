import 'package:intl/intl.dart';

/// Display helpers. Everything here takes UTC in and emits local time, which is
/// the only place that conversion is allowed to happen (brief §5).
abstract final class Fmt {
  /// `4m 32s`, `1h 05m`, `12s`. Used wherever a call length is shown inline.
  static String duration(int seconds) {
    if (seconds <= 0) return '0s';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) return '${h}h ${m.toString().padLeft(2, '0')}m';
    if (m > 0) return '${m}m ${s.toString().padLeft(2, '0')}s';
    return '${s}s';
  }

  /// `02:18` style, for the talk-time hero where the unit labels sit separately.
  static (String hours, String minutes) talkTime(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    return (h.toString().padLeft(2, '0'), m.toString().padLeft(2, '0'));
  }

  static String clock(DateTime utc) => DateFormat.Hm().format(utc.toLocal());

  static String dayHeading(DateTime utc) {
    final local = DateTime(
      utc.toLocal().year,
      utc.toLocal().month,
      utc.toLocal().day,
    );
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final delta = today.difference(local).inDays;
    if (delta == 0) return 'Today';
    if (delta == 1) return 'Yesterday';
    if (delta < 7) return DateFormat.EEEE().format(local);
    return DateFormat('d MMMM').format(local);
  }

  static String fullTimestamp(DateTime utc) =>
      DateFormat('HH:mm:ss').format(utc.toLocal());

  static String fileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// `+91 98••• ••210`.
  ///
  /// Staff see enough to recognise a number they already know without the full
  /// value being readable over a shoulder. The unmasked number is available on
  /// the call detail screen, where looking at it is a deliberate act.
  static String maskNumber(String? number) {
    if (number == null || number.isEmpty) return 'Number withheld';
    final digits = number.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length < 7) return number;
    final cc = number.startsWith('+')
        ? '+${digits.substring(0, digits.length - 10)} '
        : '';
    final tail = digits.substring(digits.length - 10);
    return '$cc${tail.substring(0, 2)}••• ••${tail.substring(7)}';
  }

  /// `+91 97397 87538` — grouped but complete.
  static String prettyNumber(String? number) {
    if (number == null || number.isEmpty) return 'Number withheld';
    final digits = number.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length < 10) return number;
    final tail = digits.substring(digits.length - 10);
    final cc = digits.substring(0, digits.length - 10);
    final prefix = cc.isEmpty ? '' : '+$cc ';
    return '$prefix${tail.substring(0, 5)} ${tail.substring(5)}';
  }

  /// Two-letter monogram for the contact avatar. Falls back to a glyph rather
  /// than showing digits, which read as noise at avatar size.
  static String initials(String? name) {
    if (name == null || name.trim().isEmpty) return '#';
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length == 1) {
      return parts.first.substring(0, 1).toUpperCase();
    }
    return (parts.first.substring(0, 1) + parts[1].substring(0, 1))
        .toUpperCase();
  }
}
