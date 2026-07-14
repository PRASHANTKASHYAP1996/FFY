import 'package:flutter_test/flutter_test.dart';

import 'package:friendify/shared/chat_unread.dart';

Map<String, dynamic> _session({
  String speakerId = 'speaker',
  Object? speakerUnread,
  Object? listenerUnread,
}) =>
    <String, dynamic>{
      'speakerId': speakerId,
      if (speakerUnread != null) 'speakerUnreadCount': speakerUnread,
      if (listenerUnread != null) 'listenerUnreadCount': listenerUnread,
    };

void main() {
  group('unreadFor', () {
    test('reads the speaker counter when I am the speaker', () {
      final s = _session(speakerId: 'me', speakerUnread: 3, listenerUnread: 9);
      expect(ChatUnread.unreadFor(s, 'me'), 3);
    });

    test('reads the listener counter when I am not the speaker', () {
      final s = _session(speakerId: 'other', speakerUnread: 3, listenerUnread: 9);
      expect(ChatUnread.unreadFor(s, 'me'), 9);
    });

    test('missing counter is zero', () {
      expect(ChatUnread.unreadFor(_session(speakerId: 'me'), 'me'), 0);
    });

    test('non-numeric counter is zero', () {
      final s = _session(speakerId: 'me', speakerUnread: 'lots');
      expect(ChatUnread.unreadFor(s, 'me'), 0);
    });

    test('negative counter clamps to zero', () {
      final s = _session(speakerId: 'me', speakerUnread: -2);
      expect(ChatUnread.unreadFor(s, 'me'), 0);
    });

    test('a double counter is truncated to an int', () {
      final s = _session(speakerId: 'me', speakerUnread: 2.9);
      expect(ChatUnread.unreadFor(s, 'me'), 2);
    });
  });

  group('conversationsWithUnread', () {
    test('counts only conversations with unread for me', () {
      final sessions = <Map<String, dynamic>>[
        _session(speakerId: 'me', speakerUnread: 1), // mine, unread -> count
        _session(speakerId: 'me', speakerUnread: 0), // mine, read -> skip
        _session(speakerId: 'other', listenerUnread: 4), // I'm listener -> count
        _session(speakerId: 'other', speakerUnread: 7), // their unread, not mine
      ];
      expect(ChatUnread.conversationsWithUnread(sessions, 'me'), 2);
    });

    test('counts conversations, not total messages', () {
      final sessions = <Map<String, dynamic>>[
        _session(speakerId: 'me', speakerUnread: 5),
        _session(speakerId: 'me', speakerUnread: 12),
      ];
      expect(ChatUnread.conversationsWithUnread(sessions, 'me'), 2);
    });

    test('empty list is zero', () {
      expect(ChatUnread.conversationsWithUnread(const [], 'me'), 0);
    });
  });
}
