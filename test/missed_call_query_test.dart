import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('missed call watcher is scoped to the signed-in callee', () {
    final source = File(
      'lib/repositories/call_repository.dart',
    ).readAsStringSync();
    final start = source.indexOf(
      'Stream<List<CallModel>> watchMissedCalls',
    );
    final end =
        source.indexOf('Future<List<CallModel>> fetchRecentCalls', start);

    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));

    final method = source.substring(start, end);
    expect(
      method,
      contains('.where(FirestorePaths.fieldCalleeId, isEqualTo: uid)'),
    );
    expect(method, contains('.where(_isMissedRejectedCall)'));
    expect(method, isNot(contains('whereIn')));
  });
}
