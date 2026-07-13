import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

import '../core/constants/firestore_paths.dart';
import '../core/constants/storage_paths.dart';
import '../shared/models/app_user_model.dart';
import '../shared/models/social_post_model.dart';

class SocialRepository {
  SocialRepository._();

  static const int _maxSocialImageBytes = 8 * 1024 * 1024;
  static const int maxPostCaptionLength = 180;

  static final SocialRepository instance = SocialRepository._();

  FirebaseAuth get _auth => FirebaseAuth.instance;
  FirebaseFirestore get _db => FirebaseFirestore.instance;
  FirebaseFunctions get _functions => FirebaseFunctions.instance;
  FirebaseStorage get _storage => FirebaseStorage.instance;

  CollectionReference<Map<String, dynamic>> get _posts =>
      _db.collection(FirestorePaths.socialPosts);

  CollectionReference<Map<String, dynamic>> _savedPosts(String uid) =>
      _db.collection(FirestorePaths.users).doc(uid).collection('saved_posts');

  CollectionReference<Map<String, dynamic>> _notifications(String uid) =>
      _db.collection(FirestorePaths.users).doc(uid).collection('notifications');

  static String normalizePostCaption(String caption) => caption.trim();

  static String? postDraftValidationMessage({
    required String caption,
    required bool hasImage,
  }) {
    final safeCaption = normalizePostCaption(caption);
    if (!hasImage) {
      return 'Add a photo before uploading.';
    }
    if (safeCaption.isEmpty) {
      return 'Write a caption before uploading.';
    }
    if (safeCaption.length > maxPostCaptionLength) {
      return 'Caption must be $maxPostCaptionLength characters or less.';
    }
    return null;
  }

  String get _myUid {
    final uid = _auth.currentUser?.uid.trim();
    if (uid == null || uid.isEmpty) {
      throw StateError('User not logged in');
    }
    return uid;
  }

  Future<void> _validateSocialImageFile(File imageFile) async {
    if (!await imageFile.exists()) {
      throw StateError('Choose the photo again before uploading.');
    }

    final imageBytes = await imageFile.length();
    if (imageBytes <= 0) {
      throw StateError('That image file looks empty. Choose another photo.');
    }
    if (imageBytes >= _maxSocialImageBytes) {
      throw StateError('Image is too large. Choose a photo under 8 MB.');
    }
  }

  String _socialImageContentType(File imageFile) {
    final path = imageFile.path.toLowerCase();
    if (path.endsWith('.png')) return 'image/png';
    if (path.endsWith('.webp')) return 'image/webp';
    if (path.endsWith('.heic') || path.endsWith('.heif')) return 'image/heic';
    return 'image/jpeg';
  }

  Stream<List<SocialPostModel>> watchFeedPosts({int limit = 60}) {
    final safeLimit = limit < 1 ? 1 : limit;
    return _posts
        .orderBy(FirestorePaths.fieldSocialCreatedAtMs, descending: true)
        .limit(safeLimit * 2)
        .snapshots()
        .map((query) => _postsFromQuery(query)
            .where((post) => !post.isStory)
            .take(safeLimit)
            .toList(growable: false));
  }

  Stream<SocialPostModel?> watchPost(String postId) {
    final safePostId = postId.trim();
    if (safePostId.isEmpty) {
      return Stream<SocialPostModel?>.value(null).asBroadcastStream();
    }
    return _posts.doc(safePostId).snapshots().map(
          (doc) => doc.exists
              ? SocialPostModel.fromMap(doc.data(), fallbackId: doc.id)
              : null,
        );
  }

  Future<SocialPostModel?> fetchPost(String postId) async {
    final safePostId = postId.trim();
    if (safePostId.isEmpty) return null;
    final doc = await _posts.doc(safePostId).get();
    if (!doc.exists) return null;
    return SocialPostModel.fromMap(doc.data(), fallbackId: doc.id);
  }

  Stream<List<SocialPostModel>> watchUserPosts(
    String ownerId, {
    int limit = 60,
  }) {
    final safeOwnerId = ownerId.trim();
    if (safeOwnerId.isEmpty) {
      return Stream<List<SocialPostModel>>.value(
        const <SocialPostModel>[],
      ).asBroadcastStream();
    }

    final safeLimit = limit < 1 ? 1 : limit;
    return _posts
        .where(FirestorePaths.fieldSocialOwnerId, isEqualTo: safeOwnerId)
        .limit(safeLimit * 2)
        .snapshots()
        .map((query) {
      final posts = _postsFromQuery(query)
          .where((post) => !post.isStory)
          .toList(growable: false);
      posts.sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs));
      return posts.take(safeLimit).toList(growable: false);
    });
  }

  Stream<List<SocialPostModel>> watchActiveStories({int limit = 80}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final safeLimit = limit < 1 ? 1 : limit;
    return _posts
        .where(FirestorePaths.fieldSocialExpiresAtMs, isGreaterThan: now)
        .orderBy(FirestorePaths.fieldSocialExpiresAtMs)
        .limit(safeLimit * 2)
        .snapshots()
        .map((query) {
      final stories = _postsFromQuery(query)
          .where((post) => post.isStory && post.expiresAtMs > now)
          .toList(growable: false);
      stories.sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs));
      return stories.take(safeLimit).toList(growable: false);
    });
  }

  Stream<List<SocialCommentModel>> watchComments(String postId,
      {int limit = 80}) {
    final safePostId = postId.trim();
    if (safePostId.isEmpty) {
      return Stream<List<SocialCommentModel>>.value(
        const <SocialCommentModel>[],
      ).asBroadcastStream();
    }
    final safeLimit = limit < 1 ? 1 : limit;
    return _posts
        .doc(safePostId)
        .collection('comments')
        .orderBy('createdAtMs')
        .limit(safeLimit)
        .snapshots()
        .map((query) {
      final comments = <SocialCommentModel>[];
      for (final doc in query.docs) {
        final comment = SocialCommentModel.fromMap(
          doc.data(),
          fallbackId: doc.id,
        );
        if (comment != null) comments.add(comment);
      }
      return comments;
    });
  }

  Stream<bool> watchPostLikedByMe(String postId) {
    final safePostId = postId.trim();
    final uid = _auth.currentUser?.uid.trim() ?? '';
    if (safePostId.isEmpty || uid.isEmpty) {
      return Stream<bool>.value(false).asBroadcastStream();
    }
    return _posts
        .doc(safePostId)
        .collection('likes')
        .doc(uid)
        .snapshots()
        .map((doc) => doc.exists);
  }

  Stream<bool> watchPostSavedByMe(String postId) {
    final safePostId = postId.trim();
    final uid = _auth.currentUser?.uid.trim() ?? '';
    if (safePostId.isEmpty || uid.isEmpty) {
      return Stream<bool>.value(false).asBroadcastStream();
    }
    return _savedPosts(uid)
        .doc(safePostId)
        .snapshots()
        .map((doc) => doc.exists);
  }

  Future<SocialPostModel?> _savedPostFromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> savedDoc,
  ) async {
    final postId = (savedDoc.data()['postId'] as String?)?.trim() ?? '';
    if (postId.isEmpty) {
      return null;
    }

    try {
      final postDoc = await _posts.doc(postId).get();
      if (!postDoc.exists) {
        return null;
      }

      final post = SocialPostModel.fromMap(
        postDoc.data(),
        fallbackId: postDoc.id,
      );
      if (post == null || post.isStory) {
        return null;
      }
      return post;
    } catch (_) {
      return null;
    }
  }

  Stream<List<SocialPostModel>> watchSavedPostsByMe({int limit = 90}) {
    final uid = _auth.currentUser?.uid.trim() ?? '';
    if (uid.isEmpty) {
      return Stream<List<SocialPostModel>>.value(
        const <SocialPostModel>[],
      ).asBroadcastStream();
    }
    final safeLimit = limit < 1 ? 1 : limit;
    return _savedPosts(uid)
        .orderBy('savedAtMs', descending: true)
        .limit(safeLimit)
        .snapshots()
        .asyncMap((query) async {
      final posts = await Future.wait(query.docs.map(_savedPostFromDoc));
      return posts.whereType<SocialPostModel>().toList(growable: false);
    });
  }

  Future<SocialPostModel> createPost({
    required AppUserModel owner,
    required File imageFile,
    required String caption,
    bool isStory = false,
  }) async {
    final uid = _myUid;
    if (uid != owner.uid.trim()) {
      throw StateError('Cannot create a post for a different user.');
    }

    final safeCaption = normalizePostCaption(caption);
    if (!isStory) {
      final validationMessage = postDraftValidationMessage(
        caption: safeCaption,
        hasImage: true,
      );
      if (validationMessage != null) {
        throw StateError(validationMessage);
      }
    }
    await _validateSocialImageFile(imageFile);

    final doc = _posts.doc();
    final storagePath = StoragePaths.socialPostImage(
      userId: uid,
      postId: doc.id,
    );

    final ref = _storage.ref(storagePath);
    var uploaded = false;
    var serverCreateCompleted = false;
    try {
      final uploadSnapshot = await ref.putFile(
        imageFile,
        SettableMetadata(
          contentType: _socialImageContentType(imageFile),
          customMetadata: {
            'ownerId': uid,
            'kind': isStory ? 'story' : 'post',
          },
        ),
      );
      uploaded = true;
      final imageUrl = await uploadSnapshot.ref.getDownloadURL();

      final result =
          await _functions.httpsCallable('createSocialPost_v1').call({
        'postId': doc.id,
        'caption': safeCaption,
        'imageURL': imageUrl,
        'imagePath': storagePath,
        'isStory': isStory,
      });
      serverCreateCompleted = true;
      final data = result.data;
      final rawPost = data is Map ? data['post'] : null;
      final postData = rawPost is Map
          ? Map<String, dynamic>.from(rawPost)
          : <String, dynamic>{};
      final post = SocialPostModel.fromMap(postData, fallbackId: doc.id);
      if (post == null) {
        throw StateError('Post was created, but the response was invalid.');
      }

      return post;
    } catch (_) {
      if (uploaded && !serverCreateCompleted) {
        try {
          await ref.delete();
        } catch (_) {
          // Best-effort cleanup: keep the original upload/write failure.
        }
      }
      rethrow;
    }
  }

  Future<void> likePost(String postId) => _callSocialAction(
        'likeSocialPost_v1',
        postId: postId,
      );

  Future<void> unlikePost(String postId) => _callSocialAction(
        'unlikeSocialPost_v1',
        postId: postId,
      );

  Future<void> sharePost(String postId) => _callSocialAction(
        'shareSocialPost_v1',
        postId: postId,
      );

  Future<void> savePost(String postId) async {
    final safePostId = postId.trim();
    if (safePostId.isEmpty) return;
    await _functions.httpsCallable('saveSocialPost_v1').call({
      'postId': safePostId,
    });
  }

  Future<void> unsavePost(String postId) async {
    final safePostId = postId.trim();
    if (safePostId.isEmpty) return;
    await _functions.httpsCallable('unsaveSocialPost_v1').call({
      'postId': safePostId,
    });
  }

  Future<void> deletePost(SocialPostModel post) async {
    final uid = _myUid;
    if (post.ownerId.trim() != uid) {
      throw StateError('Only the owner can delete this post.');
    }
    await _functions.httpsCallable('deleteSocialPost_v1').call({
      'postId': post.postId,
    });
  }

  Future<void> addComment({
    required String postId,
    required String text,
  }) async {
    final safePostId = postId.trim();
    if (safePostId.isEmpty) return;
    final safeText = text.trim();
    if (safeText.isEmpty) return;
    await _functions.httpsCallable('addSocialPostComment_v1').call({
      'postId': safePostId,
      'text': safeText,
    });
  }

  Future<void> deleteComment({
    required String postId,
    required String commentId,
  }) async {
    final safePostId = postId.trim();
    final safeCommentId = commentId.trim();
    if (safePostId.isEmpty || safeCommentId.isEmpty) return;
    await _functions.httpsCallable('deleteSocialPostComment_v1').call({
      'postId': safePostId,
      'commentId': safeCommentId,
    });
  }

  Future<void> reportPost({
    required String postId,
    required String reason,
  }) async {
    final safePostId = postId.trim();
    final safeReason = reason.trim();
    if (safePostId.isEmpty || safeReason.isEmpty) return;
    await _functions.httpsCallable('reportSocialPost_v1').call({
      'postId': safePostId,
      'reason': safeReason,
    });
  }

  Future<void> reportComment({
    required String postId,
    required String commentId,
    required String reason,
  }) async {
    final safePostId = postId.trim();
    final safeCommentId = commentId.trim();
    final safeReason = reason.trim();
    if (safePostId.isEmpty || safeCommentId.isEmpty || safeReason.isEmpty) {
      return;
    }
    await _functions.httpsCallable('reportSocialPostComment_v1').call({
      'postId': safePostId,
      'commentId': safeCommentId,
      'reason': safeReason,
    });
  }

  Stream<List<SocialNotificationModel>> watchNotifications({int limit = 60}) {
    final uid = _auth.currentUser?.uid.trim() ?? '';
    if (uid.isEmpty) {
      return Stream<List<SocialNotificationModel>>.value(
        const <SocialNotificationModel>[],
      ).asBroadcastStream();
    }
    final safeLimit = limit < 1 ? 1 : limit;
    return _notifications(uid)
        .orderBy('createdAtMs', descending: true)
        .limit(safeLimit)
        .snapshots()
        .map((query) => query.docs
            .map((doc) => SocialNotificationModel.fromMap(
                  doc.data(),
                  fallbackId: doc.id,
                ))
            .whereType<SocialNotificationModel>()
            .toList(growable: false));
  }

  Stream<int> watchUnreadNotificationCount({int limit = 99}) {
    final uid = _auth.currentUser?.uid.trim() ?? '';
    if (uid.isEmpty) return Stream<int>.value(0).asBroadcastStream();
    final safeLimit = limit < 1 ? 1 : limit;
    return _notifications(uid)
        .where('read', isEqualTo: false)
        .limit(safeLimit)
        .snapshots()
        .map((query) => query.docs.length);
  }

  Future<void> markNotificationRead(String notificationId) async {
    final safeId = notificationId.trim();
    if (safeId.isEmpty) return;
    await _functions.httpsCallable('markNotificationRead_v1').call({
      'notificationId': safeId,
    });
  }

  Future<void> deleteNotification(String notificationId) async {
    final safeId = notificationId.trim();
    if (safeId.isEmpty) return;
    await _functions.httpsCallable('deleteNotification_v1').call({
      'notificationId': safeId,
    });
  }

  Future<void> markAllNotificationsRead({int limit = 100}) async {
    final safeLimit = limit < 1 ? 1 : limit;
    await _functions.httpsCallable('markAllNotificationsRead_v1').call({
      'limit': safeLimit,
    });
  }

  Future<void> _callSocialAction(
    String functionName, {
    required String postId,
  }) async {
    final safePostId = postId.trim();
    if (safePostId.isEmpty) return;
    await _functions.httpsCallable(functionName).call({
      'postId': safePostId,
    });
  }

  List<SocialPostModel> _postsFromQuery(
    QuerySnapshot<Map<String, dynamic>> query,
  ) {
    final out = <SocialPostModel>[];
    for (final doc in query.docs) {
      final post = SocialPostModel.fromMap(doc.data(), fallbackId: doc.id);
      if (post == null) continue;
      out.add(post);
    }
    return out;
  }
}

class SocialNotificationModel {
  const SocialNotificationModel({
    required this.notificationId,
    required this.type,
    required this.actorId,
    required this.actorName,
    required this.actorPhotoURL,
    required this.postId,
    required this.postImageURL,
    required this.text,
    required this.read,
    required this.createdAtMs,
  });

  final String notificationId;
  final String type;
  final String actorId;
  final String actorName;
  final String actorPhotoURL;
  final String postId;
  final String postImageURL;
  final String text;
  final bool read;
  final int createdAtMs;

  bool get opensPost {
    final safeType = type.trim();
    return postId.trim().isNotEmpty &&
        (safeType == 'post_like' ||
            safeType == 'post_comment' ||
            safeType == 'post_share' ||
            safeType == 'moderation_report_reviewed');
  }

  bool get opensWallet =>
      type == 'withdrawal_request_approved' ||
      type == 'withdrawal_request_rejected';

  bool get opensProfile =>
      type == 'account_blocked_by_admin' ||
      type == 'account_unblocked_by_admin' ||
      type == 'account_deletion_request_reviewed';

  bool get hasAction => opensPost || opensWallet || opensProfile;

  String get title {
    final name = actorName.trim().isEmpty ? 'Someone' : actorName.trim();
    switch (type) {
      case 'post_like':
        return '$name liked your post';
      case 'post_comment':
        return '$name commented on your post';
      case 'post_share':
        return '$name shared your post';
      case 'withdrawal_request_approved':
        return 'Withdrawal request approved';
      case 'withdrawal_request_rejected':
        return 'Withdrawal request rejected';
      case 'account_blocked_by_admin':
        return 'Account restricted';
      case 'account_unblocked_by_admin':
        return 'Account restriction lifted';
      case 'moderation_report_reviewed':
        return 'Your report was reviewed';
      case 'moderation_content_removed':
        return 'Content removed by moderation';
      case 'account_deletion_request_reviewed':
        return 'Delete-account request reviewed';
      default:
        return 'Friendify update';
    }
  }

  String get ageLabel {
    if (createdAtMs <= 0) return 'Just now';
    final elapsed = DateTime.now().millisecondsSinceEpoch - createdAtMs;
    if (elapsed < const Duration(minutes: 1).inMilliseconds) {
      return 'Just now';
    }
    if (elapsed < const Duration(hours: 1).inMilliseconds) {
      final minutes = (elapsed / const Duration(minutes: 1).inMilliseconds)
          .floor()
          .clamp(1, 59);
      return '${minutes}m ago';
    }
    if (elapsed < const Duration(days: 1).inMilliseconds) {
      final hours = (elapsed / const Duration(hours: 1).inMilliseconds)
          .floor()
          .clamp(1, 23);
      return '${hours}h ago';
    }
    final days =
        (elapsed / const Duration(days: 1).inMilliseconds).floor().clamp(1, 99);
    return '${days}d ago';
  }

  static SocialNotificationModel? fromMap(
    Map<String, dynamic> data, {
    required String fallbackId,
  }) {
    String string(Object? value) => value is String ? value.trim() : '';
    int integer(Object? value) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      return int.tryParse(value?.toString() ?? '') ?? 0;
    }

    final notificationId = string(data['notificationId']);
    final type = string(data['type']);
    if (type.isEmpty) return null;
    return SocialNotificationModel(
      notificationId: notificationId.isNotEmpty ? notificationId : fallbackId,
      type: type,
      actorId: string(data['actorId']),
      actorName: string(data['actorName']),
      actorPhotoURL: string(data['actorPhotoURL']),
      postId: string(data['postId']),
      postImageURL: string(data['postImageURL']),
      text: string(data['text']),
      read: data['read'] == true,
      createdAtMs: integer(data['createdAtMs']),
    );
  }
}

class SocialCommentModel {
  const SocialCommentModel({
    required this.commentId,
    required this.uid,
    required this.displayName,
    required this.photoURL,
    required this.text,
    required this.createdAtMs,
  });

  final String commentId;
  final String uid;
  final String displayName;
  final String photoURL;
  final String text;
  final int createdAtMs;

  factory SocialCommentModel.local(String text) {
    return SocialCommentModel(
      commentId: 'local_${DateTime.now().microsecondsSinceEpoch}',
      uid: '',
      displayName: 'You',
      photoURL: '',
      text: text,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  static SocialCommentModel? fromMap(
    Map<String, dynamic> data, {
    required String fallbackId,
  }) {
    final commentId = _string(data['commentId']);
    final displayName = _string(data['displayName']);
    final text = _string(data['text']);
    if (text.isEmpty) return null;
    return SocialCommentModel(
      commentId: commentId.isNotEmpty ? commentId : fallbackId,
      uid: _string(data['uid']),
      displayName: displayName.isNotEmpty ? displayName : 'Friend',
      photoURL: _string(data['photoURL']),
      text: text,
      createdAtMs: (data['createdAtMs'] as num?)?.toInt() ?? 0,
    );
  }

  static String _string(Object? value) {
    return value is String ? value.trim() : '';
  }
}
