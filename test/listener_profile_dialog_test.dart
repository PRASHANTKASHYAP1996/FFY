import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:friendify/screens/listener_profile_screen.dart';
import 'package:friendify/shared/models/app_user_model.dart';

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
  testWidgets(
    'Listener profile with opposite direction shows controlled dialog',
    (tester) async {
      final user = _testUser(uid: 'listener_1', displayName: 'Taylor');

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              return Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () {
                      showDialog<void>(
                        context: context,
                        builder: (_) => buildExistingConversationDialog(
                          user: user,
                          onGoBack: () {},
                          onOpenConversation: () {},
                        ),
                      );
                    },
                    child: const Text('Show'),
                  ),
                ),
              );
            },
          ),
        ),
      );

      await tester.tap(find.text('Show'));
      await tester.pumpAndSettle();

      expect(find.text('Existing conversation found'), findsOneWidget);
      expect(
        find.textContaining('You already have a conversation with Taylor'),
        findsOneWidget,
      );
      expect(find.text('Open conversation'), findsOneWidget);
      expect(find.text('Go back'), findsOneWidget);
    },
  );
}
