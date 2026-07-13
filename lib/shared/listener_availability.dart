enum ListenerAvailabilityKind {
  available,
  onAnotherCall,
  checking,
  offline,
}

class ListenerAvailabilityResult {
  const ListenerAvailabilityResult({
    required this.kind,
    required this.label,
    required this.reason,
    required this.isOnline,
    required this.canCallNow,
  });

  final ListenerAvailabilityKind kind;
  final String label;
  final String reason;
  final bool isOnline;
  final bool canCallNow;

  String get debugName {
    switch (kind) {
      case ListenerAvailabilityKind.available:
        return 'available';
      case ListenerAvailabilityKind.onAnotherCall:
        return 'on_another_call';
      case ListenerAvailabilityKind.checking:
        return 'checking';
      case ListenerAvailabilityKind.offline:
        return 'offline';
    }
  }
}

class ListenerAvailabilityResolver {
  ListenerAvailabilityResolver._();

  static const Duration onlineWindow = Duration(minutes: 10);

  static ListenerAvailabilityResult resolve({
    required bool isAvailable,
    required bool isOnCall,
    required String activeCallId,
    required DateTime? lastSeen,
    DateTime? now,
  }) {
    final safeNow = now ?? DateTime.now();
    final safeActiveCallId = activeCallId.trim();
    final hasCallLock = safeActiveCallId.isNotEmpty || isOnCall;
    final online = _isOnline(lastSeen, safeNow);

    if (hasCallLock) {
      return const ListenerAvailabilityResult(
        kind: ListenerAvailabilityKind.onAnotherCall,
        label: 'On another call',
        reason: 'active_call_lock',
        isOnline: true,
        canCallNow: false,
      );
    }

    if (isAvailable && online) {
      return const ListenerAvailabilityResult(
        kind: ListenerAvailabilityKind.available,
        label: 'Available',
        reason: 'listener_available_and_recent',
        isOnline: true,
        canCallNow: true,
      );
    }

    if (lastSeen == null) {
      return ListenerAvailabilityResult(
        kind: ListenerAvailabilityKind.checking,
        label: 'Checking...',
        reason: isAvailable
            ? 'missing_last_seen_for_available_listener'
            : 'missing_last_seen_for_unavailable_listener',
        isOnline: false,
        canCallNow: false,
      );
    }

    return ListenerAvailabilityResult(
      kind: ListenerAvailabilityKind.offline,
      label: formatLastSeen(lastSeen, now: safeNow),
      reason: isAvailable
          ? 'availability_stale_from_last_seen'
          : 'listener_marked_unavailable',
      isOnline: false,
      canCallNow: false,
    );
  }

  static bool _isOnline(DateTime? lastSeen, DateTime now) {
    if (lastSeen == null) return false;
    final age = now.difference(lastSeen);
    if (age.isNegative) return true;
    return age <= onlineWindow;
  }

  static String formatLastSeen(DateTime lastSeen, {DateTime? now}) {
    final safeNow = now ?? DateTime.now();
    final age = safeNow.difference(lastSeen);
    if (age.isNegative || age.inMinutes < 30) {
      return 'Last seen recently';
    }
    if (age.inHours < 24) {
      return 'Last seen today';
    }
    if (age.inDays < 7) {
      return 'Last seen this week';
    }
    return 'Last seen a while ago';
  }
}
