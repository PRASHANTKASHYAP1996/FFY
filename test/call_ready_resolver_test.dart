import 'package:flutter_test/flutter_test.dart';

import 'package:friendify/shared/call_ready_resolver.dart';
import 'package:friendify/shared/models/app_user_model.dart';

/// Fake that reads its answers straight out of the session map, so each test
/// session fully specifies the primitive behaviour and we exercise only the
/// resolver's own composition logic.
class _FakeAccess implements SessionCallAccess {
  @override
  List<String> sessionParticipantIds(Map<String, dynamic> session) {
    final raw = session['participants'];
    return raw is List ? raw.cast<String>() : const <String>[];
  }

  @override
  bool sessionAllowsCallForDirection({
    required Map<String, dynamic> session,
    required String speakerId,
    required String listenerId,
  }) =>
      session['allowDirection'] == true;

  @override
  bool sessionIdentityLooksComplete({
    required Map<String, dynamic> session,
    required String speakerId,
    required String listenerId,
  }) =>
      session['identityComplete'] == true;
}

AppUserModel _listener(String uid) =>
    AppUserModel.fromMap(<String, dynamic>{'uid': uid, 'displayName': uid});

Map<String, dynamic> _session({
  required List<String> participants,
  bool exists = true,
  bool allowDirection = false,
  String status = '',
  String actualListenerId = '',
  bool identityComplete = false,
  bool speakerBlocked = false,
  bool listenerBlocked = false,
}) =>
    <String, dynamic>{
      'exists': exists,
      'participants': participants,
      'allowDirection': allowDirection,
      // Keys mirror FirestorePaths (status / actualListenerId / *Blocked).
      'status': status,
      'actualListenerId': actualListenerId,
      'identityComplete': identityComplete,
      'speakerBlocked': speakerBlocked,
      'listenerBlocked': listenerBlocked,
    };

const _me = 'me';
final _resolver = CallReadyResolver(_FakeAccess());

List<String> _uids(List<AppUserModel> users) =>
    users.map((u) => u.uid).toList();

void main() {
  group('sessionAllowsCallAccess', () {
    test('strict directional approval is enough on its own', () {
      final s = _session(participants: const [_me, 'a'], allowDirection: true);
      expect(
        _resolver.sessionAllowsCallAccess(
            session: s, myUid: _me, listenerId: 'a'),
        isTrue,
      );
    });

    test('accepted + matching listener + complete identity passes', () {
      final s = _session(
        participants: const [_me, 'a'],
        status: 'accepted',
        actualListenerId: 'a',
        identityComplete: true,
      );
      expect(
        _resolver.sessionAllowsCallAccess(
            session: s, myUid: _me, listenerId: 'a'),
        isTrue,
      );
    });

    test('non-accepted status without strict approval fails', () {
      final s = _session(
        participants: const [_me, 'a'],
        status: 'pending',
        actualListenerId: 'a',
        identityComplete: true,
      );
      expect(
        _resolver.sessionAllowsCallAccess(
            session: s, myUid: _me, listenerId: 'a'),
        isFalse,
      );
    });

    test('accepted but the actual listener does not match fails', () {
      final s = _session(
        participants: const [_me, 'a'],
        status: 'accepted',
        actualListenerId: 'someone_else',
        identityComplete: true,
      );
      expect(
        _resolver.sessionAllowsCallAccess(
            session: s, myUid: _me, listenerId: 'a'),
        isFalse,
      );
    });

    test('accepted and matching but incomplete identity fails', () {
      final s = _session(
        participants: const [_me, 'a'],
        status: 'accepted',
        actualListenerId: 'a',
        identityComplete: false,
      );
      expect(
        _resolver.sessionAllowsCallAccess(
            session: s, myUid: _me, listenerId: 'a'),
        isFalse,
      );
    });
  });

  group('callReadyListeners', () {
    test('includes a listener sharing an allowed session', () {
      final ready = _resolver.callReadyListeners(
        myUid: _me,
        listeners: [_listener('a')],
        sessions: [
          _session(participants: const [_me, 'a'], allowDirection: true),
        ],
      );
      expect(_uids(ready), <String>['a']);
    });

    test('excludes self', () {
      final ready = _resolver.callReadyListeners(
        myUid: _me,
        listeners: [_listener(_me)],
        sessions: [
          _session(participants: const [_me, _me], allowDirection: true),
        ],
      );
      expect(ready, isEmpty);
    });

    test('excludes a listener with no shared session', () {
      final ready = _resolver.callReadyListeners(
        myUid: _me,
        listeners: [_listener('a')],
        sessions: const [],
      );
      expect(ready, isEmpty);
    });

    test('ignores sessions that do not exist', () {
      final ready = _resolver.callReadyListeners(
        myUid: _me,
        listeners: [_listener('a')],
        sessions: [
          _session(
              participants: const [_me, 'a'],
              exists: false,
              allowDirection: true),
        ],
      );
      expect(ready, isEmpty);
    });

    test('ignores sessions the current user is not part of', () {
      final ready = _resolver.callReadyListeners(
        myUid: _me,
        listeners: [_listener('a')],
        sessions: [
          _session(participants: const ['x', 'a'], allowDirection: true),
        ],
      );
      expect(ready, isEmpty);
    });

    test('excludes a blocked session even when the direction allows', () {
      final speakerBlocked = _resolver.callReadyListeners(
        myUid: _me,
        listeners: [_listener('a')],
        sessions: [
          _session(
              participants: const [_me, 'a'],
              allowDirection: true,
              speakerBlocked: true),
        ],
      );
      final listenerBlocked = _resolver.callReadyListeners(
        myUid: _me,
        listeners: [_listener('b')],
        sessions: [
          _session(
              participants: const [_me, 'b'],
              allowDirection: true,
              listenerBlocked: true),
        ],
      );
      expect(speakerBlocked, isEmpty);
      expect(listenerBlocked, isEmpty);
    });

    test('excludes a shared session that does not permit calls', () {
      final ready = _resolver.callReadyListeners(
        myUid: _me,
        listeners: [_listener('a')],
        sessions: [
          _session(participants: const [_me, 'a'], status: 'pending'),
        ],
      );
      expect(ready, isEmpty);
    });

    test('excludes listeners with a blank uid', () {
      final ready = _resolver.callReadyListeners(
        myUid: _me,
        listeners: [_listener('')],
        sessions: [
          _session(participants: const [_me, ''], allowDirection: true),
        ],
      );
      expect(ready, isEmpty);
    });

    test('keeps only call-ready listeners and preserves input order', () {
      final ready = _resolver.callReadyListeners(
        myUid: _me,
        listeners: [_listener('a'), _listener('b'), _listener('c')],
        sessions: [
          // c is accepted-and-complete, a is strictly allowed, b is pending.
          _session(
              participants: const [_me, 'c'],
              status: 'accepted',
              actualListenerId: 'c',
              identityComplete: true),
          _session(participants: const [_me, 'a'], allowDirection: true),
          _session(participants: const [_me, 'b'], status: 'pending'),
        ],
      );
      expect(_uids(ready), <String>['a', 'c']);
    });
  });
}
