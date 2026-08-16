import 'package:flutter_test/flutter_test.dart';

import 'package:friendify/shared/people_match.dart';

int match(List<String> myT, List<String> myL, List<String> tT, List<String> tL) =>
    PeopleMatch.percent(
      myTopics: myT,
      myLanguages: myL,
      theirTopics: tT,
      theirLanguages: tL,
    );

void main() {
  test('identical sets are 100%', () {
    expect(match(['Loneliness'], ['Hindi'], ['Loneliness'], ['Hindi']), 100);
  });

  test('no overlap is 0%', () {
    expect(match(['Work'], ['Tamil'], ['Breakup'], ['Bengali']), 0);
  });

  test('empty on either side is 0%', () {
    expect(match([], [], ['Work'], ['Hindi']), 0);
    expect(match(['Work'], ['Hindi'], [], []), 0);
  });

  test('case-insensitive and whitespace-trimmed', () {
    expect(match(['  Loneliness '], ['HINDI'], ['loneliness'], ['hindi']), 100);
  });

  test('partial overlap is Jaccard-based', () {
    // mine = {work, hindi}; theirs = {work, tamil}
    // intersection 1, union 3 -> 33%
    expect(match(['Work'], ['Hindi'], ['Work'], ['Tamil']), 33);
  });

  test('subset overlap', () {
    // mine = {a, b}; theirs = {a, b, c} -> inter 2, union 3 -> 67%
    expect(match(['a', 'b'], [], ['a', 'b', 'c'], []), 67);
  });
}
