import 'models/app_user_model.dart';

/// Pure ranking + filtering logic for the Discover tab, extracted from the
/// widget so it can be unit tested. No Flutter or Firebase dependencies.
///
/// Pipeline used by Discover: [applyFilters] narrows the available listeners
/// by search text and language, then [orderByMood] re-orders (never hides)
/// the result so mood matches float to the top, then [sortByPriceAscending]
/// optionally overrides that order by rate.
class DiscoverRanking {
  const DiscoverRanking._();

  /// Mood chips shown on Discover, in display order.
  static const List<String> moods = <String>[
    'Lonely',
    'Stressed',
    'Breakup',
    'Just talk',
  ];

  /// Keywords matched (case-insensitive) against a listener's topics + bio.
  /// An empty list means "matches everyone" (used by 'Just talk').
  static const Map<String, List<String>> moodKeywords = <String, List<String>>{
    'Lonely': <String>[
      'lonely',
      'loneliness',
      'alone',
      'friend',
      'company',
      'companion',
      'listen',
    ],
    'Stressed': <String>[
      'stress',
      'anxiety',
      'anxious',
      'pressure',
      'work',
      'career',
      'study',
      'exam',
      'calm',
      'overthink',
    ],
    'Breakup': <String>[
      'breakup',
      'break-up',
      'break up',
      'relationship',
      'heartbreak',
      'love',
      'dating',
      'divorce',
      'marriage',
    ],
    'Just talk': <String>[],
  };

  /// True when a mood is picked that actually narrows/reorders. 'Just talk'
  /// (and any unknown or empty mood) has no keywords, so it never filters.
  static bool moodActive(String mood) =>
      mood.isNotEmpty && (moodKeywords[mood]?.isNotEmpty ?? false);

  /// Whether a listener matches the given mood, by scanning their topics + bio
  /// for any of the mood's keywords. A mood with no keywords matches everyone.
  static bool matchesMood(AppUserModel user, String mood) {
    final keywords = moodKeywords[mood] ?? const <String>[];
    if (keywords.isEmpty) return true;
    final haystack = '${user.topics.join(' ')} ${user.bio}'.toLowerCase();
    return keywords.any(haystack.contains);
  }

  /// Narrow [all] by a free-text [query] (name, bio, city, state, topics,
  /// languages) and an exact [language]. Returns the same list instance when
  /// neither filter is set, so callers can cheaply detect "no filtering".
  static List<AppUserModel> applyFilters(
    List<AppUserModel> all, {
    String query = '',
    String language = '',
  }) {
    final q = query.trim().toLowerCase();
    final lang = language.trim().toLowerCase();
    if (q.isEmpty && lang.isEmpty) return all;
    return all.where((u) {
      if (q.isNotEmpty) {
        final hay = <String>[
          u.safeDisplayName,
          u.bio,
          u.city,
          u.state,
          ...u.topics,
          ...u.languages,
        ].join(' ').toLowerCase();
        if (!hay.contains(q)) return false;
      }
      if (lang.isNotEmpty && !u.languages.any((l) => l.toLowerCase() == lang)) {
        return false;
      }
      return true;
    }).toList(growable: false);
  }

  /// Re-order [all] so listeners matching [mood] come first, preserving the
  /// original relative order within the matched and unmatched groups. Nobody
  /// is dropped. [matchCount] is how many matched. When the mood is inactive
  /// the input is returned unchanged with a zero count.
  static ({List<AppUserModel> ordered, int matchCount}) orderByMood(
    List<AppUserModel> all,
    String mood,
  ) {
    if (!moodActive(mood)) return (ordered: all, matchCount: 0);
    final matched =
        all.where((u) => matchesMood(u, mood)).toList(growable: false);
    final matchedUids = matched.map((u) => u.uid).toSet();
    return (
      ordered: <AppUserModel>[
        ...matched,
        ...all.where((u) => !matchedUids.contains(u.uid)),
      ],
      matchCount: matched.length,
    );
  }

  /// A copy of [listeners] sorted by listener rate, cheapest first. The input
  /// is not mutated. Sort is stable, so equal-rate listeners keep their order.
  static List<AppUserModel> sortByPriceAscending(
    List<AppUserModel> listeners,
  ) {
    final sorted = [...listeners];
    _stableSortByRate(sorted);
    return sorted;
  }

  /// [List.sort] is not guaranteed stable, so implement an explicitly stable
  /// insertion by decorating with the original index.
  static void _stableSortByRate(List<AppUserModel> list) {
    final indexed = <MapEntry<int, AppUserModel>>[
      for (var i = 0; i < list.length; i++) MapEntry(i, list[i]),
    ];
    indexed.sort((a, b) {
      final byRate = a.value.listenerRate.compareTo(b.value.listenerRate);
      return byRate != 0 ? byRate : a.key.compareTo(b.key);
    });
    for (var i = 0; i < indexed.length; i++) {
      list[i] = indexed[i].value;
    }
  }
}
