import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/constants/firestore_paths.dart';
import '../core/theme/app_palette.dart';
import '../repositories/call_repository.dart';
import '../repositories/user_repository.dart';
import '../services/call_session_manager.dart';
import '../services/firestore_service.dart';
import '../shared/chat_direction_resolver.dart';
import '../shared/chat_navigation_guards.dart';
import '../shared/models/app_user_model.dart';
import '../shared/user_safety_actions.dart';
import 'caller_waiting_screen.dart';
import 'chat_conversation_screen.dart';
import 'crisis_help_screen.dart';
import 'voice_call_screen.dart';

String _listenerProfileSafeName(AppUserModel user) {
  final name = user.displayName.trim();
  return name.isEmpty ? 'Listener' : name;
}

@visibleForTesting
AlertDialog buildConversationRepairDialog({
  required AppUserModel user,
  required VoidCallback onGoBack,
}) {
  return AlertDialog(
    title: const Text('This conversation needs repair'),
    content: Text(
      'We could not confirm the saved speaker/listener direction for your '
      'conversation with ${_listenerProfileSafeName(user)}. Please go back '
      'and repair it before opening this chat.',
    ),
    actions: [
      FilledButton(
        onPressed: onGoBack,
        child: const Text('Go back'),
      ),
    ],
  );
}

@visibleForTesting
AlertDialog buildExistingConversationDialog({
  required AppUserModel user,
  required VoidCallback onGoBack,
  required VoidCallback onOpenConversation,
}) {
  return AlertDialog(
    title: const Text('Existing conversation found'),
    content: Text(
      'You already have a conversation with ${_listenerProfileSafeName(user)} '
      'from the other side of this connection. You can open that conversation '
      'safely or go back.',
    ),
    actions: [
      TextButton(
        onPressed: onGoBack,
        child: const Text('Go back'),
      ),
      FilledButton(
        onPressed: onOpenConversation,
        child: const Text('Open conversation'),
      ),
    ],
  );
}

class ListenerProfileScreen extends StatefulWidget {
  final String listenerId;
  final AppUserModel? initialUser;

  const ListenerProfileScreen({
    super.key,
    required this.listenerId,
    this.initialUser,
  });

  @override
  State<ListenerProfileScreen> createState() => _ListenerProfileScreenState();
}

class _ListenerProfileScreenState extends State<ListenerProfileScreen> {
  final UserRepository _userRepository = UserRepository.instance;
  final CallRepository _callRepository = CallRepository.instance;
  final CallSessionManager _callSession = CallSessionManager.instance;

  String _followingWorkingFor = '';
  String _favoriteWorkingFor = '';
  String _callingFor = '';
  final String _requestingAccessFor = '';
  bool _callStartInFlight = false;
  bool _reportingUser = false;
  bool _blockingUser = false;

  void _showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  Future<void> _showConversationRepairDialog(AppUserModel user) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return buildConversationRepairDialog(
          user: user,
          onGoBack: () => Navigator.of(dialogContext).pop(),
        );
      },
    );
  }

  Future<bool> _showExistingConversationDialog(AppUserModel user) async {
    if (!mounted) return false;
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return buildExistingConversationDialog(
          user: user,
          onGoBack: () => Navigator.of(dialogContext).pop(false),
          onOpenConversation: () => Navigator.of(dialogContext).pop(true),
        );
      },
    );
    return result == true;
  }

  String _safeName(AppUserModel user) {
    return _listenerProfileSafeName(user);
  }

  List<String> _safeStringList(List<String> value) {
    final seen = <String>{};
    final out = <String>[];

    for (final item in value) {
      final safe = item.trim();
      if (safe.isEmpty) continue;

      final key = safe.toLowerCase();
      if (seen.contains(key)) continue;

      seen.add(key);
      out.add(safe);
    }

    return out;
  }

  bool _hasAnyActionRunning() {
    return _followingWorkingFor.isNotEmpty ||
        _favoriteWorkingFor.isNotEmpty ||
        _callingFor.isNotEmpty ||
        _requestingAccessFor.isNotEmpty ||
        _callStartInFlight ||
        _reportingUser ||
        _blockingUser;
  }

  bool get _hasBlockingCallState =>
      _callSession.active ||
      _callSession.state == CallState.preparing ||
      _callSession.state == CallState.joining ||
      _callSession.state == CallState.reconnecting ||
      _callSession.state == CallState.ending;

  String _ratingLabel(num avg) => avg.toStringAsFixed(1);

  String _humanizeFunctionError(Object e) {
    return _callRepository.humanizeCallActionError(e);
  }

  String _canonicalSessionDocId({
    required String speakerId,
    required String listenerId,
  }) {
    return _callRepository.chatSessionIdForPair(
      speakerId: speakerId,
      listenerId: listenerId,
    );
  }

  bool _sessionExists(Map<String, dynamic> session) {
    return session['exists'] == true;
  }

  bool _sessionBlocked(Map<String, dynamic> session) {
    return session[FirestorePaths.fieldListenerBlocked] == true ||
        session[FirestorePaths.fieldSpeakerBlocked] == true ||
        session['listenerBlocked'] == true ||
        session['speakerBlocked'] == true;
  }

  bool _sessionCallAllowedForDirection({
    required AppUserModel me,
    required AppUserModel user,
    required Map<String, dynamic> session,
  }) {
    final strictAllowed = _callRepository.sessionAllowsCallForDirection(
      session: session,
      speakerId: me.uid,
      listenerId: user.uid,
    );
    if (strictAllowed) return true;

    final status = (session[FirestorePaths.fieldChatStatus] ?? '').toString();
    if (status != FirestorePaths.chatStatusAccepted) return false;

    final actualListenerId =
        (session[FirestorePaths.fieldActualListenerId] ?? '').toString().trim();
    return actualListenerId == user.uid.trim() &&
        _sessionIdentityLooksComplete(me: me, user: user, session: session);
  }

  bool _sessionIdentityLooksComplete({
    required AppUserModel me,
    required AppUserModel user,
    required Map<String, dynamic> session,
  }) {
    return _callRepository.sessionIdentityLooksComplete(
      session: session,
      speakerId: me.uid,
      listenerId: user.uid,
    );
  }

  bool _sessionLooksCanonical({
    required AppUserModel me,
    required AppUserModel user,
    required Map<String, dynamic> session,
  }) {
    if (!_sessionIdentityLooksComplete(me: me, user: user, session: session)) {
      return false;
    }
    return _callRepository.sessionDirectionLooksComplete(
      session: session,
      speakerId: me.uid,
      listenerId: user.uid,
    );
  }

  bool _canRequestAccess({
    required AppUserModel me,
    required AppUserModel user,
    required Map<String, dynamic> session,
  }) {
    if (_hasAnyActionRunning()) return false;
    if (_hasBlockingCallState) return false;
    if (me.uid == user.uid) return false;
    if (me.blocked.contains(user.uid)) return false;
    if (!_sessionLooksCanonical(me: me, user: user, session: session)) {
      return false;
    }
    if (_sessionBlocked(session)) {
      return false;
    }
    return true;
  }

  bool _canCallNow({
    required AppUserModel me,
    required AppUserModel user,
    required Map<String, dynamic> session,
  }) {
    if (_hasAnyActionRunning()) return false;
    if (_hasBlockingCallState) return false;
    if (me.uid == user.uid) return false;
    if (me.blocked.contains(user.uid)) return false;
    if (!_sessionLooksCanonical(me: me, user: user, session: session)) {
      return false;
    }
    if (_sessionBlocked(session)) {
      return false;
    }
    if (!_sessionCallAllowedForDirection(
        me: me, user: user, session: session)) {
      return false;
    }
    return true;
  }

  Future<void> _toggleFollow({
    required String listenerId,
    required bool isFollowing,
  }) async {
    if (_hasAnyActionRunning() || _hasBlockingCallState) return;

    setState(() => _followingWorkingFor = listenerId);

    try {
      if (isFollowing) {
        await _userRepository.unfollowUser(listenerId);
      } else {
        await _userRepository.followUser(listenerId);
      }
    } catch (_) {
      _showSnack('Follow action failed. Please try again.');
    }

    if (!mounted) return;
    setState(() => _followingWorkingFor = '');
  }

  Future<void> _toggleFavorite({
    required String listenerId,
    required bool isFavorite,
  }) async {
    if (_hasAnyActionRunning() || _hasBlockingCallState) return;

    setState(() => _favoriteWorkingFor = listenerId);

    try {
      await _userRepository.toggleFavoriteListener(
        listenerId: listenerId,
        isFavoriteNow: isFavorite,
      );
    } catch (_) {
      _showSnack('Favorite action failed. Please try again.');
    }

    if (!mounted) return;
    setState(() => _favoriteWorkingFor = '');
  }

  Future<String> _recentSharedCallId(String otherUserId) async {
    final safeOtherUserId = otherUserId.trim();
    final myUid = _userRepository.myUidOrNull ?? '';
    if (safeOtherUserId.isEmpty || myUid.isEmpty) return '';

    final activeCallId = _callSession.callDocRef?.id.trim() ?? '';
    if (activeCallId.isNotEmpty) {
      final activeCall = _callSession.call;
      final callerId =
          (activeCall[FirestorePaths.fieldCallerId] ?? '').toString().trim();
      final calleeId =
          (activeCall[FirestorePaths.fieldCalleeId] ?? '').toString().trim();
      final matchesActiveCall =
          (callerId == myUid && calleeId == safeOtherUserId) ||
              (callerId == safeOtherUserId && calleeId == myUid);
      if (matchesActiveCall) {
        return activeCallId;
      }
    }

    final recentCalls = await _callRepository.fetchRecentCalls(limit: 50);
    for (final call in recentCalls) {
      final matches =
          (call.callerId == myUid && call.calleeId == safeOtherUserId) ||
              (call.callerId == safeOtherUserId && call.calleeId == myUid);
      if (matches) {
        return call.id.trim();
      }
    }

    return '';
  }

  Future<void> _openHelp() async {
    if (!mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const CrisisHelpScreen(),
      ),
    );
  }

  Future<void> _reportUser(AppUserModel user) async {
    if (_reportingUser) return;

    final reason = await showUserSafetyReportReasonSheet(
      context,
      title: 'Report user',
    );
    if (!mounted) return;
    if (reason == null || reason.trim().isEmpty) return;

    setState(() => _reportingUser = true);

    try {
      final callId = await _recentSharedCallId(user.uid);
      if (callId.isEmpty) {
        _showSnack('Report is available after you have a call with this user.');
        return;
      }

      await FirestoreService.report(
        reportedUserId: user.uid,
        callId: callId,
        reason: reason,
      );

      _showSnack('Report submitted.');
    } catch (e) {
      _showSnack('Report failed. Please try again.');
      if (kDebugMode) {
        debugPrint('Listener profile report failed: ${e.runtimeType}');
      }
    } finally {
      if (mounted) {
        setState(() => _reportingUser = false);
      } else {
        _reportingUser = false;
      }
    }
  }

  Future<void> _blockUser(AppUserModel user) async {
    if (_blockingUser) return;

    final confirmed = await showBlockUserConfirmationDialog(
      context,
      userName: userSafetyDisplayName(user, fallback: 'this user'),
    );
    if (!mounted || !confirmed) return;

    setState(() => _blockingUser = true);

    try {
      await FirestoreService.blockUser(user.uid);
      _showSnack('User blocked. Chat unavailable.');
    } catch (e) {
      _showSnack('Could not block this user. Please try again.');
      if (kDebugMode) {
        debugPrint('Listener profile block failed: ${e.runtimeType}');
      }
    } finally {
      if (mounted) {
        setState(() => _blockingUser = false);
      } else {
        _blockingUser = false;
      }
    }
  }

  Map<String, dynamic> _sessionWithSafetyOverrides({
    required AppUserModel me,
    required AppUserModel user,
    required Map<String, dynamic> session,
  }) {
    final blockedByUsers = userSafetyBlockApplies(
      myUid: me.uid,
      otherUserId: user.uid,
      myBlockedUserIds: me.blocked,
      otherBlockedUserIds: user.blocked,
    );

    if (!blockedByUsers) return session;

    return <String, dynamic>{
      ...session,
      FirestorePaths.fieldSpeakerBlocked: true,
      FirestorePaths.fieldListenerBlocked: true,
    };
  }

  // ignore: unused_element
  List<Widget> _buildSafetyActions(AppUserModel user) {
    return [
      PopupMenuButton<UserSafetyAction>(
        tooltip: 'Safety actions',
        onSelected: (action) async {
          switch (action) {
            case UserSafetyAction.reportUser:
              await _reportUser(user);
              break;
            case UserSafetyAction.blockUser:
              await _blockUser(user);
              break;
            case UserSafetyAction.help:
              await _openHelp();
              break;
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem<UserSafetyAction>(
            value: UserSafetyAction.reportUser,
            enabled: !_reportingUser,
            child: const Text('Report user'),
          ),
          PopupMenuItem<UserSafetyAction>(
            value: UserSafetyAction.blockUser,
            enabled: !_blockingUser,
            child: const Text('Block user'),
          ),
          const PopupMenuItem<UserSafetyAction>(
            value: UserSafetyAction.help,
            child: Text('Help / Crisis resources'),
          ),
        ],
      ),
    ];
  }

  Future<void> _openChat({
    required AppUserModel me,
    required AppUserModel user,
  }) async {
    final safeListenerId = user.uid.trim();
    if (safeListenerId.isEmpty) return;

    if (me.uid == safeListenerId) {
      _showSnack('You cannot open chat with yourself.');
      return;
    }

    try {
      final existingSession = await _callRepository.getChatSessionByPair(
        speakerId: me.uid,
        listenerId: safeListenerId,
      );

      if (existingSession['exists'] == true) {
        final direction = _callRepository.resolveSessionDirectionForUser(
          session: existingSession,
          myUid: me.uid,
          fallbackSpeakerId: me.uid,
          fallbackListenerId: safeListenerId,
          mode: ChatDirectionResolutionMode.strictStoredDirection,
        );

        if (!direction.isResolved) {
          await _showConversationRepairDialog(user);
          return;
        }

        if (!selectedListenerMatchesStoredDirection(
          selectedListenerId: safeListenerId,
          actualListenerId: direction.actualListenerId,
        )) {
          final openExisting = await _showExistingConversationDialog(user);
          if (openExisting != true) return;

          FocusManager.instance.primaryFocus?.unfocus();
          if (!mounted) return;

          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ChatConversationScreen(
                speakerId: direction.actualSpeakerId,
                listenerId: direction.actualListenerId,
                actualListenerId: direction.actualListenerId,
                iAmListener: direction.iAmListener,
                initialOtherUser: user,
              ),
            ),
          );
          return;
        }

        FocusManager.instance.primaryFocus?.unfocus();
        if (!mounted) return;

        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ChatConversationScreen(
              speakerId: direction.actualSpeakerId,
              listenerId: direction.actualListenerId,
              actualListenerId: direction.actualListenerId,
              iAmListener: direction.iAmListener,
              initialOtherUser: user,
            ),
          ),
        );
        return;
      }

      final ensuredId =
          await _callRepository.ensureChatSessionWithListener(safeListenerId);

      final expectedId = _canonicalSessionDocId(
        speakerId: me.uid,
        listenerId: safeListenerId,
      );

      if (ensuredId.isEmpty || ensuredId != expectedId) {
        _showSnack('Could not get this chat ready. Please try again.');
        return;
      }
    } catch (e) {
      _showSnack(_callRepository.humanizeChatActionError(e));
      return;
    }

    if (!mounted) return;
    FocusManager.instance.primaryFocus?.unfocus();

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatConversationScreen(
          speakerId: me.uid,
          listenerId: safeListenerId,
          actualListenerId: safeListenerId,
          iAmListener: false,
          initialOtherUser: user,
        ),
      ),
    );
  }

  Future<void> _startCall({
    required AppUserModel me,
    required String listenerId,
    required int visibleRate,
    required Map<String, dynamic> session,
  }) async {
    if (_hasAnyActionRunning()) return;

    if (_hasBlockingCallState) {
      _showSnack('Finish your current call flow first.');
      return;
    }

    final safeListenerId = listenerId.trim();
    if (safeListenerId.isEmpty) return;

    if (!_sessionLooksCanonical(
      me: me,
      user: AppUserModel(
        uid: safeListenerId,
        email: '',
        displayName: '',
        photoURL: '',
        bio: '',
        topics: const [],
        languages: const [],
        gender: '',
        city: '',
        state: '',
        country: '',
        isListener: true,
        isAvailable: true,
        followersCount: 0,
        level: 1,
        listenerRate: visibleRate,
        credits: 0,
        reservedCredits: 0,
        earningsCredits: 0,
        platformRevenueCredits: 0,
        following: const [],
        blocked: const [],
        fcmTokens: const [],
        favoriteListeners: const [],
        activeCallId: '',
        ratingAvg: 0,
        ratingCount: 0,
        ratingSum: 0,
        createdAt: null,
        lastSeen: null,
      ),
      session: session,
    )) {
      _showSnack('Send a message first to start this chat.');
      return;
    }

    if (!_sessionExists(session)) {
      _showSnack('Send a message first to start this chat.');
      return;
    }

    if (visibleRate <= 0) {
      _showSnack('Invalid listener rate.');
      return;
    }

    if (me.uid == safeListenerId) {
      _showSnack('You cannot call yourself.');
      return;
    }

    if (me.blocked.contains(safeListenerId)) {
      _showSnack('You blocked this listener.');
      return;
    }

    try {
      final meLatest = await _userRepository.getMe();
      if (meLatest == null) {
        _showSnack('Could not load your account. Please try again.');
        return;
      }

      if (_hasBlockingCallState) {
        _showSnack('You already have an active call.');
        return;
      }

      final listenerLatest = await _userRepository.getUser(safeListenerId);
      if (listenerLatest == null) {
        _showSnack('Listener not found.');
        return;
      }

      final canCall = await _callRepository.canCurrentUserCallListener(
        listenerId: safeListenerId,
      );

      final readiness = _callRepository.callReadinessForKnownUsers(
        me: meLatest,
        listener: listenerLatest,
        hasCallAccess: canCall,
        requiredCredits: visibleRate,
      );
      if (!readiness.canStart) {
        debugPrint(
          'call.start_local_preflight_blocked reason=${readiness.reason}',
        );
        _showSnack(readiness.message);
        return;
      }

      if (mounted) {
        setState(() {
          _callingFor = safeListenerId;
          _callStartInFlight = true;
        });
      } else {
        _callingFor = safeListenerId;
        _callStartInFlight = true;
      }

      final callStart = await _callRepository.createCallToListener(
        listenerId: safeListenerId,
      );

      if (!mounted) return;
      setState(() {
        _callingFor = '';
        _callStartInFlight = false;
      });

      if (callStart == null) {
        _showSnack('Could not start the call. Please try again.');
        return;
      }

      if (!callStart.canOpenWaitingScreen) {
        _showSnack('Call setup is incomplete. Please try again.');
        return;
      }

      final ok = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => CallerWaitingScreen(
            callDocRef: callStart.callRef,
            initialAgoraToken: callStart.agoraToken,
            initialAgoraUid: callStart.agoraUid,
            initialChannelId: callStart.channelId,
          ),
        ),
      );

      if (!mounted) return;
      if (ok == true) {
        Navigator.of(context).pop(true);
      }
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        setState(() {
          _callingFor = '';
          _callStartInFlight = false;
        });
      } else {
        _callingFor = '';
        _callStartInFlight = false;
      }
      _showSnack(_humanizeFunctionError(e));
    } catch (e) {
      if (mounted) {
        setState(() {
          _callingFor = '';
          _callStartInFlight = false;
        });
      } else {
        _callingFor = '';
        _callStartInFlight = false;
      }
      _showSnack(_humanizeFunctionError(e));
    }
  }

  // ignore: unused_element
  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w900,
        color: AppPalette.textPrimary,
      ),
    );
  }

  Widget _pillChip(
    String text, {
    Color background = AppPalette.blueTint,
    Color foreground = AppPalette.blue,
    Color border = AppPalette.blueTint,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontWeight: FontWeight.w800,
          color: foreground,
          fontSize: 12.5,
        ),
      ),
    );
  }

  // ignore: unused_element
  Widget _metricCard({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: AppPalette.feedBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.26)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: color.withValues(alpha: 0.16),
            child: Icon(icon, color: color, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                    color: color,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: const TextStyle(
                    color: AppPalette.textSecondary,
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Color _callStateColor() {
    switch (_callSession.state) {
      case CallState.connected:
        return const Color(0xFF15803D);
      case CallState.reconnecting:
        return const Color(0xFFD97706);
      case CallState.failed:
      case CallState.ending:
      case CallState.ended:
        return const Color(0xFFDC2626);
      case CallState.preparing:
      case CallState.joining:
        return const Color(0xFF4F46E5);
      case CallState.idle:
        return const Color(0xFF6B7280);
    }
  }

  String _callStateLabel() {
    switch (_callSession.state) {
      case CallState.preparing:
        return 'Preparing call...';
      case CallState.joining:
        return 'Joining voice channel...';
      case CallState.connected:
        return _callSession.status;
      case CallState.reconnecting:
        return _callSession.status;
      case CallState.ending:
        return 'Ending call...';
      case CallState.ended:
        return 'Call ended';
      case CallState.failed:
        return _callSession.status.isEmpty
            ? 'Call failed'
            : _callSession.status;
      case CallState.idle:
        return _callSession.status;
    }
  }

  Widget _activeCallBanner() {
    return AnimatedBuilder(
      animation: _callSession,
      builder: (_, __) {
        if (!_callSession.active) {
          return const SizedBox.shrink();
        }

        final call = _callSession.call;
        final otherName = _callSession.iAmCaller
            ? ((call['calleeName'] ?? '').toString().trim().isNotEmpty
                ? (call['calleeName'] as String).trim()
                : 'Listener')
            : ((call['callerName'] ?? '').toString().trim().isNotEmpty
                ? (call['callerName'] as String).trim()
                : 'User');

        final mm = (_callSession.seconds ~/ 60).toString().padLeft(2, '0');
        final ss = (_callSession.seconds % 60).toString().padLeft(2, '0');
        final safeStateColor = _callStateColor();
        final safeStateLabel = _callStateLabel();

        final showDuration = _callSession.state == CallState.connected ||
            _callSession.state == CallState.reconnecting;

        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: AppPalette.cardDecoration(radius: 18),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                const CircleAvatar(
                  backgroundColor: Color(0x333ED7B8),
                  child: Icon(Icons.call, color: AppPalette.online),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Call is active',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                          color: AppPalette.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'With $otherName - $safeStateLabel',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: AppPalette.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        showDuration ? 'Duration $mm:$ss' : 'Connecting...',
                        style: const TextStyle(
                          color: AppPalette.textSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: safeStateColor.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: safeStateColor.withValues(alpha: 0.25),
                          ),
                        ),
                        child: Text(
                          'State: ${_callSession.state.name}',
                          style: TextStyle(
                            color: safeStateColor,
                            fontWeight: FontWeight.w800,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  onPressed: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        settings: const RouteSettings(
                          name: VoiceCallScreen.routeName,
                        ),
                        builder: (_) => const VoiceCallScreen(),
                      ),
                    );
                  },
                  child: const Text('Open'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _profileAvatar(AppUserModel user, double size) {
    final name = _safeName(user);
    final photoUrl = user.photoURL.trim();

    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppPalette.blue,
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      child: Text(
        name.isNotEmpty ? name[0].toUpperCase() : 'L',
        style: TextStyle(
          fontSize: size * 0.34,
          fontWeight: FontWeight.w900,
          color: Colors.white,
        ),
      ),
    );

    if (photoUrl.isEmpty) return fallback;

    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.28),
      child: Image.network(
        photoUrl,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => fallback,
      ),
    );
  }

  // ignore: unused_element
  Widget _infoSection({
    required String title,
    required Widget child,
  }) {
    return Container(
      decoration: AppPalette.cardDecoration(radius: 18),
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitle(title),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }

  Widget _profileStat({
    required String value,
    required String label,
  }) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppPalette.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w900,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppPalette.textSecondary,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _smallActionTile({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    bool selected = false,
    bool working = false,
  }) {
    final color = selected ? AppPalette.blue : AppPalette.textPrimary;
    return Expanded(
      child: InkWell(
        onTap: working ? null : onTap,
        borderRadius: BorderRadius.circular(15),
        child: Container(
          height: 56,
          decoration: BoxDecoration(
            color: AppPalette.card,
            borderRadius: BorderRadius.circular(15),
            border: Border.all(
              color: selected ? AppPalette.blue : AppPalette.border,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (working)
                const SizedBox(
                  width: 17,
                  height: 17,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(icon, color: color, size: 20),
              const SizedBox(height: 5),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppPalette.textSecondary,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _profileMenuButton(AppUserModel user) {
    return PopupMenuButton<UserSafetyAction>(
      tooltip: 'Profile actions',
      icon: const Icon(
        Icons.ios_share_rounded,
        color: AppPalette.textPrimary,
      ),
      color: AppPalette.card,
      onSelected: (action) async {
        switch (action) {
          case UserSafetyAction.reportUser:
            await _reportUser(user);
            break;
          case UserSafetyAction.blockUser:
            await _blockUser(user);
            break;
          case UserSafetyAction.help:
            await _openHelp();
            break;
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem<UserSafetyAction>(
          value: UserSafetyAction.reportUser,
          enabled: !_reportingUser,
          child: const Text('Report user'),
        ),
        PopupMenuItem<UserSafetyAction>(
          value: UserSafetyAction.blockUser,
          enabled: !_blockingUser,
          child: const Text('Block user'),
        ),
        const PopupMenuItem<UserSafetyAction>(
          value: UserSafetyAction.help,
          child: Text('Help / Crisis resources'),
        ),
      ],
    );
  }

  Widget _buildBody({
    required AppUserModel me,
    required AppUserModel user,
    required Map<String, dynamic> session,
  }) {
    final effectiveSession = _sessionWithSafetyOverrides(
      me: me,
      user: user,
      session: session,
    );
    final myUid = FirestoreService.safeUidOrNull() ?? '';
    final isMyOwnProfile = myUid == user.uid;

    final name = _safeName(user);
    final followers = user.followersCount;
    final level = _userRepository.levelFromFollowers(followers);
    final visibleRate = user.listenerRate;
    final isFollowing = me.following.contains(user.uid);
    final isFavorite = _userRepository.isFavoriteListener(
      me: me,
      listenerId: user.uid,
    );

    final followWorking = _followingWorkingFor == user.uid;
    final favoriteWorking = _favoriteWorkingFor == user.uid;
    final callWorking = _callingFor == user.uid;
    final requestWorking = _requestingAccessFor == user.uid;

    final canRequestAccess = _canRequestAccess(
      me: me,
      user: user,
      session: effectiveSession,
    );

    final hasCallAccess = _sessionCallAllowedForDirection(
      me: me,
      user: user,
      session: effectiveSession,
    );
    final callReadiness = _callRepository.callReadinessForKnownUsers(
      me: me,
      listener: user,
      hasCallAccess: hasCallAccess,
      requiredCredits: visibleRate,
    );
    final canCall = callReadiness.canStart &&
        _canCallNow(
          me: me,
          user: user,
          session: effectiveSession,
        );

    final ratingAvg = user.ratingAvg;
    final ratingCount = user.ratingCount;
    final hasRating = ratingCount > 0;
    final ratingCountLabel = ratingCount >= 1000
        ? '${(ratingCount / 1000).toStringAsFixed(1)}k'
        : '$ratingCount';
    final ratingCopy = hasRating
        ? '${_ratingLabel(ratingAvg)} ($ratingCountLabel reviews)'
        : 'New listener';

    final bio = user.bio.trim().isEmpty
        ? "I'm here to listen and support you. Let's talk and make you feel better."
        : user.bio.trim();
    final tags = _safeStringList(user.topics).isEmpty
        ? const <String>['Empathetic', 'Friendly', 'Supportive']
        : _safeStringList(user.topics).take(3).toList(growable: false);

    final safetyBlocked = _sessionBlocked(effectiveSession);
    final callCtaLabel = callWorking
        ? 'Calling...'
        : _hasBlockingCallState
            ? 'Call in progress'
            : safetyBlocked
                ? 'Chat unavailable'
                : canCall
                    ? 'Start Session'
                    : callReadiness.label;
    final canUseProfileActions =
        !isMyOwnProfile && !_hasAnyActionRunning() && !_hasBlockingCallState;

    return Stack(
      children: [
        const Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(color: AppPalette.pageBg),
          ),
        ),
        ListView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 112),
          children: [
            SafeArea(
              bottom: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _activeCallBanner(),
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'Back',
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(
                          Icons.arrow_back_ios_new_rounded,
                          color: AppPalette.textPrimary,
                          size: 21,
                        ),
                      ),
                      const Spacer(),
                      if (!isMyOwnProfile) _profileMenuButton(user),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Center(
                    child: SizedBox(
                      height: 238,
                      width: 238,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                colors: [
                                  AppPalette.blue.withValues(alpha: 0.16),
                                  AppPalette.blue.withValues(alpha: 0.05),
                                  Colors.transparent,
                                ],
                              ),
                              border: Border.all(
                                color: AppPalette.blue.withValues(alpha: 0.14),
                              ),
                            ),
                          ),
                          ClipOval(child: _profileAvatar(user, 212)),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppPalette.textPrimary,
                            fontSize: 25,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Icon(
                        Icons.verified_rounded,
                        color: Color(0xFF2E7DFF),
                        size: 21,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(
                        Icons.star_rounded,
                        color: AppPalette.star,
                        size: 19,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          ratingCopy,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppPalette.textPrimary,
                            fontWeight: FontWeight.w800,
                            fontSize: 13.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    decoration: BoxDecoration(
                      color: AppPalette.card,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppPalette.border),
                    ),
                    child: Row(
                      children: [
                        _profileStat(value: '$followers', label: 'Sessions'),
                        Container(
                          width: 1,
                          height: 34,
                          color: AppPalette.border,
                        ),
                        _profileStat(
                          value: hasRating ? _ratingLabel(ratingAvg) : '0.0',
                          label: 'Rating',
                        ),
                        Container(
                          width: 1,
                          height: 34,
                          color: AppPalette.border,
                        ),
                        _profileStat(value: '$level', label: 'Years'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'About',
                    style: TextStyle(
                      color: AppPalette.textPrimary,
                      fontWeight: FontWeight.w900,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    bio,
                    style: const TextStyle(
                      color: AppPalette.textSecondary,
                      fontWeight: FontWeight.w600,
                      height: 1.38,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: tags.map((tag) => _pillChip(tag)).toList(),
                  ),
                  if (!isMyOwnProfile) ...[
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        _smallActionTile(
                          icon: Icons.chat_bubble_outline_rounded,
                          label: requestWorking ? 'Wait' : 'Chat',
                          working: requestWorking,
                          onTap: canRequestAccess
                              ? () => _openChat(me: me, user: user)
                              : null,
                        ),
                        const SizedBox(width: 10),
                        _smallActionTile(
                          icon: isFollowing
                              ? Icons.person_remove_alt_1_rounded
                              : Icons.person_add_alt_1_rounded,
                          label: followWorking
                              ? 'Wait'
                              : (isFollowing ? 'Following' : 'Follow'),
                          selected: isFollowing,
                          working: followWorking,
                          onTap: canUseProfileActions && !followWorking
                              ? () => _toggleFollow(
                                    listenerId: user.uid,
                                    isFollowing: isFollowing,
                                  )
                              : null,
                        ),
                        const SizedBox(width: 10),
                        _smallActionTile(
                          icon: isFavorite
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          label: favoriteWorking
                              ? 'Wait'
                              : (isFavorite ? 'Saved' : 'Favorite'),
                          selected: isFavorite,
                          working: favoriteWorking,
                          onTap: canUseProfileActions && !favoriteWorking
                              ? () => _toggleFavorite(
                                    listenerId: user.uid,
                                    isFavorite: isFavorite,
                                  )
                              : null,
                        ),
                      ],
                    ),
                  ],
                  if (!isMyOwnProfile) ...[
                    const SizedBox(height: 20),
                    Container(
                      height: 54,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: AppPalette.blue,
                        borderRadius: BorderRadius.circular(15),
                        boxShadow: [
                          BoxShadow(
                            color: AppPalette.blue.withValues(alpha: 0.22),
                            blurRadius: 18,
                            offset: const Offset(0, 9),
                          ),
                        ],
                      ),
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.transparent,
                          disabledBackgroundColor: Colors.transparent,
                          shadowColor: Colors.transparent,
                          foregroundColor: Colors.white,
                          disabledForegroundColor:
                              Colors.white.withValues(alpha: 0.52),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(15),
                          ),
                        ),
                        onPressed: canCall
                            ? () => _startCall(
                                  me: me,
                                  listenerId: user.uid,
                                  visibleRate: visibleRate,
                                  session: effectiveSession,
                                )
                            : null,
                        child: Text(
                          canCall && !callWorking
                              ? 'Start Session - Rs $visibleRate/min'
                              : '$callCtaLabel - Rs $visibleRate/min',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ),
                    if (!canCall && callReadiness.message.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        callReadiness.message,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: AppPalette.textSecondary,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ],
                  _reviewsSection(user.uid),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _reviewsSection(String listenerId) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 22),
        const Text(
          'Reviews',
          style: TextStyle(
            color: AppPalette.textPrimary,
            fontWeight: FontWeight.w900,
            fontSize: 14,
          ),
        ),
        const SizedBox(height: 10),
        StreamBuilder<List<Map<String, dynamic>>>(
          stream: _userRepository.watchListenerReviews(listenerId),
          builder: (context, snapshot) {
            final reviews = snapshot.data ?? const <Map<String, dynamic>>[];
            if (reviews.isEmpty) {
              return const Text(
                'No reviews yet.',
                style: TextStyle(
                  color: AppPalette.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              );
            }
            return Column(
              children: reviews.map(_reviewCard).toList(),
            );
          },
        ),
      ],
    );
  }

  Widget _reviewCard(Map<String, dynamic> data) {
    final rawStars = data['stars'];
    final stars = rawStars is num ? rawStars.toInt() : 0;
    final comment =
        data['comment'] is String ? (data['comment'] as String).trim() : '';

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(13),
      decoration: AppPalette.cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: List.generate(5, (i) {
              return Icon(
                i < stars ? Icons.star_rounded : Icons.star_outline_rounded,
                size: 16,
                color: AppPalette.star,
              );
            }),
          ),
          if (comment.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              comment,
              style: const TextStyle(
                color: AppPalette.textPrimary,
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
          ],
          const SizedBox(height: 6),
          const Text(
            'anon',
            style: TextStyle(
              color: AppPalette.textMuted,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _callSession,
      builder: (_, __) {
        return StreamBuilder<AppUserModel?>(
          stream: _userRepository.watchMe(),
          builder: (_, meSnap) {
            if (!meSnap.hasData) {
              return const Scaffold(
                backgroundColor: AppPalette.pageBg,
                body: Center(child: CircularProgressIndicator()),
              );
            }

            final me = meSnap.data!;

            return StreamBuilder<AppUserModel?>(
              stream: _userRepository.watchUser(widget.listenerId),
              initialData: widget.initialUser,
              builder: (_, userSnap) {
                final user = userSnap.data;

                if (user == null) {
                  return Scaffold(
                    backgroundColor: AppPalette.pageBg,
                    appBar: AppBar(
                      elevation: 0,
                      scrolledUnderElevation: 0,
                      backgroundColor: Colors.transparent,
                      surfaceTintColor: Colors.transparent,
                      foregroundColor: AppPalette.textPrimary,
                      title: const Text('Listener Profile'),
                    ),
                    body: const Center(
                      child: Text(
                        'Listener not found.',
                        style: TextStyle(color: AppPalette.textPrimary),
                      ),
                    ),
                  );
                }

                final isMyOwnProfile = me.uid == user.uid;

                if (isMyOwnProfile) {
                  return Scaffold(
                    backgroundColor: AppPalette.pageBg,
                    body: DecoratedBox(
                      decoration: const BoxDecoration(color: AppPalette.pageBg),
                      child: _buildBody(
                        me: me,
                        user: user,
                        session: const <String, dynamic>{},
                      ),
                    ),
                  );
                }

                return StreamBuilder<Map<String, dynamic>>(
                  stream: _callRepository.watchChatSessionForListener(user.uid),
                  builder: (_, sessionSnap) {
                    final expectedDocId = _canonicalSessionDocId(
                      speakerId: me.uid,
                      listenerId: user.uid,
                    );

                    final session = sessionSnap.data ??
                        <String, dynamic>{
                          FirestorePaths.fieldSpeakerId: me.uid,
                          FirestorePaths.fieldListenerId: user.uid,
                          FirestorePaths.fieldParticipantIds: <String>[
                            ...(<String>[me.uid, user.uid]..sort()),
                          ],
                          FirestorePaths.fieldPairKey: expectedDocId,
                          FirestorePaths.fieldActualListenerId: user.uid,
                          FirestorePaths.fieldChatStatus:
                              FirestorePaths.chatStatusNone,
                          FirestorePaths.fieldCallAllowed: false,
                          FirestorePaths.fieldListenerBlocked: false,
                          FirestorePaths.fieldSpeakerBlocked: false,
                          'exists': false,
                          'docId': expectedDocId,
                          'canonicalDocId': expectedDocId,
                        };

                    return Scaffold(
                      backgroundColor: AppPalette.pageBg,
                      body: DecoratedBox(
                        decoration:
                            const BoxDecoration(color: AppPalette.pageBg),
                        child: _buildBody(
                          me: me,
                          user: user,
                          session: session,
                        ),
                      ),
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}
