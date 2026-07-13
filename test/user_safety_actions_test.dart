import 'package:flutter_test/flutter_test.dart';
import 'package:friendify/shared/user_safety_actions.dart';

void main() {
  group('userSafetyBlockApplies', () {
    test('returns true when I blocked the other user', () {
      expect(
        userSafetyBlockApplies(
          myUid: 'me',
          otherUserId: 'other',
          myBlockedUserIds: const ['other'],
          otherBlockedUserIds: const [],
        ),
        isTrue,
      );
    });

    test('returns true when the other user blocked me', () {
      expect(
        userSafetyBlockApplies(
          myUid: 'me',
          otherUserId: 'other',
          myBlockedUserIds: const [],
          otherBlockedUserIds: const ['me'],
        ),
        isTrue,
      );
    });

    test('returns false when neither user is blocked', () {
      expect(
        userSafetyBlockApplies(
          myUid: 'me',
          otherUserId: 'other',
          myBlockedUserIds: const ['someone-else'],
          otherBlockedUserIds: const ['another-user'],
        ),
        isFalse,
      );
    });
  });
}
