/// A member's level, derived purely from follower count. Used on posts,
/// profiles, and people cards across Home, Explore, and You.
///
/// Tiers:
/// - Level 1: fewer than 100 followers
/// - Level 2: 100–499
/// - Level 3: 500–1,999
/// - Level 4: 2,000–9,999
/// - Level 5: 10,000+
class LevelUtils {
  const LevelUtils._();

  static const int maxLevel = 5;

  /// The level (1–5) for a given [followers] count. Negative/zero → level 1.
  static int levelForFollowers(int followers) {
    if (followers >= 10000) return 5;
    if (followers >= 2000) return 4;
    if (followers >= 500) return 3;
    if (followers >= 100) return 2;
    return 1;
  }

  /// Short label, e.g. "Lv 3".
  static String levelLabel(int followers) =>
      'Lv ${levelForFollowers(followers)}';

  /// Followers still needed to reach the next level, or null at max level.
  static int? followersToNextLevel(int followers) {
    const thresholds = <int>[100, 500, 2000, 10000];
    for (final t in thresholds) {
      if (followers < t) return t - followers;
    }
    return null;
  }
}
