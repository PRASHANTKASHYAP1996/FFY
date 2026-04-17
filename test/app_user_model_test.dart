import 'package:flutter_test/flutter_test.dart';

import 'package:friendify/shared/models/app_user_model.dart';

void main() {
  test('AppUserModel.fromMap applies safe defaults and normalization', () {
    final model = AppUserModel.fromMap({
      'uid': 'u1',
      'email': 'demo@example.com',
      'displayName': ' ',
      'listenerRate': 0,
      'level': 0,
      'topics': [' anxiety ', 'Anxiety', '', 'focus'],
      'languages': ['en', 'EN', 'hi'],
      'favoriteListeners': ['abc', 'ABC', 'xyz'],
    });

    expect(model.safeDisplayName, 'demo');
    expect(model.listenerRate, 5);
    expect(model.level, 1);
    expect(model.topics, ['anxiety', 'focus']);
    expect(model.languages, ['en', 'hi']);
    expect(model.favoriteListeners, ['abc', 'xyz']);
  });
}
