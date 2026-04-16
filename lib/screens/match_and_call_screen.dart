import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../repositories/call_repository.dart';
import '../repositories/user_repository.dart';
import '../services/call_session_manager.dart';
import '../shared/models/app_user_model.dart';
import 'caller_waiting_screen.dart';
import 'chat_conversation_screen.dart';
import 'listener_profile_screen.dart';

enum _ListenerSortOption {
  bestMatch,
  highestRated,
  lowestPrice,
  highestFollowers,
  favoritesFirst,
}

class MatchAndCallScreen extends StatefulWidget {
  const MatchAndCallScreen({super.key});

  @override
  State<MatchAndCallScreen> createState() => _MatchAndCallScreenState();
}

class _MatchAndCallScreenState extends State<MatchAndCallScreen> {
  final UserRepository _userRepository = UserRepository.instance;
  final CallRepository _callRepository = CallRepository.instance;
  final CallSessionManager _callSession = CallSessionManager.instance;

  final TextEditingController _searchController = TextEditingController();

  String search = '';
  String followingWorkingFor = '';
  String favoriteWorkingFor = '';
  String callingFor = '';
  String openingChatFor = '';
  String openingProfileFor = '';
  bool _callStartInFlight = false;

  bool availableOnly = true;
  bool favoritesOnly = false;
  String selectedTopic = 'All';
  String selectedLanguage = 'All';
  String selectedGender = 'All';
  String selectedLocation = 'All';
  _ListenerSortOption sortOption = _ListenerSortOption.bestMatch;

  Timer? _searchDebounce;
  Timer? _callCooldownTimer;

  final ValueNotifier<int> _callCooldownRemaining = ValueNotifier<int>(0);
  final ValueNotifier<String> _callCooldownFor = ValueNotifier<String>('');

  bool get _busyWithAnyAction =>
      followingWorkingFor.isNotEmpty ||
      favoriteWorkingFor.isNotEmpty ||
      callingFor.isNotEmpty ||
      openingChatFor.isNotEmpty ||
      openingProfileFor.isNotEmpty ||
      _callStartInFlight;

  bool get _hasBlockingCallState =>
      _callSession.active ||
      _callSession.state == CallState.preparing ||
      _callSession.state == CallState.joining ||
      _callSession.state == CallState.reconnecting ||
      _callSession.state == CallState.ending;

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _callCooldownTimer?.cancel();
    _searchController.dispose();
    _callCooldownRemaining.dispose();
    _callCooldownFor.dispose();
    super.dispose();
  }

  void _showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  int _listenerEarnFromVisible(int visibleRate) {
    return _userRepository.listenerPayoutFromVisibleRate(visibleRate);
  }

  bool _isUserBusyFromUserDoc(AppUserModel user) {
    return user.hasActiveCall || !user.isAvailable;
  }

  bool _isCoolingDownFor(String listenerId) {
    return _callCooldownRemaining.value > 0 &&
        _callCooldownFor.value == listenerId.trim();
  }

  void _handleSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 220), () {
      final next = value.trim().toLowerCase();
      if (!mounted) return;
      if (search == next) return;
      setState(() {
        search = next;
      });
    });
  }

  void _startCallCooldown({
    required String listenerId,
    int seconds = 60,
  }) {
    final safeListenerId = listenerId.trim();
    if (safeListenerId.isEmpty) return;

    _callCooldownTimer?.cancel();

    _callCooldownFor.value = safeListenerId;
    _callCooldownRemaining.value = seconds;

    if (mounted && callingFor == safeListenerId) {
      setState(() {
        callingFor = '';
      });
    } else {
      callingFor = '';
    }

    _callCooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      final current = _callCooldownRemaining.value;
      if (current <= 1) {
        timer.cancel();
        _callCooldownRemaining.value = 0;
        _callCooldownFor.value = '';
        return;
      }

      _callCooldownRemaining.value = current - 1;
    });
  }

  String _humanizeFunctionError(Object e) {
    if (e is FirebaseFunctionsException) {
      final code = e.code.trim();
      final msg = (e.message ?? '').trim();

      debugPrint(
        'startCall_v2 FirebaseFunctionsException: '
        'code=$code message=$msg details=${e.details}',
      );

      if (msg.isNotEmpty) return msg;

      switch (code) {
        case 'resource-exhausted':
          return 'Too many call attempts. Please wait 60 seconds and try again.';
        case 'failed-precondition':
          return 'Listener is unavailable, busy, or has not allowed call yet.';
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

    debugPrint('startCall_v2 unknown error: $e');
    return 'Could not start call. Please try again.';
  }

  String _ratingLabel(num avg) {
    return avg.toStringAsFixed(1);
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

  String _sortLabel(_ListenerSortOption option) {
    switch (option) {
      case _ListenerSortOption.bestMatch:
        return 'Best match';
      case _ListenerSortOption.highestRated:
        return 'Highest rated';
      case _ListenerSortOption.lowestPrice:
        return 'Lowest price';
      case _ListenerSortOption.highestFollowers:
        return 'Most followers';
      case _ListenerSortOption.favoritesFirst:
        return 'Favorites first';
    }
  }

  int _searchScore(AppUserModel user) {
    if (search.isEmpty) return 0;

    final q = search.toLowerCase();

    final name = user.displayName.toLowerCase();
    final bio = user.bio.toLowerCase();
    final topics =
        _safeStringList(user.topics).map((e) => e.toLowerCase()).toList();
    final languages =
        _safeStringList(user.languages).map((e) => e.toLowerCase()).toList();
    final gender = user.gender.trim().toLowerCase();
    final city = user.city.trim().toLowerCase();
    final state = user.state.trim().toLowerCase();
    final country = user.country.trim().toLowerCase();

    int score = 0;

    if (name == q) score += 100;
    if (name.startsWith(q)) score += 60;
    if (name.contains(q)) score += 40;
    if (bio.contains(q)) score += 20;
    if (topics.any((t) => t == q)) score += 35;
    if (topics.any((t) => t.contains(q))) score += 20;
    if (languages.any((l) => l == q)) score += 25;
    if (languages.any((l) => l.contains(q))) score += 15;
    if (gender == q) score += 20;
    if (city == q) score += 18;
    if (state == q) score += 16;
    if (country == q) score += 14;

    return score;
  }

  List<String> _collectAllTopics(List<AppUserModel> users) {
    final set = <String>{};

    for (final user in users) {
      for (final topic in _safeStringList(user.topics)) {
        set.add(topic);
      }
    }

    final list = set.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return list;
  }

  List<String> _collectAllLanguages(List<AppUserModel> users) {
    final set = <String>{};

    for (final user in users) {
      for (final language in _safeStringList(user.languages)) {
        set.add(language);
      }
    }

    final list = set.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return list;
  }

  List<String> _collectAllGenders(List<AppUserModel> users) {
    final set = <String>{};

    for (final user in users) {
      final gender = user.gender.trim();
      if (gender.isNotEmpty) {
        set.add(gender);
      }
    }

    final list = set.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return list;
  }

  List<String> _collectAllLocations(List<AppUserModel> users) {
    final set = <String>{};

    for (final user in users) {
      final city = user.city.trim();
      final state = user.state.trim();
      if (city.isNotEmpty) set.add('Nearby');
      if (state.isNotEmpty) set.add(state);
    }

    final list = set.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return list;
  }

  void _resetFilters() {
    _searchDebounce?.cancel();
    _searchController.clear();
    setState(() {
      search = '';
      availableOnly = true;
      favoritesOnly = false;
      selectedTopic = 'All';
      selectedLanguage = 'All';
      selectedGender = 'All';
      selectedLocation = 'All';
      sortOption = _ListenerSortOption.bestMatch;
    });
  }

  Future<void> _toggleFollow({
    required String listenerId,
    required bool isFollowing,
  }) async {
    if (_busyWithAnyAction || _hasBlockingCallState) return;

    setState(() => followingWorkingFor = listenerId);

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
    setState(() => followingWorkingFor = '');
  }

  Future<void> _toggleFavorite({
    required String listenerId,
    required bool isFavorite,
  }) async {
    if (_busyWithAnyAction || _hasBlockingCallState) return;

    setState(() => favoriteWorkingFor = listenerId);

    try {
      await _userRepository.toggleFavoriteListener(
        listenerId: listenerId,
        isFavoriteNow: isFavorite,
      );
    } catch (_) {
      _showSnack('Favorite action failed. Please try again.');
    }

    if (!mounted) return;
    setState(() => favoriteWorkingFor = '');
  }

  Future<void> _openChat({
    required AppUserModel me,
    required AppUserModel listener,
  }) async {
    final safeListenerId = listener.uid.trim();
    if (safeListenerId.isEmpty) return;

    if (me.uid == safeListenerId) {
      _showSnack('You cannot chat with yourself.');
      return;
    }

    if (_busyWithAnyAction || _hasBlockingCallState) return;

    setState(() => openingChatFor = safeListenerId);

    try {
      final ensuredId =
          await _callRepository.ensureChatSessionWithListener(safeListenerId);

      final expectedId = _callRepository.chatSessionIdForPair(
        speakerId: me.uid,
        listenerId: safeListenerId,
      );

      if (ensuredId.isEmpty || ensuredId != expectedId) {
        _showSnack('Could not prepare the correct chat session.');
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
            initialOtherUser: listener,
          ),
        ),
      );
    } catch (_) {
      _showSnack('Could not open chat right now.');
    } finally {
      if (mounted) {
        setState(() => openingChatFor = '');
      } else {
        openingChatFor = '';
      }
    }
  }

  Future<void> _startCall({
    required AppUserModel me,
    required String listenerId,
    required int visibleRate,
  }) async {
    if (_busyWithAnyAction) return;

    if (_hasBlockingCallState) {
      _showSnack('Finish your current call flow first.');
      return;
    }

    final safeListenerId = listenerId.trim();
    if (safeListenerId.isEmpty) return;

    if (_isCoolingDownFor(safeListenerId)) {
      _showSnack(
        'Please wait ${_callCooldownRemaining.value}s before trying this listener again.',
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

      final canActuallyCall = await _callRepository.canCurrentUserCallListener(
        listenerId: safeListenerId,
      );

      if (!canActuallyCall) {
        _showSnack(
          'Open chat first. Listener must allow call before you can call now.',
        );
        return;
      }

      if (mounted) {
        setState(() {
          callingFor = safeListenerId;
          _callStartInFlight = true;
        });
      } else {
        callingFor = safeListenerId;
        _callStartInFlight = true;
      }

      final callRef = await _callRepository.createCallToListener(
        listenerId: safeListenerId,
      );

      if (!mounted) return;
      setState(() {
        callingFor = '';
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
          callingFor = '';
          _callStartInFlight = false;
        });
      } else {
        callingFor = '';
        _callStartInFlight = false;
      }

      if (e.code.trim() == 'resource-exhausted') {
        _startCallCooldown(listenerId: safeListenerId, seconds: 60);
      }

      _showSnack(_humanizeFunctionError(e));
    } catch (e) {
      if (mounted) {
        setState(() {
          callingFor = '';
          _callStartInFlight = false;
        });
      } else {
        callingFor = '';
        _callStartInFlight = false;
      }
      _showSnack(_humanizeFunctionError(e));
    }
  }

  Future<void> _openListenerProfile(AppUserModel user) async {
    if (_busyWithAnyAction) return;

    setState(() => openingProfileFor = user.uid);

    try {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ListenerProfileScreen(
            listenerId: user.uid,
            initialUser: user,
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => openingProfileFor = '');
      } else {
        openingProfileFor = '';
      }
    }
  }

  bool _matchesGender(AppUserModel user, String effectiveGender) {
    if (effectiveGender == 'All') return true;
    return user.gender.trim().toLowerCase() == effectiveGender.toLowerCase();
  }

  bool _matchesLocation({
    required AppUserModel user,
    required AppUserModel me,
    required String effectiveLocation,
  }) {
    if (effectiveLocation == 'All') return true;

    if (effectiveLocation == 'Nearby') {
      final myCity = me.city.trim().toLowerCase();
      final myState = me.state.trim().toLowerCase();
      final userCity = user.city.trim().toLowerCase();
      final userState = user.state.trim().toLowerCase();

      if (myCity.isNotEmpty && userCity.isNotEmpty && myCity == userCity) {
        return true;
      }
      if (myState.isNotEmpty &&
          userState.isNotEmpty &&
          myState == userState) {
        return true;
      }
      return false;
    }

    return user.state.trim().toLowerCase() == effectiveLocation.toLowerCase();
  }

  List<AppUserModel> _applyFilters({
    required List<AppUserModel> listeners,
    required String myUid,
    required AppUserModel me,
    required String effectiveTopic,
    required String effectiveLanguage,
    required String effectiveGender,
    required String effectiveLocation,
  }) {
    return listeners.where((user) {
      if (user.uid == myUid) return false;

      if (availableOnly && !user.isAvailable) return false;

      final isFavorite = _userRepository.isFavoriteListener(
        me: me,
        listenerId: user.uid,
      );

      if (favoritesOnly && !isFavorite) return false;

      final name = user.displayName.toLowerCase();
      final bio = user.bio.toLowerCase();
      final topics = _safeStringList(user.topics);
      final languages = _safeStringList(user.languages);

      if (effectiveTopic != 'All' && !topics.contains(effectiveTopic)) {
        return false;
      }

      if (effectiveLanguage != 'All' && !languages.contains(effectiveLanguage)) {
        return false;
      }

      if (!_matchesGender(user, effectiveGender)) {
        return false;
      }

      if (!_matchesLocation(
        user: user,
        me: me,
        effectiveLocation: effectiveLocation,
      )) {
        return false;
      }

      if (search.isEmpty) return true;

      final fullSearchText =
          '$name $bio ${topics.join(' ')} ${languages.join(' ')} ${user.gender} ${user.city} ${user.state} ${user.country}'
              .toLowerCase();

      return fullSearchText.contains(search);
    }).toList(growable: false);
  }

  void _sortListeners({
    required List<AppUserModel> listeners,
    required AppUserModel me,
  }) {
    listeners.sort((a, b) {
      final ar = a.ratingAvg;
      final br = b.ratingAvg;

      final ac = a.ratingCount;
      final bc = b.ratingCount;

      final ap = a.listenerRate;
      final bp = b.listenerRate;

      final af = a.followersCount;
      final bf = b.followersCount;

      final aIsFavorite = _userRepository.isFavoriteListener(
        me: me,
        listenerId: a.uid,
      );
      final bIsFavorite = _userRepository.isFavoriteListener(
        me: me,
        listenerId: b.uid,
      );

      final aBusy = _isUserBusyFromUserDoc(a);
      final bBusy = _isUserBusyFromUserDoc(b);

      switch (sortOption) {
        case _ListenerSortOption.highestRated:
          if (bBusy != aBusy) return aBusy ? 1 : -1;
          final ratingCompare = br.compareTo(ar);
          if (ratingCompare != 0) return ratingCompare;
          final countCompare = bc.compareTo(ac);
          if (countCompare != 0) return countCompare;
          return ap.compareTo(bp);

        case _ListenerSortOption.lowestPrice:
          if (bBusy != aBusy) return aBusy ? 1 : -1;
          final priceCompare = ap.compareTo(bp);
          if (priceCompare != 0) return priceCompare;
          final ratingCompare = br.compareTo(ar);
          if (ratingCompare != 0) return ratingCompare;
          return bf.compareTo(af);

        case _ListenerSortOption.highestFollowers:
          if (bBusy != aBusy) return aBusy ? 1 : -1;
          final followerCompare = bf.compareTo(af);
          if (followerCompare != 0) return followerCompare;
          final ratingCompare = br.compareTo(ar);
          if (ratingCompare != 0) return ratingCompare;
          return ap.compareTo(bp);

        case _ListenerSortOption.favoritesFirst:
          if (bIsFavorite != aIsFavorite) {
            return aIsFavorite ? -1 : 1;
          }
          if (bBusy != aBusy) return aBusy ? 1 : -1;
          final ratingCompare = br.compareTo(ar);
          if (ratingCompare != 0) return ratingCompare;
          final followerCompare = bf.compareTo(af);
          if (followerCompare != 0) return followerCompare;
          return ap.compareTo(bp);

        case _ListenerSortOption.bestMatch:
          final aScore = _searchScore(a);
          final bScore = _searchScore(b);

          if (bIsFavorite != aIsFavorite) {
            return aIsFavorite ? -1 : 1;
          }

          if (bBusy != aBusy) {
            return aBusy ? 1 : -1;
          }

          final scoreCompare = bScore.compareTo(aScore);
          if (scoreCompare != 0) return scoreCompare;

          final ratingCompare = br.compareTo(ar);
          if (ratingCompare != 0) return ratingCompare;

          final followerCompare = bf.compareTo(af);
          if (followerCompare != 0) return followerCompare;

          return ap.compareTo(bp);
      }
    });
  }

  List<AppUserModel> _topListeners(List<AppUserModel> users) {
    final out = users
        .where(
          (u) =>
              u.isAvailable &&
              !u.hasActiveCall &&
              u.ratingAvg >= 4.0 &&
              u.ratingCount >= 5,
        )
        .toList(growable: false);

    final sorted = [...out]
      ..sort((a, b) {
        final ratingCompare = b.ratingAvg.compareTo(a.ratingAvg);
        if (ratingCompare != 0) return ratingCompare;

        final ratingCountCompare = b.ratingCount.compareTo(a.ratingCount);
        if (ratingCountCompare != 0) return ratingCountCompare;

        final followerCompare = b.followersCount.compareTo(a.followersCount);
        if (followerCompare != 0) return followerCompare;

        return a.listenerRate.compareTo(b.listenerRate);
      });

    return sorted.take(4).toList(growable: false);
  }

  List<AppUserModel> _regularListenersWithoutTop({
    required List<AppUserModel> filtered,
    required List<AppUserModel> topListeners,
  }) {
    if (topListeners.isEmpty) return filtered;

    final topIds = topListeners.map((e) => e.uid).toSet();
    return filtered.where((u) => !topIds.contains(u.uid)).toList(growable: false);
  }

  Widget _sectionTitle(
    String text, {
    String? subtitle,
    Widget? trailing,
  }) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                text,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF111827),
                ),
              ),
              if (subtitle != null && subtitle.trim().isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) trailing,
      ],
    );
  }

  Widget _metricChip({
    required IconData icon,
    required String text,
    Color? color,
  }) {
    final safeColor = color ?? const Color(0xFF5B5BD6);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      decoration: BoxDecoration(
        color: safeColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: safeColor.withValues(alpha: 0.18),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: safeColor),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              color: safeColor,
              fontWeight: FontWeight.w800,
              fontSize: 12.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _tinyTag(String text, {Color? bg, Color? fg}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: bg ?? const Color(0xFFF1F3F9),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w800,
          color: fg ?? const Color(0xFF374151),
        ),
      ),
    );
  }

  Widget _smallChips(List<String> items) {
    if (items.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: items.take(3).map((e) => _tinyTag(e)).toList(growable: false),
    );
  }

  Widget _topDiscoveryCard({
    required int total,
    required int online,
    required int favorites,
    required int usableCredit,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Find your best listener',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w900,
                color: Color(0xFF111827),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Search by topic, language, gender, location, rating, or price and connect faster.',
              style: TextStyle(
                color: Color(0xFF6B7280),
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _metricChip(
                  icon: Icons.people_alt_rounded,
                  text: '$total listeners',
                ),
                _metricChip(
                  icon: Icons.wifi_tethering_rounded,
                  text: '$online online',
                  color: const Color(0xFF16A34A),
                ),
                _metricChip(
                  icon: Icons.star_rounded,
                  text: '$favorites favorites',
                  color: const Color(0xFFF59E0B),
                ),
                _metricChip(
                  icon: Icons.account_balance_wallet_rounded,
                  text: _hasBlockingCallState
                      ? 'Call in progress'
                      : '₹$usableCredit credit',
                  color: _hasBlockingCallState
                      ? const Color(0xFF4F46E5)
                      : const Color(0xFF7C3AED),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _toggleFilterChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Material(
      color: selected ? const Color(0xFFEEF1FF) : const Color(0xFFF5F6FA),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected
                  ? const Color(0xFF5B5BD6).withValues(alpha: 0.30)
                  : Colors.black.withValues(alpha: 0.06),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: selected
                  ? const Color(0xFF4A4FB3)
                  : const Color(0xFF4B5563),
            ),
          ),
        ),
      ),
    );
  }

  Widget _filterCard({
    required List<String> topicOptions,
    required List<String> languageOptions,
    required List<String> genderOptions,
    required List<String> locationOptions,
    required String safeSelectedTopic,
    required String safeSelectedLanguage,
    required String safeSelectedGender,
    required String safeSelectedLocation,
    required int myAvailable,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _sectionTitle(
              'Search & filters',
              subtitle: 'Compact controls for faster browsing.',
              trailing: TextButton.icon(
                onPressed: _resetFilters,
                icon: const Icon(Icons.filter_alt_off_rounded),
                label: const Text('Reset'),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                hintText: 'Search name, bio, topic, language...',
                prefixIcon: Icon(Icons.search_rounded),
              ),
              onChanged: _handleSearchChanged,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                SizedBox(
                  width: 220,
                  child: DropdownButtonFormField<_ListenerSortOption>(
                    initialValue: sortOption,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Sort by',
                    ),
                    items: _ListenerSortOption.values
                        .map(
                          (e) => DropdownMenuItem<_ListenerSortOption>(
                            value: e,
                            child: Text(
                              _sortLabel(e),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() => sortOption = v);
                    },
                  ),
                ),
                _toggleFilterChip(
                  label: 'Available now',
                  selected: availableOnly,
                  onTap: () => setState(() => availableOnly = !availableOnly),
                ),
                _toggleFilterChip(
                  label: 'Favorites only',
                  selected: favoritesOnly,
                  onTap: () => setState(() => favoritesOnly = !favoritesOnly),
                ),
                _metricChip(
                  icon: Icons.account_balance_wallet_outlined,
                  text: _hasBlockingCallState
                      ? 'Call in progress'
                      : '₹$myAvailable usable',
                  color: _hasBlockingCallState
                      ? const Color(0xFF4F46E5)
                      : const Color(0xFF374151),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: safeSelectedTopic,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Topic',
                    ),
                    items: topicOptions
                        .map(
                          (e) => DropdownMenuItem<String>(
                            value: e,
                            child: Text(
                              e,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() => selectedTopic = v);
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: safeSelectedLanguage,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Language',
                    ),
                    items: languageOptions
                        .map(
                          (e) => DropdownMenuItem<String>(
                            value: e,
                            child: Text(
                              e,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() => selectedLanguage = v);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: safeSelectedGender,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Gender',
                    ),
                    items: genderOptions
                        .map(
                          (e) => DropdownMenuItem<String>(
                            value: e,
                            child: Text(
                              e,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() => selectedGender = v);
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: safeSelectedLocation,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Location',
                    ),
                    items: locationOptions
                        .map(
                          (e) => DropdownMenuItem<String>(
                            value: e,
                            child: Text(
                              e,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() => selectedLocation = v);
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _topListenersSection({
    required List<AppUserModel> topListeners,
    required AppUserModel me,
    required int myAvailable,
  }) {
    if (topListeners.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(
          'Top listeners',
          subtitle: 'Highly rated and ready right now.',
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 222,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: topListeners.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (_, index) {
              final user = topListeners[index];
              final name = user.displayName.trim().isEmpty
                  ? 'Listener'
                  : user.displayName.trim();
              final isFavorite = _userRepository.isFavoriteListener(
                me: me,
                listenerId: user.uid,
              );
              final canCallButton =
                  !_busyWithAnyAction &&
                  !_hasBlockingCallState &&
                  !_isCoolingDownFor(user.uid) &&
                  !_isUserBusyFromUserDoc(user);

              return SizedBox(
                width: 220,
                child: Material(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(24),
                    onTap: _busyWithAnyAction
                        ? null
                        : () => _openListenerProfile(user),
                    child: Ink(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: Colors.black.withValues(alpha: 0.05),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              CircleAvatar(
                                radius: 22,
                                backgroundColor: const Color(0xFFE6E8FF),
                                child: Text(
                                  name.isNotEmpty ? name[0].toUpperCase() : 'L',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w900,
                                    color: Color(0xFF4A4FB3),
                                  ),
                                ),
                              ),
                              const Spacer(),
                              if (isFavorite)
                                const Icon(
                                  Icons.star_rounded,
                                  color: Color(0xFFF59E0B),
                                  size: 20,
                                ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF111827),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '⭐ ${_ratingLabel(user.ratingAvg)} • ${user.followersCount} followers',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFF6B7280),
                              fontWeight: FontWeight.w700,
                              fontSize: 12.5,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              _tinyTag(
                                '₹${user.listenerRate}/min',
                                bg: const Color(0xFFEEF2FF),
                                fg: const Color(0xFF4A4FB3),
                              ),
                              _tinyTag(
                                _hasBlockingCallState
                                    ? 'Your call active'
                                    : user.isAvailable && !user.hasActiveCall
                                        ? 'Available'
                                        : 'Busy',
                                bg: _hasBlockingCallState
                                    ? const Color(0xFFEEF2FF)
                                    : user.isAvailable && !user.hasActiveCall
                                        ? const Color(0xFFECFDF3)
                                        : const Color(0xFFFEECEC),
                                fg: _hasBlockingCallState
                                    ? const Color(0xFF4F46E5)
                                    : user.isAvailable && !user.hasActiveCall
                                        ? const Color(0xFF15803D)
                                        : const Color(0xFFDC2626),
                              ),
                            ],
                          ),
                          const Spacer(),
                          SizedBox(
                            width: double.infinity,
                            child: ValueListenableBuilder<int>(
                              valueListenable: _callCooldownRemaining,
                              builder: (_, __, ___) {
                                return FilledButton(
                                  onPressed: canCallButton
                                      ? () => _startCall(
                                            me: me,
                                            listenerId: user.uid,
                                            visibleRate: user.listenerRate,
                                          )
                                      : null,
                                  child: Text(
                                    callingFor == user.uid
                                        ? 'Calling...'
                                        : _hasBlockingCallState
                                            ? 'Call Active'
                                            : _isCoolingDownFor(user.uid)
                                                ? 'Wait ${_callCooldownRemaining.value}s'
                                                : user.isAvailable &&
                                                        !user.hasActiveCall
                                                    ? 'Call now'
                                                    : 'Busy',
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _emptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              favoritesOnly
                  ? Icons.star_border_rounded
                  : Icons.search_off_rounded,
              size: 52,
              color: Colors.black38,
            ),
            const SizedBox(height: 12),
            Text(
              favoritesOnly
                  ? 'No favorite listeners match your filters.'
                  : 'No listeners match your filters.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              favoritesOnly
                  ? 'Try turning off Favorites only, or change topic, language, gender, location, or search.'
                  : 'Try changing topic, language, gender, location, availability, or search text.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFF6B7280),
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: _resetFilters,
              icon: const Icon(Icons.filter_alt_off_rounded),
              label: const Text('Reset filters'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _listenerCard({
    required AppUserModel user,
    required AppUserModel me,
    required Set<String> followingSet,
    required int myAvailable,
  }) {
    final id = user.uid;
    final name =
        user.displayName.trim().isEmpty ? 'Listener' : user.displayName.trim();

    final followers = user.followersCount;
    final level = _userRepository.levelFromFollowers(followers);

    final visibleRate = user.listenerRate;
    final listenerEarn = _listenerEarnFromVisible(visibleRate);

    final isBusy = _isUserBusyFromUserDoc(user);

    final isFollowing = followingSet.contains(id);
    final isFavorite = _userRepository.isFavoriteListener(
      me: me,
      listenerId: id,
    );

    final followWorking = followingWorkingFor == id;
    final favoriteWorking = favoriteWorkingFor == id;
    final chatWorking = openingChatFor == id;
    final profileWorking = openingProfileFor == id;
    final canInteract = (!_busyWithAnyAction && !_hasBlockingCallState) ||
        followWorking ||
        favoriteWorking ||
        chatWorking ||
        profileWorking;

    final ratingAvg = user.ratingAvg;
    final ratingCount = user.ratingCount;
    final hasRating = ratingCount > 0;

    final bio = user.bio.trim();
    final topics = _safeStringList(user.topics);
    final languages = _safeStringList(user.languages);

    final statusText = _hasBlockingCallState
        ? 'Your call active'
        : isBusy
            ? 'Busy'
            : 'Available';
    final statusBg = _hasBlockingCallState
        ? const Color(0xFFEEF2FF)
        : isBusy
            ? const Color(0xFFFEECEC)
            : const Color(0xFFECFDF3);
    final statusFg = _hasBlockingCallState
        ? const Color(0xFF4F46E5)
        : isBusy
            ? const Color(0xFFDC2626)
            : const Color(0xFF16A34A);

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: canInteract ? () => _openListenerProfile(user) : null,
        child: Ink(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: Colors.black.withValues(alpha: 0.05),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: const Color(0xFFE6E8FF),
                    child: Text(
                      name.isNotEmpty ? name[0].toUpperCase() : 'L',
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF4A4FB3),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w900,
                                  color: Color(0xFF111827),
                                ),
                              ),
                            ),
                            if (isFavorite)
                              const Padding(
                                padding: EdgeInsets.only(left: 6),
                                child: Icon(
                                  Icons.star_rounded,
                                  color: Color(0xFFF59E0B),
                                  size: 18,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 5),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 9,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: statusBg,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                statusText,
                                style: TextStyle(
                                  color: statusFg,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 11.5,
                                ),
                              ),
                            ),
                            _tinyTag('Level $level'),
                            _tinyTag('$followers followers'),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _metricChip(
                    icon: Icons.currency_rupee_rounded,
                    text: '$visibleRate/min',
                    color: const Color(0xFF5B5BD6),
                  ),
                  _metricChip(
                    icon: Icons.star_rounded,
                    text: hasRating
                        ? '${_ratingLabel(ratingAvg)} ($ratingCount)'
                        : 'No ratings',
                    color: const Color(0xFFF59E0B),
                  ),
                ],
              ),
              if (bio.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  bio,
                  style: const TextStyle(
                    color: Color(0xFF4B5563),
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                    fontSize: 13,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (topics.isNotEmpty) ...[
                const SizedBox(height: 10),
                _smallChips(topics),
              ],
              if (languages.isNotEmpty) ...[
                const SizedBox(height: 8),
                _smallChips(languages),
              ],
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8F9FD),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'You pay ₹$visibleRate / full minute',
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF111827),
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Listener earns ₹$listenerEarn / full minute',
                      style: const TextStyle(
                        color: Color(0xFF6B7280),
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _hasBlockingCallState
                          ? 'Finish current call to start another'
                          : 'Your usable credit: ₹$myAvailable',
                      style: const TextStyle(
                        color: Color(0xFF6B7280),
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              ValueListenableBuilder<int>(
                valueListenable: _callCooldownRemaining,
                builder: (_, __, ___) {
                  return Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: FilledButton.icon(
                          onPressed: !_busyWithAnyAction &&
                                  !_hasBlockingCallState &&
                                  !isBusy &&
                                  !_isCoolingDownFor(id)
                              ? () => _startCall(
                                    me: me,
                                    listenerId: id,
                                    visibleRate: visibleRate,
                                  )
                              : null,
                          icon: const Icon(Icons.call_rounded, size: 18),
                          label: Text(
                            callingFor == id
                                ? 'Calling...'
                                : _hasBlockingCallState
                                    ? 'Call Active'
                                    : _isCoolingDownFor(id)
                                        ? 'Wait ${_callCooldownRemaining.value}s'
                                        : isBusy
                                            ? 'Busy'
                                            : 'Call now',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: !canInteract
                              ? null
                              : () => _openListenerProfile(user),
                          child: Text(
                            profileWorking ? '...' : 'Profile',
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: (!canInteract || chatWorking)
                          ? null
                          : () => _openChat(
                                me: me,
                                listener: user,
                              ),
                      icon: chatWorking
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(
                              Icons.chat_bubble_outline_rounded,
                              size: 18,
                            ),
                      label: Text(chatWorking ? 'Opening...' : 'Chat'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: (!canInteract || followWorking)
                          ? null
                          : () => _toggleFollow(
                                listenerId: id,
                                isFollowing: isFollowing,
                              ),
                      icon: Icon(
                        isFollowing
                            ? Icons.person_remove_alt_1
                            : Icons.person_add_alt_1,
                        size: 18,
                      ),
                      label: Text(
                        followWorking
                            ? 'Please wait...'
                            : (isFollowing ? 'Unfollow' : 'Follow'),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: (!canInteract || favoriteWorking)
                          ? null
                          : () => _toggleFavorite(
                                listenerId: id,
                                isFavorite: isFavorite,
                              ),
                      icon: favoriteWorking
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                              ),
                            )
                          : Icon(
                              isFavorite
                                  ? Icons.star_rounded
                                  : Icons.star_border_rounded,
                              color: isFavorite
                                  ? const Color(0xFFF59E0B)
                                  : null,
                            ),
                      label: Text(
                        isFavorite ? 'Unfavorite' : 'Favorite',
                      ),
                    ),
                  ),
                ],
              ),
              if (kDebugMode) ...[
                const SizedBox(height: 8),
                Text(
                  'Debug → isBusy=$isBusy, isFavorite=$isFavorite, isAvailable=${user.isAvailable}, activeCallId=${user.activeCallId}, cooldown=${_isCoolingDownFor(user.uid) ? _callCooldownRemaining.value : 0}, localCallState=${_callSession.state.name}',
                  style: const TextStyle(
                    color: Colors.black45,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _callSession,
      builder: (_, __) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Find a Listener'),
          ),
          body: StreamBuilder<AppUserModel?>(
            stream: _userRepository.watchMe(),
            builder: (_, meSnap) {
              if (!meSnap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              final me = meSnap.data!;
              final followingSet = me.following.map((e) => e.trim()).toSet();
              final myAvailable = me.usableCredits;

              return StreamBuilder<List<AppUserModel>>(
                stream: _userRepository.watchAvailableListeners(limit: 200),
                builder: (_, snap) {
                  if (!snap.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  final allListeners = snap.data!;
                  final listenerOnly = List<AppUserModel>.from(
                    allListeners,
                    growable: false,
                  );
                  
                  final topicOptions = [
                    'All',
                    ..._collectAllTopics(listenerOnly),
                  ];
                  final languageOptions = [
                    'All',
                    ..._collectAllLanguages(listenerOnly),
                  ];
                  final genderOptions = [
                    'All',
                    ..._collectAllGenders(listenerOnly),
                  ];
                  final locationOptions = [
                    'All',
                    ..._collectAllLocations(listenerOnly),
                  ];

                  final safeSelectedTopic = topicOptions.contains(selectedTopic)
                      ? selectedTopic
                      : 'All';
                  final safeSelectedLanguage =
                      languageOptions.contains(selectedLanguage)
                          ? selectedLanguage
                          : 'All';
                  final safeSelectedGender = genderOptions.contains(selectedGender)
                      ? selectedGender
                      : 'All';
                  final safeSelectedLocation =
                      locationOptions.contains(selectedLocation)
                          ? selectedLocation
                          : 'All';

                  final filtered = _applyFilters(
                    listeners: listenerOnly,
                    myUid: me.uid,
                    me: me,
                    effectiveTopic: safeSelectedTopic,
                    effectiveLanguage: safeSelectedLanguage,
                    effectiveGender: safeSelectedGender,
                    effectiveLocation: safeSelectedLocation,
                  ).toList();

                  _sortListeners(
                    listeners: filtered,
                    me: me,
                  );

                  final topListeners = _topListeners(filtered);
                  final regularListeners = _regularListenersWithoutTop(
                    filtered: filtered,
                    topListeners: topListeners,
                  );

                  final totalListeners = listenerOnly.length;
                  final onlineListeners = listenerOnly
                      .where((e) => e.isAvailable && !e.hasActiveCall)
                      .length;
                  final favoriteCount = _safeStringList(me.favoriteListeners).length;

                  return ListView(
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 20),
                    children: [
                      _topDiscoveryCard(
                        total: totalListeners,
                        online: onlineListeners,
                        favorites: favoriteCount,
                        usableCredit: myAvailable,
                      ),
                      const SizedBox(height: 12),
                      _filterCard(
                        topicOptions: topicOptions,
                        languageOptions: languageOptions,
                        genderOptions: genderOptions,
                        locationOptions: locationOptions,
                        safeSelectedTopic: safeSelectedTopic,
                        safeSelectedLanguage: safeSelectedLanguage,
                        safeSelectedGender: safeSelectedGender,
                        safeSelectedLocation: safeSelectedLocation,
                        myAvailable: myAvailable,
                      ),
                      const SizedBox(height: 16),
                      if (_hasBlockingCallState) ...[
                        Card(
                          color: const Color(0xFFEEF2FF),
                          child: const Padding(
                            padding: EdgeInsets.all(14),
                            child: Text(
                              'You already have a call flow in progress. Starting another call is temporarily disabled.',
                              style: TextStyle(
                                color: Color(0xFF4F46E5),
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                      ],
                      if (topListeners.isNotEmpty) ...[
                        _topListenersSection(
                          topListeners: topListeners,
                          me: me,
                          myAvailable: myAvailable,
                        ),
                        const SizedBox(height: 18),
                      ],
                      _sectionTitle(
                        topListeners.isNotEmpty ? 'More listeners' : 'Listeners',
                        subtitle:
                            '${filtered.length} result${filtered.length == 1 ? '' : 's'}',
                      ),
                      const SizedBox(height: 10),
                      if (filtered.isEmpty)
                        SizedBox(
                          height: 280,
                          child: _emptyState(),
                        )
                      else if (regularListeners.isEmpty && topListeners.isNotEmpty)
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(18),
                            child: Column(
                              children: const [
                                Icon(
                                  Icons.emoji_events_outlined,
                                  size: 42,
                                  color: Color(0xFFF59E0B),
                                ),
                                SizedBox(height: 10),
                                Text(
                                  'Only top listeners match your current filters.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w900,
                                    fontSize: 16,
                                  ),
                                ),
                                SizedBox(height: 6),
                                Text(
                                  'Try changing filters to see more listeners.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: Color(0xFF6B7280),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      else
                        ...List.generate(regularListeners.length, (i) {
                          final user = regularListeners[i];
                          return Padding(
                            padding: EdgeInsets.only(
                              bottom: i == regularListeners.length - 1 ? 0 : 10,
                            ),
                            child: _listenerCard(
                              user: user,
                              me: me,
                              followingSet: followingSet,
                              myAvailable: myAvailable,
                            ),
                          );
                        }),
                    ],
                  );
                },
              );
            },
          ),
        );
      },
    );
  }
}