import '../core/constants/firestore_paths.dart';

enum ChatDirectionResolutionMode {
  strictStoredDirection,
  legacyRepair,
}

class ChatDirectionResolution {
  const ChatDirectionResolution._({
    required this.participantIds,
    required this.actualSpeakerId,
    required this.actualListenerId,
    required this.otherUid,
    required this.iAmListener,
    required this.errorReason,
  });

  const ChatDirectionResolution.success({
    required List<String> participantIds,
    required String actualSpeakerId,
    required String actualListenerId,
    required String otherUid,
    required bool iAmListener,
  }) : this._(
          participantIds: participantIds,
          actualSpeakerId: actualSpeakerId,
          actualListenerId: actualListenerId,
          otherUid: otherUid,
          iAmListener: iAmListener,
          errorReason: '',
        );

  const ChatDirectionResolution.error(String errorReason)
      : this._(
          participantIds: const <String>[],
          actualSpeakerId: '',
          actualListenerId: '',
          otherUid: '',
          iAmListener: false,
          errorReason: errorReason,
        );

  final List<String> participantIds;
  final String actualSpeakerId;
  final String actualListenerId;
  final String otherUid;
  final bool iAmListener;
  final String errorReason;

  bool get isResolved => errorReason.isEmpty;
}

class ChatDirectionResolver {
  const ChatDirectionResolver._();

  static String _asString(dynamic value, {String fallback = ''}) {
    if (value is String) return value.trim();
    if (value == null) return fallback;
    return value.toString().trim();
  }

  static List<String> participantIds(
    Map<String, dynamic> session, {
    String fallbackSpeakerId = '',
    String fallbackListenerId = '',
  }) {
    final seen = <String>{};
    final ids = <String>[];

    void addId(dynamic value) {
      final safe = _asString(value, fallback: '');
      if (safe.isEmpty || seen.contains(safe)) return;
      seen.add(safe);
      ids.add(safe);
    }

    final rawParticipantIds = session[FirestorePaths.fieldParticipantIds];
    if (rawParticipantIds is List) {
      for (final value in rawParticipantIds) {
        addId(value);
      }
    }

    if (ids.length != 2) {
      ids.clear();
      seen.clear();
      addId(session[FirestorePaths.fieldPairUserA]);
      addId(session[FirestorePaths.fieldPairUserB]);
      addId(session[FirestorePaths.fieldSpeakerId]);
      addId(session[FirestorePaths.fieldListenerId]);
      addId(fallbackSpeakerId);
      addId(fallbackListenerId);
    }

    ids.sort();
    if (ids.length == 2 && ids[0] != ids[1]) {
      return List<String>.unmodifiable(ids);
    }
    return const <String>[];
  }

  static String actualListenerId(
    Map<String, dynamic> session, {
    required String fallbackSpeakerId,
    required String fallbackListenerId,
    ChatDirectionResolutionMode mode =
        ChatDirectionResolutionMode.strictStoredDirection,
  }) {
    final participants = participantIds(
      session,
      fallbackSpeakerId: fallbackSpeakerId,
      fallbackListenerId: fallbackListenerId,
    );
    if (participants.length != 2) {
      return '';
    }

    final directCandidates = <String>[
      _asString(session[FirestorePaths.fieldActualListenerId], fallback: ''),
      _asString(session[FirestorePaths.fieldResponderId], fallback: ''),
      _asString(session[FirestorePaths.fieldPendingFor], fallback: ''),
    ];
    for (final candidate in directCandidates) {
      if (participants.contains(candidate)) {
        return candidate;
      }
    }

    if (mode != ChatDirectionResolutionMode.legacyRepair) {
      return '';
    }

    final requesterId = _asString(
      session[FirestorePaths.fieldRequesterId],
      fallback: _asString(
        session[FirestorePaths.fieldCallRequestedBy],
        fallback: '',
      ),
    );
    if (participants.contains(requesterId)) {
      return participants.firstWhere((uid) => uid != requesterId);
    }

    return '';
  }

  static ChatDirectionResolution resolveForUser({
    required Map<String, dynamic> session,
    required String myUid,
    required String fallbackSpeakerId,
    required String fallbackListenerId,
    ChatDirectionResolutionMode mode =
        ChatDirectionResolutionMode.strictStoredDirection,
  }) {
    final safeMyUid = myUid.trim();
    final ids = participantIds(
      session,
      fallbackSpeakerId: fallbackSpeakerId,
      fallbackListenerId: fallbackListenerId,
    );

    if (ids.length != 2) {
      return const ChatDirectionResolution.error(
        'participantIds are incomplete',
      );
    }
    if (!ids.contains(safeMyUid)) {
      return ChatDirectionResolution.error(
        'current user $safeMyUid is not part of ${ids.join(',')}',
      );
    }

    final resolvedActualListenerId = actualListenerId(
      session,
      fallbackSpeakerId: fallbackSpeakerId,
      fallbackListenerId: fallbackListenerId,
      mode: mode,
    );
    if (!ids.contains(resolvedActualListenerId)) {
      return const ChatDirectionResolution.error(
        'actualListenerId is missing or unsafe',
      );
    }

    final actualSpeakerId = ids.firstWhere(
      (uid) => uid != resolvedActualListenerId,
      orElse: () => '',
    );
    if (actualSpeakerId.isEmpty ||
        actualSpeakerId == resolvedActualListenerId) {
      return const ChatDirectionResolution.error(
        'actual speaker could not be derived',
      );
    }

    final otherUid = ids.firstWhere(
      (uid) => uid != safeMyUid,
      orElse: () => '',
    );
    if (otherUid.isEmpty) {
      return const ChatDirectionResolution.error(
        'other participant could not be derived',
      );
    }

    return ChatDirectionResolution.success(
      participantIds: ids,
      actualSpeakerId: actualSpeakerId,
      actualListenerId: resolvedActualListenerId,
      otherUid: otherUid,
      iAmListener: safeMyUid == resolvedActualListenerId,
    );
  }

  static ChatDirectionResolution resolvePushDirectionForUser({
    required List<String> participantIds,
    required String myUid,
    required String actualListenerId,
  }) {
    final safeMyUid = myUid.trim();
    final normalizedIds = participantIds
        .map((uid) => uid.trim())
        .where((uid) => uid.isNotEmpty)
        .toSet()
        .toList()
      ..sort();

    if (normalizedIds.length != 2) {
      return const ChatDirectionResolution.error(
        'participantIds are incomplete',
      );
    }
    if (!normalizedIds.contains(safeMyUid)) {
      return ChatDirectionResolution.error(
        'current user $safeMyUid is not part of ${normalizedIds.join(',')}',
      );
    }

    final safeActualListenerId = actualListenerId.trim();
    if (!normalizedIds.contains(safeActualListenerId)) {
      return const ChatDirectionResolution.error(
        'actualListenerId is missing or unsafe',
      );
    }

    final actualSpeakerId = normalizedIds.firstWhere(
      (uid) => uid != safeActualListenerId,
      orElse: () => '',
    );
    if (actualSpeakerId.isEmpty || actualSpeakerId == safeActualListenerId) {
      return const ChatDirectionResolution.error(
        'actual speaker could not be derived',
      );
    }

    final otherUid = normalizedIds.firstWhere(
      (uid) => uid != safeMyUid,
      orElse: () => '',
    );
    if (otherUid.isEmpty) {
      return const ChatDirectionResolution.error(
        'other participant could not be derived',
      );
    }

    return ChatDirectionResolution.success(
      participantIds: normalizedIds,
      actualSpeakerId: actualSpeakerId,
      actualListenerId: safeActualListenerId,
      otherUid: otherUid,
      iAmListener: safeMyUid == safeActualListenerId,
    );
  }
}
