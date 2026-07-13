class AppUserModel {
  final String uid;
  final String email;
  final String displayName;

  final int credits;
  final int reservedCredits;
  final int earningsCredits;
  final int platformRevenueCredits;

  final String photoURL;
  final String bio;
  final String gender;
  final String city;
  final String state;
  final String country;

  final List<String> topics;
  final List<String> languages;

  final bool isListener;
  final bool isAvailable;
  final bool isOnCall;
  final bool onlyChatMode;

  final int followersCount;
  final int level;
  final int listenerRate;

  final List<String> following;
  final List<String> blocked;
  final List<String> fcmTokens;
  final List<String> favoriteListeners;

  final String activeCallId;
  final DateTime? activeCallUpdatedAt;

  final double ratingAvg;
  final int ratingCount;
  final int ratingSum;

  final DateTime? createdAt;
  final DateTime? lastSeen;
  final bool adminBlocked;
  final String adminBlockReason;
  final String accountDeletionRequestId;
  final String accountDeletionRequestStatus;
  final String accountDeletionRequestOutcome;
  final DateTime? accountDeletionRequestRequestedAt;
  final DateTime? accountDeletionRequestReviewedAt;

  const AppUserModel({
    required this.uid,
    required this.email,
    required this.displayName,
    required this.credits,
    required this.reservedCredits,
    required this.earningsCredits,
    required this.platformRevenueCredits,
    required this.photoURL,
    required this.bio,
    required this.gender,
    required this.city,
    required this.state,
    required this.country,
    required this.topics,
    required this.languages,
    required this.isListener,
    required this.isAvailable,
    this.isOnCall = false,
    this.onlyChatMode = false,
    required this.followersCount,
    required this.level,
    required this.listenerRate,
    required this.following,
    required this.blocked,
    required this.fcmTokens,
    required this.favoriteListeners,
    required this.activeCallId,
    this.activeCallUpdatedAt,
    required this.ratingAvg,
    required this.ratingCount,
    required this.ratingSum,
    required this.createdAt,
    required this.lastSeen,
    this.adminBlocked = false,
    this.adminBlockReason = '',
    this.accountDeletionRequestId = '',
    this.accountDeletionRequestStatus = '',
    this.accountDeletionRequestOutcome = '',
    this.accountDeletionRequestRequestedAt,
    this.accountDeletionRequestReviewedAt,
  });

  static int _asInt(dynamic value, {int fallback = 0}) {
    if (value is int) return value;
    if (value is num) return value.floor();
    return fallback;
  }

  static double _asDouble(dynamic value, {double fallback = 0}) {
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return fallback;
  }

  static bool _asBool(dynamic value, {bool fallback = false}) {
    if (value is bool) return value;
    return fallback;
  }

  static String _asString(dynamic value, {String fallback = ''}) {
    if (value is String) return value.trim();
    return fallback;
  }

  static Map<String, dynamic> _stringMap(dynamic value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    return const <String, dynamic>{};
  }

  static List<String> _stringList(dynamic value) {
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

  static DateTime? _timestampToDate(dynamic value) {
    if (value == null) return null;

    if (value is DateTime) return value;

    final type = value.runtimeType.toString();
    if (type == 'Timestamp') {
      try {
        return value.toDate() as DateTime;
      } catch (_) {
        return null;
      }
    }

    return null;
  }

  static String _displayNameWithFallback(
    Map<String, dynamic> data,
  ) {
    final rawName = _asString(data['displayName']);
    if (rawName.isNotEmpty) return rawName;

    final rawEmail = _asString(data['email']);
    if (rawEmail.isNotEmpty && rawEmail.contains('@')) {
      return rawEmail.split('@').first;
    }

    return 'Friendify User';
  }

  factory AppUserModel.fromMap(Map<String, dynamic> data) {
    final safeFollowers = _asInt(data['followersCount']);
    final safeLevel = _asInt(data['level']) <= 0 ? 1 : _asInt(data['level']);
    final safeRate =
        _asInt(data['listenerRate']) <= 0 ? 5 : _asInt(data['listenerRate']);

    final callAvailability = _stringMap(data['callAvailability']);

    return AppUserModel(
      uid: _asString(data['uid']),
      email: _asString(data['email']),
      displayName: _displayNameWithFallback(data),
      credits: _asInt(data['credits']),
      reservedCredits: _asInt(data['reservedCredits']),
      earningsCredits: _asInt(data['earningsCredits']),
      platformRevenueCredits: _asInt(data['platformRevenueCredits']),
      photoURL: _asString(data['photoURL']),
      bio: _asString(data['bio']),
      gender: _asString(data['gender']),
      city: _asString(data['city']),
      state: _asString(data['state']),
      country: _asString(data['country']),
      topics: _stringList(data['topics']),
      languages: _stringList(data['languages']),
      isListener: _asBool(data['isListener']),
      isAvailable: _asBool(data['isAvailable']),
      isOnCall: _asBool(data['isOnCall']),
      onlyChatMode: _asBool(
        callAvailability['onlyChatMode'],
        fallback: _asBool(data['onlyChatMode']),
      ),
      followersCount: safeFollowers,
      level: safeLevel,
      listenerRate: safeRate,
      following: _stringList(data['following']),
      blocked: _stringList(data['blocked']),
      fcmTokens: _stringList(data['fcmTokens']),
      favoriteListeners: _stringList(data['favoriteListeners']),
      activeCallId: _asString(data['activeCallId']),
      activeCallUpdatedAt: _timestampToDate(data['activeCallUpdatedAt']),
      ratingAvg: _asDouble(data['ratingAvg']),
      ratingCount: _asInt(data['ratingCount']),
      ratingSum: _asInt(data['ratingSum']),
      createdAt: _timestampToDate(data['createdAt']),
      lastSeen: _timestampToDate(data['lastSeen']),
      adminBlocked: _asBool(data['adminBlocked']),
      adminBlockReason: _asString(data['adminBlockReason']),
      accountDeletionRequestId: _asString(data['accountDeletionRequestId']),
      accountDeletionRequestStatus:
          _asString(data['accountDeletionRequestStatus']),
      accountDeletionRequestOutcome:
          _asString(data['accountDeletionRequestOutcome']),
      accountDeletionRequestRequestedAt: _timestampToDate(
        data['accountDeletionRequestRequestedAt'],
      ),
      accountDeletionRequestReviewedAt: _timestampToDate(
        data['accountDeletionRequestReviewedAt'],
      ),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'uid': uid,
      'email': email,
      'displayName': displayName,
      'credits': credits,
      'reservedCredits': reservedCredits,
      'earningsCredits': earningsCredits,
      'platformRevenueCredits': platformRevenueCredits,
      'photoURL': photoURL,
      'bio': bio,
      'gender': gender,
      'city': city,
      'state': state,
      'country': country,
      'topics': topics,
      'languages': languages,
      'isListener': isListener,
      'isAvailable': isAvailable,
      'isOnCall': isOnCall,
      'callAvailability': {
        'onlyChatMode': onlyChatMode,
      },
      'followersCount': followersCount,
      'level': level,
      'listenerRate': listenerRate,
      'following': following,
      'blocked': blocked,
      'fcmTokens': fcmTokens,
      'favoriteListeners': favoriteListeners,
      'activeCallId': activeCallId,
      'activeCallUpdatedAt': activeCallUpdatedAt,
      'ratingAvg': ratingAvg,
      'ratingCount': ratingCount,
      'ratingSum': ratingSum,
      'createdAt': createdAt,
      'lastSeen': lastSeen,
      'adminBlocked': adminBlocked,
      'adminBlockReason': adminBlockReason,
      'accountDeletionRequestId': accountDeletionRequestId,
      'accountDeletionRequestStatus': accountDeletionRequestStatus,
      'accountDeletionRequestOutcome': accountDeletionRequestOutcome,
      'accountDeletionRequestRequestedAt': accountDeletionRequestRequestedAt,
      'accountDeletionRequestReviewedAt': accountDeletionRequestReviewedAt,
    };
  }

  int get usableCredits {
    final value = credits - reservedCredits;
    return value < 0 ? 0 : value;
  }

  bool get hasActiveCall => isOnCall;

  bool get hasCallReference => activeCallId.trim().isNotEmpty;

  bool get hasPhoto => photoURL.trim().isNotEmpty;
  bool get hasBio => bio.trim().isNotEmpty;
  bool get hasTopics => topics.isNotEmpty;
  bool get hasLanguages => languages.isNotEmpty;
  bool get hasLocation =>
      city.trim().isNotEmpty ||
      state.trim().isNotEmpty ||
      country.trim().isNotEmpty;
  bool get hasRatings => ratingCount > 0;
  bool get isAdminBlocked => adminBlocked;
  bool get hasPendingAccountDeletionRequest =>
      accountDeletionRequestStatus.trim().toLowerCase() == 'pending';
  bool get hasReviewedAccountDeletionRequest =>
      accountDeletionRequestStatus.trim().toLowerCase() == 'reviewed';

  int get profileCompletenessPercent {
    var score = 0;
    if (displayName.trim().isNotEmpty) score += 15;
    if (hasBio) score += 15;
    if (hasTopics) score += 15;
    if (hasLanguages) score += 15;
    if (hasPhoto) score += 15;
    if (gender.trim().isNotEmpty) score += 10;
    if (city.trim().isNotEmpty) score += 10;
    if (state.trim().isNotEmpty) score += 5;
    return score.clamp(0, 100);
  }

  List<String> get profileCompletionMissingItems {
    final out = <String>[];
    if (displayName.trim().isEmpty) out.add('Name');
    if (!hasBio) out.add('Bio');
    if (!hasTopics) out.add('Topics');
    if (!hasLanguages) out.add('Languages');
    if (!hasPhoto) out.add('Photo');
    if (gender.trim().isEmpty) out.add('Gender');
    if (city.trim().isEmpty) out.add('City');
    if (state.trim().isEmpty) out.add('State');
    return out;
  }

  bool get isProfileComplete => profileCompletenessPercent >= 100;

  bool get isDiscoveryReady {
    return !isAdminBlocked &&
        displayName.trim().isNotEmpty &&
        hasBio &&
        hasTopics &&
        hasLanguages;
  }

  int get marketplaceProfileScore {
    var score = 0;
    if (hasPhoto) score += 3;
    if (hasBio) score += 3;
    if (hasTopics) score += 2;
    if (hasLanguages) score += 2;
    if (hasLocation) score += 1;
    if (!onlyChatMode) score += 1;
    return score;
  }

  bool isFavoriteListener(String listenerId) {
    final safeId = listenerId.trim();
    if (safeId.isEmpty) return false;
    return favoriteListeners.contains(safeId);
  }

  String get safeDisplayName {
    final safe = displayName.trim();
    if (safe.isNotEmpty) return safe;

    final safeEmail = email.trim();
    if (safeEmail.isNotEmpty && safeEmail.contains('@')) {
      return safeEmail.split('@').first;
    }

    return 'Friendify User';
  }

  String get firstLetter {
    final safe = safeDisplayName.trim();
    if (safe.isEmpty) return 'U';
    return safe[0].toUpperCase();
  }

  AppUserModel copyWith({
    String? uid,
    String? email,
    String? displayName,
    int? credits,
    int? reservedCredits,
    int? earningsCredits,
    int? platformRevenueCredits,
    String? photoURL,
    String? bio,
    String? gender,
    String? city,
    String? state,
    String? country,
    List<String>? topics,
    List<String>? languages,
    bool? isListener,
    bool? isAvailable,
    bool? isOnCall,
    bool? onlyChatMode,
    int? followersCount,
    int? level,
    int? listenerRate,
    List<String>? following,
    List<String>? blocked,
    List<String>? fcmTokens,
    List<String>? favoriteListeners,
    String? activeCallId,
    DateTime? activeCallUpdatedAt,
    double? ratingAvg,
    int? ratingCount,
    int? ratingSum,
    DateTime? createdAt,
    DateTime? lastSeen,
    bool? adminBlocked,
    String? adminBlockReason,
    String? accountDeletionRequestId,
    String? accountDeletionRequestStatus,
    String? accountDeletionRequestOutcome,
    DateTime? accountDeletionRequestRequestedAt,
    DateTime? accountDeletionRequestReviewedAt,
  }) {
    return AppUserModel(
      uid: uid ?? this.uid,
      email: email ?? this.email,
      displayName: displayName ?? this.displayName,
      credits: credits ?? this.credits,
      reservedCredits: reservedCredits ?? this.reservedCredits,
      earningsCredits: earningsCredits ?? this.earningsCredits,
      platformRevenueCredits:
          platformRevenueCredits ?? this.platformRevenueCredits,
      photoURL: photoURL ?? this.photoURL,
      bio: bio ?? this.bio,
      gender: gender ?? this.gender,
      city: city ?? this.city,
      state: state ?? this.state,
      country: country ?? this.country,
      topics: topics ?? this.topics,
      languages: languages ?? this.languages,
      isListener: isListener ?? this.isListener,
      isAvailable: isAvailable ?? this.isAvailable,
      isOnCall: isOnCall ?? this.isOnCall,
      onlyChatMode: onlyChatMode ?? this.onlyChatMode,
      followersCount: followersCount ?? this.followersCount,
      level: level ?? this.level,
      listenerRate: listenerRate ?? this.listenerRate,
      following: following ?? this.following,
      blocked: blocked ?? this.blocked,
      fcmTokens: fcmTokens ?? this.fcmTokens,
      favoriteListeners: favoriteListeners ?? this.favoriteListeners,
      activeCallId: activeCallId ?? this.activeCallId,
      activeCallUpdatedAt: activeCallUpdatedAt ?? this.activeCallUpdatedAt,
      ratingAvg: ratingAvg ?? this.ratingAvg,
      ratingCount: ratingCount ?? this.ratingCount,
      ratingSum: ratingSum ?? this.ratingSum,
      createdAt: createdAt ?? this.createdAt,
      lastSeen: lastSeen ?? this.lastSeen,
      adminBlocked: adminBlocked ?? this.adminBlocked,
      adminBlockReason: adminBlockReason ?? this.adminBlockReason,
      accountDeletionRequestId:
          accountDeletionRequestId ?? this.accountDeletionRequestId,
      accountDeletionRequestStatus:
          accountDeletionRequestStatus ?? this.accountDeletionRequestStatus,
      accountDeletionRequestOutcome:
          accountDeletionRequestOutcome ?? this.accountDeletionRequestOutcome,
      accountDeletionRequestRequestedAt: accountDeletionRequestRequestedAt ??
          this.accountDeletionRequestRequestedAt,
      accountDeletionRequestReviewedAt: accountDeletionRequestReviewedAt ??
          this.accountDeletionRequestReviewedAt,
    );
  }
}
