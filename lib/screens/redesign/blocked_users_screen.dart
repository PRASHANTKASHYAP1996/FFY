import 'package:flutter/material.dart';

import '../../core/theme/app_palette.dart';
import '../../repositories/user_repository.dart';
import '../../shared/models/app_user_model.dart';

/// Manage the people you've blocked: see who they are and unblock them.
/// This was previously only reachable from the retired home screen.
class BlockedUsersScreen extends StatefulWidget {
  const BlockedUsersScreen({super.key});

  @override
  State<BlockedUsersScreen> createState() => _BlockedUsersScreenState();
}

class _BlockedUsersScreenState extends State<BlockedUsersScreen> {
  final Stream<AppUserModel?> _me = UserRepository.instance.watchMe();
  final Map<String, AppUserModel?> _cache = <String, AppUserModel?>{};
  final Set<String> _working = <String>{};

  Future<AppUserModel?> _resolve(String uid) async {
    if (_cache.containsKey(uid)) return _cache[uid];
    final user = await UserRepository.instance.getUser(uid);
    _cache[uid] = user;
    return user;
  }

  Future<void> _unblock(String uid) async {
    if (_working.contains(uid)) return;
    setState(() => _working.add(uid));
    try {
      await UserRepository.instance.unblockUser(uid);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('User unblocked.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not unblock. Please try again.')),
      );
    } finally {
      if (mounted) setState(() => _working.remove(uid));
    }
  }

  String _initials(String name) {
    final safe = name.trim();
    return safe.isEmpty ? 'U' : safe[0].toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppPalette.pageBg,
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: AppPalette.textPrimary,
        surfaceTintColor: Colors.transparent,
        title: const Text('Blocked users'),
      ),
      body: StreamBuilder<AppUserModel?>(
        stream: _me,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting &&
              !snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final blocked = (snap.data?.blocked ?? const <String>[])
              .where((id) => id.trim().isNotEmpty)
              .toList(growable: false);
          if (blocked.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(28),
                child: Text(
                  'You have not blocked anyone.\n'
                  'People you block from chats or profiles will appear here.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppPalette.textSecondary,
                    fontWeight: FontWeight.w600,
                    height: 1.5,
                  ),
                ),
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 20),
            itemCount: blocked.length,
            itemBuilder: (context, i) => _blockedRow(blocked[i]),
          );
        },
      ),
    );
  }

  Widget _blockedRow(String uid) {
    final working = _working.contains(uid);
    return FutureBuilder<AppUserModel?>(
      future: _resolve(uid),
      initialData: _cache[uid],
      builder: (context, snap) {
        final name = snap.data?.safeDisplayName ?? 'Friendify user';
        final photo = (snap.data?.photoURL ?? '').trim();
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: AppPalette.cardDecoration(radius: 16),
          child: Row(
            children: [
              ClipOval(
                child: SizedBox(
                  width: 42,
                  height: 42,
                  child: photo.isEmpty
                      ? _initialsCircle(name)
                      : Image.network(
                          photo,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _initialsCircle(name),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppPalette.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: working ? null : () => _unblock(uid),
                child: Text(working ? 'Wait...' : 'Unblock'),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _initialsCircle(String name) {
    return Container(
      color: AppPalette.blueTint,
      alignment: Alignment.center,
      child: Text(
        _initials(name),
        style: const TextStyle(
          fontWeight: FontWeight.w700,
          color: AppPalette.blue,
        ),
      ),
    );
  }
}
