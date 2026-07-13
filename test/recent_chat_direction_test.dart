import 'package:flutter_test/flutter_test.dart';

import 'package:friendify/screens/home_screen.dart';
import 'package:friendify/shared/models/app_user_model.dart';
import 'package:friendify/shared/chat_direction_resolver.dart';

AppUserModel _testUser({
  required String uid,
  required String displayName,
}) {
  return AppUserModel(
    uid: uid,
    email: '$uid@example.com',
    displayName: displayName,
    credits: 0,
    reservedCredits: 0,
    earningsCredits: 0,
    platformRevenueCredits: 0,
    photoURL: '',
    bio: '',
    gender: '',
    city: '',
    state: '',
    country: '',
    topics: const <String>[],
    languages: const <String>[],
    isListener: true,
    isAvailable: true,
    followersCount: 0,
    level: 1,
    listenerRate: 5,
    following: const <String>[],
    blocked: const <String>[],
    fcmTokens: const <String>[],
    favoriteListeners: const <String>[],
    activeCallId: '',
    ratingAvg: 0,
    ratingCount: 0,
    ratingSum: 0,
    createdAt: null,
    lastSeen: null,
  );
}

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

  test('Recent Chats destination uses actual speaker and listener ids', () {
    const direction = ChatDirectionResolution.success(
      participantIds: <String>['listener_a', 'speaker_z'],
      actualSpeakerId: 'speaker_z',
      actualListenerId: 'listener_a',
      otherUid: 'listener_a',
      iAmListener: false,
    );

    final screen = buildRecentChatsConversationScreen(direction: direction);

    expect(screen.speakerId, 'speaker_z');
    expect(screen.listenerId, 'listener_a');
    expect(screen.actualListenerId, 'listener_a');
    expect(screen.iAmListener, isFalse);
  });

  test(
    'Recent Chats navigation resolves initialOtherUser before opening',
    () async {
      const direction = ChatDirectionResolution.success(
        participantIds: <String>['listener_a', 'speaker_z'],
        actualSpeakerId: 'speaker_z',
        actualListenerId: 'listener_a',
        otherUid: 'listener_a',
        iAmListener: false,
      );
      final listener = _testUser(uid: 'listener_a', displayName: 'Taylor');

      final screen = await buildRecentChatsConversationScreenWithResolvedUser(
        direction: direction,
        otherUid: 'listener_a',
        resolveOtherUser: (uid) async {
          expect(uid, 'listener_a');
          return listener;
        },
      );

      expect(screen.initialOtherUser, same(listener));
      expect(screen.speakerId, 'speaker_z');
      expect(screen.listenerId, 'listener_a');
    },
  );
}
