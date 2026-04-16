import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/constants/firestore_paths.dart';
import '../repositories/call_repository.dart';
import '../repositories/user_repository.dart';
import '../services/call_session_manager.dart';
import '../services/firestore_service.dart';
import '../shared/models/app_user_model.dart';
import 'caller_waiting_screen.dart';
import 'chat_conversation_screen.dart';
import 'voice_call_screen.dart';

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
  String _requestingAccessFor = '';
  bool _callStartInFlight = false;

  void _showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  String _safeName(AppUserModel user) {
    final name = user.displayName.trim();
    return name.isEmpty ? 'Listener' : name;
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

  bool _isBusy(AppUserModel user) {
    return user.hasActiveCall || !user.isAvailable;
  }

  bool _hasAnyActionRunning() {
    return _followingWorkingFor.isNotEmpty ||
        _favoriteWorkingFor.isNotEmpty ||
        _callingFor.isNotEmpty ||
        _requestingAccessFor.isNotEmpty ||
        _callStartInFlight;
  }

  bool get _hasBlockingCallState =>
      _callSession.active ||
      _callSession.state == CallState.preparing ||
      _callSession.state == CallState.joining ||
      _callSession.state == CallState.reconnecting ||
      _callSession.state == CallState.ending;

  int _listenerEarnFromVisible(int visibleRate) {
    return _userRepository.listenerPayoutFromVisibleRate(visibleRate);
  }

  String _ratingLabel(num avg) => avg.toStringAsFixed(1);

  String _humanizeFunctionError(Object e) {
    if (e is FirebaseFunctionsException) {
      final code = e.code.trim();
      final msg = (e.message ?? '').trim();

      debugPrint(
        'listener_profile startCall_v2 FirebaseFunctionsException: '
        'code=$code message=$msg details=${e.details}',
      );

      if (msg.isNotEmpty) return msg;

      switch (code) {
        case 'resource-exhausted':
          return 'Too many call attempts. Please wait and try again.';
        case 'failed-precondition':
          return 'Listener is unavailable, busy, or has not allowed calls yet.';
        case 'unauthenticated':
          return 'Please login again.';
        case 'invalid-argument':
          return 'Invalid call request.';
        case 'not-found':
          return 'Listener not found.';
        default:
          return 'Call failed: $code';
      }
    }

    return 'Could not start call. Please try again.';
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

  bool _sessionCallAllowed(Map<String, dynamic> session) {
    if (!_sessionExists(session)) return false;
    return session[FirestorePaths.fieldCallAllowed] == true ||
        session['callAllowed'] == true;
  }

  String _sessionStatus(Map<String, dynamic> session) {
    if (!_sessionExists(session)) {
      return FirestorePaths.chatStatusNone;
    }

    final status = (session[FirestorePaths.fieldChatStatus] ??
            session['status'] ??
            FirestorePaths.chatStatusNone)
        .toString()
        .trim();

    if (status.isEmpty) {
      return FirestorePaths.chatStatusNone;
    }

    return status;
  }

  bool _sessionLooksCanonical({
    required AppUserModel me,
    required AppUserModel user,
    required Map<String, dynamic> session,
  }) {
    final expectedDocId = _canonicalSessionDocId(
      speakerId: me.uid,
      listenerId: user.uid,
    );
    final docId = (session['docId'] ?? '').toString().trim();
    final canonicalDocId = (session['canonicalDocId'] ?? '').toString().trim();
    final speakerId =
        (session[FirestorePaths.fieldSpeakerId] ?? '').toString().trim();
    final listenerId =
        (session[FirestorePaths.fieldListenerId] ?? '').toString().trim();

    if (expectedDocId.isEmpty) return false;
    if (speakerId != me.uid) return false;
    if (listenerId != user.uid) return false;
    if (canonicalDocId.isNotEmpty && canonicalDocId != expectedDocId) {
      return false;
    }
    if (docId.isNotEmpty && docId != expectedDocId) {
      return false;
    }
    return true;
  }

  String _chatStatusText({
    required AppUserModel me,
    required AppUserModel user,
    required Map<String, dynamic> session,
  }) {
    final status = _sessionStatus(session);
    final callAllowed = _sessionCallAllowed(session);
    final blocked = _sessionBlocked(session);
    final exists = _sessionExists(session);
    final canonical = _sessionLooksCanonical(
      me: me,
      user: user,
      session: session,
    );

    if (blocked) {
      return 'Chat unavailable';
    }

    if (_hasBlockingCallState) {
      return 'Call already active';
    }

    if (!canonical) {
      return 'Chat not ready';
    }

    if (!exists || status == FirestorePaths.chatStatusNone) {
      return 'Chat not started';
    }

    if (callAllowed) {
      return 'Call allowed';
    }

    if (status == FirestorePaths.chatStatusPending) {
      return 'Waiting for listener approval';
    }

    if (status == FirestorePaths.chatStatusAccepted ||
        status == FirestorePaths.chatStatusActive) {
      return 'Chat approved • call still locked';
    }

    if (status == FirestorePaths.chatStatusBlocked) {
      return 'Blocked';
    }

    return 'Chat status: $status';
  }

  Color _chatStatusColor({
    required AppUserModel me,
    required AppUserModel user,
    required Map<String, dynamic> session,
  }) {
    final status = _sessionStatus(session);
    final callAllowed = _sessionCallAllowed(session);
    final blocked = _sessionBlocked(session);
    final canonical = _sessionLooksCanonical(
      me: me,
      user: user,
      session: session,
    );

    if (_hasBlockingCallState) {
      return const Color(0xFF4F46E5);
    }
    if (!canonical) {
      return const Color(0xFF6B7280);
    }
    if (blocked || status == FirestorePaths.chatStatusBlocked) {
      return const Color(0xFFDC2626);
    }
    if (callAllowed) {
      return const Color(0xFF15803D);
    }
    if (status == FirestorePaths.chatStatusPending) {
      return const Color(0xFFD97706);
    }
    if (status == FirestorePaths.chatStatusAccepted ||
        status == FirestorePaths.chatStatusActive) {
      return const Color(0xFF4F46E5);
    }
    return const Color(0xFF6B7280);
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
    if (_isBusy(user)) return false;
    if (me.hasActiveCall || me.activeCallId.trim().isNotEmpty) return false;
    if (me.blocked.contains(user.uid)) return false;
    if (!_sessionLooksCanonical(me: me, user: user, session: session)) {
      return false;
    }
    if (_sessionBlocked(session)) {
      return false;
    }
    if (!_sessionCallAllowed(session)) {
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

  Future<void> _requestChatAccess({
    required AppUserModel me,
    required AppUserModel user,
  }) async {
    if (_hasAnyActionRunning()) return;

    if (_hasBlockingCallState) {
      _showSnack('Finish your current call flow first.');
      return;
    }

    final safeListenerId = user.uid.trim();
    if (safeListenerId.isEmpty) return;

    if (me.uid == safeListenerId) {
      _showSnack('This is your own profile.');
      return;
    }

    if (me.blocked.contains(safeListenerId)) {
      _showSnack('You blocked this listener.');
      return;
    }

    setState(() => _requestingAccessFor = safeListenerId);

    try {
      final ensuredId =
          await _callRepository.ensureChatSessionWithListener(safeListenerId);

      final expectedId = _canonicalSessionDocId(
        speakerId: me.uid,
        listenerId: safeListenerId,
      );

      if (ensuredId.isEmpty || ensuredId != expectedId) {
        _showSnack('Could not prepare the correct chat session.');
        return;
      }

      await _callRepository.requestCallPermissionFromListener(
        listenerId: safeListenerId,
      );

      if (!mounted) return;
      _showSnack(
        'Chat request sent. You can chat now, but calling stays locked until listener approval.',
      );
    } catch (_) {
      _showSnack('Could not send chat request. Please try again.');
    }

    if (!mounted) return;
    setState(() => _requestingAccessFor = '');
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
      final ensuredId =
          await _callRepository.ensureChatSessionWithListener(safeListenerId);

      final expectedId = _canonicalSessionDocId(
        speakerId: me.uid,
        listenerId: safeListenerId,
      );

      if (ensuredId.isEmpty || ensuredId != expectedId) {
        _showSnack('Could not prepare the correct chat session.');
        return;
      }
    } catch (_) {
      _showSnack('Could not open chat right now.');
      return;
    }

    if (!mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatConversationScreen(
          speakerId: me.uid,
          listenerId: safeListenerId,
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
      _showSnack('Chat session missing. Open chat first.');
      return;
    }

    if (!_sessionExists(session)) {
      _showSnack('Chat session missing. Open chat first.');
      return;
    }

    if (!_sessionCallAllowed(session)) {
      _showSnack(
        'Chat first. Listener must allow calls before you can call now.',
      );
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

    if (me.hasActiveCall || me.activeCallId.trim().isNotEmpty) {
      _showSnack('You already have an active call.');
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

      if (_hasBlockingCallState ||
          meLatest.hasActiveCall ||
          meLatest.activeCallId.trim().isNotEmpty) {
        _showSnack('You already have an active call.');
        return;
      }

      final latestAvailable = _userRepository.usableCreditsFromUser(meLatest);

      if (latestAvailable < visibleRate) {
        _showSnack(
          'Low credit. You need at least ₹$visibleRate to start this call.',
        );
        return;
      }

      final listenerLatest = await _userRepository.getUser(safeListenerId);
      if (listenerLatest == null) {
        _showSnack('Listener not found.');
        return;
      }

      final latestActiveCallId = listenerLatest.activeCallId.trim();
      final latestAvailableFlag = listenerLatest.isAvailable;

      if (!latestAvailableFlag) {
        _showSnack('Listener is offline right now.');
        return;
      }

      if (latestActiveCallId.isNotEmpty) {
        _showSnack('Listener is busy right now.');
        return;
      }

      final canCall = await _callRepository.canCurrentUserCallListener(
        listenerId: safeListenerId,
      );

      if (!canCall) {
        _showSnack(
          'Call is still locked. Wait until the listener allows call.',
        );
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

      final callRef = await _callRepository.createCallToListener(
        listenerId: safeListenerId,
      );

      if (!mounted) return;
      setState(() {
        _callingFor = '';
        _callStartInFlight = false;
      });

      if (callRef == null) {
        _showSnack('Call could not start. Please try again.');
        return;
      }

      final ok = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => CallerWaitingScreen(callDocRef: callRef),
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

  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w900,
        color: Color(0xFF111827),
      ),
    );
  }

  Widget _pillChip(
    String text, {
    Color background = const Color(0xFFF3F4F8),
    Color foreground = const Color(0xFF374151),
    Color border = const Color(0xFFE5E7EB),
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

  Widget _metricCard({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.20)),
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
                    color: Color(0xFF6B7280),
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
        return _callSession.status.isEmpty ? 'Call failed' : _callSession.status;
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

        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          color: const Color(0xFFECFDF3),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                const CircleAvatar(
                  backgroundColor: Color(0xFFD1FAE5),
                  child: Icon(Icons.call, color: Color(0xFF047857)),
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
                          color: Color(0xFF111827),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'With $otherName • $safeStateLabel',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF374151),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        showDuration ? 'Duration $mm:$ss' : 'Connecting...',
                        style: const TextStyle(
                          color: Color(0xFF6B7280),
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

  Widget _infoSection({
    required String title,
    required Widget child,
  }) {
    return Card(
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

  Widget _accessStatusCard({
    required AppUserModel me,
    required AppUserModel user,
    required Map<String, dynamic> session,
  }) {
    final color = _chatStatusColor(
      me: me,
      user: user,
      session: session,
    );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: color.withValues(alpha: 0.22),
        ),
      ),
      child: Row(
        children: [
          Icon(
            _hasBlockingCallState
                ? Icons.call_rounded
                : _sessionCallAllowed(session)
                    ? Icons.lock_open_rounded
                    : Icons.lock_outline_rounded,
            color: color,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _chatStatusText(
                me: me,
                user: user,
                session: session,
              ),
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody({
    required AppUserModel me,
    required AppUserModel user,
    required Map<String, dynamic> session,
  }) {
    final myUid = FirestoreService.safeUidOrNull() ?? '';
    final isMyOwnProfile = myUid == user.uid;

    final name = _safeName(user);
    final followers = user.followersCount;
    final level = _userRepository.levelFromFollowers(followers);
    final visibleRate = user.listenerRate;
    final listenerEarn = _listenerEarnFromVisible(visibleRate);
    final platformKeep = visibleRate - listenerEarn;
    final isBusy = _isBusy(user);
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
      session: session,
    );

    final canCall = _canCallNow(
      me: me,
      user: user,
      session: session,
    );

    final ratingAvg = user.ratingAvg;
    final ratingCount = user.ratingCount;
    final hasRating = ratingCount > 0;

    final bio = user.bio.trim();
    final topics = _safeStringList(user.topics);
    final languages = _safeStringList(user.languages);

    final statusText = _hasBlockingCallState
        ? 'Busy on your call'
        : isBusy
            ? 'Busy'
            : 'Available now';
    final statusColor = _hasBlockingCallState
        ? const Color(0xFF4F46E5)
        : isBusy
            ? const Color(0xFFDC2626)
            : const Color(0xFF15803D);

    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 20),
      children: [
        _activeCallBanner(),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Container(
                  width: 82,
                  height: 82,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [
                        Color(0xFF6366F1),
                        Color(0xFF8B5CF6),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    name.isNotEmpty ? name[0].toUpperCase() : 'L',
                    style: const TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  name,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF111827),
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    _pillChip(
                      statusText,
                      background: statusColor.withValues(alpha: 0.10),
                      foreground: statusColor,
                      border: statusColor.withValues(alpha: 0.24),
                    ),
                    _pillChip('Level $level'),
                    if (isFavorite)
                      _pillChip(
                        'Favorite',
                        background: const Color(0xFFFFF7DB),
                        foreground: const Color(0xFFB45309),
                        border: const Color(0xFFFDE68A),
                      ),
                    if (isFollowing)
                      _pillChip(
                        'Following',
                        background: const Color(0xFFECFEFF),
                        foreground: const Color(0xFF0F766E),
                        border: const Color(0xFFA5F3FC),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                if (hasRating)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.star_rounded,
                        color: Color(0xFFF59E0B),
                        size: 20,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _ratingLabel(ratingAvg),
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '($ratingCount review${ratingCount == 1 ? '' : 's'})',
                        style: const TextStyle(
                          color: Color(0xFF6B7280),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  )
                else
                  const Text(
                    'No ratings yet',
                    style: TextStyle(
                      color: Color(0xFF6B7280),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                if (bio.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    bio,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFF374151),
                      fontWeight: FontWeight.w600,
                      height: 1.45,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (_hasBlockingCallState) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _callStateColor().withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: _callStateColor().withValues(alpha: 0.22),
              ),
            ),
            child: Text(
              'New actions are limited while your call state is ${_callSession.state.name}.',
              style: TextStyle(
                color: _callStateColor(),
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (!isMyOwnProfile) ...[
          _accessStatusCard(
            me: me,
            user: user,
            session: session,
          ),
          const SizedBox(height: 12),
        ],
        GridView.count(
          crossAxisCount: 2,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 1.55,
          children: [
            _metricCard(
              icon: Icons.groups_rounded,
              label: 'Followers',
              value: '$followers',
              color: const Color(0xFF4F46E5),
            ),
            _metricCard(
              icon: Icons.sell_rounded,
              label: 'Visible price',
              value: '₹$visibleRate/min',
              color: const Color(0xFF15803D),
            ),
            _metricCard(
              icon: Icons.account_balance_wallet_rounded,
              label: 'Listener earns',
              value: '₹$listenerEarn/min',
              color: const Color(0xFF7C3AED),
            ),
            _metricCard(
              icon: Icons.business_center_rounded,
              label: 'Platform keeps',
              value: '₹$platformKeep/min',
              color: const Color(0xFFD97706),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _infoSection(
          title: 'Topics',
          child: topics.isEmpty
              ? const Text(
                  'No topics added yet.',
                  style: TextStyle(
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w600,
                  ),
                )
              : Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: topics.map((e) => _pillChip(e)).toList(),
                ),
        ),
        const SizedBox(height: 12),
        _infoSection(
          title: 'Languages',
          child: languages.isEmpty
              ? const Text(
                  'No languages added yet.',
                  style: TextStyle(
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w600,
                  ),
                )
              : Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: languages.map((e) => _pillChip(e)).toList(),
                ),
        ),
        const SizedBox(height: 12),
        _infoSection(
          title: 'Billing',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'You pay: ₹$visibleRate per full minute',
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF111827),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Listener earns: ₹$listenerEarn per full minute',
                style: const TextStyle(
                  color: Color(0xFF6B7280),
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Friendify keeps: ₹$platformKeep per full minute',
                style: const TextStyle(
                  color: Color(0xFF6B7280),
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFFE5E7EB)),
                ),
                child: const Text(
                  'Billing starts after 60 seconds. Full minutes only.',
                  style: TextStyle(
                    color: Color(0xFF374151),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (!isMyOwnProfile) ...[
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: canCall
                ? () => _startCall(
                      me: me,
                      listenerId: user.uid,
                      visibleRate: visibleRate,
                      session: session,
                    )
                : null,
            icon: Icon(
              _hasBlockingCallState
                  ? Icons.call_rounded
                  : _sessionCallAllowed(session)
                      ? Icons.call_rounded
                      : Icons.lock_rounded,
            ),
            label: Text(
              callWorking
                  ? 'Calling...'
                  : _hasBlockingCallState
                      ? 'Call In Progress'
                      : _sessionCallAllowed(session)
                          ? (isBusy ? 'Busy' : 'Call Now')
                          : 'Call Locked',
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: canRequestAccess
                      ? () => _openChat(
                            me: me,
                            user: user,
                          )
                      : null,
                  icon: requestWorking
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.chat_bubble_outline_rounded),
                  label: Text(
                    requestWorking
                        ? 'Please wait...'
                        : _sessionExists(session)
                            ? 'Open Chat'
                            : 'Start Chat First',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (!_sessionExists(session) &&
              !_hasBlockingCallState &&
              !_sessionBlocked(session) &&
              _sessionLooksCanonical(me: me, user: user, session: session)) ...[
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: canRequestAccess
                    ? () => _requestChatAccess(
                          me: me,
                          user: user,
                        )
                    : null,
                icon: const Icon(Icons.mark_chat_read_rounded),
                label: const Text('Send Chat Request'),
              ),
            ),
            const SizedBox(height: 10),
          ],
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: (!_hasAnyActionRunning() &&
                          !_hasBlockingCallState &&
                          !followWorking)
                      ? () => _toggleFollow(
                            listenerId: user.uid,
                            isFollowing: isFollowing,
                          )
                      : null,
                  icon: Icon(
                    isFollowing
                        ? Icons.person_remove_alt_1_rounded
                        : Icons.person_add_alt_1_rounded,
                  ),
                  label: Text(
                    followWorking
                        ? 'Please wait...'
                        : (isFollowing ? 'Unfollow' : 'Follow'),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: (!_hasAnyActionRunning() &&
                          !_hasBlockingCallState &&
                          !favoriteWorking)
                      ? () => _toggleFavorite(
                            listenerId: user.uid,
                            isFavorite: isFavorite,
                          )
                      : null,
                  icon: Icon(
                    isFavorite
                        ? Icons.star_rounded
                        : Icons.star_border_rounded,
                    color: isFavorite ? const Color(0xFFF59E0B) : null,
                  ),
                  label: Text(
                    favoriteWorking
                        ? 'Please wait...'
                        : (isFavorite ? 'Unfavorite' : 'Favorite'),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Your usable credit: ₹${me.usableCredits}',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFF6B7280),
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
        if (kDebugMode) ...[
          const SizedBox(height: 12),
          Text(
            'Debug → uid=${user.uid}, isAvailable=${user.isAvailable}, activeCallId=${user.activeCallId}, ratingCount=${user.ratingCount}, sessionExists=${_sessionExists(session)}, chatStatus=${_sessionStatus(session)}, callAllowed=${_sessionCallAllowed(session)}, canonical=${_sessionLooksCanonical(me: me, user: user, session: session)}, localCallState=${_callSession.state.name}',
            style: const TextStyle(
              color: Colors.black45,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
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
                    backgroundColor: const Color(0xFFF8FAFC),
                    appBar: AppBar(
                      elevation: 0,
                      scrolledUnderElevation: 0,
                      backgroundColor: Colors.white,
                      surfaceTintColor: Colors.white,
                      title: const Text('Listener Profile'),
                    ),
                    body: const Center(
                      child: Text('Listener not found.'),
                    ),
                  );
                }

                final isMyOwnProfile = me.uid == user.uid;

                if (isMyOwnProfile) {
                  return Scaffold(
                    backgroundColor: const Color(0xFFF8FAFC),
                    appBar: AppBar(
                      elevation: 0,
                      scrolledUnderElevation: 0,
                      backgroundColor: Colors.white,
                      surfaceTintColor: Colors.white,
                      title: const Text('Listener Profile'),
                    ),
                    body: _buildBody(
                      me: me,
                      user: user,
                      session: const <String, dynamic>{},
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
                      backgroundColor: const Color(0xFFF8FAFC),
                      appBar: AppBar(
                        elevation: 0,
                        scrolledUnderElevation: 0,
                        backgroundColor: Colors.white,
                        surfaceTintColor: Colors.white,
                        title: const Text('Listener Profile'),
                      ),
                      body: _buildBody(
                        me: me,
                        user: user,
                        session: session,
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