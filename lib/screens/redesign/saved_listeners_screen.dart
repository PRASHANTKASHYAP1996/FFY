import 'package:flutter/material.dart';

import '../../core/theme/app_palette.dart';
import '../../repositories/user_repository.dart';
import '../../shared/models/app_user_model.dart';
import '../listener_profile_screen.dart';

/// The people you've saved (favourited). Open one to message or call, or
/// remove it from your saved list.
class SavedListenersScreen extends StatefulWidget {
  const SavedListenersScreen({super.key});

  @override
  State<SavedListenersScreen> createState() => _SavedListenersScreenState();
}

class _SavedListenersScreenState extends State<SavedListenersScreen> {
  final Stream<AppUserModel?> _me = UserRepository.instance.watchMe();
  final Map<String, Future<AppUserModel?>> _userFutures =
      <String, Future<AppUserModel?>>{};
  final Set<String> _working = <String>{};

  Future<AppUserModel?> _resolve(String uid) => _userFutures.putIfAbsent(
        uid,
        () => UserRepository.instance.getUser(uid),
      );

  Future<void> _remove(String uid) async {
    if (_working.contains(uid)) return;
    setState(() => _working.add(uid));
    try {
      await UserRepository.instance
          .toggleFavoriteListener(listenerId: uid, isFavoriteNow: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Removed from saved.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not update. Please try again.')),
      );
    } finally {
      if (mounted) setState(() => _working.remove(uid));
    }
  }

  void _openProfile(AppUserModel user) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ListenerProfileScreen(
          listenerId: user.uid,
          initialUser: user,
        ),
      ),
    );
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
        title: const Text('Saved listeners'),
      ),
      body: StreamBuilder<AppUserModel?>(
        stream: _me,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting &&
              !snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final saved = (snap.data?.favoriteListeners ?? const <String>[])
              .where((id) => id.trim().isNotEmpty)
              .toList(growable: false);
          if (saved.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(28),
                child: Text(
                  "You haven't saved anyone yet.\n"
                  'Tap the heart on a listener in Explore to save them here.',
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
            itemCount: saved.length,
            itemBuilder: (context, i) => _savedRow(saved[i]),
          );
        },
      ),
    );
  }

  Widget _savedRow(String uid) {
    final working = _working.contains(uid);
    return FutureBuilder<AppUserModel?>(
      future: _resolve(uid),
      builder: (context, snap) {
        final user = snap.data;
        final name = user?.safeDisplayName ?? 'Friendify user';
        final photo = (user?.photoURL ?? '').trim();
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: AppPalette.cardDecoration(radius: 16),
          child: Row(
            children: [
              GestureDetector(
                onTap: user == null ? null : () => _openProfile(user),
                child: ClipOval(
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
              ),
              const SizedBox(width: 12),
              Expanded(
                child: GestureDetector(
                  onTap: user == null ? null : () => _openProfile(user),
                  behavior: HitTestBehavior.opaque,
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
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: working ? null : () => _remove(uid),
                child: Text(working ? 'Wait...' : 'Remove'),
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
