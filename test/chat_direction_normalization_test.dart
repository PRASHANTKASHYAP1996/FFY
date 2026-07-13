import 'package:flutter_test/flutter_test.dart';

import 'package:friendify/core/constants/firestore_paths.dart';
import 'package:friendify/repositories/call_repository.dart';

void main() {
  test(
      'normalization does not invent actual listener from requester-only legacy data',
      () {
    final normalized = CallRepository.instance.debugNormalizeChatSessionPayload(
      requestedSpeakerId: 'speaker_z',
      requestedListenerId: 'listener_a',
      docId: 'listener_a_speaker_z',
      exists: true,
      data: <String, dynamic>{
        FirestorePaths.fieldParticipantIds: <String>['listener_a', 'speaker_z'],
        FirestorePaths.fieldRequesterId: 'speaker_z',
        FirestorePaths.fieldCallRequestedBy: 'speaker_z',
        FirestorePaths.fieldCallRequestOpen: true,
      },
    );

    expect(normalized[FirestorePaths.fieldActualListenerId], isEmpty);
    expect(normalized[FirestorePaths.fieldResponderId], isEmpty);
    expect(normalized[FirestorePaths.fieldPendingFor], isEmpty);
  });

  test('normalization preserves explicit stored direction fields', () {
    final normalized = CallRepository.instance.debugNormalizeChatSessionPayload(
      requestedSpeakerId: 'speaker_z',
      requestedListenerId: 'listener_a',
      docId: 'listener_a_speaker_z',
      exists: true,
      data: <String, dynamic>{
        FirestorePaths.fieldParticipantIds: <String>['listener_a', 'speaker_z'],
        FirestorePaths.fieldActualListenerId: 'listener_a',
        FirestorePaths.fieldRequesterId: 'speaker_z',
        FirestorePaths.fieldResponderId: 'listener_a',
        FirestorePaths.fieldPendingFor: 'listener_a',
        FirestorePaths.fieldCallRequestOpen: true,
      },
    );

    expect(normalized[FirestorePaths.fieldActualListenerId], 'listener_a');
    expect(normalized[FirestorePaths.fieldResponderId], 'listener_a');
    expect(normalized[FirestorePaths.fieldPendingFor], 'listener_a');
  });
}
