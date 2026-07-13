import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'app_log.dart';
import 'call_manager.dart';
import 'call_session_manager.dart';

class AuthScopedSubscriptions {
  AuthScopedSubscriptions._();

  static final AuthScopedSubscriptions instance = AuthScopedSubscriptions._();

  String _lastCleanupUid = '';
  DateTime? _lastCleanupAt;

  Future<void> disposeForUid(String uid) async {
    final safeUid = uid.trim();
    if (safeUid.isEmpty) return;

    final now = DateTime.now();
    final lastAt = _lastCleanupAt;
    if (_lastCleanupUid == safeUid &&
        lastAt != null &&
        now.difference(lastAt) < const Duration(seconds: 3)) {
      return;
    }
    _lastCleanupUid = safeUid;
    _lastCleanupAt = now;

    final logUid = AppLog.safeId(safeUid);
    debugPrint('auth.cleanup_begin uid=$logUid');
    try {
      await CallManager.instance.disposeForUid(safeUid);
      await CallSessionManager.instance.disposeForUid(safeUid);
      debugPrint('auth.cleanup_success uid=$logUid');
    } catch (e) {
      debugPrint('auth.cleanup_failed uid=$logUid error=${e.runtimeType}');
    }
  }

  bool isCurrentUid(String uid) {
    final safeUid = uid.trim();
    if (safeUid.isEmpty) return false;
    return FirebaseAuth.instance.currentUser?.uid.trim() == safeUid;
  }
}
