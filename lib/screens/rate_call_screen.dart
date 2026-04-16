import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../services/firestore_service.dart';

class RateCallScreen extends StatefulWidget {
  final DocumentReference<Map<String, dynamic>> callDocRef;
  final bool iAmCaller;

  const RateCallScreen({
    super.key,
    required this.callDocRef,
    required this.iAmCaller,
  });

  @override
  State<RateCallScreen> createState() => _RateCallScreenState();
}

class _RateCallScreenState extends State<RateCallScreen> {
  int _stars = 5;
  final _text = TextEditingController();
  bool _saving = false;
  bool _alreadyHandled = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  String _safeString(dynamic value, {String fallback = ''}) {
    if (value is String) return value.trim();
    return fallback;
  }

  int _safeInt(dynamic value, {int fallback = 0}) {
    if (value is int) return value;
    if (value is num) return value.floor();
    return fallback;
  }

  bool _wasAnswered(Map<String, dynamic> call) {
    final startedAt = call['startedAt'];
    if (startedAt != null) return true;

    final endedSeconds = _safeInt(call['endedSeconds']);
    if (endedSeconds > 0) return true;

    final status = _safeString(call['status']);
    if (status == 'accepted') return true;

    return false;
  }

  String _durationLabel(Map<String, dynamic> call) {
    final seconds = _safeInt(call['endedSeconds']);
    final safeSeconds = seconds < 0 ? 0 : seconds;

    if (safeSeconds <= 0) return '0s';

    final hours = safeSeconds ~/ 3600;
    final mins = (safeSeconds % 3600) ~/ 60;
    final secs = safeSeconds % 60;

    if (hours > 0) {
      if (secs == 0) return '${hours}h ${mins}m';
      return '${hours}h ${mins}m ${secs}s';
    }

    if (mins > 0) {
      if (secs == 0) return '${mins}m';
      return '${mins}m ${secs}s';
    }

    return '${secs}s';
  }

  Widget _star(int i) {
    final filled = i <= _stars;
    return IconButton(
      icon: Icon(
        filled ? Icons.star_rounded : Icons.star_border_rounded,
        color: filled ? Colors.amber : null,
      ),
      iconSize: 36,
      onPressed: _saving ? null : () => setState(() => _stars = i),
    );
  }

  void _showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  Future<void> _submit(Map<String, dynamic> call) async {
    if (_saving || _alreadyHandled) return;

    final callerId = _safeString(call['callerId']);
    final calleeId = _safeString(call['calleeId']);
    final reviewedUserId = widget.iAmCaller ? calleeId : callerId;

    if (!_wasAnswered(call)) {
      _alreadyHandled = true;
      if (mounted) Navigator.pop(context, false);
      return;
    }

    if (reviewedUserId.isEmpty) {
      _showSnack('Unable to identify who to review.');
      return;
    }

    setState(() => _saving = true);

    bool created = false;
    bool failed = false;

    try {
      created = await FirestoreService.submitReviewCreateOnly(
        callId: widget.callDocRef.id,
        reviewedUserId: reviewedUserId,
        stars: _stars,
        text: _text.text.trim(),
      );
    } catch (_) {
      failed = true;
    }

    if (!mounted) return;

    if (failed) {
      _showSnack('Could not submit review.');
      setState(() => _saving = false);
      return;
    }

    _alreadyHandled = true;

    if (created) {
      _showSnack('Review submitted.');
      Navigator.pop(context, true);
    } else {
      _showSnack('You already reviewed this call.');
      Navigator.pop(context, false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: widget.callDocRef.snapshots(),
      builder: (_, snap) {
        final call = snap.data?.data() ?? <String, dynamic>{};

        final otherName = widget.iAmCaller
            ? _safeString(call['calleeName'], fallback: 'Listener')
            : _safeString(call['callerName'], fallback: 'Caller');

        final safeOtherName = otherName.isEmpty
            ? (widget.iAmCaller ? 'Listener' : 'Caller')
            : otherName;

        final durationLabel = _durationLabel(call);
        final wasAnswered = _wasAnswered(call);

        return Scaffold(
          appBar: AppBar(title: const Text('Rate your call')),
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircleAvatar(
                          radius: 30,
                          child: Text(
                            safeOtherName.isNotEmpty
                                ? safeOtherName[0].toUpperCase()
                                : 'U',
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'How was $safeOtherName?',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Call duration: $durationLabel',
                          style: const TextStyle(
                            color: Colors.black54,
                            fontWeight: FontWeight.w700,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        if (!wasAnswered)
                          const Text(
                            'This call was not fully answered, so rating is unavailable.',
                            style: TextStyle(
                              color: Colors.black54,
                              fontWeight: FontWeight.w700,
                            ),
                            textAlign: TextAlign.center,
                          )
                        else ...[
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _star(1),
                              _star(2),
                              _star(3),
                              _star(4),
                              _star(5),
                            ],
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _text,
                            maxLines: 3,
                            maxLength: 240,
                            enabled: !_saving,
                            decoration: const InputDecoration(
                              labelText: 'Optional review',
                              hintText:
                                  'Share what felt helpful, respectful, or needs improvement.',
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: (!wasAnswered || _saving)
                              ? null
                              : () => _submit(call),
                          child: Text(_saving ? 'Saving...' : 'Submit'),
                        ),
                        const SizedBox(height: 6),
                        TextButton(
                          onPressed: _saving
                              ? null
                              : () => Navigator.pop(context, false),
                          child: Text(wasAnswered ? 'Skip' : 'Close'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}