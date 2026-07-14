/// Pure "time ago" formatting for feed/chat timestamps, extracted from the
/// shell so its boundaries can be unit tested. Injecting [now] keeps tests
/// deterministic.
class RelativeTime {
  const RelativeTime._();

  /// Formats the epoch-millisecond timestamp [ms] as a short relative label:
  /// 'now', '5m', '2h', '3d', '1w', '4mo', '2y'. Returns '' for a non-positive
  /// timestamp (i.e. "unknown"). [now] defaults to the current time.
  static String format(int ms, {DateTime? now}) {
    if (ms <= 0) return '';
    final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final diff = nowMs - ms;
    if (diff < 60000) return 'now';
    final mins = diff ~/ 60000;
    if (mins < 60) return '${mins}m';
    final hours = mins ~/ 60;
    if (hours < 24) return '${hours}h';
    final days = hours ~/ 24;
    if (days < 7) return '${days}d';
    if (days < 35) return '${days ~/ 7}w';
    if (days < 365) return '${days ~/ 30}mo';
    return '${days ~/ 365}y';
  }
}
