import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/constants/firestore_paths.dart';
import '../shared/models/call_model.dart';
import '../services/firestore_service.dart';

class CallHistoryItem {
  final String callId;
  final bool isIncoming;
  final String name;
  final int seconds;
  final int amount;
  final int endedAtMs;
  final bool listenerCredited;
  final String status;
  final String endedReason;
  final String rejectedReason;
  final bool wasAnswered;

  const CallHistoryItem({
    required this.callId,
    required this.isIncoming,
    required this.name,
    required this.seconds,
    required this.amount,
    required this.endedAtMs,
    required this.listenerCredited,
    required this.status,
    required this.endedReason,
    required this.rejectedReason,
    required this.wasAnswered,
  });

  bool get isMissed {
    if (wasAnswered) return false;
    return status == FirestorePaths.statusRejected ||
        status == FirestorePaths.statusRinging ||
        status == FirestorePaths.statusEnded;
  }

  bool get isUnderOneMinuteAnswered {
    if (!wasAnswered) return false;
    return seconds >= 0 && seconds < 60 && !isPaidCall;
  }

  bool get isExactlyZeroSeconds => seconds <= 0;

  bool get isPaidOrCredited => amount > 0;

  bool get isPaidCall => wasAnswered && seconds >= 60 && amount > 0;

  bool get isFreeAnsweredCall => wasAnswered && !isPaidCall;

  bool get isZeroSecondAnswered => wasAnswered && seconds <= 0 && !isPaidCall;
}

class HistoryRepository {
  HistoryRepository._();

  static final HistoryRepository instance = HistoryRepository._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _calls =>
      _db.collection(FirestorePaths.calls);

  String get myUid => FirestoreService.uid();

  Stream<List<CallHistoryItem>> watchMyCallHistory({
    int limit = 200,
  }) {
    final uid = myUid;

    final incomingStream = _calls
        .where(FirestorePaths.fieldCalleeId, isEqualTo: uid)
        .orderBy(FirestorePaths.fieldCreatedAtMs, descending: true)
        .limit(limit)
        .snapshots();

    final outgoingStream = _calls
        .where(FirestorePaths.fieldCallerId, isEqualTo: uid)
        .orderBy(FirestorePaths.fieldCreatedAtMs, descending: true)
        .limit(limit)
        .snapshots();

    late final StreamController<List<CallHistoryItem>> controller;
    StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? incomingSub;
    StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? outgoingSub;

    List<QueryDocumentSnapshot<Map<String, dynamic>>> incomingDocs = const [];
    List<QueryDocumentSnapshot<Map<String, dynamic>>> outgoingDocs = const [];

    void emitMerged() {
      if (controller.isClosed) return;

      controller.add(
        _mergeHistoryDocs(
          incomingDocs: incomingDocs,
          outgoingDocs: outgoingDocs,
          limit: limit,
        ),
      );
    }

    controller = StreamController<List<CallHistoryItem>>(
      onListen: () {
        incomingSub = incomingStream.listen(
          (snap) {
            incomingDocs = snap.docs;
            emitMerged();
          },
          onError: controller.addError,
        );

        outgoingSub = outgoingStream.listen(
          (snap) {
            outgoingDocs = snap.docs;
            emitMerged();
          },
          onError: controller.addError,
        );
      },
      onCancel: () async {
        await incomingSub?.cancel();
        await outgoingSub?.cancel();
      },
    );

    return controller.stream;
  }

  Future<List<CallHistoryItem>> getMyCallHistory({
    int limit = 200,
  }) async {
    final uid = myUid;

    final incomingSnap = await _calls
        .where(FirestorePaths.fieldCalleeId, isEqualTo: uid)
        .orderBy(FirestorePaths.fieldCreatedAtMs, descending: true)
        .limit(limit)
        .get();

    final outgoingSnap = await _calls
        .where(FirestorePaths.fieldCallerId, isEqualTo: uid)
        .orderBy(FirestorePaths.fieldCreatedAtMs, descending: true)
        .limit(limit)
        .get();

    return _mergeHistoryDocs(
      incomingDocs: incomingSnap.docs,
      outgoingDocs: outgoingSnap.docs,
      limit: limit,
    );
  }

  List<CallHistoryItem> _mergeHistoryDocs({
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> incomingDocs,
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> outgoingDocs,
    required int limit,
  }) {
    final items = <CallHistoryItem>[];

    for (final doc in incomingDocs) {
      final call = CallModel.fromMap(doc.id, doc.data());
      if (!_shouldInclude(call)) continue;
      items.add(_buildIncomingItem(call));
    }

    for (final doc in outgoingDocs) {
      final call = CallModel.fromMap(doc.id, doc.data());
      if (!_shouldInclude(call)) continue;
      items.add(_buildOutgoingItem(call));
    }

    items.sort((a, b) {
      final timeCompare = b.endedAtMs.compareTo(a.endedAtMs);
      if (timeCompare != 0) return timeCompare;
      return b.callId.compareTo(a.callId);
    });

    if (items.length <= limit) return items;
    return items.take(limit).toList();
  }

  CallHistoryItem _buildIncomingItem(CallModel call) {
    return CallHistoryItem(
      callId: call.id,
      isIncoming: true,
      name: _safeDisplayName(call.callerName),
      seconds: _safeSeconds(call.endedSeconds),
      amount: _safeAmount(call.listenerPayout),
      endedAtMs: _historyTimeMs(call),
      listenerCredited: _isListenerCredited(call),
      status: _safeText(call.status),
      endedReason: _safeText(call.endedReason),
      rejectedReason: _safeText(call.rejectedReason),
      wasAnswered: _wasAnswered(call),
    );
  }

  CallHistoryItem _buildOutgoingItem(CallModel call) {
    return CallHistoryItem(
      callId: call.id,
      isIncoming: false,
      name: _safeDisplayName(call.calleeName),
      seconds: _safeSeconds(call.endedSeconds),
      amount: _safeAmount(call.speakerCharge),
      endedAtMs: _historyTimeMs(call),
      listenerCredited: true,
      status: _safeText(call.status),
      endedReason: _safeText(call.endedReason),
      rejectedReason: _safeText(call.rejectedReason),
      wasAnswered: _wasAnswered(call),
    );
  }

  bool _shouldInclude(CallModel call) {
    return call.isEnded || call.isRejected;
  }

  bool _wasAnswered(CallModel call) {
    if (call.startedAt != null) return true;
    if (call.status == FirestorePaths.statusAccepted) return true;

    final seconds = _safeSeconds(call.endedSeconds);
    final hasCharge = call.speakerCharge > 0 || call.listenerPayout > 0;
    if (seconds > 0 || hasCharge) return true;

    final endedReason = _safeText(call.endedReason).toLowerCase();
    final rejectedReason = _safeText(call.rejectedReason).toLowerCase();

    const nonAnsweredReasons = <String>{
      'timeout',
      'busy',
      'caller_cancel',
      'caller_cancelled',
      'callee_reject',
      'callee_reject_callkit',
      'callkit_ended',
      'invalid',
      'open_call_failed',
      'invalid_channel',
      'caller_timeout',
      'caller_timeout_cleanup',
      'server_timeout',
      'stale_timeout',
      'missed',
      'no_answer',
    };

    if (nonAnsweredReasons.contains(endedReason)) return false;
    if (nonAnsweredReasons.contains(rejectedReason)) return false;

    if (call.isRejected) return false;

    return call.isEnded && (seconds > 0 || hasCharge || call.startedAt != null);
  }

  bool _isListenerCredited(CallModel call) {
    if (call.listenerPayout <= 0) return true;
    if (call.settled) return true;
    return call.listenerCredited;
  }

  int _historyTimeMs(CallModel call) {
    if (call.endedAtMs > 0) return call.endedAtMs;

    if (call.endedAt != null) {
      return call.endedAt!.millisecondsSinceEpoch;
    }

    if (call.startedAt != null) {
      return call.startedAt!.millisecondsSinceEpoch;
    }

    if (call.createdAt != null) {
      return call.createdAt!.millisecondsSinceEpoch;
    }

    if (call.createdAtMs > 0) {
      return call.createdAtMs;
    }

    return 0;
  }

  String _safeDisplayName(String value) {
    final safe = value.trim();
    if (safe.isEmpty) return 'Unknown';
    return safe;
  }

  String _safeText(String value) {
    return value.trim();
  }

  int _safeSeconds(int value) {
    if (value < 0) return 0;
    return value;
  }

  int _safeAmount(int value) {
    if (value < 0) return 0;
    return value;
  }

  int fullMinutesFromSeconds(int seconds) {
    if (seconds < 60) return 0;
    return seconds ~/ 60;
  }

  String durationLabelDetailed(int seconds) {
    final safeSeconds = seconds < 0 ? 0 : seconds;

    if (safeSeconds <= 0) {
      return '0s';
    }

    final hours = safeSeconds ~/ 3600;
    final mins = (safeSeconds % 3600) ~/ 60;
    final secs = safeSeconds % 60;

    if (hours > 0) {
      if (mins == 0 && secs == 0) return '${hours}h';
      if (secs == 0) return '${hours}h ${mins}m';
      return '${hours}h ${mins}m ${secs}s';
    }

    if (mins == 0) return '${secs}s';
    if (secs == 0) return '${mins}m';
    return '${mins}m ${secs}s';
  }

  String durationLabelCompact(int seconds) {
    final safeSeconds = seconds < 0 ? 0 : seconds;

    if (safeSeconds < 60) {
      return 'Under 60s';
    }

    return '${fullMinutesFromSeconds(safeSeconds)} min';
  }

  String amountLabel({
    required bool isIncoming,
    required int amount,
  }) {
    final safeAmount = amount < 0 ? 0 : amount;

    if (isIncoming) {
      return safeAmount <= 0 ? '+₹0' : '+₹$safeAmount';
    }

    return safeAmount <= 0 ? '-₹0' : '-₹$safeAmount';
  }

  String badgeText(CallHistoryItem item) {
    if (item.isMissed) {
      return item.isIncoming ? 'Missed' : 'Not answered';
    }

    if (item.isPaidCall) {
      return item.isIncoming
          ? (item.listenerCredited ? 'Credited' : 'Pending')
          : 'Paid';
    }

    if (item.isFreeAnsweredCall) {
      return item.isIncoming ? 'Received free' : 'Free';
    }

    if (item.isIncoming) {
      return item.listenerCredited ? 'Credited' : 'Pending';
    }

    return item.amount <= 0 ? 'Free' : 'Paid';
  }

  String secondaryStatus(CallHistoryItem item) {
    if (item.isMissed) {
      final rejectedReason = item.rejectedReason.trim();
      final endedReason = item.endedReason.trim();

      if (rejectedReason.isNotEmpty) {
        return _humanizeReason(rejectedReason);
      }

      if (endedReason.isNotEmpty) {
        return _humanizeReason(endedReason);
      }

      return item.isIncoming ? 'Missed call' : 'Call not answered';
    }

    if (item.isFreeAnsweredCall) {
      return 'Answered under 60s';
    }

    if (item.isIncoming) {
      if (item.amount <= 0) return 'No credit for free call';
      return item.listenerCredited ? 'Amount credited' : 'Credit pending';
    }

    return item.amount > 0 ? 'Amount charged' : 'No charge';
  }

  String _humanizeReason(String value) {
    final safe = value.trim().toLowerCase();

    switch (safe) {
      case 'timeout':
        return 'Timed out';
      case 'busy':
        return 'User was busy';
      case 'caller_cancel':
      case 'caller_cancelled':
        return 'Caller cancelled';
      case 'caller_timeout':
      case 'caller_timeout_cleanup':
      case 'no_answer':
        return 'No answer';
      case 'callee_reject':
      case 'callee_reject_callkit':
        return 'Rejected';
      case 'callkit_ended':
        return 'Call ended from system UI';
      case 'invalid':
        return 'Invalid call';
      case 'invalid_channel':
        return 'Invalid channel';
      case 'open_call_failed':
        return 'Open call failed';
      case 'user_end':
        return 'Ended normally';
      case 'connection_lost':
        return 'Connection lost';
      case 'remote_left':
        return 'Other user left';
      case 'server_timeout':
        return 'Timed out';
      case 'stale_timeout':
        return 'Call expired';
      case 'missed':
        return 'Missed call';
      default:
        if (safe.isEmpty) return 'Unknown';
        return safe.replaceAll('_', ' ');
    }
  }

  int missedCount(List<CallHistoryItem> items) {
    return items.where((e) => e.isMissed).length;
  }

  int shortAnsweredCount(List<CallHistoryItem> items) {
    return items.where((e) => e.isFreeAnsweredCall).length;
  }

  int paidCount(List<CallHistoryItem> items) {
    return items.where((e) => e.isPaidOrCredited).length;
  }

  int incomingCount(List<CallHistoryItem> items) {
    return items.where((e) => e.isIncoming).length;
  }

  int outgoingCount(List<CallHistoryItem> items) {
    return items.where((e) => !e.isIncoming).length;
  }

  int totalPaidOutgoingAmount(List<CallHistoryItem> items) {
    int total = 0;

    for (final item in items) {
      if (!item.isIncoming && item.amount > 0) {
        total += item.amount;
      }
    }

    return total;
  }

  int totalCreditedIncomingAmount(List<CallHistoryItem> items) {
    int total = 0;

    for (final item in items) {
      if (item.isIncoming && item.amount > 0) {
        total += item.amount;
      }
    }

    return total;
  }

  bool isEmpty(List<CallHistoryItem> items) => items.isEmpty;
}