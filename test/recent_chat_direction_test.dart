import 'package:flutter_test/flutter_test.dart';

import 'package:friendify/shared/chat_direction_resolver.dart';

// The old home-screen "Recent Chats" helpers were removed with the redesign;
// the direction-resolution logic itself lives in ChatDirectionResolver and the
// scenario below is kept because it covers the lexically-greater-uid case.
void main() {
  test(
    'Recent Chats resolve the correct direction when current uid is lexically greater',
    () {
      final result = ChatDirectionResolver.resolveForUser(
        session: <String, dynamic>{
          'participantIds': ['listener_a', 'speaker_z'],
          'pairUserA': 'listener_a',
          'pairUserB': 'speaker_z',
          'speakerId': 'listener_a',
          'listenerId': 'speaker_z',
          'pairKey': 'listener_a_speaker_z',
          'actualListenerId': 'listener_a',
          'requesterId': 'speaker_z',
          'responderId': 'listener_a',
          'pendingFor': '',
          'actionOwner': 'listener_a',
          'callRequestedBy': 'speaker_z',
        },
        myUid: 'speaker_z',
        fallbackSpeakerId: 'listener_a',
        fallbackListenerId: 'speaker_z',
      );

      expect(result.isResolved, true);
      expect(result.actualSpeakerId, 'speaker_z');
      expect(result.actualListenerId, 'listener_a');
      expect(result.otherUid, 'listener_a');
      expect(result.iAmListener, false);
    },
  );
}
