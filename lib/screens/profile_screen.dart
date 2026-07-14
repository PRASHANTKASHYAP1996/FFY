import 'dart:async';
import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../core/constants/storage_paths.dart';
import '../core/theme/app_palette.dart';
import '../repositories/social_repository.dart';
import '../repositories/user_repository.dart';
import '../services/auth_scoped_subscriptions.dart';
import '../services/call_latency_tracker.dart';
import '../services/call_session_manager.dart';
import '../services/firestore_service.dart';
import '../services/notifications_service.dart';
import '../shared/models/app_user_model.dart';
import '../shared/models/social_post_model.dart';
import 'auth_screen.dart';
import 'help_support_screen.dart';
import 'legal_policy_screen.dart';
import 'post_detail_screen.dart';

enum _ProfileMenuAction {
  editProfile,
  editAccount,
  savedPosts,
  privacy,
  terms,
  refund,
  community,
  help,
  logout,
  deleteAccount,
}

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  static const int _maxProfilePhotoBytes = 5 * 1024 * 1024;

  final UserRepository _userRepository = UserRepository.instance;
  final SocialRepository _socialRepository = SocialRepository.instance;

  final TextEditingController _name = TextEditingController();
  final TextEditingController _bio = TextEditingController();
  final TextEditingController _topics = TextEditingController();
  final TextEditingController _languages = TextEditingController();
  final TextEditingController _city = TextEditingController();
  final TextEditingController _state = TextEditingController();
  final TextEditingController _country = TextEditingController();

  String _selectedGender = '';
  int _selectedRate = 5;

  final FirebaseFunctions _functions = FirebaseFunctions.instance;

  bool _saving = false;
  bool _initialized = false;
  bool _deleteRequestBusy = false;
  bool _signingOut = false;
  int _profileRetryToken = 0;

  @override
  void dispose() {
    _name.dispose();
    _bio.dispose();
    _topics.dispose();
    _languages.dispose();
    _city.dispose();
    _state.dispose();
    _country.dispose();
    super.dispose();
  }

  // Tappable presets, mirroring onboarding. Topic wording contains the
  // Discover mood keywords (lonely, stress, work, breakup, relationship,
  // listen) so picking them makes a listener match those moods.
  static const List<String> _suggestedTopics = <String>[
    'Loneliness',
    'Stress & anxiety',
    'Work & career',
    'Breakup',
    'Relationships',
    'Study & exams',
    'Family',
    'Just listening',
  ];

  static const List<String> _suggestedLanguages = <String>[
    'English',
    'Hindi',
    'Tamil',
    'Telugu',
    'Bengali',
    'Marathi',
    'Punjabi',
    'Kannada',
  ];

  List<String> _splitCsv(String value) {
    final seen = <String>{};
    final out = <String>[];

    for (final raw in value.split(',')) {
      final item = raw.trim();
      if (item.isEmpty) continue;

      final key = item.toLowerCase();
      if (seen.contains(key)) continue;

      seen.add(key);
      out.add(item);
    }

    return out;
  }

  bool _csvContains(TextEditingController c, String value) => _splitCsv(c.text)
      .any((item) => item.toLowerCase() == value.toLowerCase());

  void _toggleCsv(TextEditingController c, String value) {
    final items = _splitCsv(c.text);
    final idx =
        items.indexWhere((i) => i.toLowerCase() == value.toLowerCase());
    if (idx >= 0) {
      items.removeAt(idx);
    } else {
      items.add(value);
    }
    final text = items.join(', ');
    c.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    setState(() {});
  }

  Widget _suggestionChips(TextEditingController c, List<String> options) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 7,
        runSpacing: 7,
        children: options.map((option) {
          final selected = _csvContains(c, option);
          return InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: () => _toggleCsv(c, option),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: selected ? AppPalette.blue : AppPalette.blueTint,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    selected ? Icons.check_rounded : Icons.add_rounded,
                    size: 14,
                    color: selected ? Colors.white : AppPalette.blue,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    option,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: selected ? Colors.white : AppPalette.blue,
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Future<void> _validateProfilePhoto(XFile picked) async {
    final byteLength = await picked.length();
    if (byteLength <= 0) {
      throw StateError('That photo looks empty. Choose another image.');
    }
    if (byteLength >= _maxProfilePhotoBytes) {
      throw StateError('Photo is too large. Choose an image under 5 MB.');
    }

    if (!kIsWeb) {
      final file = File(picked.path);
      if (!await file.exists()) {
        throw StateError('Choose the photo again before uploading.');
      }
    }
  }

  void _fillControllersOnce(AppUserModel me) {
    if (_initialized) return;
    _initialized = true;

    _name.text = me.displayName.trim();
    _bio.text = me.bio.trim();
    _topics.text = me.topics.join(', ');
    _languages.text = me.languages.join(', ');
    _city.text = me.city.trim();
    _state.text = me.state.trim();
    _country.text = me.country.trim();
    _selectedGender = me.gender.trim();
    _selectedRate = me.listenerRate > 0 ? me.listenerRate : 5;
  }

  void _retryProfileLoad() {
    setState(() => _profileRetryToken++);
  }

  void _showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  bool _hasBlockingCallStateForSignOut() {
    if (CallLatencyTracker.hasPendingStarts) return true;

    final callSession = CallSessionManager.instance;
    if (callSession.active) return true;

    return switch (callSession.state) {
      CallState.preparing ||
      CallState.joining ||
      CallState.connected ||
      CallState.reconnecting ||
      CallState.ending =>
        true,
      CallState.idle || CallState.ended || CallState.failed => false,
    };
  }

  Future<void> _signOut() async {
    if (_signingOut) return;

    if (_hasBlockingCallStateForSignOut()) {
      debugPrint('auth.signout_blocked_call_active');
      _showSnack('End the current call before logging out.');
      return;
    }

    final oldUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    setState(() => _signingOut = true);

    try {
      await WidgetsBinding.instance.endOfFrame;
      await AuthScopedSubscriptions.instance.disposeForUid(oldUid);
      await NotificationsService.instance.detachCurrentTokenForSignOut();
      AuthScreen.clearNextFormOnOpen();
      await _userRepository.signOut();
    } catch (_) {
      if (!mounted) return;
      _showSnack('Logout failed. Please try again.');
      setState(() => _signingOut = false);
    }
  }

  void _showInfoSheet({
    required String title,
    required String body,
  }) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              8,
              16,
              MediaQuery.of(sheetContext).viewInsets.bottom + 20,
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF111827),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    body,
                    style: const TextStyle(
                      color: Color(0xFF374151),
                      fontWeight: FontWeight.w600,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      child: const Text('Close'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String _deletionErrorText(Object error) {
    if (error is FirebaseFunctionsException) {
      final message = (error.message ?? '').trim();
      if (message == 'app_check_failed' ||
          message == 'App Check token is required.') {
        return 'Account changes are temporarily paused. Please try again later.';
      }
      switch (error.code.trim()) {
        case 'unauthenticated':
          return 'Please log in again and retry.';
        case 'failed-precondition':
          return message.isNotEmpty
              ? message
              : 'Your account is not ready for a deletion request yet.';
        case 'permission-denied':
          return 'You are not allowed to submit this request.';
        default:
          return message.isNotEmpty
              ? message
              : 'Delete request failed. Please try again.';
      }
    }

    final raw = error.toString().trim();
    if (raw.isEmpty) {
      return 'Delete request failed. Please try again.';
    }
    return raw;
  }

  String _deleteAccountTitle(AppUserModel me) {
    if (_deleteRequestBusy) return 'Submitting request...';
    if (me.hasPendingAccountDeletionRequest) {
      return 'Delete request pending';
    }
    if (me.hasReviewedAccountDeletionRequest) {
      final outcome = me.accountDeletionRequestOutcome.trim().toLowerCase();
      if (outcome == 'completed') return 'Delete request completed';
      if (outcome == 'rejected') return 'Delete request reviewed';
    }
    return 'Delete Account Request';
  }

  String _deleteAccountSubtitle(AppUserModel me) {
    if (_deleteRequestBusy) return 'Submitting request...';
    if (me.hasPendingAccountDeletionRequest) {
      return 'Your request is waiting for admin review.';
    }
    if (me.hasReviewedAccountDeletionRequest) {
      final outcome = me.accountDeletionRequestOutcome.trim().toLowerCase();
      if (outcome == 'completed') {
        return 'Admin marked your request complete.';
      }
      if (outcome == 'rejected') {
        return 'Admin reviewed your request. Contact support if needed.';
      }
      return 'Your request was reviewed by admin.';
    }
    return 'Submit a request to delete your account.';
  }

  String _compactDateLabel(DateTime? value) {
    if (value == null) return '';
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${value.day} ${months[value.month - 1]} ${value.year}';
  }

  Widget _deleteAccountStatusPanel(AppUserModel me) {
    if (!me.hasPendingAccountDeletionRequest &&
        !me.hasReviewedAccountDeletionRequest) {
      return const SizedBox.shrink();
    }

    final outcome = me.accountDeletionRequestOutcome.trim().toLowerCase();
    final isPending = me.hasPendingAccountDeletionRequest;
    final isCompleted = outcome == 'completed';
    final accent = isPending
        ? const Color(0xFFF59E0B)
        : isCompleted
            ? AppPalette.online
            : AppPalette.blue;
    final icon = isPending
        ? Icons.hourglass_top_rounded
        : isCompleted
            ? Icons.check_circle_rounded
            : Icons.info_rounded;
    final dateLabel = isPending
        ? _compactDateLabel(me.accountDeletionRequestRequestedAt)
        : _compactDateLabel(me.accountDeletionRequestReviewedAt);
    final statusLabel = isPending
        ? 'Admin review pending'
        : isCompleted
            ? 'Completed by admin'
            : 'Reviewed by admin';
    final meta = dateLabel.isEmpty ? statusLabel : '$statusLabel - $dateLabel';

    return Container(
      decoration: BoxDecoration(
        color: AppPalette.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withValues(alpha: 0.36)),
      ),
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.16),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: accent, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _deleteAccountTitle(me),
                  style: const TextStyle(
                    color: AppPalette.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _deleteAccountSubtitle(me),
                  style: const TextStyle(
                    color: AppPalette.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    height: 1.22,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  meta,
                  style: TextStyle(
                    color: accent,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openDeleteRequestSheet() async {
    if (_deleteRequestBusy) return;

    final reasonController = TextEditingController();
    final noteController = TextEditingController();

    try {
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (sheetContext) {
          bool submitBusy = false;

          return StatefulBuilder(
            builder: (context, setSheetState) {
              Future<void> submit() async {
                if (submitBusy) return;

                final safeReason = reasonController.text.trim();
                final safeNote = noteController.text.trim();

                if (safeReason.isEmpty) {
                  ScaffoldMessenger.of(sheetContext).showSnackBar(
                    const SnackBar(
                      content: Text('Please add a short reason.'),
                    ),
                  );
                  return;
                }

                setState(() => _deleteRequestBusy = true);
                setSheetState(() => submitBusy = true);

                try {
                  final result = await _functions
                      .httpsCallable('requestAccountDeletion_v1')
                      .call({
                    'reason': safeReason,
                    'note': safeNote,
                  });

                  final data = result.data;
                  final map = data is Map
                      ? Map<String, dynamic>.from(data)
                      : <String, dynamic>{};
                  final alreadyPending = map['alreadyPending'] == true;

                  if (sheetContext.mounted) {
                    Navigator.of(sheetContext).pop();
                  }

                  _showInfoSheet(
                    title: alreadyPending
                        ? 'Delete request already pending'
                        : 'Delete request submitted',
                    body: alreadyPending
                        ? 'A delete-account request is already pending for this account.\n\nThis screen submits a request for review. Your account is not deleted instantly from the device.'
                        : 'Your delete-account request has been recorded.\n\nThis screen submits a request for review. Your account is not deleted instantly from the device.',
                  );
                } catch (error) {
                  _showSnack(_deletionErrorText(error));
                } finally {
                  if (mounted) {
                    setState(() => _deleteRequestBusy = false);
                  }
                  if (sheetContext.mounted) {
                    setSheetState(() => submitBusy = false);
                  }
                }
              }

              return Theme(
                data: _lightSheetTheme(sheetContext),
                child: SafeArea(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      8,
                      16,
                      MediaQuery.of(sheetContext).viewInsets.bottom + 20,
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Delete Account Request',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF111827),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFEF2F2),
                              borderRadius: BorderRadius.circular(16),
                              border:
                                  Border.all(color: const Color(0xFFFECACA)),
                            ),
                            child: const Text(
                              'This screen submits a delete-account request for review. It does not instantly delete your account from the device. Some records may be retained for payment, safety, fraud prevention, legal, or support reasons.',
                              style: TextStyle(
                                color: Color(0xFF7F1D1D),
                                fontWeight: FontWeight.w700,
                                height: 1.4,
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: reasonController,
                            enabled: !submitBusy,
                            maxLength: 120,
                            decoration: const InputDecoration(
                              labelText: 'Reason',
                              hintText:
                                  'Example: I no longer want to use the app',
                            ),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: noteController,
                            enabled: !submitBusy,
                            minLines: 3,
                            maxLines: 5,
                            maxLength: 500,
                            decoration: const InputDecoration(
                              labelText: 'Additional note (optional)',
                              hintText:
                                  'Add anything support/admin should know before processing the request.',
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton(
                                  onPressed: submitBusy
                                      ? null
                                      : () => Navigator.of(sheetContext).pop(),
                                  child: const Text('Cancel'),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: FilledButton(
                                  onPressed: submitBusy ? null : submit,
                                  child: Text(
                                    submitBusy
                                        ? 'Submitting...'
                                        : 'Submit Request',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        },
      );
    } finally {
      reasonController.dispose();
      noteController.dispose();
    }
  }

  Future<void> _saveAll() async {
    if (_saving) return;

    final safeName = _name.text.trim();
    final safeBio = _bio.text.trim();
    final topics = _splitCsv(_topics.text);
    final languages = _splitCsv(_languages.text);
    final safeGender = _selectedGender.trim();
    final safeCity = _city.text.trim();
    final safeState = _state.text.trim();
    final safeCountry = _country.text.trim();

    if (safeName.isEmpty) {
      _showSnack('Display name cannot be empty');
      return;
    }

    if (safeName.length > 40) {
      _showSnack('Display name is too long');
      return;
    }

    if (safeBio.length > 280) {
      _showSnack('Bio must be 280 characters or less');
      return;
    }

    setState(() => _saving = true);

    try {
      await _userRepository.updateProfile(
        displayName: safeName,
        bio: safeBio,
        gender: safeGender,
        city: safeCity,
        state: safeState,
        country: safeCountry,
        topics: topics,
        languages: languages,
      );

      await _userRepository.setListenerRate(_selectedRate);
      _showSnack('Profile updated');
    } catch (e) {
      _showSnack('Could not save your profile. Please try again.');
      if (kDebugMode) {
        debugPrint('Profile save failed: ${e.runtimeType}');
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _pickAndUploadPhoto() async {
    if (_saving) return;

    setState(() => _saving = true);

    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 80,
        maxWidth: 1024,
        maxHeight: 1024,
      );

      if (picked == null) {
        if (mounted) {
          setState(() => _saving = false);
        }
        return;
      }

      await _validateProfilePhoto(picked);

      final uid = FirestoreService.uid();
      final ref = FirebaseStorage.instance.ref().child(
            StoragePaths.profilePhoto(uid),
          );

      if (kIsWeb) {
        final bytes = await picked.readAsBytes();
        await ref.putData(
          bytes,
          SettableMetadata(contentType: 'image/jpeg'),
        );
      } else {
        await ref.putFile(
          File(picked.path),
          SettableMetadata(contentType: 'image/jpeg'),
        );
      }

      final url = await ref.getDownloadURL();
      await _userRepository.setPhotoUrl(url);

      _showSnack('Photo updated');
    } on StateError catch (e) {
      _showSnack(e.message);
    } catch (e) {
      _showSnack('Could not upload your photo. Please try again.');
      if (kDebugMode) {
        debugPrint('Profile photo upload failed: ${e.runtimeType}');
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _removePhoto() async {
    if (_saving) return;

    setState(() => _saving = true);

    try {
      await _userRepository.setPhotoUrl('');

      final uid = FirestoreService.uid();
      final ref = FirebaseStorage.instance.ref().child(
            StoragePaths.profilePhoto(uid),
          );

      try {
        await ref.delete();
      } catch (_) {
        // ignore if already missing
      }

      _showSnack('Photo removed');
    } catch (e) {
      _showSnack('Could not remove your photo. Please try again.');
      if (kDebugMode) {
        debugPrint('Profile photo remove failed: ${e.runtimeType}');
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Widget _avatar(String url, String name) {
    if (url.trim().isNotEmpty) {
      return CircleAvatar(
        radius: 42,
        backgroundImage: NetworkImage(url),
      );
    }

    final letter = name.trim().isNotEmpty ? name.trim()[0].toUpperCase() : 'U';

    return CircleAvatar(
      radius: 42,
      backgroundColor: AppPalette.blueTint,
      child: Text(
        letter,
        style: const TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w900,
          color: AppPalette.blue,
        ),
      ),
    );
  }

  // ignore: unused_element
  Widget _chipsFromList(List<String> items) {
    if (items.isEmpty) {
      return const Text(
        'Nothing added yet',
        style: TextStyle(
          color: AppPalette.textSecondary,
          fontWeight: FontWeight.w600,
        ),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: items
          .map(
            (e) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: AppPalette.blueTint,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: AppPalette.blueTint,
                ),
              ),
              child: Text(
                e,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  color: AppPalette.blue,
                ),
              ),
            ),
          )
          .toList(),
    );
  }

  String _displayName(AppUserModel me) {
    final safe = me.displayName.trim();
    if (safe.isNotEmpty) return safe;
    return 'Friendify User';
  }

  bool _missingProfileItemUsesAccountEditor(String label) {
    switch (label.trim().toLowerCase()) {
      case 'gender':
      case 'city':
      case 'state':
        return true;
      default:
        return false;
    }
  }

  Widget _progressChip(
    String label,
    bool done, {
    VoidCallback? onTap,
  }) {
    final bg =
        done ? AppPalette.online.withValues(alpha: 0.13) : AppPalette.feedBg;
    final fg = done ? AppPalette.online : AppPalette.textSecondary;

    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: fg.withValues(alpha: done ? 0.24 : 0.10),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: fg,
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 5),
            Icon(
              Icons.chevron_right_rounded,
              color: fg.withValues(alpha: 0.72),
              size: 16,
            ),
          ],
        ],
      ),
    );

    if (onTap == null) return chip;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: chip,
      ),
    );
  }

  Widget _missingProfileItemChip(AppUserModel me, String item) {
    final accountOnly = _missingProfileItemUsesAccountEditor(item);
    return _progressChip(
      item,
      false,
      onTap: () => _openProfileEditor(
        me,
        accountOnly: accountOnly,
      ),
    );
  }

  String _profileCompletionPrimaryActionLabel(List<String> missingItems) {
    if (missingItems.isEmpty) return 'Edit profile';
    final accountCount =
        missingItems.where(_missingProfileItemUsesAccountEditor).length;
    final profileCount = missingItems.length - accountCount;
    if (accountCount > profileCount) return 'Edit account details';
    return 'Edit profile';
  }

  bool _profileCompletionPrimaryActionUsesAccount(List<String> missingItems) {
    if (missingItems.isEmpty) return false;
    final accountCount =
        missingItems.where(_missingProfileItemUsesAccountEditor).length;
    final profileCount = missingItems.length - accountCount;
    return accountCount > profileCount;
  }

  String _profileCompletionHint(List<String> missingItems) {
    if (missingItems.isEmpty) {
      return 'Your profile has the main signals people need before chatting or calling.';
    }
    final accountCount =
        missingItems.where(_missingProfileItemUsesAccountEditor).length;
    final profileCount = missingItems.length - accountCount;
    if (profileCount > 0 && accountCount > 0) {
      return 'Tap a missing item below to jump to the right editor. Complete profiles rank better in discovery.';
    }
    if (accountCount > 0) {
      return 'Add your account details so people can understand location and profile context before they connect.';
    }
    return 'Add your profile details so people can decide before starting chat or call requests.';
  }

  Widget _profileCompletionActions({
    required AppUserModel me,
    required List<String> missingItems,
  }) {
    final primaryUsesAccount =
        _profileCompletionPrimaryActionUsesAccount(missingItems);
    final secondaryUsesAccount = !primaryUsesAccount;
    final secondaryLabel =
        secondaryUsesAccount ? 'Account details' : 'Profile details';
    final secondaryIcon = secondaryUsesAccount
        ? Icons.person_pin_circle_outlined
        : Icons.edit_rounded;

    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: () => _openProfileEditor(
              me,
              accountOnly: primaryUsesAccount,
            ),
            icon: Icon(
              primaryUsesAccount
                  ? Icons.person_pin_circle_outlined
                  : Icons.edit_rounded,
            ),
            label: Text(_profileCompletionPrimaryActionLabel(missingItems)),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => _openProfileEditor(
              me,
              accountOnly: secondaryUsesAccount,
            ),
            icon: Icon(secondaryIcon),
            label: Text(secondaryLabel),
          ),
        ),
      ],
    );
  }

  Widget _profileCompletionPanel({
    required AppUserModel me,
    required int completeness,
    required List<String> missingItems,
  }) {
    final safeCompleteness = completeness.clamp(0, 100);
    final completed = safeCompleteness >= 100;
    final progress = safeCompleteness / 100;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: completed
            ? AppPalette.online.withValues(alpha: 0.10)
            : AppPalette.blueTint,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: completed
              ? AppPalette.online.withValues(alpha: 0.28)
              : AppPalette.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  completed ? 'Profile ready' : 'Complete your profile',
                  style: const TextStyle(
                    color: AppPalette.textPrimary,
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
              ),
              Text(
                '$safeCompleteness%',
                style: TextStyle(
                  color: completed ? AppPalette.online : AppPalette.blue,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              backgroundColor: AppPalette.divider,
              valueColor: AlwaysStoppedAnimation<Color>(
                completed ? AppPalette.online : AppPalette.blue,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            _profileCompletionHint(missingItems),
            style: const TextStyle(
              color: AppPalette.textSecondary,
              fontWeight: FontWeight.w700,
              height: 1.35,
            ),
          ),
          if (missingItems.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: missingItems
                  .map((item) => _missingProfileItemChip(me, item))
                  .toList(growable: false),
            ),
            const SizedBox(height: 12),
            _profileCompletionActions(
              me: me,
              missingItems: missingItems,
            ),
          ],
        ],
      ),
    );
  }

  Widget _profileLoadError() {
    return Scaffold(
      backgroundColor: AppPalette.pageBg,
      body: DecoratedBox(
        decoration: const BoxDecoration(color: AppPalette.pageBg),
        child: Center(
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
                    Icons.sync_problem_rounded,
                    color: Color(0xFFF59E0B),
                    size: 34,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Profile unavailable',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppPalette.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Your profile could not sync. Check your connection and try again.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppPalette.textSecondary,
                      fontWeight: FontWeight.w700,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed: _retryProfileLoad,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _previewChip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: AppPalette.blueTint,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontWeight: FontWeight.w800,
          color: AppPalette.blue,
        ),
      ),
    );
  }

  Widget _sectionCard({
    required String title,
    String? subtitle,
    required Widget child,
  }) {
    return Container(
      decoration: AppPalette.cardDecoration(radius: 18),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w900,
                color: AppPalette.textPrimary,
              ),
            ),
            if (subtitle != null && subtitle.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: const TextStyle(
                  color: AppPalette.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }

  Widget _label(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontWeight: FontWeight.w900,
        color: AppPalette.textPrimary,
      ),
    );
  }

  // ignore: unused_element
  Widget _miniStat({
    required String label,
    required String value,
    Color? valueColor,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppPalette.feedBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppPalette.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: AppPalette.textSecondary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w900,
              color: valueColor ?? AppPalette.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _launchLinkTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    Color iconColor = const Color(0xFF4F46E5),
    Color iconBg = const Color(0xFFEEF2FF),
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: iconBg,
        child: Icon(icon, color: iconColor),
      ),
      title: Text(
        title,
        style: const TextStyle(
          fontWeight: FontWeight.w900,
          color: AppPalette.textPrimary,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(
          color: AppPalette.textSecondary,
          fontWeight: FontWeight.w600,
        ),
      ),
      trailing: const Icon(
        Icons.chevron_right_rounded,
        color: AppPalette.textMuted,
      ),
      onTap: onTap,
    );
  }

  // ignore: unused_element
  Widget _accountAndComplianceCard() {
    return _sectionCard(
      title: 'Account',
      subtitle: 'Manage your account and review support information.',
      child: Column(
        children: [
          _launchLinkTile(
            icon: Icons.privacy_tip_outlined,
            title: 'Privacy Policy',
            subtitle: 'Learn how Friendify handles your data.',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const LegalPolicyScreen(
                    kind: LegalPolicyKind.privacy,
                  ),
                ),
              );
            },
          ),
          const Divider(height: 1),
          _launchLinkTile(
            icon: Icons.description_outlined,
            title: 'Terms of Service',
            subtitle: 'Read the rules for using Friendify.',
            iconColor: const Color(0xFF374151),
            iconBg: const Color(0xFFF3F4F6),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const LegalPolicyScreen(
                    kind: LegalPolicyKind.terms,
                  ),
                ),
              );
            },
          ),
          const Divider(height: 1),
          _launchLinkTile(
            icon: Icons.receipt_long_outlined,
            title: 'Refund / Cancellation Policy',
            subtitle: 'See refund and cancellation details.',
            iconColor: const Color(0xFFD97706),
            iconBg: const Color(0xFFFFFBEB),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const LegalPolicyScreen(
                    kind: LegalPolicyKind.refund,
                  ),
                ),
              );
            },
          ),
          const Divider(height: 1),
          _launchLinkTile(
            icon: Icons.volunteer_activism_outlined,
            title: 'Community Guidelines',
            subtitle: 'Review safety and behavior expectations.',
            iconColor: const Color(0xFF7C3AED),
            iconBg: const Color(0xFFF5F3FF),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const LegalPolicyScreen(
                    kind: LegalPolicyKind.communityGuidelines,
                  ),
                ),
              );
            },
          ),
          const Divider(height: 1),
          _launchLinkTile(
            icon: Icons.support_agent_rounded,
            title: 'Help & Support',
            subtitle: 'Get help with account, payment, call, or abuse issues.',
            iconColor: const Color(0xFF15803D),
            iconBg: const Color(0xFFECFDF3),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const HelpSupportScreen(),
                ),
              );
            },
          ),
          const Divider(height: 1),
          _launchLinkTile(
            icon: Icons.logout_rounded,
            title: 'Logout Account',
            subtitle: _signingOut
                ? 'Logging out...'
                : 'Sign out from this device safely.',
            iconColor: const Color(0xFF7C3AED),
            iconBg: const Color(0xFFF5F3FF),
            onTap: _signingOut ? () {} : _signOut,
          ),
          const Divider(height: 1),
          _launchLinkTile(
            icon: Icons.delete_outline_rounded,
            title: _deleteRequestBusy
                ? 'Submitting request...'
                : 'Delete Account Request',
            subtitle: _deleteRequestBusy
                ? 'Submitting request...'
                : 'Submit a request to delete your account.',
            iconColor: const Color(0xFFDC2626),
            iconBg: const Color(0xFFFEF2F2),
            onTap: _deleteRequestBusy ? () {} : _openDeleteRequestSheet,
          ),
        ],
      ),
    );
  }

  Future<void> _handleProfileMenuAction(
    _ProfileMenuAction action,
    AppUserModel me,
  ) async {
    switch (action) {
      case _ProfileMenuAction.editProfile:
        _openProfileEditor(me, accountOnly: false);
        break;
      case _ProfileMenuAction.editAccount:
        _openProfileEditor(me, accountOnly: true);
        break;
      case _ProfileMenuAction.savedPosts:
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => const _SavedPostsScreen(),
          ),
        );
        break;
      case _ProfileMenuAction.privacy:
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => const LegalPolicyScreen(
              kind: LegalPolicyKind.privacy,
            ),
          ),
        );
        break;
      case _ProfileMenuAction.terms:
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => const LegalPolicyScreen(
              kind: LegalPolicyKind.terms,
            ),
          ),
        );
        break;
      case _ProfileMenuAction.refund:
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => const LegalPolicyScreen(
              kind: LegalPolicyKind.refund,
            ),
          ),
        );
        break;
      case _ProfileMenuAction.community:
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => const LegalPolicyScreen(
              kind: LegalPolicyKind.communityGuidelines,
            ),
          ),
        );
        break;
      case _ProfileMenuAction.help:
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => const HelpSupportScreen(),
          ),
        );
        break;
      case _ProfileMenuAction.logout:
        await _signOut();
        break;
      case _ProfileMenuAction.deleteAccount:
        if (!_deleteRequestBusy) {
          _openDeleteRequestSheet();
        }
        break;
    }
  }

  Widget _profileMenu(AppUserModel me) {
    return IconButton(
      tooltip: 'Profile menu',
      onPressed: () => _openProfileMenuSheet(me),
      icon: const Icon(Icons.menu_rounded, size: 30),
      color: AppPalette.textPrimary,
    );
  }

  void _openProfileMenuSheet(AppUserModel me) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AppPalette.card,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Profile menu',
                    style: TextStyle(
                      color: AppPalette.textPrimary,
                      fontSize: 21,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _profileMenuTile(
                    icon: Icons.edit_rounded,
                    title: 'Edit profile',
                    subtitle: 'Photo, name, bio, topics, and languages',
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      _handleProfileMenuAction(
                        _ProfileMenuAction.editProfile,
                        me,
                      );
                    },
                  ),
                  _profileMenuTile(
                    icon: Icons.manage_accounts_rounded,
                    title: 'Edit account details',
                    subtitle: 'Gender, location, and visible call rate',
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      _handleProfileMenuAction(
                        _ProfileMenuAction.editAccount,
                        me,
                      );
                    },
                  ),
                  _profileMenuTile(
                    icon: Icons.bookmark_rounded,
                    title: 'Saved posts',
                    subtitle: 'Posts you bookmarked from the feed',
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      _handleProfileMenuAction(
                        _ProfileMenuAction.savedPosts,
                        me,
                      );
                    },
                  ),
                  const Divider(height: 18, color: AppPalette.divider),
                  _profileMenuTile(
                    icon: Icons.privacy_tip_outlined,
                    title: 'Privacy Policy',
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      _handleProfileMenuAction(_ProfileMenuAction.privacy, me);
                    },
                  ),
                  _profileMenuTile(
                    icon: Icons.description_outlined,
                    title: 'Terms of Service',
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      _handleProfileMenuAction(_ProfileMenuAction.terms, me);
                    },
                  ),
                  _profileMenuTile(
                    icon: Icons.receipt_long_outlined,
                    title: 'Refund / Cancellation Policy',
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      _handleProfileMenuAction(_ProfileMenuAction.refund, me);
                    },
                  ),
                  _profileMenuTile(
                    icon: Icons.volunteer_activism_outlined,
                    title: 'Community Guidelines',
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      _handleProfileMenuAction(
                        _ProfileMenuAction.community,
                        me,
                      );
                    },
                  ),
                  _profileMenuTile(
                    icon: Icons.support_agent_rounded,
                    title: 'Help & Support',
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      _handleProfileMenuAction(_ProfileMenuAction.help, me);
                    },
                  ),
                  const Divider(height: 18, color: AppPalette.divider),
                  _profileMenuTile(
                    icon: Icons.logout_rounded,
                    title: _signingOut ? 'Logging out...' : 'Logout Account',
                    onTap: _signingOut
                        ? null
                        : () {
                            Navigator.of(sheetContext).pop();
                            _handleProfileMenuAction(
                              _ProfileMenuAction.logout,
                              me,
                            );
                          },
                  ),
                  _profileMenuTile(
                    icon: Icons.delete_outline_rounded,
                    title: _deleteAccountTitle(me),
                    subtitle: _deleteAccountSubtitle(me),
                    danger: true,
                    onTap: _deleteRequestBusy ||
                            me.hasPendingAccountDeletionRequest
                        ? null
                        : () {
                            Navigator.of(sheetContext).pop();
                            _handleProfileMenuAction(
                              _ProfileMenuAction.deleteAccount,
                              me,
                            );
                          },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _profileMenuTile({
    required IconData icon,
    required String title,
    String? subtitle,
    required VoidCallback? onTap,
    bool danger = false,
  }) {
    final color = danger ? const Color(0xFFDC2626) : AppPalette.textPrimary;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      minLeadingWidth: 34,
      leading: Icon(icon, color: color, size: 23),
      title: Text(
        title,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w900,
        ),
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              style: const TextStyle(
                color: AppPalette.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
      trailing: const Icon(
        Icons.chevron_right_rounded,
        color: AppPalette.textMuted,
      ),
      onTap: onTap,
    );
  }

  // The global input theme uses translucent-white fills/borders meant for dark
  // surfaces; on the light sheets below they'd be invisible. This overrides it
  // with visible light-theme inputs for the editor sheets.
  InputDecorationTheme _lightInputTheme() {
    return InputDecorationTheme(
      filled: true,
      fillColor: AppPalette.feedBg,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      labelStyle: const TextStyle(
        color: AppPalette.textSecondary,
        fontWeight: FontWeight.w600,
      ),
      hintStyle: const TextStyle(
        color: AppPalette.textMuted,
        fontWeight: FontWeight.w500,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: AppPalette.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: AppPalette.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: AppPalette.blue, width: 1.4),
      ),
    );
  }

  // Full light-theme override for the bottom sheets: the global filled/outlined
  // button themes use purple/translucent-white styling meant for dark surfaces
  // (outlined buttons would be invisible on white). This makes them blue and
  // visible alongside the light inputs.
  ThemeData _lightSheetTheme(BuildContext ctx) {
    return Theme.of(ctx).copyWith(
      inputDecorationTheme: _lightInputTheme(),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          elevation: 0,
          backgroundColor: AppPalette.blue,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          elevation: 0,
          foregroundColor: AppPalette.blue,
          side: const BorderSide(color: AppPalette.border),
          backgroundColor: Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
        ),
      ),
    );
  }

  void _openProfileEditor(AppUserModel me, {required bool accountOnly}) {
    final allowedRates = _userRepository.allowedRatesForFollowers(
      me.followersCount,
    );
    if (!allowedRates.contains(_selectedRate)) {
      _selectedRate = allowedRates.first;
    }

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AppPalette.card,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Theme(
              data: _lightSheetTheme(sheetContext),
              child: SafeArea(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    4,
                    16,
                    MediaQuery.of(sheetContext).viewInsets.bottom + 18,
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          accountOnly ? 'Edit account details' : 'Edit profile',
                          style: const TextStyle(
                            color: AppPalette.textPrimary,
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 14),
                        if (!accountOnly) ...[
                          Row(
                            children: [
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed:
                                      _saving ? null : _pickAndUploadPhoto,
                                  icon: const Icon(Icons.photo_outlined),
                                  label: Text(
                                    _saving ? 'Please wait...' : 'Upload Photo',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed:
                                      (_saving || me.photoURL.trim().isEmpty)
                                          ? null
                                          : _removePhoto,
                                  icon:
                                      const Icon(Icons.delete_outline_rounded),
                                  label: const Text('Remove'),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          _label('Display Name'),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _name,
                            textInputAction: TextInputAction.next,
                            maxLength: 40,
                            decoration: const InputDecoration(
                              labelText: 'Your name',
                            ),
                          ),
                          const SizedBox(height: 8),
                          _label('Bio'),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _bio,
                            minLines: 3,
                            maxLines: 4,
                            maxLength: 280,
                            decoration: const InputDecoration(
                              labelText: 'Write a short intro',
                            ),
                          ),
                          const SizedBox(height: 10),
                          _label('Topics'),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _topics,
                            onChanged: (_) => setState(() {}),
                            decoration: const InputDecoration(
                              labelText: 'Comma separated topics',
                            ),
                          ),
                          _suggestionChips(_topics, _suggestedTopics),
                          const SizedBox(height: 10),
                          _label('Languages'),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _languages,
                            onChanged: (_) => setState(() {}),
                            decoration: const InputDecoration(
                              labelText: 'Comma separated languages',
                            ),
                          ),
                          _suggestionChips(_languages, _suggestedLanguages),
                        ],
                        if (accountOnly) ...[
                          _label('Gender'),
                          const SizedBox(height: 8),
                          DropdownButtonFormField<String>(
                            initialValue:
                                _selectedGender.isEmpty ? '' : _selectedGender,
                            decoration: const InputDecoration(
                              labelText: 'Select gender',
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: '',
                                child: Text('Prefer not to say'),
                              ),
                              DropdownMenuItem(
                                value: 'Male',
                                child: Text('Male'),
                              ),
                              DropdownMenuItem(
                                value: 'Female',
                                child: Text('Female'),
                              ),
                              DropdownMenuItem(
                                value: 'Others',
                                child: Text('Others'),
                              ),
                            ],
                            onChanged: _saving
                                ? null
                                : (value) {
                                    setState(
                                        () => _selectedGender = value ?? '');
                                    setSheetState(() {});
                                  },
                          ),
                          const SizedBox(height: 10),
                          _label('Location'),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _city,
                            textInputAction: TextInputAction.next,
                            decoration:
                                const InputDecoration(labelText: 'City'),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: _state,
                            textInputAction: TextInputAction.next,
                            decoration:
                                const InputDecoration(labelText: 'State'),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: _country,
                            decoration: const InputDecoration(
                              labelText: 'Country',
                            ),
                          ),
                          const SizedBox(height: 10),
                          _label('Your call rate'),
                          const SizedBox(height: 8),
                          DropdownButtonFormField<int>(
                            initialValue: _selectedRate,
                            decoration: const InputDecoration(
                              labelText: 'Visible rate',
                            ),
                            items: allowedRates
                                .map(
                                  (rate) => DropdownMenuItem<int>(
                                    value: rate,
                                    child: Text('Rs $rate / min'),
                                  ),
                                )
                                .toList(),
                            onChanged: _saving
                                ? null
                                : (value) {
                                    if (value == null) return;
                                    setState(() => _selectedRate = value);
                                    setSheetState(() {});
                                  },
                          ),
                        ],
                        const SizedBox(height: 18),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: _saving
                                ? null
                                : () async {
                                    await _saveAll();
                                    if (mounted && sheetContext.mounted) {
                                      Navigator.of(sheetContext).pop();
                                    }
                                  },
                            child: Text(_saving ? 'Saving...' : 'Save'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _profileStat(String value, String label) {
    return Expanded(
      child: _profileStatBody(value, label),
    );
  }

  Widget _profileStatBody(String value, String label) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: AppPalette.textPrimary,
            fontSize: 21,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: AppPalette.textSecondary,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  Widget _profilePostCountStat(AppUserModel me) {
    return Expanded(
      child: StreamBuilder<List<SocialPostModel>>(
        stream: _socialRepository.watchUserPosts(me.uid, limit: 100),
        builder: (_, postSnap) {
          final postCount = postSnap.data?.length ?? 0;
          return _profileStatBody('$postCount', 'posts');
        },
      ),
    );
  }

  Widget _profileActionButton({
    required String label,
    required VoidCallback? onTap,
    IconData? icon,
  }) {
    return Expanded(
      child: SizedBox(
        height: 38,
        child: FilledButton(
          onPressed: onTap,
          style: FilledButton.styleFrom(
            backgroundColor: AppPalette.blueTint,
            foregroundColor: AppPalette.blue,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          child: icon == null
              ? Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w900),
                )
              : Icon(icon, size: 20),
        ),
      ),
    );
  }

  Future<void> _shareProfile(AppUserModel me) async {
    final name = _displayName(me);
    final handle = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '.')
        .replaceAll(RegExp(r'^\.+|\.+$'), '');
    final safeHandle = handle.isEmpty ? 'friendify.user' : handle;
    await Clipboard.setData(
      ClipboardData(text: 'Friendify profile: $name (@$safeHandle)'),
    );
    if (!mounted) return;
    _showSnack('Profile copied to clipboard.');
  }

  void _showCreatePostSheet(AppUserModel me) {
    final controller = TextEditingController();
    XFile? pickedImage;
    var uploading = false;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AppPalette.card,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final validationMessage =
                SocialRepository.postDraftValidationMessage(
              caption: controller.text,
              hasImage: pickedImage != null,
            );
            final canPublish = !uploading && validationMessage == null;

            Future<void> pickImage() async {
              if (uploading) return;
              final picked = await ImagePicker().pickImage(
                source: ImageSource.gallery,
                imageQuality: 84,
                maxWidth: 1800,
                maxHeight: 1800,
              );
              if (picked == null) return;
              setSheetState(() => pickedImage = picked);
            }

            Future<void> publish() async {
              if (uploading) return;
              final validationMessage =
                  SocialRepository.postDraftValidationMessage(
                caption: controller.text,
                hasImage: pickedImage != null,
              );
              if (validationMessage != null) {
                _showSnack(validationMessage);
                return;
              }
              final caption = controller.text.trim();
              final imagePath = pickedImage?.path.trim() ?? '';
              setSheetState(() => uploading = true);
              try {
                await _socialRepository.createPost(
                  owner: me,
                  imageFile: File(imagePath),
                  caption: caption,
                );
                if (!mounted || !sheetContext.mounted) return;
                Navigator.of(sheetContext).pop();
                _showSnack('Post added.');
              } on StateError catch (e) {
                if (!mounted || !sheetContext.mounted) return;
                setSheetState(() => uploading = false);
                _showSnack(e.message);
              } catch (_) {
                if (!mounted || !sheetContext.mounted) return;
                setSheetState(() => uploading = false);
                _showSnack('Could not upload post. Try again.');
              }
            }

            return Theme(
              data: _lightSheetTheme(sheetContext),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  18,
                  4,
                  18,
                  MediaQuery.viewInsetsOf(sheetContext).bottom + 18,
                ),
                child: SafeArea(
                  top: false,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'New post',
                          style: TextStyle(
                            color: AppPalette.textPrimary,
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 12),
                        InkWell(
                          onTap: pickImage,
                          borderRadius: BorderRadius.circular(18),
                          child: AspectRatio(
                            aspectRatio: 1.35,
                            child: Container(
                              decoration: BoxDecoration(
                                color: AppPalette.feedBg,
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(
                                  color: AppPalette.border,
                                ),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: pickedImage == null
                                  ? const Center(
                                      child: Icon(
                                        Icons.add_photo_alternate_outlined,
                                        color: AppPalette.blue,
                                        size: 42,
                                      ),
                                    )
                                  : Image.file(
                                      File(pickedImage!.path),
                                      fit: BoxFit.cover,
                                    ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: controller,
                          minLines: 2,
                          maxLines: 4,
                          maxLength: 180,
                          onChanged: (_) => setSheetState(() {}),
                          style: const TextStyle(color: AppPalette.textPrimary),
                          decoration: InputDecoration(
                            hintText: 'Write a caption...',
                            hintStyle: const TextStyle(
                              color: AppPalette.textMuted,
                            ),
                            filled: true,
                            fillColor: AppPalette.feedBg,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(18),
                              borderSide: const BorderSide(
                                color: AppPalette.border,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed:
                                canPublish ? () => unawaited(publish()) : null,
                            icon: uploading
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.publish_rounded),
                            label: Text(
                                uploading ? 'Uploading...' : 'Upload post'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showProfileSuggestionsSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: AppPalette.card,
      builder: (sheetContext) {
        return Theme(
          data: _lightSheetTheme(sheetContext),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Discover people',
                    style: TextStyle(
                      color: AppPalette.textPrimary,
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Use the Search tab to find listeners, follow profiles, and start chats.',
                    style: TextStyle(
                      color: AppPalette.textSecondary,
                      fontWeight: FontWeight.w700,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      icon: const Icon(Icons.search_rounded),
                      label: const Text('Open Search tab from bottom menu'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _showHighlightSheet(String label) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: AppPalette.card,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: AppPalette.textPrimary,
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  label == 'Calls'
                      ? 'Your call highlights will collect here as real sessions complete.'
                      : 'Profile highlights are ready for your future posts and moments.',
                  style: const TextStyle(
                    color: AppPalette.textSecondary,
                    fontWeight: FontWeight.w700,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _highlightBubble({
    required IconData icon,
    required String label,
    AppUserModel? me,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () => label == 'New' && me != null
          ? _showCreatePostSheet(me)
          : _showHighlightSheet(label),
      child: SizedBox(
        width: 86,
        child: Column(
          children: [
            Container(
              width: 68,
              height: 68,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppPalette.blue.withValues(alpha: 0.45),
                  width: 1.4,
                ),
              ),
              child: Icon(
                icon,
                color: AppPalette.blue,
                size: 30,
              ),
            ),
            const SizedBox(height: 7),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppPalette.textSecondary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _profileContentTabs() {
    const items = [
      Icons.grid_on_rounded,
      Icons.play_arrow_outlined,
      Icons.repeat_rounded,
      Icons.assignment_ind_outlined,
    ];

    return Row(
      children: items.map((icon) {
        final selected = icon == Icons.grid_on_rounded;
        return Expanded(
          child: Container(
            height: 48,
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: selected ? AppPalette.blue : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            child: Icon(
              icon,
              color: selected ? AppPalette.blue : AppPalette.textMuted,
              size: 27,
            ),
          ),
        );
      }).toList(growable: false),
    );
  }

  void _openSocialPost(SocialPostModel post) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PostDetailScreen(initialPost: post),
      ),
    );
  }

  Widget _postGrid(AppUserModel me) {
    return StreamBuilder<List<SocialPostModel>>(
      stream: _socialRepository.watchUserPosts(me.uid, limit: 90),
      builder: (_, snap) {
        final posts = snap.data ?? const <SocialPostModel>[];
        return GridView.builder(
          padding: EdgeInsets.zero,
          physics: const NeverScrollableScrollPhysics(),
          shrinkWrap: true,
          itemCount: posts.isEmpty ? 9 : posts.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 2,
            crossAxisSpacing: 2,
          ),
          itemBuilder: (_, index) {
            if (posts.isNotEmpty) {
              final post = posts[index];
              return InkWell(
                onTap: () => _openSocialPost(post),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.network(
                      post.imageURL,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        color: AppPalette.blueTint,
                      ),
                    ),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.55),
                          ],
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Align(
                        alignment: Alignment.bottomLeft,
                        child: Text(
                          post.caption,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }

            return Container(
              color: AppPalette.feedBg,
              child: InkWell(
                onTap: index == 4 ? () => _showCreatePostSheet(me) : null,
                child: index == 4
                    ? const Icon(
                        Icons.add_photo_alternate_outlined,
                        color: AppPalette.textMuted,
                      )
                    : null,
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AppUserModel?>(
      key: ValueKey('profile_$_profileRetryToken'),
      stream: _userRepository.watchMe(),
      builder: (_, snap) {
        if (snap.hasError) {
          return _profileLoadError();
        }

        if (!snap.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final me = snap.data!;
        _fillControllersOnce(me);

        final currentName = _displayName(me);
        final photoURL = me.photoURL.trim();
        final bio = me.bio.trim();
        final topics = me.topics;
        final languages = me.languages;
        final gender = me.gender.trim();
        final city = me.city.trim();
        final state = me.state.trim();
        final country = me.country.trim();
        final completeness = me.profileCompletenessPercent;
        final missingProfileItems = me.profileCompletionMissingItems;
        final handle = currentName
            .toLowerCase()
            .replaceAll(RegExp(r'[^a-z0-9]+'), '.')
            .replaceAll(RegExp(r'^\.+|\.+$'), '');
        final displayHandle = handle.isEmpty ? 'friendify.user' : handle;
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: const SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.dark,
            statusBarBrightness: Brightness.light,
          ),
          child: Scaffold(
            backgroundColor: AppPalette.pageBg,
            body: DecoratedBox(
              decoration: const BoxDecoration(color: AppPalette.pageBg),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 104),
                children: [
                  SafeArea(
                    bottom: false,
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: 'New post',
                          onPressed: () => _showCreatePostSheet(me),
                          icon: const Icon(Icons.add_rounded, size: 32),
                          color: AppPalette.textPrimary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Center(
                            child: Text(
                              displayHandle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppPalette.textPrimary,
                                fontSize: 20,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        ),
                        _profileMenu(me),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: AppPalette.border,
                                width: 3,
                              ),
                            ),
                            child: _avatar(photoURL, currentName),
                          ),
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: InkWell(
                              onTap: _saving ? null : _pickAndUploadPhoto,
                              borderRadius: BorderRadius.circular(999),
                              child: Container(
                                width: 28,
                                height: 28,
                                decoration: BoxDecoration(
                                  color: AppPalette.blue,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Colors.white,
                                    width: 2,
                                  ),
                                ),
                                child: const Icon(
                                  Icons.add_rounded,
                                  color: Colors.white,
                                  size: 20,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 20),
                      _profilePostCountStat(me),
                      _profileStat('${me.followersCount}', 'followers'),
                      _profileStat('${me.following.length}', 'following'),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    currentName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppPalette.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    bio.isEmpty ? 'No bio added yet.' : bio,
                    style: const TextStyle(
                      color: AppPalette.textSecondary,
                      fontSize: 14,
                      height: 1.25,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (gender.isNotEmpty ||
                      city.isNotEmpty ||
                      state.isNotEmpty ||
                      country.isNotEmpty) ...[
                    const SizedBox(height: 9),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (gender.isNotEmpty) _previewChip(gender),
                        if (city.isNotEmpty) _previewChip(city),
                        if (state.isNotEmpty) _previewChip(state),
                        if (country.isNotEmpty) _previewChip(country),
                      ],
                    ),
                  ],
                  if (topics.isNotEmpty || languages.isNotEmpty) ...[
                    const SizedBox(height: 9),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ...topics.take(3).map(_previewChip),
                        ...languages.take(2).map(_previewChip),
                      ],
                    ),
                  ],
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      _profileActionButton(
                        label: 'Share profile',
                        onTap: () => unawaited(_shareProfile(me)),
                      ),
                      const SizedBox(width: 8),
                      _profileActionButton(
                        label: 'Add',
                        icon: Icons.person_add_alt_1_rounded,
                        onTap: _showProfileSuggestionsSheet,
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _profileCompletionPanel(
                    me: me,
                    completeness: completeness,
                    missingItems: missingProfileItems,
                  ),
                  if (me.hasPendingAccountDeletionRequest ||
                      me.hasReviewedAccountDeletionRequest) ...[
                    const SizedBox(height: 14),
                    _deleteAccountStatusPanel(me),
                  ],
                  const SizedBox(height: 22),
                  SizedBox(
                    height: 96,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        _highlightBubble(
                          icon: Icons.add_rounded,
                          label: 'New',
                          me: me,
                        ),
                        _highlightBubble(
                          icon: Icons.favorite_border_rounded,
                          label: 'Highlights',
                        ),
                        _highlightBubble(
                          icon: Icons.headphones_rounded,
                          label: 'Calls',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  _profileContentTabs(),
                  const SizedBox(height: 2),
                  _postGrid(me),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SavedPostsScreen extends StatelessWidget {
  const _SavedPostsScreen();

  static final SocialRepository _socialRepository = SocialRepository.instance;

  void _openPost(BuildContext context, SocialPostModel post) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PostDetailScreen(initialPost: post),
      ),
    );
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
          'Saved posts',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: DecoratedBox(
        decoration: const BoxDecoration(color: AppPalette.pageBg),
        child: StreamBuilder<List<SocialPostModel>>(
          stream: _socialRepository.watchSavedPostsByMe(),
          builder: (context, snap) {
            final posts = snap.data ?? const <SocialPostModel>[];
            if (snap.connectionState == ConnectionState.waiting &&
                posts.isEmpty) {
              return const Center(child: CircularProgressIndicator());
            }
            if (posts.isEmpty) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(28),
                  child: Text(
                    'Saved posts will appear here.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppPalette.textSecondary,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              );
            }

            return GridView.builder(
              padding: const EdgeInsets.all(2),
              itemCount: posts.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 2,
                crossAxisSpacing: 2,
              ),
              itemBuilder: (context, index) {
                final post = posts[index];
                return InkWell(
                  onTap: () => _openPost(context, post),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.network(
                        post.imageURL,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          color: AppPalette.blueTint,
                        ),
                      ),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.54),
                            ],
                          ),
                        ),
                      ),
                      Align(
                        alignment: Alignment.bottomLeft,
                        child: Padding(
                          padding: const EdgeInsets.all(7),
                          child: Text(
                            post.ownerName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
