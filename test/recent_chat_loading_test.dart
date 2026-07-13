import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:friendify/screens/home_screen.dart';

void main() {
  testWidgets(
    'Recent Chats loading state hides the Conversation placeholder',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 220,
                child: buildRecentChatPartnerName(
                  otherUser: null,
                  loading: true,
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.text('Conversation'), findsNothing);
      expect(find.byKey(recentChatPartnerLoadingNameKey), findsOneWidget);
    },
  );
}
