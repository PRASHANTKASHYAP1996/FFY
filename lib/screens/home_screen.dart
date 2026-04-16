import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../core/constants/firestore_paths.dart';
import '../repositories/admin_repository.dart';
import '../repositories/call_repository.dart';
import '../repositories/user_repository.dart';
import '../services/firestore_service.dart';
import '../shared/models/app_user_model.dart';
import '../widgets/incoming_call_overlay.dart';
import 'admin_dashboard_screen.dart';
import 'analytics_dashboard_screen.dart';
import 'call_history_screen.dart';
import 'chat_conversation_screen.dart';
import 'crisis_help_screen.dart';
import 'match_and_call_screen.dart';
import 'profile_screen.dart';
import 'wallet_details_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final UserRepository _userRepository = UserRepository.instance;
  final CallRepository _callRepository = CallRepository.instance;
  final AdminRepository _adminRepository = AdminRepository.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  final Map<String, Future<AppUserModel?>> _chatUserFutureCache =
      <String, Future<AppUserModel?>>{};

  Future<bool>? _isAdminFuture;

  bool _maintenanceRunning = false;
  bool _signingOut = false;

  String _allowingChatFor = '';
  String _allowingCallFor = '';
  String _denyingCallFor = '';
  String _blockingRequestFor = '';
  String _openingChatFor = '';

  DateTime? _lastMaintenanceRun;

  bool get _requestActionBusy =>
      _allowingChatFor.isNotEmpty ||
      _allowingCallFor.isNotEmpty ||
      _denyingCallFor.isNotEmpty ||
      _blockingRequestFor.isNotEmpty ||
      _openingChatFor.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _isAdminFuture = _adminRepository.isCurrentUserAdmin();
    WidgetsBinding.instance.addObserver(this);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runMaintenance();
      _ensureDisplayName();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _runMaintenance();
      _ensureDisplayName();
    }
  }

  void _showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  String _safeString(dynamic value, {String fallback = ''}) {
    if (value is String) return value.trim();
    return fallback;
  }

  int _safeInt(dynamic value, {int fallback = 0}) {
    if (value is int) return value;
    if (value is num) return value.floor();
    return fallback;
  }

  String _canonicalSessionId({
    required String speakerId,
    required String listenerId,
  }) {
    return _callRepository.chatSessionIdForPair(
      speakerId: speakerId,
      listenerId: listenerId,
    );
  }

  bool _isCanonicalDirectionalSession(Map<String, dynamic> session) {
    final speakerId =
        _safeString(session[FirestorePaths.fieldSpeakerId], fallback: '');
    final listenerId =
        _safeString(session[FirestorePaths.fieldListenerId], fallback: '');
    final docId = _safeString(session['_docId'], fallback: '');
    final expectedDocId = _canonicalSessionId(
      speakerId: speakerId,
      listenerId: listenerId,
    );

    if (speakerId.isEmpty || listenerId.isEmpty) return false;
    if (speakerId == listenerId) return false;
    if (expectedDocId.isEmpty) return false;
    if (docId.isEmpty) return false;
    if (docId != expectedDocId) return false;

    return true;
  }

  Future<void> _runMaintenance() async {
    if (_maintenanceRunning) return;

    final now = DateTime.now();
    if (_lastMaintenanceRun != null &&
        now.difference(_lastMaintenanceRun!).inSeconds < 30) {
      return;
    }

    _maintenanceRunning = true;
    _lastMaintenanceRun = now;

    try {
      await FirestoreService.cleanupMyStaleCalls();
    } catch (_) {
      // ignore maintenance failure
    } finally {
      _maintenanceRunning = false;
    }
  }

  Future<void> _ensureDisplayName() async {
    try {
      final authUser = FirebaseAuth.instance.currentUser;
      if (authUser == null) return;

      final me = await _userRepository.getMe();
      final existing = me?.displayName.trim() ?? '';
      if (existing.isNotEmpty) return;

      final fallback = (authUser.displayName ?? '').trim().isNotEmpty
          ? authUser.displayName!.trim()
          : (authUser.email ?? 'Friendify User').split('@').first;

      await _userRepository.setDisplayName(fallback);
    } catch (_) {
      // ignore fallback display name failure
    }
  }

  Future<void> _signOut() async {
    if (_signingOut) return;

    setState(() => _signingOut = true);

    try {
      await _userRepository.signOut();
    } catch (_) {
      if (!mounted) return;
      _showSnack('Sign out failed. Please try again.');
      setState(() => _signingOut = false);
    }
  }

  String _requestSpeakerId(Map<String, dynamic> request) {
    return (request[FirestorePaths.fieldSpeakerId] ?? request['speakerId'] ?? '')
        .toString()
        .trim();
  }

  String _requestListenerId(Map<String, dynamic> request) {
    return (request[FirestorePaths.fieldListenerId] ??
            request['listenerId'] ??
            '')
        .toString()
        .trim();
  }

  String _requestStatus(Map<String, dynamic> request) {
    final exists = request['exists'] == true;
    if (!exists) {
      return FirestorePaths.chatStatusNone;
    }

    return (request[FirestorePaths.fieldChatStatus] ?? request['status'] ?? '')
        .toString()
        .trim();
  }

  bool _requestCallAllowed(Map<String, dynamic> request) {
    if (request['exists'] != true) return false;
    return request[FirestorePaths.fieldCallAllowed] == true ||
        request['callAllowed'] == true;
  }

  bool _requestListenerBlocked(Map<String, dynamic> request) {
    return request[FirestorePaths.fieldListenerBlocked] == true ||
        request['listenerBlocked'] == true;
  }

  bool _requestSpeakerBlocked(Map<String, dynamic> request) {
    return request[FirestorePaths.fieldSpeakerBlocked] == true ||
        request['speakerBlocked'] == true;
  }

  bool _requestBlocked(Map<String, dynamic> request) {
    return _requestListenerBlocked(request) || _requestSpeakerBlocked(request);
  }

  Future<void> _allowChatOnly({
    required String speakerId,
    required String listenerId,
  }) async {
    if (_requestActionBusy) return;

    setState(() => _allowingChatFor = speakerId);

    try {
      await _callRepository.markListenerAllowedChatOnly(
        speakerId: speakerId,
        listenerId: listenerId,
      );
      if (!mounted) return;
      _showSnack('Chat allowed. Call remains locked.');
    } catch (_) {
      if (!mounted) return;
      _showSnack('Could not allow chat right now.');
    } finally {
      if (mounted) {
        setState(() => _allowingChatFor = '');
      }
    }
  }

  Future<void> _allowCallNow({
    required String speakerId,
    required String listenerId,
  }) async {
    if (_requestActionBusy) return;

    setState(() => _allowingCallFor = speakerId);

    try {
      await _callRepository.markListenerAllowedCall(
        speakerId: speakerId,
        listenerId: listenerId,
      );
      if (!mounted) return;
      _showSnack('Call allowed for this speaker.');
    } catch (_) {
      if (!mounted) return;
      _showSnack('Could not allow call right now.');
    } finally {
      if (mounted) {
        setState(() => _allowingCallFor = '');
      }
    }
  }

  Future<void> _denyCall({
    required String speakerId,
    required String listenerId,
  }) async {
    if (_requestActionBusy) return;

    setState(() => _denyingCallFor = speakerId);

    try {
      await _callRepository.markListenerDeniedCall(
        speakerId: speakerId,
        listenerId: listenerId,
      );
      if (!mounted) return;
      _showSnack('Call denied. Chat remains available, but calling stays locked.');
    } catch (_) {
      if (!mounted) return;
      _showSnack('Could not deny call right now.');
    } finally {
      if (mounted) {
        setState(() => _denyingCallFor = '');
      }
    }
  }

  Future<void> _blockRequest({
    required String speakerId,
    required String listenerId,
  }) async {
    if (_requestActionBusy) return;

    setState(() => _blockingRequestFor = speakerId);

    try {
      await _callRepository.blockChatPair(
        speakerId: speakerId,
        listenerId: listenerId,
        blockedByListener: true,
      );
      if (!mounted) return;
      _showSnack('Speaker blocked for this chat pair.');
    } catch (_) {
      if (!mounted) return;
      _showSnack('Could not block this request right now.');
    } finally {
      if (mounted) {
        setState(() => _blockingRequestFor = '');
      }
    }
  }

  Future<void> _openChatFromRequest({
    required String speakerId,
    required String listenerId,
    required AppUserModel? speaker,
  }) async {
    if (_requestActionBusy) return;

    setState(() => _openingChatFor = speakerId);

    try {
      final ensuredId = await _callRepository.ensureChatSessionByPair(
        speakerId: speakerId,
        listenerId: listenerId,
      );

      final expectedId = _canonicalSessionId(
        speakerId: speakerId,
        listenerId: listenerId,
      );

      if (ensuredId.isEmpty || ensuredId != expectedId) {
        if (!mounted) return;
        _showSnack('Could not prepare the correct chat session.');
        return;
      }

      if (!mounted) return;

      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatConversationScreen(
            speakerId: speakerId,
            listenerId: listenerId,
            iAmListener: true,
            initialOtherUser: speaker,
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _openingChatFor = '');
      } else {
        _openingChatFor = '';
      }
    }
  }

  String _displayNameFromUser(AppUserModel me) {
    final displayName = me.displayName.trim();
    if (displayName.isNotEmpty) return displayName;

    final authUser = FirebaseAuth.instance.currentUser;
    final authName = (authUser?.displayName ?? '').trim();
    if (authName.isNotEmpty) return authName;

    final email = (authUser?.email ?? '').trim();
    if (email.isNotEmpty) {
      return email.split('@').first;
    }

    return 'Friendify User';
  }

  String _listenerLevelLabel(int level) {
    switch (level) {
      case 5:
        return 'Icon';
      case 4:
        return 'Expert';
      case 3:
        return 'Rising';
      case 2:
        return 'Growing';
      default:
        return 'Starter';
    }
  }

  String _requestStatusLabel(Map<String, dynamic> request) {
    final blocked = _requestBlocked(request);
    final callAllowed = _requestCallAllowed(request);
    final status = _requestStatus(request);
    final exists = request['exists'] == true;

    if (!exists) return 'Chat not started';
    if (blocked || status == FirestorePaths.chatStatusBlocked) return 'Blocked';
    if (callAllowed) return 'Call allowed';
    if (status == FirestorePaths.chatStatusAccepted) return 'Chat approved';
    if (status == FirestorePaths.chatStatusActive) return 'Active connection';
    if (status == FirestorePaths.chatStatusPending) {
      return 'Waiting for your action';
    }
    return 'New request';
  }

  Color _requestStatusColor(Map<String, dynamic> request) {
    final blocked = _requestBlocked(request);
    final callAllowed = _requestCallAllowed(request);
    final status = _requestStatus(request);
    final exists = request['exists'] == true;

    if (!exists) {
      return const Color(0xFF6B7280);
    }
    if (blocked || status == FirestorePaths.chatStatusBlocked) {
      return const Color(0xFFDC2626);
    }
    if (callAllowed) return const Color(0xFF15803D);
    if (status == FirestorePaths.chatStatusAccepted ||
        status == FirestorePaths.chatStatusActive) {
      return const Color(0xFF4F46E5);
    }
    if (status == FirestorePaths.chatStatusPending) {
      return const Color(0xFFD97706);
    }
    return const Color(0xFF6B7280);
  }

  String _lastMessagePreview(Map<String, dynamic> request) {
    final lastMessage = (request[FirestorePaths.fieldLastMessageText] ??
            request['lastMessageText'] ??
            '')
        .toString()
        .trim();
    final status = _requestStatus(request);
    final callAllowed = _requestCallAllowed(request);
    final exists = request['exists'] == true;

    if (!exists) return 'Chat not started yet.';
    if (lastMessage.isNotEmpty) return lastMessage;
    if (callAllowed) return 'You allowed call for this speaker.';
    if (status == FirestorePaths.chatStatusAccepted) {
      return 'Chat approved. Call is still controlled by you.';
    }
    if (status == FirestorePaths.chatStatusActive) {
      return 'This chat pair already became active.';
    }
    if (status == FirestorePaths.chatStatusPending) {
      return 'Speaker wants to chat first before calling.';
    }
    return 'No message yet.';
  }

  String _chatPreviewText(Map<String, dynamic> session) {
    final type = (session[FirestorePaths.fieldLastMessageType] ?? '')
        .toString()
        .trim();
    final text = (session[FirestorePaths.fieldLastMessageText] ?? '')
        .toString()
        .trim();
    final exists = session['exists'] == true;

    if (!exists) return 'Start chatting';
    if (type == FirestorePaths.messageTypeCallStart) return '📞 Call started';
    if (type == FirestorePaths.messageTypeCallEnd) {
      return text.isNotEmpty ? text : '📞 Call ended';
    }
    if (type == FirestorePaths.messageTypeMissedCall) return '📞 Missed call';
    if (type == FirestorePaths.messageTypeCallCharge) {
      return text.isNotEmpty ? text : 'Call charge';
    }
    if (type == FirestorePaths.messageTypeSystem) {
      return text.isNotEmpty ? text : 'System update';
    }
    if (text.isNotEmpty) return text;
    return 'Start chatting';
  }

  int _chatUnreadCount({
    required Map<String, dynamic> session,
    required String myUid,
  }) {
    if (session['exists'] != true) return 0;

    final speakerId =
        (session[FirestorePaths.fieldSpeakerId] ?? '').toString().trim();
    final listenerId =
        (session[FirestorePaths.fieldListenerId] ?? '').toString().trim();

    if (myUid == speakerId) {
      final value = session[FirestorePaths.fieldSpeakerUnreadCount];
      if (value is int) return value;
      if (value is num) return value.floor();
      return 0;
    }

    if (myUid == listenerId) {
      final value = session[FirestorePaths.fieldListenerUnreadCount];
      if (value is int) return value;
      if (value is num) return value.floor();
      return 0;
    }

    return 0;
  }

  String _formatChatTime(dynamic value) {
    int ms = 0;
    if (value is int) {
      ms = value;
    } else if (value is num) {
      ms = value.floor();
    }
    if (ms <= 0) return '';

    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final sameDay =
        dt.year == now.year && dt.month == now.month && dt.day == now.day;

    if (sameDay) {
      final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
      final minute = dt.minute.toString().padLeft(2, '0');
      final suffix = dt.hour >= 12 ? 'PM' : 'AM';
      return '$hour:$minute $suffix';
    }

    return '${dt.day}/${dt.month}/${dt.year.toString().substring(2)}';
  }

  Widget _avatar(String photoURL, String displayName) {
    final first =
        displayName.trim().isNotEmpty ? displayName.trim()[0].toUpperCase() : 'F';

    if (photoURL.isNotEmpty) {
      return CircleAvatar(
        radius: 30,
        backgroundImage: NetworkImage(photoURL),
      );
    }

    return CircleAvatar(
      radius: 30,
      backgroundColor: const Color(0xFFE0E7FF),
      child: Text(
        first,
        style: const TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w900,
          color: Color(0xFF312E81),
        ),
      ),
    );
  }

  Widget _softChip({
    required IconData icon,
    required String text,
    Color bg = const Color(0xFFF3F4F6),
    Color fg = const Color(0xFF374151),
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: fg),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionCard({
    required String title,
    String? subtitle,
    required List<Widget> children,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w900,
                color: Color(0xFF111827),
              ),
            ),
            if (subtitle != null && subtitle.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: const TextStyle(
                  color: Color(0xFF6B7280),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 14),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _statTile({
    required String label,
    required String value,
    String? subtitle,
    bool highlight = false,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: highlight ? const Color(0xFFEEF2FF) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: highlight
              ? const Color(0xFFC7D2FE)
              : const Color(0xFFE5E7EB),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF6B7280),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: highlight ? 24 : 20,
              fontWeight: FontWeight.w900,
              color: highlight
                  ? const Color(0xFF312E81)
                  : const Color(0xFF111827),
            ),
          ),
          if (subtitle != null && subtitle.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: const TextStyle(
                color: Color(0xFF6B7280),
                fontWeight: FontWeight.w600,
                height: 1.3,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _actionButton({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    Color iconBg = const Color(0xFFF3F4F6),
    Color iconColor = const Color(0xFF4F46E5),
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: iconBg,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: iconColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF111827),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: Color(0xFF6B7280),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(
              Icons.chevron_right_rounded,
              color: Color(0xFF9CA3AF),
            ),
          ],
        ),
      ),
    );
  }

  Widget _launchActionButton({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color iconBg,
    required Color iconColor,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: iconBg,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: iconColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF111827),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: Color(0xFF6B7280),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(
              Icons.chevron_right_rounded,
              color: Color(0xFF9CA3AF),
            ),
          ],
        ),
      ),
    );
  }

  void _showInfoSheet({
    required String title,
    required String body,
  }) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              8,
              16,
              MediaQuery.of(sheetContext).viewInsets.bottom + 20,
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF111827),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    body,
                    style: const TextStyle(
                      color: Color(0xFF374151),
                      fontWeight: FontWeight.w600,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      child: const Text('Close'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  bool _isValidChatSession(Map<String, dynamic> session) {
    final speakerId =
        _safeString(session[FirestorePaths.fieldSpeakerId], fallback: '');
    final listenerId =
        _safeString(session[FirestorePaths.fieldListenerId], fallback: '');
    if (speakerId.isEmpty || listenerId.isEmpty) return false;
    if (speakerId == listenerId) return false;
    return true;
  }

  String _pairKeyFromSession(Map<String, dynamic> session) {
    final speakerId =
        _safeString(session[FirestorePaths.fieldSpeakerId], fallback: '');
    final listenerId =
        _safeString(session[FirestorePaths.fieldListenerId], fallback: '');

    if (speakerId.isEmpty || listenerId.isEmpty) {
      return '';
    }

    return '${speakerId}__${listenerId}';
  }

  int _sessionSortScore(Map<String, dynamic> session) {
    final updatedAt = _safeInt(session[FirestorePaths.fieldChatUpdatedAtMs]);
    final lastMessageAt = _safeInt(session[FirestorePaths.fieldLastMessageAtMs]);
    final createdAt = _safeInt(session[FirestorePaths.fieldChatCreatedAtMs]);

    if (updatedAt > 0) return updatedAt;
    if (lastMessageAt > 0) return lastMessageAt;
    return createdAt;
  }

  List<Map<String, dynamic>> _buildPreferredChatSessionsForList(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final mergedByPair = <String, Map<String, dynamic>>{};

    for (final doc in docs) {
      final data = <String, dynamic>{
        ...doc.data(),
        '_docId': doc.id,
        'exists': true,
      };

      if (!_isValidChatSession(data)) {
        continue;
      }

      if (!_isCanonicalDirectionalSession(data)) {
        continue;
      }

      final pairKey = _pairKeyFromSession(data);
      if (pairKey.isEmpty) {
        continue;
      }

      final existing = mergedByPair[pairKey];
      if (existing == null) {
        mergedByPair[pairKey] = data;
        continue;
      }

      final candidateScore = _sessionSortScore(data);
      final existingScore = _sessionSortScore(existing);

      if (candidateScore > existingScore) {
        mergedByPair[pairKey] = data;
        continue;
      }

      if (candidateScore == existingScore &&
          _safeString(data['_docId']).compareTo(_safeString(existing['_docId'])) <
              0) {
        mergedByPair[pairKey] = data;
      }
    }

    final items = mergedByPair.values.toList()
      ..sort((a, b) {
        final aMs = _sessionSortScore(a);
        final bMs = _sessionSortScore(b);
        return bMs.compareTo(aMs);
      });

    return items;
  }

  Future<AppUserModel?> _chatUserFuture(String uid) {
    final safeUid = uid.trim();
    if (safeUid.isEmpty) {
      return Future<AppUserModel?>.value(null);
    }

    return _chatUserFutureCache.putIfAbsent(
      safeUid,
      () => _userRepository.getUser(safeUid),
    );
  }

  Widget _chatTile({
    required AppUserModel me,
    required Map<String, dynamic> session,
  }) {
    final speakerId =
        (session[FirestorePaths.fieldSpeakerId] ?? '').toString().trim();
    final listenerId =
        (session[FirestorePaths.fieldListenerId] ?? '').toString().trim();

    if (speakerId.isEmpty || listenerId.isEmpty || speakerId == listenerId) {
      return const SizedBox.shrink();
    }

    final otherUid = me.uid == speakerId ? listenerId : speakerId;
    final iAmListener = me.uid == listenerId;
    final unread = _chatUnreadCount(session: session, myUid: me.uid);
    final preview = _chatPreviewText(session);
    final time = _formatChatTime(
      session[FirestorePaths.fieldLastMessageAtMs] ??
          session[FirestorePaths.fieldChatUpdatedAtMs],
    );

    return FutureBuilder<AppUserModel?>(
      future: _chatUserFuture(otherUid),
      builder: (_, userSnap) {
        final otherUser = userSnap.data;
        final displayName = otherUser?.safeDisplayName ?? 'Conversation';
        final photoUrl = otherUser?.photoURL.trim() ?? '';

        return InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () async {
            final expectedId = _canonicalSessionId(
              speakerId: speakerId,
              listenerId: listenerId,
            );

            final ensuredId = await _callRepository.ensureChatSessionByPair(
              speakerId: speakerId,
              listenerId: listenerId,
            );

            if (!mounted) return;

            if (ensuredId.isEmpty || ensuredId != expectedId) {
              _showSnack('Could not prepare the correct chat session.');
              return;
            }

            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ChatConversationScreen(
                  speakerId: speakerId,
                  listenerId: listenerId,
                  iAmListener: iAmListener,
                  initialOtherUser: otherUser,
                ),
              ),
            );
          },
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                _avatar(photoUrl, displayName),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 15.5,
                          color: Color(0xFF111827),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFF6B7280),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (time.isNotEmpty)
                      Text(
                        time,
                        style: const TextStyle(
                          color: Color(0xFF9CA3AF),
                          fontWeight: FontWeight.w700,
                          fontSize: 11.5,
                        ),
                      ),
                    const SizedBox(height: 6),
                    if (unread > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF4F46E5),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '$unread',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                            fontSize: 11.5,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _recentChatsSection({
    required AppUserModel me,
  }) {
    final speakerQuery = _db
        .collection(FirestorePaths.chatSessions)
        .where(FirestorePaths.fieldSpeakerId, isEqualTo: me.uid)
        .limit(100);

    final listenerQuery = _db
        .collection(FirestorePaths.chatSessions)
        .where(FirestorePaths.fieldListenerId, isEqualTo: me.uid)
        .limit(100);

    return _sectionCard(
      title: 'Recent Chats',
      subtitle: 'Your messages, call events, and conversation history.',
      children: [
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: speakerQuery.snapshots(),
          builder: (_, speakerSnap) {
            return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: listenerQuery.snapshots(),
              builder: (_, listenerSnap) {
                final allDocs = <QueryDocumentSnapshot<Map<String, dynamic>>>[
                  ...(speakerSnap.data?.docs ?? const []),
                  ...(listenerSnap.data?.docs ?? const []),
                ];

                final items = _buildPreferredChatSessionsForList(allDocs);

                if (speakerSnap.connectionState == ConnectionState.waiting &&
                    listenerSnap.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: CircularProgressIndicator(),
                    ),
                  );
                }

                if (items.isEmpty) {
                  return Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: const Color(0xFFE5E7EB)),
                    ),
                    child: const Text(
                      'No chats yet. Start chatting from a profile and your conversation history will appear here.',
                      style: TextStyle(
                        color: Color(0xFF6B7280),
                        fontWeight: FontWeight.w600,
                        height: 1.4,
                      ),
                    ),
                  );
                }

                return Column(
                  children: List.generate(items.length, (index) {
                    final item = items[index];
                    return Column(
                      children: [
                        _chatTile(me: me, session: item),
                        if (index != items.length - 1)
                          const Divider(height: 1, color: Color(0xFFE5E7EB)),
                      ],
                    );
                  }),
                );
              },
            );
          },
        ),
      ],
    );
  }

  Widget _requestCard({
    required Map<String, dynamic> request,
    required String listenerId,
  }) {
    final speakerId = _requestSpeakerId(request);
    final statusLabel = _requestStatusLabel(request);
    final statusColor = _requestStatusColor(request);
    final callAllowed = _requestCallAllowed(request);
    final blocked = _requestBlocked(request);
    final exists = request['exists'] == true;

    final allowChatWorking = _allowingChatFor == speakerId;
    final allowCallWorking = _allowingCallFor == speakerId;
    final denyWorking = _denyingCallFor == speakerId;
    final blockWorking = _blockingRequestFor == speakerId;
    final openChatWorking = _openingChatFor == speakerId;

    return FutureBuilder<AppUserModel?>(
      future: _chatUserFuture(speakerId),
      builder: (_, userSnap) {
        final speaker = userSnap.data;
        final speakerName = speaker?.displayName.trim().isNotEmpty == true
            ? speaker!.displayName.trim()
            : 'Speaker';
        final speakerPhoto = speaker?.photoURL.trim() ?? '';
        final speakerBio = speaker?.bio.trim() ?? '';
        final speakerTopics =
            speaker == null ? const <String>[] : speaker.topics.take(3).toList();

        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xFFE5E7EB)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _avatar(speakerPhoto, speakerName),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          speakerName,
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 16,
                            color: Color(0xFF111827),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: statusColor.withValues(alpha: 0.22),
                            ),
                          ),
                          child: Text(
                            statusLabel,
                            style: TextStyle(
                              color: statusColor,
                              fontWeight: FontWeight.w800,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                _lastMessagePreview(request),
                style: const TextStyle(
                  color: Color(0xFF374151),
                  fontWeight: FontWeight.w600,
                  height: 1.35,
                ),
              ),
              if (speakerBio.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  speakerBio,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
              ],
              if (speakerTopics.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: speakerTopics
                      .map(
                        (e) => _softChip(
                          icon: Icons.tag_rounded,
                          text: e,
                          bg: const Color(0xFFF3F4F6),
                          fg: const Color(0xFF374151),
                        ),
                      )
                      .toList(),
                ),
              ],
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: (_requestActionBusy || speakerId.isEmpty || !exists)
                      ? null
                      : () => _openChatFromRequest(
                            speakerId: speakerId,
                            listenerId: listenerId,
                            speaker: speaker,
                          ),
                  icon: openChatWorking
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.chat_bubble_outline_rounded),
                  label: Text(exists ? 'Open Chat' : 'Chat Not Ready'),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed:
                          (_requestActionBusy || blocked || callAllowed || !exists)
                              ? null
                              : () => _allowChatOnly(
                                    speakerId: speakerId,
                                    listenerId: listenerId,
                                  ),
                      icon: allowChatWorking
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.chat_bubble_outline_rounded),
                      label: const Text('Allow Chat'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: (_requestActionBusy || blocked || !exists)
                          ? null
                          : () => _allowCallNow(
                                speakerId: speakerId,
                                listenerId: listenerId,
                              ),
                      icon: allowCallWorking
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Icon(
                              callAllowed
                                  ? Icons.lock_open_rounded
                                  : Icons.call_rounded,
                            ),
                      label: Text(callAllowed ? 'Call Allowed' : 'Allow Call'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: (_requestActionBusy || blocked || !exists)
                          ? null
                          : () => _denyCall(
                                speakerId: speakerId,
                                listenerId: listenerId,
                              ),
                      icon: denyWorking
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.block_flipped),
                      label: const Text('Deny Call'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: (_requestActionBusy || blocked || !exists)
                          ? null
                          : () => _blockRequest(
                                speakerId: speakerId,
                                listenerId: listenerId,
                              ),
                      icon: blockWorking
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.gpp_bad_rounded),
                      label: const Text('Block'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _incomingRequestsSection({
    required AppUserModel me,
  }) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _userRepository.watchListenerChatRequests(limit: 50),
      builder: (_, snap) {
        final allRequests = snap.data ?? const <Map<String, dynamic>>[];

        final visibleRequests = allRequests.where((item) {
          final status = _requestStatus(item);
          final blocked = _requestBlocked(item);
          final exists = item['exists'] == true;
          return exists &&
              !blocked &&
              (status == FirestorePaths.chatStatusPending ||
                  status == FirestorePaths.chatStatusAccepted ||
                  status == FirestorePaths.chatStatusActive);
        }).toList();

        return _sectionCard(
          title: 'Incoming Chat Requests',
          subtitle: visibleRequests.isEmpty
              ? 'No active requests right now.'
              : '${visibleRequests.length} speaker request${visibleRequests.length == 1 ? '' : 's'} waiting for your control.',
          children: [
            if (visibleRequests.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFFE5E7EB)),
                ),
                child: const Text(
                  'When someone starts chat first, their requests will appear here. You can allow chat, allow call, deny, block, or open chat.',
                  style: TextStyle(
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                  ),
                ),
              )
            else
              ...List.generate(visibleRequests.length, (index) {
                final item = visibleRequests[index];
                final listenerIdFromRequest = _requestListenerId(item);
                return Padding(
                  padding: EdgeInsets.only(
                    bottom: index == visibleRequests.length - 1 ? 0 : 10,
                  ),
                  child: _requestCard(
                    request: item,
                    listenerId: listenerIdFromRequest.isNotEmpty
                        ? listenerIdFromRequest
                        : me.uid,
                  ),
                );
              }),
          ],
        );
      },
    );
  }

  List<Widget> _adminQuickActions() {
    return [
      _actionButton(
        icon: Icons.analytics_outlined,
        title: 'Analytics Dashboard',
        subtitle: 'See growth, calls, and money flow metrics.',
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => const AnalyticsDashboardScreen(),
            ),
          );
        },
        iconBg: const Color(0xFFFFF7ED),
        iconColor: const Color(0xFFD97706),
      ),
      const SizedBox(height: 10),
      _actionButton(
        icon: Icons.admin_panel_settings_outlined,
        title: 'Admin Dashboard',
        subtitle: 'Monitor reports, reviews, withdrawals, and moderation.',
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => const AdminDashboardScreen(),
            ),
          );
        },
        iconBg: const Color(0xFFEEF2FF),
        iconColor: const Color(0xFF4338CA),
      ),
      const SizedBox(height: 10),
    ];
  }

  Widget _launchReadinessSection() {
    return _sectionCard(
      title: 'Launch information',
      subtitle:
          'Important user-facing product and compliance surfaces for the current India-first launch-prep build.',
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFFFFBEB),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFFDE68A)),
          ),
          child: const Text(
            'Current truth: these surfaces are intentionally visible for launch readiness, but final legal text, support contacts, grievance details, and operational workflows still need founder/business completion.',
            style: TextStyle(
              color: Color(0xFF92400E),
              fontWeight: FontWeight.w700,
              height: 1.4,
            ),
          ),
        ),
        const SizedBox(height: 12),
        _launchActionButton(
          icon: Icons.privacy_tip_outlined,
          title: 'Privacy Policy',
          subtitle: 'Visible placeholder until final approved policy is linked.',
          iconBg: const Color(0xFFEEF2FF),
          iconColor: const Color(0xFF4F46E5),
          onTap: () {
            _showInfoSheet(
              title: 'Privacy Policy',
              body:
                  'Privacy Policy page is not finalized in this build yet.\n\nBefore launch, add the final approved Privacy Policy text and public link here. This surface is visible so it is not hidden during launch preparation.',
            );
          },
        ),
        const SizedBox(height: 10),
        _launchActionButton(
          icon: Icons.description_outlined,
          title: 'Terms of Service',
          subtitle: 'Visible placeholder until final approved terms are linked.',
          iconBg: const Color(0xFFF3F4F6),
          iconColor: const Color(0xFF374151),
          onTap: () {
            _showInfoSheet(
              title: 'Terms of Service',
              body:
                  'Terms of Service page is not finalized in this build yet.\n\nBefore launch, add final consumer terms, listener terms, prohibited conduct, moderation enforcement, billing terms, and dispute language here.',
            );
          },
        ),
        const SizedBox(height: 10),
        _launchActionButton(
          icon: Icons.receipt_long_outlined,
          title: 'Refund Policy',
          subtitle: 'Shows the current launch-phase truth about refunds.',
          iconBg: const Color(0xFFFFFBEB),
          iconColor: const Color(0xFFD97706),
          onTap: () {
            _showInfoSheet(
              title: 'Refund Policy',
              body:
                  'Refund Policy is still placeholder-only in this build.\n\nCurrent truth: payment flow is still test-oriented in parts of the system, so this should not be presented as a fully live production refund system yet.\n\nBefore launch, add the final approved refund / cancellation / failed-payment handling policy here.',
            );
          },
        ),
        const SizedBox(height: 10),
        _launchActionButton(
          icon: Icons.support_agent_rounded,
          title: 'Support / Grievance Contact',
          subtitle:
              'Visible placeholder until final support channels are configured.',
          iconBg: const Color(0xFFECFDF3),
          iconColor: const Color(0xFF15803D),
          onTap: () {
            _showInfoSheet(
              title: 'Support / Grievance Contact',
              body:
                  'Support and grievance contact details are not finalized in this build yet.\n\nBefore launch, configure:\n• support email\n• support response window\n• grievance officer/contact\n• escalation path\n• business address if required\n\nThis surface is visible so support/dispute handling is not hidden.',
            );
          },
        ),
        const SizedBox(height: 10),
        _launchActionButton(
          icon: Icons.delete_outline_rounded,
          title: 'Delete Account Request',
          subtitle: 'Reachable request surface exists from Profile screen.',
          iconBg: const Color(0xFFFEF2F2),
          iconColor: const Color(0xFFDC2626),
          onTap: () {
            _showInfoSheet(
              title: 'Delete Account Request',
              body:
                  'Delete-account request is available from the Profile screen.\n\nCurrent truth: it submits a controlled review request, not instant device-side deletion. Final retention policy and operational handling still need founder/business verification before launch.',
            );
          },
        ),
      ],
    );
  }

  Widget _quickActions({required bool isAdmin}) {
    return _sectionCard(
      title: 'Quick Actions',
      subtitle: 'Everything important, but in a smaller cleaner layout.',
      children: [
        _actionButton(
          icon: Icons.call_rounded,
          title: 'Find & Call People',
          subtitle:
              'Discover profiles by topic, language, gender, and location.',
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const MatchAndCallScreen(),
              ),
            );
          },
          iconBg: const Color(0xFFEEF2FF),
          iconColor: const Color(0xFF4F46E5),
        ),
        const SizedBox(height: 10),
        _actionButton(
          icon: Icons.history_rounded,
          title: 'Call History',
          subtitle: 'Review past calls, credits, and charges.',
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const CallHistoryScreen(),
              ),
            );
          },
          iconBg: const Color(0xFFF3F4F6),
          iconColor: const Color(0xFF374151),
        ),
        const SizedBox(height: 10),
        _actionButton(
          icon: Icons.account_balance_wallet_rounded,
          title: 'Wallet & Earnings',
          subtitle:
              'Track wallet balance, earnings, and test/manual withdrawals.',
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const WalletDetailsScreen(),
              ),
            );
          },
          iconBg: const Color(0xFFECFDF3),
          iconColor: const Color(0xFF15803D),
        ),
        const SizedBox(height: 10),
        if (isAdmin) ..._adminQuickActions(),
        _actionButton(
          icon: Icons.health_and_safety_rounded,
          title: 'Crisis Help',
          subtitle: 'Get immediate help if you feel unsafe.',
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const CrisisHelpScreen(),
              ),
            );
          },
          iconBg: const Color(0xFFFEF2F2),
          iconColor: const Color(0xFFDC2626),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final myUid = FirestoreService.safeUidOrNull() ?? '';

    return StreamBuilder<AppUserModel?>(
      stream: _userRepository.watchMe(),
      builder: (_, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (snap.hasError) {
          return Scaffold(
            body: Center(
              child: Text(
                'Error loading profile\n${snap.error}',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        if (!snap.hasData || snap.data == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            try {
              final user = FirebaseAuth.instance.currentUser;
              if (user != null) {
                await FirestoreService.ensureProfile(
                  email: user.email ?? '',
                );
              }
            } catch (_) {}
          });

          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final me = snap.data!;
        final displayName = _displayNameFromUser(me);
        final photoURL = me.photoURL.trim();

        final credits = me.credits;
        final reserved = me.reservedCredits;
        final usable = _userRepository.usableCreditsFromUser(me);

        final followers = me.followersCount;
        final level = _userRepository.levelFromFollowers(followers);
        final levelLabel = _listenerLevelLabel(level);

        final ratingAvg = me.ratingAvg;
        final ratingCount = me.ratingCount;

        final favoriteCount = me.favoriteListeners.length;
        final followingCount = me.following.length;
        final blockedCount = me.blocked.length;
        final hasActiveCall = me.hasActiveCall;

        return FutureBuilder<bool>(
          future: _isAdminFuture,
          initialData: false,
          builder: (_, adminSnap) {
            final showAdminTools = adminSnap.data == true;

            return Scaffold(
              backgroundColor: const Color(0xFFF8FAFC),
              appBar: AppBar(
                elevation: 0,
                scrolledUnderElevation: 0,
                backgroundColor: Colors.white,
                surfaceTintColor: Colors.white,
                title: const Text('Friendify'),
                actions: [
                  IconButton(
                    tooltip: 'Sign out',
                    icon: _signingOut
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.logout_rounded),
                    onPressed: _signingOut ? null : _signOut,
                  ),
                ],
              ),
              body: Stack(
                children: [
                  ListView(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
                    children: [
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(18),
                          child: Row(
                            children: [
                              _avatar(photoURL, displayName),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      displayName,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w900,
                                        fontSize: 20,
                                        color: Color(0xFF111827),
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'Level $level • $levelLabel',
                                      style: const TextStyle(
                                        color: Color(0xFF374151),
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: [
                                        _softChip(
                                          icon: Icons.people_alt_rounded,
                                          text: '$followers followers',
                                        ),
                                        _softChip(
                                          icon: Icons.star_rounded,
                                          text: ratingCount > 0
                                              ? '${ratingAvg.toStringAsFixed(1)} ($ratingCount)'
                                              : 'No ratings',
                                          bg: const Color(0xFFFFFBEB),
                                          fg: const Color(0xFFD97706),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              OutlinedButton(
                                onPressed: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => const ProfileScreen(),
                                    ),
                                  );
                                },
                                child: const Text('Edit'),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _recentChatsSection(me: me),
                      const SizedBox(height: 12),
                      _sectionCard(
                        title: 'Overview',
                        subtitle:
                            'Your profile, wallet, and network at a glance.',
                        children: [
                          _statTile(
                            label: 'Usable credit',
                            value: '₹$usable',
                            subtitle: 'Available right now',
                            highlight: true,
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: _statTile(
                                  label: 'Total credits',
                                  value: '₹$credits',
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: _statTile(
                                  label: 'Reserved',
                                  value: '₹$reserved',
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: _statTile(
                                  label: 'Favorites',
                                  value: '$favoriteCount',
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: _statTile(
                                  label: 'Following',
                                  value: '$followingCount',
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          _statTile(
                            label: 'Blocked users',
                            value: '$blockedCount',
                            subtitle: hasActiveCall
                                ? 'You currently have an active call'
                                : 'No active call lock right now',
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _incomingRequestsSection(me: me),
                      const SizedBox(height: 12),
                      _quickActions(isAdmin: showAdminTools),
                      const SizedBox(height: 12),
                      _launchReadinessSection(),
                    ],
                  ),
                  if (myUid.isNotEmpty) IncomingCallOverlay(myUid: myUid),
                ],
              ),
            );
          },
        );
      },
    );
  }
}