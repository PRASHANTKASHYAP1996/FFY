import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:friendify/screens/chat_conversation_screen.dart';

void main() {
  testWidgets(
    'composer becomes visible after pushed chat route settles',
    (tester) async {
      const composerKey = ValueKey<String>('composer_visible');
      const hiddenKey = ValueKey<String>('composer_hidden');

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              return Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () {
                      Navigator.of(context).push(
                        PageRouteBuilder<void>(
                          transitionDuration: const Duration(milliseconds: 250),
                          reverseTransitionDuration:
                              const Duration(milliseconds: 250),
                          pageBuilder: (_, __, ___) {
                            return const Scaffold(
                              body: Align(
                                alignment: Alignment.bottomCenter,
                                child: ChatComposerVisibilityGate(
                                  bootstrapping: false,
                                  hasBootstrapError: false,
                                  navigatingAway: false,
                                  hiddenChild: SizedBox(key: hiddenKey),
                                  child: SizedBox(key: composerKey),
                                ),
                              ),
                            );
                          },
                        ),
                      );
                    },
                    child: const Text('Open chat'),
                  ),
                ),
              );
            },
          ),
        ),
      );

      await tester.tap(find.text('Open chat'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byKey(hiddenKey), findsOneWidget);
      expect(find.byKey(composerKey), findsNothing);

      await tester.pumpAndSettle();

      expect(find.byKey(composerKey), findsOneWidget);
      expect(find.byKey(hiddenKey), findsNothing);
    },
  );
}
