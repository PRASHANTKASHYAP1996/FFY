import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme/app_palette.dart';
import '../repositories/social_repository.dart';
import '../shared/models/social_post_model.dart';
import '../shared/user_safety_actions.dart';
import 'listener_profile_screen.dart';
import 'profile_screen.dart';

class PostDetailScreen extends StatefulWidget {
  const PostDetailScreen({
    super.key,
    required this.initialPost,
  });

  final SocialPostModel initialPost;

  @override
  State<PostDetailScreen> createState() => _PostDetailScreenState();
}

class _PostDetailScreenState extends State<PostDetailScreen> {
  final SocialRepository _socialRepository = SocialRepository.instance;
  final TextEditingController _commentController = TextEditingController();
  final FocusNode _commentFocusNode = FocusNode();
  final Set<String> _liked = <String>{};
  final Set<String> _saved = <String>{};
  final Map<String, int> _shareDelta = <String, int>{};
  final Map<String, List<String>> _localComments = <String, List<String>>{};

  bool _deleting = false;

  String get _myUid => FirebaseAuth.instance.currentUser?.uid.trim() ?? '';

  @override
  void dispose() {
    _commentController.dispose();
    _commentFocusNode.dispose();
    super.dispose();
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _ignore(Future<void> action, {VoidCallback? onFailure}) async {
    try {
      await action;
    } catch (_) {
      if (mounted) onFailure?.call();
    }
  }

  void _toggleLike(SocialPostModel post, {required bool liked}) {
    setState(() {
      if (liked) {
        _liked.remove(post.postId);
      } else {
        _liked.add(post.postId);
      }
    });
    unawaited(_ignore(
      liked
          ? _socialRepository.unlikePost(post.postId)
          : _socialRepository.likePost(post.postId),
      onFailure: () {
        if (!mounted) return;
        setState(() {
          if (liked) {
            _liked.add(post.postId);
          } else {
            _liked.remove(post.postId);
          }
        });
        _showSnack('Like update failed.');
      },
    ));
  }

  void _toggleSave(SocialPostModel post, {required bool saved}) {
    setState(() {
      if (saved) {
        _saved.remove(post.postId);
      } else {
        _saved.add(post.postId);
      }
    });
    unawaited(_ignore(
      saved
          ? _socialRepository.unsavePost(post.postId)
          : _socialRepository.savePost(post.postId),
      onFailure: () {
        if (!mounted) return;
        setState(() {
          if (saved) {
            _saved.add(post.postId);
          } else {
            _saved.remove(post.postId);
          }
        });
        _showSnack('Save update failed.');
      },
    ));
  }

  Future<void> _sharePost(SocialPostModel post) async {
    await Clipboard.setData(
      ClipboardData(text: '${post.ownerName} on Friendify\n${post.caption}'),
    );
    if (!mounted) return;
    setState(
        () => _shareDelta[post.postId] = (_shareDelta[post.postId] ?? 0) + 1);
    unawaited(_ignore(
      _socialRepository.sharePost(post.postId),
      onFailure: () {
        if (!mounted) return;
        final current = _shareDelta[post.postId] ?? 0;
        setState(() {
          if (current <= 1) {
            _shareDelta.remove(post.postId);
          } else {
            _shareDelta[post.postId] = current - 1;
          }
        });
      },
    ));
    _showSnack('Post copied. Share it anywhere.');
  }

  void _addComment(SocialPostModel post) {
    final text = _commentController.text.trim();
    if (text.isEmpty) return;
    _commentController.clear();
    setState(() {
      _localComments.putIfAbsent(post.postId, () => <String>[]).add(text);
    });
    unawaited(_submitComment(post, text));
  }

  void _removeLocalComment(String postId, String text) {
    if (!mounted) return;
    setState(() {
      final comments = _localComments[postId];
      comments?.remove(text);
      if (comments != null && comments.isEmpty) {
        _localComments.remove(postId);
      }
    });
  }

  Future<void> _deleteComment({
    required SocialPostModel post,
    required SocialCommentModel comment,
  }) async {
    if (comment.commentId.startsWith('local_')) {
      _removeLocalComment(post.postId, comment.text);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete comment?'),
        content: const Text('This removes the comment from the post.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await _socialRepository.deleteComment(
        postId: post.postId,
        commentId: comment.commentId,
      );
      _showSnack('Comment deleted.');
    } catch (_) {
      _showSnack('Could not delete comment. Please try again.');
    }
  }

  Future<void> _reportComment({
    required SocialPostModel post,
    required SocialCommentModel comment,
  }) async {
    final reason = await showUserSafetyReportReasonSheet(
      context,
      title: 'Report comment',
    );
    if (reason == null || reason.trim().isEmpty || !mounted) return;

    try {
      await _socialRepository.reportComment(
        postId: post.postId,
        commentId: comment.commentId,
        reason: reason,
      );
      _showSnack('Comment report submitted.');
    } catch (_) {
      _showSnack('Could not report comment. Please try again.');
    }
  }

  Future<void> _submitComment(SocialPostModel post, String text) async {
    try {
      await _socialRepository.addComment(postId: post.postId, text: text);
      _removeLocalComment(post.postId, text);
    } catch (_) {
      _removeLocalComment(post.postId, text);
      _showSnack('Comment failed.');
    }
  }

  Future<void> _deletePost(SocialPostModel post) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete post?'),
        content:
            const Text('This removes the post from your profile and feed.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _deleting = true);
    try {
      await _socialRepository.deletePost(post);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() => _deleting = false);
      _showSnack('Delete failed. Please try again.');
    }
  }

  Future<void> _reportPost(SocialPostModel post) async {
    final reason = await showUserSafetyReportReasonSheet(
      context,
      title: 'Report post',
    );
    if (reason == null || reason.trim().isEmpty) return;
    try {
      await _socialRepository.reportPost(
        postId: post.postId,
        reason: reason,
      );
      _showSnack('Report submitted. Our team will review it.');
    } catch (_) {
      _showSnack('Report failed. Please try again.');
    }
  }

  void _openOwner(SocialPostModel post) {
    if (post.ownerId == _myUid) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const ProfileScreen()),
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ListenerProfileScreen(listenerId: post.ownerId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<SocialPostModel?>(
      stream: _socialRepository.watchPost(widget.initialPost.postId),
      initialData: widget.initialPost,
      builder: (context, snapshot) {
        final post = snapshot.data;
        if (post == null) {
          return _missingPostScaffold();
        }
        final isOwner = post.ownerId == _myUid;
        return Scaffold(
          backgroundColor: AppPalette.pageBg,
          appBar: AppBar(
            elevation: 0,
            scrolledUnderElevation: 0,
            backgroundColor: AppPalette.card,
            foregroundColor: AppPalette.textPrimary,
            title: const Text(
              'Post',
              style: TextStyle(fontWeight: FontWeight.w900),
            ),
            actions: [
              if (_deleting)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'delete') {
                      unawaited(_deletePost(post));
                    } else if (value == 'report') {
                      unawaited(_reportPost(post));
                    }
                  },
                  itemBuilder: (_) => [
                    if (isOwner)
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete post'),
                      )
                    else
                      const PopupMenuItem(
                        value: 'report',
                        child: Text('Report post'),
                      ),
                  ],
                ),
            ],
          ),
          body: DecoratedBox(
            decoration: const BoxDecoration(color: AppPalette.pageBg),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(0, 14, 0, 24),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: _ownerRow(post),
                ),
                const SizedBox(height: 12),
                GestureDetector(
                  onDoubleTap: () => _toggleLike(post, liked: false),
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: Image.network(
                      post.imageURL,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        decoration: const BoxDecoration(
                          color: AppPalette.blue,
                        ),
                        alignment: Alignment.center,
                        child: const Icon(
                          Icons.image_not_supported_outlined,
                          color: Colors.white,
                          size: 48,
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                  child: _engagement(post),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: RichText(
                    text: TextSpan(
                      style: const TextStyle(
                        color: AppPalette.textPrimary,
                        fontSize: 15,
                        height: 1.35,
                      ),
                      children: [
                        TextSpan(
                          text: '${post.ownerName} ',
                          style: const TextStyle(fontWeight: FontWeight.w900),
                        ),
                        TextSpan(text: post.caption),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                _comments(post),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _missingPostScaffold() {
    return Scaffold(
      backgroundColor: AppPalette.pageBg,
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: AppPalette.card,
        foregroundColor: AppPalette.textPrimary,
        title: const Text(
          'Post',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: DecoratedBox(
        decoration: const BoxDecoration(color: AppPalette.pageBg),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 70,
                  height: 70,
                  decoration: BoxDecoration(
                    color: AppPalette.feedBg,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: AppPalette.border,
                    ),
                  ),
                  child: const Icon(
                    Icons.image_not_supported_outlined,
                    color: AppPalette.textSecondary,
                    size: 34,
                  ),
                ),
                const SizedBox(height: 18),
                const Text(
                  'This post is no longer available.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppPalette.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'It may have been deleted by the creator.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppPalette.textSecondary,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 18),
                FilledButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text('Go back'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _ownerRow(SocialPostModel post) {
    final first = post.ownerName.trim().isEmpty
        ? 'F'
        : post.ownerName.trim()[0].toUpperCase();
    return Row(
      children: [
        InkWell(
          onTap: () => _openOwner(post),
          borderRadius: BorderRadius.circular(999),
          child: ClipOval(
            child: SizedBox(
              width: 42,
              height: 42,
              child: post.ownerPhotoURL.trim().isEmpty
                  ? Container(
                      decoration: const BoxDecoration(
                        color: AppPalette.blue,
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        first,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    )
                  : Image.network(
                      post.ownerPhotoURL,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        decoration: const BoxDecoration(
                          color: AppPalette.blue,
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          first,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: InkWell(
            onTap: () => _openOwner(post),
            child: Text(
              post.ownerName.trim().isEmpty ? 'Friendify user' : post.ownerName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppPalette.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _engagement(SocialPostModel post) {
    return StreamBuilder<bool>(
      stream: _socialRepository.watchPostLikedByMe(post.postId),
      initialData: _liked.contains(post.postId),
      builder: (context, likedSnap) {
        final serverLiked = likedSnap.data == true;
        final optimisticLiked = _liked.contains(post.postId) && !serverLiked;
        final liked = serverLiked || optimisticLiked;
        return StreamBuilder<bool>(
          stream: _socialRepository.watchPostSavedByMe(post.postId),
          initialData: _saved.contains(post.postId),
          builder: (context, savedSnap) {
            final serverSaved = savedSnap.data == true;
            final optimisticSaved =
                _saved.contains(post.postId) && !serverSaved;
            final saved = serverSaved || optimisticSaved;
            final localCommentCount = _localComments[post.postId]?.length ?? 0;
            final likeCount = post.likeCount + (optimisticLiked ? 1 : 0);
            final commentCount = post.commentCount + localCommentCount;
            final shareCount =
                post.shareCount + (_shareDelta[post.postId] ?? 0);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _actionIcon(
                      liked
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      onPressed: () => _toggleLike(post, liked: liked),
                      active: liked,
                    ),
                    _actionIcon(
                      Icons.chat_bubble_outline_rounded,
                      onPressed: () => _commentFocusNode.requestFocus(),
                    ),
                    _actionIcon(
                      Icons.send_rounded,
                      onPressed: () => unawaited(_sharePost(post)),
                    ),
                    const Spacer(),
                    _actionIcon(
                      saved
                          ? Icons.bookmark_rounded
                          : Icons.bookmark_border_rounded,
                      onPressed: () => _toggleSave(post, saved: saved),
                      active: saved,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '$likeCount likes  -  $commentCount comments'
                  '${shareCount > 0 ? '  -  $shareCount shares' : ''}',
                  style: const TextStyle(
                    color: AppPalette.textPrimary,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _actionIcon(
    IconData icon, {
    required VoidCallback onPressed,
    bool active = false,
  }) {
    return IconButton(
      onPressed: onPressed,
      icon: Icon(icon),
      color: active ? AppPalette.blue : AppPalette.textSecondary,
    );
  }

  Widget _comments(SocialPostModel post) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StreamBuilder<List<SocialCommentModel>>(
            stream: _socialRepository.watchComments(post.postId),
            initialData: const <SocialCommentModel>[],
            builder: (context, snapshot) {
              final remote = snapshot.data ?? const <SocialCommentModel>[];
              final local = (_localComments[post.postId] ?? const <String>[])
                  .map(SocialCommentModel.local);
              final comments = <SocialCommentModel>[...remote, ...local];
              if (comments.isEmpty) {
                return const Text(
                  'No comments yet.',
                  style: TextStyle(
                    color: AppPalette.textSecondary,
                    fontWeight: FontWeight.w700,
                  ),
                );
              }
              return Column(
                children: comments
                    .map((comment) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _commentRow(post, comment),
                        ))
                    .toList(growable: false),
              );
            },
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _commentController,
            focusNode: _commentFocusNode,
            minLines: 1,
            maxLines: 3,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _addComment(post),
            style: const TextStyle(color: AppPalette.textPrimary),
            decoration: InputDecoration(
              hintText: 'Add a comment...',
              hintStyle: const TextStyle(
                color: AppPalette.textMuted,
              ),
              suffixIcon: IconButton(
                onPressed: () => _addComment(post),
                icon: const Icon(Icons.send_rounded),
                color: AppPalette.blue,
              ),
              filled: true,
              fillColor: AppPalette.feedBg,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: const BorderSide(
                  color: AppPalette.border,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _commentRow(SocialPostModel post, SocialCommentModel comment) {
    final name = comment.displayName.trim().isEmpty
        ? 'Friend'
        : comment.displayName.trim();
    final first = name[0].toUpperCase();
    final canDelete = comment.commentId.startsWith('local_') ||
        comment.uid == _myUid ||
        post.ownerId == _myUid;
    final canReport = comment.uid.isNotEmpty &&
        comment.uid != _myUid &&
        !comment.commentId.startsWith('local_');
    final hasActions = canDelete || canReport;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipOval(
          child: SizedBox(
            width: 32,
            height: 32,
            child: comment.photoURL.trim().isEmpty
                ? Container(
                    decoration: const BoxDecoration(
                      color: AppPalette.blue,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      first,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  )
                : Image.network(
                    comment.photoURL,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      decoration: const BoxDecoration(
                        color: AppPalette.blue,
                      ),
                    ),
                  ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: RichText(
            text: TextSpan(
              style: const TextStyle(
                color: AppPalette.textPrimary,
                height: 1.32,
              ),
              children: [
                TextSpan(
                  text: '$name ',
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                TextSpan(text: comment.text),
              ],
            ),
          ),
        ),
        if (hasActions)
          PopupMenuButton<String>(
            tooltip: 'Comment actions',
            icon: const Icon(
              Icons.more_horiz_rounded,
              color: AppPalette.textMuted,
            ),
            color: AppPalette.card,
            onSelected: (value) {
              if (value == 'delete') {
                unawaited(_deleteComment(post: post, comment: comment));
              } else if (value == 'report') {
                unawaited(_reportComment(post: post, comment: comment));
              }
            },
            itemBuilder: (_) => [
              if (canDelete)
                const PopupMenuItem(
                  value: 'delete',
                  child: Text('Delete comment'),
                ),
              if (canReport)
                const PopupMenuItem(
                  value: 'report',
                  child: Text('Report comment'),
                ),
            ],
          ),
      ],
    );
  }
}
