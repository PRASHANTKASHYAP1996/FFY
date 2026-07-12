import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../core/constants/firestore_paths.dart';
import '../services/firestore_service.dart';
import '../shared/listener_availability.dart';
import '../shared/models/app_user_model.dart';

class UserRepository {
  UserRepository._();

  static final UserRepository instance = UserRepository._();

  FirebaseAuth get _auth => FirebaseAuth.instance;
  FirebaseFirestore get _db => FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _users =>
      _db.collection(FirestorePaths.users);

  CollectionReference<Map<String, dynamic>> get _publicUsers =>
      _db.collection(FirestorePaths.publicUsers);

  CollectionReference<Map<String, dynamic>> get _chatSessions =>
      _db.collection(FirestorePaths.chatSessions);

  String? get myUidOrNull {
    final uid = _auth.currentUser?.uid.trim();
    if (uid == null || uid.isEmpty) return null;
    return uid;
  }

  Stream<T> _authBoundStream<T, S>({
    required String uid,
    required Stream<S> source,
    required T signedOutValue,
    required T Function(S event) convert,
  }) {
    final safeUid = uid.trim();
    if (safeUid.isEmpty) {
      return Stream<T>.value(signedOutValue).asBroadcastStream();
    }

    late StreamController<T> controller;
    StreamSubscription<S>? subscription;

    controller = StreamController<T>.broadcast(
      onListen: () {
        subscription = source.listen(
          (event) {
            if (myUidOrNull != safeUid) return;
            if (controller.isClosed) return;
            controller.add(convert(event));
          },
          onError: (Object error, StackTrace stackTrace) {
            if (myUidOrNull != safeUid) return;
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

  String get myUid {
    final uid = myUidOrNull;
    if (uid == null) {
      throw StateError('User not logged in');
    }
    return uid;
  }

  List<String> _safeStringList(dynamic value) {
    if (value is! List) return const <String>[];

    final seen = <String>{};
    final out = <String>[];

    for (final item in value) {
      final safe = item.toString().trim();
      if (safe.isEmpty) continue;

      final key = safe.toLowerCase();
      if (seen.contains(key)) continue;

      seen.add(key);
      out.add(safe);
    }

    return out;
  }

  int _safeInt(dynamic value, {int fallback = 0}) {
    if (value is int) return value;
    if (value is num) return value.floor();
    return fallback;
  }

  double _safeDouble(dynamic value, {double fallback = 0.0}) {
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return fallback;
  }

  bool _safeBool(dynamic value, {bool fallback = false}) {
    if (value is bool) return value;
    return fallback;
  }

  String _safeString(dynamic value, {String fallback = ''}) {
    if (value is String) return value.trim();
    return fallback;
  }

  Map<String, dynamic>? _normalizePublicUserMap(
    Map<String, dynamic>? data, {
    String? fallbackUid,
  }) {
    if (data == null) return null;

    final uid = _safeString(
      data[FirestorePaths.fieldUid],
      fallback: fallbackUid ?? '',
    );

    if (uid.isEmpty) return null;

    final rawCallAvailability = data[FirestorePaths.fieldCallAvailability];
    final callAvailability = rawCallAvailability is Map
        ? Map<String, dynamic>.from(rawCallAvailability)
        : const <String, dynamic>{};

    final safe = <String, dynamic>{
      FirestorePaths.fieldUid: uid,

      FirestorePaths.fieldDisplayName: _safeString(
        data[FirestorePaths.fieldDisplayName],
      ),
      FirestorePaths.fieldPhotoURL: _safeString(
        data[FirestorePaths.fieldPhotoURL],
      ),
      FirestorePaths.fieldBio: _safeString(
        data[FirestorePaths.fieldBio],
      ),
      FirestorePaths.fieldGender: _safeString(
        data[FirestorePaths.fieldGender],
      ),
      FirestorePaths.fieldCity: _safeString(
        data[FirestorePaths.fieldCity],
      ),
      FirestorePaths.fieldState: _safeString(
        data[FirestorePaths.fieldState],
      ),
      FirestorePaths.fieldCountry: _safeString(
        data[FirestorePaths.fieldCountry],
      ),
      FirestorePaths.fieldTopics: _safeStringList(
        data[FirestorePaths.fieldTopics],
      ),
      FirestorePaths.fieldLanguages: _safeStringList(
        data[FirestorePaths.fieldLanguages],
      ),
      FirestorePaths.fieldIsListener: _safeBool(
        data[FirestorePaths.fieldIsListener],
        fallback: false,
      ),
      FirestorePaths.fieldIsAvailable: _safeBool(
        data[FirestorePaths.fieldIsAvailable],
        fallback: false,
      ),
      FirestorePaths.fieldCallAvailability: {
        FirestorePaths.fieldOnlyChatMode: _safeBool(
          callAvailability[FirestorePaths.fieldOnlyChatMode],
          fallback: _safeBool(data[FirestorePaths.fieldOnlyChatMode]),
        ),
      },
      FirestorePaths.fieldIsOnCall: _safeBool(
        data[FirestorePaths.fieldIsOnCall],
        fallback: false,
      ),
      FirestorePaths.fieldAdminBlocked: _safeBool(
        data[FirestorePaths.fieldAdminBlocked],
      ),
      FirestorePaths.fieldAdminBlockReason: _safeString(
        data[FirestorePaths.fieldAdminBlockReason],
      ),
      FirestorePaths.fieldHiddenFromDiscovery: _safeBool(
        data[FirestorePaths.fieldHiddenFromDiscovery],
      ),
      FirestorePaths.fieldDiscoverable: _safeBool(
        data[FirestorePaths.fieldDiscoverable],
        fallback: _safeBool(data[FirestorePaths.fieldIsListener]),
      ),
      FirestorePaths.fieldFollowersCount: _safeInt(
        data[FirestorePaths.fieldFollowersCount],
      ),
      FirestorePaths.fieldLevel: _safeInt(
        data[FirestorePaths.fieldLevel],
        fallback: 1,
      ),
      FirestorePaths.fieldListenerRate: _safeInt(
        data[FirestorePaths.fieldListenerRate],
        fallback: 5,
      ),
      FirestorePaths.fieldRatingAvg: _safeDouble(
        data[FirestorePaths.fieldRatingAvg],
      ),
      FirestorePaths.fieldRatingCount: _safeInt(
        data[FirestorePaths.fieldRatingCount],
      ),
      FirestorePaths.fieldRatingSum: _safeInt(
        data[FirestorePaths.fieldRatingSum],
      ),
      FirestorePaths.fieldCreatedAt: data[FirestorePaths.fieldCreatedAt],
      FirestorePaths.fieldLastSeen: data[FirestorePaths.fieldLastSeen],

      // Private-only fields kept harmless/defaulted when mapping public docs.
      FirestorePaths.fieldEmail: '',
      FirestorePaths.fieldCredits: 0,
      FirestorePaths.fieldReservedCredits: 0,
      FirestorePaths.fieldEarningsCredits: 0,
      FirestorePaths.fieldPlatformRevenueCredits: 0,
      FirestorePaths.fieldFollowing: <String>[],
      FirestorePaths.fieldBlocked: <String>[],
      FirestorePaths.fieldFcmTokens: <String>[],
      FirestorePaths.fieldFavoriteListeners: <String>[],
      FirestorePaths.fieldActiveCallId: _safeString(
        data[FirestorePaths.fieldActiveCallId],
      ),
      FirestorePaths.fieldActiveCallUpdatedAt:
          data[FirestorePaths.fieldActiveCallUpdatedAt],
    };

    return safe;
  }

  AppUserModel? _safeUserFromDoc(
    DocumentSnapshot<Map<String, dynamic>> snap,
  ) {
    if (!snap.exists) return null;

    final data = snap.data();
    if (data == null) return null;

    try {
      return AppUserModel.fromMap(data);
    } catch (_) {
      return null;
    }
  }

  AppUserModel? _safePublicUserFromDoc(
    DocumentSnapshot<Map<String, dynamic>> snap,
  ) {
    if (!snap.exists) return null;

    final data = _normalizePublicUserMap(
      snap.data(),
      fallbackUid: snap.id,
    );
    if (data == null) return null;

    try {
      return AppUserModel.fromMap(data);
    } catch (_) {
      return null;
    }
  }

  AppUserModel? _safePublicUserFromMap(
    Map<String, dynamic>? data, {
    String? fallbackUid,
  }) {
    final normalized = _normalizePublicUserMap(
      data,
      fallbackUid: fallbackUid,
    );
    if (normalized == null) return null;

    try {
      return AppUserModel.fromMap(normalized);
    } catch (_) {
      return null;
    }
  }

  int _availabilityRank(AppUserModel user) {
    switch (listenerAvailabilityForUser(user).kind) {
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

  ListenerAvailabilityResult listenerAvailabilityForUser(
    AppUserModel user, {
    DateTime? now,
  }) {
    return ListenerAvailabilityResolver.resolve(
      isAvailable: user.isAvailable,
      isOnCall: user.isOnCall,
      activeCallId: user.activeCallId,
      lastSeen: user.lastSeen,
      now: now,
    );
  }

  bool _asBool(dynamic value, {bool fallback = false}) {
    if (value is bool) return value;
    return fallback;
  }

  String _asString(dynamic value, {String fallback = ''}) {
    if (value is String) return value.trim();
    return fallback;
  }

  int _profileSignalScore(AppUserModel user) {
    return user.marketplaceProfileScore;
  }

  int _compareProfileSignals(AppUserModel a, AppUserModel b) {
    final profileCompare =
        _profileSignalScore(b).compareTo(_profileSignalScore(a));
    if (profileCompare != 0) return profileCompare;

    final aHasPhoto = a.photoURL.trim().isNotEmpty;
    final bHasPhoto = b.photoURL.trim().isNotEmpty;
    if (aHasPhoto != bHasPhoto) return bHasPhoto ? 1 : -1;

    final aHasBio = a.bio.trim().isNotEmpty;
    final bHasBio = b.bio.trim().isNotEmpty;
    if (aHasBio != bHasBio) return bHasBio ? 1 : -1;

    final topicsCompare = b.topics.length.compareTo(a.topics.length);
    if (topicsCompare != 0) return topicsCompare;

    return b.languages.length.compareTo(a.languages.length);
  }

  int _marketplaceScore(AppUserModel user) {
    final hasRatingsBoost = user.ratingCount > 0 ? 1 : 0;
    final profileSignalScore = _profileSignalScore(user);
    final roundedRating = (user.ratingAvg * 100).round();
    final cheaperRateAdvantage = 1000 - user.listenerRate;

    return (2 - _availabilityRank(user)) * 100000000 +
        hasRatingsBoost * 10000000 +
        profileSignalScore * 1000000 +
        roundedRating * 10000 +
        user.ratingCount * 100 +
        user.followersCount * 10 +
        cheaperRateAdvantage;
  }

  int _compareUsersForMarketplace(AppUserModel a, AppUserModel b) {
    final aAvailabilityRank = _availabilityRank(a);
    final bAvailabilityRank = _availabilityRank(b);

    if (aAvailabilityRank != bAvailabilityRank) {
      return aAvailabilityRank.compareTo(bAvailabilityRank);
    }

    final aHasRatings = a.ratingCount > 0;
    final bHasRatings = b.ratingCount > 0;
    if (aHasRatings != bHasRatings) return aHasRatings ? -1 : 1;

    final profileCompare = _compareProfileSignals(a, b);
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

    final scoreCompare = _marketplaceScore(b).compareTo(_marketplaceScore(a));
    if (scoreCompare != 0) return scoreCompare;

    return a.safeDisplayName.toLowerCase().compareTo(
          b.safeDisplayName.toLowerCase(),
        );
  }

  Stream<User?> authStateChanges() => _auth.authStateChanges();

  Future<UserCredential> signIn({
    required String email,
    required String password,
  }) {
    return _auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
  }

  Future<UserCredential> signUp({
    required String email,
    required String password,
    String? displayName,
  }) async {
    final cred = await _auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );

    await FirestoreService.ensureProfile(
      email: email.trim(),
      displayName:
          (displayName ?? '').trim().isEmpty ? null : displayName!.trim(),
    );

    return cred;
  }

  Future<void> ensureProfile({
    required String email,
    String? displayName,
  }) {
    return FirestoreService.ensureProfile(
      email: email.trim(),
      displayName:
          displayName?.trim().isEmpty == true ? null : displayName?.trim(),
    );
  }

  Future<void> signOut() => _auth.signOut();

  Stream<AppUserModel?> watchMe() {
    final uid = myUidOrNull;
    if (uid == null) {
      return Stream<AppUserModel?>.value(null).asBroadcastStream();
    }

    return _authBoundStream<AppUserModel?,
        DocumentSnapshot<Map<String, dynamic>>>(
      uid: uid,
      source: _users.doc(uid).snapshots(),
      signedOutValue: null,
      convert: _safeUserFromDoc,
    );
  }

  Future<AppUserModel?> getMe() async {
    final uid = myUidOrNull;
    if (uid == null) return null;

    final snap = await _users.doc(uid).get();
    return _safeUserFromDoc(snap);
  }

  Stream<AppUserModel?> watchUser(String uid) {
    final safeUid = uid.trim();
    if (safeUid.isEmpty) {
      return Stream<AppUserModel?>.value(null).asBroadcastStream();
    }

    final myUid = myUidOrNull;
    if (myUid != null && myUid == safeUid) {
      return _authBoundStream<AppUserModel?,
          DocumentSnapshot<Map<String, dynamic>>>(
        uid: myUid,
        source: _users.doc(safeUid).snapshots(),
        signedOutValue: null,
        convert: _safeUserFromDoc,
      );
    }

    return _publicUsers.doc(safeUid).snapshots().map(_safePublicUserFromDoc);
  }

  Future<AppUserModel?> getUser(String uid) async {
    final safeUid = uid.trim();
    if (safeUid.isEmpty) return null;

    final myUid = myUidOrNull;
    if (myUid != null && myUid == safeUid) {
      final privateSnap = await _users.doc(safeUid).get();
      return _safeUserFromDoc(privateSnap);
    }

    final publicSnap = await _publicUsers.doc(safeUid).get();
    return _safePublicUserFromDoc(publicSnap);
  }

  Stream<List<AppUserModel>> watchAvailableListeners({int limit = 200}) {
    final safeLimit = limit < 1 ? 1 : limit;

    return _publicUsers
        .where(FirestorePaths.fieldDiscoverable, isEqualTo: true)
        .where(FirestorePaths.fieldIsListener, isEqualTo: true)
        .orderBy(FirestorePaths.fieldRatingAvg, descending: true)
        .limit(safeLimit)
        .snapshots()
        .map((query) {
      final out = <AppUserModel>[];

      for (final doc in query.docs) {
        final user = _safePublicUserFromMap(doc.data(), fallbackUid: doc.id);
        if (user == null) continue;
        out.add(user);
      }

      out.sort(_compareUsersForMarketplace);
      return out;
    });
  }

  /// Anonymized public reviews for a listener (stars + comment + date only).
  Stream<List<Map<String, dynamic>>> watchListenerReviews(
    String listenerId, {
    int limit = 20,
  }) {
    final safeId = listenerId.trim();
    if (safeId.isEmpty) {
      return Stream<List<Map<String, dynamic>>>.value(
        const <Map<String, dynamic>>[],
      );
    }

    return _publicUsers
        .doc(safeId)
        .collection('reviews')
        .orderBy('createdAtMs', descending: true)
        .limit(limit < 1 ? 1 : limit)
        .snapshots()
        .map((query) => query.docs.map((d) => d.data()).toList());
  }

  Stream<List<Map<String, dynamic>>> watchListenerChatRequests({
    int limit = 100,
  }) {
    final uid = myUidOrNull;
    if (uid == null) {
      return Stream<List<Map<String, dynamic>>>.value(
        const <Map<String, dynamic>>[],
      ).asBroadcastStream();
    }

    final safeLimit = limit < 1 ? 1 : limit;

    final source = _chatSessions
        .where(FirestorePaths.fieldParticipantIds, arrayContains: uid)
        .where(FirestorePaths.fieldPendingFor, isEqualTo: uid)
        .where(FirestorePaths.fieldCallRequestOpen, isEqualTo: true)
        .orderBy(FirestorePaths.fieldChatUpdatedAtMs, descending: true)
        .limit(safeLimit)
        .snapshots();

    return _authBoundStream<List<Map<String, dynamic>>,
        QuerySnapshot<Map<String, dynamic>>>(
      uid: uid,
      source: source,
      signedOutValue: const <Map<String, dynamic>>[],
      convert: (query) {
        final out = <Map<String, dynamic>>[];

        for (final doc in query.docs) {
          final data = doc.data();
          out.add({
            'id': doc.id,
            ...data,
          });
        }

        return out;
      },
    );
  }

  Future<List<Map<String, dynamic>>> getListenerChatRequests({
    int limit = 100,
  }) async {
    final uid = myUidOrNull;
    if (uid == null) return const <Map<String, dynamic>>[];

    final safeLimit = limit < 1 ? 1 : limit;

    final query = await _chatSessions
        .where(FirestorePaths.fieldParticipantIds, arrayContains: uid)
        .where(FirestorePaths.fieldPendingFor, isEqualTo: uid)
        .where(FirestorePaths.fieldCallRequestOpen, isEqualTo: true)
        .orderBy(FirestorePaths.fieldChatUpdatedAtMs, descending: true)
        .limit(safeLimit)
        .get();

    return query.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList();
  }

  Future<bool> didListenerAllowCall({
    required String speakerId,
    required String listenerId,
  }) async {
    final safeSpeakerId = speakerId.trim();
    final safeListenerId = listenerId.trim();

    if (safeSpeakerId.isEmpty || safeListenerId.isEmpty) return false;

    final ids = <String>[safeSpeakerId, safeListenerId]..sort();
    final snap = await _chatSessions.doc('${ids[0]}_${ids[1]}').get();

    if (!snap.exists) return false;

    final data = snap.data() ?? <String, dynamic>{};
    final status = _asString(data[FirestorePaths.fieldChatStatus]);
    final callAllowed = _asBool(data[FirestorePaths.fieldCallAllowed]);
    final listenerBlocked = _asBool(data[FirestorePaths.fieldListenerBlocked]);
    final speakerBlocked = _asBool(data[FirestorePaths.fieldSpeakerBlocked]);

    if (listenerBlocked || speakerBlocked) return false;
    if (status != FirestorePaths.chatStatusAccepted &&
        status != FirestorePaths.chatStatusActive) {
      return false;
    }

    return callAllowed;
  }

  List<AppUserModel> sortListenersForMarketplace(
    List<AppUserModel> listeners,
  ) {
    final out = [...listeners];
    out.sort(_compareUsersForMarketplace);
    return out;
  }

  List<AppUserModel> topRatedListeners(
    List<AppUserModel> listeners, {
    int limit = 10,
  }) {
    final out = List<AppUserModel>.from(listeners)
      ..sort((a, b) {
        final availabilityCompare =
            _availabilityRank(a).compareTo(_availabilityRank(b));
        if (availabilityCompare != 0) return availabilityCompare;

        final profileCompare = _compareProfileSignals(a, b);
        if (profileCompare != 0) return profileCompare;

        final ratingCompare = b.ratingAvg.compareTo(a.ratingAvg);
        if (ratingCompare != 0) return ratingCompare;

        final countCompare = b.ratingCount.compareTo(a.ratingCount);
        if (countCompare != 0) return countCompare;

        final followersCompare = b.followersCount.compareTo(a.followersCount);
        if (followersCompare != 0) return followersCompare;

        return a.listenerRate.compareTo(b.listenerRate);
      });

    if (out.length <= limit) return out;
    return out.take(limit).toList();
  }

  List<AppUserModel> risingListeners(
    List<AppUserModel> listeners, {
    int limit = 10,
  }) {
    final out = List<AppUserModel>.from(listeners)
      ..sort((a, b) {
        final availabilityCompare =
            _availabilityRank(a).compareTo(_availabilityRank(b));
        if (availabilityCompare != 0) return availabilityCompare;

        final profileCompare = _compareProfileSignals(a, b);
        if (profileCompare != 0) return profileCompare;

        final countCompare = b.ratingCount.compareTo(a.ratingCount);
        if (countCompare != 0) return countCompare;

        final followersCompare = b.followersCount.compareTo(a.followersCount);
        if (followersCompare != 0) return followersCompare;

        final ratingCompare = b.ratingAvg.compareTo(a.ratingAvg);
        if (ratingCompare != 0) return ratingCompare;

        return a.listenerRate.compareTo(b.listenerRate);
      });

    if (out.length <= limit) return out;
    return out.take(limit).toList();
  }

  List<AppUserModel> affordableListeners(
    List<AppUserModel> listeners, {
    int limit = 10,
  }) {
    final out = List<AppUserModel>.from(listeners)
      ..sort((a, b) {
        final availabilityCompare =
            _availabilityRank(a).compareTo(_availabilityRank(b));
        if (availabilityCompare != 0) return availabilityCompare;

        final rateCompare = a.listenerRate.compareTo(b.listenerRate);
        if (rateCompare != 0) return rateCompare;

        final profileCompare = _compareProfileSignals(a, b);
        if (profileCompare != 0) return profileCompare;

        final ratingCompare = b.ratingAvg.compareTo(a.ratingAvg);
        if (ratingCompare != 0) return ratingCompare;

        final countCompare = b.ratingCount.compareTo(a.ratingCount);
        if (countCompare != 0) return countCompare;

        return b.followersCount.compareTo(a.followersCount);
      });

    if (out.length <= limit) return out;
    return out.take(limit).toList();
  }

  int usableCreditsFromUser(AppUserModel user) {
    final usable = user.credits - user.reservedCredits;
    return usable < 0 ? 0 : usable;
  }

  bool isFavoriteListener({
    required AppUserModel me,
    required String listenerId,
  }) {
    final safeListenerId = listenerId.trim();
    if (safeListenerId.isEmpty) return false;
    return me.favoriteListeners.contains(safeListenerId);
  }

  int levelFromFollowers(int followers) {
    return FirestoreService.levelFromFollowers(followers);
  }

  List<int> allowedRatesForFollowers(int followers) {
    return FirestoreService.allowedRatesForFollowers(followers);
  }

  int listenerPayoutFromVisibleRate(int visibleRate) {
    return FirestoreService.listenerPayoutFromVisibleRate(visibleRate);
  }

  Future<void> setDisplayName(String value) {
    final safe = value.trim();
    if (safe.isEmpty) return Future.value();
    return FirestoreService.setDisplayName(safe);
  }

  Future<void> setPhotoUrl(String value) {
    return FirestoreService.setPhotoUrl(value.trim());
  }

  Future<void> updateProfile({
    required String displayName,
    required String bio,
    required List<String> topics,
    required List<String> languages,
    String gender = '',
    String city = '',
    String state = '',
    String country = '',
  }) {
    return FirestoreService.updateProfile(
      displayName: displayName.trim(),
      bio: bio.trim(),
      gender: gender.trim(),
      city: city.trim(),
      state: state.trim(),
      country: country.trim(),
      topics: _safeStringList(topics),
      languages: _safeStringList(languages),
    );
  }

  Future<void> setListenerMode(bool enabled) {
    return FirestoreService.setListenerMode(enabled);
  }

  Future<void> setAvailability(bool available) {
    return FirestoreService.setAvailability(available);
  }

  Future<void> setOnlyChatMode(bool enabled) {
    return FirestoreService.setOnlyChatMode(enabled);
  }

  Future<void> setListenerRate(int value) {
    return FirestoreService.setListenerRate(value);
  }

  Future<void> followUser(String userId) {
    final safeUserId = userId.trim();
    if (safeUserId.isEmpty || safeUserId == myUidOrNull) {
      return Future.value();
    }
    return FirestoreService.followUser(safeUserId);
  }

  Future<void> unfollowUser(String userId) {
    final safeUserId = userId.trim();
    if (safeUserId.isEmpty || safeUserId == myUidOrNull) {
      return Future.value();
    }
    return FirestoreService.unfollowUser(safeUserId);
  }

  Future<void> toggleFavoriteListener({
    required String listenerId,
    required bool isFavoriteNow,
  }) {
    final safeListenerId = listenerId.trim();
    if (safeListenerId.isEmpty || safeListenerId == myUidOrNull) {
      return Future.value();
    }

    if (isFavoriteNow) {
      return FirestoreService.removeFavoriteListener(safeListenerId);
    }
    return FirestoreService.addFavoriteListener(safeListenerId);
  }

  Future<void> blockUser(String userId) {
    final safeUserId = userId.trim();
    if (safeUserId.isEmpty || safeUserId == myUidOrNull) {
      return Future.value();
    }
    return FirestoreService.blockUser(safeUserId);
  }

  Future<void> unblockUser(String userId) {
    final safeUserId = userId.trim();
    if (safeUserId.isEmpty || safeUserId == myUidOrNull) {
      return Future.value();
    }
    return FirestoreService.unblockUser(safeUserId);
  }

  Future<int> getUsableCreditsNow() async {
    final me = await getMe();
    if (me == null) return 0;
    return usableCreditsFromUser(me);
  }

  Future<bool> hasActiveCallNow() async {
    final me = await getMe();
    if (me == null) return false;
    return me.isOnCall || me.hasCallReference;
  }

  Future<bool> canCallListenerNow({
    required String listenerId,
    required int requiredCredits,
  }) async {
    final me = await getMe();
    if (me == null) return false;

    final safeListenerId = listenerId.trim();
    if (safeListenerId.isEmpty) return false;
    if (me.uid == safeListenerId) return false;
    if (me.isOnCall) return false;
    if (usableCreditsFromUser(me) < requiredCredits) return false;
    if (me.blocked.contains(safeListenerId)) return false;

    final listener = await getUser(safeListenerId);
    if (listener == null) return false;
    final availability = listenerAvailabilityForUser(listener);
    if (!availability.canCallNow) return false;

    return true;
  }
}
