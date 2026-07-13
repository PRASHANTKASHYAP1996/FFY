import 'dart:async';

import 'package:flutter/material.dart';

import '../core/theme/app_palette.dart';
import '../repositories/social_repository.dart';
import 'post_detail_screen.dart';
import 'profile_screen.dart';
import 'wallet_details_screen.dart';

class NotificationsCenterScreen extends StatefulWidget {
  const NotificationsCenterScreen({super.key});

  @override
  State<NotificationsCenterScreen> createState() =>
      _NotificationsCenterScreenState();
}

class _NotificationsCenterScreenState extends State<NotificationsCenterScreen> {
  final SocialRepository _socialRepository = SocialRepository.instance;

  bool _markingAllRead = false;
  String _openingNotificationId = '';
  int _notificationsRetryToken = 0;
  final Set<String> _deletingNotificationIds = <String>{};

  void _showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  void _retryNotifications() {
    setState(() => _notificationsRetryToken++);
  }

  Future<void> _markAllRead() async {
    if (_markingAllRead) return;
    setState(() => _markingAllRead = true);
    try {
      await _socialRepository.markAllNotificationsRead();
      if (!mounted) return;
      _retryNotifications();
      _showSnack('Notifications marked as read.');
    } catch (_) {
      if (!mounted) return;
      _showSnack('Could not mark notifications read.');
    } finally {
      if (mounted) setState(() => _markingAllRead = false);
    }
  }

  Future<void> _openNotification(SocialNotificationModel item) async {
    if (_openingNotificationId.isNotEmpty ||
        _deletingNotificationIds.contains(item.notificationId)) {
      return;
    }
    setState(() => _openingNotificationId = item.notificationId);

    try {
      try {
        await _socialRepository.markNotificationRead(item.notificationId);
        if (mounted) _retryNotifications();
      } catch (_) {
        // Opening the target is more important than read-state bookkeeping.
      }

      if (item.opensWallet) {
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const WalletDetailsScreen()),
        );
        return;
      }

      if (item.opensProfile) {
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const ProfileScreen()),
        );
        return;
      }

      if (!item.opensPost) {
        if (!item.read) _showSnack('Notification marked as read.');
        return;
      }

      final postId = item.postId.trim();
      if (postId.isEmpty) return;

      final post = await _socialRepository.fetchPost(postId);
      if (!mounted) return;
      if (post == null) {
        try {
          await _socialRepository.deleteNotification(item.notificationId);
          if (mounted) _retryNotifications();
        } catch (_) {
          // The post is gone either way; keep the user-facing path quiet.
        }
        if (!mounted) return;
        _showSnack('That post is no longer available. Notification removed.');
        return;
      }

      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PostDetailScreen(initialPost: post),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      _showSnack('Could not open this notification. Please try again.');
    } finally {
      if (mounted) setState(() => _openingNotificationId = '');
    }
  }

  Future<void> _deleteNotification(SocialNotificationModel item) async {
    if (_deletingNotificationIds.contains(item.notificationId)) return;
    setState(() => _deletingNotificationIds.add(item.notificationId));
    try {
      await _socialRepository.deleteNotification(item.notificationId);
      if (!mounted) return;
      _retryNotifications();
      _showSnack('Notification dismissed.');
    } catch (_) {
      if (!mounted) return;
      _showSnack('Could not dismiss notification.');
    } finally {
      if (mounted) {
        setState(() => _deletingNotificationIds.remove(item.notificationId));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppPalette.pageBg,
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: AppPalette.card,
        foregroundColor: AppPalette.textPrimary,
        title: const Text(
          'Notifications',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
        actions: [
          StreamBuilder<int>(
            key: ValueKey<String>('unread_$_notificationsRetryToken'),
            stream: _socialRepository.watchUnreadNotificationCount(),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return IconButton(
                  tooltip: 'Retry notifications',
                  onPressed: _retryNotifications,
                  icon: const Icon(Icons.refresh_rounded),
                );
              }

              final unread = snapshot.data ?? 0;
              return TextButton(
                onPressed: unread == 0 || _markingAllRead ? null : _markAllRead,
                child: _markingAllRead
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        unread == 0 ? 'All read' : 'Mark read',
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
              );
            },
          ),
        ],
      ),
      body: DecoratedBox(
        decoration: const BoxDecoration(color: AppPalette.pageBg),
        child: StreamBuilder<List<SocialNotificationModel>>(
          key: ValueKey<String>('notifications_$_notificationsRetryToken'),
          stream: _socialRepository.watchNotifications(),
          builder: (context, snapshot) {
            final notifications =
                snapshot.data ?? const <SocialNotificationModel>[];
            if (snapshot.hasError && notifications.isEmpty) {
              return _notificationLoadError();
            }

            if (snapshot.connectionState == ConnectionState.waiting &&
                notifications.isEmpty) {
              return const Center(child: CircularProgressIndicator());
            }
            if (notifications.isEmpty) {
              return _emptyNotifications();
            }

            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
              itemCount: notifications.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final item = notifications[index];
                return Dismissible(
                  key: ValueKey<String>('notification_${item.notificationId}'),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: const Icon(
                      Icons.delete_outline_rounded,
                      color: AppPalette.textPrimary,
                    ),
                  ),
                  onDismissed: (_) => unawaited(_deleteNotification(item)),
                  child: _notificationTile(context, item),
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _notificationLoadError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: AppPalette.cardDecoration(radius: 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.notifications_off_outlined,
                color: Color(0xFFF59E0B),
                size: 36,
              ),
              const SizedBox(height: 12),
              const Text(
                'Notifications unavailable',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppPalette.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Your notification inbox could not sync. Check your connection and try again.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppPalette.textSecondary,
                  fontWeight: FontWeight.w800,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: _retryNotifications,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _emptyNotifications() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.notifications_none_rounded,
              color: AppPalette.textMuted,
              size: 42,
            ),
            const SizedBox(height: 12),
            const Text(
              'Likes, comments, follows, calls, and wallet updates will appear here.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppPalette.textSecondary,
                fontSize: 16,
                fontWeight: FontWeight.w800,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: _retryNotifications,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Refresh'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _notificationTile(
    BuildContext context,
    SocialNotificationModel item,
  ) {
    final name = item.actorName.trim().isEmpty ? 'F' : item.actorName.trim();
    final first = name[0].toUpperCase();
    final opening = _openingNotificationId == item.notificationId;
    final deleting = _deletingNotificationIds.contains(item.notificationId);
    final icon = _notificationIcon(item);
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: opening || deleting ? null : () => _openNotification(item),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: item.read ? AppPalette.feedBg : AppPalette.blueTint,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: item.read
                ? AppPalette.border
                : AppPalette.blue.withValues(alpha: 0.32),
          ),
        ),
        child: Row(
          children: [
            icon == null
                ? ClipOval(
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: item.actorPhotoURL.trim().isEmpty
                          ? _notificationAvatarFallback(first)
                          : Image.network(
                              item.actorPhotoURL,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) =>
                                  _notificationAvatarFallback(first),
                            ),
                    ),
                  )
                : _notificationIconAvatar(icon),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppPalette.textPrimary,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    item.ageLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppPalette.textMuted,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (item.text.trim().isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      item.text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppPalette.textSecondary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (item.postImageURL.trim().isNotEmpty) ...[
              const SizedBox(width: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.network(
                  item.postImageURL,
                  width: 48,
                  height: 48,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            ],
            if (item.hasAction && !opening && !deleting) ...[
              const SizedBox(width: 8),
              const Icon(
                Icons.chevron_right_rounded,
                color: AppPalette.textMuted,
                size: 24,
              ),
            ],
            if (!item.hasAction && !opening && !deleting) ...[
              const SizedBox(width: 10),
              Icon(
                Icons.done_rounded,
                color: item.read ? AppPalette.textMuted : AppPalette.blue,
                size: 20,
              ),
            ],
            if (opening || deleting) ...[
              const SizedBox(width: 10),
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ],
          ],
        ),
      ),
    );
  }

  IconData? _notificationIcon(SocialNotificationModel item) {
    switch (item.type) {
      case 'withdrawal_request_approved':
        return Icons.account_balance_wallet_outlined;
      case 'withdrawal_request_rejected':
        return Icons.money_off_rounded;
      case 'account_blocked_by_admin':
        return Icons.block_rounded;
      case 'account_unblocked_by_admin':
        return Icons.lock_open_rounded;
      case 'moderation_report_reviewed':
        return Icons.verified_user_outlined;
      case 'moderation_content_removed':
        return Icons.gpp_maybe_outlined;
      case 'account_deletion_request_reviewed':
        return Icons.manage_accounts_outlined;
      default:
        return null;
    }
  }

  Widget _notificationAvatarFallback(String first) {
    return Container(
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
    );
  }

  Widget _notificationIconAvatar(IconData icon) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: AppPalette.border,
        shape: BoxShape.circle,
        border: Border.all(
          color: AppPalette.divider,
        ),
      ),
      child: Icon(
        icon,
        color: AppPalette.blue,
        size: 22,
      ),
    );
  }
}
