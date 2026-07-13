import 'package:flutter_test/flutter_test.dart';

import 'package:friendify/core/constants/firestore_paths.dart';
import 'package:friendify/repositories/call_repository.dart';
import 'package:friendify/screens/chat_conversation_screen.dart';

void main() {
  test(
    'accepted chat status wins over stale open request fields',
    () {
      final session = <String, dynamic>{
        'exists': true,
        FirestorePaths.fieldChatStatus: FirestorePaths.chatStatusAccepted,
        FirestorePaths.fieldCallRequestOpen: true,
        FirestorePaths.fieldCallAllowed: false,
        FirestorePaths.fieldCallRequestedBy: 'speaker_a',
        FirestorePaths.fieldRequesterId: 'speaker_a',
        FirestorePaths.fieldResponderId: 'listener_b',
        FirestorePaths.fieldPendingFor: 'listener_b',
      };

      expect(chatSessionHasAcceptedCallAccessForUi(session), isTrue);
    },
  );

  test('call access is accepted when callAllowed is true', () {
    final session = <String, dynamic>{
      'exists': true,
      FirestorePaths.fieldChatStatus: FirestorePaths.chatStatusAccepted,
      FirestorePaths.fieldCallRequestOpen: false,
      FirestorePaths.fieldCallAllowed: true,
      FirestorePaths.fieldCallRequestedBy: 'speaker_a',
      FirestorePaths.fieldRequesterId: 'speaker_a',
      FirestorePaths.fieldResponderId: 'listener_b',
      FirestorePaths.fieldPendingFor: '',
    };

    expect(chatSessionHasAcceptedCallAccessForUi(session), isTrue);
  });

  test('stale open request does not block accepted call access flag', () {
    final session = <String, dynamic>{
      'exists': true,
      FirestorePaths.fieldChatStatus: FirestorePaths.chatStatusAccepted,
      FirestorePaths.fieldCallRequestOpen: true,
      FirestorePaths.fieldCallAllowed: true,
      FirestorePaths.fieldCallRequestedBy: 'speaker_a',
      FirestorePaths.fieldRequesterId: 'speaker_a',
      FirestorePaths.fieldResponderId: 'listener_b',
      FirestorePaths.fieldPendingFor: 'listener_b',
    };

    expect(chatSessionHasAcceptedCallAccessForUi(session), isTrue);
  });

  test('accepted call direction survives cleared legacy request fields', () {
    final repository = CallRepository.instance;
    final sessionId = repository.chatSessionIdForPair(
      speakerId: 'speaker_a',
      listenerId: 'listener_b',
    );
    final participants = <String>['speaker_a', 'listener_b']..sort();
    final session = <String, dynamic>{
      'exists': true,
      FirestorePaths.fieldChatSessionId: sessionId,
      FirestorePaths.fieldSpeakerId: participants[0],
      FirestorePaths.fieldListenerId: participants[1],
      FirestorePaths.fieldPairUserA: participants[0],
      FirestorePaths.fieldPairUserB: participants[1],
      FirestorePaths.fieldParticipantIds: participants,
      FirestorePaths.fieldPairKey: sessionId,
      FirestorePaths.fieldActualListenerId: 'listener_b',
      FirestorePaths.fieldChatStatus: FirestorePaths.chatStatusAccepted,
      FirestorePaths.fieldCallAllowed: false,
      FirestorePaths.fieldCallRequestOpen: false,
      FirestorePaths.fieldCallRequestedBy: '',
      FirestorePaths.fieldRequesterId: '',
      FirestorePaths.fieldResponderId: '',
      FirestorePaths.fieldPendingFor: '',
      FirestorePaths.fieldSpeakerBlocked: false,
      FirestorePaths.fieldListenerBlocked: false,
    };

    expect(
      repository.sessionAllowsCallForDirection(
        session: session,
        speakerId: 'speaker_a',
        listenerId: 'listener_b',
      ),
      isTrue,
    );
  });

  test('effective start access follows accepted status when direction is valid',
      () {
    expect(
      chatSessionHasEffectiveStartCallAccessForUi(
        acceptedAccess: true,
        directionAllowed: true,
        allowedAtMs: 0,
        staleCallApprovalAtMs: 0,
      ),
      isTrue,
    );
  });
}
