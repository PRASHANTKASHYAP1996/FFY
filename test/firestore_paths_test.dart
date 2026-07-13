import 'package:flutter_test/flutter_test.dart';

import 'package:friendify/core/constants/firestore_paths.dart';

void main() {
  test('chatSessionDoc canonicalizes user pair order', () {
    final pathA = FirestorePaths.chatSessionDoc(
      speakerId: 'user_b',
      listenerId: 'user_a',
    );
    final pathB = FirestorePaths.chatSessionDoc(
      speakerId: 'user_a',
      listenerId: 'user_b',
    );

    expect(pathA, 'chat_sessions/user_a_user_b');
    expect(pathB, 'chat_sessions/user_a_user_b');
  });

  test('socialPostDoc builds the canonical social post path', () {
    expect(
      FirestorePaths.socialPostDoc('post_123'),
      'social_posts/post_123',
    );
  });
}
