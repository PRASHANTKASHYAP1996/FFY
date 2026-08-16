import 'package:flutter_test/flutter_test.dart';

import 'package:friendify/shared/level_utils.dart';

void main() {
  group('levelForFollowers', () {
    test('level 1 below 100 (incl. zero/negative)', () {
      expect(LevelUtils.levelForFollowers(-5), 1);
      expect(LevelUtils.levelForFollowers(0), 1);
      expect(LevelUtils.levelForFollowers(99), 1);
    });

    test('level 2 at 100–499', () {
      expect(LevelUtils.levelForFollowers(100), 2);
      expect(LevelUtils.levelForFollowers(499), 2);
    });

    test('level 3 at 500–1,999', () {
      expect(LevelUtils.levelForFollowers(500), 3);
      expect(LevelUtils.levelForFollowers(1999), 3);
    });

    test('level 4 at 2,000–9,999', () {
      expect(LevelUtils.levelForFollowers(2000), 4);
      expect(LevelUtils.levelForFollowers(9999), 4);
    });

    test('level 5 at 10,000+', () {
      expect(LevelUtils.levelForFollowers(10000), 5);
      expect(LevelUtils.levelForFollowers(1000000), 5);
    });
  });

  test('levelLabel formats as "Lv N"', () {
    expect(LevelUtils.levelLabel(0), 'Lv 1');
    expect(LevelUtils.levelLabel(750), 'Lv 3');
    expect(LevelUtils.levelLabel(50000), 'Lv 5');
  });

  test('level titles match the prototype (L2–L4) with L1/L5 fallbacks', () {
    expect(LevelUtils.levelTitle(50), 'New Voice');
    expect(LevelUtils.levelTitle(326), 'Rising Voice');
    expect(LevelUtils.levelTitle(842), 'Trusted Voice');
    expect(LevelUtils.levelTitle(2900), 'Community Star');
    expect(LevelUtils.levelTitle(12000), 'Guiding Light');
  });

  test('levelTag formats as "L{n} · Title"', () {
    expect(LevelUtils.levelTag(2900), 'L4 · Community Star');
    expect(LevelUtils.levelTag(326), 'L2 · Rising Voice');
  });

  group('followersToNextLevel', () {
    test('distance to the next threshold', () {
      expect(LevelUtils.followersToNextLevel(0), 100);
      expect(LevelUtils.followersToNextLevel(90), 10);
      expect(LevelUtils.followersToNextLevel(100), 400);
      expect(LevelUtils.followersToNextLevel(1999), 1);
    });

    test('null at max level', () {
      expect(LevelUtils.followersToNextLevel(10000), isNull);
      expect(LevelUtils.followersToNextLevel(99999), isNull);
    });
  });
}
