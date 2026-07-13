import 'package:flutter_test/flutter_test.dart';

import 'package:friendify/core/constants/storage_paths.dart';

void main() {
  test('profilePhoto builds the canonical profile photo path', () {
    expect(
      StoragePaths.profilePhoto('user_123'),
      'profile_photos/user_123/profile.jpg',
    );
  });

  test('profilePhoto trims surrounding whitespace from uid', () {
    expect(
      StoragePaths.profilePhoto('  user_123  '),
      'profile_photos/user_123/profile.jpg',
    );
  });

  test('socialPostImage builds the canonical social upload path', () {
    expect(
      StoragePaths.socialPostImage(
        userId: 'user_123',
        postId: 'post_456',
      ),
      'social_uploads/user_123/post_456.jpg',
    );
  });
}
