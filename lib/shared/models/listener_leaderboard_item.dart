class ListenerLeaderboardItem {
  final String uid;
  final String displayName;
  final int followersCount;
  final double ratingAvg;
  final int ratingCount;
  final int totalEarned;
  final int paidCalls;
  final bool isAvailable;

  const ListenerLeaderboardItem({
    required this.uid,
    required this.displayName,
    required this.followersCount,
    required this.ratingAvg,
    required this.ratingCount,
    required this.totalEarned,
    required this.paidCalls,
    required this.isAvailable,
  });
}