import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../repositories/user_repository.dart';
import '../services/firestore_service.dart';
import '../shared/models/app_user_model.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final UserRepository _userRepository = UserRepository.instance;

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

  int _profileCompleteness({
    required String name,
    required String bio,
    required List<String> topics,
    required List<String> languages,
    required String photoUrl,
    required String gender,
    required String city,
    required String state,
  }) {
    int score = 0;

    if (name.trim().isNotEmpty) score += 15;
    if (bio.trim().isNotEmpty) score += 15;
    if (topics.isNotEmpty) score += 15;
    if (languages.isNotEmpty) score += 15;
    if (photoUrl.trim().isNotEmpty) score += 15;
    if (gender.trim().isNotEmpty) score += 10;
    if (city.trim().isNotEmpty) score += 10;
    if (state.trim().isNotEmpty) score += 5;

    return score;
  }

  void _showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
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
                        ? 'A delete-account request is already pending for this account.\n\nYour account is not deleted immediately from this screen. Support/admin review, retention handling, and final execution still remain controlled before launch.'
                        : 'Your delete-account request has been recorded.\n\nThis build uses a controlled request flow. Deletion is not instant from the device. Support/admin review and retention handling still apply before final removal.',
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
                            border: Border.all(color: const Color(0xFFFECACA)),
                          ),
                          child: const Text(
                            'This screen submits a review request only. It does not instantly delete your account from the device. Before launch, final retention policy, support workflow, and final confirmation steps still need to be verified.',
                            style: TextStyle(
                              color: Color(0xFF7F1D1D),
                              fontWeight: FontWeight.w700,
                              height: 1.4,
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
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
                        const SizedBox(height: 16),
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
      _showSnack('Save failed: $e');
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
      );

      if (picked == null) {
        if (mounted) {
          setState(() => _saving = false);
        }
        return;
      }

      final uid = FirestoreService.uid();
      final ref = FirebaseStorage.instance
          .ref()
          .child('user_photos')
          .child(uid)
          .child('profile.jpg');

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
    } catch (e) {
      _showSnack('Photo upload failed: $e');
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
      final ref = FirebaseStorage.instance
          .ref()
          .child('user_photos')
          .child(uid)
          .child('profile.jpg');

      try {
        await ref.delete();
      } catch (_) {
        // ignore if already missing
      }

      _showSnack('Photo removed');
    } catch (e) {
      _showSnack('Photo remove failed: $e');
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
      backgroundColor: const Color(0xFFE6E8FF),
      child: Text(
        letter,
        style: const TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w900,
          color: Color(0xFF4A4FB3),
        ),
      ),
    );
  }

  Widget _chipsFromList(List<String> items) {
    if (items.isEmpty) {
      return const Text(
        'Nothing added yet',
        style: TextStyle(
          color: Color(0xFF6B7280),
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
                color: const Color(0xFFF3F4F8),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                e,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF374151),
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

  Widget _progressChip(String label, bool done) {
    final bg = done ? const Color(0xFFECFDF3) : const Color(0xFFF3F4F8);
    final fg = done ? const Color(0xFF15803D) : const Color(0xFF4B5563);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontWeight: FontWeight.w800,
          color: fg,
        ),
      ),
    );
  }

  Widget _sectionCard({
    required String title,
    String? subtitle,
    required Widget child,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
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
            if (subtitle != null && subtitle.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: const TextStyle(
                  color: Color(0xFF6B7280),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 16),
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
        color: Color(0xFF111827),
      ),
    );
  }

  Widget _miniStat({
    required String label,
    required String value,
    Color? valueColor,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF6B7280),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w900,
              color: valueColor ?? const Color(0xFF111827),
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
          color: Color(0xFF111827),
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(
          color: Color(0xFF6B7280),
          fontWeight: FontWeight.w600,
        ),
      ),
      trailing: const Icon(
        Icons.chevron_right_rounded,
        color: Color(0xFF9CA3AF),
      ),
      onTap: onTap,
    );
  }

  Widget _accountAndComplianceCard() {
    return _sectionCard(
      title: 'Account & launch information',
      subtitle:
          'Visible user-facing surfaces for account management and launch compliance.',
      child: Column(
        children: [
          _launchLinkTile(
            icon: Icons.delete_outline_rounded,
            title: 'Delete Account Request',
            subtitle: _deleteRequestBusy
                ? 'Submitting request...'
                : 'Submit a controlled deletion request for support/admin review.',
            iconColor: const Color(0xFFDC2626),
            iconBg: const Color(0xFFFEF2F2),
            onTap: _deleteRequestBusy ? () {} : _openDeleteRequestSheet,
          ),
          const Divider(height: 1),
          _launchLinkTile(
            icon: Icons.privacy_tip_outlined,
            title: 'Privacy Policy',
            subtitle: 'Placeholder until final approved policy is linked.',
            onTap: () {
              _showInfoSheet(
                title: 'Privacy Policy',
                body:
                    'Privacy Policy page is not finalized in this build yet.\n\nBefore launch, add the final approved Privacy Policy text and public link here.',
              );
            },
          ),
          const Divider(height: 1),
          _launchLinkTile(
            icon: Icons.description_outlined,
            title: 'Terms of Service',
            subtitle: 'Placeholder until final approved terms are linked.',
            iconColor: const Color(0xFF374151),
            iconBg: const Color(0xFFF3F4F6),
            onTap: () {
              _showInfoSheet(
                title: 'Terms of Service',
                body:
                    'Terms of Service page is not finalized in this build yet.\n\nBefore launch, add final user terms, listener terms, prohibited conduct rules, moderation enforcement, billing terms, and dispute language here.',
              );
            },
          ),
          const Divider(height: 1),
          _launchLinkTile(
            icon: Icons.receipt_long_outlined,
            title: 'Refund Policy',
            subtitle: 'Visible placeholder until final policy is approved.',
            iconColor: const Color(0xFFD97706),
            iconBg: const Color(0xFFFFFBEB),
            onTap: () {
              _showInfoSheet(
                title: 'Refund Policy',
                body:
                    'Refund Policy is still placeholder-only in this build.\n\nCurrent truth: parts of payment flow remain sandbox / test oriented, so the product should not be presented as fully live production money flow yet.',
              );
            },
          ),
          const Divider(height: 1),
          _launchLinkTile(
            icon: Icons.support_agent_rounded,
            title: 'Support / Grievance Contact',
            subtitle: 'Placeholder until final support channels are configured.',
            iconColor: const Color(0xFF15803D),
            iconBg: const Color(0xFFECFDF3),
            onTap: () {
              _showInfoSheet(
                title: 'Support / Grievance Contact',
                body:
                    'Support and grievance contact details are not finalized in this build yet.\n\nBefore launch, configure support email, support hours, grievance officer/contact, and escalation path.',
              );
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AppUserModel?>(
      stream: _userRepository.watchMe(),
      builder: (_, snap) {
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
        final allowedRates = _userRepository.allowedRatesForFollowers(me.followersCount);
        if (!allowedRates.contains(_selectedRate)) {
          _selectedRate = allowedRates.first;
        }

        final profileCompletion = _profileCompleteness(
          name: currentName,
          bio: bio,
          topics: topics,
          languages: languages,
          photoUrl: photoURL,
          gender: gender,
          city: city,
          state: state,
        );

        return Scaffold(
          appBar: AppBar(title: const Text('Profile')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          _avatar(photoURL, currentName),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  currentName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w900,
                                    color: Color(0xFF111827),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Profile completeness: $profileCompletion%',
                                  style: const TextStyle(
                                    color: Color(0xFF6B7280),
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          value: profileCompletion / 100,
                          minHeight: 10,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _progressChip('Photo', photoURL.isNotEmpty),
                          _progressChip('Bio', bio.isNotEmpty),
                          _progressChip('Topics', topics.isNotEmpty),
                          _progressChip('Languages', languages.isNotEmpty),
                          _progressChip('Gender', gender.isNotEmpty),
                          _progressChip('Location', city.isNotEmpty || state.isNotEmpty),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: _saving ? null : _pickAndUploadPhoto,
                              icon: const Icon(Icons.photo_outlined),
                              label: Text(
                                _saving ? 'Please wait...' : 'Upload Photo',
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: (_saving || photoURL.isEmpty)
                                  ? null
                                  : _removePhoto,
                              icon: const Icon(Icons.delete_outline_rounded),
                              label: const Text('Remove'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _miniStat(
                      label: 'Topics',
                      value: '${topics.length}',
                      valueColor: const Color(0xFF4A4FB3),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _miniStat(
                      label: 'Languages',
                      value: '${languages.length}',
                      valueColor: const Color(0xFF15803D),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _miniStat(
                      label: 'Rate',
                      value: '₹${me.listenerRate}',
                      valueColor: const Color(0xFFD97706),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _sectionCard(
                title: 'Edit public profile',
                subtitle: 'Keep it short, clear, and trustworthy.',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
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
                        hintText:
                            'Example: Calm listener for relationship talks, stress, motivation, and late-night support.',
                      ),
                    ),
                    const SizedBox(height: 14),
                    _label('Gender'),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: _selectedGender.isEmpty ? '' : _selectedGender,
                      decoration: const InputDecoration(
                        labelText: 'Select gender',
                      ),
                      items: const [
                        DropdownMenuItem(value: '', child: Text('Prefer not to say')),
                        DropdownMenuItem(value: 'Male', child: Text('Male')),
                        DropdownMenuItem(value: 'Female', child: Text('Female')),
                        DropdownMenuItem(value: 'Others', child: Text('Others')),
                      ],
                      onChanged: _saving
                          ? null
                          : (value) {
                              setState(() {
                                _selectedGender = value ?? '';
                              });
                            },
                    ),
                    const SizedBox(height: 14),
                    _label('Location'),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _city,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'City',
                        hintText: 'Example: Mumbai',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _state,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'State',
                        hintText: 'Example: Maharashtra',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _country,
                      decoration: const InputDecoration(
                        labelText: 'Country',
                        hintText: 'Example: India',
                      ),
                    ),
                    const SizedBox(height: 14),
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
                              child: Text('₹$rate / min'),
                            ),
                          )
                          .toList(),
                      onChanged: _saving
                          ? null
                          : (value) {
                              if (value == null) return;
                              setState(() {
                                _selectedRate = value;
                              });
                            },
                    ),
                    const SizedBox(height: 8),
                    _label('Topics'),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _topics,
                      decoration: const InputDecoration(
                        labelText: 'Comma separated topics',
                        hintText:
                            'Breakup, Motivation, Friendship, Career, Emotional Support',
                      ),
                    ),
                    const SizedBox(height: 14),
                    _label('Languages'),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _languages,
                      decoration: const InputDecoration(
                        labelText: 'Comma separated languages',
                        hintText: 'English, Hindi, Punjabi',
                      ),
                    ),
                    const SizedBox(height: 18),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _saving ? null : _saveAll,
                        child: Text(_saving ? 'Saving...' : 'Save Profile'),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _sectionCard(
                title: 'Profile preview',
                subtitle: 'This is how your profile content looks.',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _label('Bio'),
                    const SizedBox(height: 8),
                    if (bio.isEmpty)
                      const Text(
                        'No bio added yet.',
                        style: TextStyle(
                          color: Color(0xFF6B7280),
                          fontWeight: FontWeight.w600,
                        ),
                      )
                    else
                      Text(
                        bio,
                        style: const TextStyle(
                          color: Color(0xFF374151),
                          fontWeight: FontWeight.w600,
                          height: 1.4,
                        ),
                      ),
                    const SizedBox(height: 16),
                    _label('Gender & location'),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (gender.isNotEmpty) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF3F4F8),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              gender,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF374151),
                              ),
                            ),
                          ),
                        ],
                        if (city.isNotEmpty) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF3F4F8),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              city,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF374151),
                              ),
                            ),
                          ),
                        ],
                        if (state.isNotEmpty) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF3F4F8),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              state,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF374151),
                              ),
                            ),
                          ),
                        ],
                        if (country.isNotEmpty) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF3F4F8),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              country,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF374151),
                              ),
                            ),
                          ),
                        ],
                        if (gender.isEmpty && city.isEmpty && state.isEmpty && country.isEmpty)
                          const Text(
                            'No gender or location added yet.',
                            style: TextStyle(
                              color: Color(0xFF6B7280),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _label('Topics'),
                    const SizedBox(height: 8),
                    _chipsFromList(topics),
                    const SizedBox(height: 16),
                    _label('Languages'),
                    const SizedBox(height: 8),
                    _chipsFromList(languages),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _accountAndComplianceCard(),
            ],
          ),
        );
      },
    );
  }
}