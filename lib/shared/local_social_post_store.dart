import 'package:flutter/foundation.dart';

@immutable
class LocalSocialPost {
  const LocalSocialPost({
    required this.id,
    required this.ownerUid,
    required this.caption,
    required this.imagePath,
    required this.isStory,
    required this.createdAt,
  });

  final String id;
  final String ownerUid;
  final String caption;
  final String imagePath;
  final bool isStory;
  final DateTime createdAt;
}

class LocalSocialPostStore {
  LocalSocialPostStore._();

  static final ValueNotifier<List<LocalSocialPost>> items =
      ValueNotifier<List<LocalSocialPost>>(<LocalSocialPost>[]);

  static void addPost({
    required String ownerUid,
    required String caption,
    required String imagePath,
  }) {
    _add(
      ownerUid: ownerUid,
      caption: caption,
      imagePath: imagePath,
      isStory: false,
    );
  }

  static void addStory({
    required String ownerUid,
    required String imagePath,
  }) {
    _add(
      ownerUid: ownerUid,
      caption: 'Story',
      imagePath: imagePath,
      isStory: true,
    );
  }

  static List<LocalSocialPost> postsFor(String ownerUid) {
    final safeUid = ownerUid.trim();
    return items.value
        .where((post) => !post.isStory && post.ownerUid == safeUid)
        .toList(growable: false);
  }

  static LocalSocialPost? latestStoryFor(String ownerUid) {
    final safeUid = ownerUid.trim();
    for (final post in items.value) {
      if (post.isStory && post.ownerUid == safeUid) return post;
    }
    return null;
  }

  static void _add({
    required String ownerUid,
    required String caption,
    required String imagePath,
    required bool isStory,
  }) {
    final safeUid = ownerUid.trim();
    final safeImagePath = imagePath.trim();
    if (safeUid.isEmpty || safeImagePath.isEmpty) return;

    final post = LocalSocialPost(
      id: '${DateTime.now().microsecondsSinceEpoch}_$safeUid',
      ownerUid: safeUid,
      caption: caption.trim(),
      imagePath: safeImagePath,
      isStory: isStory,
      createdAt: DateTime.now(),
    );

    items.value = <LocalSocialPost>[post, ...items.value];
  }
}
