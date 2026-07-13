import 'package:flutter_test/flutter_test.dart';

import 'package:friendify/core/constants/firestore_paths.dart';
import 'package:friendify/repositories/call_repository.dart';

void main() {
  test(
      'normalized chat session does not invent direction from requester-only data',
      () {
    final normalized = CallRepository.instance.debugNormalizeChatSessionPayload(
      requestedSpeakerId: 'speaker_z',
      requestedListenerId: 'listener_a',
      docId: 'listener_a_speaker_z',
      data: <String, dynamic>{
        FirestorePaths.fieldParticipantIds: <String>['listener_a', 'speaker_z'],
        FirestorePaths.fieldPairUserA: 'listener_a',
        FirestorePaths.fieldPairUserB: 'speaker_z',
        FirestorePaths.fieldSpeakerId: 'listener_a',
        FirestorePaths.fieldListenerId: 'speaker_z',
        FirestorePaths.fieldRequesterId: 'speaker_z',
        FirestorePaths.fieldCallRequestedBy: 'speaker_z',
        FirestorePaths.fieldCallRequestOpen: true,
      },
      exists: true,
    );

    expect(normalized[FirestorePaths.fieldActualListenerId], isEmpty);
    expect(normalized[FirestorePaths.fieldResponderId], isEmpty);
    expect(normalized[FirestorePaths.fieldPendingFor], isEmpty);
    expect(
      CallRepository.instance.sessionIdentityLooksComplete(
        session: normalized,
        speakerId: 'speaker_z',
        listenerId: 'listener_a',
      ),
      isFalse,
    );
    expect(
      CallRepository.instance.sessionDirectionLooksComplete(
        session: normalized,
        speakerId: 'speaker_z',
        listenerId: 'listener_a',
      ),
      isFalse,
    );
  });
}
