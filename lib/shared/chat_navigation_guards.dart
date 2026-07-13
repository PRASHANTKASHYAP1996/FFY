import 'package:flutter/animation.dart';

class ActiveChatSessionTracker {
  ActiveChatSessionTracker._();

  static final ActiveChatSessionTracker instance = ActiveChatSessionTracker._();

  String _activeSessionId = '';

  void markVisible(String sessionId) {
    final safeSessionId = sessionId.trim();
    if (safeSessionId.isEmpty) return;
    _activeSessionId = safeSessionId;
  }

  void clearVisible(String sessionId) {
    final safeSessionId = sessionId.trim();
    if (safeSessionId.isEmpty) return;
    if (_activeSessionId == safeSessionId) {
      _activeSessionId = '';
    }
  }

  bool isActive(String sessionId) {
    final safeSessionId = sessionId.trim();
    return safeSessionId.isNotEmpty && _activeSessionId == safeSessionId;
  }
}

bool shouldHandleDirectionMismatchInUi({
  required bool directionMatchesRequested,
}) {
  return !directionMatchesRequested;
}

bool shouldShowChatComposerForBootstrap({
  required bool bootstrapping,
  required bool hasBootstrapError,
}) {
  return !bootstrapping && !hasBootstrapError;
}

bool isChatRouteTransitionActive({
  required bool navigatingAway,
  required bool hasRoute,
  required bool routeIsCurrent,
  required AnimationStatus? primaryStatus,
  required AnimationStatus? secondaryStatus,
}) {
  if (navigatingAway) return true;
  if (!hasRoute) return false;
  if (!routeIsCurrent) return true;

  final primaryBusy =
      primaryStatus != null && primaryStatus != AnimationStatus.completed;
  final secondaryBusy =
      secondaryStatus != null && secondaryStatus != AnimationStatus.dismissed;

  return primaryBusy || secondaryBusy;
}

bool selectedListenerMatchesStoredDirection({
  required String selectedListenerId,
  required String actualListenerId,
}) {
  final safeSelectedListenerId = selectedListenerId.trim();
  final safeActualListenerId = actualListenerId.trim();
  if (safeSelectedListenerId.isEmpty || safeActualListenerId.isEmpty) {
    return false;
  }
  return safeSelectedListenerId == safeActualListenerId;
}

bool isSafeChatPushDirection({
  required String speakerId,
  required String listenerId,
  required String actualListenerId,
  required String myUid,
}) {
  final safeSpeakerId = speakerId.trim();
  final safeListenerId = listenerId.trim();
  final safeActualListenerId = actualListenerId.trim();
  final safeMyUid = myUid.trim();

  if (safeSpeakerId.isEmpty || safeListenerId.isEmpty) return false;
  if (safeSpeakerId == safeListenerId) return false;
  if (safeActualListenerId.isEmpty) return false;
  if (safeMyUid.isEmpty) return false;
  if (safeMyUid != safeSpeakerId && safeMyUid != safeListenerId) return false;
  if (safeListenerId != safeActualListenerId) return false;

  return true;
}
