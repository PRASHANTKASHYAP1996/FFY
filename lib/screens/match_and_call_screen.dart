import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/constants/firestore_paths.dart';
import '../core/theme/app_palette.dart';
import '../repositories/call_repository.dart';
import '../repositories/user_repository.dart';
import '../services/call_session_manager.dart';
import '../shared/chat_direction_resolver.dart';
import '../shared/chat_navigation_guards.dart';
import '../shared/listener_availability.dart';
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

enum _AvailabilityFilter {
  onlineNow,
  allListeners,
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
  final Map<String, Future<Map<String, dynamic>>> _listenerSessionFutureCache =
      <String, Future<Map<String, dynamic>>>{};

  final TextEditingController _searchController = TextEditingController();

  String search = '';
  String followingWorkingFor = '';
  String favoriteWorkingFor = '';
  String callingFor = '';
  String openingChatFor = '';
  String openingProfileFor = '';
  bool _callStartInFlight = false;

  _AvailabilityFilter availabilityFilter = _AvailabilityFilter.allListeners;
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

  Future<void> _showConversationRepairDialog(AppUserModel listener) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('This conversation needs repair'),
          content: Text(
            'We could not confirm the saved speaker/listener direction for your conversation with ${listener.safeDisplayName}. Please go back and repair it before opening this chat.',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Go back'),
            ),
          ],
        );
      },
    );
  }

  Future<bool> _showExistingConversationDialog(AppUserModel listener) async {
    if (!mounted) return false;
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Existing conversation found'),
          content: Text(
            'You already have a conversation with ${listener.safeDisplayName} from the other side of this connection. You can open that conversation safely or go back.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Go back'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Open conversation'),
            ),
          ],
        );
      },
    );
    return result == true;
  }

  int _listenerEarnFromVisible(int visibleRate) {
    return _userRepository.listenerPayoutFromVisibleRate(visibleRate);
  }

  ListenerAvailabilityResult _availabilityForUser(AppUserModel user) {
    return _userRepository.listenerAvailabilityForUser(user);
  }

  int _availabilityRankFromUserDoc(AppUserModel user) {
    switch (_availabilityForUser(user).kind) {
      case ListenerAvailabilityKind.available:
        return 0;
      case ListenerAvailabilityKind.checking:
        return 1;
      case ListenerAvailabilityKind.offline:
        return 2;
      case ListenerAvailabilityKind.onAnotherCall:
        return 3;
    }
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
    return _callRepository.humanizeCallActionError(e);
  }

  Future<Map<String, dynamic>> _listenerSessionFuture({
    required String speakerId,
    required String listenerId,
  }) {
    final safeSpeakerId = speakerId.trim();
    final safeListenerId = listenerId.trim();
    if (safeSpeakerId.isEmpty ||
        safeListenerId.isEmpty ||
        safeSpeakerId == safeListenerId) {
      return Future<Map<String, dynamic>>.value(<String, dynamic>{});
    }

    final key = '$safeSpeakerId::$safeListenerId';
    return _listenerSessionFutureCache.putIfAbsent(
      key,
      () => _callRepository.getChatSessionByPair(
        speakerId: safeSpeakerId,
        listenerId: safeListenerId,
      ),
    );
  }

  void _invalidateListenerSession({
    required String speakerId,
    required String listenerId,
  }) {
    final safeSpeakerId = speakerId.trim();
    final safeListenerId = listenerId.trim();
    if (safeSpeakerId.isEmpty ||
        safeListenerId.isEmpty ||
        safeSpeakerId == safeListenerId) {
      return;
    }

    _listenerSessionFutureCache.remove('$safeSpeakerId::$safeListenerId');
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
      availabilityFilter = _AvailabilityFilter.allListeners;
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
          await _showConversationRepairDialog(listener);
          return;
        }

        if (!selectedListenerMatchesStoredDirection(
          selectedListenerId: safeListenerId,
          actualListenerId: direction.actualListenerId,
        )) {
          final openExisting = await _showExistingConversationDialog(listener);
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
                initialOtherUser: listener,
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
              initialOtherUser: listener,
            ),
          ),
        );
        return;
      }

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
      FocusManager.instance.primaryFocus?.unfocus();

      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatConversationScreen(
            speakerId: me.uid,
            listenerId: safeListenerId,
            actualListenerId: safeListenerId,
            iAmListener: false,
            initialOtherUser: listener,
          ),
        ),
      );
    } catch (e) {
      _showSnack(_callRepository.humanizeChatActionError(e));
    } finally {
      _invalidateListenerSession(
        speakerId: me.uid,
        listenerId: safeListenerId,
      );
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

      if (meLatest.onlyChatMode) {
        debugPrint(
          'call.start_local_preflight_blocked reason=self_only_chat_mode',
        );
        _showSnack('Turn off Only Chat Mode to start calls.');
        return;
      }

      final latestAvailable = _userRepository.usableCreditsFromUser(meLatest);

      if (latestAvailable < visibleRate) {
        debugPrint(
          'call.start_local_preflight_blocked reason=insufficient_credits',
        );
        _showSnack('Add credits before starting a call.');
        return;
      }

      final listenerLatest = await _userRepository.getUser(safeListenerId);
      if (listenerLatest == null) {
        _showSnack('Listener not found.');
        return;
      }

      if (listenerLatest.onlyChatMode) {
        debugPrint(
          'call.start_local_preflight_blocked reason=peer_only_chat_mode',
        );
        _showSnack('This user is in Only Chat Mode.');
        return;
      }

      final canActuallyCall = await _callRepository.canCurrentUserCallListener(
        listenerId: safeListenerId,
      );

      if (!canActuallyCall) {
        debugPrint(
          'call.start_local_preflight_blocked reason=not_accepted',
        );
        _showSnack('Request must be accepted before starting a call.');
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

      final callStart = await _callRepository.createCallToListener(
        listenerId: safeListenerId,
      );

      if (!mounted) return;
      setState(() {
        callingFor = '';
        _callStartInFlight = false;
      });

      if (callStart == null) {
        _showSnack('Call could not start. Please try again.');
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
      if (myState.isNotEmpty && userState.isNotEmpty && myState == userState) {
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

      if (availabilityFilter == _AvailabilityFilter.onlineNow &&
          !_availabilityForUser(user).canCallNow) {
        return false;
      }

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

      if (effectiveLanguage != 'All' &&
          !languages.contains(effectiveLanguage)) {
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

      final aAvailabilityRank = _availabilityRankFromUserDoc(a);
      final bAvailabilityRank = _availabilityRankFromUserDoc(b);

      switch (sortOption) {
        case _ListenerSortOption.highestRated:
          if (aAvailabilityRank != bAvailabilityRank) {
            return aAvailabilityRank.compareTo(bAvailabilityRank);
          }
          final ratingCompare = br.compareTo(ar);
          if (ratingCompare != 0) return ratingCompare;
          final countCompare = bc.compareTo(ac);
          if (countCompare != 0) return countCompare;
          return ap.compareTo(bp);

        case _ListenerSortOption.lowestPrice:
          if (aAvailabilityRank != bAvailabilityRank) {
            return aAvailabilityRank.compareTo(bAvailabilityRank);
          }
          final priceCompare = ap.compareTo(bp);
          if (priceCompare != 0) return priceCompare;
          final ratingCompare = br.compareTo(ar);
          if (ratingCompare != 0) return ratingCompare;
          return bf.compareTo(af);

        case _ListenerSortOption.highestFollowers:
          if (aAvailabilityRank != bAvailabilityRank) {
            return aAvailabilityRank.compareTo(bAvailabilityRank);
          }
          final followerCompare = bf.compareTo(af);
          if (followerCompare != 0) return followerCompare;
          final ratingCompare = br.compareTo(ar);
          if (ratingCompare != 0) return ratingCompare;
          return ap.compareTo(bp);

        case _ListenerSortOption.favoritesFirst:
          if (bIsFavorite != aIsFavorite) {
            return aIsFavorite ? -1 : 1;
          }
          if (aAvailabilityRank != bAvailabilityRank) {
            return aAvailabilityRank.compareTo(bAvailabilityRank);
          }
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

          if (aAvailabilityRank != bAvailabilityRank) {
            return aAvailabilityRank.compareTo(bAvailabilityRank);
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
          (u) => u.isAvailable && u.ratingAvg >= 4.0 && u.ratingCount >= 5,
        )
        .toList(growable: false);

    final sorted = [...out]..sort((a, b) {
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
    return filtered
        .where((u) => !topIds.contains(u.uid))
        .toList(growable: false);
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
                  color: AppPalette.textPrimary,
                ),
              ),
              if (subtitle != null && subtitle.trim().isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: AppPalette.textSecondary,
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
    final safeColor = color ?? AppPalette.blue;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      decoration: BoxDecoration(
        color: safeColor.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: safeColor.withValues(alpha: 0.26),
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
        color: bg ?? AppPalette.feedBg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: AppPalette.border,
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w800,
          color: fg ?? AppPalette.textSecondary,
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
    required int matching,
    required int online,
    required int favorites,
    required int usableCredit,
  }) {
    return Container(
      decoration: AppPalette.cardDecoration(radius: 24),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Find your best listener',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w900,
                color: AppPalette.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Search by topic, language, gender, location, rating, or price and connect faster.',
              style: TextStyle(
                color: AppPalette.textSecondary,
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _metricChip(
                  icon: Icons.people_alt_rounded,
                  text: matching == total
                      ? '$total listeners'
                      : '$matching matching',
                ),
                _metricChip(
                  icon: Icons.wifi_tethering_rounded,
                  text: '$online available',
                  color: AppPalette.online,
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
                      : 'Rs $usableCredit credit',
                  color: AppPalette.blue,
                ),
              ],
            ),
            if (matching != total) ...[
              const SizedBox(height: 10),
              Text(
                '$total total listeners in directory. Current filters hide ${total - matching}.',
                style: const TextStyle(
                  color: AppPalette.textSecondary,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                ),
              ),
            ],
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
      color: selected ? AppPalette.blueTint : AppPalette.feedBg,
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
                  ? AppPalette.blue.withValues(alpha: 0.4)
                  : AppPalette.border,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: selected ? AppPalette.blue : AppPalette.textSecondary,
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
    final fieldDecoration = InputDecoration(
      filled: true,
      fillColor: AppPalette.feedBg,
      labelStyle: const TextStyle(color: AppPalette.textSecondary),
      hintStyle: const TextStyle(color: AppPalette.textMuted),
      prefixIconColor: AppPalette.textMuted,
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(
          color: AppPalette.border,
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppPalette.blue),
      ),
    );

    return Container(
      decoration: AppPalette.cardDecoration(radius: 20),
      child: Padding(
        padding: const EdgeInsets.all(12),
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
            const SizedBox(height: 10),
            TextField(
              controller: _searchController,
              style: const TextStyle(
                color: AppPalette.textPrimary,
                fontWeight: FontWeight.w700,
              ),
              decoration: fieldDecoration.copyWith(
                hintText: 'Search name, bio, topic, language...',
                prefixIcon: const Icon(Icons.search_rounded),
              ),
              onChanged: _handleSearchChanged,
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                SizedBox(
                  width: 220,
                  child: DropdownButtonFormField<_ListenerSortOption>(
                    initialValue: sortOption,
                    isExpanded: true,
                    dropdownColor: AppPalette.card,
                    style: const TextStyle(color: AppPalette.textPrimary),
                    decoration: fieldDecoration.copyWith(
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
                  selected: availabilityFilter == _AvailabilityFilter.onlineNow,
                  onTap: () => setState(
                    () => availabilityFilter = _AvailabilityFilter.onlineNow,
                  ),
                ),
                _toggleFilterChip(
                  label: 'All listeners',
                  selected:
                      availabilityFilter == _AvailabilityFilter.allListeners,
                  onTap: () => setState(
                    () => availabilityFilter = _AvailabilityFilter.allListeners,
                  ),
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
                      : 'Rs $myAvailable usable',
                  color: AppPalette.blue,
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
                    dropdownColor: AppPalette.card,
                    style: const TextStyle(color: AppPalette.textPrimary),
                    decoration: fieldDecoration.copyWith(
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
                    dropdownColor: AppPalette.card,
                    style: const TextStyle(color: AppPalette.textPrimary),
                    decoration: fieldDecoration.copyWith(
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
                    dropdownColor: AppPalette.card,
                    style: const TextStyle(color: AppPalette.textPrimary),
                    decoration: fieldDecoration.copyWith(
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
                    dropdownColor: AppPalette.card,
                    style: const TextStyle(color: AppPalette.textPrimary),
                    decoration: fieldDecoration.copyWith(
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
              final availability = _availabilityForUser(user);
              final isOnAnotherCall =
                  availability.kind == ListenerAvailabilityKind.onAnotherCall;
              final isChecking =
                  availability.kind == ListenerAvailabilityKind.checking;

              return SizedBox(
                width: 220,
                child: Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(20),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: _busyWithAnyAction
                        ? null
                        : () => _openListenerProfile(user),
                    child: Ink(
                      padding: const EdgeInsets.all(14),
                      decoration: AppPalette.cardDecoration(radius: 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              CircleAvatar(
                                radius: 22,
                                backgroundColor: AppPalette.blueTint,
                                child: Text(
                                  name.isNotEmpty ? name[0].toUpperCase() : 'L',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w900,
                                    color: AppPalette.blue,
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
                              color: AppPalette.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${_ratingLabel(user.ratingAvg)} rating | ${user.followersCount} followers',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppPalette.textSecondary,
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
                                'Rs ${user.listenerRate}/min',
                                bg: AppPalette.blueTint,
                                fg: AppPalette.blue,
                              ),
                              _tinyTag(
                                _hasBlockingCallState
                                    ? 'Your call active'
                                    : availability.label,
                                bg: _hasBlockingCallState
                                    ? const Color(0xFFEEF2FF)
                                    : isOnAnotherCall
                                        ? const Color(0xFFFEECEC)
                                        : availability.kind ==
                                                ListenerAvailabilityKind
                                                    .available
                                            ? const Color(0xFFECFDF3)
                                            : isChecking
                                                ? const Color(0xFFFFFBEB)
                                                : const Color(0xFFF3F4F6),
                                fg: _hasBlockingCallState
                                    ? const Color(0xFF4F46E5)
                                    : isOnAnotherCall
                                        ? const Color(0xFFDC2626)
                                        : availability.kind ==
                                                ListenerAvailabilityKind
                                                    .available
                                            ? const Color(0xFF15803D)
                                            : isChecking
                                                ? const Color(0xFFB45309)
                                                : const Color(0xFF6B7280),
                              ),
                            ],
                          ),
                          const Spacer(),
                          SizedBox(
                            width: double.infinity,
                            child: FutureBuilder<Map<String, dynamic>>(
                              future: _listenerSessionFuture(
                                speakerId: me.uid,
                                listenerId: user.uid,
                              ),
                              builder: (_, sessionSnap) {
                                return ValueListenableBuilder<int>(
                                  valueListenable: _callCooldownRemaining,
                                  builder: (_, __, ___) {
                                    final session = sessionSnap.data ??
                                        const <String, dynamic>{};
                                    final checkingSession =
                                        sessionSnap.connectionState !=
                                                ConnectionState.done &&
                                            sessionSnap.data == null;
                                    final sessionExists =
                                        session['exists'] == true;
                                    final sessionBlocked = session[
                                                FirestorePaths
                                                    .fieldSpeakerBlocked] ==
                                            true ||
                                        session[FirestorePaths
                                                .fieldListenerBlocked] ==
                                            true;
                                    final sessionCallAllowed = sessionExists &&
                                        !sessionBlocked &&
                                        _callRepository
                                            .sessionAllowsCallForDirection(
                                          session: session,
                                          speakerId: me.uid,
                                          listenerId: user.uid,
                                        );
                                    final canPressPrimary =
                                        !_busyWithAnyAction &&
                                            !_hasBlockingCallState &&
                                            !_isCoolingDownFor(user.uid) &&
                                            !checkingSession &&
                                            !sessionBlocked &&
                                            (!sessionCallAllowed ||
                                                availability.canCallNow);

                                    final primaryLabel = openingChatFor ==
                                                user.uid &&
                                            !sessionCallAllowed
                                        ? 'Opening...'
                                        : callingFor == user.uid &&
                                                sessionCallAllowed
                                            ? 'Calling...'
                                            : _hasBlockingCallState
                                                ? 'Call Active'
                                                : _isCoolingDownFor(user.uid)
                                                    ? 'Wait ${_callCooldownRemaining.value}s'
                                                    : checkingSession
                                                        ? 'Checking...'
                                                        : sessionCallAllowed
                                                            ? (availability
                                                                    .canCallNow
                                                                ? 'Call now'
                                                                : availability
                                                                    .label)
                                                            : 'Open chat';

                                    return FilledButton(
                                      onPressed: !canPressPrimary
                                          ? null
                                          : sessionCallAllowed
                                              ? () => _startCall(
                                                    me: me,
                                                    listenerId: user.uid,
                                                    visibleRate:
                                                        user.listenerRate,
                                                  )
                                              : () => _openChat(
                                                    me: me,
                                                    listener: user,
                                                  ),
                                      child: Text(primaryLabel),
                                    );
                                  },
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

  Widget _emptyState({
    required int totalListeners,
    required int onlineListeners,
  }) {
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
              color: AppPalette.blue,
            ),
            const SizedBox(height: 12),
            Text(
              favoritesOnly
                  ? 'No favorite listeners match your filters.'
                  : availabilityFilter == _AvailabilityFilter.onlineNow &&
                          onlineListeners == 0 &&
                          totalListeners > 0
                      ? 'No listeners are available right now.'
                      : 'No listeners match your filters.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w900,
                color: AppPalette.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              favoritesOnly
                  ? 'Try turning off Favorites only, or change topic, language, gender, location, or search.'
                  : availabilityFilter == _AvailabilityFilter.onlineNow &&
                          onlineListeners == 0 &&
                          totalListeners > 0
                      ? 'Your directory has listeners, but none are currently available. Turn off Available now to browse everyone.'
                      : 'Try changing topic, language, gender, location, availability, or search text.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppPalette.textSecondary,
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

    final availability = _availabilityForUser(user);
    final isOnAnotherCall =
        availability.kind == ListenerAvailabilityKind.onAnotherCall;
    final isChecking = availability.kind == ListenerAvailabilityKind.checking;
    const isCallUnavailable = false;

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

    final statusText =
        _hasBlockingCallState ? 'Call in progress' : availability.label;
    final statusBg = _hasBlockingCallState
        ? const Color(0xFFEEF2FF)
        : isOnAnotherCall
            ? const Color(0xFFFEECEC)
            : availability.kind == ListenerAvailabilityKind.available
                ? const Color(0xFFECFDF3)
                : isChecking
                    ? const Color(0xFFFFFBEB)
                    : const Color(0xFFF3F4F6);
    final statusFg = _hasBlockingCallState
        ? const Color(0xFF4F46E5)
        : isOnAnotherCall
            ? const Color(0xFFDC2626)
            : availability.kind == ListenerAvailabilityKind.available
                ? const Color(0xFF16A34A)
                : isChecking
                    ? const Color(0xFFB45309)
                    : const Color(0xFF6B7280);

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: canInteract ? () => _openListenerProfile(user) : null,
        child: Ink(
          padding: const EdgeInsets.all(12),
          decoration: AppPalette.cardDecoration(radius: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: AppPalette.blueTint,
                    child: Text(
                      name.isNotEmpty ? name[0].toUpperCase() : 'L',
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        color: AppPalette.blue,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
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
                                  fontSize: 15,
                                  fontWeight: FontWeight.w900,
                                  color: AppPalette.textPrimary,
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
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _metricChip(
                    icon: Icons.currency_rupee_rounded,
                    text: '$visibleRate/min',
                    color: AppPalette.blue,
                  ),
                  _metricChip(
                    icon: Icons.star_rounded,
                    text: hasRating
                        ? '${_ratingLabel(ratingAvg)} ($ratingCount)'
                        : 'Not rated yet',
                    color: const Color(0xFFF59E0B),
                  ),
                ],
              ),
              if (bio.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  bio,
                  style: const TextStyle(
                    color: AppPalette.textSecondary,
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                    fontSize: 13,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (topics.isNotEmpty) ...[
                const SizedBox(height: 6),
                _smallChips(topics),
              ],
              if (languages.isNotEmpty) ...[
                const SizedBox(height: 8),
                _smallChips(languages),
              ],
              const SizedBox(height: 8),
              Text(
                _hasBlockingCallState
                    ? 'Current call in progress'
                    : 'Rs $visibleRate/min | You have Rs $myAvailable | Listener earns Rs $listenerEarn',
                style: const TextStyle(
                  color: AppPalette.textSecondary,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  height: 1.25,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              ValueListenableBuilder<int>(
                valueListenable: _callCooldownRemaining,
                builder: (_, __, ___) {
                  return Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: FutureBuilder<Map<String, dynamic>>(
                          future: _listenerSessionFuture(
                            speakerId: me.uid,
                            listenerId: id,
                          ),
                          builder: (_, sessionSnap) {
                            final session =
                                sessionSnap.data ?? const <String, dynamic>{};
                            final checkingSession =
                                sessionSnap.connectionState !=
                                        ConnectionState.done &&
                                    sessionSnap.data == null;
                            final sessionExists = session['exists'] == true;
                            final sessionBlocked = session[
                                        FirestorePaths.fieldSpeakerBlocked] ==
                                    true ||
                                session[FirestorePaths.fieldListenerBlocked] ==
                                    true;
                            final sessionCallAllowed = sessionExists &&
                                !sessionBlocked &&
                                _callRepository.sessionAllowsCallForDirection(
                                  session: session,
                                  speakerId: me.uid,
                                  listenerId: id,
                                );

                            final canPressPrimary = !_busyWithAnyAction &&
                                !_hasBlockingCallState &&
                                !_isCoolingDownFor(id) &&
                                !isCallUnavailable &&
                                !checkingSession &&
                                !sessionBlocked &&
                                (!sessionCallAllowed ||
                                    availability.canCallNow);

                            final primaryLabel = chatWorking &&
                                    !sessionCallAllowed
                                ? 'Opening...'
                                : callingFor == id && sessionCallAllowed
                                    ? 'Calling...'
                                    : _hasBlockingCallState
                                        ? 'Call Active'
                                        : _isCoolingDownFor(id)
                                            ? 'Wait ${_callCooldownRemaining.value}s'
                                            : checkingSession
                                                ? 'Checking...'
                                                : sessionCallAllowed
                                                    ? (availability.canCallNow
                                                        ? 'Call now'
                                                        : availability.label)
                                                    : 'Open chat';

                            return FilledButton.icon(
                              onPressed: !canPressPrimary
                                  ? null
                                  : sessionCallAllowed
                                      ? () => _startCall(
                                            me: me,
                                            listenerId: id,
                                            visibleRate: visibleRate,
                                          )
                                      : () => _openChat(
                                            me: me,
                                            listener: user,
                                          ),
                              icon: const Icon(Icons.call_rounded, size: 18),
                              label: Text(primaryLabel),
                            );
                          },
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
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: (!canInteract || chatWorking)
                        ? null
                        : () => _openChat(
                              me: me,
                              listener: user,
                            ),
                    icon: chatWorking
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(
                            Icons.chat_bubble_outline_rounded,
                            size: 16,
                          ),
                    label: Text(chatWorking ? 'Opening...' : 'Chat'),
                  ),
                  OutlinedButton.icon(
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
                      size: 16,
                    ),
                    label: Text(
                      followWorking
                          ? 'Please wait...'
                          : (isFollowing ? 'Unfollow' : 'Follow'),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: (!canInteract || favoriteWorking)
                        ? null
                        : () => _toggleFavorite(
                              listenerId: id,
                              isFavorite: isFavorite,
                            ),
                    icon: favoriteWorking
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            isFavorite
                                ? Icons.star_rounded
                                : Icons.star_border_rounded,
                            size: 16,
                            color: isFavorite ? const Color(0xFFF59E0B) : null,
                          ),
                    label: Text(isFavorite ? 'Unfavorite' : 'Favorite'),
                  ),
                ],
              ),
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
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: const SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.dark,
            statusBarBrightness: Brightness.light,
          ),
          child: Scaffold(
            backgroundColor: AppPalette.pageBg,
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              foregroundColor: AppPalette.textPrimary,
              title: const Text('Search'),
            ),
            body: Theme(
              data: AppPalette.lightSheetTheme(context),
              child: DecoratedBox(
                decoration: const BoxDecoration(color: AppPalette.pageBg),
                child: StreamBuilder<AppUserModel?>(
                  stream: _userRepository.watchMe(),
                  builder: (_, meSnap) {
                    if (!meSnap.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    final me = meSnap.data!;
                    final followingSet =
                        me.following.map((e) => e.trim()).toSet();
                    final myAvailable = me.usableCredits;

                    return StreamBuilder<List<AppUserModel>>(
                      stream:
                          _userRepository.watchAvailableListeners(limit: 200),
                      builder: (_, snap) {
                        if (!snap.hasData) {
                          return const Center(
                              child: CircularProgressIndicator());
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

                        final safeSelectedTopic =
                            topicOptions.contains(selectedTopic)
                                ? selectedTopic
                                : 'All';
                        final safeSelectedLanguage =
                            languageOptions.contains(selectedLanguage)
                                ? selectedLanguage
                                : 'All';
                        final safeSelectedGender =
                            genderOptions.contains(selectedGender)
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
                            .where((e) => _availabilityForUser(e).canCallNow)
                            .length;
                        final favoriteCount =
                            _safeStringList(me.favoriteListeners).length;

                        return ListView(
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          padding: const EdgeInsets.fromLTRB(14, 10, 14, 20),
                          children: [
                            _topDiscoveryCard(
                              total: totalListeners,
                              matching: filtered.length,
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
                              Container(
                                decoration:
                                    AppPalette.cardDecoration(radius: 18),
                                child: const Padding(
                                  padding: EdgeInsets.all(14),
                                  child: Text(
                                    'Finish your current call before starting another one.',
                                    style: TextStyle(
                                      color: AppPalette.blue,
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
                              topListeners.isNotEmpty
                                  ? 'More listeners'
                                  : 'Listeners',
                              subtitle:
                                  '${filtered.length} result${filtered.length == 1 ? '' : 's'}',
                            ),
                            const SizedBox(height: 10),
                            if (filtered.isEmpty)
                              SizedBox(
                                height: 280,
                                child: _emptyState(
                                  totalListeners: totalListeners,
                                  onlineListeners: onlineListeners,
                                ),
                              )
                            else if (regularListeners.isEmpty &&
                                topListeners.isNotEmpty)
                              Container(
                                decoration:
                                    AppPalette.cardDecoration(radius: 18),
                                child: const Padding(
                                  padding: EdgeInsets.all(18),
                                  child: Column(
                                    children: [
                                      Icon(
                                        Icons.emoji_events_outlined,
                                        size: 42,
                                        color: Color(0xFFF59E0B),
                                      ),
                                      SizedBox(height: 10),
                                      Text(
                                        'Only top listeners match these filters.',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontWeight: FontWeight.w900,
                                          fontSize: 16,
                                          color: AppPalette.textPrimary,
                                        ),
                                      ),
                                      SizedBox(height: 6),
                                      Text(
                                        'Try changing your filters to see more people.',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          color: AppPalette.textSecondary,
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
                                    bottom: i == regularListeners.length - 1
                                        ? 0
                                        : 10,
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
              ),
            ),
          ),
        );
      },
    );
  }
}
