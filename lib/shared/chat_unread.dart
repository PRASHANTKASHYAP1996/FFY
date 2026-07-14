import '../core/constants/firestore_paths.dart';

/// Pure unread-message math for chat sessions, extracted from the shell so the
/// Chats-tab badge count can be unit tested. The current user's unread counter
/// is chosen by which side of the session they are on.
class ChatUnread {
  const ChatUnread._();

  /// Unread messages for [myUid] in a single [session]: the speaker counter
  /// when they are the speaker, otherwise the listener counter. Missing or
  /// non-numeric values count as zero.
  static int unreadFor(Map<String, dynamic> session, String myUid) {
    final raw = session[FirestorePaths.fieldSpeakerId] == myUid
        ? session[FirestorePaths.fieldSpeakerUnreadCount]
        : session[FirestorePaths.fieldListenerUnreadCount];
    return raw is num && raw > 0 ? raw.toInt() : 0;
  }

  /// How many conversations have at least one unread message for [myUid] — the
  /// number shown on the Chats tab badge.
  static int conversationsWithUnread(
    List<Map<String, dynamic>> sessions,
    String myUid,
  ) {
    var count = 0;
    for (final session in sessions) {
      if (unreadFor(session, myUid) > 0) count++;
    }
    return count;
  }
}
