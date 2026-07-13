import 'package:flutter_test/flutter_test.dart';

import 'package:friendify/shared/chat_direction_resolver.dart';

void main() {
  test(
      'chat direction resolver prefers actual listener fields over canonical listener id',
      () {
    final result = ChatDirectionResolver.resolveForUser(
      session: <String, dynamic>{
        'participantIds': ['user_a', 'user_z'],
        'speakerId': 'user_a',
        'listenerId': 'user_z',
        'pairUserA': 'user_a',
        'pairUserB': 'user_z',
        'actualListenerId': 'user_a',
        'requesterId': 'user_z',
        'responderId': 'user_a',
        'pendingFor': 'user_a',
      },
      myUid: 'user_z',
      fallbackSpeakerId: 'user_a',
      fallbackListenerId: 'user_z',
      mode: ChatDirectionResolutionMode.strictStoredDirection,
    );

    expect(result.isResolved, true);
    expect(result.actualSpeakerId, 'user_z');
    expect(result.actualListenerId, 'user_a');
    expect(result.iAmListener, false);
  });

  test(
      'chat direction resolver rejects sessions without a safe actual listener',
      () {
    final result = ChatDirectionResolver.resolveForUser(
      session: <String, dynamic>{
        'participantIds': ['user_a', 'user_z'],
        'speakerId': 'user_a',
        'listenerId': 'user_z',
        'pairUserA': 'user_a',
        'pairUserB': 'user_z',
      },
      myUid: 'user_z',
      fallbackSpeakerId: 'user_a',
      fallbackListenerId: 'user_z',
      mode: ChatDirectionResolutionMode.strictStoredDirection,
    );

    expect(result.isResolved, false);
    expect(result.errorReason, contains('actualListenerId'));
  });

  test(
      'strict mode rejects an existing session without stored direction fields',
      () {
    final result = ChatDirectionResolver.resolveForUser(
      session: <String, dynamic>{
        'participantIds': ['speaker_a', 'listener_b'],
        'speakerId': 'speaker_a',
        'listenerId': 'listener_b',
        'pairUserA': 'listener_b',
        'pairUserB': 'speaker_a',
      },
      myUid: 'speaker_a',
      fallbackSpeakerId: 'speaker_a',
      fallbackListenerId: 'listener_b',
      mode: ChatDirectionResolutionMode.strictStoredDirection,
    );

    expect(result.isResolved, false);
    expect(result.errorReason, contains('actualListenerId'));
  });

  test('selected listener fallback does not silently pass strict mode', () {
    final result = ChatDirectionResolver.resolveForUser(
      session: <String, dynamic>{
        'participantIds': ['speaker_a', 'listener_b'],
        'speakerId': 'speaker_a',
        'listenerId': 'listener_b',
      },
      myUid: 'speaker_a',
      fallbackSpeakerId: 'speaker_a',
      fallbackListenerId: 'listener_b',
      mode: ChatDirectionResolutionMode.strictStoredDirection,
    );

    expect(result.isResolved, false);
    expect(result.actualListenerId, isEmpty);
  });

  test('legacy requesterId can derive actualListenerId safely', () {
    final result = ChatDirectionResolver.resolveForUser(
      session: <String, dynamic>{
        'participantIds': ['speaker_a', 'listener_b'],
        'speakerId': 'speaker_a',
        'listenerId': 'listener_b',
        'requesterId': 'speaker_a',
      },
      myUid: 'listener_b',
      fallbackSpeakerId: 'speaker_a',
      fallbackListenerId: 'listener_b',
      mode: ChatDirectionResolutionMode.legacyRepair,
    );

    expect(result.isResolved, true);
    expect(result.actualListenerId, 'listener_b');
    expect(result.actualSpeakerId, 'speaker_a');
    expect(result.iAmListener, true);
  });

  test(
      'push direction resolver handles canonical participant order reversed from product direction',
      () {
    final result = ChatDirectionResolver.resolvePushDirectionForUser(
      participantIds: const ['listener_a', 'speaker_z'],
      myUid: 'speaker_z',
      actualListenerId: 'listener_a',
    );

    expect(result.isResolved, true);
    expect(result.actualListenerId, 'listener_a');
    expect(result.actualSpeakerId, 'speaker_z');
    expect(result.iAmListener, false);
  });

  test('push direction resolver supports actualListenerId at participantIds[0]',
      () {
    final result = ChatDirectionResolver.resolvePushDirectionForUser(
      participantIds: const ['listener_first', 'speaker_second'],
      myUid: 'listener_first',
      actualListenerId: 'listener_first',
    );

    expect(result.isResolved, true);
    expect(result.actualListenerId, 'listener_first');
    expect(result.actualSpeakerId, 'speaker_second');
    expect(result.iAmListener, true);
  });

  test(
      'push direction resolver derives actualSpeakerId from the other participant',
      () {
    final result = ChatDirectionResolver.resolvePushDirectionForUser(
      participantIds: const ['listener_a', 'speaker_b'],
      myUid: 'speaker_b',
      actualListenerId: 'listener_a',
    );

    expect(result.isResolved, true);
    expect(result.actualSpeakerId, 'speaker_b');
    expect(result.actualListenerId, 'listener_a');
  });
}
