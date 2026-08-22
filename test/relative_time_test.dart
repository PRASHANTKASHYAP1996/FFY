import 'package:flutter_test/flutter_test.dart';

import 'package:friendify/shared/relative_time.dart';

void main() {
  // Fixed reference point so every case is deterministic.
  final now = DateTime(2026, 7, 14, 12, 0, 0);
  int ago(Duration d) => now.subtract(d).millisecondsSinceEpoch;
  String fmt(Duration d) => RelativeTime.format(ago(d), now: now);

  test('non-positive timestamp is empty (unknown)', () {
    expect(RelativeTime.format(0, now: now), '');
    expect(RelativeTime.format(-1, now: now), '');
  });

  test('under a minute reads "now"', () {
    expect(fmt(const Duration(seconds: 0)), 'now');
    expect(fmt(const Duration(seconds: 59)), 'now');
  });

  test('a future timestamp also reads "now"', () {
    expect(
        RelativeTime.format(
            now.add(const Duration(hours: 1)).millisecondsSinceEpoch,
            now: now),
        'now');
  });

  test('minutes', () {
    expect(fmt(const Duration(minutes: 1)), '1m');
    expect(fmt(const Duration(minutes: 59)), '59m');
  });

  test('hours', () {
    expect(fmt(const Duration(hours: 1)), '1h');
    expect(fmt(const Duration(hours: 23, minutes: 59)), '23h');
  });

  test('days', () {
    expect(fmt(const Duration(days: 1)), '1d');
    expect(fmt(const Duration(days: 6)), '6d');
  });

  test('weeks (7..34 days)', () {
    expect(fmt(const Duration(days: 7)), '1w');
    expect(fmt(const Duration(days: 34)), '4w');
  });

  test('months (35..364 days)', () {
    expect(fmt(const Duration(days: 35)), '1mo');
    expect(fmt(const Duration(days: 364)), '12mo');
  });

  test('years (365+ days)', () {
    expect(fmt(const Duration(days: 365)), '1y');
    expect(fmt(const Duration(days: 800)), '2y');
  });
}
