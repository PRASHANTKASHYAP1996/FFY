import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../core/theme/app_palette.dart';
import '../repositories/social_repository.dart';
import '../shared/models/social_post_model.dart';
import '../shared/user_safety_actions.dart';

class StoryViewerScreen extends StatefulWidget {
  const StoryViewerScreen({
    super.key,
    required this.stories,
    this.initialIndex = 0,
  });

  final List<SocialPostModel> stories;
  final int initialIndex;

  @override
  State<StoryViewerScreen> createState() => _StoryViewerScreenState();
}

class _StoryViewerScreenState extends State<StoryViewerScreen>
    with SingleTickerProviderStateMixin {
  final SocialRepository _socialRepository = SocialRepository.instance;

  late int _index;
  late final AnimationController _progress;
  bool _actionBusy = false;

  List<SocialPostModel> get _stories => widget.stories
      .where((story) => story.isActiveStory)
      .toList(growable: false);

  String get _myUid => FirebaseAuth.instance.currentUser?.uid.trim() ?? '';

  @override
  void initState() {
    super.initState();
    final maxIndex = widget.stories.isEmpty ? 0 : widget.stories.length - 1;
    _index = widget.initialIndex.clamp(0, maxIndex).toInt();
    _progress = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    )..addStatusListener((status) {
        if (status == AnimationStatus.completed) _next();
      });
    unawaited(_progress.forward(from: 0));
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  void _next() {
    final stories = _stories;
    if (stories.isEmpty) {
      Navigator.of(context).maybePop();
      return;
    }
    if (_index >= stories.length - 1) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() => _index += 1);
    unawaited(_progress.forward(from: 0));
  }

  void _previous() {
    if (_index <= 0) {
      unawaited(_progress.forward(from: 0));
      return;
    }
    setState(() => _index -= 1);
    unawaited(_progress.forward(from: 0));
  }

  void _showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  Future<void> _deleteStory(SocialPostModel story) async {
    if (_actionBusy) return;
    _progress.stop();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete story?'),
        content: const Text('This removes the story from Friendify.'),
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
    if (!mounted) return;
    if (confirmed != true) {
      unawaited(_progress.forward());
      return;
    }

    setState(() => _actionBusy = true);
    try {
      await _socialRepository.deletePost(story);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      _showSnack('Story delete failed. Please try again.');
      unawaited(_progress.forward());
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  Future<void> _reportStory(SocialPostModel story) async {
    if (_actionBusy) return;
    _progress.stop();
    final reason = await showUserSafetyReportReasonSheet(
      context,
      title: 'Report story',
    );
    if (!mounted) return;
    if (reason == null || reason.trim().isEmpty) {
      unawaited(_progress.forward());
      return;
    }

    setState(() => _actionBusy = true);
    try {
      await _socialRepository.reportPost(
        postId: story.postId,
        reason: reason,
      );
      if (!mounted) return;
      _showSnack('Report submitted. Our team will review it.');
      unawaited(_progress.forward());
    } catch (_) {
      if (!mounted) return;
      _showSnack('Story report failed. Please try again.');
      unawaited(_progress.forward());
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final stories = _stories;
    if (stories.isEmpty) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Text(
            'Story expired',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900),
          ),
        ),
      );
    }

    final index = _index.clamp(0, stories.length - 1).toInt();
    final story = stories[index];
    final isOwner = story.ownerId == _myUid;
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onVerticalDragEnd: (details) {
          if ((details.primaryVelocity ?? 0) > 240) {
            Navigator.of(context).maybePop();
          }
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.network(
              story.imageURL,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => Container(
                decoration: const BoxDecoration(
                  color: AppPalette.blue,
                ),
                alignment: Alignment.center,
                child: const Icon(
                  Icons.broken_image_outlined,
                  color: Colors.white,
                  size: 48,
                ),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _previous,
                  ),
                ),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _next,
                  ),
                ),
              ],
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: List.generate(stories.length, (barIndex) {
                        return Expanded(
                          child: Padding(
                            padding: EdgeInsets.only(
                              right: barIndex == stories.length - 1 ? 0 : 4,
                            ),
                            child: AnimatedBuilder(
                              animation: _progress,
                              builder: (_, __) {
                                final value = barIndex < index
                                    ? 1.0
                                    : barIndex == index
                                        ? _progress.value
                                        : 0.0;
                                return LinearProgressIndicator(
                                  value: value,
                                  minHeight: 3,
                                  backgroundColor:
                                      Colors.white.withValues(alpha: 0.25),
                                  valueColor:
                                      const AlwaysStoppedAnimation<Color>(
                                    Colors.white,
                                  ),
                                );
                              },
                            ),
                          ),
                        );
                      }),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        ClipOval(
                          child: SizedBox(
                            width: 38,
                            height: 38,
                            child: story.ownerPhotoURL.trim().isEmpty
                                ? Container(
                                    decoration: const BoxDecoration(
                                      color: AppPalette.blue,
                                    ),
                                    alignment: Alignment.center,
                                    child: Text(
                                      story.ownerName.trim().isEmpty
                                          ? 'F'
                                          : story.ownerName
                                              .trim()[0]
                                              .toUpperCase(),
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                  )
                                : Image.network(
                                    story.ownerPhotoURL,
                                    fit: BoxFit.cover,
                                  ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            story.ownerName.trim().isEmpty
                                ? 'Friendify user'
                                : story.ownerName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        if (_actionBusy)
                          const Padding(
                            padding: EdgeInsets.all(14),
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            ),
                          )
                        else
                          PopupMenuButton<String>(
                            tooltip: 'Story options',
                            icon: const Icon(
                              Icons.more_vert_rounded,
                              color: Colors.white,
                            ),
                            color: const Color(0xFF1F2430),
                            onSelected: (value) {
                              if (value == 'delete') {
                                unawaited(_deleteStory(story));
                              } else if (value == 'report') {
                                unawaited(_reportStory(story));
                              }
                            },
                            itemBuilder: (_) => [
                              if (isOwner)
                                const PopupMenuItem(
                                  value: 'delete',
                                  child: Text(
                                    'Delete story',
                                    style: TextStyle(
                                      color: Colors.white,
                                    ),
                                  ),
                                )
                              else
                                const PopupMenuItem(
                                  value: 'report',
                                  child: Text(
                                    'Report story',
                                    style: TextStyle(
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        IconButton(
                          onPressed: () => Navigator.of(context).maybePop(),
                          icon: const Icon(Icons.close_rounded),
                          color: Colors.white,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
