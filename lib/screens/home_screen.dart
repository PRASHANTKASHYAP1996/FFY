import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../core/constants/firestore_paths.dart';
import '../core/constants/ui_copy.dart';
import '../core/theme/friendify_brand.dart';
import '../repositories/admin_repository.dart';
import '../repositories/call_repository.dart';
import '../repositories/social_repository.dart';
import '../repositories/user_repository.dart';
import '../services/auth_scoped_subscriptions.dart';
import '../services/app_log.dart';
import '../services/call_latency_tracker.dart';
import '../services/call_manager.dart';
import '../services/call_session_manager.dart';
import '../services/firestore_service.dart';
import '../services/notifications_service.dart';
import '../shared/chat_direction_resolver.dart';
import '../shared/models/app_user_model.dart';
import '../shared/models/call_model.dart';
import '../shared/models/social_post_model.dart';
import '../shared/user_safety_actions.dart';
import 'admin_dashboard_screen.dart';
import 'analytics_dashboard_screen.dart';
import 'auth_screen.dart';
import 'call_history_screen.dart';
import 'chat_conversation_screen.dart';
import 'crisis_help_screen.dart';
import 'developer_diagnostics_screen.dart';
import 'help_support_screen.dart';
import 'legal_policy_screen.dart';
import 'listener_profile_screen.dart';
import 'match_and_call_screen.dart';
import 'notifications_center_screen.dart';
import 'post_detail_screen.dart';
import 'profile_screen.dart';
import 'story_viewer_screen.dart';

@visibleForTesting
ChatConversationScreen buildRecentChatsConversationScreen({
  required ChatDirectionResolution direction,
  AppUserModel? initialOtherUser,
}) {
  return ChatConversationScreen(
    speakerId: direction.actualSpeakerId,
    listenerId: direction.actualListenerId,
    actualListenerId: direction.actualListenerId,
    iAmListener: direction.iAmListener,
    initialOtherUser: initialOtherUser,
  );
}

@visibleForTesting
const ValueKey<String> recentChatPartnerLoadingNameKey =
    ValueKey<String>('recent_chat_partner_loading_name');

@visibleForTesting
Widget buildRecentChatPartnerName({
  required AppUserModel? otherUser,
  required bool loading,
}) {
  if (loading) {
    return Container(
      key: recentChatPartnerLoadingNameKey,
      width: 132,
      height: 14,
      decoration: BoxDecoration(
        color: FriendifyBrand.pureWhite.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
    );
  }

  final displayName = otherUser?.safeDisplayName ?? 'Friendify User';
  return Text(
    displayName,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: const TextStyle(
      fontWeight: FontWeight.w900,
      fontSize: 15.5,
      color: FriendifyBrand.pureWhite,
    ),
  );
}

@visibleForTesting
Future<ChatConversationScreen>
    buildRecentChatsConversationScreenWithResolvedUser({
  required ChatDirectionResolution direction,
  required String otherUid,
  required Future<AppUserModel?> Function(String uid) resolveOtherUser,
  AppUserModel? initialOtherUser,
}) async {
  final safeOtherUid = otherUid.trim();
  final resolvedOtherUser = initialOtherUser ??
      (safeOtherUid.isEmpty ? null : await resolveOtherUser(safeOtherUid));

  return buildRecentChatsConversationScreen(
    direction: direction,
    initialOtherUser: resolvedOtherUser,
  );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.mode = HomeScreenMode.feed,
    this.onOpenChats,
  });

  final HomeScreenMode mode;
  final VoidCallback? onOpenChats;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

enum HomeScreenMode {
  feed,
  discovery,
  chats,
}

enum _HomeOverflowAction {
  profile,
  privacy,
  terms,
  refund,
  community,
  help,
  crisis,
  signOut,
}

enum _HomeListenerFilter {
  all,
  online,
  newer,
  favorites,
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final UserRepository _userRepository = UserRepository.instance;
  final CallRepository _callRepository = CallRepository.instance;
  final AdminRepository _adminRepository = AdminRepository.instance;
  final SocialRepository _socialRepository = SocialRepository.instance;
  final CallSessionManager _callSession = CallSessionManager.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  final Map<String, Future<AppUserModel?>> _chatUserFutureCache =
      <String, Future<AppUserModel?>>{};
  final Map<String, AppUserModel> _resolvedChatUserCache =
      <String, AppUserModel>{};
  final TextEditingController _homeSearchController = TextEditingController();
  final TextEditingController _chatSearchController = TextEditingController();
  final ScrollController _discoveryListController = ScrollController();

  Future<bool>? _isAdminFuture;
  StreamSubscription<User?>? _authStateSub;
  Timer? _storyExpiryRefreshTimer;
  Stream<AppUserModel?>? _meStream;
  Stream<QuerySnapshot<Map<String, dynamic>>>? _recentChatsStream;
  Stream<List<Map<String, dynamic>>>? _incomingRequestsStream;

  bool _maintenanceRunning = false;
  bool _signingOut = false;
  bool _ensuringProfile = false;
  bool _availabilityUpdating = false;
  bool _creatingStory = false;
  bool _profileEnsureFailed = false;
  bool _discoveryChromeCollapsed = false;
  bool? _pendingOnlyChatModeValue;
  _HomeListenerFilter _homeListenerFilter = _HomeListenerFilter.all;
  final Set<String> _likedFeedPosts = <String>{};
  final Set<String> _savedFeedPosts = <String>{};
  final Set<String> _hiddenDeletedSocialPostIds = <String>{};
  final Map<String, List<String>> _feedComments = <String, List<String>>{};
  final Map<String, int> _feedShareCounts = <String, int>{};

  int _socialFeedRetryToken = 0;
  int _storyRetryToken = 0;
  int _discoveryRetryToken = 0;
  int _incomingRequestsRetryToken = 0;

  String _allowingChatFor = '';
  String _allowingCallFor = '';
  String _denyingCallFor = '';
  String _blockingRequestFor = '';
  String _openingChatFor = '';
  String _lastEnsuredProfileUid = '';
  String _meStreamUid = '__unset__';
  String _recentChatsStreamUid = '__unset__';
  String _incomingRequestsStreamUid = '__unset__';
  String _lastRecentCanonicalResolvedSignature = '';
  String _lastRecentDuplicateSuppressedSignature = '';
  String _openingActiveCallId = '';

  DateTime? _lastMaintenanceRun;
  final Map<String, DateTime> _snackThrottleByKey = <String, DateTime>{};

  bool get _requestActionBusy =>
      _allowingChatFor.isNotEmpty ||
      _allowingCallFor.isNotEmpty ||
      _denyingCallFor.isNotEmpty ||
      _blockingRequestFor.isNotEmpty ||
      _openingChatFor.isNotEmpty ||
      _openingActiveCallId.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _isAdminFuture = _adminRepository.isCurrentUserAdmin();
    _homeSearchController.addListener(_handleHomeSearchChanged);
    _chatSearchController.addListener(_handleChatSearchChanged);
    _discoveryListController.addListener(_handleDiscoveryListScrolled);
    WidgetsBinding.instance.addObserver(this);
    _authStateSub = FirebaseAuth.instance.authStateChanges().listen(
          _handleAuthStateChanged,
        );
    _storyExpiryRefreshTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) {
        if (mounted) setState(() {});
      },
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _dismissAnyFocus();
      _runMaintenance();
      _ensureDisplayName();
      _maybeEnsureProfile(FirebaseAuth.instance.currentUser);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _authStateSub?.cancel();
    _storyExpiryRefreshTimer?.cancel();
    _homeSearchController.removeListener(_handleHomeSearchChanged);
    _chatSearchController.removeListener(_handleChatSearchChanged);
    _discoveryListController.removeListener(_handleDiscoveryListScrolled);
    _homeSearchController.dispose();
    _chatSearchController.dispose();
    _discoveryListController.dispose();
    super.dispose();
  }

  void _handleHomeSearchChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _handleChatSearchChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _handleDiscoveryListScrolled() {
    if (!mounted) return;
    final collapsed = _discoveryListController.hasClients &&
        _discoveryListController.offset > 28;
    if (collapsed == _discoveryChromeCollapsed) return;
    setState(() => _discoveryChromeCollapsed = collapsed);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _dismissAnyFocus();
      _runMaintenance();
      _ensureDisplayName();
      _maybeEnsureProfile(FirebaseAuth.instance.currentUser);
    }
  }

  void _resetHomeStreamsForUid(String uid) {
    final safeUid = uid.trim();
    if (_meStreamUid != safeUid) {
      _meStreamUid = '__unset__';
      _meStream = null;
    }
    if (_recentChatsStreamUid != safeUid) {
      _recentChatsStreamUid = '__unset__';
      _recentChatsStream = null;
    }
    if (_incomingRequestsStreamUid != safeUid) {
      _incomingRequestsStreamUid = '__unset__';
      _incomingRequestsStream = null;
    }
  }

  Stream<AppUserModel?> _meStreamForCurrentAuth() {
    final uid = FirestoreService.safeUidOrNull() ?? '';
    if (_meStream == null || _meStreamUid != uid) {
      _meStreamUid = uid;
      _meStream = _userRepository.watchMe();
    }
    return _meStream!;
  }

  void _handleAuthStateChanged(User? user) {
    _resetHomeStreamsForUid(user?.uid ?? '');
    if (mounted) setState(() {});
    unawaited(_maybeEnsureProfile(user));
  }

  void _showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  void _showSnackThrottled(
    String key,
    String text, {
    Duration cooldown = const Duration(seconds: 10),
  }) {
    final now = DateTime.now();
    final last = _snackThrottleByKey[key];
    if (last != null && now.difference(last) < cooldown) {
      if (key == 'only_chat_mode_error') {
        debugPrint('only_chat_mode.error_snackbar_throttled');
      }
      return;
    }
    _snackThrottleByKey[key] = now;
    _showSnack(text);
  }

  Future<void> _setOnlyChatMode(
    bool enabled, {
    required AppUserModel me,
    bool userInitiated = true,
  }) async {
    if (_availabilityUpdating && _pendingOnlyChatModeValue == enabled) return;
    if (_availabilityUpdating) return;
    if (enabled == me.onlyChatMode) return;

    if (enabled && me.hasActiveCall) {
      _showSnack('End the current call before enabling Only Chat Mode.');
      return;
    }

    setState(() {
      _availabilityUpdating = true;
      _pendingOnlyChatModeValue = enabled;
    });
    try {
      await _userRepository
          .setOnlyChatMode(enabled)
          .timeout(const Duration(seconds: 8));
      if (!mounted) return;
      _showSnack(enabled
          ? 'Only Chat Mode is on. People can still message you.'
          : 'Calls are on. People can request calls from chats.');
    } on TimeoutException {
      if (!mounted) return;
      if (userInitiated) {
        debugPrint('only_chat_mode.update_timeout');
        _showSnackThrottled(
          'only_chat_mode_error',
          'Could not update Only Chat Mode. Check your connection and try again.',
        );
      } else {
        debugPrint('only_chat_mode.background_sync_timeout_silent');
      }
    } catch (_) {
      if (!mounted) return;
      if (userInitiated) {
        debugPrint('only_chat_mode.update_user_action_failed');
        _showSnackThrottled(
          'only_chat_mode_error',
          'Could not update Only Chat Mode. Please try again.',
        );
      } else {
        debugPrint('only_chat_mode.background_sync_failed_silent');
      }
    } finally {
      if (mounted) {
        setState(() {
          _availabilityUpdating = false;
          _pendingOnlyChatModeValue = null;
        });
      } else {
        _availabilityUpdating = false;
        _pendingOnlyChatModeValue = null;
      }
    }
  }

  void _dismissAnyFocus() {
    FocusManager.instance.primaryFocus?.unfocus();
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

  String _humanizeChatStreamError(
    Object error, {
    required String fallback,
  }) {
    final raw = error.toString().trim().toLowerCase();
    if (raw.contains('permission-denied') ||
        raw.contains('missing or insufficient permissions')) {
      return '$fallback Please refresh or sign in again.';
    }
    if (raw.contains('failed-precondition')) {
      return '$fallback Please try again in a moment.';
    }
    return fallback;
  }

  Widget _streamDiagnosticState({
    required IconData icon,
    required String title,
    required String message,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFDE68A)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: const Color(0xFFD97706)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Color(0xFF92400E),
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: const TextStyle(
                    color: Color(0xFFB45309),
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _streamWarningBanner({
    required IconData icon,
    required String title,
    required String message,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFECACA)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: const Color(0xFFDC2626)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Color(0xFF991B1B),
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: const TextStyle(
                    color: Color(0xFFB91C1C),
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _recentChatsLoadingPlaceholder() {
    Widget placeholderRow({double widthFactor = 1}) {
      return Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: FriendifyBrand.pureWhite.withValues(alpha: 0.08),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FractionallySizedBox(
                  widthFactor: widthFactor,
                  child: Container(
                    height: 12,
                    decoration: BoxDecoration(
                      color: FriendifyBrand.pureWhite.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                FractionallySizedBox(
                  widthFactor: 0.85,
                  child: Container(
                    height: 10,
                    decoration: BoxDecoration(
                      color: FriendifyBrand.pureWhite.withValues(alpha: 0.07),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: FriendifyBrand.panelDecoration(radius: 16),
      child: Column(
        children: [
          placeholderRow(widthFactor: 0.55),
          const SizedBox(height: 14),
          placeholderRow(widthFactor: 0.72),
        ],
      ),
    );
  }

  Widget _loadingScaffold({required String message}) {
    return Scaffold(
      backgroundColor: FriendifyBrand.deepIndigo,
      body: SafeArea(
        child: DecoratedBox(
          decoration: FriendifyBrand.brandedBackground(),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      gradient: FriendifyBrand.primaryGradient,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          blurRadius: 28,
                          color: FriendifyBrand.softViolet.withValues(
                            alpha: 0.35,
                          ),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.favorite_rounded,
                      color: FriendifyBrand.pureWhite,
                      size: 34,
                    ),
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'Friendify',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                      color: FriendifyBrand.pureWhite,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: FriendifyBrand.slate,
                      fontWeight: FontWeight.w600,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 20),
                  const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.6,
                      color: FriendifyBrand.lavenderGlow,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ignore: unused_element
  void _openDeveloperDiagnostics() {
    _dismissAnyFocus();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const DeveloperDiagnosticsScreen(),
      ),
    );
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

  Future<void> _maybeEnsureProfile(User? user) async {
    final safeUser = user;
    if (safeUser == null) {
      _lastEnsuredProfileUid = '';
      _resetHomeStreamsForUid('');
      return;
    }

    final safeUid = safeUser.uid.trim();
    if (safeUid.isEmpty) return;
    _resetHomeStreamsForUid(safeUid);
    if (_ensuringProfile) return;
    if (_lastEnsuredProfileUid == safeUid) return;

    _ensuringProfile = true;
    if (_profileEnsureFailed && mounted) {
      setState(() => _profileEnsureFailed = false);
    }
    try {
      await FirestoreService.ensureProfile(
        email: safeUser.email ?? '',
      );
      _lastEnsuredProfileUid = safeUid;
      if (mounted && _profileEnsureFailed) {
        setState(() => _profileEnsureFailed = false);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _profileEnsureFailed = true);
      }
    } finally {
      _ensuringProfile = false;
    }
  }

  Future<void> _signOut() async {
    if (_signingOut) return;

    if (_hasBlockingCallStateForSignOut()) {
      debugPrint('auth.signout_blocked_call_active');
      _showSnack('End the current call before signing out.');
      return;
    }

    final oldUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    setState(() => _signingOut = true);

    try {
      await WidgetsBinding.instance.endOfFrame;
      await AuthScopedSubscriptions.instance.disposeForUid(oldUid);
      await NotificationsService.instance.detachCurrentTokenForSignOut();
      AuthScreen.clearNextFormOnOpen();
      await _userRepository.signOut();
    } catch (_) {
      if (!mounted) return;
      _showSnack('Sign out failed. Please try again.');
      setState(() => _signingOut = false);
    }
  }

  Future<void> _handleOverflowAction(_HomeOverflowAction action) async {
    _dismissAnyFocus();

    switch (action) {
      case _HomeOverflowAction.profile:
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => const ProfileScreen(),
          ),
        );
        break;
      case _HomeOverflowAction.privacy:
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => const LegalPolicyScreen(
              kind: LegalPolicyKind.privacy,
            ),
          ),
        );
        break;
      case _HomeOverflowAction.terms:
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => const LegalPolicyScreen(
              kind: LegalPolicyKind.terms,
            ),
          ),
        );
        break;
      case _HomeOverflowAction.refund:
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => const LegalPolicyScreen(
              kind: LegalPolicyKind.refund,
            ),
          ),
        );
        break;
      case _HomeOverflowAction.community:
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => const LegalPolicyScreen(
              kind: LegalPolicyKind.communityGuidelines,
            ),
          ),
        );
        break;
      case _HomeOverflowAction.help:
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => const HelpSupportScreen(),
          ),
        );
        break;
      case _HomeOverflowAction.crisis:
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => const CrisisHelpScreen(),
          ),
        );
        break;
      case _HomeOverflowAction.signOut:
        await _signOut();
        break;
    }
  }

  List<PopupMenuEntry<_HomeOverflowAction>> _homeOverflowMenuItems() {
    const menuTextStyle = TextStyle(
      color: FriendifyBrand.pureWhite,
      fontWeight: FontWeight.w800,
    );

    return const [
      PopupMenuItem<_HomeOverflowAction>(
        value: _HomeOverflowAction.profile,
        child: Text('Profile', style: menuTextStyle),
      ),
      PopupMenuDivider(),
      PopupMenuItem<_HomeOverflowAction>(
        value: _HomeOverflowAction.help,
        child: Text('Help & Support', style: menuTextStyle),
      ),
      PopupMenuItem<_HomeOverflowAction>(
        value: _HomeOverflowAction.crisis,
        child: Text('Crisis Help', style: menuTextStyle),
      ),
      PopupMenuDivider(),
      PopupMenuItem<_HomeOverflowAction>(
        value: _HomeOverflowAction.privacy,
        child: Text('Privacy Policy', style: menuTextStyle),
      ),
      PopupMenuItem<_HomeOverflowAction>(
        value: _HomeOverflowAction.terms,
        child: Text('Terms of Service', style: menuTextStyle),
      ),
      PopupMenuItem<_HomeOverflowAction>(
        value: _HomeOverflowAction.refund,
        child: Text('Refund / Cancellation Policy', style: menuTextStyle),
      ),
      PopupMenuItem<_HomeOverflowAction>(
        value: _HomeOverflowAction.community,
        child: Text('Community Guidelines', style: menuTextStyle),
      ),
      PopupMenuDivider(),
      PopupMenuItem<_HomeOverflowAction>(
        value: _HomeOverflowAction.signOut,
        child: Text('Sign out', style: menuTextStyle),
      ),
    ];
  }

  bool _hasBlockingCallStateForSignOut() {
    if (CallLatencyTracker.hasPendingStarts) return true;

    final callSession = CallSessionManager.instance;
    if (callSession.active) return true;

    return switch (callSession.state) {
      CallState.preparing ||
      CallState.joining ||
      CallState.connected ||
      CallState.reconnecting ||
      CallState.ending =>
        true,
      CallState.idle || CallState.ended || CallState.failed => false,
    };
  }

  String _requestSpeakerId(Map<String, dynamic> request) {
    return (request[FirestorePaths.fieldRequesterId] ??
            request['requesterId'] ??
            request[FirestorePaths.fieldCallRequestedBy] ??
            request[FirestorePaths.fieldSpeakerId] ??
            request['speakerId'] ??
            '')
        .toString()
        .trim();
  }

  String _requestListenerId(Map<String, dynamic> request) {
    return (request[FirestorePaths.fieldResponderId] ??
            request['responderId'] ??
            request[FirestorePaths.fieldPendingFor] ??
            request['pendingFor'] ??
            request[FirestorePaths.fieldListenerId] ??
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
      _showSnack(
          'Call denied. Chat remains available, but calling stays locked.');
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

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Block this chat request?'),
        content: const Text(
          'This blocks the speaker for this chat pair and removes the active request.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Block'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
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

      final direction =
          await _callRepository.resolveStoredChatDirectionForCurrentUser(
        speakerId: speakerId,
        listenerId: listenerId,
        mode: ChatDirectionResolutionMode.strictStoredDirection,
      );

      if (!direction.isResolved) {
        if (!mounted) return;
        _showSnack('This conversation needs repair before it can open.');
        return;
      }

      if (!mounted) return;
      _dismissAnyFocus();

      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatConversationScreen(
            speakerId: direction.actualSpeakerId,
            listenerId: direction.actualListenerId,
            actualListenerId: direction.actualListenerId,
            iAmListener: direction.iAmListener,
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

  // ignore: unused_element
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

  Stream<QuerySnapshot<Map<String, dynamic>>> _authBoundQuerySnapshots({
    required Query<Map<String, dynamic>> query,
    required String uid,
  }) {
    final safeUid = uid.trim();
    late StreamController<QuerySnapshot<Map<String, dynamic>>> controller;
    StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? subscription;

    controller =
        StreamController<QuerySnapshot<Map<String, dynamic>>>.broadcast(
      onListen: () {
        subscription = query.snapshots().listen(
          (snapshot) {
            if (FirebaseAuth.instance.currentUser?.uid.trim() != safeUid) {
              return;
            }
            if (controller.isClosed) return;
            controller.add(snapshot);
          },
          onError: (Object error, StackTrace stackTrace) {
            if (FirebaseAuth.instance.currentUser?.uid.trim() != safeUid) {
              return;
            }
            if (controller.isClosed) return;
            controller.addError(error, stackTrace);
          },
        );
      },
      onCancel: () async {
        await subscription?.cancel();
      },
    );

    return controller.stream;
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _recentChatsStreamFor(
    AppUserModel me,
  ) {
    final safeUid = me.uid.trim();
    if (_recentChatsStream != null && _recentChatsStreamUid == safeUid) {
      return _recentChatsStream!;
    }

    final recentChatsQuery = _db
        .collection(FirestorePaths.chatSessions)
        .where(FirestorePaths.fieldParticipantIds, arrayContains: safeUid)
        .orderBy(FirestorePaths.fieldChatUpdatedAtMs, descending: true)
        .limit(100);

    _recentChatsStreamUid = safeUid;
    _recentChatsStream = _authBoundQuerySnapshots(
      query: recentChatsQuery,
      uid: safeUid,
    );
    return _recentChatsStream!;
  }

  Stream<List<Map<String, dynamic>>> _incomingRequestsStreamFor(
    AppUserModel me,
  ) {
    final safeUid = me.uid.trim();
    if (_incomingRequestsStream != null &&
        _incomingRequestsStreamUid == safeUid) {
      return _incomingRequestsStream!;
    }

    _incomingRequestsStreamUid = safeUid;
    _incomingRequestsStream = _userRepository.watchListenerChatRequests(
      limit: 50,
    );
    return _incomingRequestsStream!;
  }

  void _retryIncomingRequests() {
    _incomingRequestsStream = null;
    _incomingRequestsStreamUid = '__unset__';
    setState(() => _incomingRequestsRetryToken++);
  }

  // ignore: unused_element
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
    final type =
        (session[FirestorePaths.fieldLastMessageType] ?? '').toString().trim();
    final text =
        (session[FirestorePaths.fieldLastMessageText] ?? '').toString().trim();
    final exists = session['exists'] == true;

    if (!exists) return 'Start chatting';
    if (type == FirestorePaths.messageTypeCallStart) return 'Call started';
    if (type == FirestorePaths.messageTypeCallEnd) {
      return text.isNotEmpty ? text : 'Call ended';
    }
    if (type == FirestorePaths.messageTypeMissedCall) return 'Missed call';
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
    return _avatarSized(photoURL, displayName, radius: 30);
  }

  Widget _avatarSized(
    String photoURL,
    String displayName, {
    required double radius,
  }) {
    final first = displayName.trim().isNotEmpty
        ? displayName.trim()[0].toUpperCase()
        : 'F';

    if (photoURL.isNotEmpty) {
      return CircleAvatar(
        radius: radius,
        backgroundImage: NetworkImage(photoURL),
      );
    }

    return CircleAvatar(
      radius: radius,
      backgroundColor: FriendifyBrand.softViolet.withValues(alpha: 0.20),
      child: Text(
        first,
        style: TextStyle(
          fontSize: radius * 0.72,
          fontWeight: FontWeight.w900,
          color: FriendifyBrand.lavenderGlow,
        ),
      ),
    );
  }

  Widget _loadingAvatar() {
    return Container(
      width: 50,
      height: 50,
      decoration: BoxDecoration(
        color: FriendifyBrand.pureWhite.withValues(alpha: 0.10),
        shape: BoxShape.circle,
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
    Key? key,
    required String title,
    String? subtitle,
    required List<Widget> children,
  }) {
    return Container(
      key: key,
      decoration: FriendifyBrand.panelDecoration(),
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
                color: FriendifyBrand.pureWhite,
              ),
            ),
            if (subtitle != null && subtitle.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: const TextStyle(
                  color: FriendifyBrand.slate,
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

  // Kept available for a future profile/call settings surface.
  // ignore: unused_element
  Widget _callModeSection(AppUserModel me) {
    final onlyChatMode = me.onlyChatMode;
    const title = 'Only Chat Mode';
    final subtitle = onlyChatMode
        ? 'Calls are paused. You can still chat.'
        : 'Calls are available. People can request calls with you.';
    final color =
        onlyChatMode ? const Color(0xFF6B7280) : const Color(0xFF15803D);

    return _sectionCard(
      key: const ValueKey<String>('home_only_chat_mode_card'),
      title: 'Only Chat Mode',
      subtitle: 'Control calling for all chats from one place.',
      children: [
        Container(
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
                  color: onlyChatMode
                      ? const Color(0xFFF3F4F6)
                      : const Color(0xFFECFDF3),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  onlyChatMode
                      ? Icons.chat_bubble_outline_rounded
                      : Icons.phone_in_talk_rounded,
                  color: color,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Color(0xFF6B7280),
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _availabilityUpdating
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2.2),
                    )
                  : Switch.adaptive(
                      value: onlyChatMode,
                      onChanged: (value) => unawaited(
                        _setOnlyChatMode(value, me: me),
                      ),
                    ),
            ],
          ),
        ),
      ],
    );
  }

  String _activeCallOtherName() {
    final call = _callSession.call;
    final rawName = _callSession.iAmCaller
        ? _safeString(call[FirestorePaths.fieldCalleeName])
        : _safeString(call[FirestorePaths.fieldCallerName]);
    return rawName.isEmpty ? 'Friendify call' : rawName;
  }

  String _activeCallStatusLabel() {
    if (!_callSession.active) return 'Call active';
    switch (_callSession.state) {
      case CallState.preparing:
        return 'Preparing call';
      case CallState.joining:
        return 'Joining call';
      case CallState.connected:
        return _callSession.remoteConnected ? 'Connected' : 'Call running';
      case CallState.reconnecting:
        return 'Reconnecting';
      case CallState.ending:
        return 'Ending call';
      case CallState.idle:
      case CallState.ended:
      case CallState.failed:
        return 'Call active';
    }
  }

  bool _isRecoverableProfileCall(CallModel? call) {
    if (call == null) return false;
    if (call.isFinal) return false;
    if (call.isRinging) return false;
    return call.isAccepted;
  }

  Widget _activeCallCard({
    required String callId,
    required String title,
    required String status,
    required bool canOpen,
  }) {
    final openingThisCall = _openingActiveCallId.isNotEmpty &&
        (_openingActiveCallId == callId || callId.isEmpty);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        key: const ValueKey<String>('home_active_call_card'),
        color: const Color(0xFFECFDF3),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: const Color(0xFFD1FAE5),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.phone_in_talk_rounded,
                  color: Color(0xFF047857),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF064E3B),
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      status,
                      style: const TextStyle(
                        color: Color(0xFF047857),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              FilledButton.icon(
                onPressed: canOpen && !openingThisCall
                    ? () => unawaited(_openActiveCallFromHome(callId))
                    : null,
                icon: openingThisCall
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.open_in_full_rounded, size: 18),
                label: Text(openingThisCall ? 'Opening' : 'Open'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openActiveCallFromHome(String callId) async {
    final safeCallId = callId.trim();
    if (safeCallId.isEmpty && !_callSession.active) {
      _showSnack('Call is still syncing. Please try again.');
      return;
    }

    final activeCallId = _callSession.callDocRef?.id.trim() ?? safeCallId;
    if (_openingActiveCallId.isNotEmpty) {
      debugPrint('call.active_call_reopen_duplicate_ignored source=home_card');
      return;
    }

    _dismissAnyFocus();
    debugPrint('call.active_call_reopen_tap source=home_card');

    if (mounted) {
      setState(() => _openingActiveCallId = activeCallId);
    }

    try {
      if (_callSession.active) {
        await CallManager.instance.openActiveCallScreen(source: 'home_card');
        return;
      }

      await CallManager.instance.recoverCallFromPushOpen(safeCallId);
    } finally {
      if (mounted && _openingActiveCallId == activeCallId) {
        setState(() => _openingActiveCallId = '');
      } else if (_openingActiveCallId == activeCallId) {
        _openingActiveCallId = '';
      }
    }
  }

  // Kept available for a future compact active-call recovery surface.
  // ignore: unused_element
  Widget _activeCallSection(AppUserModel me) {
    return AnimatedBuilder(
      animation: _callSession,
      builder: (_, __) {
        final sessionCallId = _callSession.callDocRef?.id.trim() ?? '';
        final profileCallId = me.activeCallId.trim();
        final callId = sessionCallId.isNotEmpty ? sessionCallId : profileCallId;

        if (!_callSession.active) {
          if (profileCallId.isEmpty) return const SizedBox.shrink();

          return StreamBuilder<CallModel?>(
            stream: _callRepository.watchCall(profileCallId),
            builder: (_, callSnap) {
              final call = callSnap.data;
              if (callSnap.hasData && !_isRecoverableProfileCall(call)) {
                unawaited(FirestoreService.cleanupMyStaleCalls());
                return const SizedBox.shrink();
              }

              if (!_isRecoverableProfileCall(call)) {
                return const SizedBox.shrink();
              }

              AppLog.debugThrottled(
                'call.active_call_card_visible:$profileCallId',
                'call.active_call_card_visible '
                    'callId=${AppLog.safeId(profileCallId)} '
                    'sessionActive=false '
                    'profileActive=true '
                    'verifiedStatus=${call!.status}',
                interval: const Duration(seconds: 30),
              );

              return _activeCallCard(
                callId: profileCallId,
                title: 'Call in progress',
                status: 'Call active',
                canOpen: true,
              );
            },
          );
        }

        AppLog.debugThrottled(
          'call.active_call_card_visible:$callId',
          'call.active_call_card_visible '
              'callId=${AppLog.safeId(callId)} '
              'sessionActive=${_callSession.active} '
              'profileActive=${me.isOnCall || profileCallId.isNotEmpty}',
          interval: const Duration(seconds: 30),
        );

        final title = _activeCallOtherName();
        final status = _activeCallStatusLabel();
        final canOpen = callId.isNotEmpty || _callSession.active;

        return _activeCallCard(
          callId: callId,
          title: title,
          status: status,
          canOpen: canOpen,
        );
      },
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
          color: FriendifyBrand.pureWhite.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: FriendifyBrand.pureWhite.withValues(alpha: 0.08),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: iconBg.withValues(alpha: 0.16),
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
                      color: FriendifyBrand.pureWhite,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: FriendifyBrand.slate,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(
              Icons.chevron_right_rounded,
              color: FriendifyBrand.slate,
            ),
          ],
        ),
      ),
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

    return '${speakerId}__$listenerId';
  }

  int _sessionSortScore(Map<String, dynamic> session) {
    final updatedAt = _safeInt(session[FirestorePaths.fieldChatUpdatedAtMs]);
    final lastMessageAt =
        _safeInt(session[FirestorePaths.fieldLastMessageAtMs]);
    final createdAt = _safeInt(session[FirestorePaths.fieldChatCreatedAtMs]);

    if (updatedAt > 0) return updatedAt;
    if (lastMessageAt > 0) return lastMessageAt;
    return createdAt;
  }

  void _logRecentChatResolutionChanges({
    required Set<String> canonicalResolvedKeys,
    required Set<String> duplicateSuppressedKeys,
  }) {
    final resolvedSignature =
        (canonicalResolvedKeys.toList()..sort()).join('|');
    if (resolvedSignature != _lastRecentCanonicalResolvedSignature) {
      _lastRecentCanonicalResolvedSignature = resolvedSignature;
      if (canonicalResolvedKeys.isNotEmpty) {
        AppLog.debugThrottled(
          'recent_chats.canonical_session_resolved:$resolvedSignature',
          'recent_chats.canonical_session_resolved',
          interval: const Duration(minutes: 10),
        );
      }
    }

    final duplicateSignature =
        (duplicateSuppressedKeys.toList()..sort()).join('|');
    if (duplicateSignature != _lastRecentDuplicateSuppressedSignature) {
      _lastRecentDuplicateSuppressedSignature = duplicateSignature;
      if (duplicateSuppressedKeys.isNotEmpty) {
        AppLog.debugThrottled(
          'recent_chats.duplicate_session_suppressed:$duplicateSignature',
          'recent_chats.duplicate_session_suppressed',
          interval: const Duration(minutes: 10),
        );
      }
    }
  }

  List<Map<String, dynamic>> _buildPreferredChatSessionsForList(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs, {
    required String myUid,
  }) {
    final mergedByPeerOrPair = <String, Map<String, dynamic>>{};
    final canonicalResolvedKeys = <String>{};
    final duplicateSuppressedKeys = <String>{};

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

      final direction = ChatDirectionResolver.resolveForUser(
        session: data,
        myUid: myUid,
        fallbackSpeakerId: _safeString(data[FirestorePaths.fieldSpeakerId]),
        fallbackListenerId: _safeString(data[FirestorePaths.fieldListenerId]),
      );
      final pairKey = _pairKeyFromSession(data);
      if (pairKey.isEmpty) {
        continue;
      }
      final dedupeKey = direction.isResolved && direction.otherUid.isNotEmpty
          ? 'peer:${direction.otherUid}'
          : 'pair:$pairKey';

      final existing = mergedByPeerOrPair[dedupeKey];
      if (existing == null) {
        mergedByPeerOrPair[dedupeKey] = data;
        canonicalResolvedKeys.add(dedupeKey);
        continue;
      }

      duplicateSuppressedKeys.add(dedupeKey);
      final candidateScore = _sessionSortScore(data);
      final existingScore = _sessionSortScore(existing);

      if (candidateScore > existingScore) {
        mergedByPeerOrPair[dedupeKey] = data;
        continue;
      }

      if (candidateScore == existingScore &&
          _safeString(data['_docId'])
                  .compareTo(_safeString(existing['_docId'])) <
              0) {
        mergedByPeerOrPair[dedupeKey] = data;
      }
    }

    _logRecentChatResolutionChanges(
      canonicalResolvedKeys: canonicalResolvedKeys,
      duplicateSuppressedKeys: duplicateSuppressedKeys,
    );

    final items = mergedByPeerOrPair.values.toList()
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

    final cachedUser = _resolvedChatUserCache[safeUid];
    if (cachedUser != null) {
      return Future<AppUserModel?>.value(cachedUser);
    }

    return _chatUserFutureCache.putIfAbsent(
      safeUid,
      () async {
        final user = await _userRepository.getUser(safeUid);
        if (user != null) {
          _resolvedChatUserCache[safeUid] = user;
          if (mounted) {
            setState(() {});
          }
        }
        return user;
      },
    );
  }

  Future<void> _openResolvedChat({
    required ChatDirectionResolution direction,
    required String otherUid,
    AppUserModel? initialOtherUser,
  }) async {
    final safeOtherUid = otherUid.trim();
    if (safeOtherUid.isEmpty || _openingChatFor == safeOtherUid) return;

    setState(() {
      _openingChatFor = safeOtherUid;
    });

    try {
      final destinationFuture =
          buildRecentChatsConversationScreenWithResolvedUser(
        direction: direction,
        otherUid: safeOtherUid,
        resolveOtherUser: _chatUserFuture,
        initialOtherUser: initialOtherUser,
      );
      final expectedId = _canonicalSessionId(
        speakerId: direction.actualSpeakerId,
        listenerId: direction.actualListenerId,
      );

      final ensuredId = await _callRepository.ensureChatSessionByPair(
        speakerId: direction.actualSpeakerId,
        listenerId: direction.actualListenerId,
      );

      if (!mounted) return;

      if (ensuredId.isEmpty || ensuredId != expectedId) {
        _showSnack('Could not prepare the correct chat session.');
        return;
      }

      final destination = await destinationFuture;

      if (!mounted) return;
      _dismissAnyFocus();
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => destination,
        ),
      );
    } finally {
      if (mounted && _openingChatFor == safeOtherUid) {
        setState(() {
          _openingChatFor = '';
        });
      }
    }
  }

  Widget _recentChatDirectionErrorCard({
    required Map<String, dynamic> session,
    required String reason,
  }) {
    final docId = _safeString(session['_docId']);
    final pairKey = _safeString(
      session[FirestorePaths.fieldPairKey],
      fallback: _pairKeyFromSession(session),
    );

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: FriendifyBrand.panelDecoration(radius: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Conversation needs repair',
            style: TextStyle(
              color: FriendifyBrand.danger,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            kDebugMode
                ? 'Recent Chats did not derive a safe speaker/listener direction for this session.\n'
                    'pairKey=$pairKey docId=$docId\n'
                    'reason=$reason'
                : 'This conversation could not be opened safely right now.',
            style: const TextStyle(
              color: FriendifyBrand.slate,
              fontWeight: FontWeight.w700,
              height: 1.35,
            ),
          ),
        ],
      ),
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

    final direction = ChatDirectionResolver.resolveForUser(
      session: session,
      myUid: me.uid,
      fallbackSpeakerId: speakerId,
      fallbackListenerId: listenerId,
    );
    if (!direction.isResolved) {
      return _recentChatDirectionErrorCard(
        session: session,
        reason: direction.errorReason,
      );
    }

    final otherUid = direction.otherUid;
    final openingThisChat = _openingChatFor == otherUid;
    final unread = _chatUnreadCount(session: session, myUid: me.uid);
    final preview = _chatPreviewText(session);
    final time = _formatChatTime(
      session[FirestorePaths.fieldLastMessageAtMs] ??
          session[FirestorePaths.fieldChatUpdatedAtMs],
    );

    return FutureBuilder<AppUserModel?>(
      future: _chatUserFuture(otherUid),
      initialData: _resolvedChatUserCache[otherUid],
      builder: (_, userSnap) {
        final otherUser = userSnap.data;
        final loadingIdentity = otherUser == null &&
            userSnap.connectionState == ConnectionState.waiting;
        if (!loadingIdentity && otherUser == null) {
          AppLog.debugThrottled(
            'recent_chats.peer_profile_missing_fallback:$otherUid',
            'recent_chats.peer_profile_missing_fallback',
          );
        }
        final displayName = otherUser?.safeDisplayName ?? 'Friendify User';
        final photoUrl = otherUser?.photoURL.trim() ?? '';

        return InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: openingThisChat
              ? null
              : () => _openResolvedChat(
                    direction: direction,
                    otherUid: otherUid,
                    initialOtherUser: otherUser,
                  ),
          child: Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.fromLTRB(11, 10, 10, 10),
            decoration: BoxDecoration(
              color: FriendifyBrand.pureWhite.withValues(alpha: 0.065),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: unread > 0
                    ? FriendifyBrand.lavenderGlow.withValues(alpha: 0.28)
                    : FriendifyBrand.pureWhite.withValues(alpha: 0.08),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.12),
                  blurRadius: 10,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: Row(
              children: [
                loadingIdentity
                    ? _loadingAvatar()
                    : _avatarSized(photoUrl, displayName, radius: 25),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      buildRecentChatPartnerName(
                        otherUser: otherUser,
                        loading: loadingIdentity,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: FriendifyBrand.slate,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 44,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (time.isNotEmpty)
                        Text(
                          time,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: FriendifyBrand.slate,
                            fontWeight: FontWeight.w700,
                            fontSize: 10.5,
                          ),
                        ),
                      const SizedBox(height: 5),
                      if (openingThisChat)
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: FriendifyBrand.lavenderGlow,
                          ),
                        )
                      else if (unread > 0)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            gradient: FriendifyBrand.primaryGradient,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            '$unread',
                            style: const TextStyle(
                              color: FriendifyBrand.pureWhite,
                              fontWeight: FontWeight.w900,
                              fontSize: 10.5,
                            ),
                          ),
                        )
                      else
                        const Icon(
                          Icons.chevron_right_rounded,
                          color: FriendifyBrand.slate,
                          size: 22,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ignore: unused_element
  Widget _chatsHeroCard({
    required AppUserModel me,
  }) {
    final followingCount = me.following.length;
    final favoriteCount = me.favoriteListeners.length;

    return Container(
      decoration: FriendifyBrand.panelDecoration(radius: 24, glow: true),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: const BoxDecoration(
                    gradient: FriendifyBrand.primaryGradient,
                    borderRadius: BorderRadius.all(Radius.circular(16)),
                  ),
                  child: const Icon(
                    Icons.chat_bubble_rounded,
                    color: FriendifyBrand.pureWhite,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Chats',
                        style: TextStyle(
                          color: FriendifyBrand.pureWhite,
                          fontSize: 24,
                          fontWeight: FontWeight.w900,
                          height: 1.05,
                        ),
                      ),
                      SizedBox(height: 3),
                      Text(
                        'Messages, approvals, and call-ready connections.',
                        style: TextStyle(
                          color: FriendifyBrand.slate,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _softChip(
                  icon: Icons.people_alt_rounded,
                  text: '$followingCount following',
                  bg: FriendifyBrand.softViolet.withValues(alpha: 0.16),
                  fg: FriendifyBrand.lavenderGlow,
                ),
                _softChip(
                  icon: Icons.favorite_rounded,
                  text: '$favoriteCount favorites',
                  bg: FriendifyBrand.magenta.withValues(alpha: 0.14),
                  fg: FriendifyBrand.lavenderGlow,
                ),
                _softChip(
                  icon: Icons.lock_rounded,
                  text: 'Private',
                  bg: FriendifyBrand.mintGreen.withValues(alpha: 0.12),
                  fg: FriendifyBrand.mintGreen,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  bool _chatMatchesSearch({
    required Map<String, dynamic> session,
    required String query,
    required String myUid,
  }) {
    final safeQuery = query.trim().toLowerCase();
    if (safeQuery.isEmpty) return true;

    final preview = _chatPreviewText(session).toLowerCase();
    if (preview.contains(safeQuery)) return true;

    final direction = ChatDirectionResolver.resolveForUser(
      session: session,
      myUid: myUid,
      fallbackSpeakerId: _safeString(session[FirestorePaths.fieldSpeakerId]),
      fallbackListenerId: _safeString(session[FirestorePaths.fieldListenerId]),
    );
    if (!direction.isResolved) return false;

    final otherUid = direction.otherUid;
    if (otherUid.toLowerCase().contains(safeQuery)) return true;

    final cachedUser = _resolvedChatUserCache[otherUid];
    if (cachedUser == null) return true;
    return cachedUser.safeDisplayName.toLowerCase().contains(safeQuery);
  }

  Widget _chatSearchField() {
    return Container(
      height: 46,
      decoration: BoxDecoration(
        color: FriendifyBrand.pureWhite.withValues(alpha: 0.075),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(
          color: FriendifyBrand.pureWhite.withValues(alpha: 0.10),
        ),
      ),
      child: TextField(
        controller: _chatSearchController,
        cursorColor: FriendifyBrand.lavenderGlow,
        style: const TextStyle(
          color: FriendifyBrand.pureWhite,
          fontWeight: FontWeight.w800,
        ),
        decoration: InputDecoration(
          prefixIcon: Icon(
            Icons.search_rounded,
            color: FriendifyBrand.pureWhite.withValues(alpha: 0.58),
          ),
          hintText: 'Search chats...',
          hintStyle: TextStyle(
            color: FriendifyBrand.pureWhite.withValues(alpha: 0.46),
            fontWeight: FontWeight.w800,
          ),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
        ),
      ),
    );
  }

  Widget _incomingRequestsCompact({
    required AppUserModel me,
  }) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      key: ValueKey<String>(
        'home_chat_requests_compact_${me.uid}_$_incomingRequestsRetryToken',
      ),
      stream: _incomingRequestsStreamFor(me),
      builder: (_, snap) {
        final allRequests = snap.data ?? const <Map<String, dynamic>>[];
        final requestsError = snap.hasError
            ? _humanizeChatStreamError(
                snap.error!,
                fallback: allRequests.isEmpty
                    ? 'Incoming requests could not load.'
                    : 'Showing saved requests until updates resume.',
              )
            : null;
        final visibleRequests = allRequests.where((item) {
          final status = _requestStatus(item);
          final blocked = _requestBlocked(item);
          final exists = item['exists'] == true;
          return exists &&
              !blocked &&
              status == FirestorePaths.chatStatusPending;
        }).toList(growable: false);
        final count = visibleRequests.length;
        final showingError = requestsError != null && visibleRequests.isEmpty;

        return InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: showingError
              ? _retryIncomingRequests
              : count == 0
                  ? null
                  : () => _openIncomingRequestsSheet(
                        me: me,
                        requests: visibleRequests,
                      ),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              color: FriendifyBrand.pureWhite.withValues(alpha: 0.065),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: showingError
                    ? FriendifyBrand.warning.withValues(alpha: 0.35)
                    : count > 0
                        ? FriendifyBrand.lavenderGlow.withValues(alpha: 0.26)
                        : FriendifyBrand.pureWhite.withValues(alpha: 0.08),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: FriendifyBrand.primaryGradient,
                  ),
                  child: const Icon(
                    Icons.person_add_alt_1_rounded,
                    color: FriendifyBrand.pureWhite,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        showingError
                            ? 'Incoming requests unavailable'
                            : 'Incoming chat requests',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: FriendifyBrand.pureWhite,
                          fontWeight: FontWeight.w900,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        showingError
                            ? requestsError
                            : count == 0
                                ? 'No active requests right now'
                                : '$count request${count == 1 ? '' : 's'} ready',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: showingError
                              ? FriendifyBrand.warning
                              : FriendifyBrand.slate,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  height: 30,
                  constraints: const BoxConstraints(minWidth: 30),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    gradient: count > 0 ? FriendifyBrand.primaryGradient : null,
                    color: count > 0
                        ? null
                        : FriendifyBrand.pureWhite.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    showingError ? 'Retry' : '$count',
                    style: const TextStyle(
                      color: FriendifyBrand.pureWhite,
                      fontWeight: FontWeight.w900,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  Icons.chevron_right_rounded,
                  color: FriendifyBrand.pureWhite.withValues(alpha: 0.55),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _openIncomingRequestsSheet({
    required AppUserModel me,
    required List<Map<String, dynamic>> requests,
  }) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: FriendifyBrand.deepIndigo,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Incoming chat requests (${requests.length})',
                    style: const TextStyle(
                      color: FriendifyBrand.pureWhite,
                      fontSize: 21,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ...List.generate(requests.length, (index) {
                    final item = requests[index];
                    final listenerIdFromRequest = _requestListenerId(item);
                    return Padding(
                      padding: EdgeInsets.only(
                        bottom: index == requests.length - 1 ? 0 : 10,
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
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _recentChatsSection({
    required AppUserModel me,
  }) {
    return Container(
      key: ValueKey<String>('home_recent_chats_${me.uid}'),
      child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        key: ValueKey<String>('home_recent_chats_stream_${me.uid}'),
        stream: _recentChatsStreamFor(me),
        builder: (_, recentChatsSnap) {
          final allDocs = recentChatsSnap.data?.docs ?? const [];
          final items = _buildPreferredChatSessionsForList(
            allDocs,
            myUid: me.uid,
          );
          final query = _chatSearchController.text.trim().toLowerCase();
          final visibleItems = items.where((item) {
            return _chatMatchesSearch(
              session: item,
              query: query,
              myUid: me.uid,
            );
          }).toList(growable: false);
          final recentChatsError = recentChatsSnap.hasError
              ? _humanizeChatStreamError(
                  recentChatsSnap.error!,
                  fallback: items.isEmpty
                      ? 'Recent chats could not load.'
                      : 'Showing saved chats until updates resume.',
                )
              : null;

          if (recentChatsSnap.connectionState == ConnectionState.waiting &&
              recentChatsSnap.data == null) {
            return _recentChatsLoadingPlaceholder();
          }

          if (recentChatsError != null && items.isEmpty) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _chatSearchField(),
                const SizedBox(height: 12),
                _incomingRequestsCompact(me: me),
                const SizedBox(height: 16),
                _streamDiagnosticState(
                  icon: Icons.chat_bubble_outline_rounded,
                  title: 'Recent chats unavailable',
                  message: recentChatsError,
                ),
              ],
            );
          }

          if (items.isEmpty) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _chatSearchField(),
                const SizedBox(height: 12),
                _incomingRequestsCompact(me: me),
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: FriendifyBrand.panelDecoration(radius: 18),
                  child: const Row(
                    children: [
                      Icon(
                        Icons.chat_bubble_outline_rounded,
                        color: FriendifyBrand.lavenderGlow,
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'No chats yet. Start chatting from a profile and your conversation history will appear here.',
                          style: TextStyle(
                            color: FriendifyBrand.slate,
                            fontWeight: FontWeight.w600,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _chatSearchField(),
              const SizedBox(height: 12),
              _incomingRequestsCompact(me: me),
              const SizedBox(height: 16),
              const Text(
                'Messages',
                style: TextStyle(
                  color: FriendifyBrand.pureWhite,
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              if (recentChatsError != null) ...[
                _streamWarningBanner(
                  icon: Icons.sync_problem_rounded,
                  title: 'Recent chats sync issue',
                  message: recentChatsError,
                ),
                const SizedBox(height: 12),
              ],
              if (visibleItems.isEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: FriendifyBrand.panelDecoration(radius: 18),
                  child: const Text(
                    'No chats match this search.',
                    style: TextStyle(
                      color: FriendifyBrand.slate,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                )
              else
                ...List.generate(visibleItems.length, (index) {
                  final item = visibleItems[index];
                  return Padding(
                    padding: EdgeInsets.only(
                      bottom: index == visibleItems.length - 1 ? 0 : 2,
                    ),
                    child: _chatTile(me: me, session: item),
                  );
                }),
            ],
          );
        },
      ),
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
        final speakerTopics = speaker == null
            ? const <String>[]
            : speaker.topics.take(3).toList();

        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: FriendifyBrand.pureWhite.withValues(alpha: 0.055),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: FriendifyBrand.pureWhite.withValues(alpha: 0.08),
            ),
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
                            color: FriendifyBrand.pureWhite,
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
                  color: FriendifyBrand.pureWhite,
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
                    color: FriendifyBrand.slate,
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
                          bg: FriendifyBrand.pureWhite.withValues(alpha: 0.08),
                          fg: FriendifyBrand.slate,
                        ),
                      )
                      .toList(),
                ),
              ],
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed:
                      (_requestActionBusy || speakerId.isEmpty || !exists)
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
                      onPressed: (_requestActionBusy ||
                              blocked ||
                              callAllowed ||
                              !exists)
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

  // Kept available for a future full request-management surface.
  // ignore: unused_element
  Widget _incomingRequestsSection({
    required AppUserModel me,
  }) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      key: ValueKey<String>(
        'home_incoming_requests_stream_${me.uid}_$_incomingRequestsRetryToken',
      ),
      stream: _incomingRequestsStreamFor(me),
      builder: (_, snap) {
        final allRequests = snap.data ?? const <Map<String, dynamic>>[];
        final requestsError = snap.hasError
            ? _humanizeChatStreamError(
                snap.error!,
                fallback: allRequests.isEmpty
                    ? 'Incoming requests could not load.'
                    : 'Showing saved requests until updates resume.',
              )
            : null;

        if (requestsError != null && allRequests.isEmpty) {
          return _sectionCard(
            key: const ValueKey<String>('home_incoming_requests_card'),
            title: 'Incoming Chat Requests',
            subtitle: 'Requests could not load.',
            children: [
              _streamDiagnosticState(
                icon: Icons.mark_chat_unread_outlined,
                title: 'Incoming requests unavailable',
                message:
                    '$requestsError Tap the compact request card to retry.',
              ),
            ],
          );
        }

        final visibleRequests = allRequests.where((item) {
          final status = _requestStatus(item);
          final blocked = _requestBlocked(item);
          final exists = item['exists'] == true;
          return exists &&
              !blocked &&
              status == FirestorePaths.chatStatusPending;
        }).toList();

        return _sectionCard(
          key: const ValueKey<String>('home_incoming_requests_card'),
          title: 'Incoming Chat Requests',
          subtitle: visibleRequests.isEmpty
              ? 'No active requests right now.'
              : '${visibleRequests.length} chat request${visibleRequests.length == 1 ? '' : 's'} ready for review.',
          children: [
            if (requestsError != null) ...[
              _streamWarningBanner(
                icon: Icons.sync_problem_rounded,
                title: 'Incoming requests sync issue',
                message: requestsError,
              ),
              const SizedBox(height: 12),
            ],
            if (visibleRequests.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: FriendifyBrand.pureWhite.withValues(alpha: 0.055),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: FriendifyBrand.pureWhite.withValues(alpha: 0.08),
                  ),
                ),
                child: const Text(
                  'New chat and call requests will appear here.',
                  style: TextStyle(
                    color: FriendifyBrand.slate,
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
          _dismissAnyFocus();
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
          _dismissAnyFocus();
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

  // ignore: unused_element
  String _greetingForNow() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 17) return 'Good afternoon';
    return 'Good evening';
  }

  List<AppUserModel> _filterDiscoveryListeners({
    required List<AppUserModel> listeners,
    required AppUserModel me,
  }) {
    final query = _homeSearchController.text.trim().toLowerCase();
    final visible = listeners.where((user) {
      if (user.uid == me.uid) return false;
      if (_homeListenerFilter == _HomeListenerFilter.online &&
          (!user.isAvailable || user.isOnCall)) {
        return false;
      }
      if (_homeListenerFilter == _HomeListenerFilter.favorites &&
          !me.favoriteListeners.contains(user.uid)) {
        return false;
      }
      if (query.isEmpty) return true;

      final haystack = <String>[
        user.safeDisplayName,
        user.bio,
        user.city,
        user.state,
        user.country,
        ...user.topics,
        ...user.languages,
      ].join(' ').toLowerCase();
      return haystack.contains(query);
    });

    final out = visible.toList(growable: false);
    out.sort((a, b) {
      if (_homeListenerFilter == _HomeListenerFilter.newer) {
        final aMs = a.createdAt?.millisecondsSinceEpoch ?? 0;
        final bMs = b.createdAt?.millisecondsSinceEpoch ?? 0;
        final createdCompare = bMs.compareTo(aMs);
        if (createdCompare != 0) return createdCompare;
      }

      final aOnline = a.isAvailable && !a.isOnCall;
      final bOnline = b.isAvailable && !b.isOnCall;
      if (aOnline != bOnline) return bOnline ? 1 : -1;

      if (query.isNotEmpty) {
        final queryCompare = _discoveryQueryScore(b, query).compareTo(
          _discoveryQueryScore(a, query),
        );
        if (queryCompare != 0) return queryCompare;
      }

      final profileCompare = _discoveryProfileScore(b).compareTo(
        _discoveryProfileScore(a),
      );
      if (profileCompare != 0) return profileCompare;

      final ratingCompare = b.ratingAvg.compareTo(a.ratingAvg);
      if (ratingCompare != 0) return ratingCompare;

      final ratingCountCompare = b.ratingCount.compareTo(a.ratingCount);
      if (ratingCountCompare != 0) return ratingCountCompare;

      final followersCompare = b.followersCount.compareTo(a.followersCount);
      if (followersCompare != 0) return followersCompare;

      final levelCompare = b.level.compareTo(a.level);
      if (levelCompare != 0) return levelCompare;

      final rateCompare = a.listenerRate.compareTo(b.listenerRate);
      if (rateCompare != 0) return rateCompare;

      return a.safeDisplayName.toLowerCase().compareTo(
            b.safeDisplayName.toLowerCase(),
          );
    });

    return out;
  }

  int _discoveryProfileScore(AppUserModel user) {
    return user.marketplaceProfileScore;
  }

  int _discoveryQueryScore(AppUserModel user, String query) {
    if (query.isEmpty) return 0;

    var score = 0;
    score += _discoveryTextMatchScore(
      user.safeDisplayName,
      query,
      exact: 90,
      startsWith: 60,
      contains: 35,
    );
    score += _discoveryTextMatchScore(
      user.bio,
      query,
      exact: 25,
      startsWith: 18,
      contains: 12,
    );
    score += _discoveryTextMatchScore(
      user.city,
      query,
      exact: 35,
      startsWith: 24,
      contains: 16,
    );
    score += _discoveryTextMatchScore(
      user.state,
      query,
      exact: 30,
      startsWith: 20,
      contains: 14,
    );
    score += _discoveryTextMatchScore(
      user.country,
      query,
      exact: 30,
      startsWith: 20,
      contains: 14,
    );

    for (final topic in user.topics) {
      score += _discoveryTextMatchScore(
        topic,
        query,
        exact: 80,
        startsWith: 52,
        contains: 34,
      );
    }

    for (final language in user.languages) {
      score += _discoveryTextMatchScore(
        language,
        query,
        exact: 70,
        startsWith: 46,
        contains: 30,
      );
    }

    if (user.isAvailable && !user.isOnCall) score += 8;
    if (user.ratingCount > 0) score += 6;
    if (user.photoURL.trim().isNotEmpty) score += 4;
    if (user.bio.trim().isNotEmpty) score += 3;
    return score;
  }

  int _discoveryTextMatchScore(
    String value,
    String query, {
    required int exact,
    required int startsWith,
    required int contains,
  }) {
    final safe = value.trim().toLowerCase();
    if (safe.isEmpty) return 0;
    if (safe == query) return exact;
    if (safe.startsWith(query)) return startsWith;
    if (safe.contains(query)) return contains;
    return 0;
  }

  Future<void> _openListenerProfile(AppUserModel user) async {
    _dismissAnyFocus();
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ListenerProfileScreen(
          listenerId: user.uid,
          initialUser: user,
        ),
      ),
    );
  }

  bool get _discoveryHasActiveFilterOrSearch =>
      _homeSearchController.text.trim().isNotEmpty ||
      _homeListenerFilter != _HomeListenerFilter.all;

  void _retryDiscovery() {
    setState(() => _discoveryRetryToken++);
  }

  void _clearDiscoveryFilters() {
    _homeSearchController.clear();
    setState(() => _homeListenerFilter = _HomeListenerFilter.all);
  }

  String _friendlyDiscoveryError(Object? error) {
    final raw = error?.toString().toLowerCase() ?? '';
    if (raw.contains('failed_precondition') ||
        raw.contains('requires an index') ||
        raw.contains('index is currently building')) {
      return 'The listener index is still preparing. Try again in a moment.';
    }
    if (raw.contains('permission-denied')) {
      return 'Listener discovery is not available for this account right now.';
    }
    if (raw.contains('unavailable') || raw.contains('network')) {
      return 'Listener discovery could not connect. Check your connection and retry.';
    }
    return 'Listener discovery could not load. Please retry.';
  }

  String _discoveryEmptyTitle() {
    if (_homeSearchController.text.trim().isNotEmpty) return 'No matches found';
    if (_homeListenerFilter == _HomeListenerFilter.online) {
      return 'No one is online';
    }
    if (_homeListenerFilter == _HomeListenerFilter.favorites) {
      return 'No favorites yet';
    }
    if (_homeListenerFilter == _HomeListenerFilter.newer) {
      return 'No new listeners yet';
    }
    return 'No listeners found';
  }

  String _discoveryEmptySubtitle() {
    if (_homeSearchController.text.trim().isNotEmpty) {
      return 'Try a different name, topic, language, or location.';
    }
    if (_homeListenerFilter == _HomeListenerFilter.online) {
      return 'Clear filters to browse listeners who may come online soon.';
    }
    if (_homeListenerFilter == _HomeListenerFilter.favorites) {
      return 'Favorite listeners from their profile to keep them here.';
    }
    if (_homeListenerFilter == _HomeListenerFilter.newer) {
      return 'Clear filters to browse the current listener marketplace.';
    }
    return 'Check again shortly as listeners finish their profiles.';
  }

  void _openMyProfile() {
    _dismissAnyFocus();
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ProfileScreen()),
    );
  }

  Widget _discoveryReadinessBanner(AppUserModel me) {
    final completeness = me.profileCompletenessPercent.clamp(0, 100);
    final missingItems = me.profileCompletionMissingItems.take(4).toList();
    final missingText = missingItems.isEmpty
        ? 'Add a few more profile details.'
        : 'Missing: ${missingItems.join(', ')}';

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: FriendifyBrand.lavenderGlow.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: FriendifyBrand.lavenderGlow.withValues(alpha: 0.28),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: FriendifyBrand.pureWhite.withValues(alpha: 0.09),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.auto_awesome_rounded,
              color: FriendifyBrand.lavenderGlow,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Boost your discovery profile',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: FriendifyBrand.pureWhite,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    Text(
                      '$completeness%',
                      style: const TextStyle(
                        color: FriendifyBrand.lavenderGlow,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  missingText,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: FriendifyBrand.pureWhite.withValues(alpha: 0.68),
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: _openMyProfile,
                    icon: const Icon(Icons.edit_rounded),
                    label: const Text('Complete profile'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _homeDiscoverySection(AppUserModel me) {
    return StreamBuilder<List<AppUserModel>>(
      key: ValueKey<int>(_discoveryRetryToken),
      stream: _userRepository.watchAvailableListeners(limit: 40),
      builder: (_, snap) {
        final listeners = _filterDiscoveryListeners(
          listeners: snap.data ?? const <AppUserModel>[],
          me: me,
        );

        final loading = snap.connectionState == ConnectionState.waiting &&
            snap.data == null;
        final discoveryError =
            snap.hasError ? _friendlyDiscoveryError(snap.error) : '';
        final showReadinessBanner = !me.isDiscoveryReady;
        final listedListeners = listeners.take(24).toList(growable: false);
        final pagePadding = FriendifyBrand.screenPadding(
          context,
          top: 18,
          bottom: 116,
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                pagePadding.left,
                pagePadding.top,
                pagePadding.right,
                0,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _friendifyReferenceHeader(me),
                  const SizedBox(height: 22),
                  const Text(
                    'Someone is\nalways ready\nto listen.',
                    style: TextStyle(
                      color: FriendifyBrand.pureWhite,
                      fontSize: 28,
                      height: 1.14,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0,
                    ),
                  ),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    switchInCurve: Curves.easeOut,
                    switchOutCurve: Curves.easeIn,
                    child: _discoveryChromeCollapsed
                        ? const SizedBox(
                            key: ValueKey<String>('collapsed_discovery_tools'),
                            height: 10,
                          )
                        : Column(
                            key: const ValueKey<String>(
                                'expanded_discovery_tools'),
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 20),
                              _referenceSearchField(),
                              const SizedBox(height: 14),
                              _referenceFilterTabs(),
                              const SizedBox(height: 14),
                            ],
                          ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : discoveryError.isNotEmpty && listeners.isEmpty
                      ? ListView(
                          controller: _discoveryListController,
                          padding: EdgeInsets.fromLTRB(
                            pagePadding.left,
                            0,
                            pagePadding.right,
                            pagePadding.bottom,
                          ),
                          children: [
                            if (showReadinessBanner)
                              _discoveryReadinessBanner(me),
                            _referenceEmptyState(
                              title: 'Could not load listeners',
                              subtitle: discoveryError,
                              actionLabel: 'Retry',
                              onAction: _retryDiscovery,
                            ),
                          ],
                        )
                      : ListView.builder(
                          controller: _discoveryListController,
                          padding: EdgeInsets.fromLTRB(
                            pagePadding.left,
                            0,
                            pagePadding.right,
                            pagePadding.bottom,
                          ),
                          itemCount: (showReadinessBanner ? 1 : 0) +
                              (listedListeners.isEmpty
                                  ? 1
                                  : listedListeners.length),
                          itemBuilder: (_, index) {
                            if (showReadinessBanner && index == 0) {
                              return _discoveryReadinessBanner(me);
                            }
                            final contentIndex =
                                showReadinessBanner ? index - 1 : index;
                            if (listedListeners.isEmpty) {
                              return _referenceEmptyState(
                                title: _discoveryEmptyTitle(),
                                subtitle: _discoveryEmptySubtitle(),
                                actionLabel: _discoveryHasActiveFilterOrSearch
                                    ? 'Clear filters'
                                    : null,
                                onAction: _discoveryHasActiveFilterOrSearch
                                    ? _clearDiscoveryFilters
                                    : null,
                              );
                            }
                            final user = listedListeners[contentIndex];
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: _referenceListenerCard(user),
                            );
                          },
                        ),
            ),
          ],
        );
      },
    );
  }

  Widget _homeFeedSection(AppUserModel me) {
    return StreamBuilder<List<SocialPostModel>>(
      key: ValueKey<int>(_socialFeedRetryToken),
      stream: _socialRepository.watchFeedPosts(limit: 60),
      builder: (_, postSnap) {
        return StreamBuilder<List<AppUserModel>>(
          stream: _userRepository.watchAvailableListeners(limit: 30),
          builder: (_, peopleSnap) {
            final people = (peopleSnap.data ?? const <AppUserModel>[])
                .where((user) => user.uid != me.uid)
                .toList(growable: false);
            final feedPeople = people.isEmpty ? <AppUserModel>[me] : people;
            final posts = (postSnap.data ?? const <SocialPostModel>[])
                .where(
                  (post) => !_hiddenDeletedSocialPostIds.contains(post.postId),
                )
                .toList(growable: false);
            final loadingPosts =
                postSnap.connectionState == ConnectionState.waiting &&
                    postSnap.data == null;
            final feedError = postSnap.hasError
                ? _friendlySocialFeedError(postSnap.error)
                : '';

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _feedTopBar(),
                const SizedBox(height: 18),
                _feedStoriesRow(me: me, people: feedPeople.take(8).toList()),
                const SizedBox(height: 18),
                if (feedError.isNotEmpty && posts.isEmpty)
                  _socialFeedStateCard(
                    icon: Icons.cloud_off_rounded,
                    title: 'Could not load posts',
                    subtitle: feedError,
                    actionLabel: 'Retry',
                    actionIcon: Icons.refresh_rounded,
                    onAction: _retrySocialFeed,
                  )
                else if (loadingPosts)
                  const SizedBox(
                    height: 180,
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (posts.isNotEmpty)
                  ...posts.map(
                    (post) => Padding(
                      padding: const EdgeInsets.only(bottom: 18),
                      child: _socialPostCard(post, me: me),
                    ),
                  )
                else ...[
                  _socialFeedStateCard(
                    icon: Icons.add_photo_alternate_rounded,
                    title: 'Start the feed',
                    subtitle:
                        'Share the first photo post, or discover listeners below while the feed grows.',
                    actionLabel: 'Create post',
                    actionIcon: Icons.add_rounded,
                    onAction: () => _showCreateFeedPostSheet(me),
                  ),
                  const SizedBox(height: 18),
                  ...feedPeople.take(12).map(
                        (user) => Padding(
                          padding: const EdgeInsets.only(bottom: 18),
                          child: _feedPostCard(user, me: me),
                        ),
                      ),
                ],
              ],
            );
          },
        );
      },
    );
  }

  void _retrySocialFeed() {
    setState(() => _socialFeedRetryToken++);
  }

  String _friendlySocialFeedError(Object? error) {
    final raw = error?.toString().toLowerCase() ?? '';
    if (raw.contains('failed_precondition') ||
        raw.contains('requires an index') ||
        raw.contains('index is currently building')) {
      return 'The feed index is still preparing. Try again in a moment.';
    }
    if (raw.contains('permission-denied')) {
      return 'Your account cannot read the feed right now. Please refresh after permissions sync.';
    }
    if (raw.contains('unavailable') || raw.contains('network')) {
      return 'The feed could not connect. Check your connection and try again.';
    }
    return 'Posts could not be loaded. Please try again.';
  }

  Widget _socialFeedStateCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required String actionLabel,
    required IconData actionIcon,
    required VoidCallback onAction,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF11162E).withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: FriendifyBrand.lavenderGlow.withValues(alpha: 0.16),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.16),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: FriendifyBrand.iconTileDecoration(),
            child: Icon(icon, color: FriendifyBrand.pureWhite),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: FriendifyBrand.pureWhite,
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: FriendifyBrand.pureWhite.withValues(alpha: 0.68),
                    fontSize: 13.5,
                    height: 1.32,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    onPressed: onAction,
                    icon: Icon(actionIcon, size: 18),
                    label: Text(actionLabel),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _feedTopBar() {
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.asset(
            'assets/branding/friendify_icon_1024.png',
            width: 38,
            height: 38,
            fit: BoxFit.cover,
          ),
        ),
        const SizedBox(width: 8),
        const Expanded(
          child: Text(
            'friendify',
            style: TextStyle(
              color: FriendifyBrand.pureWhite,
              fontSize: 25,
              fontWeight: FontWeight.w900,
              letterSpacing: 0,
            ),
          ),
        ),
        StreamBuilder<int>(
          stream: _socialRepository.watchUnreadNotificationCount(),
          builder: (context, snapshot) {
            final unread = snapshot.data ?? 0;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                IconButton(
                  tooltip: unread > 0
                      ? '$unread unread notifications'
                      : 'Notifications',
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const NotificationsCenterScreen(),
                      ),
                    );
                  },
                  icon: Icon(unread > 0
                      ? Icons.notifications_active_rounded
                      : Icons.notifications_none_rounded),
                  color: FriendifyBrand.pureWhite,
                ),
                if (unread > 0)
                  Positioned(
                    right: 7,
                    top: 7,
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 17),
                      height: 17,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(
                        gradient: FriendifyBrand.primaryGradient,
                        shape: BoxShape.rectangle,
                        borderRadius: BorderRadius.all(Radius.circular(999)),
                      ),
                      child: Text(
                        unread > 9 ? '9+' : '$unread',
                        style: const TextStyle(
                          color: FriendifyBrand.pureWhite,
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
        IconButton(
          tooltip: 'Chats',
          onPressed: () {
            _dismissAnyFocus();
            final openChats = widget.onOpenChats;
            if (openChats != null) {
              openChats();
              return;
            }
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const HomeScreen(mode: HomeScreenMode.chats),
              ),
            );
          },
          icon: const Icon(Icons.chat_bubble_outline_rounded),
          color: FriendifyBrand.pureWhite,
        ),
      ],
    );
  }

  Widget _feedStoriesRow({
    required AppUserModel me,
    required List<AppUserModel> people,
  }) {
    return StreamBuilder<List<SocialPostModel>>(
      key: ValueKey<int>(_storyRetryToken),
      stream: _socialRepository.watchActiveStories(limit: 80),
      builder: (_, storySnap) {
        final storiesByOwner = <String, SocialPostModel>{};
        final activeStories = (storySnap.data ?? const <SocialPostModel>[])
            .where((story) => story.isActiveStory)
            .toList(growable: false);
        for (final story in activeStories) {
          storiesByOwner.putIfAbsent(story.ownerId, () => story);
        }
        final loadingStories =
            storySnap.connectionState == ConnectionState.waiting &&
                storySnap.data == null;
        final storyError =
            storySnap.hasError ? _friendlyStoryError(storySnap.error) : '';
        final showStatusTile =
            (loadingStories || storyError.isNotEmpty) && activeStories.isEmpty;

        final storyPeople = <AppUserModel>[
          me,
          ...people.where((u) => u.uid != me.uid),
        ];

        return SizedBox(
          height: 94,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: storyPeople.length + (showStatusTile ? 1 : 0),
            separatorBuilder: (_, __) => const SizedBox(width: 13),
            itemBuilder: (_, index) {
              if (showStatusTile && index == 1) {
                return _storyStatusTile(
                  loading: loadingStories,
                  message: storyError,
                  onTap: storyError.isEmpty ? null : _retryStories,
                );
              }
              final userIndex = showStatusTile && index > 1 ? index - 1 : index;
              final user = storyPeople[userIndex];
              final isMe = userIndex == 0;
              final story = storiesByOwner[user.uid];
              return SizedBox(
                width: 72,
                child: Column(
                  children: [
                    InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: () {
                        if (story == null && isMe) {
                          _showCreateFeedContentMenu(me);
                          return;
                        }
                        if (story != null) {
                          final storyIndex = activeStories.indexWhere(
                            (candidate) => candidate.postId == story.postId,
                          );
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => StoryViewerScreen(
                                stories: activeStories,
                                initialIndex: storyIndex < 0 ? 0 : storyIndex,
                              ),
                            ),
                          );
                        }
                      },
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Container(
                            width: 66,
                            height: 66,
                            padding: const EdgeInsets.all(2),
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: FriendifyBrand.primaryGradient,
                            ),
                            child: story == null
                                ? _feedAvatar(user, size: 62)
                                : _feedStoryAvatar(
                                    user,
                                    story: story,
                                    size: 62,
                                  ),
                          ),
                          if (isMe)
                            Positioned(
                              right: -1,
                              bottom: -1,
                              child: Container(
                                width: 22,
                                height: 22,
                                decoration: BoxDecoration(
                                  color: FriendifyBrand.softViolet,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: FriendifyBrand.deepIndigo,
                                    width: 2,
                                  ),
                                ),
                                child: const Icon(
                                  Icons.add_rounded,
                                  color: FriendifyBrand.pureWhite,
                                  size: 16,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      isMe ? 'You' : user.safeDisplayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: FriendifyBrand.pureWhite.withValues(alpha: 0.74),
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  void _retryStories() {
    setState(() => _storyRetryToken++);
  }

  String _friendlyStoryError(Object? error) {
    final raw = error?.toString().toLowerCase() ?? '';
    if (raw.contains('failed_precondition') ||
        raw.contains('requires an index') ||
        raw.contains('index is currently building')) {
      return 'Story index is preparing';
    }
    if (raw.contains('permission-denied')) {
      return 'Stories are locked';
    }
    if (raw.contains('unavailable') || raw.contains('network')) {
      return 'Stories are offline';
    }
    return 'Stories unavailable';
  }

  Widget _storyStatusTile({
    required bool loading,
    required String message,
    required VoidCallback? onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Container(
        width: 148,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFF11162E).withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: FriendifyBrand.pureWhite.withValues(alpha: 0.08),
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 34,
              height: 34,
              child: loading
                  ? const CircularProgressIndicator(strokeWidth: 2)
                  : const Icon(
                      Icons.refresh_rounded,
                      color: FriendifyBrand.pureWhite,
                    ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                loading ? 'Loading stories' : '$message. Tap retry.',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: FriendifyBrand.pureWhite.withValues(alpha: 0.72),
                  fontSize: 12,
                  height: 1.15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showCreateFeedContentMenu(AppUserModel me) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: FriendifyBrand.darkSurfaceElevated,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Create',
                  style: TextStyle(
                    color: FriendifyBrand.pureWhite,
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 10),
                _createContentTile(
                  icon: Icons.grid_on_rounded,
                  title: 'Post',
                  subtitle: 'Choose a photo and write a caption',
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _showCreateFeedPostSheet(me);
                  },
                ),
                _createContentTile(
                  icon: Icons.auto_stories_rounded,
                  title: 'Story',
                  subtitle: 'Choose a photo for your story ring',
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(_createFeedStory(me));
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _createContentTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(
        width: 42,
        height: 42,
        decoration: FriendifyBrand.iconTileDecoration(),
        child: Icon(icon, color: FriendifyBrand.pureWhite),
      ),
      title: Text(
        title,
        style: const TextStyle(
          color: FriendifyBrand.pureWhite,
          fontWeight: FontWeight.w900,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(
          color: FriendifyBrand.slate,
          fontWeight: FontWeight.w700,
        ),
      ),
      trailing: const Icon(
        Icons.chevron_right_rounded,
        color: FriendifyBrand.slate,
      ),
      onTap: onTap,
    );
  }

  Future<void> _createFeedStory(AppUserModel me) async {
    if (_creatingStory) {
      _showSnack('Story is already uploading.');
      return;
    }
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 82,
      maxWidth: 1600,
      maxHeight: 1600,
    );
    if (picked == null) return;

    setState(() => _creatingStory = true);
    try {
      await _socialRepository.createPost(
        owner: me,
        imageFile: File(picked.path),
        caption: 'Story',
        isStory: true,
      );
      if (!mounted) return;
      _showSnack('Story added.');
    } on StateError catch (e) {
      if (!mounted) return;
      _showSnack(e.message);
    } catch (_) {
      if (!mounted) return;
      _showSnack('Story upload failed. Please try again.');
    } finally {
      if (mounted) {
        setState(() => _creatingStory = false);
      } else {
        _creatingStory = false;
      }
    }
  }

  void _showCreateFeedPostSheet(AppUserModel me) {
    final captionController = TextEditingController();
    XFile? pickedImage;
    var uploading = false;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: FriendifyBrand.darkSurfaceElevated,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final validationMessage =
                SocialRepository.postDraftValidationMessage(
              caption: captionController.text,
              hasImage: pickedImage != null,
            );
            final canPublish = !uploading && validationMessage == null;

            Future<void> pickImage() async {
              if (uploading) return;
              final picked = await ImagePicker().pickImage(
                source: ImageSource.gallery,
                imageQuality: 84,
                maxWidth: 1800,
                maxHeight: 1800,
              );
              if (picked == null) return;
              setSheetState(() => pickedImage = picked);
            }

            void publish() {
              if (uploading) return;
              final validationMessage =
                  SocialRepository.postDraftValidationMessage(
                caption: captionController.text,
                hasImage: pickedImage != null,
              );
              if (validationMessage != null) {
                _showSnack(validationMessage);
                return;
              }
              final caption = captionController.text.trim();
              final imagePath = pickedImage?.path.trim() ?? '';
              setSheetState(() => uploading = true);
              unawaited(() async {
                try {
                  await _socialRepository.createPost(
                    owner: me,
                    imageFile: File(imagePath),
                    caption: caption,
                  );
                  if (!mounted || !sheetContext.mounted) return;
                  Navigator.of(sheetContext).pop();
                  _showSnack('Post added to your profile.');
                } on StateError catch (e) {
                  if (!mounted || !sheetContext.mounted) return;
                  setSheetState(() => uploading = false);
                  _showSnack(e.message);
                } catch (_) {
                  if (!mounted || !sheetContext.mounted) return;
                  setSheetState(() => uploading = false);
                  _showSnack('Post upload failed. Please try again.');
                }
              }());
            }

            return Padding(
              padding: EdgeInsets.fromLTRB(
                18,
                4,
                18,
                MediaQuery.viewInsetsOf(sheetContext).bottom + 18,
              ),
              child: SafeArea(
                top: false,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'New post',
                        style: TextStyle(
                          color: FriendifyBrand.pureWhite,
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 12),
                      InkWell(
                        onTap: pickImage,
                        borderRadius: BorderRadius.circular(18),
                        child: AspectRatio(
                          aspectRatio: 1.35,
                          child: Container(
                            decoration: BoxDecoration(
                              color: FriendifyBrand.pureWhite
                                  .withValues(alpha: 0.07),
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: FriendifyBrand.pureWhite
                                    .withValues(alpha: 0.12),
                              ),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: pickedImage == null
                                ? const Center(
                                    child: Icon(
                                      Icons.add_photo_alternate_outlined,
                                      color: FriendifyBrand.lavenderGlow,
                                      size: 42,
                                    ),
                                  )
                                : Image.file(
                                    File(pickedImage!.path),
                                    fit: BoxFit.cover,
                                  ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: captionController,
                        minLines: 2,
                        maxLines: 4,
                        maxLength: 180,
                        onChanged: (_) => setSheetState(() {}),
                        style: const TextStyle(color: FriendifyBrand.pureWhite),
                        decoration: InputDecoration(
                          hintText: 'Write a caption...',
                          hintStyle: TextStyle(
                            color: FriendifyBrand.pureWhite
                                .withValues(alpha: 0.42),
                          ),
                          filled: true,
                          fillColor:
                              FriendifyBrand.pureWhite.withValues(alpha: 0.07),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(18),
                            borderSide: BorderSide(
                              color: FriendifyBrand.pureWhite
                                  .withValues(alpha: 0.12),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: canPublish ? publish : null,
                          icon: uploading
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.publish_rounded),
                          label:
                              Text(uploading ? 'Uploading...' : 'Upload post'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    ).whenComplete(captionController.dispose);
  }

  void _toggleFeedLike(AppUserModel user) {
    final postId = user.uid;
    var liked = false;
    setState(() {
      liked = _likedFeedPosts.add(postId);
      if (!liked) {
        _likedFeedPosts.remove(postId);
      }
    });
    _showSnack(liked ? 'Liked post.' : 'Removed like.');
  }

  void _likeFeedPost(AppUserModel user) {
    final postId = user.uid;
    if (_likedFeedPosts.contains(postId)) return;
    setState(() {
      _likedFeedPosts.add(postId);
    });
    _showSnack('Liked post.');
  }

  void _toggleFeedSave(AppUserModel user) {
    final postId = user.uid;
    setState(() {
      if (!_savedFeedPosts.add(postId)) {
        _savedFeedPosts.remove(postId);
      }
    });
    _showSnack(_savedFeedPosts.contains(postId)
        ? 'Saved post.'
        : 'Removed saved post.');
  }

  Future<void> _shareFeedPost(AppUserModel user, String caption) async {
    final text = '${user.safeDisplayName} on Friendify\n$caption';
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() {
      _feedShareCounts[user.uid] = (_feedShareCounts[user.uid] ?? 0) + 1;
    });
    _showSnack('Post copied. Share it anywhere.');
  }

  void _showFeedCommentsSheet(AppUserModel user) {
    final postId = user.uid;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: FriendifyBrand.darkSurfaceElevated,
      builder: (sheetContext) {
        return _FeedCommentsSheet(
          displayName: user.safeDisplayName,
          photoURL: user.photoURL.trim(),
          initialComments: (_feedComments[postId] ?? const <String>[])
              .map(SocialCommentModel.local)
              .toList(growable: false),
          onCommentAdded: (text) {
            if (!mounted) return;
            setState(() {
              _feedComments.putIfAbsent(postId, () => <String>[]).add(text);
            });
          },
        );
      },
    ).whenComplete(() {
      if (mounted) setState(() {});
    });
  }

  void _showFeedPostOptions(
      AppUserModel user, AppUserModel me, String caption) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: FriendifyBrand.darkSurfaceElevated,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.person_outline_rounded),
                  iconColor: FriendifyBrand.lavenderGlow,
                  textColor: FriendifyBrand.pureWhite,
                  title: const Text('View profile'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    if (user.uid == me.uid) {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const ProfileScreen()),
                      );
                    } else {
                      unawaited(_openListenerProfile(user));
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.chat_bubble_outline_rounded),
                  iconColor: FriendifyBrand.lavenderGlow,
                  textColor: FriendifyBrand.pureWhite,
                  title: const Text('Open chat menu'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    final openChats = widget.onOpenChats;
                    if (openChats != null) {
                      openChats();
                      return;
                    }
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            const HomeScreen(mode: HomeScreenMode.chats),
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.copy_rounded),
                  iconColor: FriendifyBrand.lavenderGlow,
                  textColor: FriendifyBrand.pureWhite,
                  title: const Text('Copy post'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(_shareFeedPost(user, caption));
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _toggleSocialPostLike(SocialPostModel post, {bool? likedOverride}) {
    final postId = post.postId;
    final liked = likedOverride ?? _likedFeedPosts.contains(postId);
    setState(() {
      if (liked) {
        _likedFeedPosts.remove(postId);
      } else {
        _likedFeedPosts.add(postId);
      }
    });
    unawaited(_ignoreSocialAction(
      liked
          ? _socialRepository.unlikePost(postId)
          : _socialRepository.likePost(postId),
      onFailure: () => _restoreLocalLike(postId, liked: liked),
    ));
    _showSnack(liked ? 'Removed like.' : 'Liked post.');
  }

  void _likeSocialPost(SocialPostModel post) {
    if (_likedFeedPosts.contains(post.postId)) return;
    setState(() => _likedFeedPosts.add(post.postId));
    unawaited(_ignoreSocialAction(
      _socialRepository.likePost(post.postId),
      onFailure: () => _restoreLocalLike(post.postId, liked: false),
    ));
    _showSnack('Liked post.');
  }

  void _toggleSocialPostSave(SocialPostModel post, {bool? savedOverride}) {
    final postId = post.postId;
    final saved = savedOverride ?? _savedFeedPosts.contains(postId);
    setState(() {
      if (saved) {
        _savedFeedPosts.remove(postId);
      } else {
        _savedFeedPosts.add(postId);
      }
    });
    unawaited(_ignoreSocialAction(
      saved
          ? _socialRepository.unsavePost(postId)
          : _socialRepository.savePost(postId),
      onFailure: () => _restoreLocalSave(postId, saved: saved),
    ));
    _showSnack(saved ? 'Removed saved post.' : 'Saved post.');
  }

  Future<void> _shareSocialPost(SocialPostModel post) async {
    final text = '${post.ownerName} on Friendify\n${post.caption}';
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() {
      _feedShareCounts[post.postId] = (_feedShareCounts[post.postId] ?? 0) + 1;
    });
    unawaited(_ignoreSocialAction(
      _socialRepository.sharePost(post.postId),
      onSuccess: () => _releaseLocalShareDelta(post.postId),
      onFailure: () => _releaseLocalShareDelta(post.postId),
    ));
    _showSnack('Post copied. Share it anywhere.');
  }

  Future<void> _deleteSocialPostFromFeed(SocialPostModel post) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Delete post?'),
            content:
                const Text('This removes the post from feeds and profile.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;
    if (!mounted || !confirmed) return;

    try {
      await _socialRepository.deletePost(post);
      if (!mounted) return;
      setState(() {
        _hiddenDeletedSocialPostIds.add(post.postId);
        _likedFeedPosts.remove(post.postId);
        _savedFeedPosts.remove(post.postId);
        _feedShareCounts.remove(post.postId);
        _feedComments.remove(post.postId);
      });
      _showSnack('Post deleted.');
    } catch (_) {
      _showSnack('Delete failed. Please try again.');
    }
  }

  Future<void> _reportSocialPostFromFeed(SocialPostModel post) async {
    final reason = await showUserSafetyReportReasonSheet(
      context,
      title: 'Report post',
    );
    if (!mounted || reason == null || reason.trim().isEmpty) return;

    try {
      await _socialRepository.reportPost(
        postId: post.postId,
        reason: reason,
      );
      _showSnack('Report submitted. Our team will review it.');
    } catch (_) {
      _showSnack('Report failed. Please try again.');
    }
  }

  void _openSocialPostDetail(SocialPostModel post) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PostDetailScreen(initialPost: post),
      ),
    );
  }

  void _showSocialPostCommentsSheet(SocialPostModel post) {
    final postId = post.postId;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: FriendifyBrand.darkSurfaceElevated,
      builder: (sheetContext) {
        return _FeedCommentsSheet(
          displayName: post.ownerName,
          photoURL: post.ownerPhotoURL,
          commentsStream: _socialRepository.watchComments(postId),
          initialComments: (_feedComments[postId] ?? const <String>[])
              .map(SocialCommentModel.local)
              .toList(growable: false),
          onCommentAdded: (text) {
            if (!mounted) return;
            setState(() {
              _feedComments.putIfAbsent(postId, () => <String>[]).add(text);
            });
            unawaited(_ignoreSocialAction(
              _socialRepository.addComment(
                postId: postId,
                text: text,
              ),
              onSuccess: () => _releaseLocalCommentDelta(postId, text),
              onFailure: () {
                _releaseLocalCommentDelta(postId, text);
                _showSnack('Comment failed. Please try again.');
              },
            ));
          },
        );
      },
    ).whenComplete(() {
      if (mounted) setState(() {});
    });
  }

  Future<void> _ignoreSocialAction(
    Future<void> action, {
    VoidCallback? onSuccess,
    VoidCallback? onFailure,
  }) async {
    try {
      await action;
      if (mounted) onSuccess?.call();
    } catch (_) {
      if (mounted) onFailure?.call();
      // Keep feed gestures responsive if the network drops; the server owns
      // durable engagement counters and will be retried by a later action.
    }
  }

  void _restoreLocalLike(String postId, {required bool liked}) {
    setState(() {
      if (liked) {
        _likedFeedPosts.add(postId);
      } else {
        _likedFeedPosts.remove(postId);
      }
    });
  }

  void _restoreLocalSave(String postId, {required bool saved}) {
    setState(() {
      if (saved) {
        _savedFeedPosts.add(postId);
      } else {
        _savedFeedPosts.remove(postId);
      }
    });
  }

  void _releaseLocalShareDelta(String postId) {
    final current = _feedShareCounts[postId] ?? 0;
    if (current <= 1) {
      setState(() => _feedShareCounts.remove(postId));
      return;
    }
    setState(() => _feedShareCounts[postId] = current - 1);
  }

  void _releaseLocalCommentDelta(String postId, String text) {
    final comments = _feedComments[postId];
    if (comments == null || comments.isEmpty) return;
    setState(() {
      comments.remove(text);
      if (comments.isEmpty) {
        _feedComments.remove(postId);
      }
    });
  }

  void _showSocialPostOptions(SocialPostModel post, AppUserModel me) {
    final isOwner = post.ownerId == me.uid;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: FriendifyBrand.darkSurfaceElevated,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.open_in_full_rounded),
                  iconColor: FriendifyBrand.lavenderGlow,
                  textColor: FriendifyBrand.pureWhite,
                  title: const Text('Open post'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _openSocialPostDetail(post);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.person_outline_rounded),
                  iconColor: FriendifyBrand.lavenderGlow,
                  textColor: FriendifyBrand.pureWhite,
                  title: const Text('View profile'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    if (post.ownerId == me.uid) {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const ProfileScreen(),
                        ),
                      );
                      return;
                    }
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ListenerProfileScreen(
                          listenerId: post.ownerId,
                        ),
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.copy_rounded),
                  iconColor: FriendifyBrand.lavenderGlow,
                  textColor: FriendifyBrand.pureWhite,
                  title: const Text('Copy post'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(_shareSocialPost(post));
                  },
                ),
                if (isOwner)
                  ListTile(
                    leading: const Icon(Icons.delete_outline_rounded),
                    iconColor: Colors.redAccent,
                    textColor: FriendifyBrand.pureWhite,
                    title: const Text('Delete post'),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      unawaited(_deleteSocialPostFromFeed(post));
                    },
                  )
                else
                  ListTile(
                    leading: const Icon(Icons.flag_outlined),
                    iconColor: Colors.redAccent,
                    textColor: FriendifyBrand.pureWhite,
                    title: const Text('Report post'),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      unawaited(_reportSocialPostFromFeed(post));
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _socialPostCard(SocialPostModel post, {required AppUserModel me}) {
    return StreamBuilder<bool>(
      stream: _socialRepository.watchPostLikedByMe(post.postId),
      initialData: _likedFeedPosts.contains(post.postId),
      builder: (context, likedSnapshot) {
        final serverLiked = likedSnapshot.data == true;
        final optimisticLiked =
            _likedFeedPosts.contains(post.postId) && !serverLiked;
        final liked = serverLiked || optimisticLiked;
        final commentCount =
            post.commentCount + (_feedComments[post.postId]?.length ?? 0);
        final shareCount =
            post.shareCount + (_feedShareCounts[post.postId] ?? 0);
        final likeCount = post.likeCount + (optimisticLiked ? 1 : 0);

        return StreamBuilder<bool>(
          stream: _socialRepository.watchPostSavedByMe(post.postId),
          initialData: _savedFeedPosts.contains(post.postId),
          builder: (context, savedSnapshot) {
            final serverSaved = savedSnapshot.data == true;
            final optimisticSaved =
                _savedFeedPosts.contains(post.postId) && !serverSaved;
            final saved = serverSaved || optimisticSaved;

            return InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => _openSocialPostDetail(post),
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF10162D).withValues(alpha: 0.94),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: FriendifyBrand.pureWhite.withValues(alpha: 0.06),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(13, 12, 10, 10),
                      child: Row(
                        children: [
                          _feedAvatarFromValues(
                            photoURL: post.ownerPhotoURL,
                            name: post.ownerName,
                            size: 42,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: InkWell(
                              onTap: () {
                                if (post.ownerId == me.uid) {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => const ProfileScreen(),
                                    ),
                                  );
                                  return;
                                }
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => ListenerProfileScreen(
                                      listenerId: post.ownerId,
                                    ),
                                  ),
                                );
                              },
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    post.ownerName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: FriendifyBrand.pureWhite,
                                      fontSize: 15.5,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    'Friendify listener',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: FriendifyBrand.pureWhite
                                          .withValues(alpha: 0.56),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Post menu',
                            onPressed: () => _showSocialPostOptions(post, me),
                            icon: const Icon(Icons.more_vert_rounded),
                            color: FriendifyBrand.pureWhite
                                .withValues(alpha: 0.82),
                          ),
                        ],
                      ),
                    ),
                    GestureDetector(
                      onDoubleTap: () => _likeSocialPost(post),
                      child: _socialPostMedia(post),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 13),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              _feedActionIcon(
                                liked
                                    ? Icons.favorite_rounded
                                    : Icons.favorite_border_rounded,
                                'Like',
                                onPressed: () => _toggleSocialPostLike(post,
                                    likedOverride: liked),
                                active: liked,
                              ),
                              _feedActionIcon(
                                Icons.chat_bubble_outline_rounded,
                                'Comment',
                                onPressed: () =>
                                    _showSocialPostCommentsSheet(post),
                              ),
                              _feedActionIcon(
                                Icons.send_rounded,
                                'Share',
                                onPressed: () =>
                                    unawaited(_shareSocialPost(post)),
                              ),
                              const Spacer(),
                              _feedActionIcon(
                                saved
                                    ? Icons.bookmark_rounded
                                    : Icons.bookmark_border_rounded,
                                'Save',
                                onPressed: () => _toggleSocialPostSave(post,
                                    savedOverride: saved),
                                active: saved,
                              ),
                            ],
                          ),
                          const SizedBox(height: 9),
                          Text(
                            '$likeCount likes'
                            '${commentCount > 0 ? '  -  $commentCount comments' : ''}'
                            '${shareCount > 0 ? '  -  $shareCount shares' : ''}',
                            style: const TextStyle(
                              color: FriendifyBrand.pureWhite,
                              fontWeight: FontWeight.w900,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 6),
                          RichText(
                            text: TextSpan(
                              style: const TextStyle(
                                color: FriendifyBrand.pureWhite,
                                fontSize: 13.5,
                                height: 1.35,
                              ),
                              children: [
                                TextSpan(
                                  text: '${post.ownerName} ',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w900),
                                ),
                                TextSpan(text: post.caption),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _feedPostCard(AppUserModel user, {required AppUserModel me}) {
    final name = user.safeDisplayName;
    final topic = user.topics.isNotEmpty ? user.topics.first : 'listening';
    final caption = user.bio.trim().isNotEmpty
        ? user.bio.trim()
        : 'Available for real conversations around $topic.';
    final liked = _likedFeedPosts.contains(user.uid);
    final saved = _savedFeedPosts.contains(user.uid);
    final commentCount = _feedComments[user.uid]?.length ?? 0;
    final shareCount = _feedShareCounts[user.uid] ?? 0;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF10162D).withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: FriendifyBrand.pureWhite.withValues(alpha: 0.06),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(13, 12, 10, 10),
            child: Row(
              children: [
                _feedAvatar(user, size: 42),
                const SizedBox(width: 10),
                Expanded(
                  child: InkWell(
                    onTap: () {
                      if (user.uid == me.uid) {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const ProfileScreen(),
                          ),
                        );
                        return;
                      }
                      unawaited(_openListenerProfile(user));
                    },
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: FriendifyBrand.pureWhite,
                            fontSize: 15.5,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          user.city.trim().isEmpty
                              ? 'Friendify listener'
                              : user.city.trim(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: FriendifyBrand.pureWhite
                                .withValues(alpha: 0.56),
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Post menu',
                  onPressed: () => _showFeedPostOptions(user, me, caption),
                  icon: const Icon(Icons.more_vert_rounded),
                  color: FriendifyBrand.pureWhite.withValues(alpha: 0.82),
                ),
              ],
            ),
          ),
          GestureDetector(
            onDoubleTap: () => _likeFeedPost(user),
            child: _feedPostMedia(user),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 13),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _feedActionIcon(
                      liked
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      'Like',
                      onPressed: () => _toggleFeedLike(user),
                      active: liked,
                    ),
                    _feedActionIcon(
                      Icons.chat_bubble_outline_rounded,
                      'Comment',
                      onPressed: () => _showFeedCommentsSheet(user),
                    ),
                    _feedActionIcon(
                      Icons.send_rounded,
                      'Share',
                      onPressed: () => unawaited(_shareFeedPost(user, caption)),
                    ),
                    const Spacer(),
                    _feedActionIcon(
                      saved
                          ? Icons.bookmark_rounded
                          : Icons.bookmark_border_rounded,
                      'Save',
                      onPressed: () => _toggleFeedSave(user),
                      active: saved,
                    ),
                  ],
                ),
                const SizedBox(height: 9),
                Text(
                  '${user.followersCount + (liked ? 1 : 0)} likes'
                  '${commentCount > 0 ? '  -  $commentCount comments' : ''}'
                  '${shareCount > 0 ? '  -  $shareCount shares' : ''}',
                  style: const TextStyle(
                    color: FriendifyBrand.pureWhite,
                    fontWeight: FontWeight.w900,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 6),
                RichText(
                  text: TextSpan(
                    style: const TextStyle(
                      color: FriendifyBrand.pureWhite,
                      fontSize: 13.5,
                      height: 1.35,
                    ),
                    children: [
                      TextSpan(
                        text: '$name ',
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                      TextSpan(text: caption),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _feedActionIcon(
    IconData icon,
    String tooltip, {
    required VoidCallback onPressed,
    bool active = false,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.only(right: 8),
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      icon: Icon(icon),
      color: active ? FriendifyBrand.softViolet : FriendifyBrand.pureWhite,
    );
  }

  Widget _feedPostMedia(AppUserModel user) {
    final photo = user.photoURL.trim();
    final name = user.safeDisplayName;
    return AspectRatio(
      aspectRatio: 1.18,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          gradient: photo.isEmpty ? FriendifyBrand.primaryGradient : null,
          color: const Color(0xFF151B35),
        ),
        child: photo.isEmpty
            ? _feedEmptyPostMedia(name)
            : Image.network(
                photo,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _feedEmptyPostMedia(name),
              ),
      ),
    );
  }

  Widget _socialPostMedia(SocialPostModel post) {
    return AspectRatio(
      aspectRatio: 1.18,
      child: Container(
        width: double.infinity,
        color: const Color(0xFF151B35),
        child: Image.network(
          post.imageURL,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _feedEmptyPostMedia(post.ownerName),
        ),
      ),
    );
  }

  Widget _feedEmptyPostMedia(String name) {
    final first = name.trim().isNotEmpty ? name.trim()[0].toUpperCase() : 'F';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(26),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 112,
              height: 112,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: FriendifyBrand.deepIndigo.withValues(alpha: 0.20),
                border: Border.all(
                  color: FriendifyBrand.pureWhite.withValues(alpha: 0.28),
                  width: 2,
                ),
              ),
              alignment: Alignment.center,
              child: Text(
                first,
                style: const TextStyle(
                  color: FriendifyBrand.pureWhite,
                  fontSize: 48,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: FriendifyBrand.pureWhite,
                fontSize: 24,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Friendify listener',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: FriendifyBrand.pureWhite.withValues(alpha: 0.72),
                fontSize: 14,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _feedStoryAvatar(
    AppUserModel user, {
    required SocialPostModel story,
    required double size,
  }) {
    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: Image.network(
          story.imageURL,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _feedAvatar(user, size: size),
        ),
      ),
    );
  }

  Widget _feedAvatar(AppUserModel user, {required double size}) {
    return _feedAvatarFromValues(
      photoURL: user.photoURL.trim(),
      name: user.safeDisplayName,
      size: size,
    );
  }

  Widget _feedAvatarFromValues({
    required String photoURL,
    required String name,
    required double size,
  }) {
    final photo = photoURL.trim();
    final first = name.trim().isNotEmpty ? name.trim()[0].toUpperCase() : 'F';
    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: photo.isEmpty
            ? Container(
                decoration: const BoxDecoration(
                  gradient: FriendifyBrand.primaryGradient,
                ),
                alignment: Alignment.center,
                child: Text(
                  first,
                  style: TextStyle(
                    color: FriendifyBrand.pureWhite,
                    fontSize: size * 0.38,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              )
            : Image.network(
                photo,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  decoration: const BoxDecoration(
                    gradient: FriendifyBrand.primaryGradient,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    first,
                    style: TextStyle(
                      color: FriendifyBrand.pureWhite,
                      fontSize: size * 0.38,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  Widget _friendifyReferenceHeader(AppUserModel me) {
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.asset(
            'assets/branding/friendify_icon_1024.png',
            width: 40,
            height: 40,
            fit: BoxFit.cover,
          ),
        ),
        const SizedBox(width: 8),
        const Expanded(
          child: Text(
            'friendify',
            style: TextStyle(
              color: FriendifyBrand.pureWhite,
              fontSize: 26,
              fontWeight: FontWeight.w900,
              letterSpacing: 0,
            ),
          ),
        ),
        InkWell(
          customBorder: const CircleBorder(),
          onTap: () {
            _dismissAnyFocus();
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ProfileScreen()),
            );
          },
          child: _referenceUserAvatar(me),
        ),
      ],
    );
  }

  Widget _referenceUserAvatar(AppUserModel me) {
    final photo = me.photoURL.trim();
    final name = me.safeDisplayName;
    final first = name.trim().isNotEmpty ? name.trim()[0].toUpperCase() : 'F';

    return Container(
      width: 44,
      height: 44,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: FriendifyBrand.lavenderGlow.withValues(alpha: 0.42),
        ),
      ),
      child: ClipOval(
        child: photo.isEmpty
            ? Container(
                decoration: const BoxDecoration(
                  gradient: FriendifyBrand.primaryGradient,
                ),
                alignment: Alignment.center,
                child: Text(
                  first,
                  style: const TextStyle(
                    color: FriendifyBrand.pureWhite,
                    fontWeight: FontWeight.w900,
                    fontSize: 17,
                  ),
                ),
              )
            : Image.network(
                photo,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  decoration: const BoxDecoration(
                    gradient: FriendifyBrand.primaryGradient,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    first,
                    style: const TextStyle(
                      color: FriendifyBrand.pureWhite,
                      fontWeight: FontWeight.w900,
                      fontSize: 17,
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  Widget _referenceSearchField() {
    return TextField(
      controller: _homeSearchController,
      style: const TextStyle(
        color: FriendifyBrand.pureWhite,
        fontWeight: FontWeight.w700,
      ),
      decoration: InputDecoration(
        hintText: 'Search listeners...',
        hintStyle: TextStyle(
          color: FriendifyBrand.pureWhite.withValues(alpha: 0.42),
          fontWeight: FontWeight.w700,
        ),
        prefixIcon: Icon(
          Icons.search_rounded,
          color: FriendifyBrand.pureWhite.withValues(alpha: 0.58),
        ),
        suffixIcon: _homeSearchController.text.trim().isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear search',
                onPressed: _homeSearchController.clear,
                icon: const Icon(Icons.close_rounded),
                color: FriendifyBrand.pureWhite.withValues(alpha: 0.58),
              ),
        filled: true,
        fillColor: const Color(0xFF171A34).withValues(alpha: 0.90),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(13),
          borderSide: BorderSide(
            color: FriendifyBrand.lavenderGlow.withValues(alpha: 0.34),
            width: 1.2,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(13),
          borderSide: const BorderSide(
            color: FriendifyBrand.lavenderGlow,
            width: 1.4,
          ),
        ),
      ),
    );
  }

  Widget _referenceFilterTabs() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _referenceFilterTab('All', _HomeListenerFilter.all),
          const SizedBox(width: 14),
          _referenceFilterTab('Online', _HomeListenerFilter.online),
          const SizedBox(width: 14),
          _referenceFilterTab('New', _HomeListenerFilter.newer),
          const SizedBox(width: 14),
          _referenceFilterTab('Favorites', _HomeListenerFilter.favorites),
        ],
      ),
    );
  }

  Widget _referenceFilterTab(String label, _HomeListenerFilter filter) {
    final selected = _homeListenerFilter == filter;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () {
        if (_homeListenerFilter == filter) return;
        setState(() => _homeListenerFilter = filter);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: EdgeInsets.symmetric(
          horizontal: selected ? 14 : 0,
          vertical: selected ? 8 : 7,
        ),
        decoration: BoxDecoration(
          gradient: selected ? FriendifyBrand.primaryGradient : null,
          borderRadius: BorderRadius.circular(999),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: FriendifyBrand.softViolet.withValues(alpha: 0.26),
                    blurRadius: 14,
                    offset: const Offset(0, 6),
                  ),
                ]
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected
                ? FriendifyBrand.pureWhite
                : FriendifyBrand.pureWhite.withValues(alpha: 0.84),
            fontSize: 13.5,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }

  Widget _referenceEmptyState({
    String title = 'No listeners found',
    String subtitle = 'No listeners found for this view.',
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF11162E).withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(
          color: FriendifyBrand.pureWhite.withValues(alpha: 0.06),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: FriendifyBrand.pureWhite,
              fontSize: 16,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: TextStyle(
              color: FriendifyBrand.pureWhite.withValues(alpha: 0.72),
              height: 1.3,
              fontWeight: FontWeight.w800,
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: onAction,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: Text(actionLabel),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _referenceListenerCard(AppUserModel user) {
    final name = user.safeDisplayName;
    final photo = user.photoURL.trim();
    final rate = user.listenerRate > 0 ? user.listenerRate : 5;
    final rating =
        user.ratingCount > 0 ? user.ratingAvg.toStringAsFixed(1) : 'New';
    final busy = user.isOnCall || !user.isAvailable;
    final statusText = busy ? 'Busy' : 'Online';
    final statusColor =
        busy ? FriendifyBrand.warning : FriendifyBrand.mintGreen;

    return InkWell(
      borderRadius: BorderRadius.circular(15),
      onTap: () => _openListenerProfile(user),
      child: Container(
        height: 74,
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: BoxDecoration(
          color: const Color(0xFF151B35).withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(
            color: FriendifyBrand.lavenderGlow.withValues(alpha: 0.14),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.14),
              blurRadius: 10,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Row(
          children: [
            _referenceListenerAvatar(photo, name),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: FriendifyBrand.pureWhite,
                      fontSize: 17,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    'Rs $rate/min',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: FriendifyBrand.pureWhite.withValues(alpha: 0.78),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.star_rounded,
                      color: FriendifyBrand.warning,
                      size: 18,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      rating,
                      style: const TextStyle(
                        color: FriendifyBrand.pureWhite,
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: busy ? 0.16 : 0.10),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: statusColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 3),
                      Text(
                        statusText,
                        style: TextStyle(
                          color: statusColor,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _referenceListenerAvatar(String photo, String name) {
    final first = name.trim().isNotEmpty ? name.trim()[0].toUpperCase() : 'F';
    return Container(
      width: 54,
      height: 54,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: FriendifyBrand.lavenderGlow.withValues(alpha: 0.22),
          width: 2,
        ),
      ),
      child: ClipOval(
        child: photo.isEmpty
            ? Container(
                decoration: const BoxDecoration(
                  gradient: FriendifyBrand.primaryGradient,
                ),
                alignment: Alignment.center,
                child: Text(
                  first,
                  style: const TextStyle(
                    color: FriendifyBrand.pureWhite,
                    fontWeight: FontWeight.w900,
                    fontSize: 24,
                  ),
                ),
              )
            : Image.network(
                photo,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  decoration: const BoxDecoration(
                    gradient: FriendifyBrand.primaryGradient,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    first,
                    style: const TextStyle(
                      color: FriendifyBrand.pureWhite,
                      fontWeight: FontWeight.w900,
                      fontSize: 24,
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  // ignore: unused_element
  Widget _discoveryPopularListeners(List<AppUserModel> listeners) {
    return Container(
      decoration: FriendifyBrand.panelDecoration(),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Popular Listeners',
                  style: TextStyle(
                    color: FriendifyBrand.pureWhite,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              TextButton(
                onPressed: () {
                  _dismissAnyFocus();
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const MatchAndCallScreen(),
                    ),
                  );
                },
                child: const Text('See All'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 154,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: listeners.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (_, index) {
                final user = listeners[index];
                return _popularListenerCard(user);
              },
            ),
          ),
        ],
      ),
    );
  }

  // ignore: unused_element
  Widget _popularListenerCard(AppUserModel user) {
    final name = user.safeDisplayName;
    final photo = user.photoURL.trim();
    final rate = user.listenerRate > 0 ? user.listenerRate : 5;
    final rating =
        user.ratingCount > 0 ? user.ratingAvg.toStringAsFixed(1) : 'New';

    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => _openListenerProfile(user),
      child: Container(
        width: 110,
        padding: const EdgeInsets.all(9),
        decoration: BoxDecoration(
          color: FriendifyBrand.darkSurfaceElevated,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: FriendifyBrand.lavenderGlow.withValues(alpha: 0.16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(
                width: double.infinity,
                height: 76,
                child: photo.isEmpty
                    ? Container(
                        decoration: const BoxDecoration(
                          gradient: FriendifyBrand.primaryGradient,
                        ),
                        child: Center(
                          child: Text(
                            name.isEmpty ? 'F' : name[0].toUpperCase(),
                            style: const TextStyle(
                              color: FriendifyBrand.pureWhite,
                              fontWeight: FontWeight.w900,
                              fontSize: 22,
                            ),
                          ),
                        ),
                      )
                    : Image.network(
                        photo,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          decoration: const BoxDecoration(
                            gradient: FriendifyBrand.primaryGradient,
                          ),
                          child: Center(
                            child: Text(
                              name.isEmpty ? 'F' : name[0].toUpperCase(),
                              style: const TextStyle(
                                color: FriendifyBrand.pureWhite,
                                fontWeight: FontWeight.w900,
                                fontSize: 22,
                              ),
                            ),
                          ),
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 7),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: FriendifyBrand.pureWhite,
                fontWeight: FontWeight.w900,
                fontSize: 12.5,
              ),
            ),
            const SizedBox(height: 3),
            Row(
              children: [
                const Icon(
                  Icons.star_rounded,
                  size: 13,
                  color: FriendifyBrand.warning,
                ),
                const SizedBox(width: 2),
                Text(
                  rating,
                  style: const TextStyle(
                    color: FriendifyBrand.slate,
                    fontWeight: FontWeight.w700,
                    fontSize: 10.5,
                  ),
                ),
                const Spacer(),
                Text(
                  'Rs $rate/min',
                  style: const TextStyle(
                    color: FriendifyBrand.slate,
                    fontWeight: FontWeight.w700,
                    fontSize: 10.5,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ignore: unused_element
  Widget _discoveryOnlineListeners(List<AppUserModel> listeners) {
    return Container(
      decoration: FriendifyBrand.panelDecoration(),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Online Now',
                  style: TextStyle(
                    color: FriendifyBrand.pureWhite,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              TextButton(
                onPressed: () {
                  _dismissAnyFocus();
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const MatchAndCallScreen(),
                    ),
                  );
                },
                child: const Text('See All'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 88,
            child: listeners.isEmpty
                ? const Center(
                    child: Text(
                      'Check advanced search for more listeners.',
                      style: TextStyle(
                        color: FriendifyBrand.slate,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  )
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: listeners.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 12),
                    itemBuilder: (_, index) {
                      final user = listeners[index];
                      return _onlineListenerAvatar(user);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // ignore: unused_element
  Widget _onlineListenerAvatar(AppUserModel user) {
    final name = user.safeDisplayName;
    final photo = user.photoURL.trim();

    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => _openListenerProfile(user),
      child: SizedBox(
        width: 64,
        child: Column(
          children: [
            Stack(
              children: [
                _avatar(photo, name),
                Positioned(
                  right: 2,
                  bottom: 2,
                  child: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: FriendifyBrand.mintGreen,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: FriendifyBrand.deepIndigo,
                        width: 2,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: FriendifyBrand.pureWhite,
                fontWeight: FontWeight.w700,
                fontSize: 11.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Kept available for a future dedicated tools surface.
  // ignore: unused_element
  Widget _quickActions({required bool isAdmin}) {
    return _sectionCard(
      key: const ValueKey<String>('home_quick_actions_card'),
      title: 'Quick Actions',
      subtitle: 'Discovery and call tools.',
      children: [
        _actionButton(
          icon: Icons.call_rounded,
          title: 'Find & Call People',
          subtitle:
              'Discover profiles by topic, language, gender, and location.',
          onTap: () {
            _dismissAnyFocus();
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
            _dismissAnyFocus();
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
        if (isAdmin) ..._adminQuickActions(),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_signingOut) {
      return _loadingScaffold(message: 'Signing out...');
    }

    return StreamBuilder<AppUserModel?>(
      stream: _meStreamForCurrentAuth(),
      builder: (_, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return _loadingScaffold(message: 'Loading your home...');
        }

        if (snap.hasError) {
          return const Scaffold(
            body: Center(
              child: Text(
                UiCopy.profileLoadFailed,
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        if (!snap.hasData || snap.data == null) {
          if (_profileEnsureFailed) {
            return const Scaffold(
              body: Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'We could not create your profile. Please check your connection and try again.',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            );
          }
          return _loadingScaffold(
            message: 'Getting your account ready...',
          );
        }

        final me = snap.data!;

        return FutureBuilder<bool>(
          future: _isAdminFuture,
          initialData: false,
          builder: (context, adminSnapshot) {
            if (widget.mode == HomeScreenMode.chats) {
              return Scaffold(
                backgroundColor: FriendifyBrand.deepIndigo,
                appBar: AppBar(
                  elevation: 0,
                  scrolledUnderElevation: 0,
                  backgroundColor: FriendifyBrand.darkSurface,
                  foregroundColor: FriendifyBrand.pureWhite,
                  surfaceTintColor: Colors.transparent,
                  title: const Text(
                    'Chats',
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                  actions: [
                    PopupMenuButton<_HomeOverflowAction>(
                      tooltip: 'Help and policies',
                      icon: const Icon(Icons.more_vert_rounded),
                      color: FriendifyBrand.darkSurfaceElevated,
                      surfaceTintColor: Colors.transparent,
                      onSelected: (action) {
                        unawaited(_handleOverflowAction(action));
                      },
                      itemBuilder: (_) => _homeOverflowMenuItems(),
                    ),
                  ],
                ),
                body: Stack(
                  children: [
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: FriendifyBrand.brandedBackground(),
                      ),
                    ),
                    ListView(
                      padding: FriendifyBrand.screenPadding(
                        context,
                        top: 16,
                        bottom: 116,
                      ),
                      children: [
                        _recentChatsSection(me: me),
                      ],
                    ),
                  ],
                ),
              );
            }

            return Scaffold(
              backgroundColor: FriendifyBrand.deepIndigo,
              body: Stack(
                children: [
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: FriendifyBrand.brandedBackground(),
                    ),
                  ),
                  if (widget.mode == HomeScreenMode.discovery)
                    SafeArea(
                      bottom: false,
                      child: _homeDiscoverySection(me),
                    )
                  else
                    ListView(
                      padding: FriendifyBrand.screenPadding(
                        context,
                        top: 18,
                        bottom: 220,
                      ),
                      children: [
                        SafeArea(
                          bottom: false,
                          child: _homeFeedSection(me),
                        ),
                      ],
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _FeedCommentsSheet extends StatefulWidget {
  const _FeedCommentsSheet({
    required this.displayName,
    required this.photoURL,
    required this.initialComments,
    required this.onCommentAdded,
    this.commentsStream,
  });

  final String displayName;
  final String photoURL;
  final List<SocialCommentModel> initialComments;
  final ValueChanged<String> onCommentAdded;
  final Stream<List<SocialCommentModel>>? commentsStream;

  @override
  State<_FeedCommentsSheet> createState() => _FeedCommentsSheetState();
}

class _FeedCommentsSheetState extends State<_FeedCommentsSheet> {
  late final TextEditingController _controller;
  late final List<SocialCommentModel> _comments;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    _comments = List<SocialCommentModel>.of(widget.initialComments);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _addComment() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    setState(() => _comments.add(SocialCommentModel.local(text)));
    widget.onCommentAdded(text);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final photo = widget.photoURL.trim();
    final name = widget.displayName.trim().isEmpty
        ? 'Friendify'
        : widget.displayName.trim();
    final first = name.trim().isNotEmpty ? name.trim()[0].toUpperCase() : 'F';

    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: EdgeInsets.fromLTRB(
        18,
        4,
        18,
        MediaQuery.viewInsetsOf(context).bottom + 18,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ClipOval(
                  child: SizedBox(
                    width: 36,
                    height: 36,
                    child: photo.isEmpty
                        ? Container(
                            decoration: const BoxDecoration(
                              gradient: FriendifyBrand.primaryGradient,
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              first,
                              style: const TextStyle(
                                color: FriendifyBrand.pureWhite,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          )
                        : Image.network(
                            photo,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              decoration: const BoxDecoration(
                                gradient: FriendifyBrand.primaryGradient,
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                first,
                                style: const TextStyle(
                                  color: FriendifyBrand.pureWhite,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '$name comments',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: FriendifyBrand.pureWhite,
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _commentsList(),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              minLines: 1,
              maxLines: 3,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _addComment(),
              style: const TextStyle(color: FriendifyBrand.pureWhite),
              decoration: InputDecoration(
                hintText: 'Add a comment...',
                hintStyle: TextStyle(
                  color: FriendifyBrand.pureWhite.withValues(alpha: 0.42),
                ),
                suffixIcon: IconButton(
                  tooltip: 'Post comment',
                  icon: const Icon(Icons.send_rounded),
                  color: FriendifyBrand.lavenderGlow,
                  onPressed: _addComment,
                ),
                filled: true,
                fillColor: FriendifyBrand.pureWhite.withValues(alpha: 0.07),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                  borderSide: BorderSide(
                    color: FriendifyBrand.pureWhite.withValues(alpha: 0.12),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _commentsList() {
    final stream = widget.commentsStream;
    if (stream == null) {
      return _commentsListBody(_comments);
    }

    return StreamBuilder<List<SocialCommentModel>>(
      stream: stream,
      initialData: _comments,
      builder: (context, snapshot) {
        final remoteComments = snapshot.data ?? const <SocialCommentModel>[];
        final comments = remoteComments.isEmpty ? _comments : remoteComments;
        return _commentsListBody(comments);
      },
    );
  }

  Widget _commentsListBody(List<SocialCommentModel> comments) {
    if (comments.isEmpty) {
      return Text(
        'No comments yet. Start the conversation.',
        style: TextStyle(
          color: FriendifyBrand.pureWhite.withValues(alpha: 0.62),
          fontWeight: FontWeight.w700,
        ),
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 220),
      child: ListView.separated(
        shrinkWrap: true,
        itemCount: comments.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (_, index) {
          final comment = comments[index];
          final name = comment.displayName.trim().isEmpty
              ? 'Friend'
              : comment.displayName.trim();
          final photo = comment.photoURL.trim();
          final first = name.isNotEmpty ? name[0].toUpperCase() : 'F';
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipOval(
                child: SizedBox(
                  width: 30,
                  height: 30,
                  child: photo.isEmpty
                      ? Container(
                          decoration: const BoxDecoration(
                            gradient: FriendifyBrand.primaryGradient,
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            first,
                            style: const TextStyle(
                              color: FriendifyBrand.pureWhite,
                              fontSize: 12,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        )
                      : Image.network(
                          photo,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            decoration: const BoxDecoration(
                              gradient: FriendifyBrand.primaryGradient,
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              first,
                              style: const TextStyle(
                                color: FriendifyBrand.pureWhite,
                                fontSize: 12,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: RichText(
                  text: TextSpan(
                    style: const TextStyle(
                      color: FriendifyBrand.pureWhite,
                      fontWeight: FontWeight.w700,
                      height: 1.25,
                    ),
                    children: [
                      TextSpan(
                        text: '$name ',
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                      TextSpan(text: comment.text),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
