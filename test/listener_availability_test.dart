import 'package:flutter_test/flutter_test.dart';

import 'package:friendify/shared/listener_availability.dart';

void main() {
  test('available only when listener is recent, available, and not busy', () {
    final now = DateTime(2026, 4, 21, 12, 0, 0);

    final result = ListenerAvailabilityResolver.resolve(
      isAvailable: true,
      isOnCall: false,
      activeCallId: '',
      lastSeen: now.subtract(const Duration(minutes: 2)),
      now: now,
    );

    expect(result.kind, ListenerAvailabilityKind.available);
    expect(result.label, 'Available');
    expect(result.canCallNow, isTrue);
    expect(result.isOnline, isTrue);
  });

  test('busy lock wins over availability and shows on another call', () {
    final now = DateTime(2026, 4, 21, 12, 0, 0);

    final result = ListenerAvailabilityResolver.resolve(
      isAvailable: true,
      isOnCall: true,
      activeCallId: 'call_123',
      lastSeen: now.subtract(const Duration(minutes: 1)),
      now: now,
    );

    expect(result.kind, ListenerAvailabilityKind.onAnotherCall);
    expect(result.label, 'On another call');
    expect(result.canCallNow, isFalse);
  });

  test('stale or unavailable data uses hardened last seen text', () {
    final now = DateTime(2026, 4, 21, 12, 0, 0);

    final result = ListenerAvailabilityResolver.resolve(
      isAvailable: false,
      isOnCall: false,
      activeCallId: '',
      lastSeen: now.subtract(const Duration(hours: 3)),
      now: now,
    );

    expect(result.kind, ListenerAvailabilityKind.offline);
    expect(result.label, 'Last seen today');
    expect(result.label, isNot(contains('3h')));
    expect(result.canCallNow, isFalse);
  });

  test('missing last seen becomes checking instead of vague unavailable', () {
    final result = ListenerAvailabilityResolver.resolve(
      isAvailable: false,
      isOnCall: false,
      activeCallId: '',
      lastSeen: null,
      now: DateTime(2026, 4, 21, 12, 0, 0),
    );

    expect(result.kind, ListenerAvailabilityKind.checking);
    expect(result.label, 'Checking...');
    expect(result.canCallNow, isFalse);
  });

  test('availability labels never use vague unavailable wording', () {
    final now = DateTime(2026, 4, 21, 12, 0, 0);
    final results = <ListenerAvailabilityResult>[
      ListenerAvailabilityResolver.resolve(
        isAvailable: true,
        isOnCall: false,
        activeCallId: '',
        lastSeen: now.subtract(const Duration(minutes: 2)),
        now: now,
      ),
      ListenerAvailabilityResolver.resolve(
        isAvailable: true,
        isOnCall: true,
        activeCallId: 'call_123',
        lastSeen: now.subtract(const Duration(minutes: 1)),
        now: now,
      ),
      ListenerAvailabilityResolver.resolve(
        isAvailable: false,
        isOnCall: false,
        activeCallId: '',
        lastSeen: null,
        now: now,
      ),
      ListenerAvailabilityResolver.resolve(
        isAvailable: false,
        isOnCall: false,
        activeCallId: '',
        lastSeen: now.subtract(const Duration(days: 1)),
        now: now,
      ),
    ];

    for (final result in results) {
      expect(
        result.label.toLowerCase(),
        isNot(contains('may be unavailable')),
      );
      expect(
        result.label.toLowerCase(),
        isNot(contains('may be busy')),
      );
    }
  });
}
