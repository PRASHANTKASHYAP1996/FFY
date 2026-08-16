import 'package:flutter/material.dart';

import '../../core/theme/app_palette.dart';
import '../../repositories/call_repository.dart';
import '../../shared/models/app_user_model.dart';
import '../caller_waiting_screen.dart';

/// The private-call setup step: pick an expected duration, see the estimated
/// maximum cost, then start the call. The call itself stays metered/prepaid —
/// the duration is an estimate, and you can end anytime.
class CallSetupScreen extends StatefulWidget {
  const CallSetupScreen({
    super.key,
    required this.listener,
    required this.me,
  });

  final AppUserModel listener;
  final AppUserModel me;

  @override
  State<CallSetupScreen> createState() => _CallSetupScreenState();
}

class _CallSetupScreenState extends State<CallSetupScreen> {
  final CallRepository _callRepository = CallRepository.instance;

  static const List<int> _durations = <int>[5, 10, 15, 30];
  int _minutes = 10;
  bool _starting = false;

  int get _rate =>
      widget.listener.listenerRate > 0 ? widget.listener.listenerRate : 5;
  int get _estMax => _minutes * _rate;

  void _showMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _start() async {
    if (_starting) return;
    final me = widget.me;
    final listener = widget.listener;
    final safeId = listener.uid.trim();
    if (safeId.isEmpty || safeId == me.uid) return;
    if (_callRepository.hasBlockingCallState) {
      _showMessage('Finish your current call flow first.');
      return;
    }

    setState(() => _starting = true);
    try {
      final canCall =
          await _callRepository.canCurrentUserCallListener(listenerId: safeId);
      if (!mounted) return;
      final readiness = _callRepository.callReadinessForKnownUsers(
        me: me,
        listener: listener,
        hasCallAccess: canCall,
        requiredCredits: _rate,
      );
      if (!readiness.canStart) {
        _showMessage(readiness.message);
        return;
      }

      final callStart =
          await _callRepository.createCallToListener(listenerId: safeId);
      if (!mounted) return;
      if (callStart == null || !callStart.canOpenWaitingScreen) {
        _showMessage('Call could not start. Please try again.');
        return;
      }

      await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => CallerWaitingScreen(
            callDocRef: callStart.callRef,
            initialAgoraToken: callStart.agoraToken,
            initialAgoraUid: callStart.agoraUid,
            initialChannelId: callStart.channelId,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _showMessage(_callRepository.humanizeCallActionError(e));
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final listener = widget.listener;
    final photo = listener.photoURL.trim();
    return Scaffold(
      backgroundColor: AppPalette.pageBg,
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: AppPalette.textPrimary,
        surfaceTintColor: Colors.transparent,
        title: const Text('Call setup'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
          children: [
            // Who you're calling.
            Container(
              padding: const EdgeInsets.all(14),
              decoration: AppPalette.cardDecoration(radius: 18),
              child: Row(
                children: [
                  ClipOval(
                    child: SizedBox(
                      width: 56,
                      height: 56,
                      child: photo.isEmpty
                          ? _initialsCircle(listener.safeDisplayName)
                          : Image.network(
                              photo,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) =>
                                  _initialsCircle(listener.safeDisplayName),
                            ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          listener.safeDisplayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: AppPalette.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '₹$_rate / min',
                          style: const TextStyle(
                            fontSize: 13.5,
                            color: AppPalette.textSecondary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 22),
            const Text(
              'How long do you expect to talk?',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: AppPalette.textPrimary,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final m in _durations)
                  _durationChip(m),
              ],
            ),
            const SizedBox(height: 22),
            // Estimated max cost.
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppPalette.blueTint,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline_rounded,
                      color: AppPalette.blue, size: 22),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Estimated maximum ₹$_estMax',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            color: AppPalette.blueDark,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '$_minutes min × ₹$_rate/min · you only pay for the '
                          'time used, and can end anytime.',
                          style: const TextStyle(
                            fontSize: 12.5,
                            height: 1.35,
                            color: AppPalette.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              height: 54,
              child: FilledButton.icon(
                onPressed: _starting ? null : _start,
                style: FilledButton.styleFrom(
                  backgroundColor: AppPalette.blue,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                icon: _starting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.lock_rounded, size: 18),
                label: Text(
                  _starting ? 'Starting…' : 'Start private call',
                  style:
                      const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Private 1-on-1 · encrypted voice · nobody else can join.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: AppPalette.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _durationChip(int minutes) {
    final selected = _minutes == minutes;
    return GestureDetector(
      onTap: _starting ? null : () => setState(() => _minutes = minutes),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
        decoration: BoxDecoration(
          color: selected ? AppPalette.blue : AppPalette.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? AppPalette.blue : AppPalette.border,
          ),
        ),
        child: Text(
          '$minutes min',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: selected ? Colors.white : AppPalette.textPrimary,
          ),
        ),
      ),
    );
  }

  Widget _initialsCircle(String name) {
    final safe = name.trim();
    final letter = safe.isEmpty ? 'U' : safe[0].toUpperCase();
    return Container(
      color: AppPalette.blueTint,
      alignment: Alignment.center,
      child: Text(
        letter,
        style: const TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          color: AppPalette.blue,
        ),
      ),
    );
  }
}
