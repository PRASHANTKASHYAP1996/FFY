import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../core/constants/firestore_paths.dart';

class FirestoreService {
  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static final CollectionReference<Map<String, dynamic>> users =
      _db.collection(FirestorePaths.users);
  static final CollectionReference<Map<String, dynamic>> calls =
      _db.collection(FirestorePaths.calls);
  static final CollectionReference<Map<String, dynamic>> reports =
      _db.collection(FirestorePaths.reports);
  static final CollectionReference<Map<String, dynamic>> reviews =
      _db.collection(FirestorePaths.reviews);

  static final CollectionReference<Map<String, dynamic>> walletTransactions =
      _db.collection(FirestorePaths.walletTransactions);
  static final CollectionReference<Map<String, dynamic>> withdrawalRequests =
      _db.collection(FirestorePaths.withdrawalRequests);
  static final CollectionReference<Map<String, dynamic>> paymentOrders =
      _db.collection(FirestorePaths.paymentOrders);

  static const List<int> rateOptions = <int>[5, 10, 20, 50, 100];
  static const int platformPercent = 20;

  static const int ringingTimeoutSeconds = 45;
  static const int acceptedStaleTimeoutMinutes = 5;
  static const int defaultStartingCredits = 500;

  static const int _cleanupPageSize = 20;
  static const Duration _cleanupMyStaleCallsThrottle = Duration(seconds: 12);

  static Future<void>? _cleanupMyStaleCallsInFlight;
  static DateTime? _lastCleanupMyStaleCallsAt;

  static String uid() {
    final current = FirebaseAuth.instance.currentUser;
    if (current == null) {
      throw StateError('No authenticated user is available.');
    }
    return current.uid;
  }

  static String? safeUidOrNull() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;

    final value = user.uid.trim();
    if (value.isEmpty) return null;

    return value;
  }

  static DocumentReference<Map<String, dynamic>> meRef() => users.doc(uid());

  static DocumentReference<Map<String, dynamic>>? safeMeRefOrNull() {
    final safeUid = safeUidOrNull();
    if (safeUid == null) return null;
    return users.doc(safeUid);
  }

  static FirebaseFunctions fn() =>
      FirebaseFunctions.instanceFor(region: 'us-central1');

  static int _asInt(dynamic value, {int fallback = 0}) {
    if (value is int) return value;
    if (value is num) return value.floor();
    return fallback;
  }

  static String _asString(dynamic value, {String fallback = ''}) {
    if (value is String) return value.trim();
    if (value == null) return fallback;
    return value.toString().trim();
  }

  static int _timestampMs(dynamic value) {
    if (value is Timestamp) {
      return value.toDate().millisecondsSinceEpoch;
    }
    if (value is DateTime) {
      return value.millisecondsSinceEpoch;
    }
    return 0;
  }

  static int _safeNonNegativeSeconds(int value) {
    if (value <= 0) return 0;
    return value;
  }

  static List<String> _sanitizeStringList(List<String> items) {
    final seen = <String>{};
    final out = <String>[];

    for (final item in items) {
      final safe = item.trim();
      if (safe.isEmpty) continue;

      final key = safe.toLowerCase();
      if (seen.contains(key)) continue;

      seen.add(key);
      out.add(safe);
    }

    return out;
  }

  static bool _isFinalCallStatus(String status) {
    return status == FirestorePaths.statusEnded ||
        status == FirestorePaths.statusRejected;
  }

  static bool _isLiveCallStatus(String status) {
    return status == FirestorePaths.statusRinging ||
        status == FirestorePaths.statusAccepted;
  }

  static int _callCreatedAtMs(Map<String, dynamic> data) {
    final createdAtMs = _asInt(data[FirestorePaths.fieldCreatedAtMs]);
    if (createdAtMs > 0) return createdAtMs;
    return _timestampMs(data[FirestorePaths.fieldCreatedAt]);
  }

  static int _callStartedAtMs(Map<String, dynamic> data) {
    return _timestampMs(data[FirestorePaths.fieldStartedAt]);
  }

  static bool _isExpiredRingingCall(Map<String, dynamic> data) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final expiresAtMs = _asInt(data[FirestorePaths.fieldExpiresAtMs]);
    final createdAtMs = _callCreatedAtMs(data);

    if (expiresAtMs > 0 && nowMs > expiresAtMs) return true;

    if (createdAtMs > 0 &&
        nowMs - createdAtMs > ringingTimeoutSeconds * 1000) {
      return true;
    }

    return false;
  }

  static bool _isAcceptedCallMissingStartTooLong(Map<String, dynamic> data) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final startedAtMs = _callStartedAtMs(data);
    if (startedAtMs > 0) {
      return false;
    }

    final createdAtMs = _callCreatedAtMs(data);
    if (createdAtMs <= 0) return false;

    const int maxAgeMs = acceptedStaleTimeoutMinutes * 60 * 1000;
    return nowMs - createdAtMs > maxAgeMs;
  }

  static Future<DocumentSnapshot<Map<String, dynamic>>> _loadCall(
    DocumentReference<Map<String, dynamic>> callRef,
  ) {
    return callRef.get();
  }

  static bool _isParticipantOfCall(
    Map<String, dynamic> call,
    String userId,
  ) {
    final callerId = _asString(call[FirestorePaths.fieldCallerId]);
    final calleeId = _asString(call[FirestorePaths.fieldCalleeId]);
    return callerId == userId || calleeId == userId;
  }

  static Future<void> _touchMe({
    Map<String, dynamic> extra = const <String, dynamic>{},
  }) async {
    final ref = safeMeRefOrNull();
    if (ref == null) return;

    await ref.set({
      ...extra,
      FirestorePaths.fieldLastSeen: FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static int levelFromFollowers(int followers) {
    if (followers >= 100000) return 5;
    if (followers >= 10000) return 4;
    if (followers >= 1000) return 3;
    if (followers >= 100) return 2;
    return 1;
  }

  static int maxVisibleRateForLevel(int level) {
    switch (level) {
      case 5:
        return 100;
      case 4:
        return 50;
      case 3:
        return 20;
      case 2:
        return 10;
      default:
        return 5;
    }
  }

  static List<int> allowedRatesForFollowers(int followers) {
    final level = levelFromFollowers(followers);
    final maxRate = maxVisibleRateForLevel(level);
    return rateOptions.where((rate) => rate <= maxRate).toList();
  }

  static int listenerPayoutFromVisibleRate(int visibleRate) {
    final payout = (visibleRate * (100 - platformPercent)) / 100.0;
    return payout.floor();
  }

  static Future<void> ensureProfile({
    required String email,
    String? displayName,
  }) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      throw StateError('Cannot ensure profile without an authenticated user.');
    }

    final safeEmail = email.trim();
    final requestedName = (displayName ?? '').trim();
    final safeName =
        requestedName.isNotEmpty ? requestedName : safeEmail.split('@').first;

    final ref = users.doc(currentUser.uid);
    final snap = await ref.get();

    if (!snap.exists) {
      const int defaultFollowers = 0;
      const int defaultRate = 5;

      await ref.set({
        FirestorePaths.fieldUid: currentUser.uid,
        FirestorePaths.fieldEmail: safeEmail,
        FirestorePaths.fieldDisplayName: safeName,
        FirestorePaths.fieldCredits: defaultStartingCredits,
        FirestorePaths.fieldReservedCredits: 0,
        FirestorePaths.fieldEarningsCredits: 0,
        FirestorePaths.fieldPlatformRevenueCredits: 0,
        FirestorePaths.fieldPhotoURL: '',
        FirestorePaths.fieldBio: '',
        FirestorePaths.fieldTopics: <String>[],
        FirestorePaths.fieldLanguages: <String>[],
        FirestorePaths.fieldGender: '',
        FirestorePaths.fieldCity: '',
        FirestorePaths.fieldState: '',
        FirestorePaths.fieldCountry: '',
        FirestorePaths.fieldIsListener: true,
        FirestorePaths.fieldIsAvailable: true,
        FirestorePaths.fieldFollowersCount: defaultFollowers,
        FirestorePaths.fieldLevel: levelFromFollowers(defaultFollowers),
        FirestorePaths.fieldListenerRate: defaultRate,
        FirestorePaths.fieldFollowing: <String>[],
        FirestorePaths.fieldBlocked: <String>[],
        FirestorePaths.fieldFcmTokens: <String>[],
        FirestorePaths.fieldFavoriteListeners: <String>[],
        FirestorePaths.fieldActiveCallId: '',
        FirestorePaths.fieldRatingAvg: 0.0,
        FirestorePaths.fieldRatingCount: 0,
        FirestorePaths.fieldRatingSum: 0,
        FirestorePaths.fieldCreatedAt: FieldValue.serverTimestamp(),
        FirestorePaths.fieldLastSeen: FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      return;
    }

    final data = snap.data() ?? <String, dynamic>{};
    final patch = <String, dynamic>{
      FirestorePaths.fieldLastSeen: FieldValue.serverTimestamp(),
    };

    final existingDisplayName = _asString(data[FirestorePaths.fieldDisplayName]);
    if (existingDisplayName.isEmpty && safeName.isNotEmpty) {
      patch[FirestorePaths.fieldDisplayName] = safeName;
    }

    if (data[FirestorePaths.fieldFavoriteListeners] is! List) {
      patch[FirestorePaths.fieldFavoriteListeners] = <String>[];
    }

    if (data[FirestorePaths.fieldFollowing] is! List) {
      patch[FirestorePaths.fieldFollowing] = <String>[];
    }

    if (data[FirestorePaths.fieldBlocked] is! List) {
      patch[FirestorePaths.fieldBlocked] = <String>[];
    }

    if (data[FirestorePaths.fieldFcmTokens] is! List) {
      patch[FirestorePaths.fieldFcmTokens] = <String>[];
    }

    if (_asString(data[FirestorePaths.fieldGender]).isEmpty) {
      patch[FirestorePaths.fieldGender] = '';
    }
    if (_asString(data[FirestorePaths.fieldCity]).isEmpty) {
      patch[FirestorePaths.fieldCity] = '';
    }
    if (_asString(data[FirestorePaths.fieldState]).isEmpty) {
      patch[FirestorePaths.fieldState] = '';
    }
    if (_asString(data[FirestorePaths.fieldCountry]).isEmpty) {
      patch[FirestorePaths.fieldCountry] = '';
    }

    await ref.set(patch, SetOptions(merge: true));
  }

  static Future<void> addMyFcmToken(String token) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final uid = user.uid.trim();
    final safeToken = token.trim();

    if (uid.isEmpty || safeToken.isEmpty) return;

    await users.doc(uid).set({
      FirestorePaths.fieldFcmTokens: FieldValue.arrayUnion([safeToken]),
      FirestorePaths.fieldLastSeen: FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static Future<void> removeMyFcmToken(String token) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final uid = user.uid.trim();
    final safeToken = token.trim();

    if (uid.isEmpty || safeToken.isEmpty) return;

    await users.doc(uid).set({
      FirestorePaths.fieldFcmTokens: FieldValue.arrayRemove([safeToken]),
      FirestorePaths.fieldLastSeen: FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static Future<void> setDisplayName(String value) async {
    final safeValue = value.trim();
    if (safeValue.isEmpty) return;

    await _touchMe(extra: {
      FirestorePaths.fieldDisplayName: safeValue,
    });
  }

  static Future<void> setPhotoUrl(String value) async {
    await _touchMe(extra: {
      FirestorePaths.fieldPhotoURL: value.trim(),
    });
  }

  static Future<void> setListenerMode(bool enabled) async {
    final ref = safeMeRefOrNull();
    if (ref == null) return;

    await ref.set({
      FirestorePaths.fieldIsListener: enabled,
      FirestorePaths.fieldIsAvailable: enabled,
      FirestorePaths.fieldLastSeen: FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static Future<void> setAvailability(bool available) async {
    final ref = safeMeRefOrNull();
    if (ref == null) return;

    await ref.set({
      FirestorePaths.fieldIsAvailable: available,
      FirestorePaths.fieldLastSeen: FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static Future<void> setListenerRate(int visibleRate) async {
    final ref = safeMeRefOrNull();
    if (ref == null) return;

    final snap = await ref.get();
    final data = snap.data() ?? <String, dynamic>{};

    final followers = _asInt(data[FirestorePaths.fieldFollowersCount]);
    final allowedRates = allowedRatesForFollowers(followers);

    if (!allowedRates.contains(visibleRate)) {
      throw StateError('Selected rate is not allowed for current level.');
    }

    await ref.set({
      FirestorePaths.fieldListenerRate: visibleRate,
      FirestorePaths.fieldLastSeen: FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static Future<void> followUser(String userId) async {
    final myUid = safeUidOrNull();
    if (myUid == null) return;

    final safeUserId = userId.trim();
    if (safeUserId.isEmpty || safeUserId == myUid) return;

    await _touchMe(extra: {
      FirestorePaths.fieldFollowing: FieldValue.arrayUnion([safeUserId]),
    });
  }

  static Future<void> unfollowUser(String userId) async {
    final myUid = safeUidOrNull();
    if (myUid == null) return;

    final safeUserId = userId.trim();
    if (safeUserId.isEmpty || safeUserId == myUid) return;

    await _touchMe(extra: {
      FirestorePaths.fieldFollowing: FieldValue.arrayRemove([safeUserId]),
    });
  }

  static Future<void> addFavoriteListener(String listenerId) async {
    final myUid = safeUidOrNull();
    if (myUid == null) return;

    final safeListenerId = listenerId.trim();
    if (safeListenerId.isEmpty || safeListenerId == myUid) return;

    await _touchMe(extra: {
      FirestorePaths.fieldFavoriteListeners: FieldValue.arrayUnion([
        safeListenerId,
      ]),
    });
  }

  static Future<void> removeFavoriteListener(String listenerId) async {
    final myUid = safeUidOrNull();
    if (myUid == null) return;

    final safeListenerId = listenerId.trim();
    if (safeListenerId.isEmpty || safeListenerId == myUid) return;

    await _touchMe(extra: {
      FirestorePaths.fieldFavoriteListeners: FieldValue.arrayRemove([
        safeListenerId,
      ]),
    });
  }

  static Future<void> updateProfile({
    required String displayName,
    required String bio,
    required List<String> topics,
    required List<String> languages,
    String? gender,
    String? city,
    String? state,
    String? country,
  }) async {
    final safeName = displayName.trim();
    final safeBio = bio.trim();

    await _touchMe(extra: {
      FirestorePaths.fieldDisplayName: safeName,
      FirestorePaths.fieldBio: safeBio,
      FirestorePaths.fieldTopics: _sanitizeStringList(topics),
      FirestorePaths.fieldLanguages: _sanitizeStringList(languages),
      FirestorePaths.fieldGender: (gender ?? '').trim(),
      FirestorePaths.fieldCity: (city ?? '').trim(),
      FirestorePaths.fieldState: (state ?? '').trim(),
      FirestorePaths.fieldCountry: (country ?? '').trim(),
    });
  }

  static Future<void> clearMyActiveCallFlagIfOrphaned() async {
    debugPrint(
      'clearMyActiveCallFlagIfOrphaned skipped: activeCallId authority is server-owned.',
    );
  }

  static Future<DocumentReference<Map<String, dynamic>>?> createCallToListener({
    required String listenerId,
  }) async {
    final myUid = safeUidOrNull();
    if (myUid == null) return null;

    final safeListenerId = listenerId.trim();
    if (safeListenerId.isEmpty || safeListenerId == myUid) return null;

    try {
      await cleanupMyStaleCalls();

      final result = await fn()
          .httpsCallable('startCall_v2')
          .call(<String, dynamic>{'listenerId': safeListenerId});

      final data = result.data;
      if (data is! Map) {
        debugPrint('startCall_v2 invalid response: $data');
        throw StateError('startCall_v2 returned invalid response.');
      }

      final rawCallId = data[FirestorePaths.fieldCallId];
      final callId = rawCallId is String ? rawCallId.trim() : '';
      if (callId.isEmpty) {
        debugPrint('startCall_v2 returned empty callId');
        throw StateError('startCall_v2 returned empty callId.');
      }

      return calls.doc(callId);
    } on FirebaseFunctionsException catch (e) {
      debugPrint(
        'startCall_v2 failed: '
        'code=${e.code} message=${e.message} details=${e.details}',
      );
      rethrow;
    } catch (e) {
      debugPrint('startCall_v2 failed: $e');
      rethrow;
    }
  }

  static Future<void> rejectCall(
    DocumentReference<Map<String, dynamic>> callRef, {
    String? rejectedReason,
  }) async {
    final myUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    if (myUid.isEmpty) return;

    final snap = await _loadCall(callRef);
    if (!snap.exists) return;

    final data = snap.data() ?? <String, dynamic>{};
    final status = _asString(data[FirestorePaths.fieldStatus]);

    if (_isFinalCallStatus(status)) return;
    if (status != FirestorePaths.statusRinging) return;
    if (!_isParticipantOfCall(data, myUid)) return;

    final safeReason = (rejectedReason ?? '').trim();

    await fn().httpsCallable('rejectIncomingCall_v1').call({
      'callId': callRef.id,
      'rejectedReason': safeReason,
    });
  }

  static Future<void> cancelOutgoingCall({
    required DocumentReference<Map<String, dynamic>> callRef,
    required String reason,
  }) async {
    final safeUid = safeUidOrNull();
    if (safeUid == null) return;

    final snap = await _loadCall(callRef);
    if (!snap.exists) return;

    final call = snap.data() ?? <String, dynamic>{};
    final status = _asString(call[FirestorePaths.fieldStatus]);
    final callerId = _asString(call[FirestorePaths.fieldCallerId]);

    if (_isFinalCallStatus(status)) return;
    if (status != FirestorePaths.statusRinging) return;
    if (callerId != safeUid) return;

    final safeReason = reason.trim();

    await fn().httpsCallable('cancelOutgoingCall_v1').call({
      'callId': callRef.id,
      'reason': safeReason,
    });
  }

  static Future<void> acceptCall(
    DocumentReference<Map<String, dynamic>> callRef,
  ) async {
    final myUid = safeUidOrNull();
    if (myUid == null) return;

    final snap = await _loadCall(callRef);
    if (!snap.exists) return;

    final call = snap.data() ?? <String, dynamic>{};
    final calleeId = _asString(call[FirestorePaths.fieldCalleeId]);
    final status = _asString(call[FirestorePaths.fieldStatus]);

    if (_isFinalCallStatus(status)) return;
    if (calleeId != myUid) return;
    if (status != FirestorePaths.statusRinging) return;

    if (_isExpiredRingingCall(call)) {
      await rejectCall(
        callRef,
        rejectedReason: FirestorePaths.reasonTimeout,
      );
      return;
    }

    await fn().httpsCallable('acceptIncomingCall_v1').call({
      'callId': callRef.id,
    });
  }

  static Future<void> endCallWithBilling({
    required DocumentReference<Map<String, dynamic>> callRef,
    required int seconds,
    String? reason,
  }) async {
    final safeUid = safeUidOrNull();
    if (safeUid == null) return;

    final snap = await _loadCall(callRef);
    if (!snap.exists) return;

    final call = snap.data() ?? <String, dynamic>{};
    final status = _asString(call[FirestorePaths.fieldStatus]);

    if (_isFinalCallStatus(status)) return;
    if (status != FirestorePaths.statusAccepted) return;
    if (!_isParticipantOfCall(call, safeUid)) return;

    final safeReason = (reason ?? '').trim();

    await fn().httpsCallable('endCallAuthoritative_v1').call({
      'callId': callRef.id,
      'reason': safeReason,
      'endedSeconds': _safeNonNegativeSeconds(seconds),
    });
  }

  static Future<void> endCallNoCharge({
    required DocumentReference<Map<String, dynamic>> callRef,
    required String reason,
  }) async {
    final snap = await _loadCall(callRef);
    if (!snap.exists) return;

    final call = snap.data() ?? <String, dynamic>{};
    final status = _asString(call[FirestorePaths.fieldStatus]);

    if (_isFinalCallStatus(status)) return;

    final currentUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    if (currentUid.isEmpty) return;
    if (!_isParticipantOfCall(call, currentUid)) {
      return;
    }

    if (status != FirestorePaths.statusAccepted &&
        status != FirestorePaths.statusRinging) {
      return;
    }

    final safeReason = reason.trim();

    if (status == FirestorePaths.statusRinging) {
      final callerId = _asString(call[FirestorePaths.fieldCallerId]);
      if (callerId == currentUid) {
        await fn().httpsCallable('cancelOutgoingCall_v1').call({
          'callId': callRef.id,
          'reason': safeReason,
        });
      } else {
        await fn().httpsCallable('rejectIncomingCall_v1').call({
          'callId': callRef.id,
          'rejectedReason': safeReason,
        });
      }
      return;
    }

    await fn().httpsCallable('endCallAuthoritative_v1').call({
      'callId': callRef.id,
      'reason': safeReason,
      'endedSeconds': 0,
    });
  }

  static Future<void> claimMyListenerPayouts() async {
    debugPrint(
      'claimMyListenerPayouts skipped: payout authority is server-owned.',
    );
  }

  static Future<bool> submitReviewCreateOnly({
    required String callId,
    required String reviewedUserId,
    required int stars,
    required String text,
  }) async {
    final reviewerId = safeUidOrNull();
    if (reviewerId == null) return false;

    final safeCallId = callId.trim();
    final safeReviewedUserId = reviewedUserId.trim();
    final safeStars = stars.clamp(1, 5);
    final safeText = text.trim();

    if (safeCallId.isEmpty) return false;
    if (safeReviewedUserId.isEmpty) return false;
    if (safeReviewedUserId == reviewerId) return false;

    final callSnap = await calls.doc(safeCallId).get();
    if (!callSnap.exists) return false;

    final call = callSnap.data() ?? <String, dynamic>{};
    final status = _asString(call[FirestorePaths.fieldStatus]);
    if (status != FirestorePaths.statusEnded) return false;
    if (!_isParticipantOfCall(call, reviewerId)) return false;

    final callerId = _asString(call[FirestorePaths.fieldCallerId]);
    final calleeId = _asString(call[FirestorePaths.fieldCalleeId]);
    final expectedReviewedUserId =
        callerId == reviewerId ? calleeId : callerId;

    if (expectedReviewedUserId.isEmpty) return false;
    if (expectedReviewedUserId != safeReviewedUserId) return false;

    final docId = '${safeCallId}_$reviewerId';
    final ref = reviews.doc(docId);

    return _db.runTransaction<bool>((tx) async {
      final existing = await tx.get(ref);
      if (existing.exists) return false;

      tx.set(ref, {
        FirestorePaths.fieldCallId: safeCallId,
        FirestorePaths.fieldReviewerId: reviewerId,
        FirestorePaths.fieldReviewedUserId: safeReviewedUserId,
        FirestorePaths.fieldStars: safeStars,
        FirestorePaths.fieldComment: safeText,
        FirestorePaths.fieldCreatedAt: FieldValue.serverTimestamp(),
      });

      return true;
    });
  }

  static Future<void> _cleanupLiveCallsForRole({
    required String field,
    required String myUid,
  }) async {
    Query<Map<String, dynamic>> query = calls
        .where(field, isEqualTo: myUid)
        .orderBy(FirestorePaths.fieldCreatedAtMs, descending: true)
        .limit(_cleanupPageSize);

    final snap = await query.get();
    if (snap.docs.isEmpty) return;

    for (final doc in snap.docs) {
      final data = doc.data();
      final status = _asString(data[FirestorePaths.fieldStatus]);

      if (!_isLiveCallStatus(status)) continue;

      final callerId = _asString(data[FirestorePaths.fieldCallerId]);
      final calleeId = _asString(data[FirestorePaths.fieldCalleeId]);

      if (status == FirestorePaths.statusRinging) {
        if (!_isExpiredRingingCall(data)) continue;

        try {
          if (calleeId == myUid) {
            await rejectCall(
              doc.reference,
              rejectedReason: FirestorePaths.reasonTimeout,
            );
          } else if (callerId == myUid) {
            await cancelOutgoingCall(
              callRef: doc.reference,
              reason: FirestorePaths.reasonCallerTimeoutCleanup,
            );
          }
        } catch (_) {
          // ignore cleanup failure
        }
        continue;
      }

      if (status == FirestorePaths.statusAccepted &&
          _isAcceptedCallMissingStartTooLong(data)) {
        try {
          await endCallNoCharge(
            callRef: doc.reference,
            reason: FirestorePaths.reasonStaleTimeout,
          );
        } catch (_) {
          // ignore cleanup failure
        }
      }
    }
  }

  static bool _cleanupThrottleWindowActive() {
    final lastAt = _lastCleanupMyStaleCallsAt;
    if (lastAt == null) return false;
    return DateTime.now().difference(lastAt) < _cleanupMyStaleCallsThrottle;
  }

  static Future<void> cleanupMyStaleCalls() async {
    final myUid = safeUidOrNull();
    if (myUid == null) return;

    final inFlight = _cleanupMyStaleCallsInFlight;
    if (inFlight != null) {
      return inFlight;
    }

    if (_cleanupThrottleWindowActive()) {
      return;
    }

    final future = () async {
      try {
        try {
          await _cleanupLiveCallsForRole(
            field: FirestorePaths.fieldCallerId,
            myUid: myUid,
          );
        } catch (_) {
          // ignore caller cleanup failure
        }

        try {
          await _cleanupLiveCallsForRole(
            field: FirestorePaths.fieldCalleeId,
            myUid: myUid,
          );
        } catch (_) {
          // ignore callee cleanup failure
        }

        _lastCleanupMyStaleCallsAt = DateTime.now();
      } finally {
        _cleanupMyStaleCallsInFlight = null;
      }
    }();

    _cleanupMyStaleCallsInFlight = future;
    return future;
  }

  static Future<void> report({
    required String reportedUserId,
    required String callId,
    required String reason,
  }) async {
    final safeReporterId = safeUidOrNull();
    if (safeReporterId == null) return;

    final safeReportedUserId = reportedUserId.trim();
    final safeCallId = callId.trim();
    final safeReason = reason.trim();

    if (safeReportedUserId.isEmpty ||
        safeCallId.isEmpty ||
        safeReason.isEmpty) {
      return;
    }

    if (safeReportedUserId == safeReporterId) return;

    await reports.add({
      FirestorePaths.fieldReporterId: safeReporterId,
      'reportedUserId': safeReportedUserId,
      FirestorePaths.fieldCallId: safeCallId,
      FirestorePaths.fieldReason: safeReason,
      FirestorePaths.fieldCreatedAt: FieldValue.serverTimestamp(),
    });
  }

  static Future<void> blockUser(String userId) async {
    final safeUid = safeUidOrNull();
    if (safeUid == null) return;

    final safeUserId = userId.trim();
    if (safeUserId.isEmpty || safeUserId == safeUid) return;

    await _touchMe(extra: {
      FirestorePaths.fieldBlocked: FieldValue.arrayUnion([safeUserId]),
    });
  }

  static Future<void> unblockUser(String userId) async {
    final safeUid = safeUidOrNull();
    if (safeUid == null) return;

    final safeUserId = userId.trim();
    if (safeUserId.isEmpty || safeUserId == safeUid) return;

    await _touchMe(extra: {
      FirestorePaths.fieldBlocked: FieldValue.arrayRemove([safeUserId]),
    });
  }

  static Future<void> addWalletTransaction({
    required String userId,
    required String type,
    required int amount,
    required int balanceAfter,
    required String direction,
    String method = 'system',
    String notes = '',
    String status = 'completed',
    String source = FirestorePaths.txSourceSystem,
    String currency = 'INR',
    String callId = '',
    String paymentOrderId = '',
    String paymentId = '',
    String withdrawalRequestId = '',
    String idempotencyKey = '',
    String gateway = '',
    Map<String, dynamic>? metadata,
  }) async {
    debugPrint(
      'addWalletTransaction skipped: wallet ledger authority is server-owned.',
    );
  }

  static Future<DocumentReference<Map<String, dynamic>>>
      createWithdrawalRequest({
    required int amount,
    String note = '',
    String payoutMode = 'manual_test',
    bool realMoneyEnabled = false,
    Map<String, dynamic>? payoutAccountSnapshot,
  }) async {
    final safeUid = safeUidOrNull();
    if (safeUid == null) {
      throw StateError('Cannot request withdrawal without login.');
    }

    final result = await fn().httpsCallable('requestWithdrawal_v1').call({
      'amount': amount,
      'note': note.trim(),
      'payoutMode': payoutMode.trim(),
      'realMoneyEnabled': realMoneyEnabled,
      'payoutAccountSnapshot': payoutAccountSnapshot ?? <String, dynamic>{},
    });

    final data = result.data;
    if (data is! Map) {
      throw StateError('requestWithdrawal_v1 returned invalid response.');
    }

    final requestId = _asString(data['requestId']);
    if (requestId.isEmpty) {
      throw StateError('requestWithdrawal_v1 returned empty requestId.');
    }

    return withdrawalRequests.doc(requestId);
  }

  static Future<void> cancelWithdrawalRequest({
    required DocumentReference<Map<String, dynamic>> requestRef,
  }) async {
    final safeUid = safeUidOrNull();
    if (safeUid == null) return;

    final requestId = requestRef.id.trim();
    if (requestId.isEmpty) return;

    await fn().httpsCallable('cancelMyWithdrawal_v1').call({
      'requestId': requestId,
    });
  }
}