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

  group('stays keyed to the raw speaker/listener fields (matches backend)', () {
    // INVARIANT — do not "fix" this with ChatDirectionResolver.
    //
    // The backend (functions/src/triggers.js -> unreadFieldForUser) increments
    // speakerUnreadCount / listenerUnreadCount purely by which RAW field
    // (session.speakerId / session.listenerId) holds the receiver's uid — not
    // by resolved display roles. So the read side must use the same raw fields,
    // or it reads the other participant's counter.
    //
    // This fixture has swapped-looking roles: my uid ('speaker_z') sits in the
    // listenerId field, while an unrelated uid is the speakerId. Reading my
    // unread must therefore follow the raw listenerId -> listenerUnreadCount.
    // ChatDirectionResolver would report iAmListener == false here (see
    // recent_chat_direction_test) and pick speakerUnreadCount — the wrong one.
    test('reads the counter for the raw field that holds my uid', () {
      final session = <String, dynamic>{
        'speakerId': 'listener_a', // not me
        'listenerId': 'speaker_z', // me
        'speakerUnreadCount': 5, // the other participant's unread
        'listenerUnreadCount': 2, // mine
      };
      expect(ChatUnread.unreadFor(session, 'speaker_z'), 2);
      expect(
        ChatUnread.conversationsWithUnread(<Map<String, dynamic>>[session], 'speaker_z'),
        1,
      );
    });
  });
}
