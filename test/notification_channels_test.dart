import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:friendify/services/notification_channels.dart';

void main() {
  test('Chat messages notification channel matches backend contract', () {
    const channel = friendifyChatMessagesChannel;

    expect(friendifyChatMessagesChannelId, 'chat_messages');
    expect(channel.id, friendifyChatMessagesChannelId);
    expect(channel.name, friendifyChatMessagesChannelName);
    expect(channel.description, friendifyChatMessagesChannelDescription);
    expect(channel.importance, Importance.defaultImportance);
  });
}
