import '../core/constants/firestore_paths.dart';
import 'models/app_user_model.dart';

/// The session-inspection primitives the resolver needs. In production these
/// are satisfied by an adapter over CallRepository (all pure map logic); tests
/// supply a fake. Keeping the resolver behind this interface keeps it free of
/// Firebase so it can be unit tested.
abstract class SessionCallAccess {
  /// The two distinct participant uids of a chat session (empty if malformed).
  List<String> sessionParticipantIds(Map<String, dynamic> session);

  /// Whether the session's stored direction strictly permits the given speaker
  /// to call the given listener.
  bool sessionAllowsCallForDirection({
    required Map<String, dynamic> session,
    required String speakerId,
    required String listenerId,
  });

  /// Whether the session's identity contract is complete for this pairing.
  bool sessionIdentityLooksComplete({
    required Map<String, dynamic> session,
    required String speakerId,
    required String listenerId,
  });
}

/// Pure logic for the Call tab's "Quick call" list: which available listeners
/// the current user already has an accepted, call-allowed chat session with.
///
/// Extracted verbatim from _CallPageState so the access rules can be unit
/// tested; the only dependency is [SessionCallAccess].
class CallReadyResolver {
  const CallReadyResolver(this.access);

  final SessionCallAccess access;

  /// The subset of [listeners] the current user ([myUid]) can quick-call:
  /// they share a session, it is not blocked, and it allows calls in this
  /// direction. Input order is preserved; self is excluded.
  List<AppUserModel> callReadyListeners({
    required String myUid,
    required List<AppUserModel> listeners,
    required List<Map<String, dynamic>> sessions,
  }) {
    final candidates = listeners
        .where((u) => u.uid.trim().isNotEmpty && u.uid != myUid)
        .toList(growable: false);

    final sessionByListener = <String, Map<String, dynamic>>{};
    for (final session in sessions) {
      if (session['exists'] != true) continue;
      final ids = access.sessionParticipantIds(session).toSet();
      if (!ids.contains(myUid)) continue;
      for (final listener in candidates) {
        if (ids.contains(listener.uid)) {
          sessionByListener[listener.uid] = session;
        }
      }
    }

    return candidates.where((listener) {
      final session = sessionByListener[listener.uid];
      if (session == null) return false;
      final blocked = session[FirestorePaths.fieldSpeakerBlocked] == true ||
          session[FirestorePaths.fieldListenerBlocked] == true;
      if (blocked) return false;
      return sessionAllowsCallAccess(
        session: session,
        myUid: myUid,
        listenerId: listener.uid,
      );
    }).toList(growable: false);
  }

  /// Whether [session] permits [myUid] to call [listenerId]: either the stored
  /// direction strictly allows it, or the session is accepted with a matching,
  /// complete identity contract.
  bool sessionAllowsCallAccess({
    required Map<String, dynamic> session,
    required String myUid,
    required String listenerId,
  }) {
    final strictAllowed = access.sessionAllowsCallForDirection(
      session: session,
      speakerId: myUid,
      listenerId: listenerId,
    );
    if (strictAllowed) return true;

    final status = (session[FirestorePaths.fieldChatStatus] ?? '').toString();
    if (status != FirestorePaths.chatStatusAccepted) return false;

    final actualListenerId =
        (session[FirestorePaths.fieldActualListenerId] ?? '').toString().trim();
    return actualListenerId == listenerId.trim() &&
        access.sessionIdentityLooksComplete(
          session: session,
          speakerId: myUid,
          listenerId: listenerId,
        );
  }
}
