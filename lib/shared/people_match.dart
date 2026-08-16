/// A lightweight "match" score between two members for the Explore tab,
/// computed on the client from how much their topics + languages overlap.
/// (There is no backend match field; this is a transparent heuristic.)
class PeopleMatch {
  const PeopleMatch._();

  /// Jaccard overlap (0–100) of the two members' combined topics + languages.
  /// Returns 0 when either side has nothing to compare against.
  static int percent({
    required List<String> myTopics,
    required List<String> myLanguages,
    required List<String> theirTopics,
    required List<String> theirLanguages,
  }) {
    final mine = _norm(myTopics)..addAll(_norm(myLanguages));
    final theirs = _norm(theirTopics)..addAll(_norm(theirLanguages));
    if (mine.isEmpty || theirs.isEmpty) return 0;
    final intersection = mine.intersection(theirs).length;
    final union = mine.union(theirs).length;
    if (union == 0) return 0;
    return ((intersection / union) * 100).round();
  }

  static Set<String> _norm(List<String> xs) => xs
      .map((s) => s.trim().toLowerCase())
      .where((s) => s.isNotEmpty)
      .toSet();
}
