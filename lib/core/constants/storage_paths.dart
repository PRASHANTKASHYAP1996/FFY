class StoragePaths {
  StoragePaths._();

  static const String profilePhotos = 'profile_photos';
  static const String profilePhotoFileName = 'profile.jpg';
  static const String socialUploads = 'social_uploads';

  static String profilePhoto(String userId) {
    final safeUserId = userId.trim();
    return '$profilePhotos/$safeUserId/$profilePhotoFileName';
  }

  static String socialPostImage({
    required String userId,
    required String postId,
  }) {
    final safeUserId = userId.trim();
    final safePostId = postId.trim();
    return '$socialUploads/$safeUserId/$safePostId.jpg';
  }
}
