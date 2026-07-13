import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:friendify/core/constants/firestore_paths.dart';
import 'package:friendify/screens/chat_conversation_screen.dart';

void main() {
  Future<void> pumpMessageTile(
    WidgetTester tester, {
    required Map<String, dynamic> message,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: buildChatMessageTileForTest(
            message: message,
            myUid: 'speaker_1',
          ),
        ),
      ),
    );
  }

  testWidgets(
    'access event types render as centered system tiles',
    (tester) async {
      const accessCases = <({String type, String text})>[
        (
          type: FirestorePaths.messageTypeAccessRequest,
          text: 'Chat request sent',
        ),
        (
          type: FirestorePaths.messageTypeAccessApproved,
          text: 'Call access allowed',
        ),
        (
          type: FirestorePaths.messageTypeAccessDenied,
          text: 'Call access denied',
        ),
      ];

      for (final accessCase in accessCases) {
        await pumpMessageTile(
          tester,
          message: <String, dynamic>{
            FirestorePaths.fieldMessageType: accessCase.type,
            FirestorePaths.fieldMessageText: accessCase.text,
            FirestorePaths.fieldMessageSenderId: 'speaker_1',
            FirestorePaths.fieldMessageCreatedAtMs: 0,
          },
        );

        expect(find.byKey(chatSystemTileKey), findsOneWidget);
        expect(find.byKey(chatMessageBubbleKey), findsNothing);
        expect(find.text(accessCase.text), findsOneWidget);
      }
    },
  );

  testWidgets('regular text messages still render as chat bubbles', (
    tester,
  ) async {
    await pumpMessageTile(
      tester,
      message: <String, dynamic>{
        FirestorePaths.fieldMessageType: FirestorePaths.messageTypeText,
        FirestorePaths.fieldMessageText: 'Hello there',
        FirestorePaths.fieldMessageSenderId: 'speaker_1',
        FirestorePaths.fieldMessageSeen: true,
        FirestorePaths.fieldMessageCreatedAtMs: 0,
      },
    );

    expect(find.byKey(chatMessageBubbleKey), findsOneWidget);
    expect(find.byKey(chatSystemTileKey), findsNothing);
    expect(find.text('Hello there'), findsOneWidget);
  });
}
