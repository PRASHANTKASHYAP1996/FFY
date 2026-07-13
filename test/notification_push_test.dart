import 'package:flutter_test/flutter_test.dart';

import 'package:friendify/screens/chat_conversation_screen.dart';
import 'package:friendify/services/notifications_service.dart';

void main() {
  test('Notification unsafe payload does not call navigator.push', () async {
    var pushCalls = 0;

    final didPush = await pushResolvedChatConversation(
      myUid: 'speaker_1',
      speakerId: 'speaker_1',
      listenerId: 'listener_1',
      actualListenerId: '',
      onPush: (_) async {
        pushCalls += 1;
      },
    );

    expect(didPush, isFalse);
    expect(pushCalls, 0);
  });

  test('Notification valid payload opens chat once', () async {
    var pushCalls = 0;
    ChatConversationScreen? pushedScreen;

    final didPush = await pushResolvedChatConversation(
      myUid: 'speaker_1',
      speakerId: 'speaker_1',
      listenerId: 'listener_1',
      actualListenerId: 'listener_1',
      onPush: (screen) async {
        pushCalls += 1;
        pushedScreen = screen;
      },
    );

    expect(didPush, isTrue);
    expect(pushCalls, 1);
    expect(pushedScreen, isNotNull);
    expect(pushedScreen!.speakerId, 'speaker_1');
    expect(pushedScreen!.listenerId, 'listener_1');
    expect(pushedScreen!.actualListenerId, 'listener_1');
    expect(pushedScreen!.iAmListener, isFalse);
  });

  test('Notification refuses mismatched listener direction payload', () async {
    var pushCalls = 0;

    final didPush = await pushResolvedChatConversation(
      myUid: 'speaker_1',
      speakerId: 'speaker_1',
      listenerId: 'listener_1',
      actualListenerId: 'speaker_1',
      onPush: (_) async {
        pushCalls += 1;
      },
    );

    expect(didPush, isFalse);
    expect(pushCalls, 0);
  });
}
