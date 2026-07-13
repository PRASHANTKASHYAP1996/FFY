import '../../core/constants/firestore_paths.dart';

class SocialPostModel {
  const SocialPostModel({
    required this.postId,
    required this.ownerId,
    required this.ownerName,
    required this.ownerPhotoURL,
    required this.caption,
    required this.imageURL,
    required this.imagePath,
    required this.isStory,
    required this.likeCount,
    required this.commentCount,
    required this.shareCount,
    required this.createdAtMs,
    required this.expiresAtMs,
  });

  final String postId;
  final String ownerId;
  final String ownerName;
  final String ownerPhotoURL;
  final String caption;
  final String imageURL;
  final String imagePath;
  final bool isStory;
  final int likeCount;
  final int commentCount;
  final int shareCount;
  final int createdAtMs;
  final int expiresAtMs;

  bool get isActiveStory =>
      isStory &&
      (expiresAtMs <= 0 || expiresAtMs > DateTime.now().millisecondsSinceEpoch);

  Map<String, dynamic> toFirestore() {
    return <String, dynamic>{
      FirestorePaths.fieldSocialPostId: postId,
      FirestorePaths.fieldSocialOwnerId: ownerId,
      FirestorePaths.fieldSocialOwnerName: ownerName,
      FirestorePaths.fieldSocialOwnerPhotoURL: ownerPhotoURL,
      FirestorePaths.fieldSocialCaption: caption,
      FirestorePaths.fieldSocialImageURL: imageURL,
      FirestorePaths.fieldSocialImagePath: imagePath,
      FirestorePaths.fieldSocialIsStory: isStory,
      FirestorePaths.fieldSocialLikeCount: likeCount,
      FirestorePaths.fieldSocialCommentCount: commentCount,
      FirestorePaths.fieldSocialShareCount: shareCount,
      FirestorePaths.fieldSocialCreatedAtMs: createdAtMs,
      FirestorePaths.fieldSocialExpiresAtMs: expiresAtMs,
    };
  }

  static SocialPostModel? fromMap(
    Map<String, dynamic>? data, {
    required String fallbackId,
  }) {
    if (data == null) return null;

    String safeString(String key) => (data[key] ?? '').toString().trim();
    int safeInt(String key) {
      final value = data[key];
      if (value is int) return value;
      if (value is num) return value.toInt();
      return int.tryParse(value?.toString() ?? '') ?? 0;
    }

    final postId = safeString(FirestorePaths.fieldSocialPostId).isNotEmpty
        ? safeString(FirestorePaths.fieldSocialPostId)
        : fallbackId.trim();
    final ownerId = safeString(FirestorePaths.fieldSocialOwnerId);
    final imageURL = safeString(FirestorePaths.fieldSocialImageURL);
    if (postId.isEmpty || ownerId.isEmpty || imageURL.isEmpty) return null;

    return SocialPostModel(
      postId: postId,
      ownerId: ownerId,
      ownerName: safeString(FirestorePaths.fieldSocialOwnerName),
      ownerPhotoURL: safeString(FirestorePaths.fieldSocialOwnerPhotoURL),
      caption: safeString(FirestorePaths.fieldSocialCaption),
      imageURL: imageURL,
      imagePath: safeString(FirestorePaths.fieldSocialImagePath),
      isStory: data[FirestorePaths.fieldSocialIsStory] == true,
      likeCount: safeInt(FirestorePaths.fieldSocialLikeCount),
      commentCount: safeInt(FirestorePaths.fieldSocialCommentCount),
      shareCount: safeInt(FirestorePaths.fieldSocialShareCount),
      createdAtMs: safeInt(FirestorePaths.fieldSocialCreatedAtMs),
      expiresAtMs: safeInt(FirestorePaths.fieldSocialExpiresAtMs),
    );
  }
}
