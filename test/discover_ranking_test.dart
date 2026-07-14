import 'package:flutter_test/flutter_test.dart';

import 'package:friendify/shared/discover_ranking.dart';
import 'package:friendify/shared/models/app_user_model.dart';

AppUserModel _user({
  String uid = 'u',
  String name = 'User',
  String bio = '',
  String city = '',
  String state = '',
  List<String> topics = const <String>[],
  List<String> languages = const <String>[],
  int rate = 5,
}) {
  return AppUserModel.fromMap(<String, dynamic>{
    'uid': uid,
    'displayName': name,
    'bio': bio,
    'city': city,
    'state': state,
    'topics': topics,
    'languages': languages,
    'listenerRate': rate,
  });
}

List<String> _uids(List<AppUserModel> users) =>
    users.map((u) => u.uid).toList();

void main() {
  group('applyFilters', () {
    final priya = _user(
      uid: 'priya',
      name: 'Priya',
      bio: 'Here to listen',
      city: 'Mumbai',
      topics: const ['Loneliness', 'Family'],
      languages: const ['English', 'Hindi'],
    );
    final arjun = _user(
      uid: 'arjun',
      name: 'Arjun',
      bio: 'Career coach',
      topics: const ['Work & career'],
      languages: const ['Tamil'],
    );
    final all = <AppUserModel>[priya, arjun];

    test('returns the same list instance when no filters are set', () {
      expect(identical(DiscoverRanking.applyFilters(all), all), isTrue);
    });

    test('matches display name case-insensitively', () {
      expect(_uids(DiscoverRanking.applyFilters(all, query: 'priy')),
          <String>['priya']);
      expect(_uids(DiscoverRanking.applyFilters(all, query: 'ARJUN')),
          <String>['arjun']);
    });

    test('matches on topics, bio, and city', () {
      expect(_uids(DiscoverRanking.applyFilters(all, query: 'family')),
          <String>['priya']);
      expect(_uids(DiscoverRanking.applyFilters(all, query: 'coach')),
          <String>['arjun']);
      expect(_uids(DiscoverRanking.applyFilters(all, query: 'mumbai')),
          <String>['priya']);
    });

    test('returns empty when nothing matches the query', () {
      expect(DiscoverRanking.applyFilters(all, query: 'zzz'), isEmpty);
    });

    test('language filter is an exact token match, case-insensitive', () {
      expect(_uids(DiscoverRanking.applyFilters(all, language: 'hindi')),
          <String>['priya']);
      expect(_uids(DiscoverRanking.applyFilters(all, language: 'Tamil')),
          <String>['arjun']);
      // A prefix is not a match — the token must be equal.
      expect(DiscoverRanking.applyFilters(all, language: 'hin'), isEmpty);
    });

    test('query and language combine with AND', () {
      expect(
        DiscoverRanking.applyFilters(all, query: 'priya', language: 'tamil'),
        isEmpty,
      );
      expect(
        _uids(DiscoverRanking.applyFilters(all,
            query: 'priya', language: 'english')),
        <String>['priya'],
      );
    });

    test('blank query with only whitespace is treated as no query', () {
      expect(identical(DiscoverRanking.applyFilters(all, query: '   '), all),
          isTrue);
    });
  });

  group('moodActive', () {
    test('is false for empty, unknown, and the no-keyword mood', () {
      expect(DiscoverRanking.moodActive(''), isFalse);
      expect(DiscoverRanking.moodActive('Nope'), isFalse);
      expect(DiscoverRanking.moodActive('Just talk'), isFalse);
    });

    test('is true for moods that carry keywords', () {
      expect(DiscoverRanking.moodActive('Lonely'), isTrue);
      expect(DiscoverRanking.moodActive('Stressed'), isTrue);
      expect(DiscoverRanking.moodActive('Breakup'), isTrue);
    });
  });

  group('matchesMood', () {
    test('matches a keyword found in topics or bio', () {
      expect(
        DiscoverRanking.matchesMood(
            _user(topics: const ['Loneliness']), 'Lonely'),
        isTrue,
      );
      expect(
        DiscoverRanking.matchesMood(
            _user(bio: 'I help with work stress'), 'Stressed'),
        isTrue,
      );
    });

    test('does not match when no keyword is present', () {
      expect(
        DiscoverRanking.matchesMood(
            _user(topics: const ['Gaming'], bio: 'hi'), 'Lonely'),
        isFalse,
      );
    });

    test('a no-keyword mood matches everyone, even empty profiles', () {
      expect(DiscoverRanking.matchesMood(_user(), 'Just talk'), isTrue);
      expect(DiscoverRanking.matchesMood(_user(), 'Unknown'), isTrue);
    });
  });

  group('orderByMood', () {
    final a = _user(uid: 'a', topics: const ['Gaming']);
    final b = _user(uid: 'b', topics: const ['Loneliness']);
    final c = _user(uid: 'c', bio: 'feeling alone');
    final d = _user(uid: 'd', topics: const ['Cooking']);
    final all = <AppUserModel>[a, b, c, d];

    test('inactive mood returns the input unchanged with zero count', () {
      final r = DiscoverRanking.orderByMood(all, 'Just talk');
      expect(identical(r.ordered, all), isTrue);
      expect(r.matchCount, 0);
    });

    test('matches float to the top, preserving relative order', () {
      final r = DiscoverRanking.orderByMood(all, 'Lonely');
      // b and c match ('loneliness', 'alone'); a and d do not.
      expect(_uids(r.ordered), <String>['b', 'c', 'a', 'd']);
      expect(r.matchCount, 2);
    });

    test('nobody is dropped from the list', () {
      final r = DiscoverRanking.orderByMood(all, 'Lonely');
      expect(r.ordered.length, all.length);
      expect(_uids(r.ordered).toSet(), _uids(all).toSet());
    });

    test('zero matches keeps everyone with a zero count', () {
      final r = DiscoverRanking.orderByMood(all, 'Breakup');
      expect(r.matchCount, 0);
      expect(_uids(r.ordered), _uids(all));
    });
  });

  group('sortByPriceAscending', () {
    test('sorts cheapest first', () {
      final list = <AppUserModel>[
        _user(uid: 'a', rate: 20),
        _user(uid: 'b', rate: 5),
        _user(uid: 'c', rate: 12),
      ];
      expect(_uids(DiscoverRanking.sortByPriceAscending(list)),
          <String>['b', 'c', 'a']);
    });

    test('is stable for equal rates (keeps input order)', () {
      final list = <AppUserModel>[
        _user(uid: 'a', rate: 10),
        _user(uid: 'b', rate: 10),
        _user(uid: 'c', rate: 10),
      ];
      expect(_uids(DiscoverRanking.sortByPriceAscending(list)),
          <String>['a', 'b', 'c']);
    });

    test('does not mutate the input list', () {
      final list = <AppUserModel>[
        _user(uid: 'a', rate: 20),
        _user(uid: 'b', rate: 5),
      ];
      DiscoverRanking.sortByPriceAscending(list);
      expect(_uids(list), <String>['a', 'b']);
    });
  });
}
